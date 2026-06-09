use std::time::Duration;

use flash_plugin::{run, CommandResponse, Context, Plugin, Request, Response};

struct Web;

impl Plugin for Web {
    async fn handle(&self, ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        // The URL template lives in the manifest as the `_url` field of the
        // matched subcommand, forwarded here by the host. The plugin holds no
        // engine table of its own — add engines by editing manifest.json.
        let template = cmd.meta("_url").unwrap_or("");
        if template.is_empty() {
            return CommandResponse::error(format!("unknown engine: {}", cmd.subcommand)).into();
        }
        let query = cmd.query();
        if query.is_empty() {
            return CommandResponse::error("empty query").into();
        }
        let url = template.replace("%s", &percent_encode(&query));
        ctx.run_cli(&["/usr/bin/open".to_string(), url], Duration::from_secs(10))
            .await
            .into()
    }
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
    run(Web);
}
