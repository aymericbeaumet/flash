//! The local tmux socket registry: discovery, probe outcomes and retry
//! backoff.

use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::control_mode;
use crate::inventory::is_absent_tmux_server;
use crate::invocation::{CliResult, run_local, tmux_argv};

/// Socket-directory rescan age, checked by refreshes only while the kqueue
/// watch is unavailable or the last scan was incomplete.
const SOCKET_DISCOVERY_INTERVAL_SECS: u64 = 30;
const SOCKET_DISCOVERY_FANOUT_LIMIT: usize = 16;
const SOCKET_RETRY_DELAYS_SECS: [u64; 3] = [5, 15, 60];

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(crate) struct SocketIdentity {
    pub(crate) device: u64,
    pub(crate) inode: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DiscoveredSocket {
    pub(crate) identity: SocketIdentity,
    pub(crate) path: String,
}

struct SocketDiscovery {
    sockets: Vec<DiscoveredSocket>,
    complete: bool,
}

pub(crate) struct SocketInventoryPlan {
    pub(crate) targets: Vec<DiscoveredSocket>,
    /// The server a client without `-S` reaches, when known.
    pub(crate) default_identity: Option<SocketIdentity>,
    pub(crate) deferred: bool,
    pub(crate) inventory_incomplete: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TrackedSocketState {
    Unseen,
    Active,
    Absent,
    Transient { failures: usize, retry_at: Instant },
}

#[derive(Clone, Debug)]
struct TrackedSocket {
    socket: DiscoveredSocket,
    state: TrackedSocketState,
}

#[derive(Default)]
struct TmuxSocketRegistryState {
    sockets: BTreeMap<SocketIdentity, TrackedSocket>,
    default_identity: Option<SocketIdentity>,
    discovered_at: Option<Instant>,
    discovery_complete: bool,
    /// The socket directory is watched ([`crate::socket_watch`]): a change
    /// invalidates the discovery, so a complete one never goes stale.
    watched: bool,
    /// The last candidate inventory reached a server no user client is
    /// attached to, or could not tell: a client attaching there reaches no
    /// control-mode observer.
    detached_server: bool,
    /// Consecutive transient failures of the default-socket invocation and
    /// when to retry it.
    default_retry: Option<(usize, Instant)>,
}

#[derive(Default)]
pub(crate) struct TmuxSocketRegistry {
    state: tokio::sync::Mutex<TmuxSocketRegistryState>,
    discovery_lock: tokio::sync::Mutex<()>,
    /// One control-mode observer per attached local server, which also
    /// carries commands to it without spawning a client.
    pub(crate) observers: Arc<control_mode::ControlObservers>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SocketProbeOutcome {
    Active,
    Absent,
    Transient,
}

pub(crate) fn socket_probe_outcome(result: &CliResult) -> SocketProbeOutcome {
    if result.ok {
        SocketProbeOutcome::Active
    } else if is_absent_tmux_server(result) {
        SocketProbeOutcome::Absent
    } else {
        SocketProbeOutcome::Transient
    }
}

pub(crate) fn tmux_socket_roots(uid: u32) -> [PathBuf; 2] {
    let directory = format!("tmux-{uid}");
    [
        PathBuf::from("/private/tmp").join(&directory),
        PathBuf::from("/tmp").join(directory),
    ]
}

fn dedupe_discovered_sockets(
    sockets: impl IntoIterator<Item = DiscoveredSocket>,
) -> Vec<DiscoveredSocket> {
    let mut unique = BTreeMap::new();
    for socket in sockets {
        unique
            .entry(socket.identity)
            .and_modify(|existing: &mut DiscoveredSocket| {
                if socket.path < existing.path {
                    existing.path.clone_from(&socket.path);
                }
            })
            .or_insert(socket);
    }
    unique.into_values().collect()
}

async fn discover_tmux_sockets() -> SocketDiscovery {
    let uid = nix::unistd::geteuid().as_raw();
    let mut sockets = Vec::new();
    let mut complete = true;
    for root in tmux_socket_roots(uid) {
        let mut entries = match tokio::fs::read_dir(root).await {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                complete = false;
                continue;
            }
        };
        loop {
            let entry = match entries.next_entry().await {
                Ok(Some(entry)) => entry,
                Ok(None) => break,
                Err(_) => {
                    complete = false;
                    break;
                }
            };
            let path = entry.path();
            let metadata = match tokio::fs::symlink_metadata(&path).await {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => {
                    complete = false;
                    continue;
                }
            };
            if !metadata.file_type().is_socket() {
                continue;
            }
            sockets.push(DiscoveredSocket {
                identity: SocketIdentity {
                    device: metadata.dev(),
                    inode: metadata.ino(),
                },
                path: path.to_string_lossy().into_owned(),
            });
        }
    }
    SocketDiscovery {
        sockets: dedupe_discovered_sockets(sockets),
        complete,
    }
}

async fn resolve_default_tmux_socket_identity(tmux_path: &str) -> Option<SocketIdentity> {
    let result = run_local(
        &tmux_argv(tmux_path, &["display-message", "-p", "#{socket_path}"]),
        Duration::from_secs(2),
    )
    .await;
    if !result.ok {
        return None;
    }
    let path = result.stdout.trim();
    if path.is_empty() {
        return None;
    }
    let metadata = tokio::fs::metadata(path).await.ok()?;
    metadata.file_type().is_socket().then_some(SocketIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

impl TmuxSocketRegistryState {
    fn needs_discovery(&self, now: Instant) -> bool {
        self.discovered_at.is_none_or(|discovered_at| {
            (!self.watched || !self.discovery_complete)
                && now.saturating_duration_since(discovered_at)
                    >= Duration::from_secs(SOCKET_DISCOVERY_INTERVAL_SECS)
        })
    }

    /// The watched directory changed: the next refresh rediscovers.
    pub(crate) fn invalidate(&mut self) {
        self.discovered_at = None;
    }

    fn refresh_discovery(
        &mut self,
        sockets: Vec<DiscoveredSocket>,
        default_identity: Option<SocketIdentity>,
        discovery_complete: bool,
        now: Instant,
    ) {
        let discovered = sockets
            .iter()
            .map(|socket| socket.identity)
            .collect::<BTreeSet<_>>();
        if discovery_complete {
            self.sockets
                .retain(|identity, _| discovered.contains(identity));
        }
        self.default_identity = default_identity;
        if let Some(default_identity) = self.default_identity {
            self.sockets.remove(&default_identity);
        }
        for socket in sockets {
            if Some(socket.identity) == self.default_identity {
                self.sockets.remove(&socket.identity);
                continue;
            }
            self.sockets
                .entry(socket.identity)
                .and_modify(|tracked| tracked.socket.path.clone_from(&socket.path))
                .or_insert(TrackedSocket {
                    socket,
                    state: TrackedSocketState::Unseen,
                });
        }
        self.discovered_at = Some(now);
        self.discovery_complete = discovery_complete;
    }

    pub(crate) fn inventory_plan(&self, now: Instant) -> SocketInventoryPlan {
        let mut targets = self
            .sockets
            .values()
            .filter(|tracked| tracked.state == TrackedSocketState::Active)
            .map(|tracked| tracked.socket.clone())
            .collect::<Vec<_>>();
        let eligible_probes = self.sockets.values().filter(|tracked| match tracked.state {
            TrackedSocketState::Unseen => true,
            TrackedSocketState::Transient { retry_at, .. } => now >= retry_at,
            TrackedSocketState::Active | TrackedSocketState::Absent => false,
        });
        let probes = eligible_probes
            .clone()
            .take(SOCKET_DISCOVERY_FANOUT_LIMIT)
            .map(|tracked| tracked.socket.clone());
        targets.extend(probes);
        let selected_probe_count = targets
            .iter()
            .filter(|target| {
                self.sockets
                    .get(&target.identity)
                    .is_some_and(|tracked| !matches!(tracked.state, TrackedSocketState::Active))
            })
            .count();
        let eligible_probe_count = eligible_probes.count();
        let deferred_retry = self.sockets.values().any(|tracked| {
            matches!(
                tracked.state,
                TrackedSocketState::Transient { retry_at, .. } if now < retry_at
            )
        });
        let inventory_incomplete =
            !self.discovery_complete || eligible_probe_count > selected_probe_count;
        SocketInventoryPlan {
            targets,
            default_identity: self.default_identity,
            deferred: deferred_retry || inventory_incomplete,
            inventory_incomplete,
        }
    }

    pub(crate) fn action_targets(&self) -> Vec<DiscoveredSocket> {
        let mut targets = self
            .sockets
            .values()
            .filter(|tracked| tracked.state == TrackedSocketState::Active)
            .map(|tracked| tracked.socket.clone())
            .collect::<Vec<_>>();
        targets.extend(
            self.sockets
                .values()
                .filter(|tracked| {
                    matches!(
                        tracked.state,
                        TrackedSocketState::Unseen | TrackedSocketState::Transient { .. }
                    )
                })
                .map(|tracked| tracked.socket.clone()),
        );
        targets
    }

    pub(crate) fn has_unseen_sockets(&self) -> bool {
        self.sockets
            .values()
            .any(|tracked| tracked.state == TrackedSocketState::Unseen)
    }

    pub(crate) fn record(
        &mut self,
        identity: SocketIdentity,
        outcome: SocketProbeOutcome,
        now: Instant,
    ) {
        let Some(tracked) = self.sockets.get_mut(&identity) else {
            return;
        };
        tracked.state = match outcome {
            SocketProbeOutcome::Active => TrackedSocketState::Active,
            SocketProbeOutcome::Absent => TrackedSocketState::Absent,
            SocketProbeOutcome::Transient => {
                let failures = match tracked.state {
                    TrackedSocketState::Transient { failures, .. } => failures.saturating_add(1),
                    _ => 1,
                };
                TrackedSocketState::Transient {
                    failures,
                    retry_at: now + socket_retry_delay(failures),
                }
            }
        };
    }

    pub(crate) fn record_default(&mut self, outcome: SocketProbeOutcome, now: Instant) {
        self.default_retry = (outcome == SocketProbeOutcome::Transient).then(|| {
            let failures = self
                .default_retry
                .map_or(1, |(failures, _)| failures.saturating_add(1));
            (failures, now + socket_retry_delay(failures))
        });
    }

    /// When the earliest transiently failing socket is due another probe.
    pub(crate) fn next_retry_at(&self) -> Option<Instant> {
        self.sockets
            .values()
            .filter_map(|tracked| match tracked.state {
                TrackedSocketState::Transient { retry_at, .. } => Some(retry_at),
                _ => None,
            })
            .chain(self.default_retry.map(|(_, retry_at)| retry_at))
            .min()
    }

    /// Whether a client may attach where no control-mode observer or socket
    /// watch would notice.
    pub(crate) fn attach_may_go_unnoticed(&self) -> bool {
        self.detached_server || !self.watched
    }
}

fn socket_retry_delay(failures: usize) -> Duration {
    Duration::from_secs(
        SOCKET_RETRY_DELAYS_SECS[failures
            .saturating_sub(1)
            .min(SOCKET_RETRY_DELAYS_SECS.len() - 1)],
    )
}

impl TmuxSocketRegistry {
    async fn refresh_discovery_if_needed(&self, tmux_path: &str) -> Instant {
        let _discovery_guard = self.discovery_lock.lock().await;
        let now = Instant::now();
        let needs_discovery = self.state.lock().await.needs_discovery(now);
        if needs_discovery {
            let (discovery, default_identity) = tokio::join!(
                discover_tmux_sockets(),
                resolve_default_tmux_socket_identity(tmux_path)
            );
            self.state.lock().await.refresh_discovery(
                discovery.sockets,
                default_identity,
                discovery.complete,
                now,
            );
        }
        now
    }

    pub(crate) async fn inventory_plan(&self, tmux_path: &str) -> SocketInventoryPlan {
        let now = self.refresh_discovery_if_needed(tmux_path).await;
        self.state.lock().await.inventory_plan(now)
    }

    pub(crate) async fn action_targets(&self, tmux_path: &str) -> Vec<DiscoveredSocket> {
        self.refresh_discovery_if_needed(tmux_path).await;
        self.state.lock().await.action_targets()
    }

    pub(crate) async fn has_unseen_sockets(&self) -> bool {
        self.state.lock().await.has_unseen_sockets()
    }

    pub(crate) async fn set_watched(&self, watched: bool) {
        let mut state = self.state.lock().await;
        state.watched = watched;
        state.invalidate();
    }

    pub(crate) async fn invalidate(&self) {
        self.state.lock().await.invalidate();
    }

    pub(crate) async fn record(
        &self,
        identity: SocketIdentity,
        outcome: SocketProbeOutcome,
        now: Instant,
    ) {
        self.state.lock().await.record(identity, outcome, now);
    }

    pub(crate) async fn record_default(&self, outcome: SocketProbeOutcome, now: Instant) {
        self.state.lock().await.record_default(outcome, now);
    }

    pub(crate) async fn set_detached_server(&self, detached: bool) {
        self.state.lock().await.detached_server = detached;
    }

    pub(crate) async fn next_retry_at(&self) -> Option<Instant> {
        self.state.lock().await.next_retry_at()
    }

    pub(crate) async fn attach_may_go_unnoticed(&self) -> bool {
        self.state.lock().await.attach_may_go_unnoticed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn discovered_socket(device: u64, inode: u64, path: &str) -> DiscoveredSocket {
        DiscoveredSocket {
            identity: SocketIdentity { device, inode },
            path: path.to_string(),
        }
    }

    #[test]
    fn socket_discovery_dedupes_aliases_by_inode_deterministically() {
        let private = discovered_socket(1, 10, "/private/tmp/tmux-501/work");
        let alias = discovered_socket(1, 10, "/tmp/tmux-501/work");

        let forward = dedupe_discovered_sockets([alias.clone(), private.clone()]);
        let reverse = dedupe_discovered_sockets([private.clone(), alias]);

        assert_eq!(forward, vec![private.clone()]);
        assert_eq!(reverse, vec![private]);
    }

    #[test]
    fn socket_registry_excludes_default_and_keeps_all_live_named_servers() {
        let now = Instant::now();
        let default = discovered_socket(1, 10, "/private/tmp/tmux-501/default");
        let work = discovered_socket(1, 20, "/private/tmp/tmux-501/work");
        let play = discovered_socket(1, 30, "/private/tmp/tmux-501/play");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(
            vec![default.clone(), work.clone(), play.clone()],
            Some(default.identity),
            true,
            now,
        );
        state.record(work.identity, SocketProbeOutcome::Active, now);
        state.record(play.identity, SocketProbeOutcome::Active, now);

        let plan = state.inventory_plan(now);
        assert_eq!(plan.targets, vec![work, play]);
        assert!(!plan.deferred);
        assert!(!state.sockets.contains_key(&default.identity));
    }

    #[test]
    fn socket_registry_negative_caches_an_absent_inode_but_probes_replacement() {
        let now = Instant::now();
        let old = discovered_socket(1, 10, "/private/tmp/tmux-501/stale");
        let replacement = discovered_socket(1, 11, "/private/tmp/tmux-501/stale");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(vec![old.clone()], None, true, now);
        assert_eq!(state.inventory_plan(now).targets, vec![old.clone()]);

        state.record(old.identity, SocketProbeOutcome::Absent, now);
        state.refresh_discovery(vec![old], None, true, now);
        assert!(state.inventory_plan(now).targets.is_empty());
        assert!(state.action_targets().is_empty());

        state.refresh_discovery(vec![replacement.clone()], None, true, now);
        assert_eq!(
            state.inventory_plan(now + Duration::from_secs(30)).targets,
            vec![replacement]
        );
    }

    #[test]
    fn socket_registry_backs_off_transient_failures_and_resets_after_success() {
        let now = Instant::now();
        let socket = discovered_socket(1, 10, "/private/tmp/tmux-501/work");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(vec![socket.clone()], None, true, now);
        state.record(socket.identity, SocketProbeOutcome::Transient, now);

        let backed_off = state.inventory_plan(now + Duration::from_secs(4));
        assert!(backed_off.targets.is_empty());
        assert!(backed_off.deferred);
        assert_eq!(state.action_targets(), vec![socket.clone()]);
        assert_eq!(
            state.inventory_plan(now + Duration::from_secs(5)).targets,
            vec![socket.clone()]
        );

        state.record(
            socket.identity,
            SocketProbeOutcome::Active,
            now + Duration::from_secs(5),
        );
        assert_eq!(
            state.inventory_plan(now + Duration::from_secs(5)).targets,
            vec![socket.clone()]
        );
        state.record(
            socket.identity,
            SocketProbeOutcome::Transient,
            now + Duration::from_secs(6),
        );
        assert_eq!(
            state
                .sockets
                .get(&socket.identity)
                .map(|tracked| tracked.state),
            Some(TrackedSocketState::Transient {
                failures: 1,
                retry_at: now + Duration::from_secs(11),
            })
        );
    }

    #[test]
    fn socket_registry_bounds_new_probes_without_dropping_active_servers() {
        let now = Instant::now();
        let sockets = (0..20)
            .map(|index| {
                discovered_socket(
                    1,
                    index,
                    &format!("/private/tmp/tmux-501/socket-{index:02}"),
                )
            })
            .collect::<Vec<_>>();
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(sockets.clone(), None, true, now);
        state.record(sockets[0].identity, SocketProbeOutcome::Active, now);
        state.record(sockets[1].identity, SocketProbeOutcome::Active, now);

        let plan = state.inventory_plan(now);
        assert_eq!(plan.targets.len(), 2 + SOCKET_DISCOVERY_FANOUT_LIMIT);
        assert!(plan.targets.contains(&sockets[0]));
        assert!(plan.targets.contains(&sockets[1]));
        assert!(plan.deferred);
        assert_eq!(state.action_targets().len(), sockets.len());
    }

    #[test]
    fn socket_registry_clears_stale_default_identity_before_inode_reuse() {
        let now = Instant::now();
        let former_default = discovered_socket(1, 10, "/private/tmp/tmux-501/default");
        let replacement = discovered_socket(1, 10, "/private/tmp/tmux-501/work");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(
            vec![former_default.clone()],
            Some(former_default.identity),
            true,
            now,
        );
        assert!(state.sockets.is_empty());

        state.refresh_discovery(
            vec![replacement.clone()],
            None,
            true,
            now + Duration::from_secs(30),
        );

        assert_eq!(state.inventory_plan(now).targets, vec![replacement]);
    }

    #[test]
    fn incomplete_socket_discovery_preserves_known_live_servers() {
        let now = Instant::now();
        let socket = discovered_socket(1, 10, "/private/tmp/tmux-501/work");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(vec![socket.clone()], None, true, now);
        state.record(socket.identity, SocketProbeOutcome::Active, now);

        state.refresh_discovery(Vec::new(), None, false, now + Duration::from_secs(30));

        let plan = state.inventory_plan(now + Duration::from_secs(30));
        assert_eq!(plan.targets, vec![socket]);
        assert!(plan.deferred);
    }

    #[test]
    fn successful_empty_socket_probe_still_marks_server_active() {
        let successful_empty = CliResult {
            ok: true,
            status: 0,
            ..CliResult::default()
        };
        assert_eq!(
            socket_probe_outcome(&successful_empty),
            SocketProbeOutcome::Active
        );
    }

    #[test]
    fn a_watched_socket_directory_is_rescanned_only_when_it_changes() {
        let now = Instant::now();
        let later = now + Duration::from_secs(SOCKET_DISCOVERY_INTERVAL_SECS);
        let mut state = TmuxSocketRegistryState::default();
        assert!(state.needs_discovery(now), "never discovered");
        state.refresh_discovery(Vec::new(), None, true, now);
        assert!(!state.needs_discovery(now));
        assert!(state.needs_discovery(later), "unwatched: the rescan period");

        state.watched = true;
        assert!(
            !state.needs_discovery(later + Duration::from_secs(3_600)),
            "watched: a complete scan stays current"
        );
        state.invalidate();
        assert!(state.needs_discovery(now), "a directory change rescans");
        state.refresh_discovery(Vec::new(), None, false, now);
        assert!(!state.needs_discovery(now));
        assert!(
            state.needs_discovery(later),
            "an incomplete scan still retries on the period"
        );
    }

    #[test]
    fn transient_failures_owe_one_retry_at_their_backoff() {
        let now = Instant::now();
        let socket = discovered_socket(1, 10, "/private/tmp/tmux-501/work");
        let mut state = TmuxSocketRegistryState::default();
        state.refresh_discovery(vec![socket.clone()], None, true, now);
        assert_eq!(state.next_retry_at(), None);
        state.record(socket.identity, SocketProbeOutcome::Transient, now);
        assert_eq!(state.next_retry_at(), Some(now + Duration::from_secs(5)));
        state.record_default(SocketProbeOutcome::Transient, now);
        state.record_default(SocketProbeOutcome::Transient, now);
        assert_eq!(
            state.default_retry,
            Some((2, now + Duration::from_secs(15))),
            "the default socket backs off too"
        );
        assert_eq!(state.next_retry_at(), Some(now + Duration::from_secs(5)));
        state.record(socket.identity, SocketProbeOutcome::Absent, now);
        assert_eq!(state.next_retry_at(), Some(now + Duration::from_secs(15)));
        state.record_default(SocketProbeOutcome::Active, now);
        assert_eq!(state.next_retry_at(), None, "every socket answered");
    }

    #[test]
    fn window_bursts_refresh_only_while_an_attach_could_go_unnoticed() {
        let mut state = TmuxSocketRegistryState::default();
        assert!(state.attach_may_go_unnoticed(), "no socket watch yet");
        state.watched = true;
        assert!(!state.attach_may_go_unnoticed(), "every server observed");
        state.detached_server = true;
        assert!(state.attach_may_go_unnoticed(), "a detached server runs");
    }
}
