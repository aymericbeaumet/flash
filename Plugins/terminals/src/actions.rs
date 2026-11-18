//! Source commands (`tab`, `pane`, `scroll`, `app reload`) performed on the
//! tmux client hosting the focused terminal.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use flash_plugin::{CommandRequest, Context, PerformResponse};

use crate::Tmux;
use crate::candidates::{routed_tmux_target, tmux_navigation_url};
use crate::clients::{
    TmuxClient, focused_tmux_client, run_tmux_for_client, run_tmux_for_client_capture,
};

fn trimmed(value: Option<String>) -> Option<String> {
    let stripped = value?.trim().to_string();
    if stripped.is_empty() {
        None
    } else {
        Some(stripped)
    }
}

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

/// The route of the window `client`'s session shows now: what a tab switch
/// landed on. It goes back in the reply so the host records the stop at
/// once, one per press; the control-mode settle folds a burst of switches
/// into one inventory read, which would show only the last.
async fn current_window_route(plugin: &Tmux, client: &TmuxClient) -> Option<String> {
    let session_target = format!("{}:", client.session);
    let window_id = trimmed(
        run_tmux_for_client(
            plugin,
            client,
            &[
                "display-message",
                "-t",
                &session_target,
                "-p",
                "#{window_id}",
            ],
        )
        .await,
    )?;
    window_route(&client.backend_id, &client.session, &window_id)
}

/// The route the window rows carry for `window_id` (`@N`) of `session` on
/// `backend_id`: the target the inventory builds, so the host's stop and the
/// row it publishes next are one.
fn window_route(backend_id: &str, session: &str, window_id: &str) -> Option<String> {
    if !window_id.starts_with('@') {
        return None;
    }
    Some(tmux_navigation_url(
        "window",
        &routed_tmux_target(backend_id, &format!("{session}:{window_id}")),
    ))
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
    // The kill runs straight away: the host already asked. A destructive
    // command is gated by `confirm` on its manifest `commands[]` entry, shown
    // as Flash's own confirmation before the command reaches this plugin, so
    // a Flash-initiated close is never more dangerous than the user's own
    // `bind & confirm-before … kill-window`. A tmux-side `confirm-before`
    // would ask a second time, on a prompt NORMAL mode's capture swallows
    // the `y` for.
    let args = kill_window_args(&target);
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    let ok = run_tmux_for_client(plugin, client, &args).await.is_some();
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
    // Same contract as `tab close`: the host confirmed before dispatching
    // (`confirm` on the entry), so the pane is killed without a tmux prompt.
    let args = kill_pane_args(&pane_id);
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    let ok = run_tmux_for_client(plugin, client, &args).await.is_some();
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

/// `gg` / `G` inside a pane, routed the way tmux routes the wheel (its default
/// `WheelUpPane` binding, which `ctrl-u` / `ctrl-d` go through): a pane in a
/// mode scrolls that mode; a program that turned on mouse tracking owns its
/// scrolling, so it receives wheel reports; any other pane scrolls tmux's
/// history in copy-mode, whose bottom is the live pane. Driving copy-mode for
/// a mouse-tracking program scrolled the shell history behind it instead, and
/// `G` had no copy-mode to cancel.
async fn scroll_extreme(plugin: &Tmux, client: &TmuxClient, top: bool) -> bool {
    let target = format!("{}:.", client.session);
    let Some(state) = run_tmux_for_client(
        plugin,
        client,
        &["display-message", "-p", "-t", &target, PANE_SCROLL_FORMAT],
    )
    .await
    .as_deref()
    .and_then(PaneScrollState::parse) else {
        return false;
    };
    match ScrollExtremePlan::new(&state, top) {
        ScrollExtremePlan::ModeCommand(command) => {
            run_tmux_for_client(plugin, client, &["send-keys", "-X", "-t", &target, command])
                .await
                .is_some()
        }
        ScrollExtremePlan::EnterHistoryTop => {
            run_tmux_for_client(plugin, client, &["copy-mode", "-t", &target])
                .await
                .is_some()
                && run_tmux_for_client(
                    plugin,
                    client,
                    &["send-keys", "-X", "-t", &target, "history-top"],
                )
                .await
                .is_some()
        }
        ScrollExtremePlan::AlreadyLive => true,
        ScrollExtremePlan::WheelReports(report) => {
            let count = EDGE_WHEEL_REPORTS.to_string();
            run_tmux_for_client(
                plugin,
                client,
                &["send-keys", "-t", &target, "-N", &count, "-l", &report],
            )
            .await
            .is_some()
        }
    }
}

const PANE_SCROLL_FORMAT: &str =
    "#{pane_in_mode} #{mouse_any_flag} #{mouse_sgr_flag} #{pane_width} #{pane_height}";

/// Wheel reports one `gg` / `G` sends a mouse-tracking program: enough to
/// reach either end of a long transcript, one small `send-keys -N` command.
const EDGE_WHEEL_REPORTS: u32 = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PaneScrollState {
    in_mode: bool,
    mouse_tracking: bool,
    sgr_mouse: bool,
    width: u32,
    height: u32,
}

impl PaneScrollState {
    fn parse(line: &str) -> Option<Self> {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let [in_mode, mouse, sgr, width, height] = fields.as_slice() else {
            return None;
        };
        Some(Self {
            in_mode: *in_mode == "1",
            mouse_tracking: *mouse == "1",
            sgr_mouse: *sgr == "1",
            width: width.parse().ok()?,
            height: height.parse().ok()?,
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
enum ScrollExtremePlan {
    /// A copy-mode command inside the pane's current mode.
    ModeCommand(&'static str),
    /// Enter copy-mode, then jump to the top of the history.
    EnterHistoryTop,
    /// A pane outside any mode already shows its live bottom.
    AlreadyLive,
    /// One wheel report, sent `EDGE_WHEEL_REPORTS` times as literal text
    /// (`send-keys -H` delivers nothing to the pane on tmux 3.7).
    WheelReports(String),
}

impl ScrollExtremePlan {
    fn new(state: &PaneScrollState, top: bool) -> Self {
        if state.in_mode {
            return Self::ModeCommand(if top { "history-top" } else { "cancel" });
        }
        if state.mouse_tracking {
            return Self::WheelReports(wheel_report(state, top));
        }
        if top {
            Self::EnterHistoryTop
        } else {
            Self::AlreadyLive
        }
    }
}

/// An xterm wheel report (button 64 up, 65 down) at the pane's centre, in
/// the SGR encoding when the program asked for it, else the classic one,
/// whose coordinates stay ASCII (so single-byte in its UTF-8 variant too).
fn wheel_report(state: &PaneScrollState, up: bool) -> String {
    let button: u32 = if up { 64 } else { 65 };
    let x = (state.width / 2).max(1);
    let y = (state.height / 2).max(1);
    if state.sgr_mouse {
        return format!("\x1b[<{button};{x};{y}M");
    }
    let classic = |value: u32| char::from_u32(32 + value.min(95)).unwrap_or(' ');
    format!("\x1b[M{}{}{}", classic(button), classic(x), classic(y))
}

/// `[m` / `]m`: swap the focused window with its neighbour in the same
/// session. Tmux is happy to wrap (`-d` keeps the window selected at
/// its new position), so the user can keep tapping `]m` to bubble a
/// window to the end without rebinding.
async fn tab_move(plugin: &Tmux, client: &TmuxClient, direction: &str) -> bool {
    let args = tab_move_args(&client.session, direction);
    let args: Vec<_> = args.iter().map(String::as_str).collect();
    run_tmux_for_client(plugin, client, &args).await.is_some()
}

/// `kill-window` pinned to the client's own window id (or its session when
/// the id lookup failed). No `confirm-before`: the host asked already.
fn kill_window_args(target: &str) -> Vec<String> {
    vec![
        "kill-window".to_string(),
        "-t".to_string(),
        target.to_string(),
    ]
}

/// `kill-pane` pinned to the client's current pane id, host-confirmed.
fn kill_pane_args(pane_id: &str) -> Vec<String> {
    vec![
        "kill-pane".to_string(),
        "-t".to_string(),
        pane_id.to_string(),
    ]
}

fn tab_move_args(session: &str, direction: &str) -> Vec<String> {
    let neighbour = if direction == "next" { "+1" } else { "-1" };
    vec![
        "swap-window".to_string(),
        "-d".to_string(),
        "-s".to_string(),
        format!("{session}:"),
        "-t".to_string(),
        format!("{session}:{neighbour}"),
    ]
}

async fn reload_client(plugin: &Tmux, client: &TmuxClient) -> bool {
    run_tmux_for_client(plugin, client, &["refresh-client", "-t", &client.tty])
        .await
        .is_some()
}

/// These commands are safe to route from the continuously refreshed client
/// snapshot once the cached client's current session has been checked through
/// its tty. Destructive and one-shot commands continue to pay for a complete
/// fresh client/process snapshot before they run.
fn source_command_prefers_warm_client(command: &str, subcommand: &str) -> bool {
    matches!(
        (command, subcommand),
        ("tab", "next" | "previous" | "move_next" | "move_previous")
            | ("pane", "next" | "previous")
    )
}

async fn warm_source_command_client(
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

async fn source_command_client(
    plugin: &Tmux,
    ctx: &Context,
    pid: i64,
    command: &CommandRequest,
) -> Option<(TmuxClient, &'static str)> {
    if source_command_prefers_warm_client(&command.command, &command.subcommand)
        && let Some(client) = warm_source_command_client(plugin, ctx, pid).await
    {
        return Some(client);
    }
    focused_tmux_client(plugin, ctx, pid, true)
        .await
        .map(|client| (client, "fresh"))
}

/// A core command the manifest declares under Flash's `tab`, `pane`,
/// `scroll` and `app` topics, performed by the tmux client hosting the
/// focused terminal. A terminal without one is `unhandled`, so the host
/// sends the emulator's own chord instead.
pub(crate) async fn perform_source_command(
    plugin: &Tmux,
    ctx: &Context,
    req: &CommandRequest,
) -> PerformResponse {
    let name = req.name();
    let Some(pid) = req.context.as_ref().and_then(|context| context.pid) else {
        ctx.log(
            "debug",
            &format!("[tmux] source_command {name} unhandled: no context.pid"),
        );
        return PerformResponse::unhandled();
    };
    let resolution_started = Instant::now();
    let Some((client, client_resolution)) = source_command_client(plugin, ctx, pid, req).await
    else {
        // A terminal without tmux is the common case: the host falls back to
        // the app's chord at once, without waiting on a diagnostic scan.
        ctx.log(
            "debug",
            &format!("[tmux] source_command {name} unhandled: no hosted tmux client pid={pid}"),
        );
        return PerformResponse::unhandled();
    };
    let resolution_ms = resolution_started.elapsed().as_millis();
    let action_started = Instant::now();
    let ok = match (req.command.as_str(), req.subcommand.as_str()) {
        ("tab", "select") => tab_select(plugin, &client, req.index()).await,
        ("tab", "next") => tab_adjacent(plugin, &client, "next").await,
        ("tab", "previous") => tab_adjacent(plugin, &client, "previous").await,
        ("tab", "first") => tab_extreme(plugin, &client, "first").await,
        ("tab", "last") => tab_extreme(plugin, &client, "last").await,
        ("tab", "new") => tab_new(plugin, ctx, &client).await,
        ("tab", "close") => tab_close(plugin, ctx, &client).await,
        ("tab", "move_next") => tab_move(plugin, &client, "next").await,
        ("tab", "move_previous") => tab_move(plugin, &client, "previous").await,
        ("pane", "next") => pane_select(plugin, &client, "next").await,
        ("pane", "previous") => pane_select(plugin, &client, "previous").await,
        ("pane", "split_vertical") => pane_split(plugin, ctx, &client, true).await,
        ("pane", "split_horizontal") => pane_split(plugin, ctx, &client, false).await,
        ("pane", "close") => pane_close(plugin, ctx, &client).await,
        ("scroll", "top") => scroll_extreme(plugin, &client, true).await,
        ("scroll", "bottom") => scroll_extreme(plugin, &client, false).await,
        // `--force` means nothing to a tmux client refresh.
        ("app", "reload") => reload_client(plugin, &client).await,
        _ => return PerformResponse::unhandled(),
    };
    let command_ms = action_started.elapsed().as_millis();
    let navigation_url = if ok
        && matches!(
            (req.command.as_str(), req.subcommand.as_str()),
            ("tab", "select" | "next" | "previous" | "first" | "last")
        ) {
        current_window_route(plugin, &client).await
    } else {
        None
    };
    ctx.log_fields(
        "debug",
        "[tmux] source command",
        BTreeMap::from([
            ("command".to_string(), name),
            ("command_ms".to_string(), command_ms.to_string()),
            (
                "client_resolution".to_string(),
                client_resolution.to_string(),
            ),
            ("ok".to_string(), ok.to_string()),
            ("resolution_ms".to_string(), resolution_ms.to_string()),
        ]),
    );
    // A tmux client hosts the focused terminal, so this source owns the
    // command either way: a failed tmux command must report an error (not
    // `unhandled`) or the host would fall back to a ⌘-keystroke that
    // doesn't mean "tab" in a terminal.
    if ok {
        let mut response = PerformResponse::ok().target_pid(pid);
        if let Some(url) = navigation_url {
            response = response.navigation_url(url);
        }
        response
    } else {
        PerformResponse::fail("tmux command failed")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(in_mode: bool, mouse_tracking: bool, sgr_mouse: bool) -> PaneScrollState {
        PaneScrollState {
            in_mode,
            mouse_tracking,
            sgr_mouse,
            width: 120,
            height: 40,
        }
    }

    #[test]
    fn scroll_extremes_follow_tmux_wheel_routing() {
        // A pane in a mode scrolls that mode, even over a mouse-tracking program.
        assert_eq!(
            ScrollExtremePlan::new(&pane(true, true, true), true),
            ScrollExtremePlan::ModeCommand("history-top")
        );
        assert_eq!(
            ScrollExtremePlan::new(&pane(true, false, false), false),
            ScrollExtremePlan::ModeCommand("cancel")
        );
        // A mouse-tracking program owns its scrolling.
        assert_eq!(
            ScrollExtremePlan::new(&pane(false, true, true), false),
            ScrollExtremePlan::WheelReports("\x1b[<65;60;20M".to_string())
        );
        assert_eq!(
            ScrollExtremePlan::new(&pane(false, true, true), true),
            ScrollExtremePlan::WheelReports("\x1b[<64;60;20M".to_string())
        );
        // Anything else scrolls tmux history; its bottom is the live pane.
        assert_eq!(
            ScrollExtremePlan::new(&pane(false, false, false), true),
            ScrollExtremePlan::EnterHistoryTop
        );
        assert_eq!(
            ScrollExtremePlan::new(&pane(false, false, false), false),
            ScrollExtremePlan::AlreadyLive
        );
    }

    #[test]
    fn classic_wheel_reports_keep_single_byte_coordinates() {
        let wide = PaneScrollState {
            width: 400,
            height: 300,
            ..pane(false, true, false)
        };
        assert_eq!(wheel_report(&wide, false), "\x1b[Ma\x7f\x7f");
        assert_eq!(wheel_report(&pane(false, true, false), true), "\x1b[M`\\4");
    }

    #[test]
    fn pane_scroll_state_parses_the_display_format() {
        assert_eq!(
            PaneScrollState::parse("0 1 1 120 40\n"),
            Some(pane(false, true, true))
        );
        assert_eq!(PaneScrollState::parse("0 1 1 120"), None);
        assert_eq!(PaneScrollState::parse("0 1 1 wide 40"), None);
    }

    #[test]
    fn repeatable_navigation_commands_prefer_the_warm_client_snapshot() {
        for (command, subcommand) in [
            ("tab", "next"),
            ("tab", "previous"),
            ("tab", "move_next"),
            ("tab", "move_previous"),
            ("pane", "next"),
            ("pane", "previous"),
        ] {
            assert!(
                source_command_prefers_warm_client(command, subcommand),
                "{command} {subcommand}"
            );
        }
        for (command, subcommand) in [
            ("tab", "select"),
            ("tab", "new"),
            ("tab", "close"),
            ("pane", "close"),
            ("tmux", "session"),
        ] {
            assert!(
                !source_command_prefers_warm_client(command, subcommand),
                "{command} {subcommand}"
            );
        }
    }

    #[test]
    fn destructive_kills_run_without_a_tmux_prompt() {
        // Flash asks through `confirm` on the manifest's `commands[]` entry;
        // a tmux `confirm-before` would ask again on a prompt NORMAL mode
        // swallows.
        assert_eq!(kill_window_args("@17"), ["kill-window", "-t", "@17"]);
        assert_eq!(kill_window_args("work"), ["kill-window", "-t", "work"]);
        assert_eq!(kill_pane_args("%3"), ["kill-pane", "-t", "%3"]);
    }

    #[test]
    fn tab_move_pins_the_source_session_instead_of_a_marked_pane() {
        for (direction, target) in [("next", "work:+1"), ("previous", "work:-1")] {
            assert_eq!(
                tab_move_args("work", direction),
                ["swap-window", "-d", "-s", "work:", "-t", target]
            );
        }
    }

    /// A switched window replies with the route its row carries, so the
    /// host's stop and the row published after the settle are one.
    #[test]
    fn a_switched_window_reports_the_route_its_row_carries() {
        assert_eq!(
            window_route("local", "scratch", "@2").as_deref(),
            Some("tmux://window/local%7Cscratch:%402")
        );
        assert_eq!(
            window_route("local", "scratch", "@2"),
            Some(tmux_navigation_url(
                "window",
                &routed_tmux_target("local", "scratch:@2")
            ))
        );
        assert_eq!(window_route("local", "scratch", "2"), None);
        assert_eq!(window_route("local", "scratch", ""), None);
    }
}
