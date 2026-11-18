//! Warm-catalog refreshes: the coalescing coordinator, candidate partitions
//! and their hash-gated publish, observers, the socket watch and the remote
//! poll.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use flash_plugin::{Candidate, CandidateEffect, Context, PollHandle, PollPriority, Settle};

use crate::candidates::{LocalTmuxConfig, build_candidates, build_remote_candidates};
use crate::clients::{ClientSnapshot, observed_servers};
use crate::invocation::CliResult;
use crate::remote::{RemoteTmuxConfig, discover_remote_tmux_configs};
use crate::sockets::{TmuxSocketRegistry, tmux_socket_roots};
use crate::status_segments::{TmuxStatusSegments, publish_status_segments};
use crate::{Tmux, control_mode, socket_watch};

const SLOW_CANDIDATE_REFRESH_MS: u128 = 1_000;
const REMOTE_POLL_INTERVAL_SECS: u64 = 5;
const REMOTE_RETRY_DELAYS_SECS: [u64; 3] = [15, 30, 60];

// Keep the last good remote inventory through the complete retry ramp, but do
// not present it as current forever when the SSH side channel behind an active
// Mosh transport stays unavailable.
const REMOTE_CANDIDATE_STALE_AFTER_SECS: u64 = 120;

/// Identity hash of the complete host-visible and routing row set. Used by
/// [`refresh_candidate_locations_for_path`] to skip the `publish` only when
/// every field is unchanged — including current-location state and the payload
/// that identifies the tmux client.
///
/// Without this gate, every notification-triggered refresh would push a full
/// catalog replacement across the wire even when tmux state was identical.
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
/// keeps unchanged refreshes as no-ops — see the crate-level "Warm-location
/// contract" docs.
///
/// On a transient tmux failure (e.g. every usable socket invocation timed out)
/// we leave the previous warm locations in place: the host keeps pulling
/// them for synchronous reads, and the next successful refresh re-syncs. We
/// do *not* store an empty set in this case — nuking the warm cache to `[]`
/// would make tmux windows vanish from flashlight every time a single
/// socket call hiccuped.
#[derive(Default)]
pub(crate) struct CandidateRefreshCoordinator {
    lock: tokio::sync::Mutex<()>,
    requested_generation: AtomicU64,
    completed_generation: AtomicU64,
}

#[derive(Default)]
pub(crate) struct CandidatePartitions {
    pub(crate) local: Vec<Candidate>,
    pub(crate) remote: BTreeMap<String, RemoteCandidatePartition>,
}

pub(crate) struct RemoteCandidatePartition {
    pub(crate) candidates: Vec<Candidate>,
    refreshed_at: Instant,
}

#[derive(Clone)]
enum CandidatePartition {
    Local,
    Remote(String),
}

impl CandidateRefreshCoordinator {
    async fn run<F, Fut>(&self, mut work: F)
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = ()>,
    {
        let generation = self
            .requested_generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        let _guard = self.lock.lock().await;
        if self.completed_generation.load(Ordering::Acquire) >= generation {
            return;
        }
        loop {
            let through_generation = self.requested_generation.load(Ordering::Acquire);
            work().await;
            self.completed_generation
                .store(through_generation, Ordering::Release);
            if self.requested_generation.load(Ordering::Acquire) == through_generation {
                return;
            }
        }
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
    local_config: &Mutex<LocalTmuxConfig>,
    coordinator: &CandidateRefreshCoordinator,
    socket_registry: &TmuxSocketRegistry,
) {
    coordinator
        .run(|| {
            let local_config = local_config
                .lock()
                .map(|config| config.clone())
                .unwrap_or_default();
            refresh_candidate_locations_for_path_inner(
                tmux_path,
                ctx,
                last_hash,
                client_snapshot,
                partitions,
                last_status,
                local_config,
                socket_registry,
            )
        })
        .await;
}

#[allow(clippy::too_many_arguments)]
async fn refresh_candidate_locations_for_path_inner(
    tmux_path: Option<&str>,
    ctx: &Context,
    last_hash: &Mutex<Option<u64>>,
    client_snapshot: &Mutex<ClientSnapshot>,
    partitions: &Mutex<CandidatePartitions>,
    last_status: &Mutex<Option<TmuxStatusSegments>>,
    local_config: LocalTmuxConfig,
    socket_registry: &TmuxSocketRegistry,
) {
    let started_at = Instant::now();
    let previous_client_snapshot = client_snapshot
        .lock()
        .map(|snapshot| snapshot.clone())
        .unwrap_or_default();
    let build_result = build_candidates(
        tmux_path,
        ctx,
        &previous_client_snapshot,
        &local_config,
        socket_registry,
    )
    .await;
    let elapsed_ms = started_at.elapsed().as_millis();
    let Some(build) = build_result else {
        if socket_registry.has_unseen_sockets().await {
            // Bounded startup discovery deliberately needs another wave. It
            // is progress, not an operational failure, so keep the internal
            // retry silent instead of emitting one log frame per batch.
            return;
        }
        let fields = candidate_refresh_log_fields("failed", elapsed_ms, None, None);
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
        // Healthy unchanged refreshes stay allocation- and wire-silent. Slow
        // refreshes still warn with fields built only on that exceptional path.
        if elapsed_ms >= SLOW_CANDIDATE_REFRESH_MS {
            let fields = candidate_refresh_log_fields(
                "ok",
                elapsed_ms,
                Some(aggregate_count),
                Some("unchanged"),
            );
            warn_if_candidate_refresh_slow(ctx, fields, elapsed_ms);
        }
        return;
    }
    let mut fields = candidate_refresh_log_fields(
        if local_candidate_count == 0 {
            "empty"
        } else {
            "ok"
        },
        elapsed_ms,
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
    candidates: Option<usize>,
    change: Option<&str>,
) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    fields.insert("outcome".to_string(), outcome.to_string());
    fields.insert("elapsed_ms".to_string(), elapsed_ms.to_string());
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

/// Re-read the local inventory, draining newly discovered sockets in bounded
/// waves, then converge the control-mode observers on the servers it found
/// attached and arm the one retry a transiently failing socket is owed.
pub(crate) async fn refresh_candidate_locations(plugin: &Tmux, ctx: &Context) {
    loop {
        refresh_local_candidate_locations(plugin, ctx).await;
        // Stale endpoints fail quickly, so a complete catalog still lands
        // promptly without an unbounded subprocess fan-out.
        if !plugin.tmux_socket_registry().has_unseen_sockets().await {
            break;
        }
        tokio::task::yield_now().await;
    }
    reconcile_observers(plugin, ctx).await;
    if let Some(at) = plugin.tmux_socket_registry().next_retry_at().await {
        schedule_socket_retry(plugin, ctx, at);
    }
}

async fn refresh_local_candidate_locations(plugin: &Tmux, ctx: &Context) {
    refresh_candidate_locations_for_path(
        plugin.resolved_tmux_path().await,
        ctx,
        plugin.last_locations_hash(),
        plugin.client_snapshot(),
        plugin.candidate_partitions(),
        plugin.last_status_segments(),
        &plugin.local_config_arc,
        plugin.candidate_refresh_coordinator(),
        plugin.tmux_socket_registry(),
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

pub(crate) async fn refresh_remote_backends(
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

/// Control-mode notifications and socket changes come in bursts (a new
/// window posts several at once); one inventory read follows each burst,
/// within a second even while notifications keep coming.
const CHANGE_SETTLE: Duration = Duration::from_millis(100);
const CHANGE_MAX_WAIT: Duration = Duration::from_secs(1);
/// `High`: the read redraws the session and window status segments, which
/// the user is looking at as they switch.
static CHANGE_BURST: Settle<()> = Settle::new(CHANGE_SETTLE, CHANGE_MAX_WAIT, PollPriority::High);

fn schedule_change_refresh(plugin: &Tmux, ctx: &Context) {
    let plugin = plugin.clone();
    let refresh_ctx = ctx.clone();
    CHANGE_BURST.schedule(ctx, (), move |_| async move {
        refresh_candidate_locations(&plugin, &refresh_ctx).await;
    });
}

/// Retry a transiently failing socket at its backoff deadline: one pending
/// host deadline at most, and none once every socket answered. `Low`: a
/// backoff of seconds nobody is waiting on.
fn schedule_socket_retry(plugin: &Tmux, ctx: &Context, at: Instant) {
    {
        let mut pending = plugin
            .socket_retry_arc
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if pending.is_some_and(|pending| pending <= at) {
            return;
        }
        *pending = Some(at);
    }
    let plugin = plugin.clone();
    let delay = at.saturating_duration_since(Instant::now());
    ctx.after(delay, PollPriority::Low, move |ctx| async move {
        {
            let mut pending = plugin
                .socket_retry_arc
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            // An earlier retry superseded this one, or already ran.
            if *pending != Some(at) {
                return;
            }
            *pending = None;
        }
        refresh_candidate_locations(&plugin, &ctx).await;
    });
}

/// Follow every local server a user client is attached to, and only those.
async fn reconcile_observers(plugin: &Tmux, ctx: &Context) {
    if !plugin.observers_supported().await {
        return;
    }
    let Some(tmux_path) = plugin.resolved_tmux_path().await.map(str::to_string) else {
        return;
    };
    let plan = plugin
        .client_snapshot()
        .lock()
        .map(|snapshot| observed_servers(&snapshot.clients))
        .unwrap_or_default();
    let changed: Arc<dyn Fn() + Send + Sync> = {
        let plugin = plugin.clone();
        let ctx = ctx.clone();
        Arc::new(move || schedule_change_refresh(&plugin, &ctx))
    };
    let observers = plugin.observers();
    if observers.reconcile(&plan, |socket, follow, channel| {
        tokio::spawn(control_mode::observe(
            ctx.clone(),
            tmux_path.clone(),
            socket.to_string(),
            follow,
            channel,
            Arc::clone(&changed),
        ))
    }) {
        ctx.log_fields(
            "debug",
            "[tmux] observers",
            BTreeMap::from([("servers".to_string(), observers.count().to_string())]),
        );
    }
}

/// Watch the socket directory so a server starting or exiting rediscovers
/// sockets and refreshes once the change settles. Without the watch,
/// discovery falls back to rescanning on refreshes.
pub(crate) fn start_socket_watch(plugin: &Tmux, ctx: &Context) {
    let plugin = plugin.clone();
    let ctx = ctx.clone();
    tokio::spawn(async move {
        let uid = nix::unistd::geteuid().as_raw();
        let [socket_directory, _] = tmux_socket_roots(uid);
        let mut watch = match socket_watch::SocketDirWatch::new(socket_directory).await {
            Ok(watch) => watch,
            Err(error) => {
                ctx.log(
                    "warn",
                    &format!("[tmux] socket directory watch unavailable; rescanning: {error}"),
                );
                return;
            }
        };
        plugin.tmux_socket_registry().set_watched(true).await;
        loop {
            if let Err(error) = watch.changed().await {
                plugin.tmux_socket_registry().set_watched(false).await;
                ctx.log(
                    "warn",
                    &format!("[tmux] socket directory watch stopped; rescanning: {error}"),
                );
                return;
            }
            plugin.tmux_socket_registry().invalidate().await;
            schedule_change_refresh(&plugin, &ctx);
        }
    });
}

pub(crate) fn start_remote_candidate_poll(
    plugin: &Tmux,
    ctx: &Context,
    ssh_hosts: Arc<BTreeSet<String>>,
    initial_succeeded: bool,
) {
    let remote_configs = std::sync::Arc::clone(&plugin.remote_configs_arc);
    let partitions = std::sync::Arc::clone(&plugin.candidate_partitions_arc);
    let last_hash = std::sync::Arc::clone(&plugin.last_locations_hash_arc);
    let ctx = ctx.clone();
    let initial_index = if initial_succeeded { 0usize } else { 1 };
    let failure_index = Arc::new(Mutex::new(initial_index));
    let handle: Arc<OnceLock<PollHandle>> = Arc::new(OnceLock::new());
    let slot = Arc::clone(&handle);
    // `Low`: a remote pull over SSH, retried on a ladder; nothing on screen
    // waits on its exact second.
    let registered = ctx.interval(
        Duration::from_secs(remote_poll_delay_secs(initial_index)),
        PollPriority::Low,
        move |ctx| {
            let remote_configs = Arc::clone(&remote_configs);
            let ssh_hosts = Arc::clone(&ssh_hosts);
            let partitions = Arc::clone(&partitions);
            let last_hash = Arc::clone(&last_hash);
            let failure_index = Arc::clone(&failure_index);
            let slot = Arc::clone(&slot);
            async move {
                let discovered = discover_remote_tmux_configs(&ctx, &ssh_hosts).await;
                if let Ok(mut configured) = remote_configs.lock() {
                    *configured = discovered.clone();
                }
                let ok = refresh_remote_backends(
                    &discovered,
                    &ctx,
                    Arc::clone(&partitions),
                    Arc::clone(&last_hash),
                )
                .await;
                // Back off through the retry ladder on failure and drop back
                // to the steady cadence as soon as a refresh lands.
                let next = {
                    let mut index = failure_index.lock().unwrap();
                    *index = if ok {
                        0
                    } else {
                        (*index + 1).min(REMOTE_RETRY_DELAYS_SECS.len())
                    };
                    remote_poll_delay_secs(*index)
                };
                if let Some(handle) = slot.get() {
                    handle.set_period(Duration::from_secs(next));
                }
            }
        },
    );
    drop(handle.set(registered));
}

/// Steady cadence at index zero, then the retry ladder.
fn remote_poll_delay_secs(failure_index: usize) -> u64 {
    if failure_index == 0 {
        REMOTE_POLL_INTERVAL_SECS
    } else {
        REMOTE_RETRY_DELAYS_SECS[(failure_index - 1).min(REMOTE_RETRY_DELAYS_SECS.len() - 1)]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::candidates::{SOURCE_WINDOWS, TmuxPayload, routed_tmux_target, tmux_navigation_url};

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
    async fn candidate_refresh_coordinator_coalesces_a_burst_into_one_trailing_pass() {
        use std::sync::atomic::AtomicUsize;

        let coordinator = Arc::new(CandidateRefreshCoordinator::default());
        let passes = Arc::new(AtomicUsize::new(0));
        let in_flight = Arc::new(AtomicUsize::new(0));
        let max_in_flight = Arc::new(AtomicUsize::new(0));
        let first_started = Arc::new(tokio::sync::Notify::new());
        let release_first = Arc::new(tokio::sync::Notify::new());
        let leader = {
            let coordinator = Arc::clone(&coordinator);
            let passes = Arc::clone(&passes);
            let in_flight = Arc::clone(&in_flight);
            let max_in_flight = Arc::clone(&max_in_flight);
            let first_started = Arc::clone(&first_started);
            let release_first = Arc::clone(&release_first);
            tokio::spawn(async move {
                coordinator
                    .run(move || {
                        let passes = Arc::clone(&passes);
                        let in_flight = Arc::clone(&in_flight);
                        let max_in_flight = Arc::clone(&max_in_flight);
                        let first_started = Arc::clone(&first_started);
                        let release_first = Arc::clone(&release_first);
                        async move {
                            let pass = passes.fetch_add(1, Ordering::SeqCst);
                            let current = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                            max_in_flight.fetch_max(current, Ordering::SeqCst);
                            if pass == 0 {
                                first_started.notify_one();
                                release_first.notified().await;
                            }
                            in_flight.fetch_sub(1, Ordering::SeqCst);
                        }
                    })
                    .await;
            })
        };
        tokio::time::timeout(Duration::from_secs(1), first_started.notified())
            .await
            .expect("first refresh started");

        let mut requests = tokio::task::JoinSet::new();
        for _ in 0..24 {
            let coordinator = Arc::clone(&coordinator);
            let passes = Arc::clone(&passes);
            let in_flight = Arc::clone(&in_flight);
            let max_in_flight = Arc::clone(&max_in_flight);
            requests.spawn(async move {
                coordinator
                    .run(move || {
                        let passes = Arc::clone(&passes);
                        let in_flight = Arc::clone(&in_flight);
                        let max_in_flight = Arc::clone(&max_in_flight);
                        async move {
                            passes.fetch_add(1, Ordering::SeqCst);
                            let current = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                            max_in_flight.fetch_max(current, Ordering::SeqCst);
                            in_flight.fetch_sub(1, Ordering::SeqCst);
                        }
                    })
                    .await;
            });
        }
        tokio::time::timeout(Duration::from_secs(1), async {
            while coordinator.requested_generation.load(Ordering::Acquire) < 25 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("all burst requests registered");
        release_first.notify_one();

        leader.await.expect("leader refresh task");
        while let Some(result) = requests.join_next().await {
            result.expect("coalesced refresh task");
        }
        assert_eq!(passes.load(Ordering::SeqCst), 2);
        assert_eq!(max_in_flight.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn candidate_refresh_coordinator_runs_another_pass_for_trailing_requests() {
        let coordinator = Arc::new(CandidateRefreshCoordinator::default());
        let passes = Arc::new(AtomicU64::new(0));
        let first_release = Arc::new(tokio::sync::Notify::new());
        let trailing_release = Arc::new(tokio::sync::Notify::new());
        let (started_tx, mut started_rx) = tokio::sync::mpsc::unbounded_channel();
        let leader = {
            let coordinator = Arc::clone(&coordinator);
            let passes = Arc::clone(&passes);
            let first_release = Arc::clone(&first_release);
            let trailing_release = Arc::clone(&trailing_release);
            tokio::spawn(async move {
                coordinator
                    .run(move || {
                        let pass = passes.fetch_add(1, Ordering::SeqCst);
                        let first_release = Arc::clone(&first_release);
                        let trailing_release = Arc::clone(&trailing_release);
                        let started_tx = started_tx.clone();
                        async move {
                            started_tx.send(pass).expect("record pass start");
                            match pass {
                                0 => first_release.notified().await,
                                1 => trailing_release.notified().await,
                                _ => {}
                            }
                        }
                    })
                    .await;
            })
        };
        assert_eq!(started_rx.recv().await, Some(0));

        let second = {
            let coordinator = Arc::clone(&coordinator);
            tokio::spawn(async move { coordinator.run(|| async {}).await })
        };
        while coordinator.requested_generation.load(Ordering::Acquire) < 2 {
            tokio::task::yield_now().await;
        }
        first_release.notify_one();
        assert_eq!(started_rx.recv().await, Some(1));

        let third = {
            let coordinator = Arc::clone(&coordinator);
            tokio::spawn(async move { coordinator.run(|| async {}).await })
        };
        while coordinator.requested_generation.load(Ordering::Acquire) < 3 {
            tokio::task::yield_now().await;
        }
        trailing_release.notify_one();
        assert_eq!(started_rx.recv().await, Some(2));

        leader.await.expect("leader refresh task");
        second.await.expect("second refresh task");
        third.await.expect("third refresh task");
        assert_eq!(passes.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn candidate_refresh_coordinator_recovers_when_the_leader_is_cancelled() {
        let coordinator = Arc::new(CandidateRefreshCoordinator::default());
        let leader_started = Arc::new(tokio::sync::Notify::new());
        let leader = {
            let coordinator = Arc::clone(&coordinator);
            let leader_started = Arc::clone(&leader_started);
            tokio::spawn(async move {
                coordinator
                    .run(move || {
                        let leader_started = Arc::clone(&leader_started);
                        async move {
                            leader_started.notify_one();
                            std::future::pending::<()>().await;
                        }
                    })
                    .await;
            })
        };
        tokio::time::timeout(Duration::from_secs(1), leader_started.notified())
            .await
            .expect("leader refresh started");

        let waiter_ran = Arc::new(tokio::sync::Notify::new());
        let waiter = {
            let coordinator = Arc::clone(&coordinator);
            let waiter_ran = Arc::clone(&waiter_ran);
            tokio::spawn(async move {
                coordinator
                    .run(move || {
                        let waiter_ran = Arc::clone(&waiter_ran);
                        async move { waiter_ran.notify_one() }
                    })
                    .await;
            })
        };
        while coordinator.requested_generation.load(Ordering::Acquire) < 2 {
            tokio::task::yield_now().await;
        }
        leader.abort();
        let _ = leader.await;

        tokio::time::timeout(Duration::from_secs(1), waiter_ran.notified())
            .await
            .expect("waiting refresh took over after cancellation");
        waiter.await.expect("waiting refresh task");
    }

    #[tokio::test]
    async fn candidate_refresh_coordinator_runs_sequential_idle_requests() {
        let coordinator = CandidateRefreshCoordinator::default();
        let passes = AtomicU64::new(0);

        coordinator
            .run(|| async {
                passes.fetch_add(1, Ordering::SeqCst);
            })
            .await;
        coordinator
            .run(|| async {
                passes.fetch_add(1, Ordering::SeqCst);
            })
            .await;

        assert_eq!(passes.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn candidate_refresh_coordinator_trailing_pass_reads_current_shared_input() {
        let coordinator = Arc::new(CandidateRefreshCoordinator::default());
        let current_input = Arc::new(AtomicU64::new(1));
        let observed = Arc::new(Mutex::new(Vec::new()));
        let first_started = Arc::new(tokio::sync::Notify::new());
        let release_first = Arc::new(tokio::sync::Notify::new());
        let leader = {
            let coordinator = Arc::clone(&coordinator);
            let current_input = Arc::clone(&current_input);
            let observed = Arc::clone(&observed);
            let first_started = Arc::clone(&first_started);
            let release_first = Arc::clone(&release_first);
            tokio::spawn(async move {
                coordinator
                    .run(move || {
                        let value = current_input.load(Ordering::SeqCst);
                        let observed = Arc::clone(&observed);
                        let first_started = Arc::clone(&first_started);
                        let release_first = Arc::clone(&release_first);
                        async move {
                            let first = observed
                                .lock()
                                .map(|mut values| {
                                    values.push(value);
                                    values.len() == 1
                                })
                                .unwrap_or(false);
                            if first {
                                first_started.notify_one();
                                release_first.notified().await;
                            }
                        }
                    })
                    .await;
            })
        };
        first_started.notified().await;

        let follower = {
            let coordinator = Arc::clone(&coordinator);
            tokio::spawn(async move { coordinator.run(|| async {}).await })
        };
        while coordinator.requested_generation.load(Ordering::Acquire) < 2 {
            tokio::task::yield_now().await;
        }
        current_input.store(2, Ordering::SeqCst);
        release_first.notify_one();

        leader.await.expect("leader refresh task");
        follower.await.expect("follower refresh task");
        assert_eq!(
            observed.lock().map(|values| values.clone()).unwrap(),
            vec![1, 2]
        );
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
}
