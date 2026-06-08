//! Tmux plugin — ports the former Python tmux plugin to Rust.
//!
//! Subscribes to focus.changed to refresh the candidate snapshot (tmux
//! window finder). On each activation Flash calls discoverTargets with the
//! focused app's pid + window frame; the plugin returns pane-chip and
//! link-chip targets in screen coordinates.
//!
//! Geometry mirrors the previous implementation:
//!   - cell size = window / cells (fallback) OR alacritty-style font
//!     metrics when alacritty.toml exposes the font (NSFont
//!     ascender/descender/advance via objc2).
//!   - pane chips: 3-cell-wide rect at pane centre.
//!   - link chips: per-regex match in `capture-pane -p` output.

use std::collections::{BTreeMap, HashMap};
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, Context, Plugin};
use regex::Regex;

const PLUGIN_ID: &str = "tmux";
const SOURCE_ID: &str = "plugin.tmux";

const TMUX_PREFIXES: [&str; 4] = ["/opt/homebrew", "/usr/local", "/opt/local", "/usr"];

const LINKS_PER_PANE_LIMIT: usize = 40;
const ALACRITTY_BUNDLES: [&str; 2] = ["org.alacritty", "io.alacritty"];

// ---- Link extraction --------------------------------------------------------

fn link_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // URLs, ~paths, absolute paths, ./ relative paths, file.ext — each
        // with an optional trailing `:LINE[:COL]` editor-jump suffix.
        let path_tail = r"(?::\d+(?::\d+)?)?";
        let boundary = r#"[^\s"'`,\[\]\(\)<>]+"#;
        let pattern = format!(
            concat!(
                r"https?://{boundary}[A-Za-z0-9/_-]",
                r#"|~/{boundary}{tail}"#,
                r#"|/[A-Za-z0-9._-][^\s"'`,\[\]\(\)<>]*{tail}"#,
                r"|\.{{1,2}}/{boundary}{tail}",
                r"|[\w.-]+\.[A-Za-z][\w-]*{tail}",
            ),
            boundary = boundary,
            tail = path_tail,
        );
        Regex::new(&pattern).expect("tmux link regex")
    })
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

fn find_tmux() -> Option<String> {
    for prefix in TMUX_PREFIXES {
        let path = format!("{prefix}/bin/tmux");
        if let Ok(meta) = std::fs::metadata(&path) {
            if meta.is_file() {
                return Some(path);
            }
        }
    }
    which("tmux")
}

fn which(program: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(program);
        if let Ok(meta) = std::fs::metadata(&candidate) {
            if meta.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    None
}

async fn run_cmd(program: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let output = tokio::time::timeout(timeout, cmd.output())
        .await
        .ok()?
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

async fn run_tmux(tmux_path: Option<&str>, args: &[&str], timeout: Duration) -> Option<String> {
    let path = tmux_path?;
    run_cmd(path, args, timeout).await
}

async fn run_tmux_default(tmux_path: Option<&str>, args: &[&str]) -> Option<String> {
    run_tmux(tmux_path, args, Duration::from_secs(2)).await
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
    let Some(out) = run_cmd("ps", &["-axo", "pid=,ppid="], Duration::from_millis(1500)).await
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

// ---- tmux clients -----------------------------------------------------------

#[derive(Clone)]
struct TmuxClient {
    tty: String,
    session: String,
    client_pid: i64,
    activity: i64,
}

async fn list_clients(tmux_path: Option<&str>) -> Vec<TmuxClient> {
    let raw = run_tmux_default(
        tmux_path,
        &[
            "list-clients",
            "-F",
            "#{client_tty}\t#{session_name}\t#{client_pid}\t#{client_activity}",
        ],
    )
    .await;
    let Some(raw) = raw else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in raw.lines() {
        let parts: Vec<&str> = line.splitn(4, '\t').collect();
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

/// Pick the tmux client whose terminal app instance hosts `focused_pid`.
/// Tie-break by `client_activity` so we pick the one the user is actively
/// typing in (single-process terminals share `focused_pid` across windows).
async fn client_hosted_by(tmux_path: Option<&str>, focused_pid: i64) -> Option<TmuxClient> {
    let clients = list_clients(tmux_path).await;
    if clients.is_empty() {
        return None;
    }
    let pmap = parent_pid_map().await;
    let mut matches: Vec<TmuxClient> = clients
        .into_iter()
        .filter(|c| is_ancestor(focused_pid, c.client_pid, &pmap))
        .collect();
    if matches.is_empty() {
        return None;
    }
    matches.sort_by(|a, b| b.activity.cmp(&a.activity));
    matches.into_iter().next()
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

fn alacritty_font() -> Option<(String, f64)> {
    let home = std::env::var("HOME").ok()?;
    let paths = [
        format!("{home}/.config/alacritty/alacritty.toml"),
        format!("{home}/.alacritty.toml"),
    ];
    for path in paths {
        let Ok(text) = std::fs::read_to_string(&path) else {
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
fn resolve_geometry(
    bundle_id: &str,
    win_w: f64,
    win_h: f64,
    cols: f64,
    rows: f64,
) -> (f64, f64, f64, f64) {
    if ALACRITTY_BUNDLES.contains(&bundle_id) {
        if let Some((family, size)) = alacritty_font() {
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

fn build_target(
    target_id: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    role: &str,
    label: &str,
    pid: i64,
) -> Value {
    json!({
        "id": target_id,
        "frame": { "x": x, "y": y, "width": width, "height": height },
        "role": role,
        "label": label,
        "accepts_text_input": true,
        "pid": pid,
        "source_id": SOURCE_ID,
    })
}

fn frame_num(frame: &Value, key: &str) -> f64 {
    frame.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

async fn discover_targets_for_context(plugin: &Tmux, params: &Value) -> Value {
    let tmux_path = plugin.tmux_path.as_deref();
    let pid = params.get("pid").and_then(Value::as_i64);
    let bundle_id = params
        .get("bundle_id")
        .and_then(Value::as_str)
        .unwrap_or("");
    let frame = params
        .get("front_window_frame")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let Some(pid) = pid else {
        return json!({ "targets": [] });
    };
    let win_w = frame_num(&frame, "width");
    let win_h = frame_num(&frame, "height");
    let min_x = frame_num(&frame, "x");
    let min_y = frame_num(&frame, "y");
    if tmux_path.is_none() || win_w <= 0.0 || win_h <= 0.0 {
        return json!({ "targets": [], "context_pid": pid });
    }

    let Some(client) = client_hosted_by(tmux_path, pid).await else {
        return json!({ "targets": [], "context_pid": pid });
    };

    let combined = run_tmux_default(
        tmux_path,
        &[
            "display-message",
            "-c",
            &client.tty,
            "-p",
            "#{client_width} #{client_height}\n#{status} #{status-position}",
        ],
    )
    .await;
    let Some(combined) = combined else {
        return json!({ "targets": [], "context_pid": pid });
    };
    let combined_lines: Vec<&str> = combined.split('\n').collect();
    if combined_lines.len() < 2 {
        return json!({ "targets": [], "context_pid": pid });
    }
    let Some((client_cols, client_rows)) = parse_two_ints(combined_lines[0]) else {
        return json!({ "targets": [], "context_pid": pid });
    };
    if client_cols <= 0 || client_rows <= 0 {
        return json!({ "targets": [], "context_pid": pid });
    }

    let (cell_w, cell_h, pad_x, pad_y) = resolve_geometry(
        bundle_id,
        win_w,
        win_h,
        client_cols as f64,
        client_rows as f64,
    );

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
        return json!({ "targets": [], "context_pid": pid });
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
        return json!({ "targets": [], "context_pid": pid });
    }

    let top_offset = parse_status_top_offset(combined_lines[1]);

    // Pane chip is 3-cells wide so the hint label is readable. Anchored at
    // pane center, chip extends 1 cell left and right.
    let pane_chip_cells: i64 = 3;
    let mut pane_targets: Vec<Value> = Vec::new();
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
        pane_targets.push(build_target(
            &target_id,
            chip_x,
            chip_y,
            pane_chip_cells as f64 * cell_w,
            cell_h,
            "tmux-pane",
            &pane.id,
            pid,
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
        let mut pane_links_seen = 0usize;
        for (row_idx, content) in raw.split('\n').enumerate() {
            if row_idx as i64 >= pane.rows {
                break;
            }
            if pane_links_seen >= LINKS_PER_PANE_LIMIT {
                break;
            }
            for (col, text) in extract_links(content, pane.cols as usize) {
                if pane_links_seen >= LINKS_PER_PANE_LIMIT {
                    break;
                }
                raw_links.push(RawLink {
                    screen_row: top_offset + pane.top + row_idx as i64,
                    screen_col: pane.left + col as i64,
                    text,
                });
                pane_links_seen += 1;
            }
        }
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
        targets.push(build_target(
            &target_id,
            x,
            y,
            cell_w,
            cell_h,
            "tmux-link",
            &link.text,
            pid,
        ));
        actions.insert(target_id, TargetAction::Link { text: link.text });
    }

    if let Ok(mut guard) = plugin.target_actions.lock() {
        *guard = actions;
    }
    json!({ "targets": targets, "context_pid": pid })
}

// ---- Candidate (tmux window finder) -----------------------------------------

/// `None` on transient tmux failure (caller preserves the previous snapshot);
/// `Some(vec)` (possibly empty) is the authoritative current window list.
async fn build_candidates(tmux_path: Option<&str>) -> Option<Vec<Value>> {
    if tmux_path.is_none() {
        return Some(Vec::new());
    }
    let clients = list_clients(tmux_path).await;
    let mut client_by_session: HashMap<String, TmuxClient> = HashMap::new();
    for client in &clients {
        client_by_session
            .entry(client.session.clone())
            .or_insert_with(|| client.clone());
    }
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

    let raw = run_tmux_default(
        tmux_path,
        &[
            "list-windows",
            "-a",
            "-F",
            "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_command}\t#{pane_current_path}",
        ],
    )
    .await?;

    let home = std::env::var("HOME").unwrap_or_default();
    let mut out = Vec::new();
    for line in raw.split('\n') {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.splitn(5, '\t').collect();
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
        if !home.is_empty() && cwd.starts_with(&home) {
            cwd = format!("~{}", &cwd[home.len()..]);
        }
        let client = client_by_session.get(session).or_else(|| clients.first());
        let terminal_pid = terminal_pid_by_session.get(session).copied().flatten();

        let head = if name.is_empty() {
            format!("{session}:{index}")
        } else {
            format!("{session}:{index} {name}")
        };
        let extras: Vec<&str> = [command, cwd.as_str()]
            .into_iter()
            .filter(|v| !v.is_empty())
            .collect();
        let title = if extras.is_empty() {
            head.clone()
        } else {
            format!("{head} · {}", extras.join(" · "))
        };
        let subtitle_extras: Vec<&str> = [name, command, cwd.as_str()]
            .into_iter()
            .filter(|v| !v.is_empty())
            .collect();
        let subtitle = if subtitle_extras.is_empty() {
            format!("tmux {session}")
        } else {
            format!("tmux {} {}", session, subtitle_extras.join(" "))
        };
        let target = format!("{session}:{index}");

        let mut candidate = json!({
            "kind": "tmux_window",
            "source_id": SOURCE_ID,
            "source": PLUGIN_ID,
            "name": title,
            "subtitle": subtitle,
            "payload": {
                "tmux_target": target,
                "tmux_client_tty": client.map(|c| c.tty.as_str()).unwrap_or(""),
                "client_pid": client.map(|c| c.client_pid),
                "terminal_pid": terminal_pid,
            },
        });
        if let Some(tp) = terminal_pid {
            candidate["pid"] = json!(tp);
        }
        out.push(candidate);
    }
    Some(out)
}

async fn refresh_candidate_snapshot(plugin: &Tmux, ctx: &Context) {
    let Some(candidates) = build_candidates(plugin.tmux_path.as_deref()).await else {
        ctx.log(
            "debug",
            "[tmux] candidate refresh skipped — tmux transient failure",
        );
        return;
    };
    ctx.emit.notify(
        "snapshot.updated",
        json!({ "targets": [], "candidates": candidates, "source_id": SOURCE_ID }),
    );
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

fn target_for_adjacent(
    direction: &str,
    session: &str,
    current_index: &str,
    indices: &[String],
) -> Option<String> {
    if indices.is_empty() {
        return None;
    }
    let offset = indices.iter().position(|i| i == current_index)?;
    let len = indices.len();
    let next = if direction == "next" {
        (offset + 1) % len
    } else {
        (offset + len - 1) % len
    };
    Some(format!("{session}:{}", indices[next]))
}

async fn switch_client(tmux_path: Option<&str>, tty: &str, target: &str) -> bool {
    run_tmux_default(tmux_path, &["switch-client", "-c", tty, "-t", target])
        .await
        .is_some()
}

async fn tab_select(tmux_path: Option<&str>, client: &TmuxClient, params: &Value) -> bool {
    let Some(idx) = params.get("index").and_then(Value::as_i64) else {
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
    let current = trimmed(
        run_tmux_default(
            tmux_path,
            &[
                "display-message",
                "-c",
                &client.tty,
                "-p",
                "#{window_index}",
            ],
        )
        .await,
    );
    let raw = run_tmux_default(
        tmux_path,
        &[
            "list-windows",
            "-t",
            &client.session,
            "-F",
            "#{window_index}",
        ],
    )
    .await;
    let (Some(current), Some(raw)) = (current, raw) else {
        return false;
    };
    let Some(target) =
        target_for_adjacent(direction, &client.session, &current, &window_indices(&raw))
    else {
        return false;
    };
    switch_client(tmux_path, &client.tty, &target).await
}

async fn tab_extreme(tmux_path: Option<&str>, client: &TmuxClient, end: &str) -> bool {
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
    let indices = window_indices(&raw);
    let Some(target_index) = (if end == "first" {
        indices.first()
    } else {
        indices.last()
    }) else {
        return false;
    };
    switch_client(
        tmux_path,
        &client.tty,
        &format!("{}:{}", client.session, target_index),
    )
    .await
}

async fn tab_new(tmux_path: Option<&str>, client: &TmuxClient) -> bool {
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
    let mut args: Vec<String> = vec![
        "new-window".into(),
        "-P".into(),
        "-F".into(),
        "#{window_index}".into(),
        "-t".into(),
        client.session.clone(),
    ];
    if let Some(path) = current_path {
        args.push("-c".into());
        args.push(path);
    }
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let Some(created) = trimmed(run_tmux_default(tmux_path, &arg_refs).await) else {
        return false;
    };
    switch_client(
        tmux_path,
        &client.tty,
        &format!("{}:{}", client.session, created),
    )
    .await
}

async fn tab_close(tmux_path: Option<&str>, client: &TmuxClient) -> bool {
    let Some(current) = trimmed(
        run_tmux_default(
            tmux_path,
            &[
                "display-message",
                "-c",
                &client.tty,
                "-p",
                "#{window_index}",
            ],
        )
        .await,
    ) else {
        return false;
    };
    run_tmux_default(
        tmux_path,
        &[
            "kill-window",
            "-t",
            &format!("{}:{}", client.session, current),
        ],
    )
    .await
    .is_some()
}

async fn perform_source_action(plugin: &Tmux, params: &Value) -> Value {
    let tmux_path = plugin.tmux_path.as_deref();
    let name = params.get("name").and_then(Value::as_str).unwrap_or("");
    let context = params.get("context").cloned().unwrap_or_else(|| json!({}));
    let Some(pid) = context.get("pid").and_then(Value::as_i64) else {
        return json!({ "did_perform": false });
    };
    let Some(client) = client_hosted_by(tmux_path, pid).await else {
        return json!({ "did_perform": false });
    };
    let ok = match name {
        "tab_select" => tab_select(tmux_path, &client, params).await,
        "tab_next" => tab_adjacent(tmux_path, &client, "next").await,
        "tab_prev" => tab_adjacent(tmux_path, &client, "previous").await,
        "tab_first" => tab_extreme(tmux_path, &client, "first").await,
        "tab_last" => tab_extreme(tmux_path, &client, "last").await,
        "tab_new" => tab_new(tmux_path, &client).await,
        "tab_close" => tab_close(tmux_path, &client).await,
        _ => return json!({ "did_perform": false }),
    };
    json!({ "did_perform": ok, "target_pid": pid })
}

// ---- Candidate resolution ---------------------------------------------------

fn parse_payload(candidate: &Value) -> Value {
    match candidate.get("payload") {
        Some(Value::String(raw)) => {
            flash_plugin::serde_json::from_str(raw).unwrap_or_else(|_| json!({}))
        }
        Some(value @ Value::Object(_)) => value.clone(),
        _ => json!({}),
    }
}

/// Pick the client to drive `switch-client`: the most-recently-active client,
/// which for single-process multi-window terminals maps to the window the
/// user just typed into. Returns the full client so the caller can both drive
/// `switch-client` on its tty and resolve the terminal app pid hosting it.
async fn resolve_active_client(tmux_path: Option<&str>) -> Option<TmuxClient> {
    let mut clients = list_clients(tmux_path).await;
    if clients.is_empty() {
        return None;
    }
    clients.sort_by(|a, b| b.activity.cmp(&a.activity));
    clients.into_iter().next()
}

async fn resolve_candidate(plugin: &Tmux, ctx: &Context, params: &Value) -> Value {
    let tmux_path = plugin.tmux_path.as_deref();
    let candidate = params
        .get("candidate")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let payload = parse_payload(&candidate);
    let target = payload
        .get("tmux_target")
        .and_then(Value::as_str)
        .unwrap_or("");
    if target.is_empty() {
        ctx.log("warn", "[tmux] resolve missing tmux_target");
        return json!({ "did_resolve": false });
    }

    let active = resolve_active_client(tmux_path).await;
    let tty = active.as_ref().map(|c| c.tty.clone()).unwrap_or_else(|| {
        payload
            .get("tmux_client_tty")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    });

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
        return json!({ "did_resolve": false });
    }

    // Recompute the terminal pid from the live client we actually drove rather
    // than the snapshot-time `terminal_pid` baked into the payload: that value
    // goes stale (or was never resolved) when the client moves between
    // snapshots, which silently strips the `target_pid` the host needs to raise
    // the terminal window. Fall back to the payload value only if the live walk
    // fails.
    let terminal_pid = match active {
        Some(ref c) => {
            let pmap = parent_pid_map().await;
            find_top_level_ancestor(c.client_pid, &pmap)
        }
        None => None,
    }
    .or_else(|| payload.get("terminal_pid").and_then(Value::as_i64));

    resolve_response(target, &tty, terminal_pid, ctx)
}

fn resolve_response(target: &str, tty: &str, terminal_pid: Option<i64>, ctx: &Context) -> Value {
    let mut response = json!({ "did_resolve": true });
    let mut fields = BTreeMap::new();
    fields.insert("target".to_string(), target.to_string());
    fields.insert("tty".to_string(), tty.to_string());
    match terminal_pid {
        Some(tp) => {
            response["target_pid"] = json!(tp);
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
    response
}

// ---- Commands (`:tmux …` jump-to mappings) ----------------------------------

/// `command.invoke` for `:tmux session <name>` and `:tmux window
/// <session:index>`. Both switch the user's active tmux client to the
/// requested target and return the terminal pid hosting it so Flash can
/// raise that window. The target argument is taken verbatim from the
/// first command arg, so a mapping like
/// `flash://plugin_command?command=tmux&subcommand=window&args=main:1`
/// jumps straight to `main:1`.
async fn invoke_command(plugin: &Tmux, ctx: &Context, params: &Value) -> Value {
    let tmux_path = plugin.tmux_path.as_deref();
    let subcommand = params
        .get("subcommand")
        .and_then(Value::as_str)
        .unwrap_or("");
    match subcommand {
        "session" | "window" => {}
        other => {
            return json!({ "ok": false, "error": format!("unknown subcommand: {other}") });
        }
    }

    let target = params
        .get("args")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let Some(target) = target else {
        ctx.log("warn", "[tmux] command missing target argument");
        return json!({ "ok": false, "error": "missing target argument" });
    };

    // `session:index` → session is the part before the first colon; a bare
    // session name has no colon and is used as-is.
    let session = target.split(':').next().unwrap_or(target);

    let clients = list_clients(tmux_path).await;
    // Drive `switch-client` with the most-recently-active client, matching
    // candidate resolution — for single-process multi-window terminals this
    // is the window the user just typed into.
    let tty = {
        let mut sorted = clients.clone();
        sorted.sort_by(|a, b| b.activity.cmp(&a.activity));
        sorted.first().map(|c| c.tty.clone()).unwrap_or_default()
    };

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
        return json!({ "ok": false, "error": "switch-client failed" });
    }

    // Terminal pid hosting the target session's client, so Flash can raise
    // the right window. Falls back to any client when the session has none.
    let terminal_pid = {
        let client = clients
            .iter()
            .find(|c| c.session == session)
            .or_else(|| clients.first());
        match client {
            Some(c) => {
                let pmap = parent_pid_map().await;
                find_top_level_ancestor(c.client_pid, &pmap)
            }
            None => None,
        }
    };

    let mut response = json!({ "ok": true });
    if let Some(tp) = terminal_pid {
        response["target_pid"] = json!(tp);
    }
    response
}

// ---- Activation -------------------------------------------------------------

async fn activate_target(plugin: &Tmux, ctx: &Context, params: &Value) {
    let tmux_path = plugin.tmux_path.as_deref();
    let target_id = params
        .get("target_id")
        .and_then(Value::as_str)
        .unwrap_or("");
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
    std::process::Command::new("open")
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

// ---- Plugin glue ------------------------------------------------------------

struct Tmux {
    tmux_path: Option<String>,
    target_actions: Mutex<HashMap<String, TargetAction>>,
}

impl Plugin for Tmux {
    async fn on_start(&self, ctx: Context) {
        if self.tmux_path.is_none() {
            ctx.log("warn", "[tmux] tmux binary not found");
        }
        refresh_candidate_snapshot(self, &ctx).await;
    }

    async fn on_event(&self, ctx: Context, name: String, _payload: Value) {
        if matches!(
            name.as_str(),
            "focus.changed" | "flash.started" | "apps.terminated"
        ) {
            refresh_candidate_snapshot(self, &ctx).await;
        }
    }

    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        match method.as_str() {
            "discoverTargets" => discover_targets_for_context(self, &params).await,
            "sourceAction" => perform_source_action(self, &params).await,
            "resolveCandidate" => resolve_candidate(self, &ctx, &params).await,
            "command.invoke" => invoke_command(self, &ctx, &params).await,
            "activateTarget" => {
                activate_target(self, &ctx, &params).await;
                json!({})
            }
            other => json!({ "ok": false, "error": format!("unknown method: {other}") }),
        }
    }
}

fn main() {
    let plugin = Tmux {
        tmux_path: find_tmux(),
        target_actions: Mutex::new(HashMap::new()),
    };
    run(plugin);
}
