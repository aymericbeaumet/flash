use std::sync::Mutex;

use flash_plugin::{run, CommandRequest, CommandResponse, Context, Event};

const HISTORY_FILE: &str = "history.json";
const HISTORY_CAP: usize = 50;
const PREVIEW_CHARS: usize = 80;
/// Entries above this size are dropped at capture: a multi-megabyte copy
/// would bloat the 50-entry state file and the `:clipboard` RPC payload for
/// no practical paste-history value.
const MAX_ENTRY_BYTES: usize = 128 * 1024;

struct Clipboard {
    history: Mutex<Vec<String>>,
}

flash_plugin::plugin!(Clipboard);

impl FlashPlugin for Clipboard {
    async fn on_start(&self, ctx: Context) {
        let loaded = read_state(&ctx, HISTORY_FILE).await.unwrap_or_default();
        *self.history.lock().unwrap() = loaded;
    }

    // The core owns the pasteboard watch (it reads NSPasteboard's changeCount
    // in-process — macOS exposes no change notification) and pushes new text
    // here as `clipboard.changed`. The plugin never polls `pbpaste`. History
    // is served only through the `:clipboard` command — it is deliberately
    // not a flashlight candidate source.
    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name != "core:clipboard.changed" {
            return;
        }
        let text = event.text.unwrap_or_default();
        if text.is_empty() || text.len() > MAX_ENTRY_BYTES {
            return;
        }
        let snapshot = {
            let mut hist = self.history.lock().unwrap();
            if hist.first().map(String::as_str) == Some(text.as_str()) {
                None
            } else {
                hist.retain(|entry| entry != &text);
                hist.insert(0, text);
                hist.truncate(HISTORY_CAP);
                Some(hist.clone())
            }
        };
        if let Some(snapshot) = snapshot {
            write_state(&ctx, HISTORY_FILE, &snapshot).await;
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

fn preview(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or("").trim();
    let collapsed = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= PREVIEW_CHARS {
        return collapsed;
    }
    let head: String = collapsed.chars().take(PREVIEW_CHARS - 1).collect();
    format!("{head}…")
}

async fn read_state<T: serde::de::DeserializeOwned>(ctx: &Context, name: &str) -> Option<T> {
    let raw = tokio::fs::read_to_string(ctx.share_dir().join(name))
        .await
        .ok()?;
    serde_json::from_str(&raw).ok()
}

async fn write_state<T: serde::Serialize>(ctx: &Context, name: &str, value: &T) -> bool {
    match serde_json::to_string(value) {
        Ok(raw) => tokio::fs::write(ctx.share_dir().join(name), raw)
            .await
            .is_ok(),
        Err(_) => false,
    }
}

fn main() {
    run(Clipboard {
        history: Mutex::new(Vec::new()),
    });
}
