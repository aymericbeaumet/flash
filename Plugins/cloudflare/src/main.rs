use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

/// Generic command plugin: every subcommand is described entirely by its
/// manifest entry. `_url` opens a link (with optional `%s` query
/// substitution); `_cmd` runs a CLI, appending the user's args and surfacing
/// stdout as a toast. The Rust code holds no per-command knowledge.
struct CliPlugin;

impl Plugin for CliPlugin {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let args = string_list(&params, "args");

        let url = str_field(&params, "_url");
        if !url.is_empty() {
            let target = if url.contains("%s") {
                let query = args.join(" ");
                if query.trim().is_empty() {
                    return json!({ "ok": false, "error": "missing query" });
                }
                url.replace("%s", &percent_encode(query.trim()))
            } else {
                url.to_string()
            };
            return ctx
                .run_cli(
                    &["/usr/bin/open".to_string(), target],
                    Duration::from_secs(10),
                )
                .await
                .value();
        }

        let cmd = str_field(&params, "_cmd");
        if cmd.is_empty() {
            let sub = str_field(&params, "subcommand");
            return json!({ "ok": false, "error": format!("subcommand has no _url or _cmd: {sub}") });
        }
        let mut argv: Vec<String> = cmd.split_whitespace().map(str::to_string).collect();
        argv.extend(args);
        let result = ctx.run_cli(&argv, Duration::from_secs(30)).await;
        if result.ok {
            let out = if result.stdout.trim().is_empty() {
                "ok".to_string()
            } else {
                result.stdout.trim().to_string()
            };
            json!({ "ok": true, "stdout": out })
        } else {
            let err = if result.stderr.trim().is_empty() {
                format!("command failed (status {})", result.status)
            } else {
                result.stderr.trim().to_string()
            };
            json!({ "ok": false, "error": err })
        }
    }
}

/// Percent-encode a query for a URL component (RFC 3986 unreserved set).
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
    run(CliPlugin);
}
