//! `flash-plugin-firefox-bridge` — the Firefox native-messaging host for the
//! Flash tab-bridge add-on.
//!
//! FIREFOX owns this process. For every `runtime.sendNativeMessage` call the
//! browser spawns this binary, writes ONE length-prefixed frame to its stdin,
//! reads ONE reply frame, and reaps it. Flash never spawns it, never connects
//! to it and has no channel to it: the only thing this binary does is drop a
//! JSON state file into the Flash `firefox` plugin's data directory, which the
//! plugin then reads off disk exactly as it reads the session store.
//!
//! Framing here is Mozilla's, not Flash's: a 4-byte NATIVE-endian (little on
//! every Apple target) length prefix followed by that many UTF-8 JSON bytes.
//! Flash's own plugin protocol is newline-delimited JSON on a long-lived
//! stdio pair; the two never meet, which is why this is a separate binary
//! instead of a mode of `flash-plugin-firefox`.
//!
//! `install` writes the native-messaging host manifest that lets Firefox find
//! this binary, and prints where it landed.

mod bridge_state;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, SystemTime};

use bridge_state::{
    host_manifest_path, state_file, BridgeState, BRIDGE_DIR_NAME, HOST_NAME, MAX_STATE_BYTES,
};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const EXTENSION_ID: &str = "flash-tab-bridge@aymericbeaumet.com";
const HOST_DESCRIPTION: &str =
    "Mirror Firefox tab state into the Flash firefox plugin's data directory.";
/// Plugin id whose data directory holds the state files. Matches
/// `Plugins/firefox/manifest.json`.
const PLUGIN_ID: &str = "firefox";
/// Files older than this whose owning process is gone are swept. A running
/// Firefox with the add-on loaded re-publishes on every tab event and on a
/// heartbeat, so a live browser's file is never anywhere near this old.
const PRUNE_AFTER: Duration = Duration::from_secs(60 * 60);

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    // Firefox passes the host manifest path as an argument, so unknown argv is
    // NOT an error — only the explicit `install` verb changes the mode.
    if std::env::args().nth(1).as_deref() == Some("install") {
        return match install().await {
            Ok(path) => {
                println!("{}", path.display());
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("flash-plugin-firefox-bridge: install failed: {error}");
                ExitCode::FAILURE
            }
        };
    }
    match serve_one_message().await {
        Ok(Some(accepted)) => {
            let reply = json!({"ok": true, "tabs": accepted});
            match write_frame(&reply.to_string()).await {
                Ok(()) => ExitCode::SUCCESS,
                Err(_) => ExitCode::FAILURE,
            }
        }
        // Clean EOF without a frame: Firefox closed the pipe (shutdown, or the
        // add-on was disabled mid-flight). Nothing to answer.
        Ok(None) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("flash-plugin-firefox-bridge: {error}");
            let reply = json!({"ok": false, "error": error});
            let _ = write_frame(&reply.to_string()).await;
            ExitCode::FAILURE
        }
    }
}

/// Read one framed message, persist it, and report how many tabs were kept.
async fn serve_one_message() -> Result<Option<usize>, String> {
    let Some(payload) = read_frame().await? else {
        return Ok(None);
    };
    let mut state: BridgeState =
        serde_json::from_slice(&payload).map_err(|error| format!("undecodable state: {error}"))?;
    if !state.is_supported() {
        return Err(format!("unsupported state version {}", state.version));
    }
    state.normalize();
    let tabs = state.tabs.len();
    let dir = state_dir();
    let pid = i64::from(std::os::unix::process::parent_id());
    write_state(&dir, pid, &state).await?;
    prune_dead_state_files(&dir, pid).await;
    Ok(Some(tabs))
}

// ---------------------------------------------------------------------------
// Mozilla native-messaging framing
// ---------------------------------------------------------------------------

/// Read the 4-byte length prefix and that many bytes. `Ok(None)` is a clean
/// EOF before any prefix byte. Zero-length and oversized frames are rejected
/// without reading the body — an oversized advertisement must never be
/// allowed to allocate.
async fn read_frame() -> Result<Option<Vec<u8>>, String> {
    let mut stdin = tokio::io::stdin();
    let mut prefix = [0u8; 4];
    let mut filled = 0usize;
    while filled < prefix.len() {
        let read = stdin
            .read(&mut prefix[filled..])
            .await
            .map_err(|error| format!("reading the length prefix failed: {error}"))?;
        if read == 0 {
            if filled == 0 {
                return Ok(None);
            }
            return Err("truncated length prefix".to_string());
        }
        filled += read;
    }
    let len = u32::from_le_bytes(prefix);
    if len == 0 {
        return Err("zero-length frame".to_string());
    }
    if u64::from(len) > MAX_STATE_BYTES {
        return Err(format!("oversized frame: {len} bytes"));
    }
    let mut payload = vec![0u8; len as usize];
    stdin
        .read_exact(&mut payload)
        .await
        .map_err(|error| format!("truncated frame body: {error}"))?;
    Ok(Some(payload))
}

async fn write_frame(body: &str) -> Result<(), String> {
    let bytes = body.as_bytes();
    let len = u32::try_from(bytes.len()).map_err(|_| "reply too large".to_string())?;
    let mut stdout = tokio::io::stdout();
    stdout
        .write_all(&len.to_le_bytes())
        .await
        .map_err(|error| format!("writing the reply prefix failed: {error}"))?;
    stdout
        .write_all(bytes)
        .await
        .map_err(|error| format!("writing the reply failed: {error}"))?;
    stdout
        .flush()
        .await
        .map_err(|error| format!("flushing the reply failed: {error}"))
}

// ---------------------------------------------------------------------------
// State files
// ---------------------------------------------------------------------------

/// Where the Flash host hands the `firefox` plugin its data directory. The
/// plugin child receives it as `FLASH_PLUGIN_DATA_DIR`; this process is
/// spawned by Firefox with no Flash environment at all, so it reconstructs the
/// same path from `PluginRepository.defaultDataDir()`'s layout. The variable
/// still wins when it is set, which is how the pair is exercised outside a
/// real install.
fn state_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("FLASH_PLUGIN_DATA_DIR") {
        return PathBuf::from(dir).join(BRIDGE_DIR_NAME);
    }
    home_dir()
        .join("Library")
        .join("Application Support")
        .join("Flash")
        .join("Plugins")
        .join(PLUGIN_ID)
        .join(BRIDGE_DIR_NAME)
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Temp file then rename: the plugin polls this directory, so it must only
/// ever observe a whole state file.
async fn write_state(dir: &Path, pid: i64, state: &BridgeState) -> Result<(), String> {
    tokio::fs::create_dir_all(dir)
        .await
        .map_err(|error| format!("creating {} failed: {error}", dir.display()))?;
    let encoded = serde_json::to_vec(state).map_err(|error| format!("encoding failed: {error}"))?;
    if encoded.len() as u64 > MAX_STATE_BYTES {
        return Err(format!("encoded state too large: {} bytes", encoded.len()));
    }
    let destination = state_file(dir, pid);
    let staged = dir.join(format!(".tabs-{pid}.json.tmp"));
    tokio::fs::write(&staged, &encoded)
        .await
        .map_err(|error| format!("writing {} failed: {error}", staged.display()))?;
    tokio::fs::rename(&staged, &destination)
        .await
        .map_err(|error| format!("publishing {} failed: {error}", destination.display()))
}

/// Sweep state files whose Firefox is gone. `keep` (our own parent) is never
/// considered. Liveness is resolved with ONE `/bin/ps` call over the candidate
/// pids — there is at most one file per running Firefox edition. A failure to
/// resolve leaves every file in place: a missed sweep is harmless, a wrong
/// delete loses a live browser's mirror.
async fn prune_dead_state_files(dir: &Path, keep: i64) {
    let Ok(mut entries) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut candidates: Vec<(i64, PathBuf)> = Vec::new();
    let now = SystemTime::now();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let path = entry.path();
        let Some(pid) = path.file_name().and_then(state_file_pid) else {
            continue;
        };
        if pid == keep || candidates.len() >= bridge_state::MAX_WINDOWS {
            continue;
        }
        let recent = tokio::fs::metadata(&path)
            .await
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age < PRUNE_AFTER);
        if recent {
            continue;
        }
        candidates.push((pid, path));
    }
    if candidates.is_empty() {
        return;
    }
    let Some(live) = live_pids(&candidates.iter().map(|(pid, _)| *pid).collect::<Vec<_>>()).await
    else {
        return;
    };
    for (pid, path) in candidates {
        if live.contains(&pid) {
            continue;
        }
        let _ = tokio::fs::remove_file(&path).await;
    }
}

fn state_file_pid(name: &std::ffi::OsStr) -> Option<i64> {
    name.to_str()?
        .strip_prefix("tabs-")?
        .strip_suffix(".json")?
        .parse::<i64>()
        .ok()
}

/// The subset of `pids` that still exist, via one `/bin/ps`. `None` means the
/// question could not be answered.
async fn live_pids(pids: &[i64]) -> Option<Vec<i64>> {
    let list = pids
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let output = tokio::process::Command::new("/bin/ps")
        .arg("-o")
        .arg("pid=")
        .arg("-p")
        .arg(&list)
        .output()
        .await
        .ok()?;
    Some(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| line.trim().parse::<i64>().ok())
            .collect(),
    )
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

/// Write the native-messaging host manifest Firefox reads to find this binary.
/// It must exist BEFORE the add-on sends its first message: Firefox resolves
/// the host name per message and fails the call outright when the manifest is
/// missing.
async fn install() -> Result<PathBuf, String> {
    let binary = std::env::current_exe()
        .map_err(|error| format!("resolving this binary's path failed: {error}"))?;
    let destination = host_manifest_path(&home_dir());
    let dir = destination
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "the host manifest path has no parent".to_string())?;
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|error| format!("creating {} failed: {error}", dir.display()))?;
    let manifest = json!({
        "name": HOST_NAME,
        "description": HOST_DESCRIPTION,
        "path": binary.to_string_lossy(),
        "type": "stdio",
        "allowed_extensions": [EXTENSION_ID],
    });
    let staged = dir.join(format!(".{HOST_NAME}.json.tmp"));
    let body = serde_json::to_string_pretty(&manifest)
        .map_err(|error| format!("encoding the host manifest failed: {error}"))?
        + "\n";
    tokio::fs::write(&staged, body.as_bytes())
        .await
        .map_err(|error| format!("writing {} failed: {error}", staged.display()))?;
    tokio::fs::rename(&staged, &destination)
        .await
        .map_err(|error| format!("publishing {} failed: {error}", destination.display()))?;
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_file_names_carry_the_owning_pid() {
        assert_eq!(
            state_file_pid(std::ffi::OsStr::new("tabs-421.json")),
            Some(421)
        );
        assert_eq!(state_file_pid(std::ffi::OsStr::new("tabs-.json")), None);
        assert_eq!(
            state_file_pid(std::ffi::OsStr::new(".tabs-421.json.tmp")),
            None
        );
        assert_eq!(state_file_pid(std::ffi::OsStr::new("places.sqlite")), None);
    }

    #[test]
    fn state_dir_honours_an_explicit_plugin_data_dir() {
        // Set/removed within one test: the process env is global, and the
        // other tests in this binary never read it.
        std::env::set_var("FLASH_PLUGIN_DATA_DIR", "/tmp/flash-bridge-test");
        assert_eq!(
            state_dir(),
            PathBuf::from("/tmp/flash-bridge-test").join(BRIDGE_DIR_NAME)
        );
        std::env::remove_var("FLASH_PLUGIN_DATA_DIR");
        assert!(state_dir().ends_with(
            PathBuf::from("Flash")
                .join("Plugins")
                .join(PLUGIN_ID)
                .join(BRIDGE_DIR_NAME)
        ));
    }
}
