//! `@contacts`: your contact cards as flashlight rows. Picking one shows
//! its card in Contacts.
//!
//! Contacts is the host's: this process is sandboxed, holds no Contacts
//! grant and reaches no address book. Under the manifest's `contacts`
//! capability it asks Flash for every card's identifier and the name
//! Contacts shows it by (`host.contacts`), never a phone number or an
//! address, and decides what a row is. When the cards are listed again, and
//! when macOS may be asked for access, is the shared catalog's
//! ([`ItemCatalog`]): while Contacts runs, on its launch, when focus leaves
//! it, when the flashlight opens on a listing a minute old, and on
//! `contacts refresh`; only a query or that command asks.

use std::collections::HashSet;

use flash_plugin::{
    AppItem, AppItems, Candidate, CatalogRow, CommandRequest, Context, Event, ItemCatalog,
    ItemCatalogSpec, PerformResponse, SearchRequest, SearchResponse, run,
};

const SPEC: ItemCatalogSpec = ItemCatalogSpec {
    app: AppItems::Contacts,
    bundle_id: "com.apple.AddressBook",
    source: "contacts.cards",
    kind: "contact",
    rows,
};

/// One row per name, in Contacts' own order: two cards with the same name
/// would read as the same row, so the first stands for both.
fn rows(cards: Vec<AppItem>) -> Vec<CatalogRow> {
    let mut names = HashSet::new();
    cards
        .into_iter()
        .filter_map(|card| {
            let name = card.title.trim();
            names.insert(name.to_string()).then(|| CatalogRow {
                id: card.id.trim().to_string(),
                title: name.to_string(),
                subtitle: "Contact".to_string(),
            })
        })
        .collect()
}

struct Contacts {
    catalog: ItemCatalog,
}

flash_plugin::plugin!(Contacts);

impl FlashPlugin for Contacts {
    async fn on_event(&self, ctx: Context, event: Event) {
        self.catalog.on_event(&ctx, &event);
    }

    async fn on_search(&self, ctx: Context, request: SearchRequest) -> SearchResponse {
        self.catalog.search(&ctx, &request).await
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        self.catalog.command(&ctx, &command).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        self.catalog.resolve(&ctx, &row).await
    }
}

fn main() {
    run(Contacts {
        catalog: ItemCatalog::new(SPEC),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::time::Instant;

    fn card(id: &str, name: &str) -> AppItem {
        AppItem {
            id: id.to_string(),
            title: name.to_string(),
            ..AppItem::default()
        }
    }

    #[test]
    fn the_manifest_declares_one_live_source_and_its_capabilities() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SPEC.source, "type": "contacts", "live": "per_scope" }])
        );
        assert_eq!(manifest["capabilities"], json!(["contacts", "open"]));
        assert_eq!(
            manifest["listen"],
            json!([
                "core:apps.launched",
                "core:apps.terminated",
                "core:focus.changed",
                "core:session.opened"
            ])
        );
        let commands: Vec<(&str, &str)> = manifest["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| {
                (
                    entry["command"].as_str().unwrap(),
                    entry["subcommand"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(commands, [("contacts", "open"), ("contacts", "refresh")]);
        for surface in ["status", "hints", "query", "sandbox"] {
            assert!(manifest.get(surface).is_none(), "{surface}");
        }
    }

    /// Two cards with one name read as one row: the first, in Contacts'
    /// order.
    #[test]
    fn contact_rows_are_one_per_name() {
        let rows = SPEC.candidates(vec![
            card("1:ABPerson", "Ada Lovelace"),
            card("2:ABPerson", " Grace Hopper "),
            card("3:ABPerson", "Ada Lovelace"),
            card("4:ABPerson", ""),
        ]);
        let shown: Vec<(&str, Option<&str>)> = rows
            .iter()
            .map(|row| (row.title.as_str(), row.payload_str()))
            .collect();
        assert_eq!(
            shown,
            [
                ("Ada Lovelace", Some("1:ABPerson")),
                ("Grace Hopper", Some("2:ABPerson")),
            ]
        );
        assert_eq!(
            serde_json::to_value(&rows[0]).unwrap(),
            json!({
                "source": "contacts.cards", "title": "Ada Lovelace",
                "metadata": {
                    "kind": "contact", "subtitle": "Contact", "payload": "1:ABPerson",
                    "finishes_command": "1",
                },
            })
        );
    }

    /// Five thousand cards are one search reply well inside the row and
    /// byte quotas (10,000 rows, 4 MiB), shaped in a few milliseconds.
    #[test]
    fn five_thousand_contacts_fit_one_search_reply() {
        let cards: Vec<AppItem> = (0..5_000)
            .map(|index| {
                card(
                    &format!("410FE041-5C4E-48DA-B4DE-{index:012}:ABPerson"),
                    &format!("Contact Number {index} Lastname"),
                )
            })
            .collect();
        let started = Instant::now();
        let rows = SPEC.candidates(cards);
        let encoded = serde_json::to_vec(&rows).unwrap();
        let elapsed = started.elapsed();
        assert_eq!(rows.len(), 5_000);
        assert!(
            encoded.len() < 4 * 1024 * 1024 / 4,
            "{} bytes",
            encoded.len()
        );
        assert!(elapsed.as_millis() < 250, "{elapsed:?}");
    }
}
