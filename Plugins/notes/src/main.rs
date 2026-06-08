use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, Context, Plugin};

const SOURCE_ID: &str = "plugin.notes";

const LIST_SCRIPT: &str = r#"
tell application "Notes"
  if not (running) then return ""
  set output to {}
  repeat with acc in accounts
    try
      repeat with n in notes of acc
        set the end of output to ((id of n as text) & tab & (name of n as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"#;

fn select_script(note_id: &str) -> String {
    format!(
        "
tell application \"Notes\"
  activate
  try
    show note id {}
  end try
end tell
",
        applescript_quote(note_id)
    )
}

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

struct Notes;

impl Plugin for Notes {
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
        ctx.log("warn", &format!("[notes] list failed: {}", result.stderr));
        return;
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in result.stdout.lines() {
        let line = line.trim();
        let Some((note_id, title)) = line.split_once('\t') else {
            continue;
        };
        let note_id = note_id.trim();
        let title = title.trim();
        if note_id.is_empty() || title.is_empty() || !seen.insert(note_id.to_string()) {
            continue;
        }
        candidates.push(json!({
            "kind": "note",
            "source_id": SOURCE_ID,
            "source": "notes",
            "name": title,
            "subtitle": "Note",
            "payload": json!({ "id": note_id, "title": title }).to_string(),
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
    let note_id = payload.get("id").and_then(Value::as_str).unwrap_or("");
    if note_id.is_empty() {
        return json!({ "did_resolve": false });
    }
    let argv = vec![
        "/usr/bin/osascript".to_string(),
        "-e".to_string(),
        select_script(note_id),
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
                    "com.apple.Notes".into(),
                ],
                Duration::from_secs(10),
            )
            .await
            .value(),
        "refresh" => {
            emit_candidates(ctx).await;
            json!({ "ok": true, "stdout": "notes refreshed", "stderr": "", "status": 0 })
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
    run(Notes);
}
