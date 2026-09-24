//! The `top_cpu` and `top_mem` status segments: aligned tables of the busiest
//! processes by CPU and by resident memory, conky's `${top …}` for Flash's
//! status surfaces.
//!
//! Sampling is scoped to observation. The host reports which of this
//! plugin's segments a status surface currently shows
//! (`core:status.observed`), and the top-N cadence is registered with the host
//! only while `top_cpu` or `top_mem` is among them; the plugin itself stays
//! resident for its catalog, but nothing samples for a table nobody shows.
//!
//! Rows come from `host.process_table`, the plugin's one process model. The
//! host reports each pid's CPU as the delta of its cumulative CPU time since
//! the previous table read (a pid seen for the first time is bracketed by two
//! reads `SAMPLE_WINDOW_MS` apart), so on this cadence every figure is the
//! average over the last period rather than a lifetime mean. It is a share of
//! one core, as `top` and Activity Monitor report it. Memory is the resident
//! set: the table's `mem_percent` is resident bytes over physical memory.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use flash_plugin::status::bytes_iec;
use flash_plugin::{Column, Context, Markup, PollHandle, Preview, RefreshGate, Table};
use serde_json::Value;
use tokio::task::JoinHandle;

/// Cadence of the top-N sample while a table is observed: fast enough for a
/// desktop widget, slow enough that one libproc pass is noise.
pub(crate) const TOP_POLL: Duration = Duration::from_secs(2);
/// Bracket for a pid the host has not sampled before, as the catalog uses.
const SAMPLE_WINDOW_MS: u64 = 150;
pub(crate) const TOP_COUNT_DEFAULT: usize = 5;
pub(crate) const TOP_COUNT_MAX: usize = 20;
const TOP_COUNT_SETTING: &str = "top_count";
/// Visible width of the name column, conky's `top_name_width` default.
const NAME_WIDTH: usize = 15;

/// One of the two tables, named by its manifest status segment.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum TopKind {
    Cpu,
    Memory,
}

impl TopKind {
    const ALL: [Self; 2] = [Self::Cpu, Self::Memory];

    pub(crate) fn segment(self) -> &'static str {
        match self {
            Self::Cpu => "top_cpu",
            Self::Memory => "top_mem",
        }
    }

    fn from_segment(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.segment() == name)
    }

    /// Busiest first; ties break by name, then pid, so equal figures never
    /// shuffle rows between samples.
    fn rank(self, left: &TopProcess, right: &TopProcess) -> Ordering {
        let by_value = match self {
            Self::Cpu => right.cpu_percent.total_cmp(&left.cpu_percent),
            Self::Memory => right.resident_bytes.cmp(&left.resident_bytes),
        };
        by_value
            .then_with(|| left.name.cmp(&right.name))
            .then_with(|| left.pid.cmp(&right.pid))
    }

    fn value(self, process: &TopProcess) -> String {
        match self {
            Self::Cpu => format!("{:.1}%", process.cpu_percent.max(0.0)),
            Self::Memory => bytes_iec(process.resident_bytes),
        }
    }

    /// The widest value in ordinary use (`100.0%`, `1023 MiB`), so the value
    /// column only widens for an outlier.
    fn value_width(self) -> usize {
        match self {
            Self::Cpu => 6,
            Self::Memory => 8,
        }
    }
}

// ---------------------------------------------------------------------------
// Observation
// ---------------------------------------------------------------------------

/// What the top-N cadence does after the observed set changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Cadence {
    Arm,
    Disarm,
    Keep,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ObservationChange {
    pub(crate) cadence: Cadence,
    /// A table became observed: sample now instead of a period from now.
    pub(crate) sample_now: bool,
    /// Tables no longer observed. They clear rather than going stale, since
    /// a surface that shows them again must not read old figures.
    pub(crate) cleared: Vec<TopKind>,
}

/// Which top tables a status surface shows — the pure state machine behind
/// arming and disarming the cadence.
#[derive(Debug, Default)]
pub(crate) struct Observation {
    observed: BTreeSet<TopKind>,
}

impl Observation {
    /// Replace the observed set with the host's complete report. Segments
    /// other than the top tables do not concern the cadence.
    pub(crate) fn update<'a>(
        &mut self,
        segments: impl IntoIterator<Item = &'a str>,
    ) -> ObservationChange {
        let next: BTreeSet<TopKind> = segments
            .into_iter()
            .filter_map(TopKind::from_segment)
            .collect();
        let cadence = match (self.observed.is_empty(), next.is_empty()) {
            (true, false) => Cadence::Arm,
            (false, true) => Cadence::Disarm,
            _ => Cadence::Keep,
        };
        let change = ObservationChange {
            cadence,
            sample_now: next.difference(&self.observed).next().is_some(),
            cleared: self.observed.difference(&next).copied().collect(),
        };
        self.observed = next;
        change
    }

    pub(crate) fn contains(&self, kind: TopKind) -> bool {
        self.observed.contains(&kind)
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.observed.is_empty()
    }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// `[plugin.processes] top_count`: rows per table, an integer in 1..=20,
/// default 5. `None` for an invalid value.
pub(crate) fn parse_top_count(value: Option<&Value>) -> Option<usize> {
    let Some(value) = value else {
        return Some(TOP_COUNT_DEFAULT);
    };
    value
        .as_u64()
        .filter(|count| (1..=TOP_COUNT_MAX as u64).contains(count))
        .map(|count| count as usize)
}

fn configured_top_count(ctx: &Context) -> usize {
    parse_top_count(ctx.config_json::<Value>(TOP_COUNT_SETTING).as_ref())
        .unwrap_or(TOP_COUNT_DEFAULT)
}

pub(crate) fn warn_invalid_top_count(ctx: &Context) {
    if parse_top_count(ctx.config_json::<Value>(TOP_COUNT_SETTING).as_ref()).is_none() {
        ctx.log(
            "warn",
            "[processes] top_count must be an integer in 1..20; using 5",
        );
    }
}

// ---------------------------------------------------------------------------
// Rows and tables
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct TopProcess {
    pub(crate) pid: i64,
    pub(crate) name: String,
    pub(crate) cpu_percent: f64,
    pub(crate) resident_bytes: u64,
}

/// Rows of a `host.process_table` reply. The full table carries resident
/// memory as `mem_percent` of physical memory, so the bytes are recovered
/// from `physical_memory`; malformed rows are skipped.
pub(crate) fn parse_processes(response: &Value, physical_memory: u64) -> Vec<TopProcess> {
    let Some(rows) = response.get("processes").and_then(Value::as_array) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| {
            let mem_percent = row.get("mem_percent")?.as_f64()?;
            Some(TopProcess {
                pid: row.get("pid")?.as_i64()?,
                name: row.get("comm")?.as_str()?.to_string(),
                cpu_percent: row.get("cpu_percent")?.as_f64()?,
                resident_bytes: (mem_percent.max(0.0) / 100.0 * physical_memory as f64).round()
                    as u64,
            })
        })
        .collect()
}

/// A process name as one table cell: control characters cannot break a row,
/// a name wider than the column ends in an ellipsis, and a nameless process
/// shows its pid.
fn cell_name(process: &TopProcess) -> String {
    let name: String = process
        .name
        .trim()
        .chars()
        .map(|character| {
            if character.is_control() {
                '?'
            } else {
                character
            }
        })
        .collect();
    if name.is_empty() {
        return format!("[{}]", process.pid);
    }
    if name.chars().count() <= NAME_WIDTH {
        return name;
    }
    let mut truncated: String = name.chars().take(NAME_WIDTH - 1).collect();
    truncated.push('…');
    truncated
}

/// The `count` busiest processes as an aligned two-column table: the name
/// padded to a fixed width, the value right-aligned. Plain text — the
/// surrounding template owns colour. Empty when there are no processes.
pub(crate) fn top_table(kind: TopKind, processes: &[TopProcess], count: usize) -> String {
    let mut ranked: Vec<&TopProcess> = processes.iter().collect();
    ranked.sort_by(|left, right| kind.rank(left, right));
    ranked.truncate(count.clamp(1, TOP_COUNT_MAX));
    if ranked.is_empty() {
        return String::new();
    }
    let values: Vec<String> = ranked.iter().map(|process| kind.value(process)).collect();
    let value_width = values
        .iter()
        .map(|value| value.chars().count())
        .fold(kind.value_width(), usize::max);
    let table = ranked.iter().zip(values).fold(
        Table::new([
            Column::new("", NAME_WIDTH),
            Column::new("", value_width).right(),
        ]),
        |table, (process, value)| {
            table.row([Markup::text(cell_name(process)), Markup::text(value)])
        },
    );
    Preview::new().table(table).render().into_string()
}

/// Physical memory, read once: it does not change while the process runs.
fn physical_memory() -> Option<u64> {
    static TOTAL: OnceLock<u64> = OnceLock::new();
    if let Some(total) = TOTAL.get() {
        return Some(*total);
    }
    let total = flash_plugin::sys::memory_stats().ok()?.total_bytes;
    (total > 0).then(|| *TOTAL.get_or_init(|| total))
}

// ---------------------------------------------------------------------------
// Sampler
// ---------------------------------------------------------------------------

#[derive(Default)]
struct SamplerState {
    observation: Observation,
    /// Registered on first arm and re-armed or cancelled in place after
    /// that, so toggling observation never leaks a registration.
    poll: Option<PollHandle>,
    published: BTreeMap<TopKind, String>,
    failure_logged: bool,
}

/// Owns the top tables: the observed set, the cadence registered while any
/// table is observed, and the last published tables.
#[derive(Default)]
pub(crate) struct TopSampler {
    state: Mutex<SamplerState>,
    gate: RefreshGate,
}

impl TopSampler {
    fn lock(&self) -> MutexGuard<'_, SamplerState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Apply the host's observed segment set. The cadence is armed only
    /// while `top_cpu` or `top_mem` is observed and cancelled as soon as
    /// neither is; a table that stops being observed is cleared. Returns the
    /// immediate sample for a table that just became observed.
    pub(crate) fn observe(
        &'static self,
        ctx: &Context,
        segments: &[String],
    ) -> Option<JoinHandle<()>> {
        let sample_now = {
            let mut state = self.lock();
            let change = state
                .observation
                .update(segments.iter().map(String::as_str));
            match (change.cadence, &state.poll) {
                (Cadence::Arm, Some(poll)) => poll.set_period(TOP_POLL),
                (Cadence::Arm, None) => {
                    state.poll = Some(ctx.interval(TOP_POLL, move |ctx| async move {
                        self.refresh(&ctx).await;
                    }));
                }
                (Cadence::Disarm, Some(poll)) => poll.cancel(),
                (Cadence::Disarm, None) | (Cadence::Keep, _) => {}
            }
            for kind in &change.cleared {
                state.published.remove(kind);
            }
            // Emitted under the lock, so no sample can publish in between.
            if !change.cleared.is_empty() {
                ctx.status(change.cleared.iter().map(|kind| (kind.segment(), "")));
            }
            change.sample_now
        };
        sample_now.then(|| {
            let ctx = ctx.clone();
            tokio::spawn(async move { self.refresh(&ctx).await })
        })
    }

    /// Sample the process table and publish every observed table that
    /// changed. A tick that raced a disarm finds nothing observed and does
    /// not sample; a failed read keeps the last tables.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        self.gate
            .run(ctx, |ctx, _applications| async move {
                if self.lock().observation.is_empty() {
                    return;
                }
                let response = ctx.process_table(Some(SAMPLE_WINDOW_MS)).await;
                let processes = physical_memory()
                    .map(|total| parse_processes(&response, total))
                    .unwrap_or_default();
                if processes.is_empty() {
                    let mut state = self.lock();
                    if !std::mem::replace(&mut state.failure_logged, true) {
                        ctx.log(
                            "warn",
                            "[processes] top sample failed; keeping the last tables",
                        );
                    }
                    return;
                }
                let count = configured_top_count(&ctx);
                let mut state = self.lock();
                state.failure_logged = false;
                let mut changed = Vec::new();
                for kind in TopKind::ALL {
                    // Checked again after the read: observation may have
                    // changed while the table was sampled.
                    if !state.observation.contains(kind) {
                        continue;
                    }
                    let table = top_table(kind, &processes, count);
                    if state.published.get(&kind) != Some(&table) {
                        state.published.insert(kind, table.clone());
                        changed.push((kind.segment(), table));
                    }
                }
                if !changed.is_empty() {
                    ctx.status(changed);
                }
            })
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::json;

    fn process(pid: i64, name: &str, cpu_percent: f64, resident_bytes: u64) -> TopProcess {
        TopProcess {
            pid,
            name: name.into(),
            cpu_percent,
            resident_bytes,
        }
    }

    fn segments(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn top_count_defaults_to_five_and_rejects_values_outside_one_to_twenty() {
        assert_eq!(parse_top_count(None), Some(5));
        assert_eq!(parse_top_count(Some(&json!(1))), Some(1));
        assert_eq!(parse_top_count(Some(&json!(12))), Some(12));
        assert_eq!(parse_top_count(Some(&json!(20))), Some(20));
        for invalid in [
            json!(0),
            json!(21),
            json!(-3),
            json!(5.0),
            json!(2.5),
            json!("5"),
            json!(true),
            json!(null),
        ] {
            assert_eq!(parse_top_count(Some(&invalid)), None, "{invalid}");
        }
    }

    #[test]
    fn an_invalid_top_count_warns_and_falls_back_to_the_default() {
        let mut harness = Harness::with_config("processes", json!({ "top_count": 0 }));
        let ctx = harness.context();
        warn_invalid_top_count(&ctx);
        assert_eq!(configured_top_count(&ctx), TOP_COUNT_DEFAULT);
        let frames = harness.drain();
        assert_eq!(frames.len(), 1, "{frames:?}");
        assert_eq!(
            frames[0]["params"]["message"],
            "[processes] top_count must be an integer in 1..20; using 5"
        );

        let mut harness = Harness::with_config("processes", json!({ "top_count": 3 }));
        let ctx = harness.context();
        warn_invalid_top_count(&ctx);
        assert_eq!(configured_top_count(&ctx), 3);
        assert!(harness.drain().is_empty());
    }

    #[test]
    fn the_cadence_arms_only_while_a_top_table_is_observed() {
        let mut observation = Observation::default();
        let mut update = |names: &[&str]| observation.update(names.iter().copied());

        // Unrelated segments never arm it.
        assert_eq!(
            update(&["focused_app_details"]),
            ObservationChange {
                cadence: Cadence::Keep,
                sample_now: false,
                cleared: vec![],
            }
        );
        // The first observed table arms it and samples at once.
        assert_eq!(
            update(&["focused_app_details", "top_cpu"]),
            ObservationChange {
                cadence: Cadence::Arm,
                sample_now: true,
                cleared: vec![],
            }
        );
        // The same set again changes nothing.
        assert_eq!(
            update(&["top_cpu", "focused_app_details"]),
            ObservationChange {
                cadence: Cadence::Keep,
                sample_now: false,
                cleared: vec![],
            }
        );
        // A second table keeps the cadence but is sampled at once.
        assert_eq!(
            update(&["top_cpu", "top_mem"]),
            ObservationChange {
                cadence: Cadence::Keep,
                sample_now: true,
                cleared: vec![],
            }
        );
        // Losing one table clears it and keeps the cadence for the other.
        assert_eq!(
            update(&["top_mem"]),
            ObservationChange {
                cadence: Cadence::Keep,
                sample_now: false,
                cleared: vec![TopKind::Cpu],
            }
        );
        // Losing the last one disarms and clears it.
        assert_eq!(
            update(&["focused_app_details"]),
            ObservationChange {
                cadence: Cadence::Disarm,
                sample_now: false,
                cleared: vec![TopKind::Memory],
            }
        );
        // An empty set is authoritative and changes nothing further.
        assert_eq!(
            update(&[]),
            ObservationChange {
                cadence: Cadence::Keep,
                sample_now: false,
                cleared: vec![],
            }
        );
        // Re-observing arms again.
        assert_eq!(update(&["top_mem"]).cadence, Cadence::Arm);
        assert!(observation.contains(TopKind::Memory));
        assert!(!observation.contains(TopKind::Cpu));
    }

    #[test]
    fn the_cpu_table_aligns_values_and_truncates_long_names() {
        let processes = [
            process(10, "WindowServer", 12.34, 0),
            process(11, "a-very-long-process-name", 3.0, 0),
            process(12, "kernel_task", 142.0, 0),
            process(13, "idle", 0.0, 0),
        ];
        assert_eq!(
            top_table(TopKind::Cpu, &processes, 3),
            "kernel_task      142.0%\n\
             WindowServer      12.3%\n\
             a-very-long-pr…    3.0%"
        );
    }

    #[test]
    fn the_memory_table_ranks_resident_bytes_and_breaks_ties_by_name() {
        let processes = [
            process(1, "beta", 0.0, 921_600),
            process(2, "Xcode", 0.0, 432_013_312),
            process(3, "firefox", 0.0, 1_610_612_736),
            process(4, "alpha", 0.0, 921_600),
        ];
        assert_eq!(
            top_table(TopKind::Memory, &processes, 5),
            "firefox           1.5 GiB\n\
             Xcode             412 MiB\n\
             alpha             900 KiB\n\
             beta              900 KiB"
        );
    }

    #[test]
    fn an_outlier_value_widens_the_value_column_for_every_row() {
        let processes = [process(1, "wide", 2345.6, 0), process(2, "idle", 0.0, 0)];
        assert_eq!(
            top_table(TopKind::Cpu, &processes, 5),
            "wide             2345.6%\nidle                0.0%"
        );
    }

    #[test]
    fn the_row_count_is_clamped_to_one_through_twenty() {
        let processes: Vec<TopProcess> = (1..=25)
            .map(|pid| process(pid, &format!("p{pid}"), pid as f64, 0))
            .collect();
        let rows = |count| top_table(TopKind::Cpu, &processes, count).lines().count();
        assert_eq!(rows(5), 5);
        assert_eq!(rows(20), 20);
        assert_eq!(rows(50), 20);
        assert_eq!(rows(0), 1);
        assert_eq!(
            top_table(TopKind::Cpu, &processes[..2], 5).lines().count(),
            2
        );
    }

    #[test]
    fn an_empty_process_list_renders_an_empty_table() {
        assert_eq!(top_table(TopKind::Cpu, &[], 5), "");
        assert_eq!(top_table(TopKind::Memory, &[], 5), "");
    }

    #[test]
    fn external_names_cannot_open_markup_or_break_rows() {
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "a#b", 0.0, 0)], 5),
            "a##b                0.0%"
        );
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "bad\nname", 0.0, 0)], 5),
            "bad?name           0.0%"
        );
        assert_eq!(
            top_table(TopKind::Cpu, &[process(77, "  ", 0.0, 0)], 5),
            "[77]               0.0%"
        );
    }

    #[test]
    fn rows_recover_resident_bytes_and_skip_malformed_entries() {
        let response = json!({ "ok": true, "processes": [
            { "pid": 1, "comm": "launchd", "cpu_percent": 0.5, "mem_percent": 12.5 },
            { "pid": 2, "comm": "no-memory", "cpu_percent": 0.5 },
            { "pid": "3", "comm": "bad-pid", "cpu_percent": 0.5, "mem_percent": 1.0 },
            { "pid": 4, "comm": "zsh", "cpu_percent": 7.25, "mem_percent": 0.1 },
        ]});
        assert_eq!(
            parse_processes(&response, 1_000_000),
            vec![
                process(1, "launchd", 0.5, 125_000),
                process(4, "zsh", 7.25, 1_000),
            ]
        );
        assert!(parse_processes(&json!({ "ok": false, "error": "x" }), 1_000).is_empty());
    }

    fn polls(frames: &[Value]) -> Vec<Value> {
        frames
            .iter()
            .filter(|frame| frame["method"] == "poll")
            .map(|frame| frame["params"]["intervals"].clone())
            .collect()
    }

    fn statuses(frames: &[Value]) -> Vec<Value> {
        frames
            .iter()
            .filter(|frame| frame["method"] == "status")
            .map(|frame| frame["params"]["segments"].clone())
            .collect()
    }

    /// Answer the sampler's table read with `processes`.
    async fn reply_table(harness: &mut Harness, processes: Value) {
        let (id, method, params) = harness.next_host_request().await.expect("table read");
        assert_eq!(method, "host.process_table");
        assert_eq!(params, json!({ "sample_window_ms": 150 }));
        assert!(harness.reply_host(id, json!({ "ok": true, "processes": processes })));
    }

    #[tokio::test]
    async fn observation_arms_samples_clears_and_rearms_one_registration() {
        let sampler: &'static TopSampler = Box::leak(Box::default());
        let mut harness = Harness::with_config("processes", json!({ "top_count": 2 }));
        let ctx = harness.context();
        let table = json!([
            { "pid": 1, "comm": "launchd", "cpu_percent": 0.5, "mem_percent": 0.1 },
            { "pid": 2, "comm": "firefox", "cpu_percent": 40.0, "mem_percent": 9.0 },
            { "pid": 3, "comm": "Xcode", "cpu_percent": 12.0, "mem_percent": 20.0 },
        ]);

        // Observing top_cpu registers the cadence and samples at once; only
        // the observed table publishes.
        let sample = sampler
            .observe(&ctx, &segments(&["focused_app_details", "top_cpu"]))
            .expect("immediate sample");
        reply_table(&mut harness, table.clone()).await;
        sample.await.unwrap();
        let frames = harness.drain();
        assert_eq!(polls(&frames), [json!({ "i0": 2.0 })]);
        assert_eq!(
            statuses(&frames),
            [json!({ "top_cpu": "firefox           40.0%\nXcode             12.0%" })]
        );

        // An unchanged table stays off the wire.
        let tick = tokio::spawn(async move { sampler.refresh(&ctx).await });
        reply_table(&mut harness, table.clone()).await;
        tick.await.unwrap();
        assert!(harness.drain().is_empty());

        // No table observed: the cadence is cancelled, the table cleared, and
        // a tick that raced the change does not sample.
        let ctx = harness.context();
        assert!(sampler
            .observe(&ctx, &segments(&["focused_app_details"]))
            .is_none());
        let frames = harness.drain();
        assert_eq!(polls(&frames), [json!({})]);
        assert_eq!(statuses(&frames), [json!({ "top_cpu": "" })]);
        sampler.refresh(&ctx).await;
        assert!(harness.drain().is_empty());

        // Observing top_mem re-arms the same registration.
        let sample = sampler
            .observe(&ctx, &segments(&["top_mem"]))
            .expect("immediate sample");
        reply_table(&mut harness, table).await;
        sample.await.unwrap();
        let frames = harness.drain();
        assert_eq!(polls(&frames), [json!({ "i0": 2.0 })]);
        let published = statuses(&frames);
        assert_eq!(published.len(), 1, "{published:?}");
        let names: Vec<&str> = published[0]["top_mem"]
            .as_str()
            .expect("top_mem table")
            .lines()
            .filter_map(|line| line.split_whitespace().next())
            .collect();
        assert_eq!(names, ["Xcode", "firefox"]);
        assert!(published[0].get("top_cpu").is_none());
    }

    #[tokio::test]
    async fn a_failed_sample_keeps_the_last_table_and_warns_once() {
        let sampler: &'static TopSampler = Box::leak(Box::default());
        let mut harness = Harness::new("processes");
        let ctx = harness.context();
        let sample = sampler
            .observe(&ctx, &segments(&["top_cpu"]))
            .expect("immediate sample");
        reply_table(&mut harness, json!([])).await;
        sample.await.unwrap();
        for _ in 0..2 {
            let tick_ctx = ctx.clone();
            let tick = tokio::spawn(async move { sampler.refresh(&tick_ctx).await });
            reply_table(&mut harness, json!([])).await;
            tick.await.unwrap();
        }
        let frames = harness.drain();
        assert!(statuses(&frames).is_empty(), "{frames:?}");
        let warnings: Vec<&Value> = frames
            .iter()
            .filter(|frame| frame["method"] == "log")
            .collect();
        assert_eq!(warnings.len(), 1, "{frames:?}");
        assert_eq!(
            warnings[0]["params"]["message"],
            "[processes] top sample failed; keeping the last tables"
        );
    }
}
