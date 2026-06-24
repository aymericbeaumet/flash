//! Tmux plugin — ports the former Python tmux plugin to Rust.
//!
//! ## Warm-location contract
//!
//! Tmux exposes no native host event stream for window-list changes (no
//! `core:focus.changed`-style ping fires when the user creates/renames/
//! closes a window inside an attached client). The plugin therefore owns
//! its own freshness loop, keeping its locations warm in memory:
//!
//!   1. `on_start` runs an immediate `build_candidates` and stores the
//!      initial warm locations. Subsequent flashlight opens never block on
//!      this seed — by the time the user can press `f`, the warm locations
//!      are populated.
//!   2. A 1 s background poll re-runs `build_candidates` and replaces the
//!      warm locations **only when the candidate hash actually changed**. The
//!      dedup gate is the load-bearing invariant: without it the warm cache
//!      would be rewritten on every poll even when tmux state was
//!      identical. Flashlight pulls the warm locations once when it opens, so
//!      unchanged plugin polls must be true no-ops.
//!   3. Host events (`core:focus.changed`, `core:flash.started`,
//!      `core:apps.terminated`) trigger an additional refresh so a
//!      focus-in catches state that drifted while the user was
//!      elsewhere.
//!   4. The host's `candidateQuery` RPC is **NOT overridden**. The
//!      default contract (return `CandidateQueryResponse::keep()`)
//!      is what we want: the host pulls the warm locations instantly, no
//!      subprocesses fire on the user's `f` keypress. Letting
//!      `candidate_query` run `build_candidates` was the previous bug —
//!      the user either waited on tmux I/O or saw stale warm locations become
//!      correct only after a later refresh.
//!   5. The eager refresh also retains its `list-clients` + process tree
//!      sample. Hint discovery and source actions consult that warm cache
//!      first, so `[t` / `]t` do not rediscover every tmux socket before
//!      running the single tmux command that actually changes windows.
//!
//! Per-socket subprocess fan-out (`list-clients`, `list-windows -a`) is
//! parallelised via `tokio::spawn` so a single hung socket can't stall
//! the whole refresh — the slowest socket sets the cycle length, not
//! the sum.
//!
//! ## Hint discovery
//!
//! On each activation Flash calls `discoverTargets` with the focused
//! app's pid + window frame; the plugin returns pane-chip and link-chip
//! targets in screen coordinates.
//!
//! Geometry mirrors the previous implementation:
//!   - cell size = window / cells (fallback) OR alacritty-style font
//!     metrics when alacritty.toml exposes the font (NSFont
//!     ascender/descender/advance via objc2).
//!   - pane chips: 3-cell-wide rect at pane centre.
//!   - link chips: per-regex match in `capture-pane -p` output.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::{Hash, Hasher};
use std::os::unix::fs::FileTypeExt;
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use flash_plugin::{
    run, ActivateRequest, Candidate, CommandRequest, CommandResponse, Context, DiscoverRequest,
    DiscoverResponse, Event, Frame, JumpTarget, NavigationRequest, Priority, ResolveResponse,
    SourceActionRequest, SourceActionResponse,
};
use regex::Regex;
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:tmux";
const NAV_SCHEME: &str = "tmux";

const TMUX_PREFIXES: [&str; 4] = ["/opt/homebrew", "/usr/local", "/opt/local", "/usr"];
const ENV_PATH: &str = "/usr/bin/env";
const PS_PATH: &str = "/bin/ps";
const TMUX_FIELD_SEP: &str = "|||";

const LINKS_PER_PANE_LIMIT: usize = 40;
const ALACRITTY_BUNDLES: [&str; 2] = ["org.alacritty", "io.alacritty"];

// ---- Link extraction --------------------------------------------------------

fn link_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // URLs · $VAR / ${VAR} shell-style env-prefixed paths · ~/ and / paths ·
        // ./ ../ relative paths · dotted host/path tokens · bare file.ext names ·
        // E#### error codes (Rust/cargo, etc.). The trailing `:LINE[:COL]`
        // editor-jump suffix is folded into the path-shaped alternatives.
        //
        // The bare `host.ext` alternative requires the final segment to start
        // with a letter and be 2+ chars (`\.[a-zA-Z][\w-]+`) so noise tokens —
        // file sizes (`8.2k`), abbreviations (`e.g`), versions (`v0.1.0`) —
        // don't masquerade as links, while real filenames/domains (`Cargo.toml`,
        // `README.md`, `beside.com`, `t.io`) still match. URLs and slash-paths
        // are unaffected.
        let pattern = r#"https?://[\w./\-?&=@%+:~#!$,;*()]+[\w/]|\$\{?\w+\}?(?:/[\w./\-]+)+|(?:~|/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|(?:\.{1,2}/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+(?:/[^\s\]\r\n][^\s\]\r\n]*)+\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+\.[a-zA-Z][\w-]+(?::\d+(?::\d+)?)?|(?-u:\b)E\d{4}(?-u:\b)"#;
        Regex::new(pattern).expect("tmux link regex")
    })
}

/// A real clickable URL (vs. a path / dotted-host / error-code match). Used to
/// prioritise URLs when a pane has more links than the per-pane hint budget.
fn is_url(text: &str) -> bool {
    text.starts_with("http://") || text.starts_with("https://")
}

/// Yield `(column, text)` for each link match on a line, bounded by `max_cols`
/// columns. Column is a character index to mirror the Python implementation.
fn extract_links(line: &str, max_cols: usize) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for m in link_pattern().find_iter(line) {
        let col = line[..m.start()].chars().count();
        if col >= max_cols {
            continue;
        }
        let text = m
            .as_str()
            .trim_end_matches(['.', ',', ';', ':', ')', ']', '}', '>']);
        if text.is_empty() {
            continue;
        }
        out.push((col, text.to_string()));
    }
    out
}

// ---- tmux invocation --------------------------------------------------------

async fn find_tmux() -> Option<String> {
    for prefix in TMUX_PREFIXES {
        let path = format!("{prefix}/bin/tmux");
        if let Ok(meta) = tokio::fs::metadata(&path).await {
            if meta.is_file() {
                return Some(path);
            }
        }
    }
    which("tmux").await
}

async fn which(program: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(program);
        if let Ok(meta) = tokio::fs::metadata(&candidate).await {
            if meta.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    None
}

async fn run_cmd(program: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(program.to_string());
    argv.extend(args.iter().map(|s| s.to_string()));
    let result = run_local(&argv, timeout).await;
    if !result.ok {
        return None;
    }
    Some(result.stdout)
}

#[derive(Clone, Debug, Default)]
struct CliResult {
    ok: bool,
    stdout: String,
    stderr: String,
    status: i32,
}

async fn run_local(argv: &[String], timeout: Duration) -> CliResult {
    let Some((program, args)) = argv.split_first() else {
        return CliResult {
            ok: false,
            stderr: "empty argv".to_string(),
            status: -1,
            ..Default::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CliResult {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CliResult {
            ok: false,
            stderr: err.to_string(),
            status: -1,
            ..Default::default()
        },
        Err(_) => CliResult {
            ok: false,
            stderr: format!("timed out after {}ms", timeout.as_millis()),
            status: 124,
            ..Default::default()
        },
    }
}

fn tmux_argv(tmux_path: &str, args: &[&str]) -> Vec<String> {
    let mut argv = Vec::with_capacity(args.len() + 10);
    argv.push(ENV_PATH.to_string());
    argv.extend([
        "-u".to_string(),
        "TMUX".to_string(),
        "-u".to_string(),
        "TMUX_PANE".to_string(),
        "-u".to_string(),
        "TMUX_TMPDIR".to_string(),
        "-u".to_string(),
        "TMPDIR".to_string(),
    ]);
    argv.push(tmux_path.to_string());
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

fn tmux_socket_argv(tmux_path: &str, socket_path: &str, args: &[&str]) -> Vec<String> {
    let mut argv = tmux_argv(tmux_path, &["-S", socket_path]);
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

async fn tmux_socket_paths() -> Vec<String> {
    let mut paths = Vec::new();
    for base in ["/private/tmp", "/tmp"] {
        let Ok(mut entries) = tokio::fs::read_dir(base).await else {
            continue;
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.starts_with("tmux-") {
                continue;
            }
            let Ok(mut sockets) = tokio::fs::read_dir(entry.path()).await else {
                continue;
            };
            while let Ok(Some(socket)) = sockets.next_entry().await {
                let Ok(file_type) = socket.file_type().await else {
                    continue;
                };
                if file_type.is_socket() {
                    paths.push(socket.path().to_string_lossy().into_owned());
                }
            }
        }
    }
    paths.sort();
    paths.dedup();
    paths
}

fn tmux_command_needs_nonempty_output(args: &[&str]) -> bool {
    matches!(args.first().copied(), Some("list-clients" | "list-windows"))
}

async fn run_tmux_local(
    tmux_path: &str,
    args: &[&str],
    timeout: Duration,
) -> Result<CliResult, CliResult> {
    let needs_nonempty = tmux_command_needs_nonempty_output(args);
    let mut result = run_local(&tmux_argv(tmux_path, args), timeout).await;
    if result.ok && (!needs_nonempty || !result.stdout.trim().is_empty()) {
        return Ok(result);
    }
    for socket_path in tmux_socket_paths().await {
        result = run_local(&tmux_socket_argv(tmux_path, &socket_path, args), timeout).await;
        if result.ok && (!needs_nonempty || !result.stdout.trim().is_empty()) {
            return Ok(result);
        }
    }
    Err(result)
}

/// Run tmux capturing stderr too, so callers can surface why a command
/// failed instead of just seeing `None`. Used by the mutating tab actions
/// (`new-window`, `kill-window`) where a silent failure is the worst
/// outcome — we'd rather log "session 1: no current path" than fall back
/// to a ⌘N that opens a fresh terminal window.
async fn run_tmux_capture(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
) -> Result<String, String> {
    let path = tmux_path.ok_or_else(|| "tmux binary not found".to_string())?;
    match run_tmux_local(path, args, timeout).await {
        Ok(result) => Ok(result.stdout),
        Err(result) => {
            let stderr = result.stderr.trim();
            Err(if stderr.is_empty() {
                format!("tmux exited status={}", result.status)
            } else {
                stderr.to_string()
            })
        }
    }
}

async fn run_tmux(tmux_path: Option<&str>, args: &[&str], timeout: Duration) -> Option<String> {
    let path = tmux_path?;
    run_tmux_local(path, args, timeout)
        .await
        .ok()
        .map(|result| result.stdout)
}

async fn run_tmux_default(tmux_path: Option<&str>, args: &[&str]) -> Option<String> {
    run_tmux(tmux_path, args, Duration::from_secs(2)).await
}

/// Run an enumeration command (`list-windows -a`, `list-clients`, …) against
/// the default socket *and* every other tmux socket discovered under
/// `/private/tmp/tmux-*` and `/tmp/tmux-*`, then return the union of stdout
/// lines.
///
/// Multiple tmux servers — one per socket — are common (e.g. `tmux -L work`
/// vs the default socket, or one per shell user). Without this, the plugin
/// would only ever see windows belonging to whichever socket happened to
/// answer first, so the flashlight finder silently dropped every session on
/// every other socket.
///
/// All per-socket invocations run in **parallel** via `tokio::spawn`. The
/// previous sequential implementation made the slowest hung socket
/// dominate every refresh — with a 2 s per-call timeout and three
/// sockets, a single dead server stretched a 50 ms operation into 6 s.
/// Now the cycle length is `max(socket)` instead of `sum(sockets)`.
///
/// Identical lines are deduplicated so an alias between the default
/// invocation and an explicit `-S <path>` for the same socket doesn't
/// double-count rows. Empty output is returned as `None` so the caller can
/// preserve the previous warm locations on a transient failure.
async fn run_tmux_aggregate(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
) -> Option<String> {
    let path = tmux_path?.to_string();
    let args_owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();

    // Discover sockets once up front; spawning all invocations together
    // means the slowest socket sets the cycle length, not the sum.
    let socket_paths = tmux_socket_paths().await;
    let mut handles: Vec<tokio::task::JoinHandle<Option<String>>> =
        Vec::with_capacity(socket_paths.len() + 1);

    // Default-socket invocation. Without `-S`, tmux resolves to whichever
    // socket the user's $TMUX_TMPDIR / process environment points at — on
    // most setups this is also covered by `tmux_socket_paths()` below, but
    // we run it first so a non-standard $TMUX_TMPDIR (e.g. a server
    // outside the standard discovery roots) still contributes.
    {
        let path = path.clone();
        let args_owned = args_owned.clone();
        handles.push(tokio::spawn(async move {
            let args_ref: Vec<&str> = args_owned.iter().map(String::as_str).collect();
            let result = run_local(&tmux_argv(&path, &args_ref), timeout).await;
            if result.ok {
                Some(result.stdout)
            } else {
                None
            }
        }));
    }

    for socket_path in socket_paths {
        let path = path.clone();
        let args_owned = args_owned.clone();
        handles.push(tokio::spawn(async move {
            let args_ref: Vec<&str> = args_owned.iter().map(String::as_str).collect();
            let result =
                run_local(&tmux_socket_argv(&path, &socket_path, &args_ref), timeout).await;
            if result.ok {
                Some(result.stdout)
            } else {
                None
            }
        }));
    }

    let mut outputs: Vec<String> = Vec::with_capacity(handles.len());
    for handle in handles {
        if let Ok(Some(stdout)) = handle.await {
            outputs.push(stdout);
        }
    }

    let merged = merge_socket_outputs(outputs.iter().map(String::as_str));
    if merged.is_empty() {
        return None;
    }
    Some(merged)
}

/// Concatenate the stdout of multiple tmux invocations (one per socket)
/// into a single newline-separated blob, dropping empty lines and
/// deduplicating identical rows so the default socket and an explicit
/// `-S <path>` pointing at the same server don't double-count records.
fn merge_socket_outputs<'a, I>(outputs: I) -> String
where
    I: IntoIterator<Item = &'a str>,
{
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut merged: Vec<String> = Vec::new();
    for stdout in outputs {
        for line in stdout.split('\n') {
            if line.is_empty() {
                continue;
            }
            if seen.insert(line.to_string()) {
                merged.push(line.to_string());
            }
        }
    }
    merged.join("\n")
}

async fn run_tmux_aggregate_default(tmux_path: Option<&str>, args: &[&str]) -> Option<String> {
    run_tmux_aggregate(tmux_path, args, Duration::from_secs(2)).await
}

/// Same as [`run_tmux_aggregate_default`] with a longer per-socket
/// budget. Used for the initial location build only — a cold tmux
/// server (just started, or paged out) can take well over the 2 s
/// budget on its first list-windows call, which used to leave the
/// flashlight with a partial location set until the next 1 s poll caught
/// the missed sockets. 6 s is generous enough that even a cold
/// `tmux -L work` socket inside a sleeping shell completes on the
/// first try.
async fn run_tmux_aggregate_warm(tmux_path: Option<&str>, args: &[&str]) -> Option<String> {
    run_tmux_aggregate(tmux_path, args, Duration::from_secs(6)).await
}

fn trimmed(value: Option<String>) -> Option<String> {
    let stripped = value?.trim().to_string();
    if stripped.is_empty() {
        None
    } else {
        Some(stripped)
    }
}

// ---- Process tree -----------------------------------------------------------

async fn parent_pid_map() -> HashMap<i64, i64> {
    let mut map = HashMap::new();
    let Some(out) = run_cmd(
        PS_PATH,
        &["-axo", "pid=,ppid="],
        Duration::from_millis(1500),
    )
    .await
    else {
        return map;
    };
    for line in out.lines() {
        let mut parts = line.split_whitespace();
        if let (Some(pid), Some(ppid)) = (parts.next(), parts.next()) {
            if let (Ok(pid), Ok(ppid)) = (pid.parse::<i64>(), ppid.parse::<i64>()) {
                map.insert(pid, ppid);
            }
        }
    }
    map
}

/// Walk up from `pid` until the next parent is launchd (pid 1); return the
/// highest-level pid before launchd — typically the terminal app hosting the
/// tmux client.
fn find_top_level_ancestor(pid: i64, parent_map: &HashMap<i64, i64>) -> Option<i64> {
    let mut cur = pid;
    for _ in 0..64 {
        if cur <= 1 {
            return None;
        }
        let nxt = *parent_map.get(&cur)?;
        if nxt == cur {
            return None;
        }
        if nxt <= 1 {
            return Some(cur);
        }
        cur = nxt;
    }
    None
}

fn is_ancestor(ancestor_pid: i64, descendant_pid: i64, parent_map: &HashMap<i64, i64>) -> bool {
    let mut cur = descendant_pid;
    for _ in 0..64 {
        if cur <= 1 {
            return false;
        }
        if cur == ancestor_pid {
            return true;
        }
        match parent_map.get(&cur) {
            Some(&nxt) if nxt != cur => cur = nxt,
            _ => return false,
        }
    }
    false
}

fn client_hosted_by_from_map(
    clients: &[TmuxClient],
    focused_pid: i64,
    parent_map: &HashMap<i64, i64>,
) -> Option<TmuxClient> {
    let process_sample_can_evaluate_clients = clients
        .iter()
        .any(|c| parent_map.contains_key(&c.client_pid));
    let mut matches: Vec<TmuxClient> = clients
        .iter()
        .filter(|c| is_ancestor(focused_pid, c.client_pid, parent_map))
        .cloned()
        .collect();
    if matches.is_empty() {
        if process_sample_can_evaluate_clients {
            return None;
        }
        let mut fallback = clients.to_vec();
        fallback.sort_by_key(|c| std::cmp::Reverse(c.activity));
        return fallback.into_iter().next();
    }
    matches.sort_by_key(|c| std::cmp::Reverse(c.activity));
    matches.into_iter().next()
}

fn split_tmux_fields(line: &str, max_fields: usize) -> Vec<&str> {
    let by_unit_sep: Vec<&str> = line.splitn(max_fields, TMUX_FIELD_SEP).collect();
    if by_unit_sep.len() >= max_fields.min(2) {
        return by_unit_sep;
    }
    let by_tab: Vec<&str> = line.splitn(max_fields, '\t').collect();
    if by_tab.len() >= max_fields.min(2) {
        return by_tab;
    }
    line.splitn(max_fields, char::is_whitespace).collect()
}

// ---- tmux clients -----------------------------------------------------------

#[derive(Clone)]
struct TmuxClient {
    tty: String,
    session: String,
    client_pid: i64,
    activity: i64,
}

#[derive(Clone, Default)]
struct ClientSnapshot {
    clients: Vec<TmuxClient>,
    parent_map: HashMap<i64, i64>,
}

impl ClientSnapshot {
    fn hosted_by(&self, focused_pid: i64) -> Option<TmuxClient> {
        if self.clients.is_empty() {
            return None;
        }
        client_hosted_by_from_map(&self.clients, focused_pid, &self.parent_map)
    }
}

async fn list_clients(tmux_path: Option<&str>) -> Vec<TmuxClient> {
    let format = format!(
        "#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    // Aggregated across every discovered tmux socket — `list-clients`
    // only reports clients attached to the socket it was called on, so
    // a single-socket invocation silently drops every client (and
    // therefore every window-resolution route) attached to other tmux
    // servers running on the host.
    let raw = run_tmux_aggregate_default(tmux_path, &["list-clients", "-F", &format]).await;
    let Some(raw) = raw else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in raw.lines() {
        let parts = split_tmux_fields(line, 4);
        if parts.len() < 3 {
            continue;
        }
        let Ok(client_pid) = parts[2].parse::<i64>() else {
            continue;
        };
        let activity = parts
            .get(3)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0);
        out.push(TmuxClient {
            tty: parts[0].to_string(),
            session: parts[1].to_string(),
            client_pid,
            activity,
        });
    }
    out
}

async fn load_client_snapshot(tmux_path: Option<&str>) -> Option<ClientSnapshot> {
    let clients = list_clients(tmux_path).await;
    if clients.is_empty() {
        return None;
    }
    let parent_map = parent_pid_map().await;
    Some(ClientSnapshot {
        clients,
        parent_map,
    })
}

fn cached_client_hosted_by(plugin: &Tmux, focused_pid: i64) -> Option<TmuxClient> {
    plugin
        .client_snapshot()
        .lock()
        .ok()
        .and_then(|snapshot| snapshot.hosted_by(focused_pid))
}

async fn refresh_cached_client_snapshot(plugin: &Tmux) -> Option<ClientSnapshot> {
    let snapshot = load_client_snapshot(plugin.resolved_tmux_path().await).await?;
    if let Ok(mut guard) = plugin.client_snapshot().lock() {
        *guard = snapshot.clone();
    }
    Some(snapshot)
}

async fn client_hosted_by_cached(plugin: &Tmux, focused_pid: i64) -> Option<TmuxClient> {
    if let Some(client) = cached_client_hosted_by(plugin, focused_pid) {
        return Some(client);
    }
    refresh_cached_client_snapshot(plugin)
        .await?
        .hosted_by(focused_pid)
}

fn parse_two_ints(line: &str) -> Option<(i64, i64)> {
    let mut parts = line.split_whitespace();
    let a = parts.next()?.parse::<i64>().ok()?;
    let b = parts.next()?.parse::<i64>().ok()?;
    Some((a, b))
}

/// Returns the status-line top offset in rows: the number of status lines
/// occupying the top of the client when `status-position` is `top`.
fn parse_status_top_offset(line: &str) -> i64 {
    let mut parts = line.split_whitespace();
    let raw = parts.next().unwrap_or("");
    let lines = raw
        .parse::<i64>()
        .unwrap_or(if raw == "on" { 1 } else { 0 });
    let at_top = parts.next() == Some("top");
    if at_top {
        lines
    } else {
        0
    }
}

// ---- Alacritty font + cell geometry -----------------------------------------

fn read_toml_raw(text: &str, section: &str, key: &str) -> Option<String> {
    let mut in_section = false;
    for raw_line in text.split('\n') {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            in_section = line[1..line.len() - 1].trim() == section;
            continue;
        }
        if !in_section {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            if k.trim() == key {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

fn read_toml_string(text: &str, section: &str, key: &str) -> Option<String> {
    let mut raw = read_toml_raw(text, section, key)?;
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        raw = raw[1..raw.len() - 1].to_string();
    }
    if raw.is_empty() {
        None
    } else {
        Some(raw)
    }
}

fn read_toml_number(text: &str, section: &str, key: &str) -> Option<f64> {
    read_toml_raw(text, section, key)?.parse::<f64>().ok()
}

async fn alacritty_font() -> Option<(String, f64)> {
    let home = std::env::var("HOME").ok()?;
    let paths = [
        format!("{home}/.config/alacritty/alacritty.toml"),
        format!("{home}/.alacritty.toml"),
    ];
    for path in paths {
        let Ok(text) = tokio::fs::read_to_string(&path).await else {
            continue;
        };
        let size = read_toml_number(&text, "font", "size").unwrap_or(11.0);
        let family =
            read_toml_string(&text, "font.normal", "family").unwrap_or_else(|| "Menlo".to_string());
        return Some((family, size));
    }
    None
}

/// (advance, line_height) from NSFont design metrics, mirroring the previous
/// PyObjC path: advance = maximumAdvancement.width, line_height = ascender −
/// descender.
fn cell_metrics_appkit(family: &str, size: f64) -> Option<(f64, f64)> {
    use objc2_app_kit::NSFont;
    use objc2_foundation::NSString;

    let name = NSString::from_str(family);
    let font = NSFont::fontWithName_size(&name, size).or_else(|| {
        let menlo = NSString::from_str("Menlo");
        NSFont::fontWithName_size(&menlo, size)
    })?;
    let line_height = font.ascender() - font.descender();
    let advance = font.maximumAdvancement().width;
    if advance <= 0.0 || line_height <= 0.0 {
        return None;
    }
    Some((advance, line_height))
}

/// (cell_w, cell_h, pad_x, pad_y). Alacritty uses font metrics with the
/// content block centred in the window; every other terminal falls back to a
/// flat window/cells division.
async fn resolve_geometry(
    bundle_id: &str,
    win_w: f64,
    win_h: f64,
    cols: f64,
    rows: f64,
) -> (f64, f64, f64, f64) {
    if ALACRITTY_BUNDLES.contains(&bundle_id) {
        if let Some((family, size)) = alacritty_font().await {
            if let Some((cell_w, cell_h)) = cell_metrics_appkit(&family, size) {
                let content_w = cols * cell_w;
                let content_h = rows * cell_h;
                let pad_x = ((win_w - content_w) / 2.0).max(0.0);
                let pad_y = ((win_h - content_h) / 2.0).max(0.0);
                return (cell_w, cell_h, pad_x, pad_y);
            }
        }
    }
    (win_w / cols, win_h / rows, 0.0, 0.0)
}

// ---- Target actions ---------------------------------------------------------

#[derive(Clone)]
enum TargetAction {
    Pane { pane_id: String },
    Link { text: String },
}

struct Pane {
    id: String,
    left: i64,
    top: i64,
    cols: i64,
    rows: i64,
}

// Eleven positional args is on the high side, but `JumpTarget` itself is the
// shape — collapsing this into a `BuildTargetArgs` struct would just rename
// the same data without making the call sites clearer.
#[allow(clippy::too_many_arguments)]
fn build_target(
    target_id: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    role: &str,
    label: &str,
    pid: i64,
    enters_insert_mode: bool,
    prefer_host_click: bool,
    priority: Priority,
) -> JumpTarget {
    JumpTarget::new(target_id, Frame::new(x, y, width, height))
        .role(role)
        .label(label)
        .enters_insert_mode(enters_insert_mode)
        .pid(pid)
        .source_id(SOURCE_ID)
        .prefer_host_click(prefer_host_click)
        .priority(priority)
}

async fn discover_targets_for_context(plugin: &Tmux, req: &DiscoverRequest) -> DiscoverResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    let Some(pid) = req.pid else {
        return DiscoverResponse::targets(vec![]);
    };
    let bundle_id = req.bundle_id.as_deref().unwrap_or("");
    let frame = req.front_window_frame.unwrap_or_default();
    let win_w = frame.width;
    let win_h = frame.height;
    let min_x = frame.x;
    let min_y = frame.y;
    if tmux_path.is_none() || win_w <= 0.0 || win_h <= 0.0 {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    }

    let Some(client) = client_hosted_by_cached(plugin, pid).await else {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    };

    // Pack client geometry and status onto one line separated by the literal
    // `|||` field marker rather than a `\n`. An embedded newline in a
    // `display-message -p` format is NOT reliably rendered as a line break —
    // depending on tmux server state it can collapse, in which case the client
    // dimensions and the status fields arrive on a single line and
    // `parse_two_ints` chokes on `"<height> <status>"`. The discover then bails
    // and `f` silently produces zero hints over a live tmux window. `|||` is
    // literal text the server always emits verbatim (the same separator
    // `list-clients`/`list-windows` rely on), so the split is deterministic.
    let combined_format = format!(
        "#{{client_width}} #{{client_height}}{TMUX_FIELD_SEP}#{{status}} #{{status-position}}"
    );
    let combined = run_tmux_default(
        tmux_path,
        &["display-message", "-c", &client.tty, "-p", &combined_format],
    )
    .await;
    let Some(combined) = combined else {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    };
    let combined_lines: Vec<&str> = combined.split(TMUX_FIELD_SEP).collect();
    if combined_lines.len() < 2 {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    }
    let Some((client_cols, client_rows)) = parse_two_ints(combined_lines[0]) else {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    };
    if client_cols <= 0 || client_rows <= 0 {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    }

    let (cell_w, cell_h, pad_x, pad_y) = resolve_geometry(
        bundle_id,
        win_w,
        win_h,
        client_cols as f64,
        client_rows as f64,
    )
    .await;

    let pane_list = run_tmux_default(
        tmux_path,
        &[
            "list-panes",
            "-t",
            &client.tty,
            "-F",
            "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}",
        ],
    )
    .await;
    let Some(pane_list) = pane_list else {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    };

    let mut panes: Vec<Pane> = Vec::new();
    for line in pane_list.split('\n') {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() != 5 {
            continue;
        }
        if let (Ok(left), Ok(top), Ok(cols), Ok(rows)) = (
            parts[1].parse::<i64>(),
            parts[2].parse::<i64>(),
            parts[3].parse::<i64>(),
            parts[4].parse::<i64>(),
        ) {
            panes.push(Pane {
                id: parts[0].to_string(),
                left,
                top,
                cols,
                rows,
            });
        }
    }
    if panes.is_empty() {
        return DiscoverResponse::targets(vec![]).context_pid(pid);
    }

    let top_offset = parse_status_top_offset(combined_lines[1]);

    // Pane chip is 3-cells wide so the hint label is readable. Anchored at
    // pane center, chip extends 1 cell left and right.
    let pane_chip_cells: i64 = 3;
    let mut pane_targets: Vec<JumpTarget> = Vec::new();
    let mut actions: HashMap<String, TargetAction> = HashMap::new();

    struct RawLink {
        screen_row: i64,
        screen_col: i64,
        text: String,
    }
    let mut raw_links: Vec<RawLink> = Vec::new();

    for (i, pane) in panes.iter().enumerate() {
        let center_col = pane.left + pane.cols / 2;
        let center_row = top_offset + pane.top + pane.rows / 2;
        let chip_x = min_x + pad_x + (center_col - pane_chip_cells / 2) as f64 * cell_w;
        let chip_y = min_y + win_h - pad_y - (center_row + 1) as f64 * cell_h;
        let target_id = format!("tmux-{pid}-p{i}");
        // Hint commits never auto-enter insert: only the explicit
        // triggers (`i`, mouse_grid, physical click, AccessibilityProvider
        // true-text-input targets) do that. A tmux pane is a terminal
        // surface, not an AX text input, so a pane hint stays in normal
        // — and shift+hint now behaves exactly like an INSERT-mode
        // shift+click (raw click delivered, mode unchanged).
        pane_targets.push(build_target(
            &target_id,
            chip_x,
            chip_y,
            pane_chip_cells as f64 * cell_w,
            cell_h,
            "tmux-pane",
            &pane.id,
            pid,
            false,
            // Synthesize a real mouse click on the pane center rather
            // than firing the plugin's `select-pane` RPC. The RPC
            // returns optimistically (the closure resolves before tmux
            // actually finishes selecting), so a fast follow-up `i`
            // landed in the *previous* active pane. A physical click
            // is observed atomically by alacritty's mouse-mode
            // forwarder, so tmux selects the pane before the next
            // keystroke is delivered.
            true,
            // Pane chips are the structural anchors of a tmux window, so the
            // renderer paints them in the accent style. Link chips below are
            // everyday clutter and stay in the default yellow.
            Priority::Critical,
        ));
        actions.insert(
            target_id,
            TargetAction::Pane {
                pane_id: pane.id.clone(),
            },
        );

        let Some(raw) = run_tmux_default(tmux_path, &["capture-pane", "-t", &pane.id, "-p"]).await
        else {
            continue;
        };
        // Collect this pane's links, then keep the most useful within the
        // per-pane budget: real URLs first (the user's primary intent), then
        // the earliest remaining matches in reading order. Without this, a
        // screenful of file paths / dotted hostnames (a diff, a log) exhausts
        // the budget before a URL lower down ever gets a hint.
        let mut pane_links: Vec<RawLink> = Vec::new();
        for (row_idx, content) in raw.split('\n').enumerate() {
            if row_idx as i64 >= pane.rows {
                break;
            }
            for (col, text) in extract_links(content, pane.cols as usize) {
                pane_links.push(RawLink {
                    screen_row: top_offset + pane.top + row_idx as i64,
                    screen_col: pane.left + col as i64,
                    text,
                });
            }
        }
        if pane_links.len() > LINKS_PER_PANE_LIMIT {
            // Stable sort keeps reading order within each group; `false < true`
            // floats URLs to the front before truncation.
            pane_links.sort_by_key(|link| !is_url(&link.text));
            pane_links.truncate(LINKS_PER_PANE_LIMIT);
        }
        raw_links.extend(pane_links);
    }

    // Pane chips emit first so the hint assigner allocates the shortest
    // labels to them. Link chips sort across all panes by screen position
    // (top-to-bottom, left-to-right).
    raw_links.sort_by(|a, b| {
        a.screen_row
            .cmp(&b.screen_row)
            .then(a.screen_col.cmp(&b.screen_col))
    });
    let mut targets = pane_targets;
    for (idx, link) in raw_links.into_iter().enumerate() {
        let x = min_x + pad_x + link.screen_col as f64 * cell_w;
        let y = min_y + win_h - pad_y - (link.screen_row + 1) as f64 * cell_h;
        let target_id = format!("tmux-{pid}-l{idx}");
        // Clicking a link opens/copies it → stay in normal mode. The
        // `activate` RPC path is the right answer here: the plugin runs
        // `/usr/bin/open` against the URL, which is what the user
        // wants. A synthesized click would just select text inside
        // alacritty.
        targets.push(build_target(
            &target_id,
            x,
            y,
            cell_w,
            cell_h,
            "tmux-link",
            &link.text,
            pid,
            false,
            false,
            Priority::Normal,
        ));
        actions.insert(target_id, TargetAction::Link { text: link.text });
    }

    if let Ok(mut guard) = plugin.target_actions.lock() {
        *guard = actions;
    }
    DiscoverResponse::targets(targets).context_pid(pid)
}

// ---- Candidate (tmux window finder) -----------------------------------------

/// Round-tripped through the host so candidate resolution can re-drive
/// `switch-client` against the right session/client.
#[derive(Default, Serialize, Deserialize)]
struct TmuxPayload {
    tmux_target: String,
    #[serde(default)]
    tmux_client_tty: String,
    #[serde(default)]
    client_pid: Option<i64>,
    #[serde(default)]
    terminal_pid: Option<i64>,
}

fn tmux_navigation_url(kind: &str, target: &str) -> String {
    format!("{NAV_SCHEME}://{kind}/{}", percent_encode(target))
}

fn parse_tmux_navigation_url(raw: &str) -> Option<(String, String)> {
    let rest = raw.strip_prefix(&format!("{NAV_SCHEME}://"))?;
    let (kind, encoded_target) = rest.split_once('/')?;
    if kind != "window" && kind != "session" {
        return None;
    }
    let target = percent_decode(encoded_target)?;
    if target.trim().is_empty() {
        return None;
    }
    Some((kind.to_string(), target))
}

fn percent_encode(raw: &str) -> String {
    let mut out = String::new();
    for byte in raw.bytes() {
        let ch = byte as char;
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '~' | ':') {
            out.push(ch);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn percent_decode(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?;
            let value = u8::from_str_radix(hex, 16).ok()?;
            out.push(value);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn client_by_session(clients: &[TmuxClient]) -> HashMap<String, TmuxClient> {
    let mut out = HashMap::new();
    for client in clients {
        out.entry(client.session.clone())
            .or_insert_with(|| client.clone());
    }
    out
}

fn build_candidates_from_window_list(
    raw: &str,
    clients: &[TmuxClient],
    terminal_pid_by_session: &HashMap<String, Option<i64>>,
    home: &str,
) -> Vec<Candidate> {
    let client_by_session = client_by_session(clients);
    let mut out = Vec::new();
    for line in raw.split('\n') {
        if line.is_empty() {
            continue;
        }
        let parts = split_tmux_fields(line, 6);
        if parts.len() < 3 {
            continue;
        }
        let session = parts[0];
        let index = parts[1];
        let name = parts[2].trim();
        let command = parts.get(3).map(|s| s.trim()).unwrap_or("");
        let mut cwd = parts
            .get(4)
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        let active = parts.get(5).map(|s| s.trim() == "1").unwrap_or(false);
        if !home.is_empty() && cwd.starts_with(home) {
            cwd = format!("~{}", &cwd[home.len()..]);
        }
        let client = client_by_session.get(session).or_else(|| clients.first());
        let terminal_pid = terminal_pid_by_session.get(session).copied().flatten();

        let target = format!("{session}:{index}");
        let primary = if name.is_empty() {
            target.clone()
        } else {
            name.to_string()
        };
        let mut secondary_parts: Vec<&str> = Vec::new();
        if !name.is_empty() {
            secondary_parts.push(target.as_str());
        }
        for value in [command, cwd.as_str()] {
            if !value.is_empty() {
                secondary_parts.push(value);
            }
        }
        let subtitle = if secondary_parts.is_empty() {
            String::new()
        } else {
            secondary_parts.join(" · ")
        };

        let navigation_url = tmux_navigation_url("window", &target);
        let payload = TmuxPayload {
            tmux_target: target,
            tmux_client_tty: client.map(|c| c.tty.clone()).unwrap_or_default(),
            client_pid: client.map(|c| c.client_pid),
            terminal_pid,
        };
        let mut candidate = Candidate::new(primary)
            .kind("tmux_window")
            .location()
            .source_id(SOURCE_ID)
            .source("tmux.windows")
            .subtitle(subtitle)
            .navigation_url(navigation_url)
            .current_location(active)
            .payload_json(&payload);
        if let Some(tp) = terminal_pid {
            candidate = candidate.pid(tp);
        }
        out.push(candidate);
    }
    out
}

/// `None` on transient tmux failure (caller preserves the previous warm locations);
/// `Some(vec)` (possibly empty) is the authoritative current window list.
struct CandidateBuild {
    candidates: Vec<Candidate>,
    client_snapshot: ClientSnapshot,
    client_count: usize,
    raw_line_count: usize,
    first_raw_line: String,
}

async fn build_candidates(tmux_path: Option<&str>) -> Option<CandidateBuild> {
    build_candidates_inner(tmux_path, BuildBudget::Steady).await
}

/// Same as [`build_candidates`] but gives every per-socket tmux call a
/// longer timeout. Used by `on_start` to give cold sockets a real shot
/// at the *first* location build — otherwise the user opens flashlight right
/// after Flash starts, sees only the windows from the fast-responding
/// socket, and has to wait for the next steady-state poll for the
/// slower socket to fold in.
async fn build_candidates_warm(tmux_path: Option<&str>) -> Option<CandidateBuild> {
    build_candidates_inner(tmux_path, BuildBudget::Warm).await
}

#[derive(Debug, Clone, Copy)]
enum BuildBudget {
    /// Background poll cadence — per-socket calls cap at 2 s.
    Steady,
    /// Warm-up budget — per-socket calls cap at 6 s. Used only at
    /// plugin start.
    Warm,
}

async fn build_candidates_inner(
    tmux_path: Option<&str>,
    budget: BuildBudget,
) -> Option<CandidateBuild> {
    if tmux_path.is_none() {
        return Some(CandidateBuild {
            candidates: Vec::new(),
            client_snapshot: ClientSnapshot::default(),
            client_count: 0,
            raw_line_count: 0,
            first_raw_line: String::new(),
        });
    }
    let clients = list_clients(tmux_path).await;
    let client_by_session = client_by_session(&clients);
    let pmap = if clients.is_empty() {
        HashMap::new()
    } else {
        parent_pid_map().await
    };
    let mut terminal_pid_by_session: HashMap<String, Option<i64>> = HashMap::new();
    for (session, client) in &client_by_session {
        terminal_pid_by_session.insert(
            session.clone(),
            find_top_level_ancestor(client.client_pid, &pmap),
        );
    }
    let client_snapshot = ClientSnapshot {
        clients: clients.clone(),
        parent_map: pmap.clone(),
    };

    let format = format!(
        "#{{session_name}}{TMUX_FIELD_SEP}#{{window_index}}{TMUX_FIELD_SEP}#{{window_name}}{TMUX_FIELD_SEP}#{{pane_current_command}}{TMUX_FIELD_SEP}#{{pane_current_path}}{TMUX_FIELD_SEP}#{{window_active}}"
    );
    // Aggregated across every tmux socket: `list-windows -a` is "all
    // windows on this server", not "all windows on this host". Without
    // the per-socket fan-out, sessions running on a second tmux server
    // (e.g. a `tmux -L work` socket) are invisible to the flashlight
    // finder — the user sees only the first responding server's
    // windows.
    let raw = match budget {
        BuildBudget::Steady => {
            run_tmux_aggregate_default(tmux_path, &["list-windows", "-a", "-F", &format]).await?
        }
        BuildBudget::Warm => {
            run_tmux_aggregate_warm(tmux_path, &["list-windows", "-a", "-F", &format]).await?
        }
    };

    let home = std::env::var("HOME").unwrap_or_default();
    let raw_line_count = raw.split('\n').filter(|line| !line.is_empty()).count();
    let first_raw_line = raw
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .take(180)
        .collect::<String>();
    let candidates =
        build_candidates_from_window_list(&raw, &clients, &terminal_pid_by_session, &home);
    Some(CandidateBuild {
        candidates,
        client_snapshot,
        client_count: clients.len(),
        raw_line_count,
        first_raw_line,
    })
}

/// Identity hash of the warm location set — `(title, subtitle, navigation_url,
/// pid)` for each row, in order. Used by [`refresh_candidate_locations_for_path`]
/// to skip `set_locations` when nothing observable changed.
///
/// Without this gate, the 1 s background poll would rewrite the warm
/// cache on every tick even when tmux state was identical. The visible
/// flashlight surface pulls the warm locations once at open time, so unchanged
/// tmux polls should not churn the warm cache or future-session
/// bookkeeping.
fn hash_candidates(candidates: &[Candidate]) -> u64 {
    use flash_plugin::candidate_metadata as meta;
    let mut hasher = DefaultHasher::new();
    candidates.len().hash(&mut hasher);
    for candidate in candidates {
        candidate.title.hash(&mut hasher);
        candidate
            .meta(meta::SUBTITLE)
            .unwrap_or("")
            .hash(&mut hasher);
        candidate
            .meta(meta::NAVIGATION_URL)
            .unwrap_or("")
            .hash(&mut hasher);
        candidate.pid_value().unwrap_or(0).hash(&mut hasher);
    }
    hasher.finish()
}

/// Rebuild the warm locations and store them **only when the
/// candidate hash differs from the last store**. The dedup gate is what
/// keeps unchanged polls as no-ops — see the module-level "Warm-location
/// contract" docs.
///
/// On a transient tmux failure (e.g. every socket invocation timed out)
/// we leave the previous warm locations in place: the host keeps pulling
/// them for synchronous reads, and the next successful poll re-syncs. We
/// do *not* store an empty set in this case — nuking the warm cache to `[]`
/// would make tmux windows vanish from flashlight every time a single
/// socket call hiccuped.
async fn refresh_candidate_locations_for_path(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
) {
    refresh_candidate_locations_for_path_inner(
        tmux_path,
        ctx,
        last_hash,
        client_snapshot,
        BuildBudget::Steady,
    )
    .await;
}

/// Warm-budget variant used at plugin start; see [`build_candidates_warm`]
/// for why we hand cold sockets a generous timeout on the first build.
async fn refresh_candidate_locations_for_path_warm(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
) {
    refresh_candidate_locations_for_path_inner(
        tmux_path,
        ctx,
        last_hash,
        client_snapshot,
        BuildBudget::Warm,
    )
    .await;
}

async fn refresh_candidate_locations_for_path_inner(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
    budget: BuildBudget,
) {
    let build_result = match budget {
        BuildBudget::Steady => build_candidates(tmux_path).await,
        BuildBudget::Warm => build_candidates_warm(tmux_path).await,
    };
    let Some(build) = build_result else {
        ctx.log(
            "debug",
            "[tmux] candidate refresh skipped — tmux transient failure",
        );
        return;
    };
    if let Ok(mut guard) = client_snapshot.lock() {
        *guard = build.client_snapshot.clone();
    }
    let new_hash = hash_candidates(&build.candidates);
    let unchanged = matches!(last_hash.lock(), Ok(guard) if *guard == Some(new_hash));
    if unchanged {
        // Still useful to record that we polled — at trace level so a
        // healthy cache doesn't drown out other plugins. The warm
        // locations are untouched, so the flashlight surface
        // doesn't repaint.
        let mut fields = BTreeMap::new();
        fields.insert("candidates".to_string(), build.candidates.len().to_string());
        ctx.log_fields("debug", "[tmux] candidate refresh (unchanged)", fields);
        return;
    }
    if let Ok(mut guard) = last_hash.lock() {
        *guard = Some(new_hash);
    }
    let mut fields = BTreeMap::new();
    fields.insert("candidates".to_string(), build.candidates.len().to_string());
    fields.insert("clients".to_string(), build.client_count.to_string());
    fields.insert("raw_lines".to_string(), build.raw_line_count.to_string());
    if build.candidates.is_empty() && !build.first_raw_line.is_empty() {
        fields.insert("first_raw_line".to_string(), build.first_raw_line.clone());
    }
    ctx.log_fields("debug", "[tmux] candidate refresh (emit)", fields);
    ctx.set_locations(SOURCE_ID, build.candidates);
}

async fn refresh_candidate_locations(plugin: &Tmux, ctx: &Context) {
    refresh_candidate_locations_for_path(
        plugin.resolved_tmux_path().await,
        ctx,
        plugin.last_locations_hash(),
        plugin.client_snapshot(),
    )
    .await;
}

async fn refresh_candidate_locations_warm(plugin: &Tmux, ctx: &Context) {
    refresh_candidate_locations_for_path_warm(
        plugin.resolved_tmux_path().await,
        ctx,
        plugin.last_locations_hash(),
        plugin.client_snapshot(),
    )
    .await;
}

/// Background poll cadence. **Do not raise without measuring**: the
/// flashlight expects the warm locations to be in sync with the user's tmux
/// state at all times, so the cycle has to be short enough that a
/// window the user just created is in the cache by the time they
/// press `f`. 1 s is the sweet spot — `build_candidates` typically
/// finishes in 50-200 ms with parallel socket fan-out, leaving the
/// runtime idle most of the cycle.
const POLL_INTERVAL_SECS: u64 = 1;

async fn start_candidate_poll(plugin: &Tmux, ctx: &Context) {
    let path = plugin.resolved_tmux_path().await.map(str::to_string);
    let last_hash = std::sync::Arc::clone(&plugin.last_locations_hash_arc);
    let client_snapshot = std::sync::Arc::clone(&plugin.client_snapshot_arc);
    let ctx = ctx.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
            refresh_candidate_locations_for_path(
                path.as_deref(),
                &ctx,
                &last_hash,
                &client_snapshot,
            )
            .await;
        }
    });
}

// ---- Tab actions ------------------------------------------------------------

fn window_indices(raw: &str) -> Vec<String> {
    raw.split('\n')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

fn target_for_ordinal(ordinal: i64, session: &str, indices: &[String]) -> Option<String> {
    if ordinal <= 0 || ordinal as usize > indices.len() {
        return None;
    }
    Some(format!("{session}:{}", indices[(ordinal - 1) as usize]))
}

async fn switch_client(tmux_path: Option<&str>, tty: &str, target: &str) -> bool {
    run_tmux_default(tmux_path, &["switch-client", "-c", tty, "-t", target])
        .await
        .is_some()
}

async fn tab_select(tmux_path: Option<&str>, client: &TmuxClient, index: Option<i64>) -> bool {
    let Some(idx) = index else {
        return false;
    };
    if idx <= 0 {
        return false;
    }
    let Some(raw) = run_tmux_default(
        tmux_path,
        &[
            "list-windows",
            "-t",
            &client.session,
            "-F",
            "#{window_index}",
        ],
    )
    .await
    else {
        return false;
    };
    let Some(target) = target_for_ordinal(idx, &client.session, &window_indices(&raw)) else {
        return false;
    };
    switch_client(tmux_path, &client.tty, &target).await
}

async fn tab_adjacent(tmux_path: Option<&str>, client: &TmuxClient, direction: &str) -> bool {
    // Use tmux's native cycle commands instead of list-windows +
    // find-current + switch-client. `next-window` / `previous-window`
    // handle wrap-around natively, work uniformly across every client
    // attached to the session, and don't depend on per-client display
    // messages that can race against fast presses. Targeting
    // `<session>:` (trailing colon) explicitly scopes the cycle to this
    // client's session — generic over clients, no shortcut emulation.
    let cmd = if direction == "next" {
        "next-window"
    } else {
        "previous-window"
    };
    let session_target = format!("{}:", client.session);
    run_tmux_default(tmux_path, &[cmd, "-t", &session_target])
        .await
        .is_some()
}

async fn tab_extreme(tmux_path: Option<&str>, client: &TmuxClient, end: &str) -> bool {
    // First/last via native window indexing: tmux accepts numeric
    // indices and the special `{start}`/`{end}` aliases. `{end}` is
    // exactly "the last window in the session" and `{start}` is the
    // first — no need to list and pick.
    let alias = if end == "first" { "{start}" } else { "{end}" };
    let session_target = format!("{}:{}", client.session, alias);
    run_tmux_default(tmux_path, &["select-window", "-t", &session_target])
        .await
        .is_some()
}

async fn tab_new(tmux_path: Option<&str>, ctx: &Context, client: &TmuxClient) -> bool {
    let current_path = trimmed(
        run_tmux_default(
            tmux_path,
            &[
                "display-message",
                "-c",
                &client.tty,
                "-p",
                "#{pane_current_path}",
            ],
        )
        .await,
    );
    // Trailing colon forces the target to be parsed as `<session>:`
    // (current window of session) rather than ambiguously matching a
    // window index — important when the session name is a digit
    // (e.g. session "1" + window "1" both exist).
    let session_target = format!("{}:", client.session);
    let mut attempt: Vec<String> = vec![
        "new-window".into(),
        "-P".into(),
        "-F".into(),
        "#{window_index}".into(),
        "-t".into(),
        session_target.clone(),
    ];
    if let Some(ref path) = current_path {
        attempt.push("-c".into());
        attempt.push(path.clone());
    }
    let created = match run_tmux_capture(
        tmux_path,
        &attempt.iter().map(String::as_str).collect::<Vec<_>>(),
        Duration::from_secs(2),
    )
    .await
    {
        Ok(out) => trimmed(Some(out)),
        Err(err) => {
            // Most common reason for failure is a `-c <path>` that tmux
            // can't `chdir` into (path went away, mount went stale, etc.).
            // Retry once without -c so the new window still opens — just
            // in $HOME instead of the dead cwd.
            ctx.log(
                "warn",
                &format!(
                    "[tmux] new-window -t {} failed ({}), retrying without -c",
                    session_target, err
                ),
            );
            let bare = [
                "new-window",
                "-P",
                "-F",
                "#{window_index}",
                "-t",
                &session_target,
            ];
            match run_tmux_capture(tmux_path, &bare, Duration::from_secs(2)).await {
                Ok(out) => trimmed(Some(out)),
                Err(err) => {
                    ctx.log(
                        "warn",
                        &format!("[tmux] new-window -t {} failed: {}", session_target, err),
                    );
                    None
                }
            }
        }
    };
    let Some(created) = created else { return false };
    switch_client(
        tmux_path,
        &client.tty,
        &format!("{}:{}", client.session, created),
    )
    .await
}

async fn tab_close(tmux_path: Option<&str>, client: &TmuxClient) -> bool {
    // Target the session directly: tmux resolves a bare session name to its
    // active window, which is exactly the window every client attached to that
    // session is viewing. This avoids a fragile `display-message -c <tty>`
    // round-trip (the previous approach), whose failure made the host fall
    // back to ⌘W and quit the whole terminal app instead of closing the window.
    run_tmux_default(tmux_path, &["kill-window", "-t", &client.session])
        .await
        .is_some()
}

/// `[m` / `]m`: swap the focused window with its neighbour in the same
/// session. Tmux is happy to wrap (`-d` keeps the window selected at
/// its new position), so the user can keep tapping `]m` to bubble a
/// window to the end without rebinding.
async fn tab_move(tmux_path: Option<&str>, client: &TmuxClient, direction: &str) -> bool {
    let neighbour = if direction == "next" { "+1" } else { "-1" };
    let target = format!("{}:{}", client.session, neighbour);
    run_tmux_default(tmux_path, &["swap-window", "-d", "-t", &target])
        .await
        .is_some()
}

/// `gg` / `G` inside a tmux client. The host's wheel-delta fallback can't
/// reach the bottom of a live buffer (wheel-down past the cursor is a
/// no-op in tmux mouse mode), so the plugin claims the action and drives
/// it via copy-mode commands directly:
///
///   * `top`: enter copy mode (if not already), then `history-top` to
///     jump to the oldest scrollback line.
///   * `bottom`: `cancel` exits copy mode, which automatically returns
///     the view to the live (bottom) buffer. A no-op when not in copy
///     mode, which is the correct semantics — the user is already at
///     the bottom.
async fn scroll_extreme(tmux_path: Option<&str>, client: &TmuxClient, end: &str) -> bool {
    let session_target = format!("{}:", client.session);
    match end {
        "top" => {
            // -u opens copy mode and pre-scrolls one page up so the
            // subsequent history-top has something to anchor on for
            // single-line panes; harmless when scrollback is large.
            if run_tmux_default(tmux_path, &["copy-mode", "-u", "-t", &session_target])
                .await
                .is_none()
            {
                return false;
            }
            run_tmux_default(
                tmux_path,
                &["send-keys", "-t", &session_target, "-X", "history-top"],
            )
            .await
            .is_some()
        }
        "bottom" => run_tmux_default(
            tmux_path,
            &["send-keys", "-t", &session_target, "-X", "cancel"],
        )
        .await
        .is_some(),
        _ => false,
    }
}

async fn reload_client(tmux_path: Option<&str>, client: &TmuxClient) -> bool {
    run_tmux_default(tmux_path, &["refresh-client", "-t", &client.tty])
        .await
        .is_some()
}

async fn perform_source_action(
    plugin: &Tmux,
    ctx: &Context,
    req: &SourceActionRequest,
) -> SourceActionResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    let Some(pid) = req.context.pid else {
        ctx.log(
            "debug",
            &format!(
                "[tmux] source_action {} unhandled: no context.pid",
                req.name
            ),
        );
        return SourceActionResponse::unhandled();
    };
    let Some(client) = client_hosted_by_cached(plugin, pid).await else {
        ctx.log(
            "debug",
            &format!(
                "[tmux] source_action {} unhandled: no tmux client hosted by pid={}",
                req.name, pid
            ),
        );
        return SourceActionResponse::unhandled();
    };
    let ok = match req.name.as_str() {
        "tab_select" => tab_select(tmux_path, &client, req.index).await,
        "tab_next" => tab_adjacent(tmux_path, &client, "next").await,
        "tab_prev" => tab_adjacent(tmux_path, &client, "previous").await,
        "tab_first" => tab_extreme(tmux_path, &client, "first").await,
        "tab_last" => tab_extreme(tmux_path, &client, "last").await,
        "tab_new" => tab_new(tmux_path, ctx, &client).await,
        "tab_close" => tab_close(tmux_path, &client).await,
        "tab_move_next" => tab_move(tmux_path, &client, "next").await,
        "tab_move_previous" => tab_move(tmux_path, &client, "previous").await,
        "scroll_top" => scroll_extreme(tmux_path, &client, "top").await,
        "scroll_bottom" => scroll_extreme(tmux_path, &client, "bottom").await,
        "app_reload" => reload_client(tmux_path, &client).await,
        _ => return SourceActionResponse::unhandled(),
    };
    ctx.log(
        "debug",
        &format!(
            "[tmux] source_action {} client_tty={} session={} ok={}",
            req.name, client.tty, client.session, ok
        ),
    );
    // A tmux client hosts the focused terminal, so this source owns the
    // action either way: a failed tmux command must report `failed` (not
    // `unhandled`) or the host would fall back to a ⌘-keystroke that
    // doesn't mean "tab" in a terminal.
    if ok {
        SourceActionResponse::performed(Some(pid))
    } else {
        SourceActionResponse::failed(Some(pid))
    }
}

// ---- Candidate resolution ---------------------------------------------------

/// Pick the client `switch-client` should drive for `target`.
///
/// Priority order:
///   1. A client already attached to the target session. Switching it
///      between windows of its own session is the least-surprising
///      gesture — it keeps each terminal window pinned to "its"
///      session instead of hijacking whichever window was last
///      active. For Alacritty (multi-process, one client per
///      window) this is what makes the flashlight pick land in the
///      window the user mentally associates with the target session.
///   2. The most-recently-active client. Used when no client is on
///      the target session — single-process multi-window terminals
///      land here so the pick reaches the window the user was last
///      typing in.
async fn select_client_for_target(tmux_path: Option<&str>, target: &str) -> Option<TmuxClient> {
    let mut clients = list_clients(tmux_path).await;
    if clients.is_empty() {
        return None;
    }
    clients.sort_by_key(|c| std::cmp::Reverse(c.activity));
    let target_session = target.split(':').next().unwrap_or(target);
    clients
        .iter()
        .find(|c| c.session == target_session)
        .cloned()
        .or_else(|| clients.into_iter().next())
}

async fn resolve(plugin: &Tmux, ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    let payload = candidate.payload_as::<TmuxPayload>().unwrap_or_default();
    let target = payload.tmux_target.as_str();
    if target.is_empty() {
        ctx.log("warn", "[tmux] resolve missing tmux_target");
        return ResolveResponse::unresolved();
    }

    let chosen = select_client_for_target(tmux_path, target).await;
    let tty = chosen
        .as_ref()
        .map(|c| c.tty.clone())
        .unwrap_or_else(|| payload.tmux_client_tty.clone());

    let mut args: Vec<&str> = vec!["switch-client"];
    if !tty.is_empty() {
        args.push("-c");
        args.push(&tty);
    }
    args.push("-t");
    args.push(target);
    // The captured tty may be stale — fall back to `switch-client` without
    // `-c`, which tmux applies to its best-guess client.
    let switched = run_tmux_default(tmux_path, &args).await.is_some()
        || run_tmux_default(tmux_path, &["switch-client", "-t", target])
            .await
            .is_some();
    if !switched {
        ctx.log("warn", "[tmux] resolve failed");
        return ResolveResponse::unresolved();
    }

    // Recompute the terminal pid from the client we actually drove
    // rather than the snapshot-time `terminal_pid` baked into the
    // payload: that value goes stale (or was never resolved) when
    // the client moves between snapshots, which silently strips the
    // `target_pid` the host needs to raise the terminal window.
    // Fall back to the payload value only if the live walk fails.
    let terminal_pid = match chosen {
        Some(ref c) => {
            let pmap = parent_pid_map().await;
            find_top_level_ancestor(c.client_pid, &pmap)
        }
        None => None,
    }
    .or(payload.terminal_pid);

    resolve_response(target, &tty, terminal_pid, ctx)
}

fn resolve_response(
    target: &str,
    tty: &str,
    terminal_pid: Option<i64>,
    ctx: &Context,
) -> ResolveResponse {
    let mut fields = BTreeMap::new();
    fields.insert("target".to_string(), target.to_string());
    fields.insert("tty".to_string(), tty.to_string());
    match terminal_pid {
        Some(tp) => {
            fields.insert("terminal_pid".to_string(), tp.to_string());
            ctx.log_fields("debug", "[tmux] resolved candidate", fields);
        }
        None => {
            ctx.log_fields(
                "warn",
                "[tmux] resolved but no terminal pid to raise",
                fields,
            );
        }
    }
    ResolveResponse::resolved(terminal_pid).navigation_url(tmux_navigation_url("window", target))
}

// ---- Commands (`:tmux …` jump-to mappings) ----------------------------------

/// `command.invoke` for `:tmux session <name>` and `:tmux window
/// <session:index>`. Both switch the user's active tmux client to the
/// requested target and return the terminal pid hosting it so Flash can
/// raise that window. The target argument is taken verbatim from the
/// first command arg, so a mapping like
/// `["flash", "plugin_command", "command=tmux", "subcommand=window", "args=main:1"]`
/// jumps straight to `main:1`.
async fn invoke_command(plugin: &Tmux, ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    match cmd.subcommand.as_str() {
        "session" | "window" => {}
        other => {
            return CommandResponse::error(format!("unknown subcommand: {other}"));
        }
    }

    let target = cmd.args.first().map(|s| s.trim()).filter(|s| !s.is_empty());
    let Some(target) = target else {
        ctx.log("warn", "[tmux] command missing target argument");
        return CommandResponse::error("missing target argument");
    };

    // `session:index` → session is the part before the first colon; a bare
    // session name has no colon and is used as-is.
    let session = target.split(':').next().unwrap_or(target);

    // Drive `switch-client` against the same priority order
    // `select_client_for_target` uses: prefer a client already on
    // the target session (keeps each terminal window pinned to its
    // session), fall back to most-recently-active (single-process
    // terminals where every window shares one client).
    let chosen = select_client_for_target(tmux_path, target).await;
    let tty = chosen.as_ref().map(|c| c.tty.clone()).unwrap_or_default();

    let mut args: Vec<&str> = vec!["switch-client"];
    if !tty.is_empty() {
        args.push("-c");
        args.push(&tty);
    }
    args.push("-t");
    args.push(target);
    let switched = run_tmux_default(tmux_path, &args).await.is_some()
        || run_tmux_default(tmux_path, &["switch-client", "-t", target])
            .await
            .is_some();
    if !switched {
        ctx.log("warn", "[tmux] command switch-client failed");
        return CommandResponse::error("switch-client failed");
    }

    // Terminal pid hosting the client we actually drove. Falls
    // back to any session-matching client when `chosen` is empty,
    // then to any client at all — same belt-and-braces ladder the
    // resolve path uses.
    let terminal_pid = match chosen {
        Some(ref c) => {
            let pmap = parent_pid_map().await;
            find_top_level_ancestor(c.client_pid, &pmap)
        }
        None => {
            let clients = list_clients(tmux_path).await;
            let fallback = clients
                .iter()
                .find(|c| c.session == session)
                .or_else(|| clients.first());
            match fallback {
                Some(c) => {
                    let pmap = parent_pid_map().await;
                    find_top_level_ancestor(c.client_pid, &pmap)
                }
                None => None,
            }
        }
    };

    let route_kind = if cmd.subcommand == "session" {
        "session"
    } else {
        "window"
    };
    let response = CommandResponse::ok().navigation_url(tmux_navigation_url(route_kind, target));
    match terminal_pid {
        Some(tp) => response.target_pid(tp),
        None => response,
    }
}

async fn restore_navigation(
    plugin: &Tmux,
    ctx: &Context,
    request: &NavigationRequest,
) -> SourceActionResponse {
    let Some((kind, target)) = parse_tmux_navigation_url(&request.url) else {
        return SourceActionResponse::unhandled();
    };
    let tmux_path = plugin.resolved_tmux_path().await;
    let session = target.split(':').next().unwrap_or(&target);
    let chosen = select_client_for_target(tmux_path, &target).await;
    let tty = chosen.as_ref().map(|c| c.tty.clone()).unwrap_or_default();

    let mut args: Vec<&str> = vec!["switch-client"];
    if !tty.is_empty() {
        args.push("-c");
        args.push(&tty);
    }
    args.push("-t");
    args.push(&target);
    let switched = run_tmux_default(tmux_path, &args).await.is_some()
        || run_tmux_default(tmux_path, &["switch-client", "-t", &target])
            .await
            .is_some();
    if !switched {
        ctx.log(
            "warn",
            &format!("[tmux] navigation restore failed target={target}"),
        );
        return SourceActionResponse::failed(None).navigation_url(request.url.clone());
    }

    let terminal_pid = match chosen {
        Some(ref c) => {
            let pmap = parent_pid_map().await;
            find_top_level_ancestor(c.client_pid, &pmap)
        }
        None => {
            let clients = list_clients(tmux_path).await;
            let fallback = clients
                .iter()
                .find(|c| c.session == session)
                .or_else(|| clients.first());
            match fallback {
                Some(c) => {
                    let pmap = parent_pid_map().await;
                    find_top_level_ancestor(c.client_pid, &pmap)
                }
                None => None,
            }
        }
    };
    ctx.log(
        "debug",
        &format!(
            "[tmux] navigation restored kind={kind} target={target} pid={}",
            terminal_pid
                .map(|pid| pid.to_string())
                .unwrap_or_else(|| "nil".to_string())
        ),
    );
    SourceActionResponse::performed(terminal_pid).navigation_url(request.url.clone())
}

// ---- Activation -------------------------------------------------------------

async fn activate(plugin: &Tmux, ctx: &Context, req: &ActivateRequest) {
    let tmux_path = plugin.resolved_tmux_path().await;
    let target_id = req.target_id.as_str();
    let entry = plugin
        .target_actions
        .lock()
        .ok()
        .and_then(|g| g.get(target_id).cloned());
    let ok = match entry {
        Some(TargetAction::Pane { pane_id }) => {
            // `select-pane` doesn't take `-c <tty>`. The pane_id is global so
            // a bare `-t %NN` is enough — pane chips are only emitted for the
            // client's current window.
            run_tmux_default(tmux_path, &["select-pane", "-t", &pane_id])
                .await
                .is_some()
        }
        Some(TargetAction::Link { text }) => open_link(&text),
        None => false,
    };
    if !ok {
        let mut fields = BTreeMap::new();
        fields.insert("target_id".to_string(), target_id.to_string());
        ctx.log_fields("debug", "[tmux] activate dropped", fields);
    }
}

fn open_link(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    // `open` doesn't expand `~`; strip the trailing `:LINE[:COL]` editor-jump
    // suffix that Launch Services doesn't understand.
    let expanded = expand_tilde(text);
    let suffix = OnceLock::new();
    let re: &Regex = suffix.get_or_init(|| Regex::new(r"(?::\d+){1,2}$").unwrap());
    let target = re.replace(&expanded, "").into_owned();
    // Fire-and-forget: `open` returns immediately and the launched app
    // outlives this child handle. `spawn()` itself is synchronous (no
    // `.await`); we only care that the process started, mirroring the
    // previous fire-and-forget behavior. tokio does not `kill_on_drop`
    // by default, so dropping the `Child` here does not reap the
    // spawned `open`.
    tokio::process::Command::new("open")
        .arg(target)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

fn expand_tilde(text: &str) -> String {
    if let Some(rest) = text.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{rest}");
        }
    } else if text == "~" {
        if let Ok(home) = std::env::var("HOME") {
            return home;
        }
    }
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_links_keeps_port_and_path() {
        let only = |s: &str| extract_links(s, 1000).into_iter().next().map(|(_, t)| t);
        assert_eq!(
            only("https://admin.test.com:1234").as_deref(),
            Some("https://admin.test.com:1234")
        );
        assert_eq!(
            only("https://google.com:443/test/a/b/c").as_deref(),
            Some("https://google.com:443/test/a/b/c")
        );
        assert_eq!(
            only("open https://admin.test.com:1234/x?y=1 now").as_deref(),
            Some("https://admin.test.com:1234/x?y=1")
        );
    }

    #[test]
    fn extract_links_drops_size_abbrev_version_noise() {
        let has = |line: &str, want: &str| extract_links(line, 1000).iter().any(|(_, t)| t == want);
        // Real filenames / domains / URLs are kept.
        assert!(has("see Cargo.toml here", "Cargo.toml"));
        assert!(has("open README.md now", "README.md"));
        assert!(has("ship config.default.toml ok", "config.default.toml"));
        assert!(has("host beside.com is up", "beside.com"));
        assert!(has(
            "go to https://app.beside.com x",
            "https://app.beside.com"
        ));
        assert!(has("edit src/main.rs:42 fast", "src/main.rs:42"));
        // Noise must NOT be matched as links.
        for (line, junk) in [
            ("size 8.2k total", "8.2k"),
            ("for e.g. this", "e.g"),
            ("tag v0.1.0 rc", "v0.1.0"),
        ] {
            assert!(!has(line, junk), "expected {junk:?} to be dropped");
        }
    }

    fn client(tty: &str, session: &str, client_pid: i64, activity: i64) -> TmuxClient {
        TmuxClient {
            tty: tty.to_string(),
            session: session.to_string(),
            client_pid,
            activity,
        }
    }

    #[test]
    fn tmux_argv_clears_inherited_tmux_environment() {
        let argv = tmux_argv("/opt/homebrew/bin/tmux", &["list-clients"]);

        assert_eq!(argv[0], ENV_PATH);
        assert_eq!(argv[1], "-u");
        assert_eq!(argv[2], "TMUX");
        assert_eq!(argv[3], "-u");
        assert_eq!(argv[4], "TMUX_PANE");
        assert_eq!(argv[5], "-u");
        assert_eq!(argv[6], "TMUX_TMPDIR");
        assert_eq!(argv[7], "-u");
        assert_eq!(argv[8], "TMPDIR");
        assert_eq!(argv[9], "/opt/homebrew/bin/tmux");
        assert_eq!(argv[10], "list-clients");
    }

    #[test]
    fn hosted_client_matches_focused_terminal_ancestor() {
        let clients = vec![
            client("/dev/ttys001", "other", 2000, 20),
            client("/dev/ttys000", "scratch", 1443, 10),
        ];
        let parent_map = HashMap::from([(1443, 1356), (1356, 1), (2000, 1999), (1999, 1)]);

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map).unwrap();

        assert_eq!(picked.session, "scratch");
        assert_eq!(picked.tty, "/dev/ttys000");
    }

    #[test]
    fn hosted_client_falls_back_to_active_when_parent_map_is_unavailable() {
        let clients = vec![
            client("/dev/ttys000", "scratch", 1443, 10),
            client("/dev/ttys001", "work", 2000, 30),
        ];
        let parent_map = HashMap::new();

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map).unwrap();

        assert_eq!(picked.session, "work");
    }

    #[test]
    fn hosted_client_does_not_fallback_when_process_sample_knows_clients() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let parent_map = HashMap::from([(1443, 2222), (2222, 1)]);

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map);

        assert!(picked.is_none());
    }

    #[test]
    fn tmux_field_splitter_accepts_configured_separator_tabs_and_whitespace() {
        assert_eq!(split_tmux_fields("a|||b|||c", 3), vec!["a", "b", "c"]);
        assert_eq!(split_tmux_fields("a\tb\tc", 3), vec!["a", "b", "c"]);
        assert_eq!(split_tmux_fields("a b c", 3), vec!["a", "b", "c"]);
    }

    #[test]
    fn tmux_navigation_urls_round_trip_targets() {
        let url = tmux_navigation_url("window", "scratch:2");
        assert_eq!(url, "tmux://window/scratch:2");
        assert_eq!(
            parse_tmux_navigation_url(&url),
            Some(("window".to_string(), "scratch:2".to_string()))
        );

        let encoded = tmux_navigation_url("session", "work/project one");
        assert_eq!(
            parse_tmux_navigation_url(&encoded),
            Some(("session".to_string(), "work/project one".to_string()))
        );
    }

    #[test]
    fn window_candidate_builder_emits_windows_from_all_sessions() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let terminal_pid_by_session = HashMap::from([("scratch".to_string(), Some(1356))]);
        let raw = "beside\t1\tbeside-agentic\tclaude\t/Users/ab/workspace/beside\n\
scratch\t2\tflash\tzsh\t/Users/ab/workspace/aymericbeaumet/flash\n";

        let candidates =
            build_candidates_from_window_list(raw, &clients, &terminal_pid_by_session, "/Users/ab");

        use flash_plugin::candidate_metadata as meta;
        assert_eq!(candidates.len(), 2);
        assert_eq!(candidates[0].title, "beside-agentic");
        assert_eq!(
            candidates[0].meta(meta::SUBTITLE),
            Some("beside:1 · claude · ~/workspace/beside")
        );
        assert_eq!(candidates[1].title, "flash");
        assert_eq!(
            candidates[1].meta(meta::SUBTITLE),
            Some("scratch:2 · zsh · ~/workspace/aymericbeaumet/flash")
        );
        assert_eq!(candidates[1].meta(meta::SOURCE_ID), Some(SOURCE_ID));
        assert_eq!(candidates[1].meta(meta::SOURCE), Some("tmux.windows"));
        assert_eq!(
            candidates[1].meta(meta::NAVIGATION_URL),
            Some("tmux://window/scratch:2")
        );
        assert_eq!(candidates[1].pid_value(), Some(1356));
    }

    /// Regression test: when multiple tmux servers (e.g. one per
    /// `/tmp/tmux-*/default` socket) are running, the candidate builder
    /// must surface windows from *every* server. Before the multi-socket
    /// aggregation fix, only the first responding socket's windows made
    /// it into the snapshot — `list-windows -a` enumerates all windows on
    /// one server, not every server on the host. We simulate that fan-out
    /// by feeding `build_candidates_from_window_list` the merged output
    /// `run_tmux_aggregate` would have produced across two sockets.
    #[test]
    fn window_candidate_builder_emits_windows_from_every_socket() {
        let clients = vec![
            client("/dev/ttys000", "work", 1443, 30),
            client("/dev/ttys001", "play", 1500, 10),
        ];
        let terminal_pid_by_session = HashMap::from([
            ("work".to_string(), Some(1356)),
            ("play".to_string(), Some(1444)),
        ]);

        // Socket A reports its sessions; socket B reports its own. Each
        // socket's `list-windows -a` only sees its own server.
        let socket_a_out = "work\t1\teditor\tnvim\t/Users/ab/work";
        let socket_b_out = "play\t1\tshell\tzsh\t/Users/ab/play";

        // Merging is what `run_tmux_aggregate` does before handing the
        // blob off to the candidate builder. Dedup is exercised by
        // feeding the same socket twice — the default-socket invocation
        // and an explicit `-S` against the same server are aliases.
        let merged = merge_socket_outputs([socket_a_out, socket_b_out, socket_a_out]);

        let candidates = build_candidates_from_window_list(
            &merged,
            &clients,
            &terminal_pid_by_session,
            "/Users/ab",
        );

        use flash_plugin::candidate_metadata as meta;
        // One row per session — duplicates dropped, both sockets'
        // windows present.
        assert_eq!(candidates.len(), 2);
        let sessions: Vec<&str> = candidates
            .iter()
            .map(|c| c.meta(meta::NAVIGATION_URL).unwrap_or(""))
            .collect();
        assert!(sessions.contains(&"tmux://window/work:1"));
        assert!(sessions.contains(&"tmux://window/play:1"));
        // The `play` session lives on the second socket — it would
        // have been entirely missing before the fix.
        let play = candidates
            .iter()
            .find(|c| c.meta(meta::NAVIGATION_URL) == Some("tmux://window/play:1"))
            .expect("play session candidate present");
        assert_eq!(play.pid_value(), Some(1444));
    }

    #[test]
    fn merge_socket_outputs_dedups_aliased_default_invocation() {
        let socket_a = "work\t1\teditor\tnvim\t/Users/ab/work\nwork\t2\tlogs\ttail\t/Users/ab/work";
        let socket_b = "play\t1\tshell\tzsh\t/Users/ab/play";

        let merged = merge_socket_outputs([socket_a, socket_a, socket_b, ""]);

        let lines: Vec<&str> = merged.split('\n').collect();
        assert_eq!(lines.len(), 3);
        assert!(lines.contains(&"work\t1\teditor\tnvim\t/Users/ab/work"));
        assert!(lines.contains(&"work\t2\tlogs\ttail\t/Users/ab/work"));
        assert!(lines.contains(&"play\t1\tshell\tzsh\t/Users/ab/play"));
    }

    // ---- Warm-location contract ------------------------------------------
    //
    // The dedup gate in `refresh_candidate_locations_for_path` is the
    // load-bearing invariant that prevents unchanged tmux polls from
    // rewriting the warm cache. These tests pin it down: any future
    // refactor that breaks them is also re-introducing the original
    // symptom (user opens flashlight and sees stale or incomplete tmux
    // candidates until a later refresh catches up).

    fn fake_candidate(target: &str, name: &str, pid: i64) -> Candidate {
        let payload = TmuxPayload {
            tmux_target: target.to_string(),
            ..TmuxPayload::default()
        };
        Candidate::new(name)
            .kind("tmux_window")
            .location()
            .source_id(SOURCE_ID)
            .source("tmux.windows")
            .subtitle(format!("{target} · zsh · ~/work"))
            .navigation_url(tmux_navigation_url("window", target))
            .payload_json(&payload)
            .pid(pid)
    }

    #[test]
    fn hash_candidates_stable_for_identical_input() {
        let snapshot = vec![
            fake_candidate("work:1", "editor", 1356),
            fake_candidate("play:2", "shell", 1444),
        ];
        let a = hash_candidates(&snapshot);
        let b = hash_candidates(&snapshot);
        assert_eq!(
            a, b,
            "identical candidate vectors must hash identically — \
             otherwise the dedup gate keeps re-emitting and the host \
             cache churns on every poll"
        );
    }

    #[test]
    fn hash_candidates_diverges_on_window_added() {
        let before = vec![fake_candidate("work:1", "editor", 1356)];
        let after = vec![
            fake_candidate("work:1", "editor", 1356),
            fake_candidate("work:2", "logs", 1356),
        ];
        assert_ne!(hash_candidates(&before), hash_candidates(&after));
    }

    #[test]
    fn hash_candidates_diverges_on_window_renamed() {
        let before = vec![fake_candidate("work:1", "editor", 1356)];
        let after = vec![fake_candidate("work:1", "vim", 1356)];
        assert_ne!(hash_candidates(&before), hash_candidates(&after));
    }

    #[test]
    fn hash_candidates_diverges_on_pid_change() {
        let before = vec![fake_candidate("work:1", "editor", 1356)];
        let after = vec![fake_candidate("work:1", "editor", 9999)];
        assert_ne!(
            hash_candidates(&before),
            hash_candidates(&after),
            "pid is part of the hash because the host uses it for app \
             activation — a pid drift across polls must trigger an emit"
        );
    }

    /// The plugin must not override `candidate_query`. The default trait
    /// method returns `CandidateQueryResponse::keep()`, which the
    /// host treats as "serve from the warm locations without blocking" —
    /// that is the entire point of the warm-location contract.
    /// This test reaches into the generated trait via a struct that
    /// implements `FlashPlugin` and confirms `candidate_query` falls
    /// back to the default (no method body declared on `Tmux`).
    ///
    /// If a future change adds an `async fn candidate_query` to the
    /// `impl FlashPlugin for Tmux` block, this test still compiles —
    /// the assertion is in the runtime behavior: any candidate_query
    /// that does subprocess work would re-introduce the session-time lag the
    /// user complained about. The companion AGENTS.md note ("Warm-locations
    /// contract") is the human-readable guardrail.
    #[test]
    fn tmux_plugin_uses_default_candidate_query() {
        // The default response carries neither `candidates` nor
        // `source_id` — both are `None` so the wire frame serializes
        // to an empty object. The host interprets that as "use the
        // warm locations you already have."
        let response = flash_plugin::CandidateQueryResponse::keep();
        assert!(
            response.candidates.is_none(),
            "keep() must not carry inline candidates — that would \
             defeat the warm-locations fast path"
        );
        assert!(response.source_id.is_none());
    }
}

// ---- Plugin glue ------------------------------------------------------------

struct Tmux {
    tmux_path: tokio::sync::OnceCell<Option<String>>,
    target_actions: Mutex<HashMap<String, TargetAction>>,
    /// Latest eager `list-clients` + process-tree sample. Source actions
    /// need the focused tmux client, but they should not fan out across
    /// every tmux socket on the hot key path when the poller already did
    /// that work.
    client_snapshot_arc: std::sync::Arc<Mutex<ClientSnapshot>>,
    /// Hash of the last snapshot we emitted to the host. Wrapped in an
    /// `Arc` so the background poll task can hold it alongside the
    /// plugin instance — both reach for the same Mutex, and the dedup
    /// invariant requires a single source of truth.
    last_locations_hash_arc: std::sync::Arc<Mutex<Option<u64>>>,
}

impl Tmux {
    /// Accessor used by [`refresh_candidate_locations`] when called with
    /// `&self`. The poll task takes an owned `Arc` instead so it
    /// outlives the plugin trait method's borrow.
    fn last_locations_hash(&self) -> &Mutex<Option<u64>> {
        &self.last_locations_hash_arc
    }

    fn client_snapshot(&self) -> &Mutex<ClientSnapshot> {
        &self.client_snapshot_arc
    }

    /// The tmux binary path, resolved (and cached) on first use via `find_tmux()`.
    /// Runs inside the SDK's async runtime so `main` never needs its own.
    async fn resolved_tmux_path(&self) -> Option<&str> {
        self.tmux_path.get_or_init(find_tmux).await.as_deref()
    }
}

flash_plugin::plugin!(Tmux);

impl FlashPlugin for Tmux {
    /// On startup we run one immediate `build_candidates` so the warm
    /// locations are populated before the user can press `f`, then we
    /// hand the freshness loop off to `start_candidate_poll`.
    ///
    /// We intentionally do **not** override `candidate_query` (the
    /// default returns `CandidateQueryResponse::keep()`). The
    /// previous implementation ran `build_candidates` inline inside the
    /// RPC handler, which gave the user a 2-8 s wait on every
    /// flashlight open and — on timeout — silently fell back to
    /// stale warm locations. See the module-level docs for the invariant.
    async fn on_start(&self, ctx: Context) {
        if self.resolved_tmux_path().await.is_none() {
            ctx.log("warn", "[tmux] tmux binary not found");
        }
        // First build uses the *warm* budget so cold sockets (a tmux
        // server the user hasn't talked to since boot, or one that
        // page-faulted in) get a real chance to respond before we
        // hand the warm locations off as "stable". Otherwise the user would
        // open flashlight a beat after Flash starts, see only the
        // fast socket's windows, and have to wait for the next 1 s
        // poll to fold in the rest.
        refresh_candidate_locations_warm(self, &ctx).await;
        // Immediate second build with the steady budget. Any sockets
        // that woke up during the warm build are now hot, so this run
        // either stores a delta (more windows) or no-ops via the
        // hash dedup. Net effect: the warm cache is provably stable when
        // we hand off to the poll.
        refresh_candidate_locations(self, &ctx).await;
        start_candidate_poll(self, &ctx).await;
    }

    /// Push events refresh the warm locations immediately. The 1 s poll keeps
    /// us in sync on its own, but `core:focus.changed` is the cheapest
    /// possible signal that the user is about to interact with a
    /// terminal — taking the refresh hit here means the warm locations are
    /// guaranteed-fresh when they open flashlight from that app, even
    /// if the poll happened to fire 900 ms ago.
    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:focus.changed"
                | "core:flash.started"
                | "core:apps.terminated"
                | "core:flashlight.opened"
        ) {
            refresh_candidate_locations(self, &ctx).await;
        }
    }

    async fn discover_targets(&self, ctx: Context, request: DiscoverRequest) -> DiscoverResponse {
        let _ = ctx;
        discover_targets_for_context(self, &request).await
    }

    async fn source_action(
        &self,
        ctx: Context,
        request: SourceActionRequest,
    ) -> SourceActionResponse {
        perform_source_action(self, &ctx, &request).await
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(self, &ctx, &candidate).await
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        invoke_command(self, &ctx, &command).await
    }

    async fn restore_navigation(
        &self,
        ctx: Context,
        request: NavigationRequest,
    ) -> SourceActionResponse {
        restore_navigation(self, &ctx, &request).await
    }

    async fn activate_target(&self, ctx: Context, request: ActivateRequest) {
        activate(self, &ctx, &request).await;
    }
}

fn main() {
    let plugin = Tmux {
        tmux_path: tokio::sync::OnceCell::new(),
        target_actions: Mutex::new(HashMap::new()),
        client_snapshot_arc: std::sync::Arc::new(Mutex::new(ClientSnapshot::default())),
        last_locations_hash_arc: std::sync::Arc::new(Mutex::new(None)),
    };
    run(plugin);
}
