use std::sync::Mutex;

use flash_plugin::{run, Candidate, CommandRequest, CommandResponse, Context, Event};

const SOURCE_ID: &str = "plugin:clipboard";
const HISTORY_FILE: &str = "history.json";
const HISTORY_CAP: usize = 50;
const PREVIEW_CHARS: usize = 80;

struct Clipboard {
    history: Mutex<Vec<String>>,
}

flash_plugin::plugin!(Clipboard);

impl FlashPlugin for Clipboard {
    async fn on_start(&self, ctx: Context) {
        {
            let mut hist = self.history.lock().unwrap();
            *hist = ctx.read_state(HISTORY_FILE).unwrap_or_default();
        }
        emit(&ctx, &self.snapshot());
    }

    // The core owns the pasteboard watch (it reads NSPasteboard's changeCount
    // in-process — macOS exposes no change notification) and pushes new text
    // here as `clipboard.changed`. The plugin never polls `pbpaste`.
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:flash.started" => emit(&ctx, &self.snapshot()),
            "core:clipboard.changed" => {
                let text = event.text.unwrap_or_default();
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
                    ctx.write_state(HISTORY_FILE, &snapshot);
                    emit(&ctx, &snapshot);
                }
            }
            _ => {}
        }
    }

    async fn on_command(&self, _ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.command.as_str() {
            // `:clipboard` opens the host's dedicated history modal. The plugin
            // can't drive macOS UI, so it just hands back the full history
            // (preview + value per entry) as JSON; the host renders the list
            // and pastes the chosen `value`.
            "clipboard" => self.history_response(),
            // `:copy` / `:paste` are top-level commands the host synthesizes as
            // ⌘C / ⌘V against the focused app; the plugin only advertises them
            // so they appear in the command catalog. Accept as no-ops.
            "copy" | "paste" => CommandResponse::ok(),
            other => CommandResponse::error(format!("unknown command: {other}")),
        }
    }
}

impl Clipboard {
    fn snapshot(&self) -> Vec<String> {
        self.history.lock().unwrap().clone()
    }

    /// The full history as a JSON array of `{preview, value}`, most-recent
    /// first — the payload the host's `:clipboard` modal renders. `preview`
    /// is the one-line label; `value` is the full text pasted on selection.
    fn history_response(&self) -> CommandResponse {
        let entries: Vec<HistoryEntry> = self
            .history
            .lock()
            .unwrap()
            .iter()
            .map(|text| HistoryEntry {
                preview: preview(text),
                value: text.clone(),
            })
            .collect();
        match serde_json::to_string(&entries) {
            Ok(json) => CommandResponse {
                ok: true,
                stdout: Some(json),
                ..Default::default()
            },
            Err(err) => CommandResponse::error(format!("encode history: {err}")),
        }
    }
}

#[derive(serde::Serialize)]
struct HistoryEntry {
    preview: String,
    value: String,
}

fn emit(ctx: &Context, history: &[String]) {
    let candidates: Vec<Candidate> = history
        .iter()
        .map(|text| {
            Candidate::new(preview(text))
                .kind("clipboard")
                .source_id(SOURCE_ID)
                .source("clipboard")
                .subtitle("Clipboard")
                .payload(text.clone())
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

fn main() {
    run(Clipboard {
        history: Mutex::new(Vec::new()),
    });
}
