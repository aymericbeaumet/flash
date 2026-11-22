//! Enumeration commands aggregated across every local tmux server.

use std::collections::{BTreeSet, HashMap};
use std::os::unix::fs::MetadataExt;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::candidates::CANDIDATE_CLIENT_RECORD;
use crate::clients::{TMUX_FIELD_SEP, parse_tmux_client};
use crate::control_mode;
use crate::invocation::{CliResult, run_local, run_on_observer, tmux_argv, tmux_socket_argv};
use crate::sockets::{
    SocketIdentity, SocketProbeOutcome, TmuxSocketRegistry, socket_probe_outcome,
};

/// Run an enumeration command (`list-windows -a`, `list-clients`, …) against
/// the default socket *and* every other tmux socket discovered in the current
/// user's `/private/tmp/tmux-<uid>` and `/tmp/tmux-<uid>` directories, then
/// return the union of stdout lines.
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
pub(crate) enum TmuxAggregate {
    Output(String),
    Absent,
    TransientFailure,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TmuxInventoryScope {
    AnyServer,
    AttachedServers,
}

/// The sockets an attached observer serves, by identity: discovery names a
/// socket by any of its paths (`/tmp` or `/private/tmp`), tmux by one.
async fn observed_socket_identities(
    observers: &control_mode::ControlObservers,
) -> HashMap<SocketIdentity, String> {
    let mut identities = HashMap::new();
    for socket in observers.attached_sockets() {
        if let Ok(metadata) = tokio::fs::metadata(&socket).await {
            identities.insert(
                SocketIdentity {
                    device: metadata.dev(),
                    inode: metadata.ino(),
                },
                socket,
            );
        }
    }
    identities
}

async fn run_tmux_aggregate_inventory(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
    socket_registry: &TmuxSocketRegistry,
) -> TmuxAggregate {
    let Some(path) = tmux_path.map(str::to_string) else {
        return TmuxAggregate::Absent;
    };
    let args_owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();

    let socket_plan = socket_registry.inventory_plan(&path).await;
    let mut handles: Vec<(Option<SocketIdentity>, tokio::task::JoinHandle<CliResult>)> =
        Vec::with_capacity(socket_plan.targets.len() + 1);
    // A server with an attached observer answers through it; the others
    // need a spawned client.
    let observed = observed_socket_identities(&socket_registry.observers).await;

    // Default-socket invocation. Without `-S`, tmux resolves to whichever
    // socket the user's $TMUX_TMPDIR / process environment points at. The
    // registry excludes that socket's inode from the explicit targets, while
    // this invocation also covers non-standard roots that discovery cannot see.
    {
        let path = path.clone();
        let args_owned = args_owned.clone();
        let observers = Arc::clone(&socket_registry.observers);
        let observed = socket_plan
            .default_identity
            .and_then(|identity| observed.get(&identity).cloned());
        handles.push((
            None,
            tokio::spawn(async move {
                let args_ref: Vec<&str> = args_owned.iter().map(String::as_str).collect();
                if let Some(socket) = observed
                    && let Some(result) =
                        run_on_observer(&observers, &socket, &args_ref, timeout).await
                {
                    return result;
                }
                run_local(&tmux_argv(&path, &args_ref), timeout).await
            }),
        ));
    }

    for socket in socket_plan.targets {
        let path = path.clone();
        let args_owned = args_owned.clone();
        let identity = socket.identity;
        let observers = Arc::clone(&socket_registry.observers);
        let observed = observed.get(&identity).cloned();
        handles.push((
            Some(identity),
            tokio::spawn(async move {
                let args_ref: Vec<&str> = args_owned.iter().map(String::as_str).collect();
                if let Some(observed) = observed
                    && let Some(result) =
                        run_on_observer(&observers, &observed, &args_ref, timeout).await
                {
                    return result;
                }
                run_local(&tmux_socket_argv(&path, &socket.path, &args_ref), timeout).await
            }),
        ));
    }

    let mut results = Vec::with_capacity(handles.len());
    let mut join_failed = false;
    for (identity, handle) in handles {
        let (outcome, result) = match handle.await {
            Ok(result) => (socket_probe_outcome(&result), Some(result)),
            Err(_) => {
                join_failed = true;
                (SocketProbeOutcome::Transient, None)
            }
        };
        match identity {
            Some(identity) => {
                socket_registry
                    .record(identity, outcome, Instant::now())
                    .await
            }
            None => {
                socket_registry
                    .record_default(outcome, Instant::now())
                    .await
            }
        }
        results.extend(result);
    }
    let scope = if args.contains(&"list-windows") {
        TmuxInventoryScope::AttachedServers
    } else {
        TmuxInventoryScope::AnyServer
    };
    if scope == TmuxInventoryScope::AttachedServers {
        let detached = results
            .iter()
            .any(|result| result.ok && !candidate_inventory_has_attached_client(&result.stdout));
        socket_registry
            .set_detached_server(detached || join_failed || socket_plan.deferred)
            .await;
    }
    classify_tmux_aggregate(
        &results,
        join_failed || socket_plan.deferred,
        socket_plan.inventory_incomplete,
        scope,
    )
}

fn classify_tmux_aggregate(
    results: &[CliResult],
    join_failed: bool,
    inventory_incomplete: bool,
    scope: TmuxInventoryScope,
) -> TmuxAggregate {
    if inventory_incomplete {
        return TmuxAggregate::TransientFailure;
    }
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

/// Whether a server's inventory lists a user client. Flash's control-mode
/// observers are attached too, but show no one anything.
pub(crate) fn candidate_inventory_has_attached_client(output: &str) -> bool {
    let prefix = format!("{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}");
    output.lines().any(|line| {
        line.strip_prefix(&prefix)
            .and_then(parse_tmux_client)
            .is_some()
    })
}

fn is_transient_tmux_failure(result: &CliResult) -> bool {
    !result.ok && !is_absent_tmux_server(result)
}

pub(crate) fn is_absent_tmux_server(result: &CliResult) -> bool {
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
pub(crate) fn merge_socket_outputs<'a, I>(outputs: I) -> String
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

pub(crate) async fn run_tmux_inventory_default(
    tmux_path: Option<&str>,
    args: &[&str],
    socket_registry: &TmuxSocketRegistry,
) -> TmuxAggregate {
    run_tmux_aggregate_inventory(tmux_path, args, Duration::from_secs(2), socket_registry).await
}

#[cfg(test)]
mod tests {
    use super::*;

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
            classify_tmux_aggregate(&[absent], false, false, TmuxInventoryScope::AnyServer),
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
            classify_tmux_aggregate(&[timeout], false, false, TmuxInventoryScope::AnyServer),
            TmuxAggregate::TransientFailure
        );
    }

    #[test]
    fn aggregate_inventory_preserves_last_good_while_socket_discovery_is_incomplete() {
        let successful = CliResult {
            ok: true,
            stdout: "work\t1\teditor".to_string(),
            status: 0,
            ..CliResult::default()
        };
        assert_eq!(
            classify_tmux_aggregate(&[successful], false, true, TmuxInventoryScope::AnyServer),
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
            classify_tmux_aggregate(
                &[successful, absent],
                false,
                false,
                TmuxInventoryScope::AnyServer,
            ),
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
            classify_tmux_aggregate(&[exited], false, false, TmuxInventoryScope::AnyServer),
            TmuxAggregate::Absent
        );
    }
}
