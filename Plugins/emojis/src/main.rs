//! Static Unicode emoji catalog with Slack-style search aliases.

use std::collections::{BTreeMap, HashMap};

use flash_plugin::{run, Candidate, Context};

const SOURCE: &str = "emojis.glyphs";
const EMOJI_DATA: &str = include_str!("../emoji.txt");
const ALIAS_DATA: &str = include_str!("../aliases.txt");

fn parse_aliases(input: &str) -> HashMap<&str, &str> {
    input
        .lines()
        .filter_map(|line| {
            let (glyph, aliases) = line.split_once('\t')?;
            let glyph = glyph.trim();
            let aliases = aliases.trim();
            (!glyph.is_empty() && !aliases.is_empty()).then_some((glyph, aliases))
        })
        .collect()
}

fn build_candidates(emoji_data: &str, alias_data: &str) -> Vec<Candidate> {
    let aliases = parse_aliases(alias_data);
    emoji_data
        .lines()
        .filter_map(|line| {
            let (glyph, name) = line.split_once('\t')?;
            let glyph = glyph.trim();
            let name = name.trim();
            if glyph.is_empty() || name.is_empty() {
                return None;
            }
            let mut candidate = Candidate::new(SOURCE, format!("{glyph} {name}"))
                .kind("emoji")
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

impl FlashPlugin for Emojis {
    async fn on_start(&self, ctx: Context) {
        let rows = build_candidates(EMOJI_DATA, ALIAS_DATA);
        let count = rows.len();
        ctx.publish(rows);
        ctx.log_fields(
            "info",
            "[emoji] dataset published",
            BTreeMap::from([("count".to_string(), count.to_string())]),
        );
    }
}

fn main() {
    run(Emojis);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_are_trimmed_and_last_duplicate_wins() {
        let aliases = parse_aliases(
            "😀\tgrin happy\nmalformed\n\tmissing\n😀\tjoy smile\n😇\t halo innocent \n",
        );

        assert_eq!(aliases.len(), 2);
        assert_eq!(aliases.get("😀"), Some(&"joy smile"));
        assert_eq!(aliases.get("😇"), Some(&"halo innocent"));
    }

    #[test]
    fn catalog_rows_preserve_dataset_order_and_metadata() {
        let rows = build_candidates(
            "😀\tgrinning face\ninvalid\n🙏\tperson with folded hands\n",
            "🙏\tpray thanks folded_hands\n",
        );

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "😀 grinning face");
        assert_eq!(rows[1].title, "🙏 person with folded hands");
        assert!(rows.iter().all(|row| row.source == SOURCE));
        assert_eq!(rows[0].meta("kind"), Some("emoji"));
        assert_eq!(rows[0].meta("subtitle"), Some("emoji"));
        assert_eq!(rows[0].payload_str(), Some("😀"));
        assert_eq!(rows[0].meta("aliases"), None);
        assert_eq!(rows[1].meta("aliases"), Some("pray thanks folded_hands"));
        assert!(rows.iter().all(|row| row.effect.is_none()));
    }

    #[test]
    fn embedded_catalog_is_complete_and_keeps_curated_aliases() {
        let rows = build_candidates(EMOJI_DATA, ALIAS_DATA);
        assert_eq!(rows.len(), 2_037);
        assert_eq!(
            rows.first().map(|row| row.title.as_str()),
            Some("😀 grinning face")
        );
        assert_eq!(
            rows.iter()
                .find(|row| row.payload_str() == Some("🙏"))
                .and_then(|row| row.meta("aliases")),
            Some("pray prayer thanks please folded_hands")
        );
        assert_eq!(
            rows.last().map(|row| row.title.as_str()),
            Some("⯿ hellschreiber pause symbol")
        );
    }
}
