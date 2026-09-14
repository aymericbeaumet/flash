//! The on-disk contract between the Firefox add-on's native-messaging host
//! (`flash-plugin-firefox-bridge`) and the Flash `firefox` plugin.
//!
//! The bridge is ONE-WAY. Firefox spawns the host binary per message, the host
//! writes one state file and exits, and the plugin reads that file off disk —
//! exactly as it already reads the session store and `places.sqlite`. Nothing
//! in this module opens a channel back to the browser.
//!
//! Both binaries of this crate include this file as a module, so the caps and
//! the shape can never drift between writer and reader.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Sub-directory of the plugin data dir that holds the state files.
pub const BRIDGE_DIR_NAME: &str = "bridge";
/// Native-messaging host name. The add-on passes exactly this string to
/// `runtime.sendNativeMessage`, and Firefox resolves it to
/// `<host name>.json` in the user's `NativeMessagingHosts` directory.
pub const HOST_NAME: &str = "com.flash.firefox_bridge";
/// Wire version of the state file. A mismatch is rejected outright (no dual
/// readers): the plugin falls back to its Accessibility walk until the
/// extension and the binary are back in step.
pub const STATE_VERSION: u32 = 1;
/// Caps mirrored by `extension/background.js`. The writer enforces them so a
/// misbehaving add-on cannot grow the file without bound; the reader enforces
/// them again so a hand-edited file cannot grow the catalog without bound.
pub const MAX_TABS: usize = 2_000;
pub const MAX_WINDOWS: usize = 200;
pub const MAX_TITLE_CHARS: usize = 512;
pub const MAX_URL_CHARS: usize = 2_048;
/// Ceiling for the encoded state file, comfortably above
/// `MAX_TABS × (MAX_TITLE_CHARS + MAX_URL_CHARS)`.
pub const MAX_STATE_BYTES: u64 = 8 * 1024 * 1024;

/// One Firefox window as the add-on sees it.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct BridgeWindow {
    pub id: i64,
    #[serde(default)]
    pub focused: bool,
}

/// One tab, with the exact strip position the add-on reports. `index` is
/// 0-based and counts pinned tabs, which is precisely what Firefox's own
/// ⌘1..⌘8 bindings address.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct BridgeTab {
    pub id: i64,
    pub window_id: i64,
    #[serde(default)]
    pub index: u32,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub pinned: bool,
}

/// The whole mirror: one atomic snapshot of every tab in every window.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct BridgeState {
    pub version: u32,
    #[serde(default)]
    pub sequence: u64,
    #[serde(default)]
    pub timestamp_ms: u64,
    #[serde(default)]
    pub focused_window_id: Option<i64>,
    #[serde(default)]
    pub windows: Vec<BridgeWindow>,
    #[serde(default)]
    pub tabs: Vec<BridgeTab>,
}

impl BridgeState {
    /// Whether this file was written by a binary that speaks the same
    /// version. Rejecting is the whole policy — there is no upgrade path.
    pub fn is_supported(&self) -> bool {
        self.version == STATE_VERSION
    }

    /// Clamp everything to the shared caps and drop rows that cannot be
    /// addressed: tabs whose window is not in the window list, and a focused
    /// window id that no window claims. Deterministic ordering
    /// (`window_id`, then strip `index`) so the reader and the writer agree
    /// on the file byte-for-byte.
    pub fn normalize(&mut self) {
        self.windows.truncate(MAX_WINDOWS);
        let known: Vec<i64> = self.windows.iter().map(|window| window.id).collect();
        self.tabs.retain(|tab| known.contains(&tab.window_id));
        self.tabs.sort_by(|lhs, rhs| {
            lhs.window_id
                .cmp(&rhs.window_id)
                .then(lhs.index.cmp(&rhs.index))
        });
        self.tabs.truncate(MAX_TABS);
        for tab in &mut self.tabs {
            truncate_chars(&mut tab.title, MAX_TITLE_CHARS);
            truncate_chars(&mut tab.url, MAX_URL_CHARS);
        }
        if let Some(focused) = self.focused_window_id {
            if !known.contains(&focused) {
                self.focused_window_id = None;
            }
        }
        if self.focused_window_id.is_none() {
            self.focused_window_id = self
                .windows
                .iter()
                .find(|window| window.focused)
                .map(|window| window.id);
        }
    }
}

/// State-file path for the Firefox process `pid`. Keying by pid keeps two
/// running editions (release and developer) independent and lets a reader
/// ignore files that belong to a browser that is no longer running.
pub fn state_file(dir: &Path, pid: i64) -> PathBuf {
    dir.join(format!("tabs-{pid}.json"))
}

/// Where Firefox looks for this bridge's native-messaging host manifest. It
/// must exist before the add-on's first message: Firefox resolves the host
/// name per message and fails the call outright when the manifest is missing.
pub fn host_manifest_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Application Support")
        .join("Mozilla")
        .join("NativeMessagingHosts")
        .join(format!("{HOST_NAME}.json"))
}

fn truncate_chars(value: &mut String, max: usize) {
    if value.chars().count() <= max {
        return;
    }
    *value = value.chars().take(max).collect();
}
