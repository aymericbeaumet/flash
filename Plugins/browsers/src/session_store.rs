//! Firefox's session store: the `mozLz40\0`-framed JSON each profile keeps at
//! `sessionstore-backups/recovery.jsonlz4`, rewritten by a running Firefox
//! about every 15 seconds. It knows every open window — including those on
//! other Spaces, which the Accessibility walk cannot see — with each tab's
//! current URL and title, the selected tab per window and the last-focused
//! window. It is read in place (never copied) and decoded in memory.
//!
//! Every Firefox channel on macOS shares `~/Library/Application
//! Support/Firefox`. `installs.ini` names each installation's default
//! profile, so those are the candidate stores; without it, every profile
//! under `Profiles/` is. Which candidate belongs to which running Firefox is
//! decided against that process's tab strip (see `firefox::assign_stores`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::UNIX_EPOCH;

use serde::Deserialize;

use crate::lz4;

const MAX_PROFILES: usize = 32;
const MAX_COMPRESSED_BYTES: u64 = 32 * 1024 * 1024;
const MAX_DECODED_BYTES: usize = 64 * 1024 * 1024;
const MAX_TABS: usize = 100_000;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionStore {
    /// Open windows, in the store's order.
    pub windows: Vec<SessionWindow>,
    /// 0-based index into `windows` of the last-focused window.
    pub selected_window: Option<usize>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionWindow {
    /// The window's tab strip in order. Hidden tabs are dropped: the strip,
    /// the Accessibility walk and Firefox's ⌘1…⌘9 all skip them.
    pub tabs: Vec<SessionTab>,
    /// 0-based index into `tabs` of the window's selected tab.
    pub selected: Option<usize>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionTab {
    pub title: String,
    pub url: String,
}

/// One decoded candidate store.
#[derive(Clone, Debug)]
pub struct StoreFile {
    pub modified_ms: u128,
    pub store: Arc<SessionStore>,
}

/// Decoded stores keyed by path, valid while the file's (mtime, length)
/// stays put: the decode is several MB of LZ4'd JSON, and a refresh, a pick
/// and its verification all read the same file between Firefox's writes.
type CacheEntry = ((u128, u64), Arc<SessionStore>);
static CACHE: LazyLock<Mutex<HashMap<PathBuf, CacheEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Every readable candidate store, newest first.
pub async fn load() -> Vec<StoreFile> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let root = PathBuf::from(home).join("Library/Application Support/Firefox");
    let mut files = Vec::new();
    let mut paths = Vec::new();
    for profile in candidate_profiles(&root).await {
        let path = profile.join("sessionstore-backups/recovery.jsonlz4");
        let Ok(metadata) = tokio::fs::metadata(&path).await else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_COMPRESSED_BYTES {
            continue;
        }
        let modified_ms = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map(|since| since.as_millis())
            .unwrap_or(0);
        let key = (modified_ms, metadata.len());
        paths.push(path.clone());
        let cached = cache()
            .get(&path)
            .filter(|(cached_key, _)| *cached_key == key)
            .map(|(_, store)| Arc::clone(store));
        let store = match cached {
            Some(store) => store,
            None => {
                let Some(store) = read(&path).await else {
                    continue;
                };
                cache().insert(path, (key, Arc::clone(&store)));
                store
            }
        };
        files.push(StoreFile { modified_ms, store });
    }
    cache().retain(|path, _| paths.contains(path));
    files.sort_by_key(|file| std::cmp::Reverse(file.modified_ms));
    files
}

fn cache() -> std::sync::MutexGuard<'static, HashMap<PathBuf, CacheEntry>> {
    CACHE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Each installation's default profile (`installs.ini`); every directory
/// under `Profiles/` when that file is missing or names none.
async fn candidate_profiles(root: &Path) -> Vec<PathBuf> {
    if let Ok(text) = tokio::fs::read_to_string(root.join("installs.ini")).await {
        let defaults = install_default_profiles(&text);
        if !defaults.is_empty() {
            return defaults
                .into_iter()
                .take(MAX_PROFILES)
                .map(|profile| root.join(profile))
                .collect();
        }
    }
    let Ok(mut entries) = tokio::fs::read_dir(root.join("Profiles")).await else {
        return Vec::new();
    };
    let mut profiles = Vec::new();
    while profiles.len() < MAX_PROFILES {
        let Ok(Some(entry)) = entries.next_entry().await else {
            break;
        };
        profiles.push(entry.path());
    }
    profiles.sort();
    profiles
}

/// The `Default=` profile path of every `[<install hash>]` section, in file
/// order and deduplicated. Paths are relative to the Firefox root unless
/// absolute (a profile outside it).
pub fn install_default_profiles(text: &str) -> Vec<String> {
    let mut profiles: Vec<String> = Vec::new();
    for line in text.lines() {
        let Some(value) = line.trim().strip_prefix("Default=") else {
            continue;
        };
        let value = value.trim();
        if !value.is_empty() && !profiles.iter().any(|profile| profile == value) {
            profiles.push(value.to_string());
        }
    }
    profiles
}

async fn read(path: &Path) -> Option<Arc<SessionStore>> {
    let bytes = tokio::fs::read(path).await.ok()?;
    if bytes.len() as u64 > MAX_COMPRESSED_BYTES {
        return None;
    }
    // Decompressing and parsing megabytes of JSON is CPU-bound: keep it off
    // the plugin's two async workers.
    tokio::task::spawn_blocking(move || decode_frame(&bytes).and_then(|text| parse(&text)))
        .await
        .ok()
        .flatten()
        .map(Arc::new)
}

/// `mozLz40\0`, the decoded length (u32 LE), then one LZ4 block.
pub fn decode_frame(bytes: &[u8]) -> Option<String> {
    const MAGIC: &[u8] = b"mozLz40\0";
    let payload = bytes.strip_prefix(MAGIC)?;
    let header: [u8; 4] = payload.get(..4)?.try_into().ok()?;
    let expected_len = u32::from_le_bytes(header) as usize;
    if expected_len > MAX_DECODED_BYTES {
        return None;
    }
    let decoded = lz4::decode_block(&payload[4..], expected_len)?;
    if decoded.len() != expected_len {
        return None;
    }
    String::from_utf8(decoded).ok()
}

#[derive(Deserialize)]
struct RawStore {
    #[serde(default)]
    windows: Vec<RawWindow>,
    #[serde(default, rename = "selectedWindow")]
    selected_window: Option<i64>,
}

#[derive(Deserialize)]
struct RawWindow {
    #[serde(default)]
    tabs: Vec<RawTab>,
    #[serde(default)]
    selected: Option<i64>,
}

#[derive(Deserialize)]
struct RawTab {
    #[serde(default)]
    entries: Vec<RawEntry>,
    #[serde(default)]
    index: Option<i64>,
    #[serde(default)]
    hidden: Option<bool>,
}

#[derive(Deserialize)]
struct RawEntry {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    title: Option<String>,
}

/// Parse the store's JSON. `selectedWindow`, `selected` and each tab's
/// `index` (its current history entry) are 1-based; 0 or out of range means
/// none.
pub fn parse(text: &str) -> Option<SessionStore> {
    let raw: RawStore = serde_json::from_str(text).ok()?;
    let mut budget = MAX_TABS;
    let windows: Vec<SessionWindow> = raw
        .windows
        .into_iter()
        .map(|window| parse_window(window, &mut budget))
        .collect();
    let selected_window = one_based(raw.selected_window).filter(|index| *index < windows.len());
    Some(SessionStore {
        windows,
        selected_window,
    })
}

fn parse_window(raw: RawWindow, budget: &mut usize) -> SessionWindow {
    let selected_position = one_based(raw.selected);
    let mut window = SessionWindow::default();
    for (position, tab) in raw.tabs.into_iter().enumerate() {
        if tab.hidden == Some(true) {
            continue;
        }
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        if selected_position == Some(position) {
            window.selected = Some(window.tabs.len());
        }
        window.tabs.push(current_entry(&tab));
    }
    window
}

/// The tab's current history entry. A page without a title shows its URL in
/// the strip, so the URL stands in for it.
fn current_entry(tab: &RawTab) -> SessionTab {
    let entry = one_based(tab.index)
        .and_then(|index| tab.entries.get(index))
        .or_else(|| tab.entries.last());
    let Some(entry) = entry else {
        return SessionTab::default();
    };
    let url = entry.url.as_deref().unwrap_or("").trim();
    let title = entry
        .title
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or(url);
    SessionTab {
        title: title.to_string(),
        url: url.to_string(),
    }
}

fn one_based(value: Option<i64>) -> Option<usize> {
    usize::try_from(value?).ok()?.checked_sub(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(title: &str, url: &str) -> SessionTab {
        SessionTab {
            title: title.into(),
            url: url.into(),
        }
    }

    #[test]
    fn keeps_window_grouping_and_selection() {
        let store = parse(
            r#"{
              "selectedWindow": 2,
              "windows": [
                {
                  "selected": 2,
                  "tabs": [
                    {"index": 2, "entries": [
                      {"url": "https://example.com/old", "title": "Old"},
                      {"url": "https://mail.google.com/mail/u/0/#inbox", "title": "Gmail"}
                    ]},
                    {"entries": [{"url": "https://github.com/aymericbeaumet/flash", "title": "flash"}]}
                  ]
                },
                {
                  "selected": 1,
                  "tabs": [{"index": 1, "entries": [{"url": "about:preferences"}]}]
                }
              ],
              "_closedWindows": [{"tabs": [{"entries": [{"url": "https://closed.example/"}]}]}]
            }"#,
        )
        .unwrap();
        assert_eq!(
            store,
            SessionStore {
                windows: vec![
                    SessionWindow {
                        tabs: vec![
                            tab("Gmail", "https://mail.google.com/mail/u/0/#inbox"),
                            tab("flash", "https://github.com/aymericbeaumet/flash"),
                        ],
                        selected: Some(1),
                    },
                    SessionWindow {
                        // No title: the strip shows the URL.
                        tabs: vec![tab("about:preferences", "about:preferences")],
                        selected: Some(0),
                    },
                ],
                selected_window: Some(1),
            }
        );
    }

    #[test]
    fn hidden_tabs_leave_the_strip_and_shift_the_selection() {
        let store = parse(
            r#"{"windows": [{"selected": 3, "tabs": [
              {"entries": [{"url": "https://a.example/", "title": "A"}]},
              {"hidden": true, "entries": [{"url": "https://h.example/", "title": "Hidden"}]},
              {"entries": [{"url": "https://b.example/", "title": "B"}]}
            ]}]}"#,
        )
        .unwrap();
        let window = &store.windows[0];
        assert_eq!(
            window.tabs,
            [
                tab("A", "https://a.example/"),
                tab("B", "https://b.example/")
            ]
        );
        assert_eq!(window.selected, Some(1));
        // No `selectedWindow`, and a zero one, both mean none.
        assert_eq!(store.selected_window, None);
        let zero = parse(r#"{"selectedWindow": 0, "windows": []}"#).unwrap();
        assert_eq!(zero.selected_window, None);
    }

    #[test]
    fn out_of_range_selection_and_entry_indexes_degrade() {
        let store = parse(
            r#"{"selectedWindow": 5, "windows": [{"selected": 9, "tabs": [
              {"index": 7, "entries": [{"url": "https://a.example/", "title": "A"}]},
              {"entries": []}
            ]}]}"#,
        )
        .unwrap();
        assert_eq!(store.selected_window, None);
        assert_eq!(store.windows[0].selected, None);
        // A stale entry index falls back to the last entry; a tab without
        // entries keeps its strip position with nothing to offer.
        assert_eq!(
            store.windows[0].tabs,
            [tab("A", "https://a.example/"), SessionTab::default()]
        );
        assert_eq!(parse("not json"), None);
    }

    #[test]
    fn installs_ini_names_each_installation_default_profile() {
        let profiles = install_default_profiles(
            "[1F42C145FFDD4120]\nDefault=Profiles/fy1p8nsy.dev-edition-default\nLocked=1\n\n\
             [2656FF1E876E9973]\r\nDefault=Profiles/rlpg30ft.default-release\r\nLocked=1\r\n\
             [3333333333333333]\nDefault=Profiles/rlpg30ft.default-release\n\
             [4444444444444444]\nDefault=/Volumes/External/firefox-profile\n\
             [5555555555555555]\nDefault=\n",
        );
        assert_eq!(
            profiles,
            [
                "Profiles/fy1p8nsy.dev-edition-default",
                "Profiles/rlpg30ft.default-release",
                "/Volumes/External/firefox-profile",
            ]
        );
        let root = Path::new("/Users/me/Library/Application Support/Firefox");
        assert_eq!(
            root.join(&profiles[2]),
            Path::new("/Volumes/External/firefox-profile")
        );
        assert!(install_default_profiles("").is_empty());
    }

    #[test]
    fn decodes_mozilla_lz4_frames() {
        let json = br#"{"windows":[]}"#;
        let mut frame = b"mozLz40\0".to_vec();
        frame.extend_from_slice(&(json.len() as u32).to_le_bytes());
        frame.push((json.len() as u8) << 4);
        frame.extend_from_slice(json);
        assert_eq!(decode_frame(&frame).as_deref(), Some(r#"{"windows":[]}"#));
        assert_eq!(decode_frame(&frame[1..]), None, "magic required");
    }

    #[test]
    fn rejects_frames_advertising_oversized_output() {
        let mut frame = b"mozLz40\0".to_vec();
        frame.extend_from_slice(&((MAX_DECODED_BYTES as u32) + 1).to_le_bytes());
        frame.push(0);
        assert!(decode_frame(&frame).is_none());
    }
}
