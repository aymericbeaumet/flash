//! Emoji finder plugin.
//!
//! Ships a static, Unicode-derived emoji dataset (glyph + lowercase UCD
//! name) embedded at build time. On startup it emits the whole set as a
//! `snapshot.updated` candidate list under the `emoji` source; Flash
//! filters/fuzzy-matches them behind `:emojis <query>` and, on selection,
//! inserts the glyph into the focused app. The plugin is otherwise inert —
//! the dataset never changes, so there is nothing to refresh on events.
//!
//! A side dataset of curated Slack-style shortcodes (`aliases.txt`) is
//! attached as the candidate's search aliases so a literal `:pray:` /
//! `pray` query ranks `🙏` ahead of UCD-name prefixes like `prayer beads`.

use std::collections::HashMap;

use flash_plugin::{run, Candidate, Context};

const SOURCE_ID: &str = "plugin:emojis";

/// `<glyph>\t<lowercase name>` rows, one per line.
const EMOJI_DATA: &str = include_str!("../emoji.txt");
/// `<glyph>\t<space-separated shortcode tokens>` rows, one per line.
/// Maps to the candidate's `search_aliases` field; missing glyphs are
/// fine — the plugin falls back to the UCD name alone.
const ALIAS_DATA: &str = include_str!("../aliases.txt");

fn parse_aliases() -> HashMap<&'static str, &'static str> {
    ALIAS_DATA
        .lines()
        .filter_map(|line| {
            let (glyph, aliases) = line.split_once('\t')?;
            let glyph = glyph.trim();
            let aliases = aliases.trim();
            if glyph.is_empty() || aliases.is_empty() {
                None
            } else {
                Some((glyph, aliases))
            }
        })
        .collect()
}

fn build_candidates() -> Vec<Candidate> {
    let aliases = parse_aliases();
    EMOJI_DATA
        .lines()
        .filter_map(|line| {
            let (glyph, name) = line.split_once('\t')?;
            let glyph = glyph.trim();
            let name = name.trim();
            if glyph.is_empty() || name.is_empty() {
                return None;
            }
            let mut candidate = Candidate::new(format!("{glyph} {name}"))
                .kind("emoji")
                .source_id(SOURCE_ID)
                .source("emojis.glyphs")
                .subtitle("emoji")
                .payload(glyph);
            if let Some(shortcodes) = aliases.get(glyph) {
                candidate = candidate.aliases(shortcodes.split_whitespace());
            }
            Some(candidate)
        })
        .collect()
}

struct Emojis;

flash_plugin::plugin!(Emojis);

// The host inserts the chosen glyph from each candidate's payload, so the
// dataset emitted on start is all this plugin drives — every handler defaults.
impl FlashPlugin for Emojis {
    async fn on_start(&self, ctx: Context) {
        let candidates = build_candidates();
        ctx.log_fields(
            "info",
            "[emoji] dataset loaded",
            [("count".to_string(), candidates.len().to_string())]
                .into_iter()
                .collect(),
        );
        ctx.set_locations(SOURCE_ID, candidates);
    }
}

fn main() {
    run(Emojis);
}
