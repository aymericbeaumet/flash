//! Samples the process values while a status surface shows them, and only
//! then: each cadence is registered with the host's clock when its first
//! value becomes observed (`core:status.observed`) and cancelled when its
//! last one stops. A value nobody shows any more is cleared; the host keeps
//! its last figures for the surface that shows it next.
//!
//! Nothing here runs on the event worker for longer than a lock: a sample
//! may wait a window on the host's clock, whose tick the event worker
//! delivers, so every sample is its own task.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::{Context, Deadline, Event, PollHandle, PollPriority};

use crate::bundle;
use crate::format::{self, FocusedApp, Metadata, TopKind};
use crate::sys::Machine;
use crate::table::{ProcessTable, Tree};

/// The top tables' cadence: fast enough for a desktop widget, slow enough
/// that one read of the table by the host is noise.
pub(crate) const TOP_PERIOD: Duration = Duration::from_secs(2);
/// CPU use has no change event: the focused app's figures are re-read on
/// this cadence while shown.
pub(crate) const FOCUSED_PERIOD: Duration = Duration::from_secs(10);
/// A burst of focus changes (Command-Tab through several apps) reads only
/// the app the user settles on.
pub(crate) const FOCUS_SETTLE: Duration = Duration::from_millis(300);

/// One status segment of the manifest.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Value {
    /// The focused app's process tree: CPU, memory, sockets, threads,
    /// uptime, disk I/O.
    FocusedAppDetails,
    TopCpu,
    TopMemory,
}

impl Value {
    pub(crate) const ALL: [Self; 3] = [Self::FocusedAppDetails, Self::TopCpu, Self::TopMemory];

    /// The manifest `status` name.
    pub(crate) fn segment(self) -> &'static str {
        match self {
            Self::FocusedAppDetails => "focused_app_details",
            Self::TopCpu => "top_cpu",
            Self::TopMemory => "top_mem",
        }
    }

    fn from_segment(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|value| value.segment() == name)
    }

    fn top_kind(self) -> Option<TopKind> {
        match self {
            Self::TopCpu => Some(TopKind::Cpu),
            Self::TopMemory => Some(TopKind::Memory),
            Self::FocusedAppDetails => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Cadence {
    Arm,
    Disarm,
    #[default]
    Keep,
}

/// What one change of the observed set asks of the sampler.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Change {
    /// The top tables' shared cadence.
    pub(crate) top: Cadence,
    /// The focused app's cadence.
    pub(crate) focused: Cadence,
    /// A top table became observed: sample now rather than a period from
    /// now.
    pub(crate) sample_top_now: bool,
    /// `focused_app_details` became observed.
    pub(crate) sample_focused_now: bool,
    /// Values no longer observed. They clear here; the host keeps each
    /// one's last figures until it is shown again and published afresh.
    pub(crate) cleared: BTreeSet<Value>,
}

/// Which values a status surface shows: the pure state behind arming and
/// disarming the cadences.
#[derive(Debug, Default)]
pub(crate) struct Observation {
    observed: BTreeSet<Value>,
}

impl Observation {
    fn observes_top(&self) -> bool {
        self.observed.iter().any(|value| value.top_kind().is_some())
    }

    fn observes_focused(&self) -> bool {
        self.observed.contains(&Value::FocusedAppDetails)
    }

    /// Replace the observed set with the host's complete report.
    pub(crate) fn update(&mut self, next: BTreeSet<Value>) -> Change {
        let cadence = |was: bool, now: bool| match (was, now) {
            (false, true) => Cadence::Arm,
            (true, false) => Cadence::Disarm,
            _ => Cadence::Keep,
        };
        let (was_top, was_focused) = (self.observes_top(), self.observes_focused());
        let previous = std::mem::replace(&mut self.observed, next);
        Change {
            top: cadence(was_top, self.observes_top()),
            focused: cadence(was_focused, self.observes_focused()),
            sample_top_now: self
                .observed
                .iter()
                .any(|value| value.top_kind().is_some() && !previous.contains(value)),
            sample_focused_now: self.observes_focused() && !was_focused,
            cleared: previous.difference(&self.observed).copied().collect(),
        }
    }
}

/// Application metadata is read once per process identity, rather than on
/// every refresh of its figures.
#[derive(Default)]
struct MetadataCache {
    identity: Option<(FocusedApp, u64)>,
    value: Metadata,
}

#[derive(Default)]
struct State {
    observation: Observation,
    focused: Option<FocusedApp>,
    metadata: MetadataCache,
    published: BTreeMap<Value, String>,
    /// Registered on first arm and re-armed or cancelled in place after
    /// that, so toggling observation never leaks a registration.
    top_poll: Option<PollHandle>,
    focused_poll: Option<PollHandle>,
    /// The pending read after a focus change; the next change replaces it.
    settle: Option<Deadline>,
    top_failure_logged: bool,
}

pub(crate) struct Sampler {
    table: Arc<ProcessTable>,
    top_count: usize,
    state: Mutex<State>,
}

impl Sampler {
    /// `top_count`: rows per table, `[plugins.processes] top_count`.
    pub(crate) fn new(table: Arc<ProcessTable>, top_count: usize) -> Self {
        Self {
            table,
            top_count,
            state: Mutex::new(State::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn machine(&self) -> &Arc<dyn Machine> {
        self.table.machine()
    }

    /// The host's complete report of the segments a surface shows.
    pub(crate) fn observe(self: &Arc<Self>, ctx: &Context, segments: &[String]) {
        let next: BTreeSet<Value> = segments
            .iter()
            .filter_map(|segment| Value::from_segment(segment))
            .collect();
        let (change, focused) = {
            let mut state = self.lock();
            let change = state.observation.update(next);
            match change.top {
                Cadence::Arm => match &state.top_poll {
                    Some(poll) => poll.set_period(TOP_PERIOD),
                    None => {
                        let sampler = self.clone();
                        // `High`: a two-second table someone has open ticks
                        // visibly.
                        state.top_poll =
                            Some(ctx.interval(TOP_PERIOD, PollPriority::High, move |ctx| {
                                let sampler = sampler.clone();
                                async move { sampler.sample_top(&ctx).await }
                            }));
                    }
                },
                Cadence::Disarm => {
                    if let Some(poll) = &state.top_poll {
                        poll.cancel();
                    }
                }
                Cadence::Keep => {}
            }
            match change.focused {
                Cadence::Arm => match &state.focused_poll {
                    Some(poll) => poll.set_period(FOCUSED_PERIOD),
                    None => {
                        let sampler = self.clone();
                        // `Normal`: a ten-second refresh of figures on
                        // screen, where a tenth of a second of slack is
                        // invisible.
                        state.focused_poll =
                            Some(
                                ctx.interval(FOCUSED_PERIOD, PollPriority::Normal, move |ctx| {
                                    let sampler = sampler.clone();
                                    async move { sampler.sample_focused(&ctx).await }
                                }),
                            );
                    }
                },
                Cadence::Disarm => {
                    if let Some(poll) = &state.focused_poll {
                        poll.cancel();
                    }
                    if let Some(settle) = state.settle.take() {
                        settle.cancel();
                    }
                    state.metadata = MetadataCache::default();
                }
                Cadence::Keep => {}
            }
            if !change.cleared.is_empty() {
                for value in &change.cleared {
                    state.published.remove(value);
                }
                // Emitted under the lock, so no sample publishes in between.
                ctx.status(change.cleared.iter().map(|value| (value.segment(), "")));
            }
            let focused = state.focused.clone();
            if change.sample_focused_now
                && let Some(app) = &focused
            {
                Self::send(
                    &mut state,
                    ctx,
                    [(
                        Value::FocusedAppDetails,
                        format::focused_placeholder(app, format::COLLECTING),
                    )],
                );
            }
            (change, focused)
        };
        if change.sample_top_now {
            let (sampler, ctx) = (self.clone(), ctx.clone());
            tokio::spawn(async move { sampler.sample_top(&ctx).await });
        }
        if change.sample_focused_now {
            let (sampler, ctx) = (self.clone(), ctx.clone());
            tokio::spawn(async move {
                if focused.is_none() {
                    sampler.adopt_focused_app(&ctx).await;
                }
                sampler.sample_focused(&ctx).await;
            });
        }
    }

    /// No focus event has named an app yet (this process started after the
    /// app took focus): ask the host which one it is.
    async fn adopt_focused_app(&self, ctx: &Context) {
        let Some(target) = ctx.normal_mode_target().await else {
            return;
        };
        let Ok(pid) = i32::try_from(target.pid) else {
            return;
        };
        let app = FocusedApp {
            pid,
            bundle_id: target.bundle_id,
        };
        let mut state = self.lock();
        // A focus event that landed meanwhile is newer than the answer.
        if state.focused.is_some() || !state.observation.observes_focused() {
            return;
        }
        state.focused = Some(app.clone());
        Self::send(
            &mut state,
            ctx,
            [(
                Value::FocusedAppDetails,
                format::focused_placeholder(&app, format::COLLECTING),
            )],
        );
    }

    /// `core:focus.changed`. While the details are shown, the new app's
    /// placeholder shows at once and its figures are read once the focus
    /// burst settles.
    pub(crate) fn focus_changed(self: &Arc<Self>, ctx: &Context, event: &Event) {
        let app = event
            .pid
            .and_then(|pid| i32::try_from(pid).ok())
            .filter(|pid| *pid > 0)
            .map(|pid| FocusedApp {
                pid,
                bundle_id: event.bundle_id.clone().unwrap_or_default(),
            });
        let mut state = self.lock();
        if app == state.focused {
            return;
        }
        state.focused = app.clone();
        state.metadata = MetadataCache::default();
        if let Some(settle) = state.settle.take() {
            settle.cancel();
        }
        if !state.observation.observes_focused() {
            return;
        }
        let Some(app) = app else {
            state.published.remove(&Value::FocusedAppDetails);
            ctx.status([(Value::FocusedAppDetails.segment(), "")]);
            return;
        };
        Self::send(
            &mut state,
            ctx,
            [(
                Value::FocusedAppDetails,
                format::focused_placeholder(&app, format::COLLECTING),
            )],
        );
        let sampler = self.clone();
        // `High`: the placeholder on screen is waiting for it.
        state.settle = Some(
            ctx.after(FOCUS_SETTLE, PollPriority::High, move |ctx| async move {
                sampler.sample_focused(&ctx).await;
            }),
        );
    }

    /// One table read, every observed table published if it changed. A tick
    /// that raced a disarm finds nothing observed and does not read; a
    /// failed read keeps the last tables.
    pub(crate) async fn sample_top(&self, ctx: &Context) {
        if !self.lock().observation.observes_top() {
            return;
        }
        let processes = self.table.processes(ctx).await;
        let mut state = self.lock();
        if processes.is_empty() {
            if !std::mem::replace(&mut state.top_failure_logged, true) {
                ctx.log(
                    "warn",
                    "[processes] top sample failed; keeping the last tables",
                );
            }
            return;
        }
        state.top_failure_logged = false;
        let tables: Vec<(Value, String)> = Value::ALL
            .into_iter()
            .filter_map(|value| {
                let kind = value.top_kind()?;
                Some((value, format::top_table(kind, &processes, self.top_count)))
            })
            .collect();
        Self::send(&mut state, ctx, tables);
    }

    /// The focused app's figures, or its placeholder when they cannot be
    /// read.
    pub(crate) async fn sample_focused(&self, ctx: &Context) {
        let app = {
            let state = self.lock();
            if !state.observation.observes_focused() {
                return;
            }
            match &state.focused {
                Some(app) => app.clone(),
                None => return,
            }
        };
        let Some(tree) = self.table.tree(ctx, app.pid).await else {
            let mut state = self.lock();
            if state.focused.as_ref() != Some(&app) {
                return;
            }
            state.metadata = MetadataCache::default();
            Self::send(
                &mut state,
                ctx,
                [(
                    Value::FocusedAppDetails,
                    format::focused_placeholder(&app, format::UNAVAILABLE),
                )],
            );
            return;
        };
        let metadata = self.metadata(ctx, &app, &tree).await;
        let text =
            format::focused_details(&app, &tree, &metadata, self.machine().physical_memory());
        let mut state = self.lock();
        // The focus moved while this app was read: its figures are not the
        // focused app's any more.
        if state.focused.as_ref() != Some(&app) {
            return;
        }
        Self::send(&mut state, ctx, [(Value::FocusedAppDetails, text)]);
    }

    /// The app's name, version and paths, read once for this process
    /// identity: its start time is part of it, so a reused pid cannot
    /// inherit another app's metadata.
    async fn metadata(&self, ctx: &Context, app: &FocusedApp, tree: &Tree) -> Metadata {
        let identity = (app.clone(), tree.start_abstime);
        {
            let state = self.lock();
            if state.metadata.identity.as_ref() == Some(&identity) {
                return state.metadata.value.clone();
            }
        }
        let value = self.read_metadata(ctx, app, tree).await;
        let mut state = self.lock();
        if state.focused.as_ref() == Some(app) {
            state.metadata = MetadataCache {
                identity: Some(identity),
                value: value.clone(),
            };
        }
        value
    }

    async fn read_metadata(&self, ctx: &Context, app: &FocusedApp, tree: &Tree) -> Metadata {
        let bundle_path = bundle::bundle_path(&tree.executable_path)
            .unwrap_or_default()
            .to_string();
        let info = if bundle_path.is_empty() {
            bundle::BundleInfo::default()
        } else {
            // A file read: off the plugin's one executor thread.
            let (machine, path) = (self.machine().clone(), bundle_path.clone());
            tokio::task::spawn_blocking(move || machine.bundle_info(&path))
                .await
                .unwrap_or_default()
        };
        // Another app's bundle at this pid's path names nothing of this one.
        if !app.bundle_id.is_empty()
            && !info.identifier.is_empty()
            && info.identifier != app.bundle_id
        {
            return Metadata::default();
        }
        let name = ctx
            .running_applications()
            .into_iter()
            .find(|running| {
                running.pid == i64::from(app.pid)
                    && (app.bundle_id.is_empty() || running.bundle_id == app.bundle_id)
            })
            .map(|running| running.localized_name)
            .unwrap_or_default();
        Metadata {
            name,
            version: info.version_label(),
            bundle_path,
            executable_path: tree.executable_path.clone(),
        }
    }

    /// Publish what changed among values still observed.
    fn send(state: &mut State, ctx: &Context, values: impl IntoIterator<Item = (Value, String)>) {
        let changed: Vec<(Value, String)> = values
            .into_iter()
            .filter(|(value, text)| {
                state.observation.observed.contains(value)
                    && state.published.get(value) != Some(text)
            })
            .collect();
        if changed.is_empty() {
            return;
        }
        for (value, text) in &changed {
            state.published.insert(*value, text.clone());
        }
        ctx.status(
            changed
                .into_iter()
                .map(|(value, text)| (value.segment(), text)),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundle::BundleInfo;
    use crate::table::testing::FakeMachine;
    use crate::testing::{Host, cadences, deadlines, segments, statuses};
    use flash_plugin::RunningApplication;
    use serde_json::json;

    const MIB: u64 = 1 << 20;

    /// launchd, Firefox with one helper, and Xcode, on a Mac with 1 GiB.
    fn machine() -> Arc<FakeMachine> {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(1, 0, "/sbin/launchd", 1);
        machine.spawn(
            20,
            1,
            "/Applications/Firefox.app/Contents/MacOS/firefox",
            200,
        );
        machine.spawn(
            21,
            20,
            "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
            210,
        );
        machine.spawn(30, 1, "/Applications/Xcode.app/Contents/MacOS/Xcode", 300);
        machine.update(20, |process| {
            process.usage.resident_bytes = 8 * MIB;
            process.threads = 4;
            process.sockets = 3;
            process.uptime_seconds = 3_600;
        });
        machine.update(21, |process| process.usage.resident_bytes = MIB);
        machine.update(30, |process| process.usage.resident_bytes = 20 * MIB);
        machine.bundles.lock().unwrap().insert(
            "/Applications/Firefox.app".into(),
            BundleInfo {
                identifier: "org.mozilla.firefox".into(),
                version: "140.0".into(),
                build: "14025.1".into(),
            },
        );
        machine
    }

    fn sampler(machine: &Arc<FakeMachine>, top_count: usize) -> Arc<Sampler> {
        Arc::new(Sampler::new(
            Arc::new(ProcessTable::new(machine.clone())),
            top_count,
        ))
    }

    fn focus(pid: i64, bundle_id: &str) -> Event {
        Event {
            name: "core:focus.changed".into(),
            bundle_id: Some(bundle_id.into()),
            pid: Some(pid),
            ..Event::default()
        }
    }

    fn set(values: &[Value]) -> BTreeSet<Value> {
        values.iter().copied().collect()
    }

    #[test]
    fn the_segments_are_the_manifests() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let names: Vec<&str> = Value::ALL.iter().map(|value| value.segment()).collect();
        assert_eq!(manifest["status"], json!(names));
        for value in Value::ALL {
            assert_eq!(Value::from_segment(value.segment()), Some(value));
        }
        assert_eq!(Value::from_segment("state"), None);
    }

    #[test]
    fn cadences_arm_only_while_their_values_are_observed() {
        use Value::{FocusedAppDetails, TopCpu, TopMemory};
        let mut observation = Observation::default();
        assert_eq!(
            observation.update(set(&[FocusedAppDetails])),
            Change {
                focused: Cadence::Arm,
                sample_focused_now: true,
                ..Change::default()
            }
        );
        assert_eq!(
            observation.update(set(&[FocusedAppDetails, TopCpu])),
            Change {
                top: Cadence::Arm,
                sample_top_now: true,
                ..Change::default()
            }
        );
        assert_eq!(
            observation.update(set(&[TopCpu, FocusedAppDetails])),
            Change::default()
        );
        // A second table keeps the cadence and is sampled at once.
        assert_eq!(
            observation.update(set(&[TopCpu, TopMemory])),
            Change {
                focused: Cadence::Disarm,
                sample_top_now: true,
                cleared: set(&[FocusedAppDetails]),
                ..Change::default()
            }
        );
        assert_eq!(
            observation.update(set(&[TopMemory])),
            Change {
                cleared: set(&[TopCpu]),
                ..Change::default()
            }
        );
        assert_eq!(
            observation.update(set(&[])),
            Change {
                top: Cadence::Disarm,
                cleared: set(&[TopMemory]),
                ..Change::default()
            }
        );
        assert_eq!(observation.update(set(&[])), Change::default());
        assert_eq!(observation.update(set(&[TopMemory])).top, Cadence::Arm);
    }

    #[tokio::test]
    async fn the_top_tables_sample_only_while_observed_and_publish_what_changed() {
        let machine = machine();
        let sampler = sampler(&machine, 2);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();

        // Unobserved: nothing registers, reads or publishes.
        sampler.sample_top(&ctx).await;
        assert_eq!(host.settle().await, Vec::<serde_json::Value>::new());

        // The first observed table registers the cadence and samples at
        // once, through one bracket; only that table publishes.
        sampler.observe(&ctx, &segments(&["top_cpu"]));
        let frames = host.settle().await;
        assert_eq!(
            cadences(&frames),
            [json!({ "i0": { "every": 2.0, "priority": "high" } })]
        );
        assert_eq!(
            deadlines(&frames),
            [json!({ "after": 0.15, "priority": "high" })]
        );
        assert_eq!(
            statuses(&frames),
            [json!({ "top_cpu": "Xcode              0.0%\nfirefox            0.0%" })]
        );

        // The cadence's tick: an unchanged table stays off the wire, and
        // known pids need no bracket.
        assert_eq!(host.tick("i0").await, Vec::<serde_json::Value>::new());

        // A second table is sampled at once and published alone.
        sampler.observe(&ctx, &segments(&["top_cpu", "top_mem"]));
        let frames = host.settle().await;
        assert_eq!(
            statuses(&frames),
            [json!({ "top_mem": "Xcode              20 MiB\nfirefox           8.0 MiB" })]
        );
        assert_eq!(cadences(&frames), Vec::<serde_json::Value>::new());

        // A table nobody shows any more clears; the cadence stays for the
        // other one.
        sampler.observe(&ctx, &segments(&["top_mem"]));
        let frames = host.settle().await;
        assert_eq!(statuses(&frames), [json!({ "top_cpu": "" })]);
        assert_eq!(cadences(&frames), Vec::<serde_json::Value>::new());
        machine.update(1, |process| process.usage.resident_bytes = 64 * MIB);
        assert_eq!(
            statuses(&host.tick("i0").await),
            [json!({ "top_mem": "launchd            64 MiB\nXcode              20 MiB" })]
        );

        // The last one gone: the cadence is cancelled, the table cleared,
        // and a tick that raced the change reads nothing.
        sampler.observe(&ctx, &segments(&["focused_app_details"]));
        let frames = host.settle().await;
        assert_eq!(statuses(&frames), [json!({ "top_mem": "" })]);
        assert!(
            !cadences(&frames)
                .last()
                .unwrap()
                .as_object()
                .unwrap()
                .contains_key("i0"),
            "{frames:?}"
        );
        sampler.sample_top(&ctx).await;
        assert_eq!(
            statuses(&host.settle().await),
            Vec::<serde_json::Value>::new()
        );

        // Observed again: the same registration re-arms.
        sampler.observe(&ctx, &segments(&["top_mem"]));
        let frames = host.settle().await;
        assert_eq!(
            cadences(&frames).last(),
            Some(&json!({ "i0": { "every": 2.0, "priority": "high" } }))
        );
        assert_eq!(
            statuses(&frames),
            [
                json!({ "focused_app_details": "" }),
                json!({ "top_mem": "launchd            64 MiB\nXcode              20 MiB" })
            ]
        );
    }

    #[tokio::test]
    async fn a_failed_table_read_keeps_the_last_tables_and_warns_once() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        let sampler = sampler(&machine, 5);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();
        sampler.observe(&ctx, &segments(&["top_cpu"]));
        let mut frames = host.settle().await;
        frames.extend(host.tick("i0").await);
        frames.extend(host.tick("i0").await);
        assert_eq!(statuses(&frames), Vec::<serde_json::Value>::new());
        let warnings: Vec<&serde_json::Value> = frames
            .iter()
            .filter(|frame| frame["method"] == "log")
            .collect();
        assert_eq!(warnings.len(), 1, "{frames:?}");
        assert_eq!(
            warnings[0]["params"]["message"],
            "[processes] top sample failed; keeping the last tables"
        );
    }

    const FIREFOX: &str = "#[bold]Firefox#[nobold]\n\
        Version       140.0 (14025.1)\n\
        Bundle        org.mozilla.firefox\n\
        PID           20\n\
        \n\
        #[bold]Resources · app + descendants#[nobold]\n\
        CPU           0.0% · 100% = 1 core\n\
        Memory        9.0 MiB (0.9% of RAM)\n\
        Processes     2 · 5 threads\n\
        Sockets       3\n\
        Running       1h 0m · main process\n\
        Disk read     0 B cumulative\n\
        Disk written  0 B cumulative\n\
        \n\
        #[bold]Busiest helpers · 1 of 1#[nobold]\n\
        Process                     PID      CPU     Memory\n\
        plugin-container             21     0.0%    1.0 MiB\n\
        \n\
        #[bold]Application#[nobold]\n\
        Bundle path   /Applications/Firefox.app\n\
        Executable    /Applications/Firefox.app/Contents/MacOS/firefox";

    #[tokio::test]
    async fn the_focused_app_is_read_only_while_its_details_are_observed() {
        let machine = machine();
        let sampler = sampler(&machine, 5);
        let mut host = Host::new(json!({}), &machine);
        host.harness
            .set_running_applications(vec![RunningApplication {
                bundle_id: "org.mozilla.firefox".into(),
                pid: 20,
                localized_name: "Firefox".into(),
            }]);
        let ctx = host.harness.context();

        // Unobserved: the focus is tracked, and nothing else happens.
        sampler.focus_changed(&ctx, &focus(20, "org.mozilla.firefox"));
        sampler.observe(&ctx, &segments(&["top_cpu"]));
        sampler.observe(&ctx, &segments(&[]));
        sampler.sample_focused(&ctx).await;
        let frames = host.settle().await;
        assert!(
            statuses(&frames)
                .iter()
                .all(|status| status.get("focused_app_details").is_none()),
            "{frames:?}"
        );

        // Observed: the cadence registers, the tracked app's placeholder
        // shows at once and its figures follow.
        sampler.observe(&ctx, &segments(&["focused_app_details"]));
        let frames = host.settle().await;
        assert_eq!(
            cadences(&frames).last(),
            Some(&json!({ "i1": { "every": 10.0, "priority": "normal" } }))
        );
        assert_eq!(
            statuses(&frames),
            [
                json!({ "focused_app_details":
                    "Bundle        org.mozilla.firefox\nPID           20\nCollecting metrics…" }),
                json!({ "focused_app_details": FIREFOX }),
            ]
        );
        assert_eq!(*machine.bundle_reads.lock().unwrap(), 1);

        // Its cadence re-reads the figures, not the application metadata.
        machine.update(20, |process| process.sockets = 4);
        let frames = host.tick("i1").await;
        assert_eq!(
            statuses(&frames),
            [
                json!({ "focused_app_details": FIREFOX.replace("Sockets       3", "Sockets       4") })
            ]
        );
        assert_eq!(
            *machine.bundle_reads.lock().unwrap(),
            1,
            "one read per identity"
        );
        assert_eq!(host.tick("i1").await, Vec::<serde_json::Value>::new());

        // A burst of focus changes shows each placeholder and reads only
        // the app it settles on, once the settle deadline lands.
        sampler.focus_changed(&ctx, &focus(1, "com.example.Passing"));
        sampler.focus_changed(&ctx, &focus(30, "com.apple.dt.Xcode"));
        let frames = host.settle().await;
        assert_eq!(
            deadlines(&frames)[..2],
            [
                json!({ "after": 0.3, "priority": "high" }),
                json!({ "after": 0.3, "priority": "high" })
            ]
        );
        let published = statuses(&frames);
        assert_eq!(
            published[..2],
            [
                json!({ "focused_app_details":
                    "Bundle        com.example.Passing\nPID           1\nCollecting metrics…" }),
                json!({ "focused_app_details":
                    "Bundle        com.apple.dt.Xcode\nPID           30\nCollecting metrics…" }),
            ]
        );
        assert_eq!(published.len(), 3, "{published:?}");
        let xcode = published[2]["focused_app_details"].as_str().unwrap();
        assert!(xcode.starts_with("#[bold]Xcode#[nobold]\nBundle        com.apple.dt.Xcode\n"));
        assert!(xcode.contains("Memory        20 MiB (2.0% of RAM)"));
        assert!(!xcode.contains("Busiest helpers"), "{xcode}");
        assert!(xcode.ends_with(
            "Bundle path   /Applications/Xcode.app\n\
             Executable    /Applications/Xcode.app/Contents/MacOS/Xcode"
        ));

        // The app is gone: its identity over the reason, never old figures.
        machine.exit(30);
        assert_eq!(
            statuses(&host.tick("i1").await),
            [json!({ "focused_app_details":
                "Bundle        com.apple.dt.Xcode\nPID           30\nMetrics unavailable" })]
        );

        // No app focused: the value clears.
        sampler.focus_changed(&ctx, &Event::default());
        assert_eq!(
            statuses(&host.settle().await),
            [json!({ "focused_app_details": "" })]
        );

        // No longer observed: the cadence is cancelled and a focus change
        // publishes nothing.
        sampler.focus_changed(&ctx, &focus(20, "org.mozilla.firefox"));
        host.settle().await;
        sampler.observe(&ctx, &segments(&[]));
        let frames = host.settle().await;
        assert_eq!(statuses(&frames), [json!({ "focused_app_details": "" })]);
        assert_eq!(cadences(&frames).last(), Some(&json!({})));
        sampler.focus_changed(&ctx, &focus(30, "com.apple.dt.Xcode"));
        sampler.sample_focused(&ctx).await;
        assert_eq!(host.settle().await, Vec::<serde_json::Value>::new());
    }

    /// A process started after the app took focus has heard no focus event:
    /// it asks the host which app is focused.
    #[tokio::test]
    async fn the_focused_app_is_asked_of_the_host_when_no_event_named_it() {
        let machine = machine();
        let sampler = sampler(&machine, 5);
        let mut host = Host::new(json!({}), &machine);
        host.target = json!({
            "ok": true, "present": true, "pid": 30, "bundle_id": "com.apple.dt.Xcode",
            "window_id": 7
        });
        let ctx = host.harness.context();
        sampler.observe(&ctx, &segments(&["focused_app_details"]));
        let frames = host.settle().await;
        assert_eq!(
            host.calls,
            [("host.normal_mode_target".to_string(), json!({}))]
        );
        let published = statuses(&frames);
        assert_eq!(
            published[0],
            json!({ "focused_app_details":
                "Bundle        com.apple.dt.Xcode\nPID           30\nCollecting metrics…" })
        );
        assert!(
            published[1]["focused_app_details"]
                .as_str()
                .unwrap()
                .starts_with("#[bold]Xcode#[nobold]"),
            "{published:?}"
        );

        // With no app at all, nothing is published and nothing is read.
        let sampler = self::sampler(&machine, 5);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();
        sampler.observe(&ctx, &segments(&["focused_app_details"]));
        assert_eq!(
            statuses(&host.settle().await),
            Vec::<serde_json::Value>::new()
        );
    }

    /// A bundle that names another app says nothing about this process.
    #[tokio::test]
    async fn metadata_of_another_app_is_not_shown() {
        let machine = machine();
        let sampler = sampler(&machine, 5);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();
        sampler.focus_changed(&ctx, &focus(20, "com.example.Imposter"));
        sampler.observe(&ctx, &segments(&["focused_app_details"]));
        let published = statuses(&host.settle().await);
        let details = published[1]["focused_app_details"].as_str().unwrap();
        assert!(
            details.starts_with("#[bold]firefox#[nobold]\nBundle        com.example.Imposter\n"),
            "{details}"
        );
        assert!(!details.contains("Version"), "{details}");
        assert!(!details.contains("Application"), "{details}");
    }
}
