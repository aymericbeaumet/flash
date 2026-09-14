//! Static lookup catalogs — emoji glyphs, HTTP status codes and DuckDuckGo-style
//! search bangs — published once at start; `!<bang> <query>` opens the engine.

use std::collections::{BTreeMap, HashMap, HashSet};

use flash_plugin::{run, Candidate, CommandRequest, Context, PerformResponse};

const EMOJIS: &str = "emojis.glyphs";
const HTTPSTATUS: &str = "httpstatus.codes";
const SEARCHENGINES: &str = "searchengines.bangs";
const EMOJI_DATA: &str = include_str!("../emoji.txt");
const ALIAS_DATA: &str = include_str!("../aliases.txt");
const STATUSES_TSV: &str = include_str!("../statuses.tsv");
const BANGS_TSV: &str = include_str!("../bangs.tsv");
const MAX_STATUSES: usize = 128;
const MAX_BANGS: usize = 4_096;
const MAX_BANG_BYTES: usize = 64;

/// One embedded dataset: the source it serves and the rows it contributes.
struct Catalog {
    source: &'static str,
    rows: fn() -> Vec<Candidate>,
}

const CATALOGS: [Catalog; 3] = [
    Catalog {
        source: EMOJIS,
        rows: || emoji_candidates(EMOJI_DATA, ALIAS_DATA),
    },
    Catalog {
        source: HTTPSTATUS,
        rows: || status_candidates(STATUSES_TSV),
    },
    Catalog {
        source: SEARCHENGINES,
        rows: || bang_candidates(&parse_bangs(BANGS_TSV)),
    },
];

/// Trimmed data lines of a `#`-commented table.
fn records(input: &str) -> impl Iterator<Item = &str> {
    input
        .lines()
        .map(|raw| raw.trim_matches([' ', '\t', '\r']))
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
}

/// `glyph<TAB>text` rows of the emoji tables (`#️⃣` is data, not a comment).
fn glyph_rows(input: &str) -> impl Iterator<Item = (&str, &str)> {
    input.lines().filter_map(|line| {
        let (glyph, text) = line.split_once('\t')?;
        let (glyph, text) = (glyph.trim(), text.trim());
        (!glyph.is_empty() && !text.is_empty()).then_some((glyph, text))
    })
}

fn parse_aliases(input: &str) -> HashMap<&str, &str> {
    glyph_rows(input).collect()
}

fn emoji_candidates(emoji_data: &str, alias_data: &str) -> Vec<Candidate> {
    let aliases = parse_aliases(alias_data);
    glyph_rows(emoji_data)
        .map(|(glyph, name)| {
            let candidate = Candidate::new(EMOJIS, format!("{glyph} {name}"))
                .kind("emoji")
                .subtitle("emoji")
                .payload(glyph);
            match aliases.get(glyph) {
                Some(shortcodes) => candidate.aliases(shortcodes.split_whitespace()),
                None => candidate,
            }
        })
        .collect()
}

/// `(code, reason phrase, category)` rows of the status table.
fn parse_statuses(input: &str) -> Vec<(&str, &str, &str)> {
    records(input)
        .filter_map(|line| {
            let mut fields = line.split('\t');
            Some((fields.next()?, fields.next()?, fields.next()?))
        })
        .take(MAX_STATUSES)
        .collect()
}

fn status_candidate((code, reason, category): (&str, &str, &str)) -> Candidate {
    Candidate::new(HTTPSTATUS, format!("{code} {reason}"))
        .url(format!(
            "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/{code}"
        ))
        .kind("http_status")
        .subtitle(format!("HTTP {category}"))
        .payload(code)
}

fn status_candidates(input: &str) -> Vec<Candidate> {
    parse_statuses(input)
        .into_iter()
        .map(status_candidate)
        .collect()
}

/// `(trigger, url template)` rows of the bang table; the first trigger wins.
fn parse_bangs(input: &str) -> Vec<(&str, &str)> {
    let mut seen = HashSet::new();
    records(input)
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let (trigger, template) = (fields.next()?, fields.next()?);
            seen.insert(trigger).then_some((trigger, template))
        })
        .take(MAX_BANGS)
        .collect()
}

fn bang_candidate((trigger, _): (&str, &str)) -> Candidate {
    Candidate::new(SEARCHENGINES, format!("!{trigger}"))
        .kind("bang")
        .subtitle("search engine bang")
        .payload(trigger)
}

fn bang_candidates(bangs: &[(&str, &str)]) -> Vec<Candidate> {
    bangs.iter().copied().map(bang_candidate).collect()
}

/// RFC 3986 query-component encoding: only unreserved bytes pass through.
fn percent_encode(input: &str) -> String {
    input.bytes().fold(String::new(), |mut out, byte| {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(char::from(byte));
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
        out
    })
}

fn search_url(
    bangs: &[(&str, &str)],
    subcommand: &str,
    args: &[String],
) -> Result<String, &'static str> {
    if subcommand.len() > MAX_BANG_BYTES {
        return Err("bang token too long");
    }
    let trigger = subcommand.to_ascii_lowercase();
    let (_, template) = bangs
        .iter()
        .find(|(candidate, _)| *candidate == trigger)
        .ok_or("unknown bang")?;
    Ok(template.replace("{{{s}}}", &percent_encode(args.join(" ").trim())))
}

struct Reference;

flash_plugin::plugin!(Reference);

impl FlashPlugin for Reference {
    async fn on_start(&self, ctx: Context) {
        let mut rows = Vec::new();
        let mut counts = BTreeMap::new();
        for catalog in &CATALOGS {
            let before = rows.len();
            rows.extend((catalog.rows)());
            counts.insert(
                catalog.source.to_string(),
                (rows.len() - before).to_string(),
            );
        }
        ctx.publish(rows);
        ctx.log_fields("info", "[reference] catalogs published", counts);
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let url = match search_url(&parse_bangs(BANGS_TSV), &command.subcommand, &command.args) {
            Ok(url) => url,
            Err(error) => return PerformResponse::fail(error),
        };
        if ctx.open_url(&url).await {
            PerformResponse::ok()
        } else {
            PerformResponse::fail("host.open failed")
        }
    }
}

fn main() {
    run(Reference);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    #[test]
    fn aliases_are_trimmed_and_last_duplicate_wins() {
        let aliases = parse_aliases(
            "😀\tgrin happy\nmalformed\n\tmissing\n😀\tjoy smile\n😇\t halo innocent \n#️⃣\thash\n",
        );

        assert_eq!(aliases.len(), 3);
        assert_eq!(aliases.get("😀"), Some(&"joy smile"));
        assert_eq!(aliases.get("😇"), Some(&"halo innocent"));
        assert_eq!(aliases.get("#️⃣"), Some(&"hash"));
    }

    #[test]
    fn emoji_rows_preserve_dataset_order_and_metadata() {
        let rows = emoji_candidates(
            "😀\tgrinning face\ninvalid\n🙏\tperson with folded hands\n",
            "🙏\tpray thanks folded_hands\n",
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
    fn embedded_emoji_catalog_is_complete_and_keeps_curated_aliases() {
        let rows = emoji_candidates(EMOJI_DATA, ALIAS_DATA);
        assert_eq!(rows.len(), 2_037);
        assert_eq!(rows[0].title, "😀 grinning face");
        assert_eq!(
            rows.iter()
                .find(|row| row.payload_str() == Some("🙏"))
                .and_then(|row| row.meta("aliases")),
            Some("pray prayer thanks please folded_hands")
        );
        assert_eq!(rows[2_036].title, "⯿ hellschreiber pause symbol");
    }

    #[test]
    fn status_parser_skips_comments_and_malformed_rows_without_reordering() {
        let statuses = parse_statuses(
            " # comment\r\n200\tOK\tsuccess\textra\nmissing\tcategory\n 418\tI'm a Teapot\tclient error\r",
        );

        assert_eq!(
            statuses,
            [
                ("200", "OK", "success"),
                ("418", "I'm a Teapot", "client error")
            ]
        );
    }

    #[test]
    fn status_rows_preserve_the_catalog_contract() {
        let row = status_candidate(("418", "I'm a Teapot", "client error"));

        assert_eq!(row.source, HTTPSTATUS);
        assert_eq!(row.title, "418 I'm a Teapot");
        assert_eq!(
            row.url.as_deref(),
            Some("https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/418")
        );
        assert_eq!(row.meta("kind"), Some("http_status"));
        assert_eq!(row.meta("subtitle"), Some("HTTP client error"));
        assert_eq!(row.payload_str(), Some("418"));
        assert!(row.effect.is_none());
    }

    #[test]
    fn embedded_status_table_is_complete_and_ordered() {
        let statuses = parse_statuses(STATUSES_TSV);
        assert_eq!(statuses.len(), 61);
        assert_eq!(statuses[0].0, "100");
        assert_eq!(statuses[60].0, "511");
    }

    #[test]
    fn bang_parser_is_first_wins_and_preserves_source_order() {
        let bangs = parse_bangs(
            "# comment\ng https://first.example/{{{s}}}\ninvalid\ng https://second.example/{{{s}}}\nddg https://duck.example/?q={{{s}}}\n",
        );

        assert_eq!(
            bangs,
            [
                ("g", "https://first.example/{{{s}}}"),
                ("ddg", "https://duck.example/?q={{{s}}}")
            ]
        );
    }

    #[test]
    fn bang_rows_keep_bang_metadata_and_order() {
        let bangs = parse_bangs("z https://z.test/{{{s}}}\na https://a.test/{{{s}}}");
        let rows = bang_candidates(&bangs);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "!z");
        assert_eq!(rows[1].title, "!a");
        assert!(rows.iter().all(|row| row.source == SEARCHENGINES));
        assert_eq!(rows[0].meta("kind"), Some("bang"));
        assert_eq!(rows[0].meta("subtitle"), Some("search engine bang"));
        assert_eq!(rows[0].payload_str(), Some("z"));
        assert!(rows[0].effect.is_none());
    }

    #[test]
    fn search_urls_are_case_insensitive_and_encode_utf8_bytes() {
        let bangs = parse_bangs("g https://google.test/?q={{{s}}}");
        let args = ["café".to_string(), "& tea".to_string()];

        assert_eq!(
            search_url(&bangs, "G", &args),
            Ok("https://google.test/?q=caf%C3%A9%20%26%20tea".to_string())
        );
        assert_eq!(search_url(&bangs, "missing", &[]), Err("unknown bang"));
    }

    #[test]
    fn embedded_bang_table_is_complete_and_keeps_dataset_order() {
        let bangs = parse_bangs(BANGS_TSV);
        assert_eq!(bangs.len(), 77);
        assert_eq!(bangs[0].0, "g");
        assert_eq!(bangs[76].0, "deepl");
        assert_eq!(
            search_url(&bangs, "googlemaps", &["a b".to_string()]),
            Ok("https://www.google.com/maps/search/a%20b".to_string())
        );
    }

    #[tokio::test]
    async fn start_publishes_every_catalog_in_one_frame() {
        let mut harness = Harness::new("reference-test");
        Reference.on_start(harness.context()).await;

        let frames = harness.drain();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["method"], "publish");
        assert_eq!(frames[1]["method"], "log");
        let rows = frames[0]["params"]["rows"].as_array().unwrap();
        let count = |source| rows.iter().filter(|row| row["source"] == source).count();
        assert_eq!(rows.len(), 2_037 + 61 + 77);
        for (source, expected) in [(EMOJIS, 2_037), (HTTPSTATUS, 61), (SEARCHENGINES, 77)] {
            assert_eq!(count(source), expected);
            assert_eq!(frames[1]["params"]["fields"][source], expected.to_string());
        }
    }
}
