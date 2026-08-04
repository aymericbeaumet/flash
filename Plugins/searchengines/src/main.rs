use std::time::Duration;

use flash_plugin::{run, run_command, Candidate, CommandRequest, CommandResponse, Context};

// Sorted `BANGS: &[(&str, &str)]` generated from bangs.tsv at build time.
include!(concat!(env!("OUT_DIR"), "/bangs_generated.rs"));

const SOURCE_ID: &str = "plugin:searchengines";

struct SearchEngines;

flash_plugin::plugin!(SearchEngines);

impl FlashPlugin for SearchEngines {
    /// Publish every BANGS entry as a kind="bang" candidate so the host
    /// flashlight can show them as suggestion rows (with proper prefix
    /// ranking via `CandidateFinder.fieldScoreNormalized`). Without
    /// this, only aiproviders' explicit-token bangs surface as
    /// candidates and a typed `!goo` couldn't surface `!google` —
    /// dispatch worked via the catch-all but the user saw no prefix
    /// match. Catch-all routing still handles unknown tokens at submit
    /// time; this is purely about visibility.
    async fn on_start(&self, ctx: Context) {
        let candidates: Vec<Candidate> = BANGS
            .iter()
            .map(|(token, _)| {
                Candidate::new(format!("!{token}"))
                    .kind("bang")
                    .source_id(SOURCE_ID)
                    .source("searchengines.bangs")
                    .subtitle("search engine bang")
                    .payload(token.to_string())
            })
            .collect();
        ctx.set_locations(SOURCE_ID, candidates);
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        // The bang the user typed (`!r` → `r`) arrives as the subcommand; the
        // rest of the flashlight line is the query. There is no `:` command:
        // this plugin is reached only through the catch-all shebang provider.
        let bang = command.subcommand.to_ascii_lowercase();
        let Some(template) = lookup(&bang) else {
            return CommandResponse::error(format!("unknown bang: !{bang}"));
        };
        let url = template.replace("{{{s}}}", &percent_encode(&command.query()));
        run_command(
            &ctx,
            &["/usr/bin/open".to_string(), url],
            Duration::from_secs(10),
        )
        .await
        .into_command()
    }
}

/// The URL template for `bang`, or `None` when no bang matches.
fn lookup(bang: &str) -> Option<&'static str> {
    BANGS
        .binary_search_by(|&(trigger, _)| trigger.cmp(bang))
        .ok()
        .map(|index| BANGS[index].1)
}

/// Percent-encode a query for use in a URL query component. Encodes every
/// byte that is not an unreserved character (RFC 3986).
fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for &byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn main() {
    run(SearchEngines);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn includes_googlemaps_bang() {
        assert_eq!(
            lookup("googlemaps"),
            Some("https://www.google.com/maps/search/{{{s}}}")
        );
    }

    #[test]
    fn bang_query_builds_a_search_url_the_same_way_for_every_engine() {
        // `!g paris weather` opens Google searching "paris weather"; the
        // {{{s}}} substitution is identical for every search engine.
        let cases = [
            (
                "g",
                "paris weather",
                "https://www.google.com/search?q=paris%20weather",
            ),
            (
                "ddg",
                "paris weather",
                "https://duckduckgo.com/?q=paris%20weather",
            ),
            (
                "b",
                "paris weather",
                "https://www.bing.com/search?q=paris%20weather",
            ),
        ];
        for (bang, query, expected) in cases {
            let template = lookup(bang).unwrap_or_else(|| panic!("bang !{bang} should exist"));
            let url = template.replace("{{{s}}}", &percent_encode(query));
            assert_eq!(url, expected, "bang !{bang}");
        }
    }
}
