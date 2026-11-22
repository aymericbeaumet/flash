//! tmux clients: the `list-clients` inventory, the warm client snapshot, the
//! client hosted by the focused terminal and commands run on its behalf.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::time::Duration;

use flash_plugin::Context;

use crate::candidates::same_client_processes;
use crate::inventory::{TmuxAggregate, run_tmux_inventory_default};
use crate::invocation::{run_on_observer, run_tmux_capture, run_tmux_default, tmux_failure_detail};
use crate::processes::{client_hosted_by_from_map, is_ancestor, parent_pid_map};
use crate::remote::{RemoteTmuxConfig, remote_host_name, run_remote_tmux, run_remote_tmux_default};
use crate::sockets::TmuxSocketRegistry;
use crate::terminal_windows::{
    focused_terminal_window_title, focused_window_from_nodes, terminal_window_nodes,
};
use crate::{Tmux, control_mode};

pub(crate) const TMUX_FIELD_SEP: &str = "|||";

pub(crate) fn split_tmux_fields(line: &str, max_fields: usize) -> Vec<&str> {
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

#[derive(Clone, Debug, Default)]
pub(crate) struct TmuxClient {
    pub(crate) tty: String,
    pub(crate) session: String,
    pub(crate) client_pid: i64,
    pub(crate) activity: i64,
    pub(crate) backend_id: String,
    pub(crate) remote: bool,
    /// `$N`; local clients only.
    pub(crate) session_id: String,
    /// The server's socket; local clients only.
    pub(crate) socket_path: String,
}

#[derive(Clone, Default)]
pub(crate) struct ClientSnapshot {
    pub(crate) clients: Vec<TmuxClient>,
    pub(crate) parent_map: Arc<HashMap<i64, i64>>,
    pub(crate) window_title_by_client_pid: Arc<HashMap<i64, String>>,
    pub(crate) window_handle_by_client_pid: Arc<HashMap<i64, u64>>,
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

/// `list-clients` fields for local servers. `client_flags` tells Flash's
/// `no-output` control-mode observers apart from user clients; `session_id`
/// and `socket_path` tell the observers which server and session to follow.
pub(crate) fn local_client_format() -> String {
    [
        "#{client_tty}",
        "#{session_name}",
        "#{client_pid}",
        "#{client_activity}",
        "#{client_flags}",
        "#{session_id}",
        "#{socket_path}",
    ]
    .join(TMUX_FIELD_SEP)
}

async fn list_clients_inventory(
    tmux_path: Option<&str>,
    socket_registry: &TmuxSocketRegistry,
) -> Result<Vec<TmuxClient>, ()> {
    let format = local_client_format();
    // Aggregated across every discovered tmux socket — `list-clients`
    // only reports clients attached to the socket it was called on, so
    // a single-socket invocation silently drops every client (and
    // therefore every window-resolution route) attached to other tmux
    // servers running on the host.
    let raw = match run_tmux_inventory_default(
        tmux_path,
        &["list-clients", "-F", &format],
        socket_registry,
    )
    .await
    {
        TmuxAggregate::Output(raw) => raw,
        TmuxAggregate::Absent => return Ok(Vec::new()),
        TmuxAggregate::TransientFailure => return Err(()),
    };
    Ok(raw.lines().filter_map(parse_tmux_client).collect())
}

pub(crate) fn parse_tmux_client(line: &str) -> Option<TmuxClient> {
    parse_tmux_client_for_backend(line, "local")
}

/// A user client, or `None` for a malformed record or a `no-output` control
/// client — Flash's own observers, which render no pane.
pub(crate) fn parse_tmux_client_for_backend(line: &str, backend_id: &str) -> Option<TmuxClient> {
    let parts = split_tmux_fields(line, 7);
    if parts.len() < 3 {
        return None;
    }
    let client_pid = parts[2].parse::<i64>().ok()?;
    let activity = parts
        .get(3)
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(0);
    let field = |index: usize| parts.get(index).map(|value| value.trim()).unwrap_or("");
    if field(4).split(',').any(|flag| flag == "no-output") {
        return None;
    }
    Some(TmuxClient {
        tty: parts[0].to_string(),
        session: parts[1].to_string(),
        client_pid,
        activity,
        backend_id: backend_id.to_string(),
        remote: backend_id != "local",
        session_id: field(5).to_string(),
        socket_path: field(6).to_string(),
    })
}

/// Each local server a user client is attached to, with the session its
/// most recently active client shows: what the control-mode observers
/// follow.
pub(crate) fn observed_servers(clients: &[TmuxClient]) -> BTreeMap<String, String> {
    let mut latest: BTreeMap<&str, &TmuxClient> = BTreeMap::new();
    for client in clients.iter().filter(|client| {
        !client.remote
            && !client.socket_path.is_empty()
            && control_mode::is_session_id(&client.session_id)
    }) {
        latest
            .entry(client.socket_path.as_str())
            .and_modify(|best| {
                if client.activity > best.activity {
                    *best = client;
                }
            })
            .or_insert(client);
    }
    latest
        .into_iter()
        .map(|(socket, client)| (socket.to_string(), client.session_id.clone()))
        .collect()
}

pub(crate) async fn list_clients(
    tmux_path: Option<&str>,
    socket_registry: &TmuxSocketRegistry,
) -> Vec<TmuxClient> {
    list_clients_inventory(tmux_path, socket_registry)
        .await
        .unwrap_or_default()
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

/// Owned inputs of one `capture-pane`, so pane captures can run as spawned
/// tasks without borrowing the plugin.
#[derive(Clone)]
pub(crate) enum PaneCaptureRunner {
    Local {
        tmux_path: Option<String>,
        socket_registry: std::sync::Arc<TmuxSocketRegistry>,
        /// The client's server, whose observer captures without a spawn.
        socket_path: String,
    },
    Remote(Option<RemoteTmuxConfig>),
}

impl PaneCaptureRunner {
    pub(crate) async fn capture(&self, pane_id: &str) -> Option<String> {
        let args = ["capture-pane", "-t", pane_id, "-p", "-e"];
        match self {
            Self::Local {
                tmux_path,
                socket_registry,
                socket_path,
            } => {
                if let Some(result) = run_on_observer(
                    &socket_registry.observers,
                    socket_path,
                    &args,
                    Duration::from_secs(2),
                )
                .await
                {
                    return result.ok.then_some(result.stdout);
                }
                run_tmux_default(tmux_path.as_deref(), &args, socket_registry).await
            }
            Self::Remote(config) => run_remote_tmux_default(config.as_ref()?, &args).await,
        }
    }
}

/// Run `args` for `client`: over SSH for a remote one, else through its
/// server's observer, else a spawned client.
pub(crate) async fn run_tmux_for_client(
    plugin: &Tmux,
    client: &TmuxClient,
    args: &[&str],
) -> Option<String> {
    if client.remote {
        let config = plugin.remote_config(&client.backend_id)?;
        return run_remote_tmux_default(&config, args).await;
    }
    if let Some(result) = run_on_observer(
        plugin.observers(),
        &client.socket_path,
        args,
        Duration::from_secs(2),
    )
    .await
    {
        return result.ok.then_some(result.stdout);
    }
    run_tmux_default(
        plugin.resolved_tmux_path().await,
        args,
        plugin.tmux_socket_registry(),
    )
    .await
}

pub(crate) async fn run_tmux_for_client_capture(
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
    } else if let Some(result) =
        run_on_observer(plugin.observers(), &client.socket_path, args, timeout).await
    {
        if result.ok {
            Ok(result.stdout)
        } else {
            Err(tmux_failure_detail(&result))
        }
    } else {
        run_tmux_capture(
            plugin.resolved_tmux_path().await,
            args,
            timeout,
            plugin.tmux_socket_registry(),
        )
        .await
    }
}

async fn load_client_snapshot(
    tmux_path: Option<&str>,
    socket_registry: &TmuxSocketRegistry,
) -> Option<ClientSnapshot> {
    let clients = list_clients_inventory(tmux_path, socket_registry)
        .await
        .ok()?;
    if clients.is_empty() {
        return None;
    }
    let parent_map = parent_pid_map();
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
    let mut snapshot = load_client_snapshot(
        plugin.resolved_tmux_path().await,
        plugin.tmux_socket_registry(),
    )
    .await?;
    if let Ok(mut guard) = plugin.client_snapshot().lock() {
        if same_client_processes(&guard.clients, &snapshot.clients) {
            snapshot.window_title_by_client_pid = Arc::clone(&guard.window_title_by_client_pid);
            snapshot.window_handle_by_client_pid = Arc::clone(&guard.window_handle_by_client_pid);
        }
        *guard = snapshot.clone();
    }
    Some(snapshot)
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

pub(crate) async fn remote_client_for_target(
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

pub(crate) async fn focused_tmux_client(
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

#[cfg(test)]
mod tests {
    use super::*;

    use crate::candidates::CANDIDATE_CLIENT_RECORD;
    use crate::inventory::candidate_inventory_has_attached_client;
    use crate::test_support::client;

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
    fn tmux_field_splitter_accepts_configured_separator_tabs_and_whitespace() {
        assert_eq!(split_tmux_fields("a|||b|||c", 3), vec!["a", "b", "c"]);
        assert_eq!(split_tmux_fields("a\tb\tc", 3), vec!["a", "b", "c"]);
        assert_eq!(split_tmux_fields("a b c", 3), vec!["a", "b", "c"]);
    }

    #[test]
    fn observers_are_not_user_clients() {
        let sep = TMUX_FIELD_SEP;
        let user = format!(
            "/dev/ttys001{sep}work{sep}42{sep}100{sep}attached,focused,UTF-8{sep}$3{sep}/private/tmp/tmux-501/default"
        );
        let client = parse_tmux_client(&user).expect("a user client");
        assert_eq!(client.session, "work");
        assert_eq!(client.activity, 100);
        assert_eq!(client.session_id, "$3");
        assert_eq!(client.socket_path, "/private/tmp/tmux-501/default");

        let observer = format!(
            "{sep}work{sep}43{sep}200{sep}attached,focused,control-mode,ignore-size,no-detach-on-destroy,no-output,UTF-8{sep}$3{sep}/private/tmp/tmux-501/default"
        );
        assert!(parse_tmux_client(&observer).is_none());
        let iterm = format!(
            "/dev/ttys002{sep}work{sep}44{sep}300{sep}attached,control-mode,UTF-8{sep}$3{sep}/private/tmp/tmux-501/default"
        );
        assert!(
            parse_tmux_client(&iterm).is_some(),
            "a control client that shows panes (iTerm2) is a user client"
        );
        let legacy = format!("/dev/ttys003{sep}work{sep}45{sep}400");
        assert_eq!(parse_tmux_client(&legacy).unwrap().activity, 400);

        let only_observer = format!("{CANDIDATE_CLIENT_RECORD}{sep}{observer}\nwindow{sep}work");
        assert!(!candidate_inventory_has_attached_client(&only_observer));
        let with_user = format!("{only_observer}\n{CANDIDATE_CLIENT_RECORD}{sep}{user}");
        assert!(candidate_inventory_has_attached_client(&with_user));
    }

    #[test]
    fn observers_follow_the_most_active_client_of_each_local_server() {
        let local = |socket: &str, session_id: &str, activity: i64| TmuxClient {
            activity,
            backend_id: "local".to_string(),
            session_id: session_id.to_string(),
            socket_path: socket.to_string(),
            ..TmuxClient::default()
        };
        let clients = [
            local("/tmp/tmux-501/default", "$1", 10),
            local("/tmp/tmux-501/default", "$2", 30),
            local("/tmp/tmux-501/default", "$3", 20),
            local("/tmp/tmux-501/work", "$0", 5),
            local("", "$4", 50),
            local("/tmp/tmux-501/odd", "main", 50),
            TmuxClient {
                remote: true,
                backend_id: "remote:moria".to_string(),
                ..local("/tmp/tmux-1000/default", "$9", 99)
            },
        ];
        assert_eq!(
            observed_servers(&clients),
            BTreeMap::from([
                ("/tmp/tmux-501/default".to_string(), "$2".to_string()),
                ("/tmp/tmux-501/work".to_string(), "$0".to_string()),
            ])
        );
        assert!(observed_servers(&[]).is_empty());
    }
}
