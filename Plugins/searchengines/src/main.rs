use std::time::Duration;

use flash_plugin::{run, CommandResponse, Context, Plugin, Request, Response};

// Sorted `BANGS: &[(&str, &str)]` generated from bangs.tsv at build time.
include!(concat!(env!("OUT_DIR"), "/bangs_generated.rs"));

struct SearchEngines;

impl Plugin for SearchEngines {
    async fn handle(&self, ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        // The bang the user typed (`!r` → `r`) arrives as the subcommand; the
        // rest of the flashlight line is the query. There is no `:` command:
        // this plugin is reached only through the catch-all shebang provider.
        let bang = cmd.subcommand.to_ascii_lowercase();
        let Some(template) = lookup(&bang) else {
            return CommandResponse::error(format!("unknown bang: !{bang}")).into();
        };
        let url = template.replace("{{{s}}}", &percent_encode(&cmd.query()));
        ctx.run_cli(&["/usr/bin/open".to_string(), url], Duration::from_secs(10))
            .await
            .into()
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
