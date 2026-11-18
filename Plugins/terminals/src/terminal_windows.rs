//! Terminal windows through the host Accessibility broker: lookup by title,
//! focus and raise.

use std::collections::{BTreeMap, HashMap};

use flash_plugin::Context;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::clients::TmuxClient;
use crate::processes::find_top_level_ancestor;

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct AxWindowNode {
    pub(crate) handle: u64,
    #[serde(default)]
    pub(crate) attrs: HashMap<String, String>,
}

fn ax_window_nodes(value: &Value) -> Vec<AxWindowNode> {
    if !value.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        return Vec::new();
    }
    value
        .get("nodes")
        .cloned()
        .and_then(|nodes| serde_json::from_value(nodes).ok())
        .unwrap_or_default()
}

pub(crate) fn focused_window_from_nodes(nodes: &[AxWindowNode]) -> Option<&AxWindowNode> {
    nodes
        .iter()
        .find(|node| {
            node.attrs.get("AXFocused").map(String::as_str) == Some("1")
                || node.attrs.get("AXMain").map(String::as_str) == Some("1")
        })
        .or_else(|| nodes.first())
}

fn focused_window_title_from_nodes(nodes: &[AxWindowNode]) -> Option<&str> {
    focused_window_from_nodes(nodes)
        .and_then(|node| node.attrs.get("AXTitle"))
        .map(String::as_str)
}

pub(crate) fn window_handle_for_title(nodes: &[AxWindowNode], title: &str) -> Option<u64> {
    nodes
        .iter()
        .find(|node| node.attrs.get("AXTitle").map(String::as_str) == Some(title))
        .map(|node| node.handle)
}

pub(crate) async fn terminal_window_nodes(ctx: &Context, pid: i64) -> Vec<AxWindowNode> {
    let value = ctx
        .ax_snapshot(json!({
            "pid": pid,
            "follow": ["AXFlashNoChildren"],
            "collect": ["AXTitle", "AXFocused", "AXMain"],
            "max_nodes": 64,
        }))
        .await;
    ax_window_nodes(&value)
}

pub(crate) async fn focused_terminal_window_title(ctx: &Context, pid: i64) -> Option<String> {
    let nodes = terminal_window_nodes(ctx, pid).await;
    focused_window_title_from_nodes(&nodes).map(str::to_string)
}

async fn raise_terminal_window_handle(ctx: &Context, pid: i64, handle: u64) -> bool {
    // Discovery already resolved the exact AX window. Activating the app and
    // raising/focusing that cached handle in one host wave keeps a warm remote
    // jump off the AX snapshot path entirely.
    let (activated, raised, main, focused) = tokio::join!(
        ctx.activate(pid),
        ctx.ax_perform(handle, "AXRaise"),
        ctx.ax_set(handle, "AXMain", true),
        ctx.ax_set(handle, "AXFocused", true),
    );
    activated && (raised || main || focused)
}

pub(crate) async fn raise_terminal_window(
    ctx: &Context,
    pid: i64,
    cached_handle: Option<u64>,
    title: &str,
) -> bool {
    if pid <= 0 {
        return false;
    }
    if let Some(handle) = cached_handle
        && raise_terminal_window_handle(ctx, pid, handle).await
    {
        return true;
    }
    // AX handles expire when a terminal window is recreated. Fall through
    // to the title lookup once so stale discovery heals transparently.
    if title.is_empty() {
        return ctx.activate(pid).await;
    }
    // App activation and the AX lookup are independent. This is the cold/stale
    // fallback; warm candidates use the cached handle above.
    let (activated, nodes) = tokio::join!(ctx.activate(pid), terminal_window_nodes(ctx, pid));
    let Some(handle) = window_handle_for_title(&nodes, title) else {
        return activated;
    };
    // Raising, making main, and making focused are likewise independent AX
    // mutations on the same already-resolved window.
    let (raised, main, focused) = tokio::join!(
        ctx.ax_perform(handle, "AXRaise"),
        ctx.ax_set(handle, "AXMain", true),
        ctx.ax_set(handle, "AXFocused", true),
    );
    activated && (raised || main || focused)
}

fn local_window_title_score(title: &str, session: &str, local_label: &str) -> usize {
    let title = title.to_ascii_lowercase();
    let session = session.to_ascii_lowercase();
    let local_label = local_label.to_ascii_lowercase();
    let mut score = 0;
    if !local_label.is_empty() && title.contains(&local_label) {
        score += 4;
    }
    if !session.is_empty() && title.contains(&session) {
        score += 2;
    }
    score
}

pub(crate) async fn discover_local_client_windows(
    ctx: &Context,
    clients: &[TmuxClient],
    parent_map: &HashMap<i64, i64>,
    local_label: &str,
) -> (HashMap<i64, String>, HashMap<i64, u64>) {
    let mut clients_by_terminal: BTreeMap<i64, Vec<&TmuxClient>> = BTreeMap::new();
    for client in clients {
        if let Some(terminal_pid) = find_top_level_ancestor(client.client_pid, parent_map) {
            clients_by_terminal
                .entry(terminal_pid)
                .or_default()
                .push(client);
        }
    }
    let mut resolved_titles = HashMap::new();
    let mut resolved_handles = HashMap::new();
    for (terminal_pid, mut hosted_clients) in clients_by_terminal {
        let mut windows = terminal_window_nodes(ctx, terminal_pid).await;
        hosted_clients.sort_by_key(|client| std::cmp::Reverse(client.activity));
        for client in hosted_clients {
            let best = windows
                .iter()
                .enumerate()
                .map(|(index, node)| {
                    let title = node.attrs.get("AXTitle").map(String::as_str).unwrap_or("");
                    (
                        index,
                        local_window_title_score(title, &client.session, local_label),
                    )
                })
                .max_by_key(|(_, score)| *score);
            let Some((index, score)) = best else {
                continue;
            };
            if score == 0 && windows.len() != 1 {
                continue;
            }
            let node = windows.remove(index);
            if let Some(title) = node.attrs.get("AXTitle").filter(|title| !title.is_empty()) {
                resolved_titles.insert(client.client_pid, title.clone());
                resolved_handles.insert(client.client_pid, node.handle);
            }
        }
    }
    (resolved_titles, resolved_handles)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::remote::terminal_title_for_host;

    #[test]
    fn focused_and_named_terminal_windows_are_resolved_independently() {
        let nodes = vec![
            AxWindowNode {
                handle: 11,
                attrs: HashMap::from([
                    ("AXTitle".to_string(), "scratch@macbook".to_string()),
                    ("AXFocused".to_string(), "0".to_string()),
                ]),
            },
            AxWindowNode {
                handle: 22,
                attrs: HashMap::from([
                    ("AXTitle".to_string(), "scratch@moria.zone".to_string()),
                    ("AXFocused".to_string(), "1".to_string()),
                ]),
            },
        ];

        assert_eq!(
            focused_window_title_from_nodes(&nodes),
            Some("scratch@moria.zone")
        );
        assert_eq!(window_handle_for_title(&nodes, "scratch@macbook"), Some(11));
        assert_eq!(
            window_handle_for_title(&nodes, "scratch@moria.zone"),
            Some(22)
        );
    }

    #[test]
    fn terminal_title_matching_uses_host_without_terminal_brand_assumptions() {
        let nodes = vec![
            AxWindowNode {
                handle: 1,
                attrs: HashMap::from([("AXTitle".to_string(), "scratch@macbook".to_string())]),
            },
            AxWindowNode {
                handle: 2,
                attrs: HashMap::from([("AXTitle".to_string(), "scratch@moria.zone".to_string())]),
            },
        ];

        assert_eq!(
            terminal_title_for_host(&nodes, "ab@moria.zone"),
            "scratch@moria.zone"
        );
        assert!(
            local_window_title_score("scratch@macbook", "scratch", "macbook")
                > local_window_title_score("scratch@moria.zone", "scratch", "macbook")
        );
    }
}
