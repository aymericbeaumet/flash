//! VS Code plugin — the per-app AX-*enhancer* exemplar.
//!
//! The core AX walk already hints generic apps. This plugin exists to show
//! the enhancement pattern: a `hints` provider scoped by `only_bundle_ids`
//! at a priority above the core walk, whose `hints` handler snapshots the
//! focused app through the host AX broker and applies a *small, documented*
//! app-specific mapping from AX nodes to hint targets. `fallback_on_empty`
//! is true because applicability is dynamic — an empty result (broker
//! degraded, weird window) falls back to the core walk instead of leaving
//! the user hintless.
//!
//! ## Mapping table (keep it small)
//!
//! VS Code is Electron: the whole UI lives under an `AXWebArea`, with
//! Chromium's ARIA→AX mapping. What we hint:
//!
//! | AX role                                  | Why                                        |
//! |------------------------------------------|--------------------------------------------|
//! | `AXButton`, `AXPopUpButton`, `AXComboBox`| toolbars, title bar, panels                |
//! | `AXLink`                                 | markdown/welcome links (semantic `AXLink`) |
//! | `AXMenuItem`                             | open menus / context menus                 |
//! | `AXCheckBox`                             | settings toggles                           |
//! | `AXRadioButton`, `AXTab`, `AXTabButton`  | editor tab strip + activity bar (Chromium  |
//! |                                          | maps ARIA `tab` to these)                  |
//! | `AXStaticText` *inside* an `AXTabGroup`/ | tab-strip and activity-bar labels whose    |
//! | `AXToolbar` ancestor                     | clickable wrapper exposes no title itself  |
//!
//! Everything else — in particular the editor text area — is left to the
//! core walk. Geometry arrives from the broker in NSScreen coordinates
//! (bottom-left origin), the exact space `JumpTarget.frame` expects, so no
//! conversion happens here.

use flash_plugin::{run, Context, Frame, HintsRequest, HintsResponse, JumpTarget};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};

/// Broker walk bound. VS Code trees are deep; the broker's own default cap
/// is 3000 — stay under it and under the 2 s generic RPC deadline.
const MAX_SNAPSHOT_NODES: usize = 2_000;
const SNAPSHOT_TIMEOUT: Duration = Duration::from_millis(1_500);
/// Hint budget: more chips than this is unreadable anyway.
const MAX_TARGETS: usize = 200;
/// Size gate: smaller is decoration, larger is a container mislabeled as a
/// control (Electron loves giant clickable wrappers).
const MIN_TARGET_SIZE: f64 = 6.0;
const MAX_TARGET_WIDTH: f64 = 800.0;
const MAX_TARGET_HEIGHT: f64 = 120.0;
const MAX_LABEL_CHARS: usize = 120;

/// Roles hinted directly (see the module-level table).
const DIRECT_ROLES: [&str; 9] = [
    "AXButton",
    "AXPopUpButton",
    "AXComboBox",
    "AXLink",
    "AXMenuItem",
    "AXCheckBox",
    "AXRadioButton",
    "AXTab",
    "AXTabButton",
];
/// `AXStaticText` is hinted only under one of these ancestors.
const STATIC_TEXT_CONTAINER_ROLES: [&str; 2] = ["AXTabGroup", "AXToolbar"];
/// How far up the parent chain the static-text containment check walks.
const ANCESTOR_WALK_LIMIT: usize = 12;

/// One flat node from a `host.ax_snapshot` reply.
#[derive(Clone, Debug, Deserialize)]
struct AxNode {
    handle: u64,
    #[serde(default)]
    parent: Option<u64>,
    #[serde(default)]
    attrs: HashMap<String, String>,
    /// `[x, y, w, h]` in NSScreen coordinates (bottom-left origin).
    #[serde(default)]
    frame: Option<[f64; 4]>,
}

impl AxNode {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }

    fn role(&self) -> &str {
        self.attr("AXRole").unwrap_or("")
    }
}

struct Vscode;

flash_plugin::plugin!(Vscode);

impl FlashPlugin for Vscode {
    async fn on_hints(&self, ctx: Context, request: HintsRequest) -> HintsResponse {
        let Some(pid) = request.pid else {
            return HintsResponse::default();
        };
        let started_at = Instant::now();
        let value = ctx
            .ax_snapshot_timeout(
                json!({
                    "pid": pid,
                    "roots": "windows",
                    "collect": ["AXRole", "AXTitle", "AXDescription", "AXValue"],
                    // Skip inside-the-editor content: per-line text nodes are
                    // volume without targets. The row itself is still visited
                    // (and rejected by the mapping), only its subtree is cut.
                    "prune_roles": ["AXTextArea", "AXTextField"],
                    "max_nodes": MAX_SNAPSHOT_NODES,
                    "geometry": true,
                }),
                SNAPSHOT_TIMEOUT,
            )
            .await;
        let Some(nodes) = ax_nodes(&value) else {
            // Broker degraded: empty + fallback_on_empty hands the surface to
            // the core AX walk.
            log_discover(&ctx, "broker_failed", 0, started_at);
            return HintsResponse::default().context_pid(pid);
        };
        let targets = targets_from_nodes(&nodes, pid, request.front_window_frame);
        log_discover(&ctx, "ok", targets.len(), started_at);
        HintsResponse::targets(targets).context_pid(pid)
    }
}

/// Decode a broker reply; `None` when the call failed outright.
fn ax_nodes(value: &Value) -> Option<Vec<AxNode>> {
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    value
        .get("nodes")
        .cloned()
        .map(|nodes| serde_json::from_value(nodes).unwrap_or_default())
}

// ---------------------------------------------------------------------------
// Node → target mapping
// ---------------------------------------------------------------------------

/// The pure mapping: filter nodes through the role table, the size gate, the
/// window-frame intersection, and frame dedupe; shape survivors into
/// [`JumpTarget`]s.
fn targets_from_nodes(nodes: &[AxNode], pid: i64, window_frame: Option<Frame>) -> Vec<JumpTarget> {
    let by_handle: HashMap<u64, &AxNode> = nodes.iter().map(|node| (node.handle, node)).collect();
    let mut seen_frames: HashSet<(i64, i64, i64, i64)> = HashSet::new();
    let mut targets = Vec::new();
    for node in nodes {
        if targets.len() >= MAX_TARGETS {
            break;
        }
        if !role_is_hintable(node, &by_handle) {
            continue;
        }
        let Some(frame) = node.frame else {
            continue;
        };
        let frame = Frame::from_ax(frame);
        if !acceptable_size(&frame) || !intersects(&frame, window_frame.as_ref()) {
            continue;
        }
        // Electron wraps one visual control in several AX nodes at the same
        // rect; hint each rect once.
        let key = (
            frame.x.round() as i64,
            frame.y.round() as i64,
            frame.width.round() as i64,
            frame.height.round() as i64,
        );
        if !seen_frames.insert(key) {
            continue;
        }
        let mut target = JumpTarget::new(format!("vscode-{pid}-{}", node.handle), frame)
            .role(target_role(node))
            .pid(pid);
        if let Some(label) = label_for(node) {
            target = target.label(label);
        }
        targets.push(target);
    }
    targets
}

fn role_is_hintable(node: &AxNode, by_handle: &HashMap<u64, &AxNode>) -> bool {
    let role = node.role();
    if DIRECT_ROLES.contains(&role) {
        return true;
    }
    if role == "AXStaticText" {
        return has_container_ancestor(node, by_handle);
    }
    false
}

/// Walk the parent chain looking for a tab-strip/activity-bar container.
fn has_container_ancestor(node: &AxNode, by_handle: &HashMap<u64, &AxNode>) -> bool {
    let mut current = node.parent;
    for _ in 0..ANCESTOR_WALK_LIMIT {
        let Some(parent) = current.and_then(|handle| by_handle.get(&handle)) else {
            return false;
        };
        if STATIC_TEXT_CONTAINER_ROLES.contains(&parent.role()) {
            return true;
        }
        current = parent.parent;
    }
    false
}

/// Links keep the semantic `AXLink` role (native-style `f` handling); every
/// other role passes through and receives a plain click from the host.
fn target_role(node: &AxNode) -> String {
    node.role().to_string()
}

fn acceptable_size(frame: &Frame) -> bool {
    frame.width >= MIN_TARGET_SIZE
        && frame.height >= MIN_TARGET_SIZE
        && frame.width <= MAX_TARGET_WIDTH
        && frame.height <= MAX_TARGET_HEIGHT
}

/// Keep targets on the focused window (the discover request's frame). With
/// no frame supplied, keep everything the size gate admitted.
fn intersects(frame: &Frame, window: Option<&Frame>) -> bool {
    let Some(window) = window else {
        return true;
    };
    frame.x < window.x + window.width
        && frame.x + frame.width > window.x
        && frame.y < window.y + window.height
        && frame.y + frame.height > window.y
}

fn label_for(node: &AxNode) -> Option<String> {
    for attr in ["AXTitle", "AXDescription", "AXValue"] {
        if let Some(value) = node.attr(attr) {
            let value = value.trim();
            if !value.is_empty() {
                return Some(value.chars().take(MAX_LABEL_CHARS).collect());
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

fn log_discover(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[vscode] hints discover",
        BTreeMap::from([
            ("outcome".to_string(), outcome.to_string()),
            ("targets".to_string(), count.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
        ]),
    );
}

fn main() {
    run(Vscode);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Canned broker snapshot: the shape `host.ax_snapshot` returns for a
    /// VS Code window (flat nodes, `parent` handles, NSScreen frames).
    fn fixture_nodes() -> Vec<AxNode> {
        serde_json::from_value(json!([
            { "handle": 1, "attrs": { "AXRole": "AXWindow", "AXTitle": "main.rs — flash" },
              "frame": [0.0, 0.0, 1512.0, 950.0] },
            { "handle": 2, "parent": 1, "attrs": { "AXRole": "AXWebArea" },
              "frame": [0.0, 0.0, 1512.0, 950.0] },
            // Toolbar button with a title.
            { "handle": 3, "parent": 2, "attrs": { "AXRole": "AXButton", "AXTitle": "Run and Debug" },
              "frame": [10.0, 900.0, 32.0, 32.0] },
            // Semantic link (welcome page).
            { "handle": 4, "parent": 2, "attrs": { "AXRole": "AXLink", "AXTitle": "Open Folder" },
              "frame": [200.0, 500.0, 120.0, 20.0] },
            // Menu item from an open menu.
            { "handle": 5, "parent": 2, "attrs": { "AXRole": "AXMenuItem", "AXTitle": "Save All" },
              "frame": [50.0, 700.0, 180.0, 24.0] },
            // Editor tab (Chromium maps ARIA tab to AXRadioButton).
            { "handle": 6, "parent": 2, "attrs": { "AXRole": "AXRadioButton", "AXDescription": "main.rs" },
              "frame": [300.0, 910.0, 140.0, 34.0] },
            // Tab strip label: static text under an AXTabGroup ancestor.
            { "handle": 7, "parent": 2, "attrs": { "AXRole": "AXTabGroup" },
              "frame": [0.0, 905.0, 1512.0, 40.0] },
            { "handle": 8, "parent": 7, "attrs": { "AXRole": "AXGroup" },
              "frame": [450.0, 910.0, 140.0, 34.0] },
            { "handle": 9, "parent": 8, "attrs": { "AXRole": "AXStaticText", "AXValue": "lib.rs" },
              "frame": [455.0, 918.0, 60.0, 16.0] },
            // Static text NOT inside a container: excluded.
            { "handle": 10, "parent": 2, "attrs": { "AXRole": "AXStaticText", "AXValue": "Ln 42, Col 7" },
              "frame": [1200.0, 10.0, 90.0, 16.0] },
            // Oversized "button" wrapper: excluded by the size gate.
            { "handle": 11, "parent": 2, "attrs": { "AXRole": "AXButton", "AXTitle": "Giant wrapper" },
              "frame": [0.0, 0.0, 1512.0, 900.0] },
            // Tiny decoration: excluded.
            { "handle": 12, "parent": 2, "attrs": { "AXRole": "AXButton" },
              "frame": [90.0, 90.0, 3.0, 3.0] },
            // No geometry: excluded.
            { "handle": 13, "parent": 2, "attrs": { "AXRole": "AXButton", "AXTitle": "Ghost" } },
            // Same rect as handle 3 (Electron double-wrapping): deduped.
            { "handle": 14, "parent": 3, "attrs": { "AXRole": "AXButton", "AXTitle": "Run and Debug inner" },
              "frame": [10.0, 900.0, 32.0, 32.0] },
            // Outside the window frame: excluded.
            { "handle": 15, "parent": 2, "attrs": { "AXRole": "AXButton", "AXTitle": "Other display" },
              "frame": [-2000.0, 100.0, 40.0, 40.0] },
        ]))
        .unwrap()
    }

    fn window_frame() -> Frame {
        Frame::new(0.0, 0.0, 1512.0, 950.0)
    }

    #[test]
    fn mapping_keeps_the_documented_roles_and_drops_the_rest() {
        let targets = targets_from_nodes(&fixture_nodes(), 55, Some(window_frame()));
        let labels: Vec<&str> = targets
            .iter()
            .map(|target| target.label.as_deref().unwrap_or(""))
            .collect();
        assert_eq!(
            labels,
            vec![
                "Run and Debug",
                "Open Folder",
                "Save All",
                "main.rs",
                "lib.rs"
            ]
        );
    }

    #[test]
    fn links_keep_the_semantic_axlink_role_and_targets_carry_the_pid() {
        let targets = targets_from_nodes(&fixture_nodes(), 55, Some(window_frame()));
        let link = targets
            .iter()
            .find(|target| target.label.as_deref() == Some("Open Folder"))
            .unwrap();
        assert_eq!(link.role.as_deref(), Some("AXLink"));
        assert!(targets.iter().all(|target| target.pid == Some(55)));
        assert!(targets
            .iter()
            .all(|target| target.id.starts_with("vscode-55-")));
    }

    #[test]
    fn frames_pass_through_in_nsscreen_coordinates() {
        let targets = targets_from_nodes(&fixture_nodes(), 55, Some(window_frame()));
        let button = &targets[0];
        assert_eq!(
            (
                button.frame.x,
                button.frame.y,
                button.frame.width,
                button.frame.height
            ),
            (10.0, 900.0, 32.0, 32.0)
        );
    }

    #[test]
    fn duplicate_rects_are_hinted_once() {
        let targets = targets_from_nodes(&fixture_nodes(), 55, Some(window_frame()));
        let at_button_rect = targets
            .iter()
            .filter(|target| target.frame.x == 10.0 && target.frame.y == 900.0)
            .count();
        assert_eq!(at_button_rect, 1);
    }

    #[test]
    fn static_text_requires_a_tab_strip_or_toolbar_ancestor() {
        let nodes = fixture_nodes();
        let by_handle: HashMap<u64, &AxNode> =
            nodes.iter().map(|node| (node.handle, node)).collect();
        let inside = nodes.iter().find(|node| node.handle == 9).unwrap();
        let outside = nodes.iter().find(|node| node.handle == 10).unwrap();
        assert!(role_is_hintable(inside, &by_handle));
        assert!(!role_is_hintable(outside, &by_handle));
    }

    #[test]
    fn missing_window_frame_admits_all_size_gated_targets() {
        let targets = targets_from_nodes(&fixture_nodes(), 55, None);
        assert!(targets
            .iter()
            .any(|target| target.label.as_deref() == Some("Other display")));
    }

    #[test]
    fn failed_broker_replies_decode_to_none() {
        assert!(ax_nodes(&json!({ "ok": false, "error": "no ax" })).is_none());
        assert!(ax_nodes(&json!({})).is_none());
        assert_eq!(
            ax_nodes(&json!({ "ok": true, "nodes": [] })).unwrap().len(),
            0
        );
    }

    #[test]
    fn target_budget_is_enforced() {
        let mut nodes = Vec::new();
        for index in 0..(MAX_TARGETS + 50) {
            nodes.push(
                serde_json::from_value::<AxNode>(json!({
                    "handle": index as u64 + 1,
                    "attrs": { "AXRole": "AXButton", "AXTitle": format!("b{index}") },
                    "frame": [10.0 * index as f64, 10.0, 20.0, 20.0],
                }))
                .unwrap(),
            );
        }
        let targets = targets_from_nodes(&nodes, 1, None);
        assert_eq!(targets.len(), MAX_TARGETS);
    }
}
