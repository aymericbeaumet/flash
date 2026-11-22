//! The plugin's one process model: every process the user may measure, and
//! the whole process tree of one app. Both are read by the host
//! (`host.process_table`): this plugin reads no process itself.
//!
//! CPU is a delta. Each pid's cumulative CPU time is cached with the moment
//! the host read it, and the next read divides the difference by the time
//! between the two: the average over the reader's own period, not a lifetime
//! mean. A pid with no usable prior read is read twice, [`SAMPLE_WINDOW`]
//! apart, so its first figure is real rather than zero. That window is a
//! deadline on the host's clock, never a sleep. The share is of one core, as
//! `top` and Activity Monitor report it.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::{Context, PollPriority, ProcessEntry, TreeProcess};

use crate::sys::Machine;

/// The bracket for a pid read for the first time.
pub(crate) const SAMPLE_WINDOW: Duration = Duration::from_millis(150);

/// One row of the full table.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Process {
    pub(crate) pid: i32,
    pub(crate) name: String,
    pub(crate) cpu_percent: f64,
    pub(crate) resident_bytes: u64,
    /// With the pid, the identity of this process: a reused pid starts at
    /// another time.
    pub(crate) start_abstime: u64,
}

/// One app's process and every currently reachable descendant, summed.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Tree {
    pub(crate) pid: i32,
    pub(crate) name: String,
    pub(crate) cpu_percent: f64,
    pub(crate) resident_bytes: u64,
    pub(crate) process_count: usize,
    pub(crate) thread_count: usize,
    pub(crate) socket_count: usize,
    /// The main process's alone.
    pub(crate) uptime_seconds: u64,
    pub(crate) disk_read_bytes: u64,
    pub(crate) disk_write_bytes: u64,
    pub(crate) start_abstime: u64,
    /// The main process's executable.
    pub(crate) executable_path: String,
    pub(crate) descendants: Vec<Process>,
}

/// One read of a pid, kept so the next read computes CPU as a delta.
/// `start_abstime` guards against pid reuse; the name is the one the host
/// read at the end of the pid's first bracket.
struct Sample {
    cpu_ns: u64,
    /// The host's monotonic clock at that read, in nanoseconds.
    sampled_at: u64,
    start_abstime: u64,
    name: String,
}

/// One process as one read of the host found it. A list carries no disk
/// figures, and names only the processes it was asked for by pid.
#[derive(Clone)]
struct Reading {
    pid: i32,
    start_abstime: u64,
    cpu_ns: u64,
    resident_bytes: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
    name: Option<String>,
}

impl From<&ProcessEntry> for Reading {
    fn from(process: &ProcessEntry) -> Self {
        Self {
            pid: process.pid,
            start_abstime: process.start,
            cpu_ns: process.cpu_ns,
            resident_bytes: process.resident_bytes,
            disk_read_bytes: 0,
            disk_write_bytes: 0,
            name: process.name.clone(),
        }
    }
}

impl From<&TreeProcess> for Reading {
    fn from(process: &TreeProcess) -> Self {
        Self {
            disk_read_bytes: process.disk_read_bytes,
            disk_write_bytes: process.disk_write_bytes,
            ..Self::from(&process.process)
        }
    }
}

struct Sampled {
    reading: Reading,
    cpu_percent: f64,
    name: String,
}

impl Sampled {
    fn process(&self) -> Process {
        Process {
            pid: self.reading.pid,
            name: self.name.clone(),
            cpu_percent: self.cpu_percent,
            resident_bytes: self.reading.resident_bytes,
            start_abstime: self.reading.start_abstime,
        }
    }
}

pub(crate) struct ProcessTable {
    machine: Arc<dyn Machine>,
    samples: Mutex<HashMap<i32, Sample>>,
}

/// CPU time spent between two reads, as a share of one core.
fn share(before_ns: u64, after_ns: u64, elapsed: Duration) -> f64 {
    let elapsed_ns = elapsed.as_nanos() as f64;
    if elapsed_ns <= 0.0 {
        return 0.0;
    }
    after_ns.saturating_sub(before_ns) as f64 / elapsed_ns * 100.0
}

impl ProcessTable {
    pub(crate) fn new(machine: Arc<dyn Machine>) -> Self {
        Self {
            machine,
            samples: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn machine(&self) -> &Arc<dyn Machine> {
        &self.machine
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i32, Sample>> {
        self.samples
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Every process the user may measure, in the kernel's order. Empty
    /// when the host could not read: this process itself is always listed.
    pub(crate) async fn processes(&self, ctx: &Context) -> Vec<Process> {
        let Ok(first) = ctx.processes(None).await else {
            return Vec::new();
        };
        let order: Vec<i32> = first.processes.iter().map(|process| process.pid).collect();
        let readings = first.processes.iter().map(Reading::from).collect();
        let (mut sampled, unread) = self.settle(first.at, readings, true);
        if !unread.is_empty() {
            // `High`: a table on screen, or a query someone typed, waits on
            // it.
            ctx.wait(SAMPLE_WINDOW, PollPriority::High).await;
            let pids: Vec<i32> = unread.iter().map(|reading| reading.pid).collect();
            if let Ok(second) = ctx.processes(Some(&pids)).await {
                let again = second.processes.iter().map(Reading::from).collect();
                self.bracket(first.at, unread, second.at, again, &mut sampled);
            }
        }
        order
            .iter()
            .filter_map(|pid| sampled.get(pid).map(Sampled::process))
            .collect()
    }

    /// `root` and every descendant reachable now. Browser and Electron work
    /// lives mostly in helpers, so a root-only figure would under-report
    /// the app. Nil when `root` is gone.
    pub(crate) async fn tree(&self, ctx: &Context, root: i32) -> Option<Tree> {
        let first = ctx.process_tree(root).await.ok()?;
        let order: Vec<i32> = first
            .processes
            .iter()
            .map(|process| process.process.pid)
            .collect();
        let readings = first.processes.iter().map(Reading::from).collect();
        let (mut sampled, unread) = self.settle(first.at, readings, false);
        // The counts, the root's path and its start are the last read's, as
        // the figures of a pid read for the first time are.
        let mut last = first;
        if !unread.is_empty() {
            // `High`: the placeholder on screen is waiting for it.
            ctx.wait(SAMPLE_WINDOW, PollPriority::High).await;
            if let Ok(second) = ctx.process_tree(root).await {
                let again = second.processes.iter().map(Reading::from).collect();
                self.bracket(last.at, unread, second.at, again, &mut sampled);
                last = second;
            }
        }
        let main = sampled.get(&root)?;
        let detail: HashMap<i32, &TreeProcess> = last
            .processes
            .iter()
            .map(|process| (process.process.pid, process))
            .collect();
        let count = |value: u64| usize::try_from(value).unwrap_or(usize::MAX);
        let mut tree = Tree {
            pid: root,
            name: main.name.clone(),
            cpu_percent: 0.0,
            resident_bytes: 0,
            process_count: 0,
            thread_count: 0,
            socket_count: 0,
            uptime_seconds: last
                .started_at
                .map_or(0, |started| self.machine.now().saturating_sub(started)),
            disk_read_bytes: 0,
            disk_write_bytes: 0,
            start_abstime: main.reading.start_abstime,
            executable_path: last.path.clone().unwrap_or_default(),
            descendants: Vec::new(),
        };
        for pid in &order {
            let Some(process) = sampled.get(pid) else {
                continue;
            };
            tree.process_count += 1;
            tree.cpu_percent += process.cpu_percent;
            tree.resident_bytes = tree
                .resident_bytes
                .saturating_add(process.reading.resident_bytes);
            tree.disk_read_bytes = tree
                .disk_read_bytes
                .saturating_add(process.reading.disk_read_bytes);
            tree.disk_write_bytes = tree
                .disk_write_bytes
                .saturating_add(process.reading.disk_write_bytes);
            if let Some(detail) = detail.get(pid) {
                tree.thread_count = tree.thread_count.saturating_add(count(detail.threads));
                tree.socket_count = tree.socket_count.saturating_add(count(detail.sockets));
            }
            if *pid != root {
                tree.descendants.push(process.process());
            }
        }
        Some(tree)
    }

    /// When the process at `pid` started: with the pid, its identity. Nil
    /// when it is gone, or not this user's to measure.
    pub(crate) async fn start(&self, ctx: &Context, pid: i32) -> Option<u64> {
        let listed = ctx.processes(Some(&[pid])).await.ok()?;
        listed
            .processes
            .iter()
            .find(|process| process.pid == pid && process.name.is_some())
            .map(|process| process.start)
    }

    /// Compute each reading the host took at `at` against the pid's prior
    /// read. A pid without a usable one is returned to be read again after
    /// the window. Prior reads come from the cache whichever caller made
    /// them; a full sweep prunes the pids that are gone.
    fn settle(
        &self,
        at: u64,
        readings: Vec<Reading>,
        prune_others: bool,
    ) -> (HashMap<i32, Sampled>, Vec<Reading>) {
        let mut out: HashMap<i32, Sampled> = HashMap::new();
        let mut unread: Vec<Reading> = Vec::new();
        let mut samples = self.lock();
        if prune_others {
            let live: HashSet<i32> = readings.iter().map(|reading| reading.pid).collect();
            samples.retain(|pid, _| live.contains(pid));
        }
        for reading in readings {
            match samples.get_mut(&reading.pid) {
                Some(prior)
                    if prior.start_abstime == reading.start_abstime && at > prior.sampled_at =>
                {
                    let cpu_percent = share(
                        prior.cpu_ns,
                        reading.cpu_ns,
                        Duration::from_nanos(at - prior.sampled_at),
                    );
                    prior.cpu_ns = reading.cpu_ns;
                    prior.sampled_at = at;
                    out.insert(
                        reading.pid,
                        Sampled {
                            cpu_percent,
                            name: prior.name.clone(),
                            reading,
                        },
                    );
                }
                _ => unread.push(reading),
            }
        }
        (out, unread)
    }

    /// The second read of the pids `settle` returned: `again`, taken at
    /// `second_at`. A pid that is gone, was reused meanwhile or has no name
    /// stays out.
    fn bracket(
        &self,
        first_at: u64,
        firsts: Vec<Reading>,
        second_at: u64,
        again: Vec<Reading>,
        out: &mut HashMap<i32, Sampled>,
    ) {
        let mut again: HashMap<i32, Reading> = again
            .into_iter()
            .map(|reading| (reading.pid, reading))
            .collect();
        let window = Duration::from_nanos(second_at.saturating_sub(first_at));
        let mut samples = self.lock();
        for first in firsts {
            let Some(reading) = again.remove(&first.pid) else {
                continue;
            };
            if reading.start_abstime != first.start_abstime {
                continue;
            }
            let Some(name) = reading.name.clone() else {
                continue;
            };
            let cpu_percent = share(first.cpu_ns, reading.cpu_ns, window);
            samples.insert(
                reading.pid,
                Sample {
                    cpu_ns: reading.cpu_ns,
                    sampled_at: second_at,
                    start_abstime: reading.start_abstime,
                    name: name.clone(),
                },
            );
            out.insert(
                reading.pid,
                Sampled {
                    reading,
                    cpu_percent,
                    name,
                },
            );
        }
    }
}

#[cfg(test)]
pub(crate) mod testing {
    //! A scripted Mac: the processes a test declares, as the host reports
    //! them, and nothing of the machine the test runs on.

    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::{Value, json};

    use crate::bundle::BundleInfo;
    use crate::sys::Machine;

    /// The wall clock of every scripted Mac, in Unix seconds.
    pub(crate) const NOW: u64 = 1_800_000_000;
    /// How far the host's monotonic clock moves between two reads.
    const READ_INTERVAL_NS: u64 = 10_000_000;

    /// What the host reads of one process.
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub(crate) struct Usage {
        pub(crate) cpu_ns: u64,
        pub(crate) resident_bytes: u64,
        pub(crate) disk_read_bytes: u64,
        pub(crate) disk_write_bytes: u64,
        pub(crate) start_abstime: u64,
    }

    #[derive(Clone, Debug, Default)]
    pub(crate) struct FakeProcess {
        pub(crate) parent: i32,
        pub(crate) path: String,
        pub(crate) usage: Usage,
        pub(crate) threads: usize,
        pub(crate) sockets: usize,
        pub(crate) uptime_seconds: u64,
    }

    #[derive(Default)]
    pub(crate) struct FakeMachine {
        pub(crate) processes: Mutex<BTreeMap<i32, FakeProcess>>,
        pub(crate) bundles: Mutex<BTreeMap<String, BundleInfo>>,
        pub(crate) physical_memory: u64,
        /// How many times a bundle was read.
        pub(crate) bundle_reads: Mutex<usize>,
        /// The host's monotonic clock, in nanoseconds.
        clock: AtomicU64,
    }

    impl FakeMachine {
        pub(crate) fn new(physical_memory: u64) -> Self {
            Self {
                physical_memory,
                ..Self::default()
            }
        }

        /// Add or replace `pid`, started at `start_abstime`.
        pub(crate) fn spawn(&self, pid: i32, parent: i32, path: &str, start_abstime: u64) {
            self.processes.lock().unwrap().insert(
                pid,
                FakeProcess {
                    parent,
                    path: path.into(),
                    usage: Usage {
                        start_abstime,
                        ..Usage::default()
                    },
                    threads: 1,
                    ..FakeProcess::default()
                },
            );
        }

        pub(crate) fn update(&self, pid: i32, change: impl FnOnce(&mut FakeProcess)) {
            change(
                self.processes
                    .lock()
                    .unwrap()
                    .get_mut(&pid)
                    .expect("a declared process"),
            );
        }

        pub(crate) fn exit(&self, pid: i32) {
            self.processes.lock().unwrap().remove(&pid);
        }

        /// Whether `pid` names a declared process.
        pub(crate) fn runs(&self, pid: Option<i64>) -> bool {
            pid.and_then(|pid| i32::try_from(pid).ok())
                .is_some_and(|pid| self.processes.lock().unwrap().contains_key(&pid))
        }

        /// One process as the host reports it. `named`: asked for by pid,
        /// or part of a tree.
        fn process(pid: i32, process: &FakeProcess, named: bool) -> Value {
            let name = process.path.trim_end_matches('/').rsplit('/').next();
            let mut row = json!({
                "pid": pid, "start": process.usage.start_abstime,
                "cpu_ns": process.usage.cpu_ns, "resident_bytes": process.usage.resident_bytes,
            });
            if let Some(name) = name.filter(|name| named && !name.is_empty()) {
                row["name"] = json!(name);
            }
            row
        }

        /// The host's reply to one `host.process_table` request: every
        /// declared process is the user's to measure, in pid order.
        pub(crate) fn reply(&self, params: &Value) -> Value {
            let at = self.clock.fetch_add(READ_INTERVAL_NS, Ordering::SeqCst) + READ_INTERVAL_NS;
            let processes = self.processes.lock().unwrap();
            match params["operation"].as_str() {
                Some("list") => {
                    let named = params.get("pids").is_some();
                    let pids: Vec<i32> = match params.get("pids") {
                        None => processes.keys().copied().collect(),
                        Some(pids) => pids
                            .as_array()
                            .expect("pids is a list")
                            .iter()
                            .map(|pid| pid.as_i64().expect("a pid") as i32)
                            .collect(),
                    };
                    let rows: Vec<Value> = pids
                        .iter()
                        .filter_map(|pid| Some(Self::process(*pid, processes.get(pid)?, named)))
                        .collect();
                    json!({ "ok": true, "at": at, "processes": rows })
                }
                Some("tree") => {
                    let root = params["pid"].as_i64().expect("a pid") as i32;
                    let Some(main) = processes.get(&root) else {
                        return json!({ "ok": true, "at": at, "processes": [] });
                    };
                    let mut ordered = vec![root];
                    let mut seen = BTreeSet::from([root]);
                    let mut index = 0;
                    while index < ordered.len() {
                        let parent = ordered[index];
                        index += 1;
                        for (pid, process) in processes.iter() {
                            if process.parent == parent && seen.insert(*pid) {
                                ordered.push(*pid);
                            }
                        }
                    }
                    let rows: Vec<Value> = ordered
                        .iter()
                        .map(|pid| {
                            let process = &processes[pid];
                            let mut row = Self::process(*pid, process, true);
                            row["threads"] = json!(process.threads);
                            row["sockets"] = json!(process.sockets);
                            row["disk_read_bytes"] = json!(process.usage.disk_read_bytes);
                            row["disk_write_bytes"] = json!(process.usage.disk_write_bytes);
                            row
                        })
                        .collect();
                    json!({
                        "ok": true, "at": at, "processes": rows, "path": main.path,
                        "started_at": NOW - main.uptime_seconds,
                    })
                }
                _ => {
                    json!({ "ok": false, "error": "host.process_table requires a supported operation" })
                }
            }
        }
    }

    impl Machine for FakeMachine {
        fn physical_memory(&self) -> u64 {
            self.physical_memory.max(1)
        }

        fn now(&self) -> u64 {
            NOW
        }

        fn bundle_info(&self, bundle_path: &str) -> BundleInfo {
            *self.bundle_reads.lock().unwrap() += 1;
            self.bundles
                .lock()
                .unwrap()
                .get(bundle_path)
                .cloned()
                .unwrap_or_default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::FakeMachine;
    use super::*;
    use crate::testing::{Host, deadlines};
    use serde_json::json;

    /// Run `read` to its end, with the host answering its reads and landing
    /// the bracket it asks for; also the deadlines it registered meanwhile.
    async fn read<T: Send + 'static>(
        host: &mut Host,
        read: impl std::future::Future<Output = T> + Send + 'static,
    ) -> (T, Vec<serde_json::Value>) {
        let task = tokio::spawn(read);
        let frames = host.settle().await;
        (task.await.unwrap(), deadlines(&frames))
    }

    fn table(machine: &Arc<FakeMachine>) -> Arc<ProcessTable> {
        Arc::new(ProcessTable::new(machine.clone()))
    }

    #[test]
    fn a_share_is_cpu_time_over_wall_time() {
        assert_eq!(share(0, 500_000_000, Duration::from_secs(1)), 50.0);
        assert_eq!(share(0, 3_000_000_000, Duration::from_secs(1)), 300.0);
        assert_eq!(share(9, 4, Duration::from_secs(1)), 0.0, "never negative");
        assert_eq!(share(0, 9, Duration::ZERO), 0.0, "no window, no figure");
    }

    #[tokio::test]
    async fn a_first_read_brackets_a_window_and_the_next_one_is_a_delta() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(10, 1, "/usr/bin/first", 100);
        machine.spawn(20, 1, "/Applications/Second.app/Contents/MacOS/Second", 200);
        machine.update(20, |process| process.usage.resident_bytes = 4096);
        let table = table(&machine);
        let mut host = Host::new(json!({}), &machine);

        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(
            waited,
            [json!({ "after": 0.15, "priority": "high" })],
            "the bracket is one host deadline"
        );
        assert_eq!(
            host.reads,
            [
                json!({ "operation": "list" }),
                json!({ "operation": "list", "pids": [10, 20] })
            ],
            "the whole table, then only the pids read for the first time"
        );
        assert_eq!(
            rows.iter()
                .map(|row| (row.pid, row.name.as_str(), row.resident_bytes))
                .collect::<Vec<_>>(),
            [(10, "first", 0), (20, "Second", 4096)]
        );
        assert_eq!(rows[1].start_abstime, 200);
        assert_eq!(rows[0].cpu_percent, 0.0, "idle across the window");

        // Known pids are deltas since their last read: no window, no wait,
        // one read. A millisecond of CPU over the 10 ms between the host's
        // two reads is a tenth of a core.
        machine.update(10, |process| process.usage.cpu_ns = 1_000_000);
        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(rows[0].cpu_percent, 10.0, "{rows:?}");
        assert_eq!(rows[1].cpu_percent, 0.0);
        assert_eq!(waited, Vec::<serde_json::Value>::new());
        assert_eq!(host.reads.len(), 3);
    }

    #[tokio::test]
    async fn a_reused_pid_is_a_new_process_and_a_gone_one_leaves_the_table() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(10, 1, "/usr/bin/old", 100);
        machine.spawn(11, 1, "/usr/bin/other", 100);
        let table = table(&machine);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();
        let reader = table.clone();
        read(&mut host, async move { reader.processes(&ctx).await }).await;

        // The same pid, started later: its name is read afresh and its
        // first figure brackets a window again.
        machine.spawn(10, 1, "/usr/bin/new", 900);
        machine.exit(11);
        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(waited.len(), 1, "a new process brackets a window again");
        assert_eq!(
            host.reads.last(),
            Some(&json!({ "operation": "list", "pids": [10] }))
        );
        assert_eq!(
            rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["new"]
        );
        assert_eq!(table.lock().len(), 1, "the sweep pruned the pid that left");

        let (ctx, reader) = (host.harness.context(), table.clone());
        let (start, _) = read(&mut host, async move { reader.start(&ctx, 10).await }).await;
        assert_eq!(start, Some(900));
        let (ctx, reader) = (host.harness.context(), table.clone());
        let (start, _) = read(&mut host, async move { reader.start(&ctx, 11).await }).await;
        assert_eq!(start, None);
    }

    /// A pid that leaves, is reused or loses its name inside the window is
    /// not listed: its second read is the one that names it.
    #[tokio::test]
    async fn a_pid_that_changes_inside_the_window_stays_out() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(10, 1, "/usr/bin/stays", 100);
        machine.spawn(11, 1, "/usr/bin/leaves", 110);
        machine.spawn(12, 1, "/usr/bin/reused", 120);
        let table = table(&machine);
        let mut host = Host::new(json!({}), &machine);
        let (ctx, reader) = (host.harness.context(), table.clone());
        let task = tokio::spawn(async move { reader.processes(&ctx).await });
        host.answer_until_waiting().await;
        machine.exit(11);
        machine.spawn(12, 1, "/usr/bin/another", 500);
        host.settle().await;
        let rows = task.await.unwrap();
        assert_eq!(
            rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["stays"]
        );
    }

    #[tokio::test]
    async fn a_failed_read_lists_nothing() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(10, 1, "/usr/bin/first", 100);
        let table = table(&machine);
        let mut host = Host::new(json!({}), &machine);
        host.failure = Some("process table unavailable".into());
        let (ctx, reader) = (host.harness.context(), table.clone());
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(rows, Vec::new());
        assert_eq!(waited, Vec::<serde_json::Value>::new());
        let (ctx, reader) = (host.harness.context(), table.clone());
        let (tree, _) = read(&mut host, async move { reader.tree(&ctx, 10).await }).await;
        assert_eq!(tree, None);
        let (ctx, reader) = (host.harness.context(), table.clone());
        let (start, _) = read(&mut host, async move { reader.start(&ctx, 10).await }).await;
        assert_eq!(start, None);
    }

    #[tokio::test]
    async fn a_tree_sums_an_app_and_every_reachable_descendant() {
        let machine = Arc::new(FakeMachine::new(1 << 30));
        machine.spawn(1, 0, "/sbin/launchd", 1);
        machine.spawn(40, 1, "/Applications/Web.app/Contents/MacOS/Web", 400);
        machine.spawn(41, 40, "/Applications/Web.app/Contents/MacOS/Helper", 410);
        machine.spawn(42, 41, "/Applications/Web.app/Contents/MacOS/Renderer", 420);
        machine.spawn(50, 1, "/usr/bin/unrelated", 500);
        machine.update(40, |process| {
            process.usage.resident_bytes = 100;
            process.usage.disk_read_bytes = 7;
            process.threads = 5;
            process.sockets = 2;
            process.uptime_seconds = 3_600;
        });
        machine.update(41, |process| {
            process.usage.resident_bytes = 20;
            process.usage.disk_write_bytes = 9;
            process.threads = 3;
            process.sockets = 1;
            process.uptime_seconds = 60;
        });
        machine.update(42, |process| process.usage.resident_bytes = 3);
        let table = table(&machine);
        let mut host = Host::new(json!({}), &machine);
        let ctx = host.harness.context();
        let reader = table.clone();
        let (tree, waited) = read(&mut host, async move { reader.tree(&ctx, 40).await }).await;
        assert_eq!(
            waited.len(),
            1,
            "pids read for the first time bracket a window"
        );
        assert_eq!(
            host.reads,
            [
                json!({ "operation": "tree", "pid": 40 }),
                json!({ "operation": "tree", "pid": 40 })
            ]
        );
        let tree = tree.expect("the app runs");
        assert_eq!(tree.name, "Web");
        assert_eq!(
            tree.executable_path,
            "/Applications/Web.app/Contents/MacOS/Web"
        );
        assert_eq!(tree.start_abstime, 400);
        assert_eq!(tree.process_count, 3);
        assert_eq!(tree.resident_bytes, 123);
        assert_eq!(tree.thread_count, 9);
        assert_eq!(tree.socket_count, 3);
        assert_eq!(tree.uptime_seconds, 3_600, "the main process's alone");
        assert_eq!(tree.disk_read_bytes, 7);
        assert_eq!(tree.disk_write_bytes, 9);
        assert_eq!(
            tree.descendants
                .iter()
                .map(|helper| (helper.pid, helper.name.as_str()))
                .collect::<Vec<_>>(),
            [(41, "Helper"), (42, "Renderer")]
        );
        assert_eq!(table.lock().len(), 3, "a tree read prunes nothing");

        // The next read is one request: every pid has a prior read.
        machine.update(41, |process| process.usage.cpu_ns = 5_000_000);
        let (ctx, reader) = (host.harness.context(), table.clone());
        let (tree, waited) = read(&mut host, async move { reader.tree(&ctx, 40).await }).await;
        assert_eq!(waited, Vec::<serde_json::Value>::new());
        assert_eq!(host.reads.len(), 3);
        assert_eq!(tree.expect("the app runs").cpu_percent, 50.0);

        let (ctx, reader) = (host.harness.context(), table.clone());
        let (tree, _) = read(&mut host, async move { reader.tree(&ctx, 999).await }).await;
        assert_eq!(tree, None, "no such app");
    }
}
