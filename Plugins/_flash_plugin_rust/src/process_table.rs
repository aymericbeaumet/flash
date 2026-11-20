//! The process table (`host.process_table`): libproc stays in the resident,
//! and a plugin holding the `process_table` capability reads every process
//! the user may measure, some of them, or one process's tree through these
//! typed calls. No sandbox profile lets a plugin read another process
//! itself.
//!
//! A process is its pid, its start, its CPU time and its resident memory,
//! and its executable's name when it is asked for by pid or belongs to a
//! tree; a tree adds each process's thread and socket counts and disk I/O,
//! and the root's path and start time. Nothing else of a process crosses
//! the wire: the host never reads its arguments or its environment.
//!
//! CPU use is a delta the plugin computes: every reply carries `at`, the
//! host's monotonic clock when it read, so the share between two reads is
//! the CPU time gained over the difference of their `at`.

use serde_json::{Value, json};

use crate::context::Context;

const METHOD: &str = "host.process_table";

/// Every `operation` of `host.process_table` (`protocol.json`
/// `process_table.operations`).
#[cfg(test)]
pub(crate) const OPERATIONS: [&str; 2] = ["list", "tree"];

/// The most pids one [`Context::processes`] names
/// (`process_table.max_pids`).
pub const MAX_PROCESS_PIDS: usize = 4_096;

/// One process of a list (`protocol.json` `process`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessEntry {
    pub pid: i32,
    /// When it started, in Mach absolute time: with the pid, the identity
    /// of one process, which a reused pid does not share.
    pub start: u64,
    /// Cumulative user and system CPU time, in nanoseconds.
    pub cpu_ns: u64,
    pub resident_bytes: u64,
    /// The last component of its executable's path, when the kernel names
    /// one: in a list of pids and in a tree, never in a list of the whole
    /// table.
    pub name: Option<String>,
}

/// One process of a tree: a [`ProcessEntry`] and its detail
/// (`process.process_detail`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeProcess {
    pub process: ProcessEntry,
    pub threads: u64,
    /// Open socket descriptors, unix-domain ones included.
    pub sockets: u64,
    /// Cumulative.
    pub disk_read_bytes: u64,
    pub disk_write_bytes: u64,
}

/// What one `list` read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProcessList {
    /// The host's monotonic clock when it read, in nanoseconds.
    pub at: u64,
    /// In the kernel's order, or the order asked.
    pub processes: Vec<ProcessEntry>,
    /// The host left later processes out of the reply
    /// (`process_table.max_processes`, `reply_bytes`).
    pub truncated: bool,
}

/// What one `tree` read: the root first, then every descendant reachable
/// then, breadth first. No process at all when the root is gone or not the
/// user's to measure.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProcessTree {
    pub at: u64,
    pub processes: Vec<TreeProcess>,
    /// The root's executable.
    pub path: Option<String>,
    /// When the root started, in Unix seconds.
    pub started_at: Option<u64>,
    pub truncated: bool,
}

fn failure(response: &Value) -> Option<String> {
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    Some(
        response
            .get("error")
            .and_then(Value::as_str)
            .filter(|error| !error.is_empty())
            .unwrap_or("host.process_table failed")
            .to_string(),
    )
}

fn entry_from_value(value: &Value) -> Option<ProcessEntry> {
    let count = |key: &str| value.get(key)?.as_u64();
    let name = match value.get("name") {
        None | Some(Value::Null) => None,
        Some(name) => Some(name.as_str()?.to_string()),
    };
    Some(ProcessEntry {
        pid: i32::try_from(count("pid")?).ok().filter(|pid| *pid > 0)?,
        start: count("start")?,
        cpu_ns: count("cpu_ns")?,
        resident_bytes: count("resident_bytes")?,
        name,
    })
}

fn tree_process_from_value(value: &Value) -> Option<TreeProcess> {
    let count = |key: &str| value.get(key)?.as_u64();
    Some(TreeProcess {
        process: entry_from_value(value)?,
        threads: count("threads")?,
        sockets: count("sockets")?,
        disk_read_bytes: count("disk_read_bytes")?,
        disk_write_bytes: count("disk_write_bytes")?,
    })
}

/// The `at`, the processes and the `truncated` of a successful reply; one
/// malformed process refuses them all.
fn snapshot<T>(
    response: &Value,
    process: fn(&Value) -> Option<T>,
) -> Result<(u64, Vec<T>, bool), String> {
    if let Some(error) = failure(response) {
        return Err(error);
    }
    let at = response
        .get("at")
        .and_then(Value::as_u64)
        .ok_or_else(|| "host.process_table response missing at".to_string())?;
    let processes = response
        .get("processes")
        .and_then(Value::as_array)
        .ok_or_else(|| "host.process_table response missing processes".to_string())?
        .iter()
        .map(process)
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| "host.process_table response has a malformed process".to_string())?;
    let truncated = response.get("truncated").and_then(Value::as_bool) == Some(true);
    Ok((at, processes, truncated))
}

/// A `list` reply.
pub(crate) fn list_from_response(response: &Value) -> Result<ProcessList, String> {
    let (at, processes, truncated) = snapshot(response, entry_from_value)?;
    Ok(ProcessList {
        at,
        processes,
        truncated,
    })
}

/// A `tree` reply.
pub(crate) fn tree_from_response(response: &Value) -> Result<ProcessTree, String> {
    let (at, processes, truncated) = snapshot(response, tree_process_from_value)?;
    Ok(ProcessTree {
        at,
        processes,
        path: response
            .get("path")
            .and_then(Value::as_str)
            .filter(|path| !path.is_empty())
            .map(str::to_string),
        started_at: response.get("started_at").and_then(Value::as_u64),
        truncated,
    })
}

impl Context {
    /// The figures of every process the user may measure, in the kernel's
    /// order, without names (`host.process_table` `list`); with `pids`, at
    /// most [`MAX_PROCESS_PIDS`] distinct ones, only those, in that order,
    /// each with its name, a pid that is gone left out. A name costs the
    /// kernel a path lookup, so sweep the table without them and name a
    /// process once, by pid. Requires the `process_table` capability, as
    /// [`process_tree`](Self::process_tree) does.
    pub async fn processes(&self, pids: Option<&[i32]>) -> Result<ProcessList, String> {
        let mut params = json!({ "operation": "list" });
        if let Some(pids) = pids {
            params["pids"] = json!(pids);
        }
        list_from_response(&self.call_host(METHOD, params).await)
    }

    /// The process `pid` and every descendant reachable from it now, each
    /// with its thread and socket counts and disk I/O, and the root's
    /// executable path and start time (`tree`).
    pub async fn process_tree(&self, pid: i32) -> Result<ProcessTree, String> {
        let params = json!({ "operation": "tree", "pid": pid });
        tree_from_response(&self.call_host(METHOD, params).await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;

    fn safari() -> Value {
        json!({
            "pid": 4242, "start": 77_000, "cpu_ns": 1_500_000_000u64,
            "resident_bytes": 268_435_456u64, "name": "Safari",
        })
    }

    fn detailed(mut process: Value) -> Value {
        let detail = json!({
            "threads": 12, "sockets": 3, "disk_read_bytes": 4096, "disk_write_bytes": 8192,
        });
        for (key, value) in detail.as_object().unwrap() {
            process[key] = value.clone();
        }
        process
    }

    #[test]
    fn a_list_decodes_whole_or_not_at_all() {
        let nameless = json!({ "pid": 4301, "start": 91_000, "cpu_ns": 0, "resident_bytes": 1 });
        let reply =
            json!({ "ok": true, "at": 90_000_000_000u64, "processes": [safari(), nameless] });
        let list = list_from_response(&reply).unwrap();
        assert_eq!(list.at, 90_000_000_000);
        assert!(!list.truncated);
        assert_eq!(
            list.processes[0],
            ProcessEntry {
                pid: 4242,
                start: 77_000,
                cpu_ns: 1_500_000_000,
                resident_bytes: 268_435_456,
                name: Some("Safari".into()),
            }
        );
        assert_eq!(list.processes[1].name, None);
        assert_eq!(
            list_from_response(&json!({ "ok": true, "at": 1, "processes": [], "truncated": true })),
            Ok(ProcessList {
                at: 1,
                processes: Vec::new(),
                truncated: true
            })
        );
        // A key the host never sends is not read.
        let mut extra = safari();
        extra["arguments"] = json!(["--private"]);
        let reply = json!({ "ok": true, "at": 1, "processes": [extra] });
        assert_eq!(
            list_from_response(&reply).unwrap().processes,
            [list.processes[0].clone()]
        );

        let malformed = |change: fn(&mut Value)| {
            let mut process = safari();
            change(&mut process);
            list_from_response(&json!({ "ok": true, "at": 1, "processes": [process] }))
        };
        for change in [
            (|process| process["pid"] = json!("4242")) as fn(&mut Value),
            |process| process["pid"] = json!(0),
            |process| process["pid"] = json!(-4242),
            |process| process["pid"] = json!(4_294_967_296u64),
            |process| {
                process.as_object_mut().unwrap().remove("start");
            },
            |process| process["cpu_ns"] = json!(1.5),
            |process| process["resident_bytes"] = json!(-1),
            |process| process["name"] = json!(["Safari"]),
        ] {
            assert_eq!(
                malformed(change),
                Err("host.process_table response has a malformed process".to_string())
            );
        }
        assert_eq!(
            list_from_response(&json!({ "ok": true, "at": 1 })),
            Err("host.process_table response missing processes".to_string())
        );
        assert_eq!(
            list_from_response(&json!({ "ok": true, "processes": [] })),
            Err("host.process_table response missing at".to_string())
        );
        assert_eq!(
            list_from_response(&json!({ "ok": false, "error": "process table unavailable" })),
            Err("process table unavailable".to_string())
        );
        assert_eq!(
            list_from_response(&json!({ "ok": false })),
            Err("host.process_table failed".to_string())
        );
    }

    #[test]
    fn a_tree_is_its_processes_with_their_detail_and_the_roots_path() {
        let reply = json!({
            "ok": true, "at": 5, "processes": [detailed(safari())],
            "path": "/Applications/Safari.app/Contents/MacOS/Safari", "started_at": 1_799_996_400,
        });
        let tree = tree_from_response(&reply).unwrap();
        assert_eq!(tree.at, 5);
        assert_eq!(
            tree.path.as_deref(),
            Some("/Applications/Safari.app/Contents/MacOS/Safari")
        );
        assert_eq!(tree.started_at, Some(1_799_996_400));
        let root = &tree.processes[0];
        assert_eq!(root.process.pid, 4242);
        assert_eq!(
            (
                root.threads,
                root.sockets,
                root.disk_read_bytes,
                root.disk_write_bytes
            ),
            (12, 3, 4096, 8192)
        );
        // Gone: no process, no path.
        assert_eq!(
            tree_from_response(&json!({ "ok": true, "at": 5, "processes": [] })),
            Ok(ProcessTree {
                at: 5,
                ..ProcessTree::default()
            })
        );
        // A tree's process without its detail is malformed.
        assert_eq!(
            tree_from_response(&json!({ "ok": true, "at": 5, "processes": [safari()] })),
            Err("host.process_table response has a malformed process".to_string())
        );
    }

    #[tokio::test]
    async fn a_read_names_its_operation_and_its_pids() {
        let mut harness = Harness::new("processes");
        for (pids, sent) in [
            (None, json!({ "operation": "list" })),
            (
                Some(vec![4300, 9999]),
                json!({ "operation": "list", "pids": [4300, 9999] }),
            ),
            (Some(Vec::new()), json!({ "operation": "list", "pids": [] })),
        ] {
            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.processes(pids.as_deref()).await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, METHOD);
            assert_eq!(params, sent);
            assert!(harness.reply_host(id, json!({ "ok": true, "at": 7, "processes": [] })));
            assert_eq!(task.await.unwrap().map(|list| list.at), Ok(7));
        }
        let ctx = harness.context();
        let task = tokio::spawn(async move { ctx.process_tree(4242).await });
        let (id, method, params) = harness.next_host_request().await.unwrap();
        assert_eq!(method, METHOD);
        assert_eq!(params, json!({ "operation": "tree", "pid": 4242 }));
        assert!(harness.reply_host(
            id,
            json!({ "ok": false, "error": "missing process_table capability" })
        ));
        assert_eq!(
            task.await.unwrap(),
            Err("missing process_table capability".to_string())
        );
    }

    #[test]
    fn the_process_table_contract_matches_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let table = &contract["process_table"];
        assert_eq!(table["operations"], json!(OPERATIONS));
        assert_eq!(table["max_pids"], MAX_PROCESS_PIDS);
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"][METHOD],
            "process_table"
        );
        let capabilities = contract["capabilities"].as_array().unwrap();
        assert!(capabilities.contains(&Value::from("process_table")));
        assert!(
            !capabilities.contains(&Value::from("process_info")),
            "no capability opens another process to a plugin's own reads"
        );
        // Every key of the process shape is one these decoders read, and
        // there is no other.
        let mut keys: Vec<String> = ["required", "optional", "process_detail"]
            .iter()
            .flat_map(|group| contract["process"][group].as_array().unwrap())
            .map(|key| key.as_str().unwrap().to_string())
            .collect();
        keys.sort();
        let mut read: Vec<String> = detailed(safari())
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        read.sort();
        assert_eq!(keys, read);
    }
}
