//! Emoji finder plugin.
//!
//! Ships a static, Unicode-derived emoji dataset (glyph + lowercase UCD
//! name) embedded at build time. On startup it emits the whole set as a
//! `snapshot.updated` candidate list under the `emoji` source; Flash
//! filters/fuzzy-matches them behind `:emojis <query>` and, on selection,
//! inserts the glyph into the focused app. The plugin is otherwise inert —
//! the dataset never changes, so there is nothing to refresh on events.

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, Context, Plugin};

const SOURCE_ID: &str = "emoji";

/// `<glyph>\t<lowercase name>` rows, one per line.
const EMOJI_DATA: &str = include_str!("../emoji.txt");

fn build_candidates() -> Vec<Value> {
    EMOJI_DATA
        .lines()
        .filter_map(|line| {
            let (glyph, name) = line.split_once('\t')?;
            let glyph = glyph.trim();
            let name = name.trim();
            if glyph.is_empty() || name.is_empty() {
                return None;
            }
            Some(json!({
                "kind": "emoji",
                "source_id": SOURCE_ID,
                "source": SOURCE_ID,
                "name": format!("{glyph} {name}"),
                "subtitle": "emoji",
                "payload": glyph,
            }))
        })
        .collect()
}

struct Emojis;

impl Plugin for Emojis {
    async fn on_start(&self, ctx: Context) {
        let candidates = build_candidates();
        ctx.log_fields(
            "info",
            "[emoji] dataset loaded",
            [("count".to_string(), candidates.len().to_string())]
                .into_iter()
                .collect(),
        );
        ctx.emit.notify(
            "snapshot.updated",
            json!({ "targets": [], "candidates": candidates, "source_id": SOURCE_ID }),
        );
    }

    async fn handle(&self, _ctx: Context, method: String, _params: Value) -> Value {
        match method.as_str() {
            "discoverTargets" => json!({ "targets": [] }),
            other => json!({ "ok": false, "error": format!("unknown method: {other}") }),
        }
    }
}

fn main() {
    run(Emojis);
}
