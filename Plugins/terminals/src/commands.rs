//! The plugin's own `:tmux session` / `:tmux window` commands and navigation
//! restore.

use std::collections::BTreeMap;
use std::time::Instant;

use flash_plugin::{CommandRequest, Context, NavigateRequest, PerformResponse};

use crate::Tmux;
use crate::candidates::{
    cached_payload_for_route, cached_terminal_pid, parse_tmux_navigation_url,
    routed_client_from_payload, routed_tmux_target, split_routed_tmux_target, tmux_navigation_url,
};
use crate::clients::{list_clients, remote_client_for_target};
use crate::invocation::run_tmux_default;
use crate::processes::{find_top_level_ancestor, parent_pid_map};
use crate::resolve::{select_client_for_target, switch_routed_target};
use crate::terminal_windows::raise_terminal_window;

/// `perform {kind: "command"}` for `:tmux session <name>` and `:tmux window
/// <session:index>`. Both switch the user's active tmux client to the
/// requested target and return the terminal pid hosting it so Flash can
/// raise that window. The target is the one positional word each command's
/// manifest entry declares, so a mapping like
/// `["flash", "tmux", "window", "main:1"]`
/// jumps straight to `main:1`.
pub(crate) async fn invoke_command(
    plugin: &Tmux,
    ctx: &Context,
    cmd: &CommandRequest,
) -> PerformResponse {
    let tmux_path = plugin.resolved_tmux_path().await;
    match cmd.subcommand.as_str() {
        "session" | "window" => {}
        other => {
            return PerformResponse::fail(format!("unknown subcommand: {other}"));
        }
    }

    let target = cmd.positional().map(str::trim).filter(|s| !s.is_empty());
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
    let chosen = select_client_for_target(tmux_path, target, plugin.tmux_socket_registry()).await;
    let tty = chosen.as_ref().map(|c| c.tty.clone()).unwrap_or_default();

    let mut args: Vec<&str> = vec!["switch-client"];
    if !tty.is_empty() {
        args.push("-c");
        args.push(&tty);
    }
    args.push("-t");
    args.push(target);
    let switched = run_tmux_default(tmux_path, &args, plugin.tmux_socket_registry())
        .await
        .is_some()
        || run_tmux_default(
            tmux_path,
            &["switch-client", "-t", target],
            plugin.tmux_socket_registry(),
        )
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
            let pmap = parent_pid_map();
            find_top_level_ancestor(c.client_pid, &pmap)
        }
        None => {
            let clients = list_clients(tmux_path, plugin.tmux_socket_registry()).await;
            let fallback = clients
                .iter()
                .find(|c| c.session == session)
                .or_else(|| clients.first());
            match fallback {
                Some(c) => {
                    let pmap = parent_pid_map();
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

pub(crate) async fn restore_navigation(
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
            select_client_for_target(
                plugin.resolved_tmux_path().await,
                tmux_target,
                plugin.tmux_socket_registry(),
            )
            .await
        };
        if let Some(client) = route_client.as_ref() {
            switched = switch_routed_target(plugin, client, tmux_target).await;
        }
    }
    if !switched {
        ctx.log("warn", "[tmux] navigation restore failed");
        return PerformResponse::fail("navigation restore failed");
    }

    if terminal_pid.is_none()
        && let Some(client) = route_client.as_ref().filter(|client| !client.remote)
    {
        let pmap = parent_pid_map();
        terminal_pid = find_top_level_ancestor(client.client_pid, &pmap);
    }
    if !focus_started && let Some(pid) = terminal_pid {
        let _ =
            raise_terminal_window(ctx, pid, terminal_window_handle, &terminal_window_title).await;
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
