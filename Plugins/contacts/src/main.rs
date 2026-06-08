use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, Context, Plugin};

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

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
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
    let argv = vec![
        "/usr/bin/osascript".to_string(),
        "-e".to_string(),
        LIST_SCRIPT.to_string(),
    ];
    let result = ctx.run_cli(&argv, Duration::from_secs(30)).await;
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
    ctx.emit.notify(
        "snapshot.updated",
        json!({ "targets": [], "candidates": candidates, "source_id": SOURCE_ID }),
    );
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
    let argv = vec![
        "/usr/bin/osascript".to_string(),
        "-e".to_string(),
        select_script(name),
    ];
    let result = ctx.run_cli(&argv, Duration::from_secs(10)).await;
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

fn parse_payload(candidate: &Value) -> Value {
    match candidate.get("payload") {
        Some(Value::String(raw)) => {
            flash_plugin::serde_json::from_str(raw).unwrap_or_else(|_| json!({}))
        }
        Some(value @ Value::Object(_)) => value.clone(),
        _ => json!({}),
    }
}

fn main() {
    run(Contacts);
}
