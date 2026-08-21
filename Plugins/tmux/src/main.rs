//! Tmux plugin — ports the former Python tmux plugin to Rust.
//!
//! ## Warm-catalog contract
//!
//! Tmux exposes no native host event stream for window-list changes (no
//! `core:focus.changed`-style ping fires when the user creates/renames/
//! closes a window inside an attached client). The plugin therefore keeps
//! the catalog warm with a background refresh loop:
//!
//!   1. `on_start` builds and publishes the initial rows, then a 1 s
//!      background poll keeps them current. The candidate hash gates
//!      publishes, so unchanged refreshes are true no-ops.
//!   2. Host events (`core:focus.changed`, `core:apps.terminated`) trigger an
//!      additional refresh at explicit interaction boundaries.
//!   3. The flashlight reads the host-owned store fed by `publish`; no tmux
//!      I/O ever rides the hot path.
//!   4. Each refresh also retains its `list-clients` + process tree
//!      sample. The expensive host-wide process tree is reused while the tmux
//!      client pid set is unchanged. Hint discovery and repeatable source
//!      actions consult that warm cache first; the actions validate only the
//!      cached client's live session, so `[t` / `]t` avoid a host-wide `ps`
//!      and all-socket rediscovery before changing windows.
//!   5. Each successful local refresh also derives the attached-client
//!      session/window/pane statusbar segments (`#{plugin:tmux.session}` /
//!      `.window` / `.pane`) from the same inventory and emits the `status`
//!      notification only when the values change.
//!
//! Per-socket subprocess fan-out (`list-clients`, `list-windows -a`) and
//! per-host SSH inventory refreshes run concurrently so one slow socket or
//! remote host cannot make every independent backend wait behind it.
//!
//! ## Hint discovery
//!
//! On each activation Flash calls `hints` with the focused app's pid +
//! window frame; the plugin returns pane-chip and link-chip targets in
//! screen coordinates.
//!
//! Geometry mirrors the previous implementation:
//!   - cell size = window / cells (fallback) OR alacritty-style font
//!     metrics when alacritty.toml exposes the font (NSFont
//!     ascender/descender/advance via objc2).
//!   - pane chips: 3-cell-wide rect at pane centre.
//!   - link chips: per-regex match in `capture-pane -p` output.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::hash::{Hash, Hasher};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use flash_plugin::{
    run, ActionRequest, Candidate, CandidateEffect, CommandRequest, Context, Event, Frame,
    HintsRequest, HintsResponse, JumpTarget, NavigateRequest, PerformResponse, Priority,
    TERMINAL_LINK_ROLE,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use flash_plugin::process as bounded_process;

const SUBPROCESS_STDOUT_LIMIT: usize = 8 * 1024 * 1024;
const SUBPROCESS_STDERR_LIMIT: usize = 64 * 1024;
const SOURCE_WINDOWS: &str = "tmux.windows";
const NAV_SCHEME: &str = "tmux";
const PANE_TARGET_ROLE: &str = "tmux-pane";
const TMUX_TARGET_ENTERS_INSERT_MODE: bool = false;

const TMUX_PREFIXES: [&str; 4] = ["/opt/homebrew", "/usr/local", "/opt/local", "/usr"];
const ENV_PATH: &str = "/usr/bin/env";
const HOSTNAME_PATH: &str = "/bin/hostname";
const ID_PATH: &str = "/usr/bin/id";
const PS_PATH: &str = "/bin/ps";
const SSH_PATH: &str = "/usr/bin/ssh";
const TMUX_FIELD_SEP: &str = "|||";

const LINKS_PER_PANE_LIMIT: usize = 40;
const ALACRITTY_BUNDLES: [&str; 2] = ["org.alacritty", "io.alacritty"];
const SLOW_CANDIDATE_REFRESH_MS: u128 = 1_000;
const REMOTE_POLL_INTERVAL_SECS: u64 = 5;
const REMOTE_RETRY_DELAYS_SECS: [u64; 3] = [15, 30, 60];
// Keep the last good remote inventory through the complete retry ramp, but do
// not present it as current forever when the SSH side channel behind an active
// Mosh transport stays unavailable.
const REMOTE_CANDIDATE_STALE_AFTER_SECS: u64 = 120;

// ---- Link extraction --------------------------------------------------------

fn link_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Quoted shell-style paths (which may contain spaces / Unicode) · URLs ·
        // $VAR / ${VAR} shell-style env-prefixed paths · ~/ and / paths · ./ ../
        // relative paths · dotted host/path tokens · bare file.ext names · E####
        // error codes (Rust/cargo, etc.). The trailing `:LINE[:COL]` editor-jump
        // suffix is folded into the unquoted path-shaped alternatives.
        //
        // The bare `host.ext` alternative requires the final segment to start
        // with a letter and be 2+ chars (`\.[a-zA-Z][\w-]+`) so noise tokens —
        // file sizes (`8.2k`), abbreviations (`e.g`), versions (`v0.1.0`) —
        // don't masquerade as links, while real filenames/domains (`Cargo.toml`,
        // `README.md`, `beside.com`, `t.io`) still match. URLs and slash-paths
        // are unaffected.
        let pattern = r#""(?:/|~/|\./|\.\./|\$\w+/|\$\{\w+\}/)[^"\r\n]+"|'(?:/|~/|\./|\.\./|\$\w+/|\$\{\w+\}/)[^'\r\n]+'|https?://[\w./\-?&=@%+:~#!$,;*()]+[\w/]|\$\{?\w+\}?(?:/[\w./\-]+)+|(?:~|/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|(?:\.{1,2}/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+(?:/[^\s\]\r\n][^\s\]\r\n]*)+\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+\.[a-zA-Z][\w-]+(?::\d+(?::\d+)?)?|(?-u:\b)E\d{4}(?-u:\b)"#;
        Regex::new(pattern).expect("tmux link regex")
    })
}

/// A bare `Type.lowerCamelMember` is source syntax, not a file or host. Slash
/// paths remain path-shaped regardless of their final component, and ordinary
/// lowercase extensions (`.swift`, `.toml`, `.com`) are unaffected.
fn is_dotted_code_identifier(text: &str) -> bool {
    if text.contains('/') {
        return false;
    }
    let Some((owner, member)) = text.rsplit_once('.') else {
        return false;
    };
    if owner.is_empty() || member.is_empty() {
        return false;
    }

    let mut chars = member.chars();
    chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.any(|character| character.is_ascii_uppercase())
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
        let raw = m.as_str();
        let (leading_quote_cols, raw) = if let Some(inner) = raw
            .strip_prefix('"')
            .and_then(|text| text.strip_suffix('"'))
        {
            (1, inner)
        } else if let Some(inner) = raw
            .strip_prefix('\'')
            .and_then(|text| text.strip_suffix('\''))
        {
            (1, inner)
        } else {
            (0, raw)
        };
        let col = line[..m.start()].chars().count() + leading_quote_cols;
        if col >= max_cols {
            continue;
        }
        let text = raw.trim_end_matches(['.', ',', ';', ':', ')', ']', '}', '>']);
        if text.is_empty() || is_dotted_code_identifier(text) {
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
        if is_file(&path).await {
            return Some(path);
        }
    }
    if let Some(path) = which("tmux").await {
        return Some(path);
    }
    // Version managers install outside the standard prefixes, and a GUI app's
    // PATH doesn't include their shims, so the scan above misses tmux entirely
    // (mise — the primary installer on this host — puts it under
    // ~/.local/share/mise/installs/…). Resolve through mise when it's present,
    // then fall back to the user's login+interactive shell, which sources their
    // full profile (mise/asdf activation, custom PATH exports).
    if let Some(path) = find_tmux_via_mise().await {
        return Some(path);
    }
    find_tmux_via_login_shell().await
}

async fn is_file(path: &str) -> bool {
    tokio::fs::metadata(path)
        .await
        .map(|m| m.is_file())
        .unwrap_or(false)
}

/// `mise which tmux` → the active tmux binary. `mise` itself installs into a
/// standard prefix (Homebrew), so it's reachable even when the tools it manages
/// are not — and it reads the user's global config, so the answer doesn't depend
/// on the plugin's cwd or PATH.
async fn find_tmux_via_mise() -> Option<String> {
    let mut mise = None;
    for prefix in TMUX_PREFIXES {
        let path = format!("{prefix}/bin/mise");
        if is_file(&path).await {
            mise = Some(path);
            break;
        }
    }
    let mise = match mise {
        Some(path) => path,
        None => which("mise").await?,
    };
    let out = run_cmd(&mise, &["which", "tmux"], Duration::from_secs(5)).await?;
    let path = out.lines().map(str::trim).find(|l| l.starts_with('/'))?;
    is_file(path).await.then(|| path.to_string())
}

/// Last resort: the user's login+interactive shell sources their full profile
/// (mise/asdf activation, custom PATH), so `command -v tmux` there resolves
/// binaries a GUI app's bare PATH can't. `-i` is required because tool managers
/// commonly activate from interactive rc files such as `~/.zshrc`.
async fn find_tmux_via_login_shell() -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let out = run_cmd(&shell, &["-lic", "command -v tmux"], Duration::from_secs(6)).await?;
    let path = out.lines().map(str::trim).find(|l| l.starts_with('/'))?;
    is_file(path).await.then(|| path.to_string())
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct LocalTmuxConfig {
    label: String,
    terminal_window_title: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RemoteTmuxConfig {
    id: String,
    label: String,
    host: String,
    tmux_path: String,
    terminal_window_title: String,
    terminal_window_handle: Option<u64>,
    terminal_pid: i64,
    transport_pid: i64,
    home: String,
    control_path: Option<PathBuf>,
    ssh_options: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProcessRecord {
    pid: i64,
    ppid: i64,
    tty: String,
    command: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RemoteTransport {
    host: String,
    tmux_path: String,
    home: String,
    ssh_options: Vec<String>,
}

fn executable_name(command: &str) -> &str {
    command.rsplit('/').next().unwrap_or(command)
}

async fn local_hostname() -> String {
    run_cmd(HOSTNAME_PATH, &["-s"], Duration::from_secs(1))
        .await
        .unwrap_or_default()
        .trim()
        .split('.')
        .next()
        .filter(|value| !value.is_empty())
        .unwrap_or("local")
        .to_string()
}

async fn local_tmux_config() -> LocalTmuxConfig {
    LocalTmuxConfig {
        label: local_hostname().await,
        terminal_window_title: String::new(),
    }
}

async fn remote_control_path() -> Option<PathBuf> {
    let uid = run_cmd(ID_PATH, &["-u"], Duration::from_secs(1))
        .await?
        .trim()
        .parse::<u32>()
        .ok()?;
    let directory = PathBuf::from(format!("/tmp/flash-tmux-{uid}"));
    match tokio::fs::symlink_metadata(&directory).await {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.uid() != uid {
                return None;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if tokio::fs::create_dir(&directory).await.is_err() {
                let metadata = tokio::fs::symlink_metadata(&directory).await.ok()?;
                if !metadata.is_dir() || metadata.uid() != uid {
                    return None;
                }
            }
        }
        Err(_) => return None,
    }
    tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .await
        .ok()?;
    Some(directory.join("ssh-%C"))
}

fn split_command_line(raw: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    for ch in raw.chars() {
        if escaped {
            word.push(ch);
            escaped = false;
            continue;
        }
        match quote {
            Some('"') if ch == '\\' => escaped = true,
            Some(active) if ch == active => quote = None,
            Some(_) => word.push(ch),
            None if ch == '\\' => escaped = true,
            None if ch == '\'' || ch == '"' => quote = Some(ch),
            None if ch.is_whitespace() => {
                if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            None => word.push(ch),
        }
    }
    if escaped {
        word.push('\\');
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn ssh_option_takes_value(option: &str) -> bool {
    option.len() == 2
        && option
            .chars()
            .nth(1)
            .is_some_and(|flag| "BbcDEeFIiJLlmOopQRSWw".contains(flag))
}

fn ssh_destination_index(words: &[String]) -> Option<usize> {
    let mut index = 1;
    while index < words.len() {
        let word = &words[index];
        if word == "--" {
            return (index + 1 < words.len()).then_some(index + 1);
        }
        if !word.starts_with('-') || word == "-" {
            return Some(index);
        }
        index += if ssh_option_takes_value(word) { 2 } else { 1 };
    }
    None
}

fn retained_ssh_options(words: &[String]) -> Vec<String> {
    let mut retained = Vec::new();
    let mut index = 0;
    while index < words.len() {
        let option = &words[index];
        let takes_value = ssh_option_takes_value(option);
        let value = takes_value.then(|| words.get(index + 1)).flatten();
        let keep = matches!(
            option.as_str(),
            "-4" | "-6" | "-B" | "-b" | "-F" | "-I" | "-i" | "-J" | "-l" | "-p"
        ) || option == "-o"
            && value.is_some_and(|value| {
                let key = value
                    .split('=')
                    .next()
                    .unwrap_or(value)
                    .to_ascii_lowercase();
                !matches!(
                    key.as_str(),
                    "batchmode"
                        | "connectionattempts"
                        | "connecttimeout"
                        | "controlmaster"
                        | "controlpath"
                        | "controlpersist"
                        | "remotecommand"
                        | "requesttty"
                )
            });
        if keep {
            retained.push(option.clone());
            if let Some(value) = value {
                retained.push(value.clone());
            }
        }
        index += if takes_value { 2 } else { 1 };
    }
    retained
}

fn tmux_command_index(words: &[String], start: usize) -> Option<usize> {
    words
        .iter()
        .enumerate()
        .skip(start)
        .find(|(_, word)| executable_name(word) == "tmux")
        .map(|(index, _)| index)
}

fn inferred_remote_home(host: &str, tmux_words: &[String]) -> String {
    let user = host
        .split('@')
        .next()
        .filter(|_| host.contains('@'))
        .unwrap_or("");
    if user.is_empty() {
        return String::new();
    }
    for pair in tmux_words.windows(2) {
        if pair[0] != "-c" {
            continue;
        }
        for prefix in ["/home/", "/Users/"] {
            let expected = format!("{prefix}{user}");
            if pair[1] == expected || pair[1].starts_with(&format!("{expected}/")) {
                return expected;
            }
        }
    }
    String::new()
}

fn parse_ssh_transport(command: &str) -> Option<RemoteTransport> {
    let words = split_command_line(command);
    if executable_name(words.first()?) != "ssh" {
        return None;
    }
    let destination = ssh_destination_index(&words)?;
    let tmux_index = tmux_command_index(&words, destination + 1)?;
    let host = words[destination].clone();
    Some(RemoteTransport {
        home: inferred_remote_home(&host, &words[tmux_index + 1..]),
        tmux_path: words[tmux_index].clone(),
        ssh_options: retained_ssh_options(&words[1..destination]),
        host,
    })
}

fn parse_mosh_transport(command: &str) -> Option<RemoteTransport> {
    let marker = command.find(" -# ")? + 4;
    let end = command[marker..].rfind(" | ")? + marker;
    let words = split_command_line(&command[marker..end]);
    let separator = words.iter().rposition(|word| word == "--")?;
    if separator == 0 || separator + 1 >= words.len() {
        return None;
    }
    let host = words[separator - 1].clone();
    let tmux_index = tmux_command_index(&words, separator + 1)?;
    Some(RemoteTransport {
        home: inferred_remote_home(&host, &words[tmux_index + 1..]),
        tmux_path: words[tmux_index].clone(),
        ssh_options: Vec::new(),
        host,
    })
}

fn parse_remote_transport(command: &str, process_name: &str) -> Option<RemoteTransport> {
    match process_name {
        "ssh" => parse_ssh_transport(command),
        "mosh-client" => parse_mosh_transport(command),
        _ => None,
    }
}

fn remote_host_name(host: &str) -> &str {
    host.rsplit('@').next().unwrap_or(host)
}

fn remote_host_label(host: &str) -> String {
    remote_host_name(host)
        .trim_matches(['[', ']'])
        .split(['.', ':'])
        .next()
        .filter(|value| !value.is_empty())
        .unwrap_or("remote")
        .to_string()
}

fn terminal_title_for_host(nodes: &[AxWindowNode], host: &str) -> String {
    let full = remote_host_name(host).to_ascii_lowercase();
    let short = remote_host_label(host).to_ascii_lowercase();
    nodes
        .iter()
        .filter_map(|node| node.attrs.get("AXTitle"))
        .max_by_key(|title| {
            let lower = title.to_ascii_lowercase();
            if !full.is_empty() && lower.contains(&full) {
                3
            } else if !short.is_empty() && lower.contains(&short) {
                2
            } else {
                0
            }
        })
        .filter(|title| {
            let lower = title.to_ascii_lowercase();
            (!full.is_empty() && lower.contains(&full))
                || (!short.is_empty() && lower.contains(&short))
                || nodes.len() == 1
        })
        .cloned()
        .unwrap_or_default()
}

async fn process_records() -> Vec<ProcessRecord> {
    let Some(raw) = run_cmd(
        PS_PATH,
        &["-axo", "pid=,ppid=,tty=,comm="],
        Duration::from_millis(1500),
    )
    .await
    else {
        return Vec::new();
    };
    raw.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some(ProcessRecord {
                pid: fields.next()?.parse().ok()?,
                ppid: fields.next()?.parse().ok()?,
                tty: fields.next()?.to_string(),
                command: fields.next()?.to_string(),
            })
        })
        .collect()
}

async fn process_command(pid: i64) -> Option<String> {
    run_cmd(
        PS_PATH,
        &["-ww", "-p", &pid.to_string(), "-o", "command="],
        Duration::from_millis(1500),
    )
    .await
    .map(|command| command.trim().to_string())
    .filter(|command| !command.is_empty())
}

async fn discover_remote_tmux_configs(ctx: &Context) -> BTreeMap<String, RemoteTmuxConfig> {
    let control_path = remote_control_path().await;
    let records = process_records().await;
    let parent_map = records
        .iter()
        .map(|record| (record.pid, record.ppid))
        .collect::<HashMap<_, _>>();
    let application_pids = ctx
        .running_applications()
        .into_iter()
        .map(|application| application.pid)
        .collect::<BTreeSet<_>>();
    let mut windows_by_pid: HashMap<i64, Vec<AxWindowNode>> = HashMap::new();
    let mut discovered = BTreeMap::new();
    for record in records {
        let process_name = executable_name(&record.command);
        if !matches!(process_name, "ssh" | "mosh-client")
            || matches!(record.tty.as_str(), "?" | "??" | "-")
        {
            continue;
        }
        let Some(terminal_pid) = find_top_level_ancestor(record.pid, &parent_map)
            .filter(|pid| application_pids.contains(pid))
        else {
            continue;
        };
        let Some(command) = process_command(record.pid).await else {
            continue;
        };
        let Some(transport) = parse_remote_transport(&command, process_name) else {
            continue;
        };
        let nodes = if let Some(nodes) = windows_by_pid.get(&terminal_pid) {
            nodes.clone()
        } else {
            let nodes = terminal_window_nodes(ctx, terminal_pid).await;
            windows_by_pid.insert(terminal_pid, nodes.clone());
            nodes
        };
        let label = remote_host_label(&transport.host);
        let id = format!(
            "remote:{}",
            remote_host_name(&transport.host).to_ascii_lowercase()
        );
        let terminal_window_title = terminal_title_for_host(&nodes, &id["remote:".len()..]);
        let terminal_window_handle = window_handle_for_title(&nodes, &terminal_window_title);
        let config = RemoteTmuxConfig {
            id: id.clone(),
            label,
            host: transport.host,
            tmux_path: transport.tmux_path,
            terminal_window_title,
            terminal_window_handle,
            terminal_pid,
            transport_pid: record.pid,
            home: transport.home,
            control_path: control_path.clone(),
            ssh_options: transport.ssh_options,
        };
        discovered.insert(id, config);
    }
    discovered
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
    command.args(args);
    let started_at = Instant::now();
    match bounded_process::capture(
        &mut command,
        None,
        timeout,
        SUBPROCESS_STDOUT_LIMIT,
        SUBPROCESS_STDERR_LIMIT,
    )
    .await
    {
        Ok(output) => {
            if started_at.elapsed() >= Duration::from_secs(1) {
                eprintln!(
                    "[tmux] subprocess slow elapsed_ms={} status={}",
                    started_at.elapsed().as_millis(),
                    output
                        .status
                        .code()
                        .map(|code| code.to_string())
                        .unwrap_or_else(|| "signal".to_string())
                );
            }
            CliResult {
                ok: output.status.success(),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                status: output.status.code().unwrap_or(-1),
            }
        }
        Err(error) => {
            eprintln!(
                "[tmux] subprocess capture failed elapsed_ms={} status={} detail={}",
                started_at.elapsed().as_millis(),
                error.status(),
                error.diagnostic()
            );
            CliResult {
                ok: false,
                stderr: error.diagnostic(),
                status: error.status(),
                ..Default::default()
            }
        }
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn remote_tmux_command(config: &RemoteTmuxConfig, args: &[&str]) -> String {
    let mut words = vec![
        shell_quote(ENV_PATH),
        "-u".to_string(),
        "TMUX".to_string(),
        "-u".to_string(),
        "TMUX_PANE".to_string(),
        "-u".to_string(),
        "TMUX_TMPDIR".to_string(),
        "-u".to_string(),
        "TMPDIR".to_string(),
        shell_quote(&config.tmux_path),
    ];
    words.extend(args.iter().map(|arg| shell_quote(arg)));
    words.join(" ")
}

fn remote_ssh_argv(config: &RemoteTmuxConfig, command: &str) -> Vec<String> {
    let mut argv = vec![SSH_PATH.to_string(), "-T".to_string()];
    argv.extend(config.ssh_options.iter().cloned());
    argv.extend([
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "ConnectTimeout=5".to_string(),
        "-o".to_string(),
        "ConnectionAttempts=1".to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=yes".to_string(),
    ]);
    if let Some(control_path) = config.control_path.as_ref() {
        argv.extend([
            "-o".to_string(),
            "ControlMaster=auto".to_string(),
            "-o".to_string(),
            "ControlPersist=60".to_string(),
            "-o".to_string(),
            format!("ControlPath={}", control_path.display()),
        ]);
    }
    argv.extend(["--".to_string(), config.host.clone(), command.to_string()]);
    argv
}

async fn run_remote_tmux(config: &RemoteTmuxConfig, args: &[&str], timeout: Duration) -> CliResult {
    let command = remote_tmux_command(config, args);
    run_local(&remote_ssh_argv(config, &command), timeout).await
}

async fn run_remote_tmux_default(config: &RemoteTmuxConfig, args: &[&str]) -> Option<String> {
    let result = run_remote_tmux(config, args, Duration::from_secs(7)).await;
    result.ok.then_some(result.stdout)
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
/// Identical lines are deduplicated so an alias between the default invocation
/// and an explicit `-S <path>` for the same socket doesn't double-count rows.
/// Candidate inventory accepts only servers reporting an attached client, so a
/// detached historical server cannot contribute stale windows. A healthy
/// server's output remains authoritative when an unrelated socket is absent or
/// transiently broken; the last-good aggregate is retained only when no server
/// supplies usable output at all.
#[derive(Clone, Debug, Eq, PartialEq)]
enum TmuxAggregate {
    Output(String),
    Absent,
    TransientFailure,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TmuxInventoryScope {
    AnyServer,
    AttachedServers,
}

async fn run_tmux_aggregate_inventory(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
) -> TmuxAggregate {
    let Some(path) = tmux_path.map(str::to_string) else {
        return TmuxAggregate::Absent;
    };
    let args_owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();

    // Discover sockets once up front; spawning all invocations together
    // means the slowest socket sets the cycle length, not the sum.
    let socket_paths = tmux_socket_paths().await;
    let mut handles: Vec<tokio::task::JoinHandle<CliResult>> =
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
            run_local(&tmux_argv(&path, &args_ref), timeout).await
        }));
    }

    for socket_path in socket_paths {
        let path = path.clone();
        let args_owned = args_owned.clone();
        handles.push(tokio::spawn(async move {
            let args_ref: Vec<&str> = args_owned.iter().map(String::as_str).collect();
            run_local(&tmux_socket_argv(&path, &socket_path, &args_ref), timeout).await
        }));
    }

    let mut results = Vec::with_capacity(handles.len());
    let mut join_failed = false;
    for handle in handles {
        match handle.await {
            Ok(result) => results.push(result),
            Err(_) => join_failed = true,
        }
    }
    let scope = if args.contains(&"list-windows") {
        TmuxInventoryScope::AttachedServers
    } else {
        TmuxInventoryScope::AnyServer
    };
    classify_tmux_aggregate(&results, join_failed, scope)
}

fn classify_tmux_aggregate(
    results: &[CliResult],
    join_failed: bool,
    scope: TmuxInventoryScope,
) -> TmuxAggregate {
    let merged = merge_socket_outputs(
        results
            .iter()
            .filter(|result| result.ok)
            .map(|result| result.stdout.as_str())
            .filter(|output| {
                scope == TmuxInventoryScope::AnyServer
                    || candidate_inventory_has_attached_client(output)
            }),
    );
    if !merged.is_empty() {
        // A healthy attached server is authoritative for its own inventory.
        // Unrelated stale/control sockets must not freeze every healthy server.
        return TmuxAggregate::Output(merged);
    }
    if join_failed || results.iter().any(is_transient_tmux_failure) {
        return TmuxAggregate::TransientFailure;
    }
    TmuxAggregate::Absent
}

fn candidate_inventory_has_attached_client(output: &str) -> bool {
    let prefix = format!("{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}");
    output.lines().any(|line| line.starts_with(&prefix))
}

fn is_transient_tmux_failure(result: &CliResult) -> bool {
    !result.ok && !is_absent_tmux_server(result)
}

fn is_absent_tmux_server(result: &CliResult) -> bool {
    if result.ok {
        return false;
    }
    let error = result.stderr.to_ascii_lowercase();
    error.contains("no server running")
        || (error.contains("error connecting to")
            && (error.contains("no such file") || error.contains("connection refused")))
        || error.contains("failed to connect to server")
        || error.contains("server exited unexpectedly")
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

async fn run_tmux_inventory_default(tmux_path: Option<&str>, args: &[&str]) -> TmuxAggregate {
    run_tmux_aggregate_inventory(tmux_path, args, Duration::from_secs(2)).await
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

/// One-line diagnostic for why `client_hosted_by_*` resolved no client: the
/// focused pid, the `ps` parent-map size, and for every listed client whether
/// its pid is known to the process sample and whether it chains up to the
/// focused terminal. Logged on the otherwise-silent no-client path so a single
/// repro distinguishes empty-client-list vs wrong-focused-pid vs broken-ancestry.
fn client_resolution_diag(
    focused_pid: i64,
    clients: &[TmuxClient],
    parent_map: &HashMap<i64, i64>,
) -> String {
    let clients_in_process_sample = clients
        .iter()
        .filter(|client| parent_map.contains_key(&client.client_pid))
        .count();
    let ancestry_matches = clients
        .iter()
        .filter(|client| is_ancestor(focused_pid, client.client_pid, parent_map))
        .count();
    format!(
        "diag pmap_len={} client_count={} clients_in_pmap={} ancestry_matches={}",
        parent_map.len(),
        clients.len(),
        clients_in_process_sample,
        ancestry_matches,
    )
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

#[derive(Clone, Debug)]
struct TmuxClient {
    tty: String,
    session: String,
    client_pid: i64,
    activity: i64,
    backend_id: String,
    remote: bool,
}

#[derive(Clone, Default)]
struct ClientSnapshot {
    clients: Vec<TmuxClient>,
    parent_map: Arc<HashMap<i64, i64>>,
    window_title_by_client_pid: Arc<HashMap<i64, String>>,
    window_handle_by_client_pid: Arc<HashMap<i64, u64>>,
}

impl ClientSnapshot {
    fn ancestry_matches(&self, focused_pid: i64) -> Vec<TmuxClient> {
        self.clients
            .iter()
            .filter(|client| is_ancestor(focused_pid, client.client_pid, &self.parent_map))
            .cloned()
            .collect()
    }

    fn hosted_by(&self, focused_pid: i64) -> Option<TmuxClient> {
        if self.clients.is_empty() {
            return None;
        }
        client_hosted_by_from_map(&self.clients, focused_pid, &self.parent_map)
    }

    /// Return without an AX lookup when process ancestry identifies exactly one
    /// tmux client in the focused terminal application. This is the common
    /// one-window case and is unambiguous even if the terminal title changes.
    fn uniquely_hosted_by(&self, focused_pid: i64) -> Option<TmuxClient> {
        let mut hosted = self.ancestry_matches(focused_pid);
        if hosted.len() == 1 {
            return hosted.pop();
        }

        let process_sample_can_evaluate_clients = self
            .clients
            .iter()
            .any(|client| self.parent_map.contains_key(&client.client_pid));
        if hosted.is_empty() && !process_sample_can_evaluate_clients && self.clients.len() == 1 {
            return self.clients.first().cloned();
        }
        None
    }

    fn hosted_by_window(
        &self,
        focused_pid: i64,
        focused_window_handle: Option<u64>,
        window_title: &str,
    ) -> Option<TmuxClient> {
        let mut hosted = self.ancestry_matches(focused_pid);
        if hosted.is_empty() {
            return self.hosted_by(focused_pid);
        }
        let normalized_title = window_title.to_ascii_lowercase();
        hosted.sort_by_key(|client| {
            let exact_handle = focused_window_handle.is_some_and(|handle| {
                self.window_handle_by_client_pid.get(&client.client_pid) == Some(&handle)
            }) as i64;
            let exact_window = self
                .window_title_by_client_pid
                .get(&client.client_pid)
                .is_some_and(|title| title == window_title) as i64;
            let session_match =
                normalized_title.contains(&client.session.to_ascii_lowercase()) as i64;
            std::cmp::Reverse((exact_handle, exact_window, session_match, client.activity))
        });
        hosted.into_iter().next()
    }
}

async fn list_clients_inventory(tmux_path: Option<&str>) -> Result<Vec<TmuxClient>, ()> {
    let format = format!(
        "#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    // Aggregated across every discovered tmux socket — `list-clients`
    // only reports clients attached to the socket it was called on, so
    // a single-socket invocation silently drops every client (and
    // therefore every window-resolution route) attached to other tmux
    // servers running on the host.
    let raw = match run_tmux_inventory_default(tmux_path, &["list-clients", "-F", &format]).await {
        TmuxAggregate::Output(raw) => raw,
        TmuxAggregate::Absent => return Ok(Vec::new()),
        TmuxAggregate::TransientFailure => return Err(()),
    };
    Ok(raw.lines().filter_map(parse_tmux_client).collect())
}

fn parse_tmux_client(line: &str) -> Option<TmuxClient> {
    parse_tmux_client_for_backend(line, "local")
}

fn parse_tmux_client_for_backend(line: &str, backend_id: &str) -> Option<TmuxClient> {
    let parts = split_tmux_fields(line, 4);
    if parts.len() < 3 {
        return None;
    }
    let client_pid = parts[2].parse::<i64>().ok()?;
    let activity = parts
        .get(3)
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(0);
    Some(TmuxClient {
        tty: parts[0].to_string(),
        session: parts[1].to_string(),
        client_pid,
        activity,
        backend_id: backend_id.to_string(),
        remote: backend_id != "local",
    })
}

async fn list_clients(tmux_path: Option<&str>) -> Vec<TmuxClient> {
    list_clients_inventory(tmux_path).await.unwrap_or_default()
}

async fn list_remote_clients(config: &RemoteTmuxConfig) -> Result<Vec<TmuxClient>, ()> {
    let format = format!(
        "#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    let result = run_remote_tmux(
        config,
        &["list-clients", "-F", &format],
        Duration::from_secs(7),
    )
    .await;
    if !result.ok {
        return Err(());
    }
    Ok(result
        .stdout
        .lines()
        .filter_map(|line| parse_tmux_client_for_backend(line, &config.id))
        .collect())
}

async fn run_tmux_for_client(plugin: &Tmux, client: &TmuxClient, args: &[&str]) -> Option<String> {
    if client.remote {
        let config = plugin.remote_config(&client.backend_id)?;
        run_remote_tmux_default(&config, args).await
    } else {
        run_tmux_default(plugin.resolved_tmux_path().await, args).await
    }
}

async fn run_tmux_for_client_capture(
    plugin: &Tmux,
    client: &TmuxClient,
    args: &[&str],
    timeout: Duration,
) -> Result<String, String> {
    if client.remote {
        let config = plugin
            .remote_config(&client.backend_id)
            .ok_or_else(|| "remote tmux transport is no longer attached".to_string())?;
        let result = run_remote_tmux(&config, args, timeout).await;
        if result.ok {
            Ok(result.stdout)
        } else if result.stderr.trim().is_empty() {
            Err(format!("remote tmux exited status={}", result.status))
        } else {
            Err(result.stderr.trim().to_string())
        }
    } else {
        run_tmux_capture(plugin.resolved_tmux_path().await, args, timeout).await
    }
}

async fn load_client_snapshot(tmux_path: Option<&str>) -> Option<ClientSnapshot> {
    let clients = list_clients_inventory(tmux_path).await.ok()?;
    if clients.is_empty() {
        return None;
    }
    let parent_map = parent_pid_map().await;
    Some(ClientSnapshot {
        clients,
        parent_map: Arc::new(parent_map),
        window_title_by_client_pid: Arc::new(HashMap::new()),
        window_handle_by_client_pid: Arc::new(HashMap::new()),
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
    let mut snapshot = load_client_snapshot(plugin.resolved_tmux_path().await).await?;
    if let Ok(mut guard) = plugin.client_snapshot().lock() {
        if same_client_processes(&guard.clients, &snapshot.clients) {
            snapshot.window_title_by_client_pid = Arc::clone(&guard.window_title_by_client_pid);
            snapshot.window_handle_by_client_pid = Arc::clone(&guard.window_handle_by_client_pid);
        }
        *guard = snapshot.clone();
    }
    Some(snapshot)
}

#[derive(Clone, Debug, Deserialize)]
struct AxWindowNode {
    handle: u64,
    #[serde(default)]
    attrs: HashMap<String, String>,
}

fn ax_window_nodes(value: &Value) -> Vec<AxWindowNode> {
    if !value.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        return Vec::new();
    }
    value
        .get("nodes")
        .cloned()
        .and_then(|nodes| serde_json::from_value(nodes).ok())
        .unwrap_or_default()
}

fn focused_window_from_nodes(nodes: &[AxWindowNode]) -> Option<&AxWindowNode> {
    nodes
        .iter()
        .find(|node| {
            node.attrs.get("AXFocused").map(String::as_str) == Some("1")
                || node.attrs.get("AXMain").map(String::as_str) == Some("1")
        })
        .or_else(|| nodes.first())
}

fn focused_window_title_from_nodes(nodes: &[AxWindowNode]) -> Option<&str> {
    focused_window_from_nodes(nodes)
        .and_then(|node| node.attrs.get("AXTitle"))
        .map(String::as_str)
}

fn window_handle_for_title(nodes: &[AxWindowNode], title: &str) -> Option<u64> {
    nodes
        .iter()
        .find(|node| node.attrs.get("AXTitle").map(String::as_str) == Some(title))
        .map(|node| node.handle)
}

async fn terminal_window_nodes(ctx: &Context, pid: i64) -> Vec<AxWindowNode> {
    let value = ctx
        .ax_snapshot(json!({
            "pid": pid,
            "roots": "windows",
            "follow": ["AXFlashNoChildren"],
            "collect": ["AXTitle", "AXFocused", "AXMain"],
            "max_nodes": 64,
            "geometry": false,
        }))
        .await;
    ax_window_nodes(&value)
}

async fn focused_terminal_window_title(ctx: &Context, pid: i64) -> Option<String> {
    let nodes = terminal_window_nodes(ctx, pid).await;
    focused_window_title_from_nodes(&nodes).map(str::to_string)
}

async fn raise_terminal_window_handle(ctx: &Context, pid: i64, handle: u64) -> bool {
    // Discovery already resolved the exact AX window. Activating the app and
    // raising/focusing that cached handle in one host wave keeps a warm remote
    // jump off the AX snapshot path entirely.
    let (activated, raised, main, focused) = tokio::join!(
        ctx.activate(pid),
        ctx.ax_perform(handle, "AXRaise"),
        ctx.ax_set(handle, "AXMain", true),
        ctx.ax_set(handle, "AXFocused", true),
    );
    activated && (raised || main || focused)
}

async fn raise_terminal_window(
    ctx: &Context,
    pid: i64,
    cached_handle: Option<u64>,
    title: &str,
) -> bool {
    if pid <= 0 {
        return false;
    }
    if let Some(handle) = cached_handle {
        if raise_terminal_window_handle(ctx, pid, handle).await {
            return true;
        }
        // AX handles expire when a terminal window is recreated. Fall through
        // to the title lookup once so stale discovery heals transparently.
    }
    if title.is_empty() {
        return ctx.activate(pid).await;
    }
    // App activation and the AX lookup are independent. This is the cold/stale
    // fallback; warm candidates use the cached handle above.
    let (activated, nodes) = tokio::join!(ctx.activate(pid), terminal_window_nodes(ctx, pid));
    let Some(handle) = window_handle_for_title(&nodes, title) else {
        return activated;
    };
    // Raising, making main, and making focused are likewise independent AX
    // mutations on the same already-resolved window.
    let (raised, main, focused) = tokio::join!(
        ctx.ax_perform(handle, "AXRaise"),
        ctx.ax_set(handle, "AXMain", true),
        ctx.ax_set(handle, "AXFocused", true),
    );
    activated && (raised || main || focused)
}

fn local_window_title_score(title: &str, session: &str, local_label: &str) -> usize {
    let title = title.to_ascii_lowercase();
    let session = session.to_ascii_lowercase();
    let local_label = local_label.to_ascii_lowercase();
    let mut score = 0;
    if !local_label.is_empty() && title.contains(&local_label) {
        score += 4;
    }
    if !session.is_empty() && title.contains(&session) {
        score += 2;
    }
    score
}

async fn discover_local_client_windows(
    ctx: &Context,
    clients: &[TmuxClient],
    parent_map: &HashMap<i64, i64>,
    local_label: &str,
) -> (HashMap<i64, String>, HashMap<i64, u64>) {
    let mut clients_by_terminal: BTreeMap<i64, Vec<&TmuxClient>> = BTreeMap::new();
    for client in clients {
        if let Some(terminal_pid) = find_top_level_ancestor(client.client_pid, parent_map) {
            clients_by_terminal
                .entry(terminal_pid)
                .or_default()
                .push(client);
        }
    }
    let mut resolved_titles = HashMap::new();
    let mut resolved_handles = HashMap::new();
    for (terminal_pid, mut hosted_clients) in clients_by_terminal {
        let mut windows = terminal_window_nodes(ctx, terminal_pid).await;
        hosted_clients.sort_by_key(|client| std::cmp::Reverse(client.activity));
        for client in hosted_clients {
            let best = windows
                .iter()
                .enumerate()
                .map(|(index, node)| {
                    let title = node.attrs.get("AXTitle").map(String::as_str).unwrap_or("");
                    (
                        index,
                        local_window_title_score(title, &client.session, local_label),
                    )
                })
                .max_by_key(|(_, score)| *score);
            let Some((index, score)) = best else {
                continue;
            };
            if score == 0 && windows.len() != 1 {
                continue;
            }
            let node = windows.remove(index);
            if let Some(title) = node.attrs.get("AXTitle").filter(|title| !title.is_empty()) {
                resolved_titles.insert(client.client_pid, title.clone());
                resolved_handles.insert(client.client_pid, node.handle);
            }
        }
    }
    (resolved_titles, resolved_handles)
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum FocusedTmuxBackend {
    Local,
    Remote(String),
}

async fn focused_tmux_backend(
    plugin: &Tmux,
    ctx: &Context,
    pid: i64,
) -> Option<FocusedTmuxBackend> {
    let remotes = plugin.remote_configs();
    if remotes.is_empty() {
        return Some(FocusedTmuxBackend::Local);
    }
    let title = focused_terminal_window_title(ctx, pid)
        .await
        .unwrap_or_default();
    let normalized_title = title.to_ascii_lowercase();
    if let Some(remote) = remotes.values().find(|remote| {
        if remote.terminal_pid != pid {
            return false;
        }
        let host = remote_host_name(&remote.host).to_ascii_lowercase();
        let label = remote.label.to_ascii_lowercase();
        (!remote.terminal_window_title.is_empty() && title == remote.terminal_window_title)
            || (!host.is_empty() && normalized_title.contains(&host))
            || (!label.is_empty() && normalized_title.contains(&label))
    }) {
        return Some(FocusedTmuxBackend::Remote(remote.id.clone()));
    }
    if cached_client_hosted_by(plugin, pid).is_some() {
        return Some(FocusedTmuxBackend::Local);
    }
    let mut matching_remotes = remotes.values().filter(|remote| remote.terminal_pid == pid);
    let only = matching_remotes.next()?;
    matching_remotes
        .next()
        .is_none()
        .then(|| FocusedTmuxBackend::Remote(only.id.clone()))
}

async fn remote_client_for_target(
    config: &RemoteTmuxConfig,
    target: Option<&str>,
) -> Option<TmuxClient> {
    let mut clients = list_remote_clients(config).await.ok()?;
    clients.sort_by_key(|client| std::cmp::Reverse(client.activity));
    let target_session = target.and_then(|value| value.split(':').next());
    target_session
        .and_then(|session| {
            clients
                .iter()
                .find(|client| client.session == session)
                .cloned()
        })
        .or_else(|| clients.into_iter().next())
}

async fn focused_tmux_client(
    plugin: &Tmux,
    ctx: &Context,
    pid: i64,
    fresh: bool,
) -> Option<TmuxClient> {
    match focused_tmux_backend(plugin, ctx, pid).await? {
        FocusedTmuxBackend::Local => {
            let fresh_snapshot = if fresh {
                refresh_cached_client_snapshot(plugin).await
            } else {
                None
            };
            let snapshot = fresh_snapshot.or_else(|| {
                plugin
                    .client_snapshot()
                    .lock()
                    .ok()
                    .map(|snapshot| snapshot.clone())
            })?;
            if let Some(client) = snapshot.uniquely_hosted_by(pid) {
                return Some(client);
            }
            let nodes = terminal_window_nodes(ctx, pid).await;
            let focused_window = focused_window_from_nodes(&nodes);
            let handle = focused_window.map(|window| window.handle);
            let title = focused_window
                .and_then(|window| window.attrs.get("AXTitle"))
                .map(String::as_str)
                .unwrap_or_default();
            snapshot.hosted_by_window(pid, handle, title)
        }
        FocusedTmuxBackend::Remote(backend_id) => {
            remote_client_for_target(&plugin.remote_config(&backend_id)?, None).await
        }
    }
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

// ---- Hint targets -----------------------------------------------------------

struct Pane {
    id: String,
    left: i64,
    top: i64,
    cols: i64,
    rows: i64,
}

// Ten positional args is on the high side, but `JumpTarget` itself is the
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
    priority: Priority,
) -> JumpTarget {
    JumpTarget::new(target_id, Frame::new(x, y, width, height))
        .role(role)
        .label(label)
        .enters_insert_mode(enters_insert_mode)
        .pid(pid)
        .priority(priority)
}

async fn hints_for_context(plugin: &Tmux, ctx: &Context, req: &HintsRequest) -> HintsResponse {
    let Some(pid) = req.pid else {
        return HintsResponse::targets(vec![]);
    };
    let bundle_id = req.bundle_id.as_deref().unwrap_or("");
    let frame = req.front_window_frame.unwrap_or_default();
    let win_w = frame.width;
    let win_h = frame.height;
    let min_x = frame.x;
    let min_y = frame.y;
    if win_w <= 0.0 || win_h <= 0.0 {
        return HintsResponse::targets(vec![]).context_pid(pid);
    }

    let Some(client) = focused_tmux_client(plugin, ctx, pid, false).await else {
        return HintsResponse::targets(vec![]).context_pid(pid);
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
    let combined = run_tmux_for_client(
        plugin,
        &client,
        &["display-message", "-c", &client.tty, "-p", &combined_format],
    )
    .await;
    let Some(combined) = combined else {
        return HintsResponse::targets(vec![]).context_pid(pid);
    };
    let combined_lines: Vec<&str> = combined.split(TMUX_FIELD_SEP).collect();
    if combined_lines.len() < 2 {
        return HintsResponse::targets(vec![]).context_pid(pid);
    }
    let Some((client_cols, client_rows)) = parse_two_ints(combined_lines[0]) else {
        return HintsResponse::targets(vec![]).context_pid(pid);
    };
    if client_cols <= 0 || client_rows <= 0 {
        return HintsResponse::targets(vec![]).context_pid(pid);
    }

    let (cell_w, cell_h, pad_x, pad_y) = resolve_geometry(
        bundle_id,
        win_w,
        win_h,
        client_cols as f64,
        client_rows as f64,
    )
    .await;

    let pane_list = run_tmux_for_client(
        plugin,
        &client,
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
        return HintsResponse::targets(vec![]).context_pid(pid);
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
        return HintsResponse::targets(vec![]).context_pid(pid);
    }

    let top_offset = parse_status_top_offset(combined_lines[1]);

    // Pane chip is 3-cells wide so the hint label is readable. Anchored at
    // pane center, chip extends 1 cell left and right.
    let pane_chip_cells: i64 = 3;
    let mut pane_targets: Vec<JumpTarget> = Vec::new();

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
        // A pane target delegates a plain click to the terminal. It stays in
        // NORMAL after the click; only mouse-grid and physical mouse clicks
        // express the separate "start typing" intent.
        pane_targets.push(build_target(
            &target_id,
            chip_x,
            chip_y,
            pane_chip_cells as f64 * cell_w,
            cell_h,
            PANE_TARGET_ROLE,
            &pane.id,
            pid,
            TMUX_TARGET_ENTERS_INSERT_MODE,
            // Pane chips are the structural anchors of a tmux window, so the
            // renderer paints them in the accent style. Link chips below are
            // everyday clutter and stay in the default yellow.
            Priority::Urgent,
        ));

        let Some(raw) =
            run_tmux_for_client(plugin, &client, &["capture-pane", "-t", &pane.id, "-p"]).await
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
        // Terminal links use a generic host-understood semantic role. The host
        // sends `f` as Shift-click and `F` as Command-Shift-click so Alacritty
        // handles the link instead of forwarding a pane click to tmux. Link
        // commits stay in NORMAL.
        targets.push(build_target(
            &target_id,
            x,
            y,
            cell_w,
            cell_h,
            TERMINAL_LINK_ROLE,
            &link.text,
            pid,
            TMUX_TARGET_ENTERS_INSERT_MODE,
            Priority::Normal,
        ));
    }

    HintsResponse::targets(targets).context_pid(pid)
}

// ---- Candidate (tmux window finder) -----------------------------------------

/// Round-tripped through the host so candidate resolution can re-drive
/// `switch-client` against the right session/client.
#[derive(Clone, Debug, Default)]
struct CandidateBackend {
    id: String,
    label: String,
    terminal_window_title: String,
    terminal_window_handle: Option<u64>,
    terminal_pid: Option<i64>,
    remote: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct TmuxPayload {
    backend_id: String,
    tmux_target: String,
    #[serde(default)]
    tmux_client_tty: String,
    #[serde(default)]
    client_pid: Option<i64>,
    #[serde(default)]
    terminal_pid: Option<i64>,
    #[serde(default)]
    terminal_window_handle: Option<u64>,
    terminal_window_title: String,
    #[serde(default)]
    remote: bool,
}

fn routed_client_from_payload(payload: &TmuxPayload) -> Option<TmuxClient> {
    if payload.backend_id.is_empty()
        || payload.tmux_target.is_empty()
        || payload.tmux_client_tty.is_empty()
    {
        return None;
    }
    Some(TmuxClient {
        tty: payload.tmux_client_tty.clone(),
        session: payload
            .tmux_target
            .split(':')
            .next()
            .unwrap_or(&payload.tmux_target)
            .to_string(),
        client_pid: payload.client_pid.unwrap_or(0),
        activity: 0,
        backend_id: payload.backend_id.clone(),
        remote: payload.remote,
    })
}

fn cached_terminal_pid(plugin: &Tmux, payload: &TmuxPayload) -> Option<i64> {
    payload.terminal_pid.or_else(|| {
        let client_pid = payload.client_pid?;
        let snapshot = plugin.client_snapshot().lock().ok()?;
        find_top_level_ancestor(client_pid, &snapshot.parent_map)
    })
}

fn cached_payload_for_route(
    plugin: &Tmux,
    backend_id: &str,
    tmux_target: &str,
) -> Option<TmuxPayload> {
    let partitions = plugin.candidate_partitions().lock().ok()?;
    let candidates = if backend_id == "local" {
        &partitions.local
    } else {
        &partitions.remote.get(backend_id)?.candidates
    };
    candidates.iter().find_map(|candidate| {
        let payload = candidate.payload_as::<TmuxPayload>()?;
        (payload.backend_id == backend_id && payload.tmux_target == tmux_target).then_some(payload)
    })
}

fn routed_tmux_target(backend_id: &str, target: &str) -> String {
    format!("{backend_id}|{target}")
}

fn split_routed_tmux_target(target: &str) -> Option<(&str, &str)> {
    let (backend_id, tmux_target) = target.split_once('|')?;
    if backend_id.is_empty() || tmux_target.is_empty() {
        return None;
    }
    Some((backend_id, tmux_target))
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
    window_title_by_client_pid: &HashMap<i64, String>,
    window_handle_by_client_pid: &HashMap<i64, u64>,
    home: &str,
    backend: &CandidateBackend,
) -> Vec<Candidate> {
    let client_by_session = client_by_session(clients);
    let mut out = Vec::new();
    for line in raw.split('\n') {
        if line.is_empty() {
            continue;
        }
        let parts = split_tmux_fields(line, 7);
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
        let terminal_pid = terminal_pid_by_session
            .get(session)
            .copied()
            .flatten()
            .or(backend.terminal_pid);
        let terminal_window_title = client
            .and_then(|client| window_title_by_client_pid.get(&client.client_pid))
            .cloned()
            .unwrap_or_else(|| backend.terminal_window_title.clone());
        let terminal_window_handle = client
            .and_then(|client| window_handle_by_client_pid.get(&client.client_pid))
            .copied()
            .or(backend.terminal_window_handle);

        let target = format!("{session}:{index}");
        let window_name = if name.is_empty() {
            target.clone()
        } else {
            name.to_string()
        };
        let primary = if backend.label.is_empty() {
            window_name
        } else {
            format!("{} · {window_name}", backend.label)
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

        let navigation_url =
            tmux_navigation_url("window", &routed_tmux_target(&backend.id, &target));
        let payload = TmuxPayload {
            backend_id: backend.id.clone(),
            tmux_target: target,
            tmux_client_tty: client.map(|c| c.tty.clone()).unwrap_or_default(),
            client_pid: client.map(|c| c.client_pid),
            terminal_pid,
            terminal_window_handle,
            terminal_window_title,
            remote: backend.remote,
        };
        let mut candidate = Candidate::new(SOURCE_WINDOWS, primary)
            .kind("tmux_window")
            .location()
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
    status: TmuxStatusSegments,
}

/// Values for the manifest-declared statusbar segments
/// (`#{plugin:tmux.session}` / `.window` / `.pane`). Empty strings clear
/// the segments host-side.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct TmuxStatusSegments {
    session: String,
    window: String,
    pane: String,
}

/// Attached-client tmux state for the statusbar, derived from the same
/// `list-clients ; list-windows -a` inventory the candidate build already
/// fetched — no extra tmux I/O. The most recently active attached client
/// wins (`client_activity`), then its session's active window supplies the
/// window name (index when unnamed) and active-pane index.
fn status_segments(clients: &[TmuxClient], raw_windows: &str) -> TmuxStatusSegments {
    let Some(client) = clients.iter().max_by_key(|client| client.activity) else {
        return TmuxStatusSegments::default();
    };
    let mut segments = TmuxStatusSegments {
        session: client.session.clone(),
        ..TmuxStatusSegments::default()
    };
    for line in raw_windows.lines() {
        let parts = split_tmux_fields(line, 7);
        if parts.len() < 3 || parts[0] != client.session {
            continue;
        }
        if parts.get(5).map(|active| active.trim()) != Some("1") {
            continue;
        }
        let name = parts[2].trim();
        segments.window = if name.is_empty() {
            parts[1].trim().to_string()
        } else {
            name.to_string()
        };
        segments.pane = parts
            .get(6)
            .map(|pane| pane.trim().to_string())
            .unwrap_or_default();
        break;
    }
    segments
}

const CANDIDATE_CLIENT_RECORD: &str = "client";
const CANDIDATE_WINDOW_RECORD: &str = "window";

fn parse_candidate_inventory(raw: &str) -> (Vec<TmuxClient>, String) {
    parse_candidate_inventory_for_backend(raw, "local")
}

fn parse_candidate_inventory_for_backend(raw: &str, backend_id: &str) -> (Vec<TmuxClient>, String) {
    let client_prefix = format!("{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}");
    let window_prefix = format!("{CANDIDATE_WINDOW_RECORD}{TMUX_FIELD_SEP}");
    let mut clients = Vec::new();
    let mut windows = Vec::new();
    for line in raw.lines() {
        if let Some(client) = line
            .strip_prefix(&client_prefix)
            .and_then(|line| parse_tmux_client_for_backend(line, backend_id))
        {
            clients.push(client);
        } else if let Some(window) = line.strip_prefix(&window_prefix) {
            windows.push(window);
        }
    }
    (clients, windows.join("\n"))
}

fn same_client_processes(previous: &[TmuxClient], current: &[TmuxClient]) -> bool {
    let mut previous_pids: Vec<i64> = previous.iter().map(|client| client.client_pid).collect();
    let mut current_pids: Vec<i64> = current.iter().map(|client| client.client_pid).collect();
    previous_pids.sort_unstable();
    current_pids.sort_unstable();
    previous_pids == current_pids
}

async fn build_candidates(
    tmux_path: Option<&str>,
    ctx: &Context,
    previous_client_snapshot: &ClientSnapshot,
    local_config: &LocalTmuxConfig,
) -> Option<CandidateBuild> {
    if tmux_path.is_none() {
        return Some(CandidateBuild {
            candidates: Vec::new(),
            client_snapshot: ClientSnapshot::default(),
            client_count: 0,
            raw_line_count: 0,
            status: TmuxStatusSegments::default(),
        });
    }
    let client_format = format!(
        "{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    // The trailing `pane_index` (the window's active pane, per tmux
    // list-windows semantics) feeds the `#{plugin:tmux.pane}` status
    // segment; candidates themselves ignore it.
    let window_format = format!(
        "{CANDIDATE_WINDOW_RECORD}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{window_index}}{TMUX_FIELD_SEP}#{{window_name}}{TMUX_FIELD_SEP}#{{pane_current_command}}{TMUX_FIELD_SEP}#{{pane_current_path}}{TMUX_FIELD_SEP}#{{window_active}}{TMUX_FIELD_SEP}#{{pane_index}}"
    );
    // A single tmux process per socket emits both inventories. Polling the two
    // commands separately doubled process creation and socket discovery for
    // the plugin's one-second freshness contract.
    let raw = match run_tmux_inventory_default(
        tmux_path,
        &[
            "list-clients",
            "-F",
            &client_format,
            ";",
            "list-windows",
            "-a",
            "-F",
            &window_format,
        ],
    )
    .await
    {
        TmuxAggregate::Output(raw) => raw,
        TmuxAggregate::Absent => {
            return Some(CandidateBuild {
                candidates: Vec::new(),
                client_snapshot: ClientSnapshot::default(),
                client_count: 0,
                raw_line_count: 0,
                status: TmuxStatusSegments::default(),
            });
        }
        TmuxAggregate::TransientFailure => return None,
    };
    let (clients, raw) = parse_candidate_inventory(&raw);
    let client_by_session = client_by_session(&clients);
    let pmap = if clients.is_empty() {
        Arc::new(HashMap::new())
    } else if same_client_processes(&previous_client_snapshot.clients, &clients) {
        Arc::clone(&previous_client_snapshot.parent_map)
    } else {
        Arc::new(parent_pid_map().await)
    };
    let mut terminal_pid_by_session: HashMap<String, Option<i64>> = HashMap::new();
    for (session, client) in &client_by_session {
        terminal_pid_by_session.insert(
            session.clone(),
            find_top_level_ancestor(client.client_pid, &pmap),
        );
    }
    let (window_title_by_client_pid, window_handle_by_client_pid) = if clients.is_empty() {
        (Arc::new(HashMap::new()), Arc::new(HashMap::new()))
    } else if same_client_processes(&previous_client_snapshot.clients, &clients)
        && !previous_client_snapshot
            .window_title_by_client_pid
            .is_empty()
        && !previous_client_snapshot
            .window_handle_by_client_pid
            .is_empty()
    {
        (
            Arc::clone(&previous_client_snapshot.window_title_by_client_pid),
            Arc::clone(&previous_client_snapshot.window_handle_by_client_pid),
        )
    } else {
        let (titles, handles) =
            discover_local_client_windows(ctx, &clients, &pmap, &local_config.label).await;
        (Arc::new(titles), Arc::new(handles))
    };
    let client_snapshot = ClientSnapshot {
        clients: clients.clone(),
        parent_map: Arc::clone(&pmap),
        window_title_by_client_pid: Arc::clone(&window_title_by_client_pid),
        window_handle_by_client_pid: Arc::clone(&window_handle_by_client_pid),
    };

    let home = std::env::var("HOME").unwrap_or_default();
    let raw_line_count = raw.split('\n').filter(|line| !line.is_empty()).count();
    let backend = CandidateBackend {
        id: "local".to_string(),
        label: local_config.label.clone(),
        terminal_window_title: local_config.terminal_window_title.clone(),
        ..CandidateBackend::default()
    };
    let candidates = build_candidates_from_window_list(
        &raw,
        &clients,
        &terminal_pid_by_session,
        &window_title_by_client_pid,
        &window_handle_by_client_pid,
        &home,
        &backend,
    );
    let status = status_segments(&clients, &raw);
    Some(CandidateBuild {
        candidates,
        client_snapshot,
        client_count: clients.len(),
        raw_line_count,
        status,
    })
}

struct RemoteCandidateBuild {
    candidates: Vec<Candidate>,
    client_count: usize,
    raw_line_count: usize,
}

async fn build_remote_candidates(
    config: &RemoteTmuxConfig,
    terminal_pid: Option<i64>,
) -> Result<RemoteCandidateBuild, CliResult> {
    let client_format = format!(
        "{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    let window_format = format!(
        "{CANDIDATE_WINDOW_RECORD}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{window_index}}{TMUX_FIELD_SEP}#{{window_name}}{TMUX_FIELD_SEP}#{{pane_current_command}}{TMUX_FIELD_SEP}#{{pane_current_path}}{TMUX_FIELD_SEP}#{{window_active}}{TMUX_FIELD_SEP}#{{pane_index}}"
    );
    let result = run_remote_tmux(
        config,
        &[
            "list-clients",
            "-F",
            &client_format,
            ";",
            "list-windows",
            "-a",
            "-F",
            &window_format,
        ],
        Duration::from_secs(7),
    )
    .await;
    if !result.ok {
        if is_absent_tmux_server(&result) {
            return Ok(RemoteCandidateBuild {
                candidates: Vec::new(),
                client_count: 0,
                raw_line_count: 0,
            });
        }
        return Err(result);
    }
    let (clients, raw) = parse_candidate_inventory_for_backend(&result.stdout, &config.id);
    let terminal_pid_by_session = clients
        .iter()
        .map(|client| (client.session.clone(), terminal_pid))
        .collect();
    let backend = CandidateBackend {
        id: config.id.clone(),
        label: config.label.clone(),
        terminal_window_title: config.terminal_window_title.clone(),
        terminal_window_handle: config.terminal_window_handle,
        terminal_pid: Some(config.terminal_pid)
            .filter(|pid| *pid > 0)
            .or(terminal_pid),
        remote: true,
    };
    let raw_line_count = raw.lines().filter(|line| !line.is_empty()).count();
    let candidates = build_candidates_from_window_list(
        &raw,
        &clients,
        &terminal_pid_by_session,
        &HashMap::new(),
        &HashMap::new(),
        &config.home,
        &backend,
    );
    Ok(RemoteCandidateBuild {
        candidates,
        client_count: clients.len(),
        raw_line_count,
    })
}

/// Identity hash of the complete host-visible and routing row set. Used by
/// [`refresh_candidate_locations_for_path`] to skip the `publish` only when
/// every field is unchanged — including current-location state and the payload
/// that identifies the tmux client.
///
/// Without this gate, event-triggered refreshes would push a full catalog
/// replacement across the wire every second even when tmux state was
/// identical.
fn hash_candidates(candidates: &[Candidate]) -> u64 {
    let mut hasher = DefaultHasher::new();
    candidates.len().hash(&mut hasher);
    for candidate in candidates {
        candidate.title.hash(&mut hasher);
        candidate.url.hash(&mut hasher);
        let mut metadata = candidate.metadata.iter().collect::<Vec<_>>();
        metadata.sort_unstable_by_key(|(key, _)| *key);
        for (key, value) in metadata {
            key.hash(&mut hasher);
            value.hash(&mut hasher);
        }
        match &candidate.effect {
            Some(CandidateEffect::CopyText { text }) => {
                1u8.hash(&mut hasher);
                text.hash(&mut hasher);
            }
            Some(CandidateEffect::InsertText { text }) => {
                2u8.hash(&mut hasher);
                text.hash(&mut hasher);
            }
            Some(CandidateEffect::Open { url, bundle_id }) => {
                3u8.hash(&mut hasher);
                url.hash(&mut hasher);
                bundle_id.hash(&mut hasher);
            }
            None => 0u8.hash(&mut hasher),
        }
    }
    hasher.finish()
}

/// Rebuild the warm locations and store them **only when the
/// candidate hash differs from the last store**. The dedup gate is what
/// keeps unchanged refreshes as no-ops — see the module-level "Warm-location
/// contract" docs.
///
/// On a transient tmux failure (e.g. every usable socket invocation timed out)
/// we leave the previous warm locations in place: the host keeps pulling
/// them for synchronous reads, and the next successful refresh re-syncs. We
/// do *not* store an empty set in this case — nuking the warm cache to `[]`
/// would make tmux windows vanish from flashlight every time a single
/// socket call hiccuped.
#[derive(Default)]
struct CandidateRefreshCoordinator {
    lock: tokio::sync::Mutex<()>,
}

#[derive(Default)]
struct CandidatePartitions {
    local: Vec<Candidate>,
    remote: BTreeMap<String, RemoteCandidatePartition>,
}

struct RemoteCandidatePartition {
    candidates: Vec<Candidate>,
    refreshed_at: Instant,
}

#[derive(Clone)]
enum CandidatePartition {
    Local,
    Remote(String),
}

impl CandidateRefreshCoordinator {
    async fn run<T>(&self, work: impl Future<Output = T>) -> T {
        let _guard = self.lock.lock().await;
        work.await
    }
}

#[allow(clippy::too_many_arguments)]
async fn refresh_candidate_locations_for_path(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
    partitions: &Mutex<CandidatePartitions>,
    last_status: &Mutex<Option<TmuxStatusSegments>>,
    local_config: &LocalTmuxConfig,
    coordinator: &CandidateRefreshCoordinator,
) {
    let requested_at = Instant::now();
    coordinator
        .run(async {
            let queue_wait_ms = requested_at.elapsed().as_millis();
            refresh_candidate_locations_for_path_inner(
                tmux_path,
                ctx,
                last_hash,
                client_snapshot,
                partitions,
                last_status,
                local_config,
                CandidateRefreshTiming {
                    requested_at,
                    queue_wait_ms,
                },
            )
            .await;
        })
        .await;
}

struct CandidateRefreshTiming {
    requested_at: Instant,
    queue_wait_ms: u128,
}

#[allow(clippy::too_many_arguments)]
async fn refresh_candidate_locations_for_path_inner(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
    partitions: &Mutex<CandidatePartitions>,
    last_status: &Mutex<Option<TmuxStatusSegments>>,
    local_config: &LocalTmuxConfig,
    timing: CandidateRefreshTiming,
) {
    let previous_client_snapshot = client_snapshot
        .lock()
        .map(|snapshot| snapshot.clone())
        .unwrap_or_default();
    let build_result =
        build_candidates(tmux_path, ctx, &previous_client_snapshot, local_config).await;
    let elapsed_ms = timing.requested_at.elapsed().as_millis();
    let work_ms = elapsed_ms.saturating_sub(timing.queue_wait_ms);
    let Some(build) = build_result else {
        let fields = candidate_refresh_log_fields(
            "failed",
            elapsed_ms,
            timing.queue_wait_ms,
            work_ms,
            None,
            None,
        );
        ctx.log_fields(
            "debug",
            "[tmux] candidate refresh skipped — tmux transient failure",
            fields.clone(),
        );
        warn_if_candidate_refresh_slow(ctx, fields, elapsed_ms);
        return;
    };
    if let Ok(mut guard) = client_snapshot.lock() {
        *guard = build.client_snapshot.clone();
    }
    // Status segments piggyback on this refresh regardless of the candidate
    // hash gate below: a client switching sessions changes the segments
    // without changing the window list.
    publish_status_segments(ctx, last_status, &build.status);
    let local_candidate_count = build.candidates.len();
    let (changed, aggregate_count) = replace_candidate_partition_and_publish(
        CandidatePartition::Local,
        build.candidates,
        ctx,
        partitions,
        last_hash,
    );
    let unchanged = !changed;
    if unchanged {
        // Still useful to record that we refreshed — at trace level so a
        // healthy cache doesn't drown out other plugins. The warm
        // locations are untouched, so the flashlight surface
        // doesn't repaint.
        let fields = candidate_refresh_log_fields(
            "ok",
            elapsed_ms,
            timing.queue_wait_ms,
            work_ms,
            Some(aggregate_count),
            Some("unchanged"),
        );
        ctx.log_fields(
            "debug",
            "[tmux] candidate refresh (unchanged)",
            fields.clone(),
        );
        warn_if_candidate_refresh_slow(ctx, fields, elapsed_ms);
        return;
    }
    let mut fields = candidate_refresh_log_fields(
        if local_candidate_count == 0 {
            "empty"
        } else {
            "ok"
        },
        elapsed_ms,
        timing.queue_wait_ms,
        work_ms,
        Some(aggregate_count),
        Some("published"),
    );
    fields.insert(
        "local_candidates".to_string(),
        local_candidate_count.to_string(),
    );
    fields.insert("clients".to_string(), build.client_count.to_string());
    fields.insert("raw_lines".to_string(), build.raw_line_count.to_string());
    ctx.log_fields("debug", "[tmux] candidate refresh (emit)", fields.clone());
    warn_if_candidate_refresh_slow(ctx, fields, elapsed_ms);
}

/// Emit the `session` / `window` / `pane` statusbar segments when their
/// values changed since the last publish. Piggybacks on the candidate
/// refresh cadence — no timer of its own — and stays quiet on unchanged
/// state so the 1 s poll does not spam the host's telemetry lane. Empty
/// values (no attached local client, no tmux server) clear the segments
/// host-side per the wire contract.
fn publish_status_segments(
    ctx: &Context,
    last_status: &Mutex<Option<TmuxStatusSegments>>,
    current: &TmuxStatusSegments,
) {
    let Ok(mut guard) = last_status.lock() else {
        return;
    };
    if guard.as_ref() == Some(current) {
        return;
    }
    *guard = Some(current.clone());
    ctx.status([
        ("session", current.session.as_str()),
        ("window", current.window.as_str()),
        ("pane", current.pane.as_str()),
    ]);
}

fn replace_candidate_partition_and_publish(
    partition: CandidatePartition,
    candidates: Vec<Candidate>,
    ctx: &Context,
    partitions: &Mutex<CandidatePartitions>,
    last_hash: &Mutex<Option<u64>>,
) -> (bool, usize) {
    let Ok(mut state) = partitions.lock() else {
        return (false, 0);
    };
    match partition {
        CandidatePartition::Local => state.local = candidates,
        CandidatePartition::Remote(backend_id) => {
            state.remote.insert(
                backend_id,
                RemoteCandidatePartition {
                    candidates,
                    refreshed_at: Instant::now(),
                },
            );
        }
    }
    publish_candidate_partitions(&state, ctx, last_hash)
}

fn publish_candidate_partitions(
    state: &CandidatePartitions,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
) -> (bool, usize) {
    let remote_count = state
        .remote
        .values()
        .map(|partition| partition.candidates.len())
        .sum::<usize>();
    let mut aggregate = Vec::with_capacity(state.local.len() + remote_count);
    aggregate.extend(state.local.iter().cloned());
    for partition in state.remote.values() {
        aggregate.extend(partition.candidates.iter().cloned());
    }
    let count = aggregate.len();
    let new_hash = hash_candidates(&aggregate);
    let Ok(mut previous_hash) = last_hash.lock() else {
        return (false, count);
    };
    if *previous_hash == Some(new_hash) {
        return (false, count);
    }
    *previous_hash = Some(new_hash);
    ctx.publish(aggregate);
    (true, count)
}

fn retain_remote_candidate_partitions(
    active_backend_ids: &BTreeSet<String>,
    ctx: &Context,
    partitions: &Mutex<CandidatePartitions>,
    last_hash: &Mutex<Option<u64>>,
) -> (bool, usize) {
    let Ok(mut state) = partitions.lock() else {
        return (false, 0);
    };
    let previous_len = state.remote.len();
    state
        .remote
        .retain(|backend_id, _| active_backend_ids.contains(backend_id));
    if state.remote.len() == previous_len {
        let count = state.local.len()
            + state
                .remote
                .values()
                .map(|partition| partition.candidates.len())
                .sum::<usize>();
        return (false, count);
    }
    publish_candidate_partitions(&state, ctx, last_hash)
}

fn expire_remote_candidate_partition_state(
    state: &mut CandidatePartitions,
    backend_id: &str,
    now: Instant,
    stale_after: Duration,
) -> (bool, Option<Duration>) {
    let age = state
        .remote
        .get(backend_id)
        .map(|partition| now.saturating_duration_since(partition.refreshed_at));
    let expired = age.is_some_and(|age| age >= stale_after);
    if expired {
        state.remote.remove(backend_id);
    }
    (expired, age)
}

fn expire_remote_candidate_partition_and_publish(
    backend_id: &str,
    now: Instant,
    stale_after: Duration,
    ctx: &Context,
    partitions: &Mutex<CandidatePartitions>,
    last_hash: &Mutex<Option<u64>>,
) -> (bool, usize, Option<Duration>) {
    let Ok(mut state) = partitions.lock() else {
        return (false, 0, None);
    };
    let (expired, age) =
        expire_remote_candidate_partition_state(&mut state, backend_id, now, stale_after);
    if expired {
        let (_, count) = publish_candidate_partitions(&state, ctx, last_hash);
        (true, count, age)
    } else {
        let count = state.local.len()
            + state
                .remote
                .values()
                .map(|partition| partition.candidates.len())
                .sum::<usize>();
        (false, count, age)
    }
}

fn candidate_refresh_log_fields(
    outcome: &str,
    elapsed_ms: u128,
    queue_wait_ms: u128,
    work_ms: u128,
    candidates: Option<usize>,
    change: Option<&str>,
) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    fields.insert("outcome".to_string(), outcome.to_string());
    fields.insert("elapsed_ms".to_string(), elapsed_ms.to_string());
    fields.insert("queue_wait_ms".to_string(), queue_wait_ms.to_string());
    fields.insert("work_ms".to_string(), work_ms.to_string());
    if let Some(candidates) = candidates {
        fields.insert("candidates".to_string(), candidates.to_string());
    }
    if let Some(change) = change {
        fields.insert("change".to_string(), change.to_string());
    }
    fields
}

fn warn_if_candidate_refresh_slow(
    ctx: &Context,
    fields: BTreeMap<String, String>,
    elapsed_ms: u128,
) {
    if elapsed_ms >= SLOW_CANDIDATE_REFRESH_MS {
        ctx.log_fields("warn", "[tmux] candidate refresh slow", fields);
    }
}

fn cli_failure_detail(result: &CliResult) -> String {
    let detail = result
        .stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if detail.is_empty() {
        format!("status={}", result.status)
    } else {
        detail.chars().take(240).collect()
    }
}

async fn refresh_candidate_locations(plugin: &Tmux, ctx: &Context) {
    let local_config = plugin.local_config();
    refresh_candidate_locations_for_path(
        plugin.resolved_tmux_path().await,
        ctx,
        plugin.last_locations_hash(),
        plugin.client_snapshot(),
        plugin.candidate_partitions(),
        plugin.last_status_segments(),
        &local_config,
        plugin.candidate_refresh_coordinator(),
    )
    .await;
}

async fn refresh_remote_candidate_locations(
    config: &RemoteTmuxConfig,
    ctx: &Context,
    partitions: &Mutex<CandidatePartitions>,
    last_hash: &Mutex<Option<u64>>,
) -> bool {
    let started_at = Instant::now();
    let build = match build_remote_candidates(config, Some(config.terminal_pid)).await {
        Ok(build) => build,
        Err(result) => {
            let (expired, aggregate_count, stale_age) =
                expire_remote_candidate_partition_and_publish(
                    &config.id,
                    Instant::now(),
                    Duration::from_secs(REMOTE_CANDIDATE_STALE_AFTER_SECS),
                    ctx,
                    partitions,
                    last_hash,
                );
            let mut fields = BTreeMap::from([
                ("backend".to_string(), config.label.clone()),
                (
                    "elapsed_ms".to_string(),
                    started_at.elapsed().as_millis().to_string(),
                ),
                ("outcome".to_string(), "failed".to_string()),
                ("error".to_string(), cli_failure_detail(&result)),
                ("candidates".to_string(), aggregate_count.to_string()),
            ]);
            if let Some(age) = stale_age {
                fields.insert("stale_ms".to_string(), age.as_millis().to_string());
            }
            fields.insert(
                "change".to_string(),
                if expired {
                    "expired"
                } else if stale_age.is_some() {
                    "preserved"
                } else {
                    "none"
                }
                .to_string(),
            );
            let message = if expired {
                "[tmux] remote candidate refresh failed; expired stale snapshot"
            } else if stale_age.is_some() {
                "[tmux] remote candidate refresh failed; preserving last good"
            } else {
                "[tmux] remote candidate refresh failed; no snapshot"
            };
            ctx.log_fields("warn", message, fields);
            return false;
        }
    };
    let remote_candidate_count = build.candidates.len();
    let (changed, aggregate_count) = replace_candidate_partition_and_publish(
        CandidatePartition::Remote(config.id.clone()),
        build.candidates,
        ctx,
        partitions,
        last_hash,
    );
    ctx.log_fields(
        "debug",
        "[tmux] remote candidate refresh",
        BTreeMap::from([
            ("backend".to_string(), config.label.clone()),
            ("candidates".to_string(), aggregate_count.to_string()),
            (
                "remote_candidates".to_string(),
                remote_candidate_count.to_string(),
            ),
            ("clients".to_string(), build.client_count.to_string()),
            ("raw_lines".to_string(), build.raw_line_count.to_string()),
            (
                "change".to_string(),
                if changed { "published" } else { "unchanged" }.to_string(),
            ),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
            ("outcome".to_string(), "ok".to_string()),
        ]),
    );
    true
}

async fn refresh_remote_backends(
    configs: &BTreeMap<String, RemoteTmuxConfig>,
    ctx: &Context,
    partitions: Arc<Mutex<CandidatePartitions>>,
    last_hash: Arc<Mutex<Option<u64>>>,
) -> bool {
    let active_backend_ids = configs.keys().cloned().collect::<BTreeSet<_>>();
    retain_remote_candidate_partitions(&active_backend_ids, ctx, &partitions, &last_hash);
    let mut refreshes = tokio::task::JoinSet::new();
    for config in configs.values() {
        let config = config.clone();
        let ctx = ctx.clone();
        let partitions = Arc::clone(&partitions);
        let last_hash = Arc::clone(&last_hash);
        refreshes.spawn(async move {
            refresh_remote_candidate_locations(&config, &ctx, &partitions, &last_hash).await
        });
    }
    let mut succeeded = true;
    while let Some(result) = refreshes.join_next().await {
        succeeded &= result.unwrap_or(false);
    }
    succeeded
}

const POLL_INTERVAL_SECS: u64 = 1;
const STARTUP_WARM_BUDGET: Duration = Duration::from_secs(10);

fn start_candidate_poll(plugin: &Tmux, ctx: &Context, retry_immediately: bool) {
    let tmux_path = std::sync::Arc::clone(&plugin.tmux_path);
    let last_hash = std::sync::Arc::clone(&plugin.last_locations_hash_arc);
    let client_snapshot = std::sync::Arc::clone(&plugin.client_snapshot_arc);
    let partitions = std::sync::Arc::clone(&plugin.candidate_partitions_arc);
    let last_status = std::sync::Arc::clone(&plugin.last_status_segments_arc);
    let coordinator = std::sync::Arc::clone(&plugin.candidate_refresh_coordinator_arc);
    let local_config = plugin.local_config();
    let ctx = ctx.clone();
    tokio::spawn(async move {
        let path = tmux_path.get_or_init(find_tmux).await.clone();
        if retry_immediately {
            refresh_candidate_locations_for_path(
                path.as_deref(),
                &ctx,
                &last_hash,
                &client_snapshot,
                &partitions,
                &last_status,
                &local_config,
                &coordinator,
            )
            .await;
        }
        loop {
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
            refresh_candidate_locations_for_path(
                path.as_deref(),
                &ctx,
                &last_hash,
                &client_snapshot,
                &partitions,
                &last_status,
                &local_config,
                &coordinator,
            )
            .await;
        }
    });
}

fn start_remote_candidate_poll(plugin: &Tmux, ctx: &Context, initial_succeeded: bool) {
    let remote_configs = std::sync::Arc::clone(&plugin.remote_configs_arc);
    let partitions = std::sync::Arc::clone(&plugin.candidate_partitions_arc);
    let last_hash = std::sync::Arc::clone(&plugin.last_locations_hash_arc);
    let ctx = ctx.clone();
    tokio::spawn(async move {
        let mut failure_index = if initial_succeeded { 0 } else { 1 };
        loop {
            let delay = if failure_index == 0 {
                REMOTE_POLL_INTERVAL_SECS
            } else {
                REMOTE_RETRY_DELAYS_SECS
                    [(failure_index - 1).min(REMOTE_RETRY_DELAYS_SECS.len() - 1)]
            };
            tokio::time::sleep(Duration::from_secs(delay)).await;
            let discovered = discover_remote_tmux_configs(&ctx).await;
            if let Ok(mut configured) = remote_configs.lock() {
                *configured = discovered.clone();
            }
            if refresh_remote_backends(
                &discovered,
                &ctx,
                Arc::clone(&partitions),
                Arc::clone(&last_hash),
            )
            .await
            {
                failure_index = 0;
            } else {
                failure_index = (failure_index + 1).min(REMOTE_RETRY_DELAYS_SECS.len());
            }
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

async fn switch_client(plugin: &Tmux, client: &TmuxClient, target: &str) -> bool {
    run_tmux_for_client(
        plugin,
        client,
        &["switch-client", "-c", &client.tty, "-t", target],
    )
    .await
    .is_some()
}

async fn tab_select(plugin: &Tmux, client: &TmuxClient, index: Option<i64>) -> bool {
    let Some(idx) = index else {
        return false;
    };
    if idx <= 0 {
        return false;
    }
    let Some(raw) = run_tmux_for_client(
        plugin,
        client,
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
    switch_client(plugin, client, &target).await
}

async fn tab_adjacent(plugin: &Tmux, client: &TmuxClient, direction: &str) -> bool {
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
    run_tmux_for_client(plugin, client, &[cmd, "-t", &session_target])
        .await
        .is_some()
}

async fn tab_extreme(plugin: &Tmux, client: &TmuxClient, end: &str) -> bool {
    // First/last via native window indexing: tmux accepts numeric
    // indices and the special `{start}`/`{end}` aliases. `{end}` is
    // exactly "the last window in the session" and `{start}` is the
    // first — no need to list and pick.
    let alias = if end == "first" { "{start}" } else { "{end}" };
    let session_target = format!("{}:{}", client.session, alias);
    run_tmux_for_client(plugin, client, &["select-window", "-t", &session_target])
        .await
        .is_some()
}

async fn tab_new(plugin: &Tmux, ctx: &Context, client: &TmuxClient) -> bool {
    let current_path = trimmed(
        run_tmux_for_client(
            plugin,
            client,
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
    let created = match run_tmux_for_client_capture(
        plugin,
        client,
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
                    "[tmux] new-window failed with cwd; retrying without cwd detail_bytes={}",
                    err.len()
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
            match run_tmux_for_client_capture(plugin, client, &bare, Duration::from_secs(2)).await {
                Ok(out) => trimmed(Some(out)),
                Err(err) => {
                    ctx.log(
                        "warn",
                        &format!(
                            "[tmux] new-window failed status=error detail_bytes={}",
                            err.len()
                        ),
                    );
                    None
                }
            }
        }
    };
    let Some(created) = created else { return false };
    switch_client(plugin, client, &format!("{}:{}", client.session, created)).await
}

async fn pane_split(plugin: &Tmux, ctx: &Context, client: &TmuxClient, vertical: bool) -> bool {
    let Some(pane_target) = trimmed(
        run_tmux_for_client(
            plugin,
            client,
            &["display-message", "-c", &client.tty, "-p", "#{pane_id}"],
        )
        .await,
    ) else {
        ctx.log("warn", "[tmux] split-window could not resolve current pane");
        return false;
    };
    let current_path = trimmed(
        run_tmux_for_client(
            plugin,
            client,
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
    // User-facing orientation names describe the resulting pane geometry.
    // Tmux's `-h` means "split the window horizontally", which creates a
    // vertical divider and side-by-side panes; `-v` creates stacked panes.
    let split_flag = if vertical { "-h" } else { "-v" };
    let orientation = if vertical { "vertical" } else { "horizontal" };
    let mut attempt: Vec<String> = vec![
        "split-window".into(),
        split_flag.into(),
        "-P".into(),
        "-F".into(),
        "#{pane_id}".into(),
        "-t".into(),
        pane_target.clone(),
    ];
    if let Some(ref path) = current_path {
        attempt.push("-c".into());
        attempt.push(path.clone());
    }
    let created = match run_tmux_for_client_capture(
        plugin,
        client,
        &attempt.iter().map(String::as_str).collect::<Vec<_>>(),
        Duration::from_secs(2),
    )
    .await
    {
        Ok(out) => trimmed(Some(out)),
        Err(err) if current_path.is_some() => {
            ctx.log(
                "warn",
                &format!(
                    "[tmux] split-window failed with cwd; retrying without cwd \
                     orientation={} detail_bytes={}",
                    orientation,
                    err.len()
                ),
            );
            let bare = [
                "split-window",
                split_flag,
                "-P",
                "-F",
                "#{pane_id}",
                "-t",
                &pane_target,
            ];
            match run_tmux_for_client_capture(plugin, client, &bare, Duration::from_secs(2)).await {
                Ok(out) => trimmed(Some(out)),
                Err(err) => {
                    ctx.log(
                        "warn",
                        &format!(
                            "[tmux] split-window failed orientation={} detail_bytes={}",
                            orientation,
                            err.len()
                        ),
                    );
                    None
                }
            }
        }
        Err(err) => {
            ctx.log(
                "warn",
                &format!(
                    "[tmux] split-window failed orientation={} detail_bytes={}",
                    orientation,
                    err.len()
                ),
            );
            None
        }
    };
    let Some(created) = created else { return false };
    let _ = created;
    ctx.log_fields(
        "debug",
        "[tmux] pane split",
        BTreeMap::from([("orientation".to_string(), orientation.to_string())]),
    );
    true
}

async fn tab_close(plugin: &Tmux, ctx: &Context, client: &TmuxClient) -> bool {
    // Pin the kill to the EXACT window the focused client displays, resolved
    // from its own tty, rather than the session's ambiguous "current window".
    // `kill-window -t <session>` is correct only when the session's
    // current-window pointer matches what *this* client shows — a second client
    // on the same session, a grouped session, or a same-named session on another
    // socket can leave them diverged, so `x` closed a window the user wasn't
    // looking at ("sometimes closes the wrong tab"). The client's `#{window_id}`
    // (`@N`, unique + stable across index renumbering) removes that ambiguity.
    //
    // Fall back to `-t <session>` when the tty lookup fails so a transient
    // `display-message` error still closes *a* window rather than dropping to
    // the host's ⌘W fallback (which quits the whole terminal app).
    let window_id = trimmed(
        run_tmux_for_client(
            plugin,
            client,
            &["display-message", "-c", &client.tty, "-p", "#{window_id}"],
        )
        .await,
    );
    let target = window_id.clone().unwrap_or_else(|| client.session.clone());
    // Destructive kills always go through `confirm-before` on the client the
    // user is looking at — matching the user's own prefix bindings (`bind &
    // confirm-before … kill-window`), so a Flash-initiated close is never
    // more dangerous than a tmux-native one. The command returns once the
    // prompt is posted; the kill itself only runs on `y`.
    // `-t` targets the client the user is looking at (`-c` is tmux's
    // CONFIRM-KEY flag, not target-client); `-b` posts the prompt without
    // blocking this invocation until the user answers.
    let ok = run_tmux_for_client(
        plugin,
        client,
        &[
            "confirm-before",
            "-b",
            "-t",
            &client.tty,
            "-p",
            "kill window \"#W\"? (y/n)",
            &format!("kill-window -t {target}"),
        ],
    )
    .await
    .is_some();
    ctx.log_fields(
        "debug",
        "[tmux] tab close",
        BTreeMap::from([
            (
                "resolved_window_id".to_string(),
                window_id.is_some().to_string(),
            ),
            ("ok".to_string(), ok.to_string()),
        ]),
    );
    ok
}

async fn pane_close(plugin: &Tmux, ctx: &Context, client: &TmuxClient) -> bool {
    let Some(pane_id) = trimmed(
        run_tmux_for_client(
            plugin,
            client,
            &["display-message", "-c", &client.tty, "-p", "#{pane_id}"],
        )
        .await,
    ) else {
        ctx.log("warn", "[tmux] pane close could not resolve current pane");
        return false;
    };
    // Same confirmation contract as tab_close: destructive, so prompt on
    // the user's client first (their own `bind x` does exactly this).
    // `-b` = non-blocking post, `-t` = target-client.
    let ok = run_tmux_for_client(
        plugin,
        client,
        &[
            "confirm-before",
            "-b",
            "-t",
            &client.tty,
            "-p",
            "kill pane #P \"#{pane_current_command}\"? (y/n)",
            &format!("kill-pane -t {pane_id}"),
        ],
    )
    .await
    .is_some();
    ctx.log_fields(
        "debug",
        "[tmux] pane close",
        BTreeMap::from([("ok".to_string(), ok.to_string())]),
    );
    ok
}

/// `cmd+[` / `cmd+]`: cycle the active pane of the client's current window.
/// `:.+` / `:.-` are tmux's pane-relative selectors (the built-in `o`
/// gesture), wrapping at the ends. Scoped to `<session>:` so the cycle
/// targets the window this client is showing, mirroring `tab_adjacent`.
async fn pane_select(plugin: &Tmux, client: &TmuxClient, direction: &str) -> bool {
    let selector = if direction == "next" { ".+" } else { ".-" };
    let target = format!("{}:{}", client.session, selector);
    run_tmux_for_client(plugin, client, &["select-pane", "-t", &target])
        .await
        .is_some()
}

/// `[m` / `]m`: swap the focused window with its neighbour in the same
/// session. Tmux is happy to wrap (`-d` keeps the window selected at
/// its new position), so the user can keep tapping `]m` to bubble a
/// window to the end without rebinding.
async fn tab_move(plugin: &Tmux, client: &TmuxClient, direction: &str) -> bool {
    let neighbour = if direction == "next" { "+1" } else { "-1" };
    let target = format!("{}:{}", client.session, neighbour);
    run_tmux_for_client(plugin, client, &["swap-window", "-d", "-t", &target])
        .await
        .is_some()
}

async fn reload_client(plugin: &Tmux, client: &TmuxClient) -> bool {
    run_tmux_for_client(plugin, client, &["refresh-client", "-t", &client.tty])
        .await
        .is_some()
}

/// These actions are safe to route from the continuously refreshed client
/// snapshot once the cached client's current session has been checked through
/// its tty. Destructive and one-shot actions continue to pay for a complete
/// fresh client/process snapshot before they run.
fn source_action_prefers_warm_client(name: &str) -> bool {
    matches!(
        name,
        "tab_next"
            | "tab_prev"
            | "tab_move_next"
            | "tab_move_previous"
            | "pane_next"
            | "pane_previous"
    )
}

async fn warm_source_action_client(
    plugin: &Tmux,
    ctx: &Context,
    pid: i64,
) -> Option<(TmuxClient, &'static str)> {
    let mut client = focused_tmux_client(plugin, ctx, pid, false).await?;
    if client.remote {
        // Remote focus resolution already fetched a current client inventory.
        return Some((client, "remote"));
    }
    client.session = trimmed(
        run_tmux_for_client(
            plugin,
            &client,
            &[
                "display-message",
                "-c",
                &client.tty,
                "-p",
                "#{session_name}",
            ],
        )
        .await,
    )?;
    Some((client, "warm"))
}

async fn source_action_client(
    plugin: &Tmux,
    ctx: &Context,
    pid: i64,
    action: &str,
) -> Option<(TmuxClient, &'static str)> {
    if source_action_prefers_warm_client(action) {
        if let Some(client) = warm_source_action_client(plugin, ctx, pid).await {
            return Some(client);
        }
    }
    focused_tmux_client(plugin, ctx, pid, true)
        .await
        .map(|client| (client, "fresh"))
}

async fn perform_action(plugin: &Tmux, ctx: &Context, req: &ActionRequest) -> PerformResponse {
    let Some(pid) = req.context.pid else {
        ctx.log(
            "debug",
            &format!(
                "[tmux] source_action {} unhandled: no context.pid",
                req.name
            ),
        );
        return PerformResponse::unhandled();
    };
    let resolution_started = Instant::now();
    let Some((client, client_resolution)) = source_action_client(plugin, ctx, pid, &req.name).await
    else {
        let clients = list_clients(plugin.resolved_tmux_path().await).await;
        let pmap = parent_pid_map().await;
        ctx.log(
            "warn",
            &format!(
                "[tmux] source_action {} unhandled: no hosted tmux client | {}",
                req.name,
                client_resolution_diag(pid, &clients, &pmap)
            ),
        );
        return PerformResponse::unhandled();
    };
    let resolution_ms = resolution_started.elapsed().as_millis();
    let action_started = Instant::now();
    let ok = match req.name.as_str() {
        "tab_select" => tab_select(plugin, &client, req.index()).await,
        "tab_next" => tab_adjacent(plugin, &client, "next").await,
        "tab_prev" => tab_adjacent(plugin, &client, "previous").await,
        "tab_first" => tab_extreme(plugin, &client, "first").await,
        "tab_last" => tab_extreme(plugin, &client, "last").await,
        "tab_new" => tab_new(plugin, ctx, &client).await,
        "tab_close" => tab_close(plugin, ctx, &client).await,
        "tab_move_next" => tab_move(plugin, &client, "next").await,
        "tab_move_previous" => tab_move(plugin, &client, "previous").await,
        "pane_next" => pane_select(plugin, &client, "next").await,
        "pane_previous" => pane_select(plugin, &client, "previous").await,
        "pane_split_vertical" => pane_split(plugin, ctx, &client, true).await,
        "pane_split_horizontal" => pane_split(plugin, ctx, &client, false).await,
        "pane_close" => pane_close(plugin, ctx, &client).await,
        "app_reload" => reload_client(plugin, &client).await,
        _ => return PerformResponse::unhandled(),
    };
    let action_ms = action_started.elapsed().as_millis();
    ctx.log_fields(
        "debug",
        "[tmux] source action",
        BTreeMap::from([
            ("action".to_string(), req.name.clone()),
            ("action_ms".to_string(), action_ms.to_string()),
            (
                "client_resolution".to_string(),
                client_resolution.to_string(),
            ),
            ("ok".to_string(), ok.to_string()),
            ("resolution_ms".to_string(), resolution_ms.to_string()),
        ]),
    );
    // A tmux client hosts the focused terminal, so this source owns the
    // action either way: a failed tmux command must report an error (not
    // `unhandled`) or the host would fall back to a ⌘-keystroke that
    // doesn't mean "tab" in a terminal.
    if ok {
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail("tmux action failed")
    }
}

// ---- Candidate resolution ---------------------------------------------------

/// Pick the client `switch-client` should drive for `target`.
///
/// Priority order:
///   1. A client already attached to the target session. Switching it
///      between windows of its own session is the least-surprising
///      gesture — it keeps each terminal window pinned to "its"
///      session instead of hijacking whichever client was last active.
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

async fn switch_routed_target(plugin: &Tmux, client: &TmuxClient, target: &str) -> bool {
    let mut args: Vec<&str> = vec!["switch-client"];
    if !client.tty.is_empty() {
        args.push("-c");
        args.push(&client.tty);
    }
    args.push("-t");
    args.push(target);
    if run_tmux_for_client(plugin, client, &args).await.is_some() {
        return true;
    }
    // A disappeared/replaced client can leave a stale tty in the one-second
    // local or five-second remote snapshot. Retry without `-c` only in that
    // uncommon case; a healthy jump is always exactly one tmux invocation.
    !client.tty.is_empty()
        && run_tmux_for_client(plugin, client, &["switch-client", "-t", target])
            .await
            .is_some()
}

async fn resolve(plugin: &Tmux, ctx: &Context, row: &Candidate) -> PerformResponse {
    let started_at = Instant::now();
    let payload = row.payload_as::<TmuxPayload>().unwrap_or_default();
    let target = payload.tmux_target.as_str();
    if target.is_empty() || payload.backend_id.is_empty() {
        ctx.log("warn", "[tmux] resolve missing routed target");
        return PerformResponse::fail("resolve missing routed target");
    }

    if payload.remote && plugin.remote_config(&payload.backend_id).is_none() {
        ctx.log(
            "warn",
            "[tmux] resolve remote backend is no longer configured",
        );
        return PerformResponse::fail("remote backend no longer configured");
    }
    if !payload.remote && payload.backend_id != "local" {
        ctx.log("warn", "[tmux] resolve unknown local backend");
        return PerformResponse::fail("unknown local backend");
    }

    // Candidate inventory already carries the exact client tty and terminal
    // window. Use that warm route directly: a remote jump must not pay a fresh
    // `list-clients` SSH round trip before the actual `switch-client`. Focus the
    // terminal concurrently so the app/window transition starts immediately.
    let mut route_client = routed_client_from_payload(&payload);
    let mut terminal_pid = cached_terminal_pid(plugin, &payload);
    let warm_route = route_client.is_some();
    let focus_started = terminal_pid.is_some();
    let switch = async {
        match route_client.as_ref() {
            Some(client) => switch_routed_target(plugin, client, target).await,
            None => false,
        }
    };
    let focus = async {
        match terminal_pid {
            Some(pid) => {
                raise_terminal_window(
                    ctx,
                    pid,
                    payload.terminal_window_handle,
                    &payload.terminal_window_title,
                )
                .await
            }
            None => false,
        }
    };
    let (mut switched, _) = tokio::join!(switch, focus);

    // First-run or stale-payload fallback. Normal warm candidates never enter
    // this branch; it keeps recovery correct after a client reconnect/race.
    let mut fallback_used = false;
    if !switched {
        fallback_used = true;
        route_client = if payload.remote {
            match plugin.remote_config(&payload.backend_id) {
                Some(config) => remote_client_for_target(&config, Some(target)).await,
                None => None,
            }
        } else {
            select_client_for_target(plugin.resolved_tmux_path().await, target).await
        };
        if let Some(client) = route_client.as_ref() {
            switched = switch_routed_target(plugin, client, target).await;
            if terminal_pid.is_none() && !client.remote {
                let parent_map = parent_pid_map().await;
                terminal_pid = find_top_level_ancestor(client.client_pid, &parent_map);
            }
        }
    }
    if !switched {
        ctx.log("warn", "[tmux] resolve failed");
        return PerformResponse::fail("switch-client failed");
    }

    if terminal_pid.is_none() {
        // Preserve the previous last-resort behavior for malformed legacy
        // payloads while avoiding it on every healthy resolution.
        if let Some(client) = route_client.as_ref().filter(|client| !client.remote) {
            let parent_map = parent_pid_map().await;
            terminal_pid = find_top_level_ancestor(client.client_pid, &parent_map);
        }
    }
    if !focus_started {
        if let Some(pid) = terminal_pid {
            let _ = raise_terminal_window(
                ctx,
                pid,
                payload.terminal_window_handle,
                &payload.terminal_window_title,
            )
            .await;
        }
    }
    ctx.log_fields(
        "debug",
        "[tmux] candidate resolve latency",
        BTreeMap::from([
            ("backend".to_string(), payload.backend_id.clone()),
            ("warm_route".to_string(), warm_route.to_string()),
            ("fallback".to_string(), fallback_used.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
        ]),
    );

    resolve_response(
        &routed_tmux_target(&payload.backend_id, target),
        route_client
            .as_ref()
            .map(|client| client.tty.as_str())
            .unwrap_or(&payload.tmux_client_tty),
        terminal_pid,
        ctx,
    )
}

fn resolve_response(
    target: &str,
    tty: &str,
    terminal_pid: Option<i64>,
    ctx: &Context,
) -> PerformResponse {
    let mut fields = BTreeMap::new();
    fields.insert("used_client".to_string(), (!tty.is_empty()).to_string());
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
    let mut response = PerformResponse::ok().navigation_url(tmux_navigation_url("window", target));
    if let Some(pid) = terminal_pid {
        response = response.target_pid(pid);
    }
    response
}

// ---- Commands (`:tmux …` jump-to mappings) ----------------------------------

/// `perform {kind: "command"}` for `:tmux session <name>` and `:tmux window
/// <session:index>`. Both switch the user's active tmux client to the
/// requested target and return the terminal pid hosting it so Flash can
/// raise that window. The target argument is taken verbatim from the
/// first command arg, so a mapping like
/// `["flash", "plugin_command", "command=tmux", "subcommand=window", "args=main:1"]`
/// jumps straight to `main:1`.
async fn invoke_command(plugin: &Tmux, ctx: &Context, cmd: &CommandRequest) -> PerformResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    match cmd.subcommand.as_str() {
        "session" | "window" => {}
        other => {
            return PerformResponse::fail(format!("unknown subcommand: {other}"));
        }
    }

    let target = cmd.args.first().map(|s| s.trim()).filter(|s| !s.is_empty());
    let Some(target) = target else {
        ctx.log("warn", "[tmux] command missing target argument");
        return PerformResponse::fail("missing target argument");
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
        return PerformResponse::fail("switch-client failed");
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
    if let Some(pid) = terminal_pid {
        let _ = raise_terminal_window(ctx, pid, None, &plugin.local_config().terminal_window_title)
            .await;
    }
    let response = PerformResponse::ok().navigation_url(tmux_navigation_url(
        route_kind,
        &routed_tmux_target("local", target),
    ));
    match terminal_pid {
        Some(tp) => response.target_pid(tp),
        None => response,
    }
}

async fn restore_navigation(
    plugin: &Tmux,
    ctx: &Context,
    request: &NavigateRequest,
) -> PerformResponse {
    let started_at = Instant::now();
    let Some((kind, target)) = parse_tmux_navigation_url(&request.url) else {
        return PerformResponse::unhandled();
    };
    let Some((backend_id, tmux_target)) = split_routed_tmux_target(&target) else {
        return PerformResponse::unhandled();
    };
    let remote = backend_id != "local";
    let remote_config = if remote {
        let Some(config) = plugin.remote_config(backend_id) else {
            return PerformResponse::unhandled();
        };
        Some(config)
    } else {
        None
    };
    let cached_payload = cached_payload_for_route(plugin, backend_id, tmux_target);
    let mut route_client = cached_payload.as_ref().and_then(routed_client_from_payload);
    let warm_route = route_client.is_some();
    let terminal_window_title = cached_payload
        .as_ref()
        .map(|payload| payload.terminal_window_title.clone())
        .filter(|title| !title.is_empty())
        .or_else(|| {
            remote_config
                .as_ref()
                .map(|config| config.terminal_window_title.clone())
        })
        .unwrap_or_else(|| plugin.local_config().terminal_window_title);
    let terminal_window_handle = cached_payload
        .as_ref()
        .and_then(|payload| payload.terminal_window_handle)
        .or_else(|| {
            remote_config
                .as_ref()
                .and_then(|config| config.terminal_window_handle)
        });
    let mut terminal_pid = cached_payload
        .as_ref()
        .and_then(|payload| cached_terminal_pid(plugin, payload))
        .or_else(|| remote_config.as_ref().map(|config| config.terminal_pid));
    let focus_started = terminal_pid.is_some();
    let switch = async {
        match route_client.as_ref() {
            Some(client) => switch_routed_target(plugin, client, tmux_target).await,
            None => false,
        }
    };
    let focus = async {
        match terminal_pid {
            Some(pid) => {
                raise_terminal_window(ctx, pid, terminal_window_handle, &terminal_window_title)
                    .await
            }
            None => false,
        }
    };
    let (mut switched, _) = tokio::join!(switch, focus);

    let mut fallback_used = false;
    if !switched {
        fallback_used = true;
        route_client = if let Some(config) = remote_config.as_ref() {
            remote_client_for_target(config, Some(tmux_target)).await
        } else {
            select_client_for_target(plugin.resolved_tmux_path().await, tmux_target).await
        };
        if let Some(client) = route_client.as_ref() {
            switched = switch_routed_target(plugin, client, tmux_target).await;
        }
    }
    if !switched {
        ctx.log("warn", "[tmux] navigation restore failed");
        return PerformResponse::fail("navigation restore failed");
    }

    if terminal_pid.is_none() {
        if let Some(client) = route_client.as_ref().filter(|client| !client.remote) {
            let pmap = parent_pid_map().await;
            terminal_pid = find_top_level_ancestor(client.client_pid, &pmap);
        }
    }
    if !focus_started {
        if let Some(pid) = terminal_pid {
            let _ = raise_terminal_window(ctx, pid, terminal_window_handle, &terminal_window_title)
                .await;
        }
    }
    ctx.log_fields(
        "debug",
        "[tmux] navigation restored",
        BTreeMap::from([
            ("kind".to_string(), kind),
            ("warm_route".to_string(), warm_route.to_string()),
            ("fallback".to_string(), fallback_used.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
            (
                "target_pid".to_string(),
                terminal_pid
                    .map(|pid| pid.to_string())
                    .unwrap_or_else(|| "nil".to_string()),
            ),
        ]),
    );
    let mut response = PerformResponse::ok().navigation_url(request.url.clone());
    if let Some(pid) = terminal_pid {
        response = response.target_pid(pid);
    }
    response
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
    fn extract_links_keeps_quoted_unicode_and_relative_paths() {
        assert_eq!(
            extract_links(r#""/Applications/Flash 🧪.app""#, 1000),
            vec![(1, "/Applications/Flash 🧪.app".to_string())]
        );
        assert_eq!(
            extract_links(r#""/Applications/Flash 🧪.app/Contents/MacOS/flash""#, 1000),
            vec![(
                1,
                "/Applications/Flash 🧪.app/Contents/MacOS/flash".to_string()
            )]
        );
        assert_eq!(
            extract_links("edit Sources/FlashCore/JumpTarget.swift", 1000),
            vec![(5, "Sources/FlashCore/JumpTarget.swift".to_string())]
        );
        assert_eq!(
            extract_links(r#""Sources/FlashCore/JumpTarget.swift""#, 1000),
            vec![(1, "Sources/FlashCore/JumpTarget.swift".to_string())]
        );
        assert_eq!(
            extract_links("open ~/.dotfiles/setup.sh", 1000),
            vec![(5, "~/.dotfiles/setup.sh".to_string())]
        );
    }

    #[test]
    fn extract_links_drops_dotted_code_identifiers() {
        assert!(extract_links("JumpTarget.entersInsertMode", 1000).is_empty());
        assert!(extract_links("SomeType.someHTTPHandler", 1000).is_empty());

        assert_eq!(
            extract_links("JumpTarget.swift", 1000),
            vec![(0, "JumpTarget.swift".to_string())]
        );
    }

    #[test]
    fn tmux_panes_and_links_stay_normal_and_only_links_use_link_semantics() {
        let pane = build_target(
            "pane",
            0.0,
            0.0,
            10.0,
            10.0,
            PANE_TARGET_ROLE,
            "%1",
            42,
            TMUX_TARGET_ENTERS_INSERT_MODE,
            Priority::Urgent,
        );
        let link = build_target(
            "link",
            0.0,
            0.0,
            10.0,
            10.0,
            TERMINAL_LINK_ROLE,
            "example.com",
            42,
            TMUX_TARGET_ENTERS_INSERT_MODE,
            Priority::Normal,
        );

        assert_eq!(pane.role.as_deref(), Some("tmux-pane"));
        assert_eq!(pane.enters_insert_mode, Some(false));
        assert_eq!(link.role.as_deref(), Some("FlashTerminalLink"));
        assert_eq!(link.enters_insert_mode, Some(false));
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
            backend_id: "local".to_string(),
            remote: false,
        }
    }

    fn local_backend() -> CandidateBackend {
        CandidateBackend {
            id: "local".to_string(),
            ..CandidateBackend::default()
        }
    }

    #[test]
    fn process_tree_cache_key_uses_only_the_tmux_client_pid_set() {
        let previous = vec![
            client("/dev/ttys000", "scratch", 1443, 10),
            client("/dev/ttys001", "work", 2000, 20),
        ];
        let same_processes_new_state = vec![
            client("/dev/ttys009", "renamed", 2000, 200),
            client("/dev/ttys008", "other", 1443, 100),
        ];
        let replacement_process = vec![
            client("/dev/ttys000", "scratch", 1443, 10),
            client("/dev/ttys002", "new", 3000, 30),
        ];

        assert!(same_client_processes(&previous, &same_processes_new_state));
        assert!(!same_client_processes(&previous, &replacement_process));
    }

    #[test]
    fn repeatable_navigation_actions_prefer_the_warm_client_snapshot() {
        for action in [
            "tab_next",
            "tab_prev",
            "tab_move_next",
            "tab_move_previous",
            "pane_next",
            "pane_previous",
        ] {
            assert!(source_action_prefers_warm_client(action), "{action}");
        }
        for action in ["tab_select", "tab_new", "tab_close", "pane_close"] {
            assert!(!source_action_prefers_warm_client(action), "{action}");
        }
    }

    #[test]
    fn focused_window_handle_disambiguates_clients_in_one_terminal_process() {
        let snapshot = ClientSnapshot {
            clients: vec![
                client("/dev/ttys000", "scratch", 1443, 100),
                client("/dev/ttys001", "work", 2000, 20),
            ],
            parent_map: Arc::new(HashMap::from([(1443, 1356), (2000, 1356), (1356, 1)])),
            window_title_by_client_pid: Arc::new(HashMap::from([
                (1443, "shell".to_string()),
                (2000, "shell".to_string()),
            ])),
            window_handle_by_client_pid: Arc::new(HashMap::from([(1443, 11), (2000, 22)])),
        };

        let picked = snapshot.hosted_by_window(1356, Some(22), "shell").unwrap();

        assert_eq!(picked.session, "work");
        assert_eq!(picked.tty, "/dev/ttys001");
    }

    #[test]
    fn one_hosted_client_is_unambiguous_without_a_window_snapshot() {
        let snapshot = ClientSnapshot {
            clients: vec![client("/dev/ttys000", "scratch", 1443, 10)],
            parent_map: Arc::new(HashMap::from([(1443, 1356), (1356, 1)])),
            ..ClientSnapshot::default()
        };

        let picked = snapshot.uniquely_hosted_by(1356).unwrap();

        assert_eq!(picked.session, "scratch");
    }

    #[test]
    fn combined_candidate_inventory_splits_client_and_window_records() {
        let raw = [
            "client|||/dev/ttys000|||scratch|||1443|||100",
            "window|||scratch|||4|||flash|||node|||/tmp/work|||1",
            "window|||scratch|||5|||logs|||tail|||/tmp/work|||0",
        ]
        .join("\n");

        let (clients, windows) = parse_candidate_inventory(&raw);

        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0].client_pid, 1443);
        assert_eq!(clients[0].session, "scratch");
        assert_eq!(
            windows,
            [
                "scratch|||4|||flash|||node|||/tmp/work|||1",
                "scratch|||5|||logs|||tail|||/tmp/work|||0",
            ]
            .join("\n")
        );
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
        let routed = routed_tmux_target("local", "scratch:2");
        let url = tmux_navigation_url("window", &routed);
        assert_eq!(url, "tmux://window/local%7Cscratch:2");
        assert_eq!(
            parse_tmux_navigation_url(&url),
            Some(("window".to_string(), routed.clone()))
        );
        assert_eq!(
            split_routed_tmux_target(&routed),
            Some(("local", "scratch:2"))
        );

        let encoded_target = routed_tmux_target("remote:moria", "work/project one");
        let encoded = tmux_navigation_url("session", &encoded_target);
        assert_eq!(
            parse_tmux_navigation_url(&encoded),
            Some(("session".to_string(), encoded_target))
        );
    }

    #[test]
    fn candidate_payload_rehydrates_the_warm_client_route_without_io() {
        let payload = TmuxPayload {
            backend_id: "remote:moria".to_string(),
            tmux_target: "scratch:3".to_string(),
            tmux_client_tty: "/dev/pts/1".to_string(),
            client_pid: Some(2443),
            terminal_pid: Some(1356),
            terminal_window_handle: Some(22),
            terminal_window_title: "scratch@moria.zone".to_string(),
            remote: true,
        };

        let client = routed_client_from_payload(&payload).unwrap();

        assert_eq!(client.backend_id, "remote:moria");
        assert_eq!(client.session, "scratch");
        assert_eq!(client.tty, "/dev/pts/1");
        assert_eq!(client.client_pid, 2443);
        assert!(client.remote);
    }

    #[test]
    fn candidate_payload_without_a_client_tty_uses_the_recovery_path() {
        let payload = TmuxPayload {
            backend_id: "remote:moria".to_string(),
            tmux_target: "scratch:3".to_string(),
            remote: true,
            ..TmuxPayload::default()
        };

        assert!(routed_client_from_payload(&payload).is_none());
    }

    #[test]
    fn local_and_remote_candidates_with_the_same_tmux_target_remain_distinct() {
        let local_clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let remote_clients = vec![TmuxClient {
            tty: "/dev/pts/1".to_string(),
            session: "scratch".to_string(),
            client_pid: 2443,
            activity: 20,
            backend_id: "remote:moria".to_string(),
            remote: true,
        }];
        let raw = "scratch\t1\tcode\tzsh\t/home/ab/workspace\t1";
        let local_backend = CandidateBackend {
            id: "local".to_string(),
            label: "macbook".to_string(),
            terminal_window_title: "scratch@macbook".to_string(),
            terminal_window_handle: Some(11),
            terminal_pid: Some(1356),
            remote: false,
        };
        let remote_backend = CandidateBackend {
            id: "remote:moria".to_string(),
            label: "moria".to_string(),
            terminal_window_title: "scratch@moria.zone".to_string(),
            terminal_window_handle: Some(22),
            terminal_pid: Some(1356),
            remote: true,
        };

        let local = build_candidates_from_window_list(
            raw,
            &local_clients,
            &HashMap::new(),
            &HashMap::new(),
            &HashMap::new(),
            "/Users/ab",
            &local_backend,
        );
        let remote = build_candidates_from_window_list(
            raw,
            &remote_clients,
            &HashMap::new(),
            &HashMap::new(),
            &HashMap::new(),
            "/home/ab",
            &remote_backend,
        );

        use flash_plugin::candidate_metadata as meta;
        assert_eq!(local[0].title, "macbook · code");
        assert_eq!(remote[0].title, "moria · code");
        assert_eq!(
            local[0].meta(meta::NAVIGATION_URL),
            Some("tmux://window/local%7Cscratch:1")
        );
        assert_eq!(
            remote[0].meta(meta::NAVIGATION_URL),
            Some("tmux://window/remote:moria%7Cscratch:1")
        );
        let local_payload = local[0].payload_as::<TmuxPayload>().unwrap();
        let remote_payload = remote[0].payload_as::<TmuxPayload>().unwrap();
        assert_eq!(local_payload.backend_id, "local");
        assert!(!local_payload.remote);
        assert_eq!(local_payload.terminal_window_handle, Some(11));
        assert_eq!(remote_payload.backend_id, "remote:moria");
        assert!(remote_payload.remote);
        assert_eq!(remote_payload.terminal_window_title, "scratch@moria.zone");
        assert_eq!(remote_payload.terminal_window_handle, Some(22));
    }

    #[test]
    fn remote_inventory_marks_clients_as_remote() {
        let raw = [
            "client|||/dev/pts/1|||scratch|||2443|||200",
            "window|||scratch|||1|||code|||zsh|||/home/ab/workspace|||1",
        ]
        .join("\n");

        let (clients, windows) = parse_candidate_inventory_for_backend(&raw, "remote:moria");

        assert_eq!(clients.len(), 1);
        assert!(clients[0].remote);
        assert_eq!(windows, "scratch|||1|||code|||zsh|||/home/ab/workspace|||1");
    }

    #[test]
    fn focused_and_named_terminal_windows_are_resolved_independently() {
        let nodes = vec![
            AxWindowNode {
                handle: 11,
                attrs: HashMap::from([
                    ("AXTitle".to_string(), "scratch@macbook".to_string()),
                    ("AXFocused".to_string(), "0".to_string()),
                ]),
            },
            AxWindowNode {
                handle: 22,
                attrs: HashMap::from([
                    ("AXTitle".to_string(), "scratch@moria.zone".to_string()),
                    ("AXFocused".to_string(), "1".to_string()),
                ]),
            },
        ];

        assert_eq!(
            focused_window_title_from_nodes(&nodes),
            Some("scratch@moria.zone")
        );
        assert_eq!(window_handle_for_title(&nodes, "scratch@macbook"), Some(11));
        assert_eq!(
            window_handle_for_title(&nodes, "scratch@moria.zone"),
            Some(22)
        );
    }

    #[test]
    fn remote_ssh_command_is_argument_safe_and_reuses_a_control_connection() {
        let config = RemoteTmuxConfig {
            id: "remote:moria".to_string(),
            label: "moria".to_string(),
            host: "ab@moria.zone".to_string(),
            tmux_path: "/opt/tmux with space".to_string(),
            terminal_window_title: "scratch@moria.zone".to_string(),
            terminal_window_handle: Some(22),
            terminal_pid: 1356,
            transport_pid: 1443,
            home: "/home/ab".to_string(),
            control_path: Some(PathBuf::from("/tmp/flash-tmux/ssh-%C")),
            ssh_options: vec!["-o".to_string(), "IdentitiesOnly=yes".to_string()],
        };
        let command = remote_tmux_command(&config, &["display-message", "it's safe"]);
        let argv = remote_ssh_argv(&config, &command);

        assert!(command.contains("'/opt/tmux with space'"));
        assert!(command.contains("'it'\\''s safe'"));
        assert!(argv.contains(&"ControlMaster=auto".to_string()));
        assert!(argv.contains(&"ControlPersist=60".to_string()));
        assert!(argv.contains(&"ControlPath=/tmp/flash-tmux/ssh-%C".to_string()));
        assert_eq!(argv[argv.len() - 2], "ab@moria.zone");
        assert_eq!(argv.last(), Some(&command));
    }

    #[test]
    fn ssh_process_command_discovers_host_tmux_and_reusable_connection_options() {
        let command = "ssh -tt -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=yes ab@moria.zone \
/home/ab/.local/share/mise/shims/tmux new-session -A -s scratch -c /home/ab";

        let transport = parse_remote_transport(command, "ssh").unwrap();

        assert_eq!(transport.host, "ab@moria.zone");
        assert_eq!(transport.tmux_path, "/home/ab/.local/share/mise/shims/tmux");
        assert_eq!(transport.home, "/home/ab");
        assert!(transport.ssh_options.contains(&"-p".to_string()));
        assert!(transport.ssh_options.contains(&"2222".to_string()));
        assert!(transport
            .ssh_options
            .contains(&"IdentitiesOnly=yes".to_string()));
        assert!(!transport.ssh_options.contains(&"BatchMode=yes".to_string()));
    }

    #[test]
    fn mosh_client_marker_discovers_original_remote_tmux_command() {
        let command = "/opt/homebrew/bin/mosh-client -# --bind-server=ssh \
--port=61000:61009 --server=/usr/bin/env MOSH_SERVER_NETWORK_TMOUT=86400 \
/usr/bin/mosh-server --ssh=ssh -o BatchMode=yes -o ConnectTimeout=10 \
ab@moria.zone -- /home/ab/.local/share/mise/shims/tmux new-session -A \
-s scratch -c /home/ab | 82.65.243.222 61000";

        let transport = parse_remote_transport(command, "mosh-client").unwrap();

        assert_eq!(transport.host, "ab@moria.zone");
        assert_eq!(transport.tmux_path, "/home/ab/.local/share/mise/shims/tmux");
        assert_eq!(transport.home, "/home/ab");
    }

    #[test]
    fn terminal_title_matching_uses_host_without_terminal_brand_assumptions() {
        let nodes = vec![
            AxWindowNode {
                handle: 1,
                attrs: HashMap::from([("AXTitle".to_string(), "scratch@macbook".to_string())]),
            },
            AxWindowNode {
                handle: 2,
                attrs: HashMap::from([("AXTitle".to_string(), "scratch@moria.zone".to_string())]),
            },
        ];

        assert_eq!(
            terminal_title_for_host(&nodes, "ab@moria.zone"),
            "scratch@moria.zone"
        );
        assert!(
            local_window_title_score("scratch@macbook", "scratch", "macbook")
                > local_window_title_score("scratch@moria.zone", "scratch", "macbook")
        );
    }

    #[test]
    fn candidate_payload_uses_the_window_discovered_for_its_tmux_client() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let candidates = build_candidates_from_window_list(
            "scratch\t1\tcode\tzsh\t/Users/ab/work\t1",
            &clients,
            &HashMap::from([("scratch".to_string(), Some(1356))]),
            &HashMap::from([(1443, "scratch@macbook".to_string())]),
            &HashMap::from([(1443, 11)]),
            "/Users/ab",
            &local_backend(),
        );

        let payload = candidates[0].payload_as::<TmuxPayload>().unwrap();
        assert_eq!(payload.terminal_window_title, "scratch@macbook");
        assert_eq!(payload.terminal_window_handle, Some(11));
    }

    #[test]
    fn window_candidate_builder_emits_windows_from_all_sessions() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let terminal_pid_by_session = HashMap::from([("scratch".to_string(), Some(1356))]);
        let raw = "beside\t1\tbeside-agentic\tclaude\t/Users/ab/workspace/beside\n\
scratch\t2\tflash\tzsh\t/Users/ab/workspace/aymericbeaumet/flash\n";

        let candidates = build_candidates_from_window_list(
            raw,
            &clients,
            &terminal_pid_by_session,
            &HashMap::new(),
            &HashMap::new(),
            "/Users/ab",
            &local_backend(),
        );

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
        assert_eq!(candidates[1].source, SOURCE_WINDOWS);
        assert_eq!(
            candidates[1].meta(meta::NAVIGATION_URL),
            Some("tmux://window/local%7Cscratch:2")
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
            &HashMap::new(),
            &HashMap::new(),
            "/Users/ab",
            &local_backend(),
        );

        use flash_plugin::candidate_metadata as meta;
        // One row per session — duplicates dropped, both sockets'
        // windows present.
        assert_eq!(candidates.len(), 2);
        let sessions: Vec<&str> = candidates
            .iter()
            .map(|c| c.meta(meta::NAVIGATION_URL).unwrap_or(""))
            .collect();
        assert!(sessions.contains(&"tmux://window/local%7Cwork:1"));
        assert!(sessions.contains(&"tmux://window/local%7Cplay:1"));
        // The `play` session lives on the second socket — it would
        // have been entirely missing before the fix.
        let play = candidates
            .iter()
            .find(|c| c.meta(meta::NAVIGATION_URL) == Some("tmux://window/local%7Cplay:1"))
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

    #[test]
    fn aggregate_inventory_clears_confirmed_absent_servers() {
        let absent = CliResult {
            stderr: "no server running on /private/tmp/tmux-501/default".to_string(),
            status: 1,
            ..CliResult::default()
        };
        assert_eq!(
            classify_tmux_aggregate(&[absent], false, TmuxInventoryScope::AnyServer),
            TmuxAggregate::Absent
        );
    }

    #[test]
    fn aggregate_inventory_preserves_last_good_when_no_server_answers() {
        let timeout = CliResult {
            stderr: "timed out after 2000ms".to_string(),
            status: 124,
            ..CliResult::default()
        };
        assert_eq!(
            classify_tmux_aggregate(&[timeout], false, TmuxInventoryScope::AnyServer),
            TmuxAggregate::TransientFailure
        );
    }

    #[test]
    fn aggregate_inventory_uses_healthy_output_when_unrelated_socket_times_out() {
        let successful = CliResult {
            ok: true,
            stdout: "client|||/dev/ttys000|||work|||1443|||30\n\
window|||work|||1|||editor|||nvim|||/Users/ab/work|||1"
                .to_string(),
            status: 0,
            ..CliResult::default()
        };
        let timeout = CliResult {
            stderr: "timed out after 2000ms".to_string(),
            status: 124,
            ..CliResult::default()
        };
        assert_eq!(
            classify_tmux_aggregate(
                &[successful.clone(), timeout],
                false,
                TmuxInventoryScope::AttachedServers,
            ),
            TmuxAggregate::Output(successful.stdout)
        );
    }

    #[test]
    fn aggregate_inventory_excludes_detached_server_windows() {
        let attached = CliResult {
            ok: true,
            stdout: "client|||/dev/ttys000|||work|||1443|||30\n\
window|||work|||1|||editor|||nvim|||/Users/ab/work|||1"
                .to_string(),
            status: 0,
            ..CliResult::default()
        };
        let detached = CliResult {
            ok: true,
            stdout: "window|||scratch|||1|||stale|||zsh|||/tmp|||1".to_string(),
            status: 0,
            ..CliResult::default()
        };

        assert_eq!(
            classify_tmux_aggregate(
                &[attached.clone(), detached],
                false,
                TmuxInventoryScope::AttachedServers,
            ),
            TmuxAggregate::Output(attached.stdout)
        );
    }

    #[test]
    fn aggregate_inventory_keeps_live_outputs_when_other_servers_are_absent() {
        let successful = CliResult {
            ok: true,
            stdout: "work\t1\teditor".to_string(),
            status: 0,
            ..CliResult::default()
        };
        let absent = CliResult {
            stderr: "error connecting to /tmp/tmux-501/old (No such file or directory)".to_string(),
            status: 1,
            ..CliResult::default()
        };
        assert_eq!(
            classify_tmux_aggregate(&[successful, absent], false, TmuxInventoryScope::AnyServer,),
            TmuxAggregate::Output("work\t1\teditor".to_string())
        );
    }

    #[test]
    fn aggregate_inventory_treats_exited_control_server_as_absent() {
        let exited = CliResult {
            stderr: "server exited unexpectedly".to_string(),
            status: 1,
            ..CliResult::default()
        };

        assert_eq!(
            classify_tmux_aggregate(&[exited], false, TmuxInventoryScope::AnyServer),
            TmuxAggregate::Absent
        );
    }

    #[test]
    fn remote_candidate_partition_expires_only_after_stale_budget() {
        let now = Instant::now();
        let backend_id = "remote:moria";
        let mut state = CandidatePartitions::default();
        state.remote.insert(
            backend_id.to_string(),
            RemoteCandidatePartition {
                candidates: vec![fake_candidate("scratch:1", "remote", 1356)],
                refreshed_at: now - Duration::from_secs(119),
            },
        );

        let (expired, age) = expire_remote_candidate_partition_state(
            &mut state,
            backend_id,
            now,
            Duration::from_secs(REMOTE_CANDIDATE_STALE_AFTER_SECS),
        );
        assert!(!expired);
        assert_eq!(age, Some(Duration::from_secs(119)));
        assert!(state.remote.contains_key(backend_id));

        let (expired, age) = expire_remote_candidate_partition_state(
            &mut state,
            backend_id,
            now + Duration::from_secs(1),
            Duration::from_secs(REMOTE_CANDIDATE_STALE_AFTER_SECS),
        );
        assert!(expired);
        assert_eq!(age, Some(Duration::from_secs(120)));
        assert!(!state.remote.contains_key(backend_id));
    }

    // ---- Warm-location contract ------------------------------------------
    //
    // The dedup gate in `refresh_candidate_locations_for_path` is the
    // load-bearing invariant that prevents unchanged tmux refreshes from
    // rewriting the warm cache. These tests pin it down: any future
    // refactor that breaks them is also re-introducing the original
    // symptom (user opens flashlight and sees stale or incomplete tmux
    // candidates after a refresh catches up).

    #[tokio::test]
    async fn candidate_refresh_coordinator_serializes_overlapping_refreshes() {
        let coordinator = std::sync::Arc::new(CandidateRefreshCoordinator::default());
        let (first_started_tx, first_started_rx) = tokio::sync::oneshot::channel();
        let (release_first_tx, release_first_rx) = tokio::sync::oneshot::channel();
        let first_coordinator = std::sync::Arc::clone(&coordinator);
        let first = tokio::spawn(async move {
            first_coordinator
                .run(async move {
                    let _ = first_started_tx.send(());
                    let _ = release_first_rx.await;
                })
                .await;
        });
        first_started_rx.await.expect("first refresh started");

        let (second_started_tx, mut second_started_rx) = tokio::sync::oneshot::channel();
        let second_coordinator = std::sync::Arc::clone(&coordinator);
        let second = tokio::spawn(async move {
            second_coordinator
                .run(async move {
                    let _ = second_started_tx.send(());
                })
                .await;
        });

        assert!(
            tokio::time::timeout(Duration::from_millis(25), &mut second_started_rx)
                .await
                .is_err(),
            "the second refresh must not begin while the first owns the coordinator"
        );
        release_first_tx.send(()).expect("release first refresh");
        first.await.expect("first refresh task");
        tokio::time::timeout(Duration::from_secs(1), &mut second_started_rx)
            .await
            .expect("second refresh started after release")
            .expect("second refresh signal");
        second.await.expect("second refresh task");
    }

    fn fake_candidate(target: &str, name: &str, pid: i64) -> Candidate {
        let payload = TmuxPayload {
            backend_id: "local".to_string(),
            tmux_target: target.to_string(),
            ..TmuxPayload::default()
        };
        Candidate::new(SOURCE_WINDOWS, name)
            .kind("tmux_window")
            .location()
            .subtitle(format!("{target} · zsh · ~/work"))
            .navigation_url(tmux_navigation_url(
                "window",
                &routed_tmux_target("local", target),
            ))
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
             cache churns on every refresh"
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
             activation — a pid drift across refreshes must trigger an emit"
        );
    }

    #[test]
    fn hash_candidates_diverges_on_current_location_change() {
        let before = vec![fake_candidate("work:1", "editor", 1356)];
        let after = vec![fake_candidate("work:1", "editor", 1356).current_location(true)];

        assert_ne!(hash_candidates(&before), hash_candidates(&after));
    }

    #[test]
    fn hash_candidates_diverges_on_routing_payload_change() {
        let before = vec![fake_candidate("work:1", "editor", 1356)];
        let payload = TmuxPayload {
            backend_id: "local".to_string(),
            tmux_target: "work:1".to_string(),
            tmux_client_tty: "/dev/ttys999".to_string(),
            client_pid: Some(42),
            terminal_pid: Some(1356),
            ..TmuxPayload::default()
        };
        let after = vec![fake_candidate("work:1", "editor", 1356).payload_json(&payload)];

        assert_ne!(hash_candidates(&before), hash_candidates(&after));
    }

    #[test]
    fn status_segments_follow_the_most_recent_client_and_its_active_window() {
        let clients = vec![
            client("/dev/ttys000", "work", 100, 10),
            client("/dev/ttys001", "play", 200, 99),
        ];
        let raw = "work\t1\teditor\tnvim\t/w\t1\t2\n\
play\t1\tshell\tzsh\t/p\t0\t0\n\
play\t3\tflash\tzsh\t/p\t1\t4\n";

        assert_eq!(
            status_segments(&clients, raw),
            TmuxStatusSegments {
                session: "play".to_string(),
                window: "flash".to_string(),
                pane: "4".to_string(),
            }
        );
    }

    #[test]
    fn status_segments_fall_back_to_the_window_index_when_unnamed() {
        let clients = vec![client("/dev/ttys000", "work", 100, 10)];
        let raw = "work\t2\t\tzsh\t/w\t1\t0\n";

        let segments = status_segments(&clients, raw);
        assert_eq!(segments.session, "work");
        assert_eq!(segments.window, "2");
        assert_eq!(segments.pane, "0");
    }

    #[test]
    fn status_segments_clear_without_attached_clients() {
        assert_eq!(
            status_segments(&[], "work\t1\teditor\tnvim\t/w\t1\t0\n"),
            TmuxStatusSegments::default(),
            "no attached client publishes empty values, which clear the \
             segments host-side"
        );
    }
}

// ---- Plugin glue ------------------------------------------------------------

struct Tmux {
    tmux_path: std::sync::Arc<tokio::sync::OnceCell<Option<String>>>,
    local_config_arc: std::sync::Arc<Mutex<LocalTmuxConfig>>,
    remote_configs_arc: std::sync::Arc<Mutex<BTreeMap<String, RemoteTmuxConfig>>>,
    /// Latest eager `list-clients` + process-tree sample. Source actions
    /// need the focused tmux client, but they should not fan out across
    /// every tmux socket on the hot key path when the poller already did
    /// that work.
    client_snapshot_arc: std::sync::Arc<Mutex<ClientSnapshot>>,
    /// Hash of the last snapshot we emitted to the host. Shared by the poller
    /// and event-triggered refreshes so the dedup invariant has one source of
    /// truth.
    last_locations_hash_arc: std::sync::Arc<Mutex<Option<u64>>>,
    candidate_partitions_arc: std::sync::Arc<Mutex<CandidatePartitions>>,
    /// Last statusbar segment values emitted through the `status`
    /// notification, so the 1 s refresh only notifies on actual changes.
    last_status_segments_arc: std::sync::Arc<Mutex<Option<TmuxStatusSegments>>>,
    /// Serializes the complete build → hash → publish cycle shared by startup,
    /// the one-second poll, and push events. Without it, an older slow refresh
    /// can finish after a newer one and publish stale rows over the host's
    /// current catalog.
    candidate_refresh_coordinator_arc: std::sync::Arc<CandidateRefreshCoordinator>,
}

impl Tmux {
    fn local_config(&self) -> LocalTmuxConfig {
        self.local_config_arc
            .lock()
            .map(|config| config.clone())
            .unwrap_or_default()
    }

    fn remote_configs(&self) -> BTreeMap<String, RemoteTmuxConfig> {
        self.remote_configs_arc
            .lock()
            .map(|configs| configs.clone())
            .unwrap_or_default()
    }

    fn remote_config(&self, backend_id: &str) -> Option<RemoteTmuxConfig> {
        self.remote_configs_arc
            .lock()
            .ok()
            .and_then(|configs| configs.get(backend_id).cloned())
    }

    fn last_locations_hash(&self) -> &Mutex<Option<u64>> {
        &self.last_locations_hash_arc
    }

    fn client_snapshot(&self) -> &Mutex<ClientSnapshot> {
        &self.client_snapshot_arc
    }

    fn candidate_partitions(&self) -> &Mutex<CandidatePartitions> {
        &self.candidate_partitions_arc
    }

    fn last_status_segments(&self) -> &Mutex<Option<TmuxStatusSegments>> {
        &self.last_status_segments_arc
    }

    fn candidate_refresh_coordinator(&self) -> &CandidateRefreshCoordinator {
        &self.candidate_refresh_coordinator_arc
    }

    /// The tmux binary path, resolved (and cached) on first use via `find_tmux()`.
    /// Runs inside the SDK's async runtime so `main` never needs its own.
    async fn resolved_tmux_path(&self) -> Option<&str> {
        self.tmux_path.get_or_init(find_tmux).await.as_deref()
    }
}

flash_plugin::plugin!(Tmux);

impl FlashPlugin for Tmux {
    async fn on_start(&self, ctx: Context) {
        let local_config = local_tmux_config().await;
        if let Ok(mut local) = self.local_config_arc.lock() {
            *local = local_config;
        }
        let remotes = discover_remote_tmux_configs(&ctx).await;
        ctx.log_fields(
            "debug",
            "[tmux] process discovery",
            BTreeMap::from([
                ("remote_backends".to_string(), remotes.len().to_string()),
                (
                    "remote_transports".to_string(),
                    remotes
                        .values()
                        .map(|config| config.transport_pid)
                        .collect::<BTreeSet<_>>()
                        .len()
                        .to_string(),
                ),
            ]),
        );
        if let Ok(mut configured) = self.remote_configs_arc.lock() {
            *configured = remotes.clone();
        }
        let initial = tokio::time::timeout(STARTUP_WARM_BUDGET, async {
            if self.resolved_tmux_path().await.is_none() {
                ctx.log(
                    "debug",
                    "[tmux] no local tmux binary; remote discovery remains active",
                );
            }
            let remote_refresh = async {
                refresh_remote_backends(
                    &remotes,
                    &ctx,
                    Arc::clone(&self.candidate_partitions_arc),
                    Arc::clone(&self.last_locations_hash_arc),
                )
                .await
            };
            let (_, remote_succeeded) =
                tokio::join!(refresh_candidate_locations(self, &ctx), remote_refresh);
            remote_succeeded
        })
        .await;
        // A timed-out first cycle publishes nothing (the host keeps its
        // last-good catalog, which survives restarts); the poll retries
        // immediately.
        let degraded_initial = initial.is_err();
        if degraded_initial {
            ctx.log_fields(
                "warn",
                "[tmux] initial warm catalog timed out",
                BTreeMap::from([
                    (
                        "timeout_ms".to_string(),
                        STARTUP_WARM_BUDGET.as_millis().to_string(),
                    ),
                    ("retry".to_string(), "immediate_background".to_string()),
                ]),
            );
        }
        start_candidate_poll(self, &ctx, degraded_initial);
        start_remote_candidate_poll(self, &ctx, matches!(initial, Ok(true)));
    }

    /// Push events refresh the warm locations immediately. The poll keeps the
    /// store current between host-visible interaction boundaries.
    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:focus.changed" | "core:apps.terminated"
        ) {
            refresh_candidate_locations(self, &ctx).await;
        }
    }

    async fn on_hints(&self, ctx: Context, request: HintsRequest) -> HintsResponse {
        hints_for_context(self, &ctx, &request).await
    }

    async fn on_action(&self, ctx: Context, action: ActionRequest) -> PerformResponse {
        perform_action(self, &ctx, &action).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(self, &ctx, &row).await
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        invoke_command(self, &ctx, &command).await
    }

    async fn on_navigate(&self, ctx: Context, request: NavigateRequest) -> PerformResponse {
        restore_navigation(self, &ctx, &request).await
    }
}

fn main() {
    let plugin = Tmux {
        tmux_path: std::sync::Arc::new(tokio::sync::OnceCell::new()),
        local_config_arc: std::sync::Arc::new(Mutex::new(LocalTmuxConfig::default())),
        remote_configs_arc: std::sync::Arc::new(Mutex::new(BTreeMap::new())),
        client_snapshot_arc: std::sync::Arc::new(Mutex::new(ClientSnapshot::default())),
        last_locations_hash_arc: std::sync::Arc::new(Mutex::new(None)),
        candidate_partitions_arc: std::sync::Arc::new(Mutex::new(CandidatePartitions::default())),
        last_status_segments_arc: std::sync::Arc::new(Mutex::new(None)),
        candidate_refresh_coordinator_arc: std::sync::Arc::new(
            CandidateRefreshCoordinator::default(),
        ),
    };
    run(plugin);
}
