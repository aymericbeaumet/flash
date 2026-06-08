use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Web;

impl Plugin for Web {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        // The URL template lives in the manifest as the `_url` field of the
        // matched subcommand, forwarded here by the host. The plugin holds no
        // engine table of its own — add engines by editing manifest.json.
        let template = str_field(&params, "_url");
        if template.is_empty() {
            let engine = str_field(&params, "subcommand");
            return json!({ "ok": false, "error": format!("unknown engine: {engine}") });
        }
        let query = string_list(&params, "args").join(" ");
        if query.trim().is_empty() {
            return json!({ "ok": false, "error": "empty query" });
        }
        let url = template.replace("%s", &percent_encode(query.trim()));
        ctx.run_cli(&["/usr/bin/open".to_string(), url], Duration::from_secs(10))
            .await
            .value()
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
