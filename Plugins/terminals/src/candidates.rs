//! The tmux window finder: candidate rows built from the local and remote
//! window inventories, their routing payloads and navigation URLs.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use flash_plugin::{Candidate, Context};
use serde::{Deserialize, Serialize};

use crate::Tmux;
use crate::clients::{
    ClientSnapshot, TMUX_FIELD_SEP, TmuxClient, local_client_format, parse_tmux_client_for_backend,
    split_tmux_fields,
};
use crate::inventory::{TmuxAggregate, is_absent_tmux_server, run_tmux_inventory_default};
use crate::invocation::CliResult;
use crate::processes::{find_top_level_ancestor, parent_pid_map};
use crate::remote::{RemoteTmuxConfig, run_remote_tmux};
use crate::sockets::TmuxSocketRegistry;
use crate::status_segments::{TmuxStatusSegments, status_segments};
use crate::terminal_windows::discover_local_client_windows;

pub(crate) const SOURCE_WINDOWS: &str = "tmux.windows";
const NAV_SCHEME: &str = "tmux";

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct LocalTmuxConfig {
    label: String,
    pub(crate) terminal_window_title: String,
}

fn local_hostname() -> String {
    nix::unistd::gethostname()
        .ok()
        .and_then(|name| name.into_string().ok())
        .unwrap_or_default()
        .split('.')
        .next()
        .filter(|value| !value.is_empty())
        .unwrap_or("local")
        .to_string()
}

pub(crate) fn local_tmux_config() -> LocalTmuxConfig {
    LocalTmuxConfig {
        label: local_hostname(),
        terminal_window_title: String::new(),
    }
}

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
pub(crate) struct TmuxPayload {
    pub(crate) backend_id: String,
    pub(crate) tmux_target: String,
    #[serde(default)]
    pub(crate) tmux_client_tty: String,
    #[serde(default)]
    pub(crate) client_pid: Option<i64>,
    #[serde(default)]
    pub(crate) terminal_pid: Option<i64>,
    #[serde(default)]
    pub(crate) terminal_window_handle: Option<u64>,
    pub(crate) terminal_window_title: String,
    #[serde(default)]
    pub(crate) remote: bool,
}

pub(crate) fn routed_client_from_payload(payload: &TmuxPayload) -> Option<TmuxClient> {
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
        backend_id: payload.backend_id.clone(),
        remote: payload.remote,
        ..TmuxClient::default()
    })
}

pub(crate) fn cached_terminal_pid(plugin: &Tmux, payload: &TmuxPayload) -> Option<i64> {
    payload.terminal_pid.or_else(|| {
        let client_pid = payload.client_pid?;
        let snapshot = plugin.client_snapshot().lock().ok()?;
        find_top_level_ancestor(client_pid, &snapshot.parent_map)
    })
}

pub(crate) fn cached_payload_for_route(
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

pub(crate) fn routed_tmux_target(backend_id: &str, target: &str) -> String {
    format!("{backend_id}|{target}")
}

pub(crate) fn split_routed_tmux_target(target: &str) -> Option<(&str, &str)> {
    let (backend_id, tmux_target) = target.split_once('|')?;
    if backend_id.is_empty() || tmux_target.is_empty() {
        return None;
    }
    Some((backend_id, tmux_target))
}

pub(crate) fn tmux_navigation_url(kind: &str, target: &str) -> String {
    format!("{NAV_SCHEME}://{kind}/{}", percent_encode(target))
}

pub(crate) fn parse_tmux_navigation_url(raw: &str) -> Option<(String, String)> {
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
        let parts = split_tmux_fields(line, 8);
        if parts.len() != 8 || !parts[7].starts_with('@') {
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

        let display_target = format!("{session}:{index}");
        let target = format!("{session}:{}", parts[7].trim());
        let window_name = if name.is_empty() {
            display_target.clone()
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
            secondary_parts.push(display_target.as_str());
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
pub(crate) struct CandidateBuild {
    pub(crate) candidates: Vec<Candidate>,
    pub(crate) client_snapshot: ClientSnapshot,
    pub(crate) client_count: usize,
    pub(crate) raw_line_count: usize,
    pub(crate) status: TmuxStatusSegments,
}

pub(crate) const CANDIDATE_CLIENT_RECORD: &str = "client";
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

pub(crate) fn same_client_processes(previous: &[TmuxClient], current: &[TmuxClient]) -> bool {
    let mut previous_pids: Vec<i64> = previous.iter().map(|client| client.client_pid).collect();
    let mut current_pids: Vec<i64> = current.iter().map(|client| client.client_pid).collect();
    previous_pids.sort_unstable();
    current_pids.sort_unstable();
    previous_pids == current_pids
}

pub(crate) async fn build_candidates(
    tmux_path: Option<&str>,
    ctx: &Context,
    previous_client_snapshot: &ClientSnapshot,
    local_config: &LocalTmuxConfig,
    socket_registry: &TmuxSocketRegistry,
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
        "{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}{}",
        local_client_format()
    );
    // `pane_index` (the window's active pane, per tmux
    // list-windows semantics) feeds the `#{flash.plugin.terminals.pane}` status
    // segment; candidates themselves ignore it.
    let window_format = format!(
        "{CANDIDATE_WINDOW_RECORD}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{window_index}}{TMUX_FIELD_SEP}#{{window_name}}{TMUX_FIELD_SEP}#{{pane_current_command}}{TMUX_FIELD_SEP}#{{pane_current_path}}{TMUX_FIELD_SEP}#{{window_active}}{TMUX_FIELD_SEP}#{{pane_index}}{TMUX_FIELD_SEP}#{{window_id}}"
    );
    // A single tmux process per socket emits both inventories: running the
    // two commands separately doubled process creation and socket discovery.
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
        socket_registry,
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
        Arc::new(parent_pid_map())
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

pub(crate) struct RemoteCandidateBuild {
    pub(crate) candidates: Vec<Candidate>,
    pub(crate) client_count: usize,
    pub(crate) raw_line_count: usize,
}

pub(crate) async fn build_remote_candidates(
    config: &RemoteTmuxConfig,
    terminal_pid: Option<i64>,
) -> Result<RemoteCandidateBuild, CliResult> {
    let client_format = format!(
        "{CANDIDATE_CLIENT_RECORD}{TMUX_FIELD_SEP}#{{client_tty}}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{client_pid}}{TMUX_FIELD_SEP}#{{client_activity}}"
    );
    let window_format = format!(
        "{CANDIDATE_WINDOW_RECORD}{TMUX_FIELD_SEP}#{{session_name}}{TMUX_FIELD_SEP}#{{window_index}}{TMUX_FIELD_SEP}#{{window_name}}{TMUX_FIELD_SEP}#{{pane_current_command}}{TMUX_FIELD_SEP}#{{pane_current_path}}{TMUX_FIELD_SEP}#{{window_active}}{TMUX_FIELD_SEP}#{{pane_index}}{TMUX_FIELD_SEP}#{{window_id}}"
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

#[cfg(test)]
mod tests {
    use super::*;

    use crate::inventory::merge_socket_outputs;
    use crate::test_support::client;

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
    fn window_location_keeps_its_identity_when_reordered() {
        let clients = [client("/dev/ttys000", "work", 1443, 30)];
        let before = "work\t1\teditor\tnvim\t/work\t1\t0\t@17";
        let after = "work\t3\teditor\tnvim\t/work\t1\t0\t@17";
        let rows: Vec<_> = [before, after]
            .iter()
            .map(|raw| {
                build_candidates_from_window_list(
                    raw,
                    &clients,
                    &HashMap::new(),
                    &HashMap::new(),
                    &HashMap::new(),
                    "",
                    &local_backend(),
                )
                .remove(0)
            })
            .collect();
        use flash_plugin::candidate_metadata as meta;
        assert_eq!(
            rows[0].meta(meta::NAVIGATION_URL),
            rows[1].meta(meta::NAVIGATION_URL)
        );
        assert_eq!(
            rows[0].payload_as::<TmuxPayload>().unwrap().tmux_target,
            "work:@17"
        );
        assert_eq!(
            rows[1].payload_as::<TmuxPayload>().unwrap().tmux_target,
            "work:@17"
        );
        assert!(rows[0].meta(meta::SUBTITLE).unwrap().starts_with("work:1"));
        assert!(rows[1].meta(meta::SUBTITLE).unwrap().starts_with("work:3"));
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
            ..TmuxClient::default()
        }];
        let raw = "scratch\t1\tcode\tzsh\t/home/ab/workspace\t1\t0\t@11";
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
            Some("tmux://window/local%7Cscratch:%4011")
        );
        assert_eq!(
            remote[0].meta(meta::NAVIGATION_URL),
            Some("tmux://window/remote:moria%7Cscratch:%4011")
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
    fn candidate_payload_uses_the_window_discovered_for_its_tmux_client() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let candidates = build_candidates_from_window_list(
            "scratch\t1\tcode\tzsh\t/Users/ab/work\t1\t0\t@11",
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
        let raw = "beside\t1\tbeside-agentic\tclaude\t/Users/ab/workspace/beside\t1\t0\t@11\n\
scratch\t2\tflash\tzsh\t/Users/ab/workspace/aymericbeaumet/flash\t1\t0\t@12\n";

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
            Some("tmux://window/local%7Cscratch:%4012")
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
        let socket_a_out = "work\t1\teditor\tnvim\t/Users/ab/work\t1\t0\t@11";
        let socket_b_out = "play\t1\tshell\tzsh\t/Users/ab/play\t1\t0\t@12";

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
        assert!(sessions.contains(&"tmux://window/local%7Cwork:%4011"));
        assert!(sessions.contains(&"tmux://window/local%7Cplay:%4012"));
        // The `play` session lives on the second socket — it would
        // have been entirely missing before the fix.
        let play = candidates
            .iter()
            .find(|c| c.meta(meta::NAVIGATION_URL) == Some("tmux://window/local%7Cplay:%4012"))
            .expect("play session candidate present");
        assert_eq!(play.pid_value(), Some(1444));
    }
}
