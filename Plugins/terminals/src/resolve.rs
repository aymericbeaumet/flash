//! Candidate resolution: switching a tmux client to the picked window and
//! raising the terminal that hosts it.

use std::collections::BTreeMap;
use std::time::Instant;

use flash_plugin::{Candidate, Context, PerformResponse};

use crate::Tmux;
use crate::candidates::{
    TmuxPayload, cached_terminal_pid, routed_client_from_payload, routed_tmux_target,
    tmux_navigation_url,
};
use crate::clients::{TmuxClient, list_clients, remote_client_for_target, run_tmux_for_client};
use crate::processes::{find_top_level_ancestor, parent_pid_map};
use crate::sockets::TmuxSocketRegistry;
use crate::terminal_windows::raise_terminal_window;

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
pub(crate) async fn select_client_for_target(
    tmux_path: Option<&str>,
    target: &str,
    socket_registry: &TmuxSocketRegistry,
) -> Option<TmuxClient> {
    let mut clients = list_clients(tmux_path, socket_registry).await;
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

pub(crate) async fn switch_routed_target(plugin: &Tmux, client: &TmuxClient, target: &str) -> bool {
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
    // A disappeared/replaced client can leave a stale tty in the local or
    // five-second remote snapshot. Retry without `-c` only in that
    // uncommon case; a healthy jump is always exactly one tmux invocation.
    !client.tty.is_empty()
        && run_tmux_for_client(plugin, client, &["switch-client", "-t", target])
            .await
            .is_some()
}

pub(crate) async fn resolve(plugin: &Tmux, ctx: &Context, row: &Candidate) -> PerformResponse {
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
            select_client_for_target(
                plugin.resolved_tmux_path().await,
                target,
                plugin.tmux_socket_registry(),
            )
            .await
        };
        if let Some(client) = route_client.as_ref() {
            switched = switch_routed_target(plugin, client, target).await;
            if terminal_pid.is_none() && !client.remote {
                let parent_map = parent_pid_map();
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
            let parent_map = parent_pid_map();
            terminal_pid = find_top_level_ancestor(client.client_pid, &parent_map);
        }
    }
    if !focus_started && let Some(pid) = terminal_pid {
        let _ = raise_terminal_window(
            ctx,
            pid,
            payload.terminal_window_handle,
            &payload.terminal_window_title,
        )
        .await;
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
