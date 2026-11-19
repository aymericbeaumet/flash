//! `@notes`: your notes as flashlight rows. Picking one shows it in Notes.
//!
//! Notes is the host's: this process is sandboxed, holds no Automation
//! grant and sends no Apple Event. Under the manifest's `notes` capability
//! it asks Flash for every note's identifier and name (`host.notes`), which
//! Flash reads with its own fixed scripts, and decides what a row is. When
//! the notes are listed again, and when macOS may be asked for access, is
//! the shared catalog's ([`ItemCatalog`]): while Notes runs, on its launch,
//! when focus leaves it, when the flashlight opens on a listing a minute
//! old, and on `notes refresh`; only a query or that command asks.

use flash_plugin::{
    AppItem, AppItems, Candidate, CatalogRow, CommandRequest, Context, Event, ItemCatalog,
    ItemCatalogSpec, PerformResponse, SearchRequest, SearchResponse, run,
};

const SPEC: ItemCatalogSpec = ItemCatalogSpec {
    app: AppItems::Notes,
    bundle_id: "com.apple.Notes",
    source: "notes.notes",
    kind: "note",
    rows,
};

/// One row per note, in Notes' own order, under its name.
fn rows(notes: Vec<AppItem>) -> Vec<CatalogRow> {
    notes
        .into_iter()
        .map(|note| CatalogRow {
            id: note.id.trim().to_string(),
            title: note.title.trim().to_string(),
            subtitle: "Note".to_string(),
        })
        .collect()
}

struct Notes {
    catalog: ItemCatalog,
}

flash_plugin::plugin!(Notes);

impl FlashPlugin for Notes {
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
    run(Notes {
        catalog: ItemCatalog::new(SPEC),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn note(id: &str, title: &str) -> AppItem {
        AppItem {
            id: id.to_string(),
            title: title.to_string(),
            ..AppItem::default()
        }
    }

    /// One live source of the shared type, pulled once per scope, behind
    /// the capabilities the listing and `notes open` ask for, in the
    /// default sandbox. Its events keep no process.
    #[test]
    fn the_manifest_declares_one_live_source_and_its_capabilities() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SPEC.source, "type": "notes", "live": "per_scope" }])
        );
        assert_eq!(manifest["capabilities"], json!(["notes", "open"]));
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
        assert_eq!(commands, [("notes", "open"), ("notes", "refresh")]);
        for surface in [
            "status",
            "hints",
            "query",
            "sandbox",
            "apple_events_targets",
        ] {
            assert!(manifest.get(surface).is_none(), "{surface}");
        }
    }

    #[test]
    fn a_note_is_a_row_under_its_trimmed_name() {
        let rows = SPEC.candidates(vec![
            note("note-1", "First"),
            note(" note-2 ", " Second "),
            note("note-1", "Renamed"),
            note("", "Missing id"),
            note("note-3", "  "),
        ]);
        let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
        assert_eq!(titles, ["First", "Second"], "Notes' order, an id once");
        assert_eq!(
            serde_json::to_value(&rows[1]).unwrap(),
            json!({
                "source": "notes.notes", "title": "Second",
                "metadata": { "kind": "note", "subtitle": "Note", "payload": "note-2" },
            })
        );
        assert!(SPEC.candidates(Vec::new()).is_empty());
    }
}
