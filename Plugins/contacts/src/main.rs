use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{applescript_quote, parse_payload, run, str_field, Context, Plugin};

const SOURCE_ID: &str = "plugin.contacts";

const LIST_SCRIPT: &str = r#"
on safeName(p)
  try
    set n to name of p
    if n is missing value then return ""
    return n
  on error
    return ""
  end try
end safeName

tell application "Contacts"
  if not (running) then return ""
  set acc to {}
  repeat with p in people
    set n to my safeName(p)
    if n is not "" then set end of acc to n
  end repeat
  set AppleScript's text item delimiters to linefeed
  return acc as text
end tell
"#;

fn select_script(name: &str) -> String {
    format!(
        "
tell application \"Contacts\"
  activate
  set candidates to every person whose name is {}
  if (count of candidates) > 0 then
    set the selection to (item 1 of candidates)
  end if
end tell
",
        applescript_quote(name)
    )
}

struct Contacts;

impl Plugin for Contacts {
    async fn on_start(&self, ctx: Context) {
        emit_candidates(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, name: String, _payload: Value) {
        if matches!(
            name.as_str(),
            "flash.started" | "apps.launched" | "config.changed"
        ) {
            emit_candidates(&ctx).await;
        }
    }

    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        match method.as_str() {
            "resolveCandidate" => resolve_candidate(&ctx, &params).await,
            "command.invoke" => invoke(&ctx, &params).await,
            other => json!({ "ok": false, "error": format!("unknown method: {other}") }),
        }
    }
}

async fn emit_candidates(ctx: &Context) {
    let result = ctx
        .run_osascript(LIST_SCRIPT, Duration::from_secs(30))
        .await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[contacts] list failed: {}", result.stderr),
        );
        return;
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in result.stdout.lines() {
        let name = line.trim();
        if name.is_empty() || !seen.insert(name.to_string()) {
            continue;
        }
        candidates.push(json!({
            "kind": "contact",
            "source_id": SOURCE_ID,
            "source": "contacts",
            "name": name,
            "subtitle": "Contact",
            "payload": json!({ "contact": name }).to_string(),
        }));
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

async fn resolve_candidate(ctx: &Context, params: &Value) -> Value {
    let candidate = params
        .get("candidate")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let payload = parse_payload(&candidate);
    let name = payload
        .get("contact")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| str_field(&candidate, "name"));
    if name.is_empty() {
        return json!({ "did_resolve": false });
    }
    let result = ctx
        .run_osascript(&select_script(name), Duration::from_secs(10))
        .await;
    json!({ "did_resolve": result.ok })
}

async fn invoke(ctx: &Context, params: &Value) -> Value {
    match str_field(params, "subcommand") {
        "open" => ctx
            .run_cli(
                &[
                    "/usr/bin/open".into(),
                    "-b".into(),
                    "com.apple.AddressBook".into(),
                ],
                Duration::from_secs(10),
            )
            .await
            .value(),
        "refresh" => {
            emit_candidates(ctx).await;
            json!({ "ok": true, "stdout": "contacts refreshed", "stderr": "", "status": 0 })
        }
        other => json!({ "ok": false, "error": format!("unknown subcommand: {other}") }),
    }
}

fn main() {
    run(Contacts);
}
