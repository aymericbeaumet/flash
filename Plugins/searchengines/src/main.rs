//! Static DuckDuckGo-style search-bang catalog and command router.

use std::collections::HashSet;

use flash_plugin::{run, Candidate, CommandRequest, Context, PerformResponse};

const SOURCE: &str = "searchengines.bangs";
const MAX_BANGS: usize = 4_096;
const MAX_BANG_BYTES: usize = 64;
const BANGS_TSV: &str = include_str!("../bangs.tsv");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Bang<'a> {
    trigger: &'a str,
    template: &'a str,
}

fn parse_bangs(input: &str) -> Vec<Bang<'_>> {
    let mut seen = HashSet::new();
    input
        .lines()
        .filter_map(|raw| {
            let line = raw.trim_matches(|character| {
                character == ' ' || character == '\t' || character == '\r'
            });
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let mut fields = line.split_whitespace();
            let trigger = fields.next()?;
            let template = fields.next()?;
            seen.insert(trigger).then_some(Bang { trigger, template })
        })
        .take(MAX_BANGS)
        .collect()
}

fn lookup<'a>(bangs: &'a [Bang<'a>], trigger: &str) -> Option<&'a str> {
    bangs
        .iter()
        .find(|bang| bang.trigger == trigger)
        .map(|bang| bang.template)
}

fn candidate(bang: Bang<'_>) -> Candidate {
    Candidate::new(SOURCE, format!("!{}", bang.trigger))
        .kind("bang")
        .subtitle("search engine bang")
        .payload(bang.trigger)
}

fn build_candidates(bangs: &[Bang<'_>]) -> Vec<Candidate> {
    bangs.iter().copied().map(candidate).collect()
}

/// RFC 3986 query-component encoding: only unreserved bytes pass through.
fn percent_encode(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";

    let mut encoded = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(char::from(byte));
            }
            _ => {
                encoded.push('%');
                encoded.push(char::from(HEX[usize::from(byte >> 4)]));
                encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
            }
        }
    }
    encoded
}

fn search_url(
    bangs: &[Bang<'_>],
    subcommand: &str,
    args: &[String],
) -> Result<String, &'static str> {
    if subcommand.len() > MAX_BANG_BYTES {
        return Err("bang token too long");
    }
    let trigger = subcommand.to_ascii_lowercase();
    let template = lookup(bangs, &trigger).ok_or("unknown bang")?;
    let query = args.join(" ");
    Ok(template.replace("{{{s}}}", &percent_encode(query.trim())))
}

struct SearchEngines {
    bangs: Vec<Bang<'static>>,
}

flash_plugin::plugin!(SearchEngines);

impl FlashPlugin for SearchEngines {
    async fn on_start(&self, ctx: Context) {
        ctx.publish(build_candidates(&self.bangs));
        ctx.log("info", "[searchengines] bang table published");
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let url = match search_url(&self.bangs, &command.subcommand, &command.args) {
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
    run(SearchEngines {
        bangs: parse_bangs(BANGS_TSV),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_is_first_wins_and_preserves_source_order() {
        let bangs = parse_bangs(
            "# comment\ng https://first.example/{{{s}}}\ninvalid\ng https://second.example/{{{s}}}\nddg https://duck.example/?q={{{s}}}\n",
        );

        assert_eq!(
            bangs,
            [
                Bang {
                    trigger: "g",
                    template: "https://first.example/{{{s}}}",
                },
                Bang {
                    trigger: "ddg",
                    template: "https://duck.example/?q={{{s}}}",
                },
            ]
        );
    }

    #[test]
    fn catalog_rows_keep_bang_metadata_and_order() {
        let bangs = parse_bangs("z https://z.test/{{{s}}}\na https://a.test/{{{s}}}");
        let rows = build_candidates(&bangs);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "!z");
        assert_eq!(rows[1].title, "!a");
        assert!(rows.iter().all(|row| row.source == SOURCE));
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
    fn embedded_table_is_complete_and_keeps_dataset_order() {
        let bangs = parse_bangs(BANGS_TSV);
        assert_eq!(bangs.len(), 77);
        assert_eq!(bangs.first().map(|bang| bang.trigger), Some("g"));
        assert_eq!(bangs.last().map(|bang| bang.trigger), Some("deepl"));
        assert_eq!(
            lookup(&bangs, "googlemaps"),
            Some("https://www.google.com/maps/search/{{{s}}}")
        );
    }
}
