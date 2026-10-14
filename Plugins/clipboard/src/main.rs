use std::fs::Permissions;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use flash_plugin::{CommandRequest, Context, Event, PerformResponse, run};
use tokio::io::AsyncWriteExt;

const HISTORY_FILE: &str = "history.json";
/// `[plugin.clipboard] history_size`: entries kept, newest first.
const DEFAULT_HISTORY_SIZE: usize = 1000;
const MAX_HISTORY_SIZE: u64 = 10_000;
/// The shown history stays well inside one protocol frame (10 MiB).
const HISTORY_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const PREVIEW_CHARS: usize = 80;
/// Plain text above this size is dropped. A rich copy keeps its image or
/// HTML and truncates only the plain fallback, which the host already capped.
const MAX_ENTRY_BYTES: usize = 128 * 1024;
const MAX_HTML_BYTES: usize = 64 * 1024;
const MAX_FILES: usize = 20;
/// History holds whatever the user copied, so its store is private to them.
const STORE_DIR_MODE: u32 = 0o700;
const STORE_FILE_MODE: u32 = 0o600;

struct Clipboard {
    history: Mutex<Vec<StoredEntry>>,
    /// How many entries the history keeps (`history_size`).
    capacity: AtomicUsize,
}

/// `history_size`: an integer in 1..=10000; 1000 when unset.
fn history_size(value: Option<serde_json::Value>) -> Result<usize, &'static str> {
    match value {
        None => Ok(DEFAULT_HISTORY_SIZE),
        Some(value) => value
            .as_u64()
            .filter(|size| (1..=MAX_HISTORY_SIZE).contains(size))
            .map(|size| size as usize)
            .ok_or("history_size must be an integer in 1..10000"),
    }
}

flash_plugin::plugin!(Clipboard);

impl FlashPlugin for Clipboard {
    async fn on_start(&self, ctx: Context) {
        // Enforce the store's modes now, not only on the next capture, so an
        // idle history never sits readable by other users.
        restrict_store(&ctx.share_dir(), HISTORY_FILE).await;
        let capacity = history_size(ctx.config_json("history_size")).unwrap_or_else(|error| {
            ctx.log(
                "warn",
                &format!("[clipboard] invalid configuration: {error}"),
            );
            DEFAULT_HISTORY_SIZE
        });
        self.capacity.store(capacity, Ordering::Relaxed);
        let (mut loaded, migrated) = load_history(&ctx).await;
        // A smaller history_size drops the oldest entries, and their images.
        let dropped: Vec<StoredEntry> = loaded.drain(capacity.min(loaded.len())..).collect();
        if let Ok(mut hist) = self.history.lock() {
            *hist = loaded.clone();
        }
        if migrated || !dropped.is_empty() {
            write_state(&ctx, HISTORY_FILE, &loaded).await;
        }
        for entry in dropped {
            remove_image_files(&ctx, &entry.id).await;
        }
    }

    // The core owns the pasteboard watch and pushes one settled copy here.
    // Image bytes are already a file under `share/images`; this event only
    // carries the metadata. The plugin never polls `pbpaste`.
    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name != "core:clipboard.changed" {
            return;
        }
        let Some(mut incoming) = parse_entry(&event) else {
            return;
        };
        if let Some(mime) = incoming.mime.clone() {
            match image_path(&ctx, &incoming.id, &mime) {
                Some(path) if file_exists(&path).await => {
                    let _ =
                        tokio::fs::set_permissions(&path, Permissions::from_mode(STORE_FILE_MODE))
                            .await;
                    if let Some(dir) = path.parent() {
                        let _ =
                            tokio::fs::set_permissions(dir, Permissions::from_mode(STORE_DIR_MODE))
                                .await;
                    }
                }
                _ if incoming.kind == "image" => return,
                _ => {
                    incoming.mime = None;
                    incoming.sha256 = None;
                }
            }
        }
        let Some((snapshot, drop_ids)) = self.record(incoming) else {
            return;
        };
        write_state(&ctx, HISTORY_FILE, &snapshot).await;
        for id in drop_ids {
            remove_image_files(&ctx, &id).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match (command.command.as_str(), command.subcommand.as_str()) {
            // `:clipboard show` hands the history to the host as JSON. Image
            // bytes stay on disk; `mime` means the host can read the file.
            ("clipboard", "show") => self.history_response(),
            ("clipboard", "delete") => self.delete(&ctx, &command.args).await,
            (other, _) => PerformResponse::fail(format!("unknown command: {other}")),
        }
    }
}

impl Clipboard {
    /// Move a duplicate to the front, keeping its original id and image file.
    /// The returned ids are files to remove: the duplicate's new file, and
    /// any entry that fell off the cap. Other image files stay, because the
    /// host may already have written the next copy's file.
    fn record(&self, incoming: StoredEntry) -> Option<(Vec<StoredEntry>, Vec<String>)> {
        let Ok(mut hist) = self.history.lock() else {
            return None;
        };
        let mut drop_ids = Vec::new();
        if let Some(kept) = hist
            .iter()
            .find(|entry| entry.same_payload(&incoming))
            .cloned()
        {
            if kept.id != incoming.id {
                drop_ids.push(incoming.id.clone());
            }
            hist.retain(|entry| !entry.same_payload(&incoming));
            hist.insert(0, kept);
        } else {
            let previous: Vec<String> = hist.iter().map(|entry| entry.id.clone()).collect();
            hist.retain(|entry| entry.id != incoming.id);
            hist.insert(0, incoming);
            hist.truncate(self.capacity.load(Ordering::Relaxed));
            for id in previous {
                if !hist.iter().any(|entry| entry.id == id) {
                    drop_ids.push(id);
                }
            }
        }
        Some((hist.clone(), drop_ids))
    }

    fn history_response(&self) -> PerformResponse {
        let Ok(hist) = self.history.lock() else {
            return PerformResponse::fail("clipboard history unavailable");
        };
        // Newest first while they fit the budget; the rest stay stored.
        let mut json = String::from("[");
        for entry in hist.iter() {
            let encoded = match serde_json::to_string(&HistoryEntry::from(entry)) {
                Ok(encoded) => encoded,
                Err(err) => return PerformResponse::fail(format!("encode history: {err}")),
            };
            if json.len() + encoded.len() + 2 > HISTORY_RESPONSE_BYTES {
                break;
            }
            if json.len() > 1 {
                json.push(',');
            }
            json.push_str(&encoded);
        }
        json.push(']');
        PerformResponse::ok().message(json)
    }

    async fn delete(&self, ctx: &Context, args: &[String]) -> PerformResponse {
        let Some(id) = arg_id(args) else {
            return PerformResponse::fail("invalid id");
        };
        let removed = {
            let Ok(mut hist) = self.history.lock() else {
                return PerformResponse::fail("clipboard history unavailable");
            };
            let Some(index) = hist.iter().position(|entry| entry.id == id) else {
                return PerformResponse::fail("not found");
            };
            hist.remove(index);
            hist.clone()
        };
        write_state(ctx, HISTORY_FILE, &removed).await;
        remove_image_files(ctx, &id).await;
        PerformResponse::ok()
    }
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
struct StoredEntry {
    id: String,
    kind: String,
    text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    html: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mime: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    files: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sha256: Option<String>,
}

impl StoredEntry {
    fn same_payload(&self, other: &Self) -> bool {
        self.kind == other.kind
            && self.text == other.text
            && self.html == other.html
            && self.files == other.files
            && self.sha256 == other.sha256
    }
}

#[derive(serde::Serialize)]
struct HistoryEntry {
    id: String,
    kind: String,
    preview: String,
    value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    html: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mime: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    files: Vec<String>,
}

impl From<&StoredEntry> for HistoryEntry {
    fn from(entry: &StoredEntry) -> Self {
        Self {
            id: entry.id.clone(),
            kind: entry.kind.clone(),
            preview: preview_of(entry),
            value: entry.text.clone(),
            html: entry.html.clone(),
            mime: entry.mime.clone(),
            files: entry.files.clone(),
        }
    }
}

fn preview_of(entry: &StoredEntry) -> String {
    match entry.kind.as_str() {
        "image" if entry.text.trim().is_empty() => match entry.mime.as_deref() {
            Some("image/png") => "PNG image".to_string(),
            Some("image/jpeg") => "JPEG image".to_string(),
            Some("image/gif") => "GIF image".to_string(),
            Some("image/webp") => "WebP image".to_string(),
            _ => "Image".to_string(),
        },
        "files" if entry.text.trim().is_empty() && entry.files.len() == 1 => {
            preview(&entry.files[0])
        }
        "files" if entry.text.trim().is_empty() => format!("{} files", entry.files.len()),
        "html" if entry.text.trim().is_empty() => "Formatted text".to_string(),
        _ => preview(&entry.text),
    }
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

fn parse_entry(event: &Event) -> Option<StoredEntry> {
    let id = event.id.as_deref().filter(|id| valid_id(id))?.to_string();
    let kind = event.kind.as_deref()?;
    let text = event.text.clone().unwrap_or_default();
    if text.len() > MAX_ENTRY_BYTES {
        return None;
    }
    let html = event.html.clone().filter(|html| !html.is_empty());
    if html
        .as_ref()
        .is_some_and(|html| html.len() > MAX_HTML_BYTES)
    {
        return None;
    }
    if event.files.len() > MAX_FILES || event.files.iter().any(String::is_empty) {
        return None;
    }
    let files = event.files.clone();
    match kind {
        "text" if !text.is_empty() => Some(StoredEntry {
            id,
            kind: "text".to_string(),
            text,
            html: None,
            mime: None,
            files: Vec::new(),
            sha256: None,
        }),
        "image" => {
            let mime = event
                .mime
                .as_deref()
                .filter(|mime| mime_ext(mime).is_some())?;
            let sha256 = event.sha256.as_deref().filter(|sha| valid_sha(sha))?;
            Some(StoredEntry {
                id,
                kind: "image".to_string(),
                text,
                html: None,
                mime: Some(mime.to_string()),
                files: Vec::new(),
                sha256: Some(sha256.to_string()),
            })
        }
        "html" => {
            let html = html?;
            Some(StoredEntry {
                id,
                kind: "html".to_string(),
                text,
                html: Some(html),
                mime: None,
                files: Vec::new(),
                sha256: None,
            })
        }
        "files" if !files.is_empty() => {
            let (mime, sha256) = match (event.mime.as_deref(), event.sha256.as_deref()) {
                (Some(mime), Some(sha)) if mime_ext(mime).is_some() && valid_sha(sha) => {
                    (Some(mime.to_string()), Some(sha.to_string()))
                }
                _ => (None, None),
            };
            Some(StoredEntry {
                id,
                kind: "files".to_string(),
                text,
                html: None,
                mime,
                files,
                sha256,
            })
        }
        _ => None,
    }
}

fn arg_id(args: &[String]) -> Option<String> {
    for arg in args {
        let id = arg.strip_prefix("id=").unwrap_or(arg);
        if valid_id(id) {
            return Some(id.to_string());
        }
    }
    None
}

fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_sha(sha: &str) -> bool {
    sha.len() == 64
        && sha
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn mime_ext(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/gif" => Some("gif"),
        "image/webp" => Some("webp"),
        _ => None,
    }
}

fn image_path(ctx: &Context, id: &str, mime: &str) -> Option<PathBuf> {
    let ext = mime_ext(mime)?;
    if !valid_id(id) {
        return None;
    }
    Some(ctx.share_dir().join("images").join(format!("{id}.{ext}")))
}

async fn file_exists(path: &Path) -> bool {
    tokio::fs::try_exists(path).await.unwrap_or(false)
}

async fn remove_image_files(ctx: &Context, id: &str) {
    if !valid_id(id) {
        return;
    }
    let dir = ctx.share_dir().join("images");
    for ext in ["png", "jpg", "gif", "webp"] {
        let _ = tokio::fs::remove_file(dir.join(format!("{id}.{ext}"))).await;
    }
}

/// `(entries, migrated)`. A previous install stored a JSON array of strings;
/// that file is rewritten once as structured entries. Anything else unreadable
/// stays on disk until the next capture replaces it.
async fn load_history(ctx: &Context) -> (Vec<StoredEntry>, bool) {
    let Ok(raw) = tokio::fs::read_to_string(ctx.share_dir().join(HISTORY_FILE)).await else {
        return (Vec::new(), false);
    };
    if let Ok(entries) = serde_json::from_str::<Vec<StoredEntry>>(&raw) {
        return (entries.into_iter().filter(valid_stored).collect(), false);
    }
    let Ok(texts) = serde_json::from_str::<Vec<String>>(&raw) else {
        return (Vec::new(), false);
    };
    let entries = texts
        .into_iter()
        .enumerate()
        .filter_map(|(index, text)| text_entry(index as u64, text))
        .collect();
    (entries, true)
}

fn text_entry(index: u64, text: String) -> Option<StoredEntry> {
    if text.is_empty() || text.len() > MAX_ENTRY_BYTES {
        return None;
    }
    Some(StoredEntry {
        id: format!(
            "{:016x}{:016x}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0),
            index
        ),
        kind: "text".to_string(),
        text,
        html: None,
        mime: None,
        files: Vec::new(),
        sha256: None,
    })
}

fn valid_stored(entry: &StoredEntry) -> bool {
    if !valid_id(&entry.id) || entry.text.len() > MAX_ENTRY_BYTES {
        return false;
    }
    if entry
        .html
        .as_ref()
        .is_some_and(|html| html.is_empty() || html.len() > MAX_HTML_BYTES)
    {
        return false;
    }
    if entry.files.len() > MAX_FILES || entry.files.iter().any(String::is_empty) {
        return false;
    }
    match entry.kind.as_str() {
        "text" => {
            !entry.text.is_empty()
                && entry.html.is_none()
                && entry.mime.is_none()
                && entry.files.is_empty()
        }
        "image" => {
            image_pair(&entry.mime, &entry.sha256) && entry.html.is_none() && entry.files.is_empty()
        }
        "html" => {
            entry.html.is_some()
                && entry.mime.is_none()
                && entry.files.is_empty()
                && entry.sha256.is_none()
        }
        "files" => {
            !entry.files.is_empty()
                && entry.html.is_none()
                && mime_pair_optional(&entry.mime, &entry.sha256)
        }
        _ => false,
    }
}

fn image_pair(mime: &Option<String>, sha: &Option<String>) -> bool {
    match (mime.as_deref(), sha.as_deref()) {
        (Some(mime), Some(sha)) => mime_ext(mime).is_some() && valid_sha(sha),
        _ => false,
    }
}

fn mime_pair_optional(mime: &Option<String>, sha: &Option<String>) -> bool {
    match (mime, sha) {
        (None, None) => true,
        (Some(_), Some(_)) => image_pair(mime, sha),
        _ => false,
    }
}

#[cfg(test)]
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
        capacity: AtomicUsize::new(DEFAULT_HISTORY_SIZE),
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

    fn plugin() -> Clipboard {
        Clipboard {
            history: Mutex::new(Vec::new()),
            capacity: AtomicUsize::new(DEFAULT_HISTORY_SIZE),
        }
    }

    fn id(byte: u8) -> String {
        format!("{byte:02x}").repeat(16)
    }

    fn sha() -> String {
        "ab".repeat(32)
    }

    fn changed(kind: &str, entry_id: &str) -> Event {
        Event {
            name: "core:clipboard.changed".into(),
            id: Some(entry_id.into()),
            kind: Some(kind.into()),
            text: Some(String::new()),
            ..Event::default()
        }
    }

    async fn show(plugin: &Clipboard, ctx: &Context) -> serde_json::Value {
        let response = plugin
            .on_command(
                ctx.clone(),
                CommandRequest {
                    command: "clipboard".into(),
                    subcommand: "show".into(),
                    ..CommandRequest::default()
                },
            )
            .await;
        assert!(response.is_ok());
        serde_json::from_str(response.toast_message().unwrap()).unwrap()
    }

    #[test]
    fn history_size_defaults_to_a_thousand_and_rejects_nonsense() {
        assert_eq!(history_size(None), Ok(1000));
        assert_eq!(history_size(Some(serde_json::json!(25))), Ok(25));
        assert_eq!(history_size(Some(serde_json::json!(10000))), Ok(10000));
        for bad in [
            serde_json::json!(0),
            serde_json::json!(10001),
            serde_json::json!(-3),
            serde_json::json!("100"),
            serde_json::json!(2.5),
        ] {
            assert!(history_size(Some(bad)).is_err());
        }
    }

    #[tokio::test]
    async fn the_history_keeps_the_configured_number_of_entries() {
        let harness = flash_plugin::testing::Harness::with_config(
            "clipboard",
            serde_json::json!({"history_size": 3}),
        );
        let ctx = harness.context();
        let clipboard = plugin();
        clipboard.on_start(ctx.clone()).await;
        for index in 0..5u8 {
            let mut event = changed("text", &id(index + 1));
            event.text = Some(format!("copy {index}"));
            clipboard.on_event(ctx.clone(), event).await;
        }
        let shown = show(&clipboard, &ctx).await;
        let values: Vec<&str> = shown
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["value"].as_str().unwrap())
            .collect();
        assert_eq!(values, ["copy 4", "copy 3", "copy 2"]);
        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }

    /// A long history of large copies would not fit one protocol frame: the
    /// newest entries are shown while they fit the budget, the rest stay
    /// stored.
    #[test]
    fn the_shown_history_stays_inside_its_byte_budget() {
        let clipboard = plugin();
        let big = "x".repeat(MAX_ENTRY_BYTES);
        {
            let mut hist = clipboard.history.lock().unwrap();
            for index in 0..120u64 {
                hist.push(text_entry(index, big.clone()).unwrap());
            }
        }
        let response = clipboard.history_response();
        let json = response.toast_message().unwrap();
        assert!(json.len() <= HISTORY_RESPONSE_BYTES, "{} bytes", json.len());
        let shown: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
        assert!(!shown.is_empty() && shown.len() < 120);
        assert_eq!(clipboard.history.lock().unwrap().len(), 120);
    }

    #[tokio::test]
    async fn history_store_is_private_to_the_user() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        let dir = ctx.share_dir();
        let file = dir.join(HISTORY_FILE);
        let stored = vec![StoredEntry {
            id: id(1),
            kind: "text".into(),
            text: "secret".into(),
            html: None,
            mime: None,
            files: Vec::new(),
            sha256: None,
        }];

        assert!(write_state(&ctx, HISTORY_FILE, &stored).await);
        assert_eq!(mode(&dir).await, 0o700);
        assert_eq!(mode(&file).await, 0o600);
        assert_eq!(
            read_state::<Vec<StoredEntry>>(&ctx, HISTORY_FILE).await,
            Some(stored)
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

    #[tokio::test]
    async fn a_string_array_history_is_rewritten_once() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        assert!(
            write_state(
                &ctx,
                HISTORY_FILE,
                &vec!["newer".to_string(), "older".to_string()]
            )
            .await
        );
        let clipboard = plugin();
        clipboard.on_start(ctx.clone()).await;
        let shown = show(&clipboard, &ctx).await;
        assert_eq!(shown[0]["value"], "newer");
        assert_eq!(shown[1]["value"], "older");
        assert_eq!(shown[0]["kind"], "text");
        assert_eq!(shown[0]["id"].as_str().unwrap().len(), 32);
        let stored = read_state::<Vec<StoredEntry>>(&ctx, HISTORY_FILE)
            .await
            .unwrap();
        assert_eq!(stored[0].text, "newer");
        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }

    #[tokio::test]
    async fn an_image_is_metadata_only_and_delete_removes_its_file() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        let clipboard = plugin();
        let entry_id = id(7);
        let path = ctx
            .share_dir()
            .join("images")
            .join(format!("{entry_id}.png"));
        tokio::fs::create_dir_all(path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&path, b"png-bytes").await.unwrap();
        let mut event = changed("image", &entry_id);
        event.mime = Some("image/png".into());
        event.sha256 = Some(sha());
        clipboard.on_event(ctx.clone(), event).await;

        let shown = show(&clipboard, &ctx).await;
        assert_eq!(shown[0]["id"], entry_id);
        assert_eq!(shown[0]["kind"], "image");
        assert_eq!(shown[0]["mime"], "image/png");
        assert_eq!(shown[0]["preview"], "PNG image");
        assert!(shown[0].get("sha256").is_none());
        assert!(!shown.to_string().contains("png-bytes"));
        assert!(path.exists());

        let deleted = clipboard
            .on_command(
                ctx.clone(),
                CommandRequest {
                    command: "clipboard".into(),
                    subcommand: "delete".into(),
                    args: vec![format!("id={entry_id}")],
                    ..CommandRequest::default()
                },
            )
            .await;
        assert!(deleted.is_ok());
        assert!(deleted.toast_message().is_none());
        assert!(!path.exists());
        assert!(show(&clipboard, &ctx).await.as_array().unwrap().is_empty());

        let missing = clipboard
            .on_command(
                ctx.clone(),
                CommandRequest {
                    command: "clipboard".into(),
                    subcommand: "delete".into(),
                    args: vec![entry_id],
                    ..CommandRequest::default()
                },
            )
            .await;
        assert!(!missing.is_ok());
        let traversal = clipboard
            .on_command(
                ctx.clone(),
                CommandRequest {
                    command: "clipboard".into(),
                    subcommand: "delete".into(),
                    args: vec!["id=../../etc/passwd".into()],
                    ..CommandRequest::default()
                },
            )
            .await;
        assert!(!traversal.is_ok());
        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }

    #[tokio::test]
    async fn a_duplicate_image_keeps_the_first_file() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        let clipboard = plugin();
        let first = id(1);
        let second = id(2);
        let dir = ctx.share_dir().join("images");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        tokio::fs::write(dir.join(format!("{first}.png")), b"one")
            .await
            .unwrap();
        let mut first_event = changed("image", &first);
        first_event.mime = Some("image/png".into());
        first_event.sha256 = Some(sha());
        clipboard.on_event(ctx.clone(), first_event).await;
        tokio::fs::write(dir.join(format!("{second}.png")), b"two")
            .await
            .unwrap();
        let mut second_event = changed("image", &second);
        second_event.mime = Some("image/png".into());
        second_event.sha256 = Some(sha());
        clipboard.on_event(ctx.clone(), second_event).await;
        let shown = show(&clipboard, &ctx).await;
        assert_eq!(shown.as_array().unwrap().len(), 1);
        assert_eq!(shown[0]["id"], first);
        assert!(dir.join(format!("{first}.png")).exists());
        assert!(!dir.join(format!("{second}.png")).exists());
        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }

    #[tokio::test]
    async fn html_and_files_round_trip_and_a_missing_image_file_is_dropped() {
        let harness = flash_plugin::testing::Harness::new("clipboard");
        let ctx = harness.context();
        let clipboard = plugin();
        let html_id = id(3);
        let mut html = changed("html", &html_id);
        html.text = Some("hello".into());
        html.html = Some("<b>hello</b>".into());
        clipboard.on_event(ctx.clone(), html).await;

        let files_id = id(4);
        let mut files = changed("files", &files_id);
        files.text = Some("/tmp/a.png".into());
        files.files = vec!["/tmp/a.png".into()];
        files.mime = Some("image/png".into());
        files.sha256 = Some(sha());
        clipboard.on_event(ctx.clone(), files).await;

        let shown = show(&clipboard, &ctx).await;
        assert_eq!(shown[0]["kind"], "files");
        assert!(
            shown[0].get("mime").is_none(),
            "no file was written for the preview"
        );
        assert_eq!(shown[0]["files"][0], "/tmp/a.png");
        assert_eq!(shown[1]["kind"], "html");
        assert_eq!(shown[1]["html"], "<b>hello</b>");

        let mut huge = changed("text", &id(5));
        huge.text = Some("x".repeat(MAX_ENTRY_BYTES + 1));
        clipboard.on_event(ctx.clone(), huge).await;
        assert_eq!(show(&clipboard, &ctx).await.as_array().unwrap().len(), 2);

        let mut outside = changed("image", "../not-an-id");
        outside.id = Some("../not-an-id".into());
        outside.mime = Some("image/png".into());
        outside.sha256 = Some(sha());
        clipboard.on_event(ctx.clone(), outside).await;
        assert_eq!(show(&clipboard, &ctx).await.as_array().unwrap().len(), 2);
        tokio::fs::remove_dir_all(ctx.data_dir()).await.unwrap();
    }
}
