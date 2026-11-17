//! The emoji glyph catalog, published once at start.
//!
//! A row is `glyph name`, searchable by the Unicode name in its title and by
//! the aliases the flashlight scores on its alias tier: the shortcodes of
//! `aliases.txt`, then the English CLDR keywords of `cldr-keywords.tsv` that
//! no name or shortcode in the catalog already carries. The host ranks an
//! exact alias above a name, so a keyword repeating another emoji's name
//! would outrank that emoji (`party` on the tropical drink would beat the
//! party popper); keywords therefore add only the vocabulary the names and
//! shortcodes lack (`idk`, `hooray`, `thx`, `facepalm`).
//!
//! The emoji glyph catalog, published once at start. `lifecycle:
//! publish_then_exit`: the process exits once the catalog is published and
//! the host keeps the rows, so no child stays resident for static data.

use std::collections::{BTreeMap, HashMap, HashSet};

use flash_plugin::{Candidate, Context, run};

const EMOJIS: &str = "emojis.glyphs";
const EMOJI_DATA: &str = include_str!("../emoji.txt");
const ALIAS_DATA: &str = include_str!("../aliases.txt");
/// `glyph<TAB>keyword|keyword…` written by `Scripts/update-emoji-keywords.sh`;
/// its `#` header lines carry no tab and parse as nothing.
const KEYWORD_DATA: &str = include_str!("../cldr-keywords.tsv");

/// The emoji presentation selector: CLDR writes every glyph without it and
/// `aliases.txt` writes some with it, so glyph lookups key on the glyph
/// without.
const VARIATION_SELECTOR_16: char = '\u{FE0F}';

/// `glyph<TAB>text` rows of the emoji tables (`#️⃣` is data, not a comment).
fn glyph_rows(input: &str) -> impl Iterator<Item = (&str, &str)> {
    input.lines().filter_map(|line| {
        let (glyph, text) = line.split_once('\t')?;
        let (glyph, text) = (glyph.trim(), text.trim());
        (!glyph.is_empty() && !text.is_empty()).then_some((glyph, text))
    })
}

fn glyph_key(glyph: &str) -> String {
    glyph
        .chars()
        .filter(|character| *character != VARIATION_SELECTOR_16)
        .collect()
}

/// A glyph table keyed without the presentation selector; the last row of a
/// repeated glyph wins.
fn parse_glyph_table(input: &str) -> HashMap<String, &str> {
    glyph_rows(input)
        .map(|(glyph, text)| (glyph_key(glyph), text))
        .collect()
}

/// The host's search tokens of a text: lowercase alphanumeric runs, as the
/// flashlight normalizer splits a title or an alias before scoring.
fn search_tokens(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(str::to_lowercase)
}

/// Every token a name or a shortcode of the catalog carries.
fn taken_tokens<'a>(
    names: impl IntoIterator<Item = &'a str>,
    shortcodes: impl IntoIterator<Item = &'a str>,
) -> HashSet<String> {
    names
        .into_iter()
        .chain(shortcodes)
        .flat_map(search_tokens)
        .collect()
}

/// The keywords of one glyph the catalog does not know yet, in CLDR order:
/// every search token of a kept keyword is at least two characters
/// (`o’clock` and `a.m.` would otherwise leave `o` and `a` as aliases) and
/// none is a token of a name or a shortcode.
fn fresh_keywords<'a>(keywords: &'a str, taken: &HashSet<String>) -> Vec<&'a str> {
    let mut seen = HashSet::new();
    keywords
        .split('|')
        .map(str::trim)
        .filter(|keyword| {
            let tokens: Vec<String> = search_tokens(keyword).collect();
            !tokens.is_empty()
                && tokens
                    .iter()
                    .all(|token| token.chars().count() >= 2 && !taken.contains(token))
                && seen.insert(tokens)
        })
        .collect()
}

fn emoji_candidates(emoji_data: &str, alias_data: &str, keyword_data: &str) -> Vec<Candidate> {
    let shortcodes = parse_glyph_table(alias_data);
    let keywords = parse_glyph_table(keyword_data);
    let glyphs: Vec<(&str, &str)> = glyph_rows(emoji_data).collect();
    let taken = taken_tokens(
        glyphs.iter().map(|(_, name)| *name),
        shortcodes.values().copied(),
    );
    glyphs
        .into_iter()
        .map(|(glyph, name)| {
            let key = glyph_key(glyph);
            let shortcodes = shortcodes
                .get(&key)
                .into_iter()
                .flat_map(|text| text.split_whitespace());
            let keywords = keywords
                .get(&key)
                .map(|text| fresh_keywords(text, &taken))
                .unwrap_or_default();
            Candidate::new(EMOJIS, format!("{glyph} {name}"))
                .kind("emoji")
                .subtitle("emoji")
                .payload(glyph)
                .aliases(shortcodes.chain(keywords))
        })
        .collect()
}

struct Emojis;

flash_plugin::plugin!(Emojis);

impl FlashPlugin for Emojis {
    async fn on_start(&self, ctx: Context) {
        let rows = emoji_candidates(EMOJI_DATA, ALIAS_DATA, KEYWORD_DATA);
        let fields = BTreeMap::from([("rows".to_string(), rows.len().to_string())]);
        ctx.publish(rows);
        ctx.log_fields("debug", "[emojis] catalog published", fields);
    }
}

fn main() {
    run(Emojis);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    /// `protocol.json` `quotas`, pinned by the SDK's wire suite.
    const CATALOG_ROWS_QUOTA: usize = 10_000;
    const CATALOG_BYTES_QUOTA: usize = 4 * 1024 * 1024;
    const METADATA_ENTRIES_QUOTA: usize = 64;
    const METADATA_KEY_BYTES_QUOTA: usize = 256;
    const METADATA_VALUE_BYTES_QUOTA: usize = 64 * 1024;

    fn aliases_of<'a>(rows: &'a [Candidate], glyph: &str) -> Option<&'a str> {
        rows.iter()
            .find(|row| row.payload_str() == Some(glyph))
            .expect("glyph in catalog")
            .meta("aliases")
    }

    #[test]
    fn glyph_tables_are_trimmed_keyed_without_vs16_and_last_duplicate_wins() {
        let aliases = parse_glyph_table(
            "😀\tgrin happy\nmalformed\n\tmissing\n😀\tjoy smile\n😇\t halo innocent \n#️⃣\thash\n❤️\theart\n",
        );

        assert_eq!(aliases.len(), 4);
        assert_eq!(aliases.get("😀"), Some(&"joy smile"));
        assert_eq!(aliases.get("😇"), Some(&"halo innocent"));
        assert_eq!(aliases.get("#⃣"), Some(&"hash"));
        assert_eq!(aliases.get("❤"), Some(&"heart"));
        assert_eq!(aliases.get("❤️"), None);
    }

    #[test]
    fn emoji_rows_preserve_dataset_order_and_metadata() {
        let rows = emoji_candidates(
            "😀\tgrinning face\ninvalid\n🙏\tperson with folded hands\n",
            "🙏\tpray thanks folded_hands\n",
            "",
        );

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "😀 grinning face");
        assert_eq!(rows[1].title, "🙏 person with folded hands");
        assert!(rows.iter().all(|row| row.source == EMOJIS));
        assert_eq!(rows[0].meta("kind"), Some("emoji"));
        assert_eq!(rows[0].meta("subtitle"), Some("emoji"));
        assert_eq!(rows[0].payload_str(), Some("😀"));
        assert_eq!(rows[0].meta("aliases"), None);
        assert_eq!(rows[1].meta("aliases"), Some("pray thanks folded_hands"));
        assert!(rows.iter().all(|row| row.effect.is_none()));
    }

    #[test]
    fn keywords_add_only_the_vocabulary_names_and_shortcodes_lack() {
        let rows = emoji_candidates(
            "🎉\tparty popper\n🍹\ttropical drink\n🤷\tshrug\n🕐\tclock face one oclock\n",
            "🎉\ttada party celebrate\n",
            "# a header line carries no tab\n\
             🎉\tcelebrate|hooray|party|tada\n\
             🍹\tbar|drink|party|tropical|Mai Tai\n\
             🤷\tdunno|idk|shrug|IDK|who\n\
             🕐\t1:00|o’clock|one|time\n",
        );

        // `party` stays with the rows whose name or shortcode carries it:
        // the alias tier outranks the name tier, so the tropical drink
        // tagged `party` would otherwise beat the party popper.
        assert_eq!(rows[0].meta("aliases"), Some("tada party celebrate hooray"));
        // `drink` and `tropical` are its own name, `party` another row's
        // shortcode; a multi-word keyword passes as one alias string.
        assert_eq!(rows[1].meta("aliases"), Some("bar Mai Tai"));
        // `shrug` is the name; keywords equal after normalization appear once.
        assert_eq!(rows[2].meta("aliases"), Some("dunno idk who"));
        // `1:00` and `o’clock` leave single-character tokens; `one` and
        // `clock` name the row.
        assert_eq!(rows[3].meta("aliases"), Some("time"));
    }

    #[test]
    fn presentation_selector_does_not_separate_a_glyph_from_its_aliases() {
        let rows = emoji_candidates(
            "❤\theavy black heart\n",
            "❤️\theart love red_heart\n",
            "❤️\temotion|heart|love|red\n",
        );

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "❤ heavy black heart");
        assert_eq!(rows[0].payload_str(), Some("❤"));
        assert_eq!(
            rows[0].meta("aliases"),
            Some("heart love red_heart emotion")
        );
    }

    #[test]
    fn embedded_keyword_table_covers_the_catalog_once_per_glyph() {
        assert!(KEYWORD_DATA.starts_with("# Unicode CLDR emoji keywords"));
        let glyphs: HashSet<String> = glyph_rows(EMOJI_DATA)
            .map(|(glyph, _)| glyph_key(glyph))
            .collect();
        let mut seen = HashSet::new();
        for (glyph, keywords) in glyph_rows(KEYWORD_DATA) {
            assert!(glyphs.contains(glyph), "{glyph} is not in emoji.txt");
            assert!(seen.insert(glyph), "{glyph} is listed twice");
            let list: Vec<&str> = keywords.split('|').collect();
            let unique: HashSet<&str> = list.iter().copied().collect();
            assert_eq!(list.len(), unique.len(), "{glyph} repeats a keyword");
            assert!(
                list.iter()
                    .all(|keyword| !keyword.is_empty() && keyword.trim() == *keyword),
                "{glyph} has an empty or untrimmed keyword"
            );
        }
        assert_eq!(seen.len(), 1_304);

        let table = parse_glyph_table(KEYWORD_DATA);
        assert_eq!(table["👍"], "+1|good|hand|like|thumb|up|yes");
        assert_eq!(table["🔥"], "af|burn|fire|flame|hot|lit|litaf|tool");
        assert!(table["🤷"].split('|').any(|keyword| keyword == "idk"));
        assert!(table["🎉"].split('|').any(|keyword| keyword == "hooray"));
        assert_eq!(table["🔟"], "keycap");
        assert_eq!(table.get("⯿"), None);
    }

    #[test]
    fn embedded_emoji_catalog_is_complete_and_keeps_curated_aliases() {
        let rows = emoji_candidates(EMOJI_DATA, ALIAS_DATA, KEYWORD_DATA);
        assert_eq!(rows.len(), 2_037);
        assert_eq!(rows[0].title, "😀 grinning face");
        assert_eq!(
            aliases_of(&rows, "🙏"),
            Some("pray prayer thanks please folded_hands appreciate ask beg blessed cmon thx")
        );
        assert_eq!(
            aliases_of(&rows, "🤷"),
            Some("doubt dunno guess idk ignorance indifference knows maybe shrugging whatever who")
        );
        assert_eq!(
            aliases_of(&rows, "🎉"),
            Some("tada party celebrate awesome excited hooray woohoo")
        );
        assert_eq!(
            aliases_of(&rows, "🍹"),
            Some("tropical_drink alcohol booze drinking drinks drunk mai tai tropics")
        );
        assert_eq!(aliases_of(&rows, "❤"), Some("heart love red_heart emotion"));
        assert_eq!(aliases_of(&rows, "⯿"), None);
        assert_eq!(rows[2_036].title, "⯿ hellschreiber pause symbol");
    }

    /// `lifecycle: publish_then_exit`: the process answers initialize,
    /// publishes the catalog and exits 0 on its own; the host keeps the
    /// rows and spawns it again only on a reload.
    #[tokio::test]
    async fn the_run_ends_once_the_catalog_is_published() {
        use flash_plugin::testing::WireHarness;
        let mut wire = WireHarness::new(Emojis);
        wire.send(serde_json::json!({
            "id": 1, "method": "initialize", "params": { "protocol_version": 1 }
        }))
        .await;
        assert_eq!(wire.recv_response(1).await["ok"], true);
        let publish = wire.recv_notification("publish").await;
        assert_eq!(publish["rows"].as_array().unwrap().len(), 2_037);
        let rest = wire.finished().await;
        assert!(
            rest.iter().all(|frame| frame["method"] == "log"),
            "{rest:?}"
        );
    }

    #[tokio::test]
    async fn start_publishes_the_emoji_catalog_in_one_frame_within_quotas() {
        let mut harness = Harness::new("emojis-test");
        Emojis.on_start(harness.context()).await;

        let frames = harness.drain();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["method"], "publish");
        assert_eq!(frames[1]["method"], "log");
        let rows = frames[0]["params"]["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 2_037);
        assert!(rows.iter().all(|row| row["source"] == EMOJIS));
        assert_eq!(frames[1]["params"]["fields"]["rows"], "2037");

        // The host counts the compact `rows` array as the SDK writes it.
        assert!(rows.len() <= CATALOG_ROWS_QUOTA);
        let bytes = frames[0]["params"]["rows"].to_string().len();
        assert!(bytes <= CATALOG_BYTES_QUOTA, "catalog is {bytes} bytes");
        for row in rows {
            let metadata = row["metadata"].as_object().unwrap();
            assert!(metadata.len() <= METADATA_ENTRIES_QUOTA);
            for (key, value) in metadata {
                assert!(key.len() <= METADATA_KEY_BYTES_QUOTA);
                assert!(value.as_str().unwrap().len() <= METADATA_VALUE_BYTES_QUOTA);
            }
        }
    }
}
