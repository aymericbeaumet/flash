//! Thin client over the host's Accessibility broker (`host.ax_*`, the
//! `accessibility` capability). The broker walks a subtree and hands back
//! flat nodes with opaque handles; which nodes are tabs is the caller's call.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, LazyLock, Mutex, Weak};

use flash_plugin::Context;
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct AxNode {
    pub handle: u64,
    pub parent: Option<u64>,
    /// Index of the `AXWindows` root this node was reached from.
    pub root: usize,
    pub attrs: BTreeMap<String, String>,
}

impl AxNode {
    fn from_value(value: &Value) -> Option<Self> {
        let handle = value.get("handle")?.as_u64()?;
        let parent = value.get("parent").and_then(Value::as_u64);
        let root = value.get("root").and_then(Value::as_u64).unwrap_or(0) as usize;
        let attrs = value
            .get("attrs")
            .and_then(Value::as_object)
            .map(|map| {
                map.iter()
                    .filter_map(|(key, value)| value.as_str().map(|s| (key.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self {
            handle,
            parent,
            root,
            attrs,
        })
    }

    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }

    /// Boolean attributes arrive as `NSNumber` strings (`"1"` / `"0"`).
    pub fn flag(&self, name: &str) -> bool {
        matches!(
            self.attr(name).map(str::to_ascii_lowercase).as_deref(),
            Some("1" | "true" | "yes")
        )
    }
}

/// Walk `pid`'s `AXWindows` breadth-first, reading `collect` on every node
/// and not descending below `prune_roles`. `None` when the broker refuses
/// (no grant, app gone, timeout): a failed walk, not an empty one.
pub async fn snapshot(
    ctx: &Context,
    pid: i64,
    collect: &[&str],
    max_nodes: u64,
    prune_roles: &[&str],
) -> Option<Vec<AxNode>> {
    let result = ctx
        .ax_snapshot(json!({
            "pid": pid,
            "roots": "windows",
            "follow": [],
            "collect": collect,
            "max_nodes": max_nodes,
            "geometry": false,
            "prune_roles": prune_roles,
        }))
        .await;
    if !result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        ctx.log(
            "warn",
            &format!(
                "[browsers] host.ax_snapshot failed pid={pid} error={}",
                result
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
            ),
        );
        return None;
    }
    Some(
        result
            .get("nodes")
            .and_then(Value::as_array)
            .map(|nodes| nodes.iter().filter_map(AxNode::from_value).collect())
            .unwrap_or_default(),
    )
}

/// Per-pid AX session lock. The broker purges a pid's handles at the start of
/// every `host.ax_snapshot`, so a snapshot and the presses that use its
/// handles must never interleave with another snapshot of the same pid.
/// Different pids have independent handle tables and run concurrently.
static SESSIONS: LazyLock<Mutex<HashMap<i64, Weak<tokio::sync::Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub fn session(pid: i64) -> Arc<tokio::sync::Mutex<()>> {
    let mut sessions = SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    sessions.retain(|_, session| session.strong_count() > 0);
    if let Some(session) = sessions.get(&pid).and_then(Weak::upgrade) {
        return session;
    }
    let session = Arc::new(tokio::sync::Mutex::new(()));
    sessions.insert(pid, Arc::downgrade(&session));
    session
}
