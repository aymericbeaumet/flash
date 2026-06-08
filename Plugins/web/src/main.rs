use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Web;

impl Plugin for Web {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let engine = str_field(&params, "subcommand");
        let Some(template) = template_for(engine) else {
            return json!({ "ok": false, "error": format!("unknown engine: {engine}") });
        };
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

fn template_for(engine: &str) -> Option<&'static str> {
    Some(match engine {
        "google" => "https://www.google.com/search?q=%s",
        "ddg" => "https://duckduckgo.com/?q=%s",
        "gh" => "https://github.com/search?q=%s&type=repositories",
        "npm" => "https://www.npmjs.com/search?q=%s",
        "mdn" => "https://developer.mozilla.org/en-US/search?q=%s",
        "so" => "https://stackoverflow.com/search?q=%s",
        "yt" => "https://www.youtube.com/results?search_query=%s",
        _ => return None,
    })
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
