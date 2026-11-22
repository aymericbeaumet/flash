//! Tmux plugin — ports the former Python tmux plugin to Rust.
//!
//! ## Warm-catalog contract
//!
//! The local catalog follows tmux's own change notifications; nothing
//! re-reads it on a timer:
//!
//!   1. `on_start` builds and publishes the initial rows. The candidate hash
//!      gates publishes, so unchanged refreshes are true no-ops.
//!   2. Every local server a user's client is attached to is followed by one
//!      output-free control-mode client ([`control_mode`]). Its notifications
//!      — sessions and windows created, closed, renamed (automatic-rename
//!      included) or selected, panes selected, added or closed, clients
//!      attaching, switching or detaching — trigger one inventory read per
//!      burst ([`Settle`]).
//!   3. A kqueue watch on the `tmux-$UID` socket directory
//!      ([`socket_watch`]) rediscovers servers when one starts or exits.
//!   4. What tmux never notifies is read at interaction boundaries: a
//!      window's working directory (and its command once automatic-rename is
//!      off) on focus changes, app termination and flashlight opens
//!      (`core:session.opened`). A client attaching to a server nobody is
//!      attached to reaches no observer; while such a server runs, a settled
//!      burst of window retitles and creations (`core:ax.changed`: attaching
//!      retitles the terminal, a new window may start attached) refreshes
//!      too. Other AX notifications, keystrokes among them, are ignored.
//!   5. The flashlight reads the host-owned store fed by `publish`; no tmux
//!      I/O ever rides the hot path.
//!   6. Each refresh also retains its `list-clients` + process tree
//!      sample. The host-wide process tree (libproc, never `ps`) is reused
//!      while the tmux client pid set is unchanged. Hint discovery and
//!      repeatable source actions consult that warm cache first; the actions
//!      validate only the cached client's live session, so `[t` / `]t` avoid
//!      a host-wide process walk and all-socket rediscovery before changing
//!      windows.
//!   7. Each successful local refresh also derives the attached-client
//!      session/window/pane statusbar segments (`#{flash.plugin.terminals.session}` /
//!      `.window` / `.pane`) from the same inventory and emits the `status`
//!      notification only when the values change.
//!   8. Local tmux commands — actions, hint captures, inventory reads — are
//!      lines written to the server's observer ([`control_mode`]), not
//!      spawned clients: an exec can stall for seconds while macOS's exec
//!      policy daemon is busy, a written line cannot. A spawned client runs a
//!      command only where no observer is attached yet.
//!
//! A socket whose probe fails transiently is retried once at its backoff
//! deadline. Remote hosts, which no local notification reaches, keep their
//! own five-second refresh.
//!
//! Per-socket subprocess fan-out (`list-clients`, `list-windows -a`) and
//! per-host SSH inventory refreshes run concurrently so one slow socket or
//! remote host cannot make every independent backend wait behind it. Remote
//! hosts are opt-in through `[plugins.terminals] ssh_hosts`; without one the plugin
//! opens no SSH connection.
//!
//! ## Hint discovery
//!
//! On each activation Flash calls `hints` with the focused app's pid +
//! window frame; the plugin returns pane-chip and link-chip targets in
//! screen coordinates.
//!
//! Alacritty uses tmux-reported cell pixels and the captured display scale,
//! for an undecorated, dynamically padded window. Other terminals keep their
//! window/grid geometry.
//!   - pane chips: 3-cell-wide rect at pane centre.
//!   - link chips: OSC 8 spans and plain URL/path matches in visible
//!     `capture-pane -p -e` snapshots, with terminal-cell columns.
//!
//! ## Text grid
//!
//! Letter search (`s`) in a terminal that publishes no Accessibility text
//! asks `text_grid` for the focused client's cells: the same layout read and
//! pane captures as `hints`, over the same observer channel, returned as
//! rows and columns. The host owns the geometry and lays out the status line
//! and pane-border titles itself.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    Candidate, CommandRequest, Context, Event, HintsRequest, HintsResponse, NavigateRequest,
    PerformResponse, PollPriority, Settle, TextGridRequest, TextGridResponse, ax_notifications,
    host_events, run,
};

mod actions;
mod candidates;
mod clients;
mod commands;
mod control_mode;
mod geometry;
mod hints;
mod inventory;
mod invocation;
mod links;
mod pane_capture;
mod processes;
mod refresh;
mod remote;
mod resolve;
mod socket_watch;
mod sockets;
mod status_hints;
mod status_segments;
mod terminal_windows;
#[cfg(test)]
mod test_support;
mod text_grid;

use actions::perform_source_command;
use candidates::{LocalTmuxConfig, local_tmux_config};
use clients::ClientSnapshot;
use commands::{invoke_command, restore_navigation};
use hints::hints_for_context;
use invocation::{find_tmux, run_local};
use refresh::{
    CandidatePartitions, CandidateRefreshCoordinator, refresh_candidate_locations,
    refresh_remote_backends, start_remote_candidate_poll, start_socket_watch,
};
use remote::{RemoteTmuxConfig, configured_ssh_hosts, discover_remote_tmux_configs};
use resolve::resolve;
use sockets::TmuxSocketRegistry;
use status_segments::TmuxStatusSegments;
use text_grid::text_grid_for_context;

const STARTUP_WARM_BUDGET: Duration = Duration::from_secs(10);
/// The AX notifications that can reveal a client attaching to a server no
/// observer follows: attaching retitles the terminal's window, and a new
/// window may start attached.
const AX_REFRESH_NOTIFICATIONS: [&str; 2] = [
    ax_notifications::TITLE_CHANGED,
    ax_notifications::WINDOW_CREATED,
];
/// A shell retitles the window before and after each command, so a burst
/// refreshes once it has been quiet this long…
const AX_SETTLE: Duration = Duration::from_millis(300);
/// …or this long after it began, whichever comes first.
const AX_MAX_WAIT: Duration = Duration::from_secs(10);
/// `Normal`: it refreshes the catalog, which nobody watches refresh.
static AX_BURST: Settle<i64> = Settle::new(AX_SETTLE, AX_MAX_WAIT, PollPriority::Normal);

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::{Value, json};

    use crate::test_support::ExecutableFixture;

    /// While no client is attached, only a window retitled or created can
    /// reveal one attaching: a keystroke's value change never starts a burst.
    #[tokio::test]
    async fn only_window_retitles_and_creations_start_an_ax_burst() {
        let plugin = Tmux::default();
        let harness = flash_plugin::testing::Harness::new("tmux");
        for notification in ax_notifications::ALL
            .into_iter()
            .filter(|notification| !AX_REFRESH_NOTIFICATIONS.contains(notification))
        {
            plugin
                .on_event(
                    harness.context(),
                    Event {
                        name: "core:ax.changed".into(),
                        pid: Some(42),
                        notification: Some(notification.into()),
                        ..Event::default()
                    },
                )
                .await;
            assert!(AX_BURST.due().is_none(), "{notification}");
        }
    }

    async fn wait_for(what: &str, mut ready: impl AsyncFnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ready().await {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn read_or_empty(path: &std::path::Path) -> String {
        tokio::fs::read_to_string(path).await.unwrap_or_default()
    }

    /// A fake tmux control client: it reports its argv and pid, answers the
    /// attach, echoes every command it reads, follows `switch-client`, and
    /// records the end of its input before leaving.
    async fn fake_control_client(fixture: &ExecutableFixture) -> String {
        let dir = fixture.0.to_string_lossy().into_owned();
        fixture
            .script(
                "tmux",
                &format!(
                    r#"dir={dir}
printf '%s\n' "$*" >> "$dir/argv"
printf '%s\n' "$$" > "$dir/pid"
printf '%%begin 1 1 0\n%%end 1 1 0\n%%session-changed $1 main\n%%window-add @2\n%%output %%1 ignored\n'
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$dir/stdin"
    case "$line" in
        "switch-client -E -t '\$2'") printf '%%begin 2 2 1\n%%end 2 2 1\n%%session-changed $2 other\n' ;;
    esac
done
printf 'eof\n' >> "$dir/stdin"
printf '%%exit\n'"#
                ),
            )
            .await
    }

    async fn process_alive(pid: &str) -> bool {
        tokio::process::Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stderr(std::process::Stdio::null())
            .status()
            .await
            .is_ok_and(|status| status.success())
    }

    #[tokio::test]
    async fn an_observer_reports_changes_follows_its_session_and_leaves_on_stop() {
        let fixture = ExecutableFixture::new().await;
        let tmux = fake_control_client(&fixture).await;
        let harness = flash_plugin::testing::Harness::new("tmux");
        let ctx = harness.context();
        let notified = Arc::new(AtomicU64::new(0));
        let changed: Arc<dyn Fn() + Send + Sync> = {
            let notified = Arc::clone(&notified);
            Arc::new(move || {
                notified.fetch_add(1, Ordering::SeqCst);
            })
        };
        let observers = control_mode::ControlObservers::default();
        let start = |socket: &str, follow, channel| {
            tokio::spawn(control_mode::observe(
                ctx.clone(),
                tmux.clone(),
                socket.to_string(),
                follow,
                channel,
                Arc::clone(&changed),
            ))
        };
        let socket = "/tmp/flash-test.sock".to_string();

        assert!(observers.reconcile(&BTreeMap::from([(socket.clone(), "$1".to_string())]), start));
        // The attach reply is output; the session and window notifications
        // count, pane output does not.
        wait_for("attach notifications", async || {
            notified.load(Ordering::SeqCst) == 2
        })
        .await;
        let argv = read_or_empty(&fixture.0.join("argv")).await;
        assert_eq!(
            argv.trim(),
            "-S /tmp/flash-test.sock -N -C attach-session -E -f no-output,ignore-size,no-detach-on-destroy -t $1"
        );

        assert!(!observers.reconcile(&BTreeMap::from([(socket.clone(), "$2".to_string())]), start));
        // The switch, then the marker its reply is matched against.
        wait_for("the switch", async || {
            read_or_empty(&fixture.0.join("stdin"))
                .await
                .starts_with("switch-client -E -t '$2'\ndisplay-message -p 'flash-tmux-reply-")
        })
        .await;
        wait_for("the new session", async || {
            notified.load(Ordering::SeqCst) == 3
        })
        .await;

        let pid = read_or_empty(&fixture.0.join("pid")).await;
        assert!(process_alive(&pid).await);
        assert!(observers.reconcile(&BTreeMap::new(), start));
        assert_eq!(observers.count(), 0);
        wait_for("end of input", async || {
            read_or_empty(&fixture.0.join("stdin"))
                .await
                .ends_with("eof\n")
        })
        .await;
        wait_for("the client to exit", async || !process_alive(&pid).await).await;
        assert_eq!(
            read_or_empty(&fixture.0.join("argv")).await.lines().count(),
            1,
            "a stopped observer does not reattach"
        );
        assert_eq!(
            notified.load(Ordering::SeqCst),
            3,
            "stopping is not a change"
        );
        fixture.cleanup().await;
    }

    #[tokio::test]
    async fn an_observer_that_leaves_reattaches_and_shutdown_detaches_it() {
        let fixture = ExecutableFixture::new().await;
        let dir = fixture.0.to_string_lossy().into_owned();
        // The first client leaves at once; the next one stays.
        let tmux = fixture
            .script(
                "tmux",
                &format!(
                    r#"dir={dir}
printf '%s\n' "$$" >> "$dir/pids"
printf '%%session-changed $1 main\n'
if test "$(wc -l < "$dir/pids")" -eq 1; then printf '%%exit\n'; exit 0; fi
while IFS= read -r line; do :; done
printf 'eof\n' >> "$dir/eof""#
                ),
            )
            .await;
        let mut harness = flash_plugin::testing::Harness::new("tmux");
        let ctx = harness.context();
        let notified = Arc::new(AtomicU64::new(0));
        let changed: Arc<dyn Fn() + Send + Sync> = {
            let notified = Arc::clone(&notified);
            Arc::new(move || {
                notified.fetch_add(1, Ordering::SeqCst);
            })
        };
        let observers = control_mode::ControlObservers::default();
        observers.reconcile(
            &BTreeMap::from([("/tmp/flash-test.sock".to_string(), "$1".to_string())]),
            |socket, follow, channel| {
                tokio::spawn(control_mode::observe(
                    ctx.clone(),
                    tmux.clone(),
                    socket.to_string(),
                    follow,
                    channel,
                    Arc::clone(&changed),
                ))
            },
        );
        // The client that left at once backs off before reattaching, on the
        // host's clock rather than a sleep: play the host and fire it.
        let deadline = Instant::now() + Duration::from_secs(5);
        let backoff = loop {
            if let Some(registrations) = harness.drain_poll_registrations() {
                break registrations;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for the backoff"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        assert_eq!(
            Value::Object(backoff.clone()),
            json!({ "d0": { "after": 1.0, "priority": "low" } })
        );
        drop(harness.deliver_poll_tick("d0").expect("the backoff ends"));
        wait_for("the reattach", async || {
            read_or_empty(&fixture.0.join("pids")).await.lines().count() == 2
        })
        .await;
        // Its session change, its leaving, then the reattached session change.
        wait_for("the notifications", async || {
            notified.load(Ordering::SeqCst) == 3
        })
        .await;
        observers.shutdown().await;
        assert_eq!(observers.count(), 0);
        assert_eq!(read_or_empty(&fixture.0.join("eof")).await, "eof\n");
        fixture.cleanup().await;
    }
}

// ---- Plugin glue ------------------------------------------------------------

#[derive(Clone, Default)]
struct Tmux {
    tmux_path: std::sync::Arc<tokio::sync::OnceCell<Option<String>>>,
    local_config_arc: std::sync::Arc<Mutex<LocalTmuxConfig>>,
    remote_configs_arc: std::sync::Arc<Mutex<BTreeMap<String, RemoteTmuxConfig>>>,
    /// Latest eager `list-clients` + process-tree sample. Source actions
    /// need the focused tmux client, but they should not fan out across
    /// every tmux socket on the hot key path when a refresh already did
    /// that work.
    client_snapshot_arc: std::sync::Arc<Mutex<ClientSnapshot>>,
    /// Hash of the last snapshot we emitted to the host. Shared by every
    /// refresh so the dedup invariant has one source of truth.
    last_locations_hash_arc: std::sync::Arc<Mutex<Option<u64>>>,
    candidate_partitions_arc: std::sync::Arc<Mutex<CandidatePartitions>>,
    /// Last statusbar segment values emitted through the `status`
    /// notification, so refreshes only notify on actual changes.
    last_status_segments_arc: std::sync::Arc<Mutex<Option<TmuxStatusSegments>>>,
    /// Tracks live local tmux socket inodes so refreshes never re-probe
    /// stale filesystem nodes or `/tmp` aliases.
    tmux_socket_registry_arc: std::sync::Arc<TmuxSocketRegistry>,
    /// Serializes the complete build → hash → publish cycle shared by startup,
    /// notifications, and push events. Without it, an older slow refresh
    /// can finish after a newer one and publish stale rows over the host's
    /// current catalog.
    candidate_refresh_coordinator_arc: std::sync::Arc<CandidateRefreshCoordinator>,
    /// Whether the tmux binary supports control-mode observers, asked once.
    observers_supported_cell: std::sync::Arc<tokio::sync::OnceCell<bool>>,
    /// The pending retry of a transiently failing socket.
    socket_retry_arc: std::sync::Arc<Mutex<Option<Instant>>>,
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

    fn tmux_socket_registry(&self) -> &TmuxSocketRegistry {
        &self.tmux_socket_registry_arc
    }

    fn observers(&self) -> &control_mode::ControlObservers {
        &self.tmux_socket_registry_arc.observers
    }

    /// The tmux binary path, resolved (and cached) on first use via `find_tmux()`.
    /// Runs inside the SDK's async runtime so `main` never needs its own.
    async fn resolved_tmux_path(&self) -> Option<&str> {
        self.tmux_path.get_or_init(find_tmux).await.as_deref()
    }

    async fn observers_supported(&self) -> bool {
        let Some(tmux_path) = self.resolved_tmux_path().await else {
            return false;
        };
        *self
            .observers_supported_cell
            .get_or_init(|| async move {
                let version = run_local(
                    &[tmux_path.to_string(), "-V".to_string()],
                    Duration::from_secs(2),
                )
                .await;
                version.ok && control_mode::supports_observers(&version.stdout)
            })
            .await
    }
}

flash_plugin::plugin!(Tmux);

impl FlashPlugin for Tmux {
    async fn on_start(&self, ctx: Context) {
        let local_config = local_tmux_config();
        if let Ok(mut local) = self.local_config_arc.lock() {
            *local = local_config;
        }
        let ssh_hosts = Arc::new(configured_ssh_hosts(&ctx));
        let remotes = discover_remote_tmux_configs(&ctx, &ssh_hosts).await;
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
                    "[tmux] no local tmux binary; configured ssh_hosts remain active",
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
        // last-good catalog, which survives restarts); it retries at once in
        // the background.
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
        if degraded_initial {
            let plugin = self.clone();
            let ctx = ctx.clone();
            tokio::spawn(async move { refresh_candidate_locations(&plugin, &ctx).await });
        } else if !self.observers_supported().await {
            ctx.log(
                "debug",
                "[tmux] control mode needs tmux 3.2; local refreshes follow host events only",
            );
        }
        start_socket_watch(self, &ctx);
        // Remote polling can observe nothing until a host is opted in.
        if !ssh_hosts.is_empty() {
            start_remote_candidate_poll(self, &ctx, ssh_hosts, matches!(initial, Ok(true)));
        }
    }

    /// Interaction boundaries read what tmux never notifies: working
    /// directories, commands without automatic-rename, which client was
    /// used last. Settled window retitles and creations stand in for the
    /// observer a server nobody is attached to lacks.
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            host_events::FOCUS_CHANGED
            | host_events::APPS_TERMINATED
            | host_events::SESSION_OPENED => {
                refresh_candidate_locations(self, &ctx).await;
            }
            host_events::AX_CHANGED if event.is_ax_change(&AX_REFRESH_NOTIFICATIONS) => {
                // Without observers (tmux before 3.2) nothing else notices.
                if self.observers_supported().await
                    && !self.tmux_socket_registry().attach_may_go_unnoticed().await
                {
                    return;
                }
                let plugin = self.clone();
                let refresh_ctx = ctx.clone();
                AX_BURST.schedule(&ctx, event.pid.unwrap_or_default(), move |_| async move {
                    refresh_candidate_locations(&plugin, &refresh_ctx).await;
                });
            }
            _ => {}
        }
    }

    /// Detach every observer before the process exits.
    async fn on_shutdown(&self, _ctx: Context) {
        self.observers().shutdown().await;
    }

    async fn on_hints(&self, ctx: Context, request: HintsRequest) -> HintsResponse {
        hints_for_context(self, &ctx, &request).await
    }

    async fn on_text_grid(&self, ctx: Context, request: TextGridRequest) -> TextGridResponse {
        text_grid_for_context(self, &ctx, &request).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(self, &ctx, &row).await
    }

    /// `tmux session` / `tmux window` are the plugin's own commands; every
    /// other command is a core one the manifest declares, asked in the
    /// focused terminal with its context.
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.command.as_str() {
            "tmux" => invoke_command(self, &ctx, &command).await,
            _ => perform_source_command(self, &ctx, &command).await,
        }
    }

    async fn on_navigate(&self, ctx: Context, request: NavigateRequest) -> PerformResponse {
        restore_navigation(self, &ctx, &request).await
    }
}

fn main() {
    run(Tmux::default());
}
