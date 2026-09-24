use std::fs::Permissions;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;

use flash_plugin::{run, CommandRequest, Context, Event, PerformResponse};
use tokio::io::AsyncWriteExt;

const HISTORY_FILE: &str = "history.json";
const HISTORY_CAP: usize = 50;
const PREVIEW_CHARS: usize = 80;
/// Entries above this size are dropped at capture: a multi-megabyte copy
/// would bloat the 50-entry state file and the `:clipboard` RPC payload for
/// no practical paste-history value.
const MAX_ENTRY_BYTES: usize = 128 * 1024;
/// History holds whatever the user copied, so its store is private to them.
const STORE_DIR_MODE: u32 = 0o700;
const STORE_FILE_MODE: u32 = 0o600;

struct Clipboard {
    history: Mutex<Vec<String>>,
}

flash_plugin::plugin!(Clipboard);

impl FlashPlugin for Clipboard {
    async fn on_start(&self, ctx: Context) {
        // Enforce the store's modes now, not only on the next capture, so an
        // idle history never sits readable by other users.
        restrict_store(&ctx.share_dir(), HISTORY_FILE).await;
        let loaded = read_state(&ctx, HISTORY_FILE).await.unwrap_or_default();
        if let Ok(mut hist) = self.history.lock() {
            *hist = loaded;
        }
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
            let Ok(mut hist) = self.history.lock() else {
                return;
            };
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

    async fn on_command(&self, _ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.command.as_str() {
            // `:clipboard` opens the host's dedicated history modal. The plugin
            // can't drive macOS UI, so it just hands back the full history
            // (preview + value per entry) as JSON; the host renders the list
            // and pastes the chosen `value`.
            "clipboard" => self.history_response(),
            // `:copy` / `:paste` are top-level commands the host synthesizes as
            // ⌘C / ⌘V against the focused app; the plugin only advertises them
            // so they appear in the command catalog. Accept as no-ops.
            "copy" | "paste" => PerformResponse::ok(),
            other => PerformResponse::fail(format!("unknown command: {other}")),
        }
    }
}

impl Clipboard {
    /// The full history as a JSON array of `{preview, value}`, most-recent
    /// first — the payload the host's `:clipboard` modal renders. `preview`
    /// is the one-line label; `value` is the full text pasted on selection.
    fn history_response(&self) -> PerformResponse {
        let Ok(hist) = self.history.lock() else {
            return PerformResponse::fail("clipboard history unavailable");
        };
        let entries: Vec<HistoryEntry> = hist
            .iter()
            .map(|text| HistoryEntry {
                preview: preview(text),
                value: text.clone(),
            })
            .collect();
        match serde_json::to_string(&entries) {
            Ok(json) => PerformResponse::ok().message(json),
            Err(err) => PerformResponse::fail(format!("encode history: {err}")),
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
    match serde_json::to_vec(value) {
        Ok(raw) => write_private(&ctx.share_dir(), name, &raw).await.is_ok(),
        Err(_) => false,
    }
}

/// Replace `dir/name` through a fresh owner-only temporary file, inside a
/// directory only the owner can list, so no reader ever sees a wider mode or
/// a torn write.
async fn write_private(dir: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    tokio::fs::create_dir_all(dir).await?;
    tokio::fs::set_permissions(dir, Permissions::from_mode(STORE_DIR_MODE)).await?;
    let temporary = dir.join(format!("{name}.tmp-{}", std::process::id()));
    let written = async {
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(STORE_FILE_MODE)
            .open(&temporary)
            .await?;
        // `mode` applies only on creation; a leftover temporary keeps its own.
        file.set_permissions(Permissions::from_mode(STORE_FILE_MODE))
            .await?;
        file.write_all(bytes).await?;
        file.flush().await?;
        drop(file);
        tokio::fs::rename(&temporary, dir.join(name)).await
    }
    .await;
    if written.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
    }
    written
}

async fn restrict_store(dir: &Path, name: &str) {
    let _ = tokio::fs::set_permissions(dir, Permissions::from_mode(STORE_DIR_MODE)).await;
    let _ =
        tokio::fs::set_permissions(dir.join(name), Permissions::from_mode(STORE_FILE_MODE)).await;
}

fn main() {
    run(Clipboard {
        history: Mutex::new(Vec::new()),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn mode(path: &Path) -> u32 {
        tokio::fs::metadata(path)
            .await
            .unwrap()
            .permissions()
            .mode()
            & 0o777
    }

    #[tokio::test]
    async fn history_store_is_private_to_the_user() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        let dir = ctx.share_dir();
        let file = dir.join(HISTORY_FILE);

        assert!(write_state(&ctx, HISTORY_FILE, &vec!["secret".to_string()]).await);
        assert_eq!(mode(&dir).await, 0o700);
        assert_eq!(mode(&file).await, 0o600);
        assert_eq!(
            read_state::<Vec<String>>(&ctx, HISTORY_FILE).await,
            Some(vec!["secret".to_string()])
        );
        let mut entries = tokio::fs::read_dir(&dir).await.unwrap();
        assert_eq!(entries.next_entry().await.unwrap().unwrap().path(), file);
        assert!(entries.next_entry().await.unwrap().is_none());

        for (path, loose) in [(&dir, 0o755), (&file, 0o644)] {
            tokio::fs::set_permissions(path, Permissions::from_mode(loose))
                .await
                .unwrap();
        }
        restrict_store(&dir, HISTORY_FILE).await;
        assert_eq!(mode(&dir).await, 0o700);
        assert_eq!(mode(&file).await, 0o600);

        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }
}
