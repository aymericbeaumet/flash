//! `@reminders`: your open reminders as flashlight rows. Picking one shows
//! it in Reminders.
//!
//! Reminders is the host's: this process is sandboxed, holds no Reminders
//! grant and reaches no EventKit. Under the manifest's `reminders`
//! capability it asks Flash for every open reminder's identifier, title,
//! list and creation time (`host.reminders`), and decides what a row is and
//! in what order. When the reminders are listed again, and when macOS may
//! be asked for access, is the shared catalog's ([`ItemCatalog`]): while
//! Reminders runs, on its launch, when focus leaves it, when the flashlight
//! opens on a listing a minute old, and on `reminders refresh`; only a
//! query or that command asks.

use flash_plugin::{
    AppItem, AppItems, Candidate, CatalogRow, CommandRequest, Context, Event, ItemCatalog,
    ItemCatalogSpec, PerformResponse, SearchRequest, SearchResponse, run,
};

const SPEC: ItemCatalogSpec = ItemCatalogSpec {
    app: AppItems::Reminders,
    bundle_id: "com.apple.reminders",
    source: "reminders.tasks",
    kind: "reminder",
    rows,
};

/// List by list, in Reminders' order, then oldest first; a list Reminders
/// no longer names goes last, and so does a reminder without a creation
/// time within its list. Reminders that tie keep the order they came in.
fn ordered(mut reminders: Vec<AppItem>) -> Vec<AppItem> {
    reminders.sort_by(|left, right| {
        let list = |reminder: &AppItem| reminder.list_index.unwrap_or(u64::MAX);
        let created = |reminder: &AppItem| reminder.created.unwrap_or(f64::INFINITY);
        list(left)
            .cmp(&list(right))
            .then(created(left).total_cmp(&created(right)))
    });
    reminders
}

/// One row per open reminder, under its title and its list's.
fn rows(reminders: Vec<AppItem>) -> Vec<CatalogRow> {
    ordered(reminders)
        .into_iter()
        .map(|reminder| CatalogRow {
            id: reminder.id.trim().to_string(),
            title: reminder.title.trim().to_string(),
            subtitle: format!(
                "Reminder — {}",
                reminder.list.as_deref().unwrap_or_default().trim()
            ),
        })
        .collect()
}

struct Reminders {
    catalog: ItemCatalog,
}

flash_plugin::plugin!(Reminders);

impl FlashPlugin for Reminders {
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
    run(Reminders {
        catalog: ItemCatalog::new(SPEC),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn reminder(id: &str, list: &str, title: &str) -> AppItem {
        AppItem {
            id: id.to_string(),
            title: title.to_string(),
            list: Some(list.to_string()),
            ..AppItem::default()
        }
    }

    fn placed(id: &str, list_index: Option<u64>, created: Option<f64>) -> AppItem {
        AppItem {
            id: id.to_string(),
            title: id.to_uppercase(),
            list_index,
            created,
            ..AppItem::default()
        }
    }

    #[test]
    fn the_manifest_declares_one_live_source_and_its_capabilities() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SPEC.source, "type": "reminders", "live": "per_scope" }])
        );
        assert_eq!(manifest["capabilities"], json!(["reminders", "open"]));
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
        assert_eq!(commands, [("reminders", "open"), ("reminders", "refresh")]);
        for surface in ["status", "hints", "query", "sandbox"] {
            assert!(manifest.get(surface).is_none(), "{surface}");
        }
    }

    #[test]
    fn reminder_rows_trim_their_fields_and_keep_their_order() {
        let rows = SPEC.candidates(vec![
            reminder("rem-1", "Inbox", "Buy milk"),
            reminder("rem-2", " Work ", " Ship release "),
            reminder("rem-1", "Inbox", "Duplicate"),
            reminder("", "Inbox", "Missing id"),
            reminder("rem-3", "Inbox", "  "),
        ]);
        let shown: Vec<(&str, Option<&str>)> = rows
            .iter()
            .map(|row| (row.title.as_str(), row.meta("subtitle")))
            .collect();
        assert_eq!(
            shown,
            [
                ("Buy milk", Some("Reminder — Inbox")),
                ("Ship release", Some("Reminder — Work")),
            ]
        );
        assert_eq!(
            serde_json::to_value(&rows[0]).unwrap(),
            json!({
                "source": "reminders.tasks", "title": "Buy milk",
                "metadata": {
                    "kind": "reminder", "subtitle": "Reminder — Inbox", "payload": "rem-1",
                },
            })
        );
    }

    /// List by list in Reminders' order, then oldest first; a list
    /// Reminders no longer names goes last.
    #[test]
    fn reminders_are_ordered_by_list_then_age() {
        let (early, late) = (Some(1_000.0), Some(2_000.0));
        let ordered = ordered(vec![
            placed("c", Some(1), late),
            placed("x", None, early),
            placed("b", Some(0), late),
            placed("a", Some(0), early),
            placed("d", Some(1), None),
            placed("y", None, early),
        ]);
        let ids: Vec<&str> = ordered
            .iter()
            .map(|reminder| reminder.id.as_str())
            .collect();
        assert_eq!(ids, ["a", "b", "c", "d", "x", "y"]);
    }
}
