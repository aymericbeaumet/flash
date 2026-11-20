//! The processes of this Mac: the busiest ones as status tables, the focused
//! app's resource summary, every process as an `@processes` row, and
//! `process kill`.
//!
//! Nothing here reads a process: the host reads the table for this plugin
//! (`host.process_table`, the `process_table` capability), and the sandbox
//! denies it every process but its own. What is sampled and when, which
//! processes top a table, how a tree is summed and how each reads as text
//! are decided here. Nothing here signals a process either: `process kill`
//! and a picked row ask the host (`host.process_signal`), which sends
//! SIGTERM only inside the perform the user confirmed. The command and each
//! row declare `confirm`, so the host asks first and this plugin never does.

mod bundle;
mod format;
mod sampler;
mod sys;
mod table;
#[cfg(test)]
mod testing;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    Candidate, CommandRequest, Context, Event, PerformResponse, ProcessSignal, SearchRequest,
    SearchResponse, host_events, run,
};

use sampler::Sampler;
use sys::{Machine, ThisMac};
use table::{Process, ProcessTable};

/// The plugin's one source, live and `per_query`: asked while a query names
/// `@processes`, on every change of its text, and answered from one read of
/// the table per [`ROWS_TTL`]. The host filters the rows.
const SOURCE: &str = "processes.processes";
/// One read serves the keystrokes of a query typed within this long.
const ROWS_TTL: Duration = Duration::from_secs(2);
const TOP_COUNT_SETTING: &str = "top_count";
/// The most bytes of a process name a row's question spells out: the whole
/// question stays inside the host's bound on one (`quotas.confirm_bytes`).
const PROMPT_NAME_BYTES: usize = 160;
const KILL_USAGE: &str = "usage: process kill --pid=<pid>";
/// The kernel's reason for a pid that names no process (`ESRCH`), as the
/// host reports it from `kill(2)`.
const NO_SUCH_PROCESS: &str = "No such process";

struct Processes {
    table: Arc<ProcessTable>,
    /// Built on the first event or search: the settings come with the
    /// context.
    sampler: Mutex<Option<Arc<Sampler>>>,
    rows: Mutex<Option<(Instant, Vec<Candidate>)>>,
}

impl Processes {
    fn new(machine: Arc<dyn Machine>) -> Self {
        Self {
            table: Arc::new(ProcessTable::new(machine)),
            sampler: Mutex::new(None),
            rows: Mutex::new(None),
        }
    }

    fn sampler(&self, ctx: &Context) -> Arc<Sampler> {
        self.sampler
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get_or_insert_with(|| Arc::new(Sampler::new(self.table.clone(), top_count(ctx))))
            .clone()
    }

    fn cached_rows(&self) -> Option<Vec<Candidate>> {
        let rows = self
            .rows
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        rows.as_ref()
            .filter(|(read_at, _)| read_at.elapsed() < ROWS_TTL)
            .map(|(_, rows)| rows.clone())
    }

    fn set_rows(&self, rows: Option<Vec<Candidate>>) {
        *self
            .rows
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) =
            rows.map(|rows| (Instant::now(), rows));
    }

    /// SIGTERM `pid` through the host. `expected_start`: the start time of
    /// the row's process, which a reused pid does not share, so a row is
    /// signalled only while the table still lists that very process. A pid
    /// the user named is the kernel's to judge: gone, another user's, or
    /// signalled.
    async fn kill(&self, ctx: &Context, pid: i32, expected_start: Option<u64>) -> PerformResponse {
        if pid <= 1 {
            return PerformResponse::fail(format!("refusing pid {pid}"));
        }
        let gone = || PerformResponse::fail(format!("no process with pid {pid}"));
        // The process the row listed is gone, or its pid now names one
        // started at another time: not the one the user was asked about.
        if let Some(expected) = expected_start
            && self.table.start(ctx, pid).await != Some(expected)
        {
            return gone();
        }
        // The next query reads the table afresh: this row is about to go.
        self.set_rows(None);
        match ctx
            .signal_process(i64::from(pid), ProcessSignal::Term)
            .await
        {
            Ok(()) => PerformResponse::ok(),
            Err(reason) if expected_start.is_none() && reason == NO_SUCH_PROCESS => gone(),
            Err(reason) => PerformResponse::fail(format!("process kill failed: {reason}")),
        }
    }
}

/// `[plugins.processes] top_count`, which the host holds to 1 through 20
/// and defaults to 5.
fn top_count(ctx: &Context) -> usize {
    ctx.config_json::<u64>(TOP_COUNT_SETTING)
        .and_then(|count| usize::try_from(count).ok())
        .filter(|count| (format::TOP_COUNT_MIN..=format::TOP_COUNT_MAX).contains(count))
        .unwrap_or(format::TOP_COUNT_DEFAULT)
}

/// The question a row asks: its process, by name and pid. The name is one
/// line and bounded, so the question always fits the host's alert.
fn prompt(process: &Process) -> String {
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
    let name = if name.len() > PROMPT_NAME_BYTES {
        let mut cut = String::new();
        for character in name.chars() {
            if cut.len() + character.len_utf8() > PROMPT_NAME_BYTES {
                break;
            }
            cut.push(character);
        }
        cut.push('…');
        cut
    } else {
        name
    };
    format!("Kill {name} (pid {})?", process.pid)
}

/// One row: the process name over its pid and resource shares; the pid is
/// also a search alias. Selecting it asks, then terminates that process.
/// Return acts on the row itself: several processes share a name, and a row
/// written onto the line as its name would stand for the first of them.
fn row(process: &Process, physical_memory: u64) -> Candidate {
    let memory_percent = process.resident_bytes as f64 / physical_memory.max(1) as f64 * 100.0;
    let title = if process.name.trim().is_empty() {
        format!("[{}]", process.pid)
    } else {
        process.name.clone()
    };
    Candidate::new(SOURCE, title)
        .kind("process")
        .subtitle(format!(
            "pid {} · {:.1}% CPU · {memory_percent:.1}% MEM",
            process.pid, process.cpu_percent
        ))
        .aliases([process.pid.to_string()])
        .payload(format!("{}:{}", process.pid, process.start_abstime))
        .confirm(prompt(process))
        .finishes_command(true)
}

/// A row's payload: the pid and the start time of its process.
fn row_identity(row: &Candidate) -> Option<(i32, u64)> {
    let (pid, start) = row.payload_str()?.split_once(':')?;
    Some((pid.parse().ok()?, start.parse().ok()?))
}

/// The pid `process kill --pid=<pid>` names: its one argument, which the
/// manifest declares as a required whole number from 2 and the host holds
/// every invocation to.
fn kill_pid(request: &CommandRequest) -> Option<i32> {
    request
        .integer("pid")
        .and_then(|pid| i32::try_from(pid).ok())
}

flash_plugin::plugin!(Processes);

impl FlashPlugin for Processes {
    async fn on_event(&self, ctx: Context, event: Event) {
        let sampler = self.sampler(&ctx);
        match event.name.as_str() {
            host_events::STATUS_OBSERVED => {
                if let Some(segments) = event.segments.as_deref() {
                    sampler.observe(&ctx, segments);
                }
            }
            host_events::FOCUS_CHANGED => sampler.focus_changed(&ctx, &event),
            // `core:apps.changed` only refreshes the app snapshot the
            // focused app's name is read from.
            _ => {}
        }
    }

    async fn on_search(&self, ctx: Context, request: SearchRequest) -> SearchResponse {
        if request.source != SOURCE {
            return SearchResponse::default();
        }
        if let Some(rows) = self.cached_rows() {
            return SearchResponse::rows(rows);
        }
        let physical_memory = self.table.machine().physical_memory();
        let rows: Vec<Candidate> = self
            .table
            .processes(&ctx)
            .await
            .iter()
            .map(|process| row(process, physical_memory))
            .collect();
        self.set_rows(Some(rows.clone()));
        SearchResponse::rows(rows)
    }

    async fn on_command(&self, ctx: Context, request: CommandRequest) -> PerformResponse {
        let name = request.name();
        if name != "process kill" {
            return PerformResponse::fail(format!("unknown command: {name}"));
        }
        match kill_pid(&request) {
            Some(pid) => self.kill(&ctx, pid, None).await,
            None => PerformResponse::fail(KILL_USAGE),
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        match row_identity(&row) {
            Some((pid, start)) => self.kill(&ctx, pid, Some(start)).await,
            None => PerformResponse::fail("unknown process row"),
        }
    }
}

fn main() {
    run(Processes::new(Arc::new(ThisMac)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::testing::FakeMachine;
    use crate::testing::Host;
    use flash_plugin::testing::WireHarness;
    use serde_json::{Value, json};

    const RAM: u64 = 1 << 30;

    fn manifest() -> Value {
        serde_json::from_str(include_str!("../manifest.json")).unwrap()
    }

    /// launchd, Safari and a shell.
    fn machine() -> Arc<FakeMachine> {
        let machine = Arc::new(FakeMachine::new(RAM));
        machine.spawn(1, 0, "/sbin/launchd", 1);
        machine.spawn(
            4242,
            1,
            "/Applications/Safari.app/Contents/MacOS/Safari",
            77,
        );
        machine.spawn(4300, 1, "/bin/zsh", 90);
        machine.update(4242, |process| process.usage.resident_bytes = RAM / 4);
        machine
    }

    fn plugin(machine: &Arc<FakeMachine>) -> Arc<Processes> {
        Arc::new(Processes::new(machine.clone()))
    }

    fn request(words: &str, args: &[&str]) -> CommandRequest {
        let (command, subcommand) = words.split_once(' ').unwrap();
        CommandRequest {
            command: command.to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            confirmed: true,
            ..CommandRequest::default()
        }
    }

    async fn search(plugin: &Arc<Processes>, host: &mut Host, source: &str) -> Vec<Candidate> {
        let (plugin, ctx) = (plugin.clone(), host.harness.context());
        let request = SearchRequest {
            source: source.to_string(),
            query: "saf".to_string(),
        };
        let task = tokio::spawn(async move { plugin.on_search(ctx, request).await });
        host.settle().await;
        task.await.unwrap().rows
    }

    async fn command(plugin: &Arc<Processes>, host: &mut Host, args: &[&str]) -> Value {
        let (plugin, ctx) = (plugin.clone(), host.harness.context());
        let request = request("process kill", args);
        let task = tokio::spawn(async move { plugin.on_command(ctx, request).await });
        host.settle().await;
        serde_json::to_value(task.await.unwrap()).unwrap()
    }

    async fn resolve(plugin: &Arc<Processes>, host: &mut Host, row: Candidate) -> Value {
        let (plugin, ctx) = (plugin.clone(), host.harness.context());
        let task = tokio::spawn(async move { plugin.on_resolve(ctx, row).await });
        host.settle().await;
        serde_json::to_value(task.await.unwrap()).unwrap()
    }

    /// The manifest declares exactly what the plugin serves.
    #[test]
    fn the_manifest_declares_the_values_the_source_the_command_and_the_capabilities() {
        let manifest = manifest();
        assert_eq!(
            manifest["commands"],
            json!([{
                "command": "process", "subcommand": "kill",
                "description": "Terminate one process, after asking",
                "confirm": "Kill this process?",
                "args": [{
                    "name": "pid", "type": "integer", "min": 2, "max": i32::MAX,
                    "required": true, "description": "The process to terminate"
                }]
            }])
        );
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SOURCE, "type": "processes", "live": "per_query" }])
        );
        assert_eq!(
            manifest["listen"],
            json!([
                host_events::STATUS_OBSERVED,
                host_events::FOCUS_CHANGED,
                host_events::APPS_CHANGED
            ])
        );
        assert_eq!(
            manifest["capabilities"],
            json!(["app_control", "process_signal", "process_table"])
        );
        assert!(manifest.get("sandbox").is_none(), "the default sandbox");
        let setting = &manifest["settings"][TOP_COUNT_SETTING];
        assert_eq!(setting["type"], "integer");
        assert_eq!(setting["default"], json!(format::TOP_COUNT_DEFAULT));
        assert_eq!(setting["min"], json!(format::TOP_COUNT_MIN));
        assert_eq!(setting["max"], json!(format::TOP_COUNT_MAX));
    }

    #[test]
    fn top_count_is_the_setting_the_host_resolved() {
        let machine = Arc::new(FakeMachine::new(RAM));
        let count = |config: Value| top_count(&Host::new(config, &machine).harness.context());
        assert_eq!(count(json!({ "top_count": 12 })), 12);
        assert_eq!(count(json!({ "top_count": 1 })), 1);
        assert_eq!(count(json!({})), 5);
        // The host sends none of these; a value it would is still bounded.
        assert_eq!(count(json!({ "top_count": 0 })), 5);
        assert_eq!(count(json!({ "top_count": 21 })), 5);
        assert_eq!(count(json!({ "top_count": "5" })), 5);
    }

    #[test]
    fn a_row_is_the_process_with_its_shares_its_identity_and_its_question() {
        let process = Process {
            pid: 4242,
            name: "Safari".into(),
            cpu_percent: 12.5,
            resident_bytes: RAM / 4,
            start_abstime: 77,
        };
        let row = row(&process, RAM);
        assert_eq!(row.source, SOURCE);
        assert_eq!(row.title, "Safari");
        assert_eq!(row.meta("kind"), Some("process"));
        assert_eq!(
            row.meta("subtitle"),
            Some("pid 4242 · 12.5% CPU · 25.0% MEM")
        );
        assert_eq!(row.meta("aliases"), Some("4242"), "the pid is searchable");
        assert_eq!(row.payload_str(), Some("4242:77"));
        assert_eq!(row.confirm.as_deref(), Some("Kill Safari (pid 4242)?"));
        assert_eq!(row_identity(&row), Some((4242, 77)));
        assert_eq!(
            row.meta("finishes_command"),
            Some("1"),
            "Return asks about this row, not the first process of its name"
        );

        // A name is one bounded line in the question, whatever it holds.
        let odd = Process {
            name: format!("bad\nname{}", "x".repeat(300)),
            ..process.clone()
        };
        let question = super::row(&odd, RAM).confirm.unwrap();
        assert!(question.starts_with("Kill bad?name"), "{question}");
        assert!(question.ends_with("… (pid 4242)?"), "{question}");
        assert!(question.len() <= 256, "{}", question.len());
        let wide = Process {
            name: "🦀".repeat(200),
            ..process.clone()
        };
        let question = super::row(&wide, RAM).confirm.unwrap();
        assert_eq!(question, format!("Kill {}… (pid 4242)?", "🦀".repeat(40)));
        assert!(question.len() <= 256, "{}", question.len());
        let nameless = Process {
            name: "  ".into(),
            ..process
        };
        assert_eq!(super::row(&nameless, RAM).title, "[4242]");
    }

    #[tokio::test]
    async fn a_search_lists_every_process_and_one_read_serves_two_seconds() {
        let machine = machine();
        let plugin = plugin(&machine);
        let mut host = Host::new(json!({}), &machine);
        let rows = search(&plugin, &mut host, SOURCE).await;
        assert_eq!(
            rows.iter()
                .map(|row| (row.title.as_str(), row.payload_str().unwrap()))
                .collect::<Vec<_>>(),
            [
                ("launchd", "1:1"),
                ("Safari", "4242:77"),
                ("zsh", "4300:90")
            ],
            "the kernel's order: the host ranks"
        );
        assert_eq!(
            rows[1].meta("subtitle"),
            Some("pid 4242 · 0.0% CPU · 25.0% MEM")
        );

        // The next keystroke reads nothing new.
        machine.spawn(4400, 1, "/usr/bin/top", 95);
        assert_eq!(search(&plugin, &mut host, SOURCE).await.len(), 3);
        // Another source is none of this plugin's.
        assert_eq!(search(&plugin, &mut host, "processes.other").await.len(), 0);
        // Once the read has aged out, the table is read afresh.
        plugin.set_rows(None);
        assert_eq!(search(&plugin, &mut host, SOURCE).await.len(), 4);
        assert_eq!(host.calls, [], "listing asks the host for the table alone");
        assert_eq!(
            host.reads,
            [
                json!({ "operation": "list" }),
                json!({ "operation": "list", "pids": [1, 4242, 4300] }),
                json!({ "operation": "list" }),
                json!({ "operation": "list", "pids": [4400] }),
            ],
            "one read per two seconds of typing, and a second for the pids it had not met"
        );
    }

    #[tokio::test]
    async fn the_command_asks_the_host_to_terminate_the_pid_it_names() {
        let machine = machine();
        let plugin = plugin(&machine);
        let mut host = Host::new(json!({}), &machine);
        assert_eq!(
            command(&plugin, &mut host, &["--pid=4242"]).await,
            json!({ "ok": true })
        );
        assert_eq!(
            host.calls,
            [(
                "host.process_signal".to_string(),
                json!({ "pid": 4242, "signal": "term" })
            )]
        );

        // The host's reason reaches the user as the command's failure, the
        // refusal of a perform the user did not confirm included.
        host.signal = Some(json!({ "ok": false, "error": "Operation not permitted" }));
        assert_eq!(
            command(&plugin, &mut host, &["--pid=4300"]).await,
            json!({ "ok": false, "error": "process kill failed: Operation not permitted" })
        );
        host.signal =
            Some(json!({ "ok": false, "error": flash_plugin::CONFIRMATION_REQUIRED_ERROR }));
        assert_eq!(
            command(&plugin, &mut host, &["--pid=4300"]).await,
            json!({
                "ok": false,
                "error": "process kill failed: requires a perform the user confirmed"
            })
        );
        assert_eq!(host.calls.len(), 3);
        assert_eq!(
            host.reads,
            Vec::<Value>::new(),
            "a named pid is not looked up"
        );
    }

    /// A pid that names no process is the kernel's to say: the host's
    /// `No such process` reads as the plugin's own words.
    #[tokio::test]
    async fn a_pid_that_names_no_process_says_so() {
        let machine = machine();
        let plugin = plugin(&machine);
        let mut host = Host::new(json!({}), &machine);
        assert_eq!(
            command(&plugin, &mut host, &["--pid=9999"]).await,
            json!({ "ok": false, "error": "no process with pid 9999" })
        );
        assert_eq!(
            host.calls,
            [(
                "host.process_signal".to_string(),
                json!({ "pid": 9999, "signal": "term" })
            )]
        );
    }

    /// The host holds `--pid` to its declaration, so none of these arrives
    /// from it; none reaches the host back either way.
    #[tokio::test]
    async fn a_missing_or_refused_pid_asks_the_host_nothing() {
        let machine = machine();
        let plugin = plugin(&machine);
        let mut host = Host::new(json!({}), &machine);
        for (args, error) in [
            (vec![], KILL_USAGE),
            (vec!["4242"], KILL_USAGE),
            (vec!["--pid="], KILL_USAGE),
            (vec!["--pid=safari"], KILL_USAGE),
            (vec!["--pid=99999999999"], KILL_USAGE),
            (vec!["--pid=-4242"], "refusing pid -4242"),
            (vec!["--pid=1"], "refusing pid 1"),
            (vec!["--pid=0"], "refusing pid 0"),
        ] {
            assert_eq!(
                command(&plugin, &mut host, &args).await,
                json!({ "ok": false, "error": error }),
                "{args:?}"
            );
        }
        let ctx = host.harness.context();
        let unknown = plugin.on_command(ctx, request("process list", &[])).await;
        assert_eq!(
            unknown.error_message(),
            Some("unknown command: process list")
        );
        assert_eq!(host.calls, [], "no signal asked");
        assert_eq!(host.reads, Vec::<Value>::new(), "and no process looked up");
    }

    #[tokio::test]
    async fn a_picked_row_terminates_the_process_it_listed_and_no_other() {
        let machine = machine();
        let plugin = plugin(&machine);
        let mut host = Host::new(json!({}), &machine);
        let rows = search(&plugin, &mut host, SOURCE).await;
        let safari = rows[1].clone();
        assert_eq!(
            resolve(&plugin, &mut host, safari.clone()).await,
            json!({ "ok": true })
        );
        assert_eq!(
            host.calls,
            [(
                "host.process_signal".to_string(),
                json!({ "pid": 4242, "signal": "term" })
            )]
        );
        // The row is about to go: the next query reads the table afresh.
        machine.exit(4242);
        assert_eq!(search(&plugin, &mut host, SOURCE).await.len(), 2);

        // The pid now names another process, started later: the question
        // the user answered was about the first one.
        machine.spawn(4242, 1, "/usr/bin/ssh-agent", 5_000);
        assert_eq!(
            resolve(&plugin, &mut host, safari.clone()).await,
            json!({ "ok": false, "error": "no process with pid 4242" })
        );
        machine.exit(4242);
        assert_eq!(
            resolve(&plugin, &mut host, safari).await,
            json!({ "ok": false, "error": "no process with pid 4242" })
        );
        assert_eq!(
            resolve(
                &plugin,
                &mut host,
                Candidate::new(SOURCE, "launchd").payload("1:1")
            )
            .await,
            json!({ "ok": false, "error": "refusing pid 1" })
        );
        assert_eq!(
            resolve(
                &plugin,
                &mut host,
                Candidate::new(SOURCE, "zsh").payload("4300")
            )
            .await,
            json!({ "ok": false, "error": "unknown process row" })
        );
        assert_eq!(host.calls.len(), 1, "only the first row reached the host");
    }

    /// Over the wire, through the generated routing: an observed table is
    /// published, a search answers rows without anything published as a
    /// catalog, and a confirmed row comes back to be terminated.
    #[tokio::test]
    async fn events_searches_and_resolves_reach_their_handlers() {
        /// The next frame that is neither a read of the process table,
        /// which the scripted Mac answers, nor a `poll`, whose deadlines
        /// land at once.
        async fn next(wire: &mut WireHarness, machine: &FakeMachine) -> Value {
            loop {
                let frame = wire.recv().await;
                if frame["method"] == "host.process_table" {
                    wire.send(json!({
                        "id": frame["id"], "result": machine.reply(&frame["params"])
                    }))
                    .await;
                    continue;
                }
                if frame["method"] != "poll" {
                    return frame;
                }
                let registrations = frame["params"]["registrations"].as_object().unwrap();
                for (name, registration) in registrations {
                    if registration.get("after").is_some() {
                        wire.send(json!({ "method": "event", "params": {
                            "name": format!("core:poll:{name}"), "payload": {}
                        }}))
                        .await;
                    }
                }
            }
        }

        let machine = machine();
        let mut wire =
            WireHarness::with_config(Processes::new(machine.clone()), json!({ "top_count": 1 }));
        wire.send(json!({ "id": 1, "method": "initialize", "params": { "protocol_version": 1 } }))
            .await;
        assert_eq!(wire.recv_response(1).await["ok"], true);

        wire.send(json!({ "method": "event", "params": {
            "name": "core:status.observed", "payload": { "segments": ["top_mem"] }
        }}))
        .await;
        let status = next(&mut wire, &machine).await;
        assert_eq!(status["method"], "status", "{status}");
        assert_eq!(
            status["params"]["segments"],
            json!({ "top_mem": "Safari            256 MiB" })
        );

        wire.send(json!({
            "id": 2, "method": "search", "deadline_ms": 1000,
            "params": { "source": SOURCE, "query": "" }
        }))
        .await;
        let reply = next(&mut wire, &machine).await;
        assert_eq!(reply["id"], 2, "{reply}");
        let listed = reply["result"]["rows"].as_array().unwrap().clone();
        assert_eq!(listed.len(), 3);
        assert_eq!(listed[1]["title"], "Safari");
        assert_eq!(listed[1]["confirm"], "Kill Safari (pid 4242)?");

        wire.send(json!({ "id": 3, "method": "perform", "params": {
            "kind": "resolve", "row": listed[1], "confirmed": true
        }}))
        .await;
        let call = next(&mut wire, &machine).await;
        assert_eq!(call["method"], "host.process_signal");
        assert_eq!(call["params"], json!({ "pid": 4242, "signal": "term" }));
        wire.send(json!({ "id": call["id"], "result": { "ok": true } }))
            .await;
        assert_eq!(wire.recv_response(3).await, json!({ "ok": true }));

        wire.send(json!({ "id": 4, "method": "perform", "params": {
            "kind": "command", "command": "process", "subcommand": "kill",
            "args": ["--pid=1"], "confirmed": true
        }}))
        .await;
        assert_eq!(
            wire.recv_response(4).await,
            json!({ "ok": false, "error": "refusing pid 1" })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }
}
