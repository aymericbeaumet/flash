//! The plugin's one process model: every visible process, and the whole
//! process tree of one app.
//!
//! CPU is a delta. Each pid's cumulative CPU time is cached with the moment
//! it was read, and the next read divides the difference by the time
//! elapsed: the average over the reader's own period, not a lifetime mean. A
//! pid with no usable prior read is read twice, [`SAMPLE_WINDOW`] apart, so
//! its first figure is real rather than zero. That window is a deadline on
//! the host's clock, never a sleep. The share is of one core, as `top` and
//! Activity Monitor report it.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::{Context, PollPriority};

use crate::sys::{Kernel, Usage, basename};

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
/// `start_abstime` guards against pid reuse; the path is cached because
/// `proc_pidpath` is the most expensive per-pid call of a sweep.
struct Sample {
    cpu_ns: u64,
    sampled_at: Instant,
    start_abstime: u64,
    path: String,
    name: String,
}

struct Sampled {
    usage: Usage,
    cpu_percent: f64,
    path: String,
    name: String,
}

pub(crate) struct ProcessTable {
    kernel: Arc<dyn Kernel>,
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
    pub(crate) fn new(kernel: Arc<dyn Kernel>) -> Self {
        Self {
            kernel,
            samples: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn kernel(&self) -> &Arc<dyn Kernel> {
        &self.kernel
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i32, Sample>> {
        self.samples
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Every visible process, in the kernel's order. Empty only when the
    /// read failed: the reading process itself is always listed.
    pub(crate) async fn processes(&self, ctx: &Context) -> Vec<Process> {
        let pids = self.kernel.pids();
        let sampled = self.sample(ctx, &pids, true).await;
        pids.iter()
            .filter_map(|pid| {
                sampled.get(pid).map(|process| Process {
                    pid: *pid,
                    name: process.name.clone(),
                    cpu_percent: process.cpu_percent,
                    resident_bytes: process.usage.resident_bytes,
                    start_abstime: process.usage.start_abstime,
                })
            })
            .collect()
    }

    /// `root` and every descendant reachable now. Browser and Electron work
    /// lives mostly in helpers, so a root-only figure would under-report
    /// the app. Nil when `root` is gone.
    pub(crate) async fn tree(&self, ctx: &Context, root: i32) -> Option<Tree> {
        let pids = self.descendants(root);
        let sampled = self.sample(ctx, &pids, false).await;
        let main = sampled.get(&root)?;
        let mut tree = Tree {
            pid: root,
            name: main.name.clone(),
            cpu_percent: 0.0,
            resident_bytes: 0,
            process_count: 0,
            thread_count: 0,
            socket_count: 0,
            uptime_seconds: self.kernel.uptime_seconds(root),
            disk_read_bytes: 0,
            disk_write_bytes: 0,
            start_abstime: main.usage.start_abstime,
            executable_path: main.path.clone(),
            descendants: Vec::new(),
        };
        for pid in &pids {
            let Some(process) = sampled.get(pid) else {
                continue;
            };
            tree.process_count += 1;
            tree.cpu_percent += process.cpu_percent;
            tree.resident_bytes = tree
                .resident_bytes
                .saturating_add(process.usage.resident_bytes);
            tree.disk_read_bytes = tree
                .disk_read_bytes
                .saturating_add(process.usage.disk_read_bytes);
            tree.disk_write_bytes = tree
                .disk_write_bytes
                .saturating_add(process.usage.disk_write_bytes);
            tree.thread_count += self.kernel.thread_count(*pid);
            tree.socket_count += self.kernel.socket_count(*pid);
            if *pid != root {
                tree.descendants.push(Process {
                    pid: *pid,
                    name: process.name.clone(),
                    cpu_percent: process.cpu_percent,
                    resident_bytes: process.usage.resident_bytes,
                    start_abstime: process.usage.start_abstime,
                });
            }
        }
        Some(tree)
    }

    /// A pid's executable name as it is now, or nil when it is gone or not
    /// this user's to inspect.
    pub(crate) fn name(&self, pid: i32) -> Option<String> {
        basename(&self.kernel.path(pid)?)
    }

    /// When the process at `pid` started: with the pid, its identity. Nil
    /// when it is gone, or another user's.
    pub(crate) fn start(&self, pid: i32) -> Option<u64> {
        self.kernel.usage(pid).map(|usage| usage.start_abstime)
    }

    /// `root`, then its children, then theirs: breadth first, each once.
    fn descendants(&self, root: i32) -> Vec<i32> {
        let mut ordered = vec![root];
        let mut seen: HashSet<i32> = HashSet::from([root]);
        let mut index = 0;
        while index < ordered.len() {
            let parent = ordered[index];
            index += 1;
            for child in self.kernel.children(parent) {
                if child > 0 && seen.insert(child) {
                    ordered.push(child);
                }
            }
        }
        ordered
    }

    /// Read every pid once; a pid without a usable prior read is read again
    /// after the window. Prior reads come from the cache whichever caller
    /// made them; a full sweep prunes the pids that are gone.
    async fn sample(
        &self,
        ctx: &Context,
        pids: &[i32],
        prune_others: bool,
    ) -> HashMap<i32, Sampled> {
        let mut out: HashMap<i32, Sampled> = HashMap::new();
        let mut needs_bracket: Vec<(i32, Usage)> = Vec::new();
        let now = Instant::now();
        {
            let mut samples = self.lock();
            for pid in pids {
                let Some(usage) = self.kernel.usage(*pid) else {
                    continue;
                };
                match samples.get_mut(pid) {
                    Some(prior)
                        if prior.start_abstime == usage.start_abstime && now > prior.sampled_at =>
                    {
                        let cpu_percent = share(prior.cpu_ns, usage.cpu_ns, now - prior.sampled_at);
                        prior.cpu_ns = usage.cpu_ns;
                        prior.sampled_at = now;
                        out.insert(
                            *pid,
                            Sampled {
                                usage,
                                cpu_percent,
                                path: prior.path.clone(),
                                name: prior.name.clone(),
                            },
                        );
                    }
                    _ => needs_bracket.push((*pid, usage)),
                }
            }
            if prune_others {
                let live: HashSet<i32> = pids.iter().copied().collect();
                samples.retain(|pid, _| live.contains(pid));
            }
        }
        if needs_bracket.is_empty() {
            return out;
        }

        // `High`: a table on screen, or a query someone typed, waits on it.
        ctx.wait(SAMPLE_WINDOW, PollPriority::High).await;
        let after = Instant::now();
        let window = after - now;
        let mut samples = self.lock();
        for (pid, first) in needs_bracket {
            let Some(usage) = self.kernel.usage(pid) else {
                continue;
            };
            if usage.start_abstime != first.start_abstime {
                continue;
            }
            let Some(path) = self.kernel.path(pid) else {
                continue;
            };
            let Some(name) = basename(&path) else {
                continue;
            };
            let cpu_percent = share(first.cpu_ns, usage.cpu_ns, window);
            samples.insert(
                pid,
                Sample {
                    cpu_ns: usage.cpu_ns,
                    sampled_at: after,
                    start_abstime: usage.start_abstime,
                    path: path.clone(),
                    name: name.clone(),
                },
            );
            out.insert(
                pid,
                Sampled {
                    usage,
                    cpu_percent,
                    path,
                    name,
                },
            );
        }
        out
    }
}

#[cfg(test)]
pub(crate) mod testing {
    //! A scripted kernel: the processes a test declares, and nothing of the
    //! machine the test runs on.

    use std::collections::BTreeMap;
    use std::sync::Mutex;

    use crate::bundle::BundleInfo;
    use crate::sys::{Kernel, Usage};

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
    pub(crate) struct FakeKernel {
        pub(crate) processes: Mutex<BTreeMap<i32, FakeProcess>>,
        pub(crate) bundles: Mutex<BTreeMap<String, BundleInfo>>,
        pub(crate) physical_memory: u64,
        /// How many times a bundle was read.
        pub(crate) bundle_reads: Mutex<usize>,
    }

    impl FakeKernel {
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
    }

    impl Kernel for FakeKernel {
        fn pids(&self) -> Vec<i32> {
            self.processes.lock().unwrap().keys().copied().collect()
        }

        fn children(&self, parent: i32) -> Vec<i32> {
            self.processes
                .lock()
                .unwrap()
                .iter()
                .filter(|(_, process)| process.parent == parent)
                .map(|(pid, _)| *pid)
                .collect()
        }

        fn usage(&self, pid: i32) -> Option<Usage> {
            self.processes
                .lock()
                .unwrap()
                .get(&pid)
                .map(|process| process.usage)
        }

        fn path(&self, pid: i32) -> Option<String> {
            self.processes
                .lock()
                .unwrap()
                .get(&pid)
                .map(|process| process.path.clone())
        }

        fn thread_count(&self, pid: i32) -> usize {
            self.processes
                .lock()
                .unwrap()
                .get(&pid)
                .map_or(0, |process| process.threads)
        }

        fn socket_count(&self, pid: i32) -> usize {
            self.processes
                .lock()
                .unwrap()
                .get(&pid)
                .map_or(0, |process| process.sockets)
        }

        fn uptime_seconds(&self, pid: i32) -> u64 {
            self.processes
                .lock()
                .unwrap()
                .get(&pid)
                .map_or(0, |process| process.uptime_seconds)
        }

        fn physical_memory(&self) -> u64 {
            self.physical_memory.max(1)
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
    use super::testing::FakeKernel;
    use super::*;
    use crate::sys::Libproc;
    use crate::testing::{Host, deadlines};
    use serde_json::json;

    /// Run `read` to its end, with the host landing the bracket it asks
    /// for; also the deadlines it registered meanwhile.
    async fn read<T: Send + 'static>(
        host: &mut Host,
        read: impl std::future::Future<Output = T> + Send + 'static,
    ) -> (T, Vec<serde_json::Value>) {
        let task = tokio::spawn(read);
        let frames = host.settle().await;
        (task.await.unwrap(), deadlines(&frames))
    }

    fn table(kernel: &Arc<FakeKernel>) -> Arc<ProcessTable> {
        Arc::new(ProcessTable::new(kernel.clone()))
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
        let kernel = Arc::new(FakeKernel::new(1 << 30));
        kernel.spawn(10, 1, "/usr/bin/first", 100);
        kernel.spawn(20, 1, "/Applications/Second.app/Contents/MacOS/Second", 200);
        kernel.update(20, |process| process.usage.resident_bytes = 4096);
        let table = table(&kernel);
        let mut host = Host::new(json!({}));

        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(
            waited,
            [json!({ "after": 0.15, "priority": "high" })],
            "the bracket is one host deadline"
        );
        assert_eq!(
            rows.iter()
                .map(|row| (row.pid, row.name.as_str(), row.resident_bytes))
                .collect::<Vec<_>>(),
            [(10, "first", 0), (20, "Second", 4096)]
        );
        assert_eq!(rows[1].start_abstime, 200);
        assert_eq!(rows[0].cpu_percent, 0.0, "idle across the window");

        // Known pids are deltas since their last read: no window, no wait.
        kernel.update(10, |process| process.usage.cpu_ns = 1_000_000);
        let ctx = host.harness.context();
        let rows = table.processes(&ctx).await;
        assert!(rows[0].cpu_percent > 0.0, "{rows:?}");
        assert_eq!(rows[1].cpu_percent, 0.0);
        assert_eq!(host.settle().await, Vec::<serde_json::Value>::new());
    }

    #[tokio::test]
    async fn a_reused_pid_is_a_new_process_and_a_gone_one_leaves_the_table() {
        let kernel = Arc::new(FakeKernel::new(1 << 30));
        kernel.spawn(10, 1, "/usr/bin/old", 100);
        kernel.spawn(11, 1, "/usr/bin/other", 100);
        let table = table(&kernel);
        let mut host = Host::new(json!({}));
        let ctx = host.harness.context();
        let reader = table.clone();
        read(&mut host, async move { reader.processes(&ctx).await }).await;

        // The same pid, started later: its name is read afresh and its
        // first figure brackets a window again.
        kernel.spawn(10, 1, "/usr/bin/new", 900);
        kernel.exit(11);
        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, waited) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        assert_eq!(waited.len(), 1, "a new process brackets a window again");
        assert_eq!(
            rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["new"]
        );
        assert_eq!(table.lock().len(), 1, "the sweep pruned the pid that left");
        assert_eq!(table.name(10).as_deref(), Some("new"));
        assert_eq!(table.start(10), Some(900));
        assert_eq!(table.name(11), None);
        assert_eq!(table.start(11), None);
    }

    #[tokio::test]
    async fn a_tree_sums_an_app_and_every_reachable_descendant() {
        let kernel = Arc::new(FakeKernel::new(1 << 30));
        kernel.spawn(1, 0, "/sbin/launchd", 1);
        kernel.spawn(40, 1, "/Applications/Web.app/Contents/MacOS/Web", 400);
        kernel.spawn(41, 40, "/Applications/Web.app/Contents/MacOS/Helper", 410);
        kernel.spawn(42, 41, "/Applications/Web.app/Contents/MacOS/Renderer", 420);
        kernel.spawn(50, 1, "/usr/bin/unrelated", 500);
        kernel.update(40, |process| {
            process.usage.resident_bytes = 100;
            process.usage.disk_read_bytes = 7;
            process.threads = 5;
            process.sockets = 2;
            process.uptime_seconds = 3_600;
        });
        kernel.update(41, |process| {
            process.usage.resident_bytes = 20;
            process.usage.disk_write_bytes = 9;
            process.threads = 3;
            process.sockets = 1;
            process.uptime_seconds = 60;
        });
        kernel.update(42, |process| process.usage.resident_bytes = 3);
        let table = table(&kernel);
        let mut host = Host::new(json!({}));
        let ctx = host.harness.context();
        let reader = table.clone();
        let (tree, _) = read(&mut host, async move { reader.tree(&ctx, 40).await }).await;
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

        let ctx = host.harness.context();
        assert_eq!(table.tree(&ctx, 999).await, None, "no such app");
    }

    /// The real table, on this process: it lists itself with a real CPU
    /// share, and sums its own tree.
    #[tokio::test]
    async fn the_live_table_lists_this_process_and_sums_its_tree() {
        let table = Arc::new(ProcessTable::new(Arc::new(Libproc)));
        let mut host = Host::new(json!({}));
        let own = std::process::id() as i32;
        let ctx = host.harness.context();
        let reader = table.clone();
        let (rows, _) = read(&mut host, async move { reader.processes(&ctx).await }).await;
        let mine = rows.iter().find(|row| row.pid == own).expect("own row");
        assert!(!mine.name.is_empty());
        assert!(mine.resident_bytes > 0);
        assert!(mine.cpu_percent >= 0.0);
        assert!(rows.len() > 10, "other processes are listed too");
        assert_eq!(table.name(own), Some(mine.name.clone()));
        assert_eq!(table.start(own), Some(mine.start_abstime));

        let ctx = host.harness.context();
        let reader = table.clone();
        let (tree, _) = read(&mut host, async move { reader.tree(&ctx, own).await }).await;
        let tree = tree.expect("own tree");
        assert_eq!(tree.pid, own);
        assert_eq!(tree.name, mine.name);
        assert!(tree.process_count >= 1);
        assert!(tree.thread_count >= 1);
        assert!(tree.resident_bytes > 0);
    }
}
