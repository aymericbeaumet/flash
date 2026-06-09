use std::sync::Mutex;

use flash_plugin::{run, Candidate, CommandResponse, Context, Event, Plugin, Request, Response};

const SOURCE_ID: &str = "plugin.clipboard";
const HISTORY_FILE: &str = "history.json";
const HISTORY_CAP: usize = 50;
const PREVIEW_CHARS: usize = 80;

struct Clipboard {
    history: Mutex<Vec<String>>,
}

impl Plugin for Clipboard {
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
            "flash.started" => emit(&ctx, &self.snapshot()),
            "clipboard.changed" => {
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

    async fn handle(&self, _ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        // `:copy` / `:paste` are top-level commands the host synthesizes as
        // ⌘C / ⌘V against the focused app; the plugin only advertises them so
        // they appear in the command catalog. Accept as no-ops.
        match cmd.command.as_str() {
            "copy" | "paste" => CommandResponse::ok().into(),
            other => CommandResponse::error(format!("unknown command: {other}")).into(),
        }
    }
}

impl Clipboard {
    fn snapshot(&self) -> Vec<String> {
        self.history.lock().unwrap().clone()
    }
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
