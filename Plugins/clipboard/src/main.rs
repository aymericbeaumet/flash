use std::sync::Mutex;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, Context, Plugin};

const SOURCE_ID: &str = "plugin.clipboard";
const HISTORY_CAP: usize = 50;
const PREVIEW_CHARS: usize = 80;

struct Clipboard {
    history: Mutex<Vec<String>>,
}

impl Plugin for Clipboard {
    async fn on_start(&self, ctx: Context) {
        {
            let mut hist = self.history.lock().unwrap();
            *hist = load(&ctx);
        }
        emit(&ctx, &self.snapshot());
    }

    // The core owns the pasteboard watch (it reads NSPasteboard's changeCount
    // in-process — macOS exposes no change notification) and pushes new text
    // here as `clipboard.changed`. The plugin never polls `pbpaste`.
    async fn on_event(&self, ctx: Context, name: String, payload: Value) {
        match name.as_str() {
            "flash.started" => emit(&ctx, &self.snapshot()),
            "clipboard.changed" => {
                let text = str_field(&payload, "text").to_string();
                if text.is_empty() {
                    return;
                }
                let changed = {
                    let mut hist = self.history.lock().unwrap();
                    if hist.first().map(String::as_str) == Some(text.as_str()) {
                        false
                    } else {
                        hist.retain(|entry| entry != &text);
                        hist.insert(0, text);
                        hist.truncate(HISTORY_CAP);
                        true
                    }
                };
                if changed {
                    let snapshot = self.snapshot();
                    persist(&ctx, &snapshot);
                    emit(&ctx, &snapshot);
                }
            }
            _ => {}
        }
    }

    async fn handle(&self, _ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        // `:copy` / `:paste` are top-level commands the host synthesizes as
        // ⌘C / ⌘V against the focused app; the plugin only advertises them so
        // they appear in the command catalog. Accept as no-ops.
        match str_field(&params, "command") {
            "copy" | "paste" => json!({ "ok": true }),
            other => json!({ "ok": false, "error": format!("unknown command: {other}") }),
        }
    }
}

impl Clipboard {
    fn snapshot(&self) -> Vec<String> {
        self.history.lock().unwrap().clone()
    }
}

fn emit(ctx: &Context, history: &[String]) {
    let candidates: Vec<Value> = history
        .iter()
        .map(|text| {
            json!({
                "kind": "clipboard",
                "source_id": SOURCE_ID,
                "source": "clipboard",
                "name": preview(text),
                "subtitle": "Clipboard",
                "payload": text,
            })
        })
        .collect();
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

fn preview(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or("").trim();
    let collapsed = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= PREVIEW_CHARS {
        return collapsed;
    }
    let head: String = collapsed.chars().take(PREVIEW_CHARS - 1).collect();
    format!("{head}…")
}

fn history_path(ctx: &Context) -> std::path::PathBuf {
    ctx.share_dir().join("history.json")
}

fn load(ctx: &Context) -> Vec<String> {
    let Ok(raw) = std::fs::read_to_string(history_path(ctx)) else {
        return Vec::new();
    };
    flash_plugin::serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default()
}

fn persist(ctx: &Context, history: &[String]) {
    if let Ok(raw) = flash_plugin::serde_json::to_string(history) {
        let _ = std::fs::write(history_path(ctx), raw);
    }
}

fn main() {
    run(Clipboard {
        history: Mutex::new(Vec::new()),
    });
}
