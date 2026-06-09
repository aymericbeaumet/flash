use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, AxNode, Context, Plugin};

const SOURCE_ID: &str = "plugin.firefox";
const MAX_NODES: u64 = 3_000;
const FIREFOX: &str = "org.mozilla.firefox";
const FIREFOX_DEV: &str = "org.mozilla.firefoxdeveloperedition";

/// Attributes the AX broker reads for every visited node. The plugin — not the
/// core — decides which of these nodes is a tab and what its title/url are; the
/// broker just hands back a flat, batched view of the subtree.
const COLLECT: &[&str] = &[
    "AXRole",
    "AXSubrole",
    "AXRoleDescription",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXURL",
    "AXDocument",
];

struct Tab {
    handle: u64,
    title: String,
    url: String,
}

struct Firefox;

impl Plugin for Firefox {
    // Firefox is focused → re-walk its AX tree and republish the tab list.
    // The host gates *surfacing* these candidates on the active app (the
    // manifest's `bundle_ids`), so emitting whenever Firefox gains focus keeps
    // the snapshot fresh without leaking tabs while another app is active.
    async fn on_event(&self, ctx: Context, name: String, payload: Value) {
        if name != "focus.changed" {
            return;
        }
        let bundle = str_field(&payload, "bundle_id");
        if !is_firefox(bundle) {
            return;
        }
        let Some(pid) = payload.get("pid").and_then(Value::as_i64) else {
            return;
        };
        let source = source_name(bundle);
        let tabs = collect_tabs(&ctx, pid).await;
        let candidates = tabs
            .iter()
            .map(|tab| candidate(tab, &source, pid))
            .collect();
        ctx.emit_snapshot(SOURCE_ID, candidates);
    }

    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        match method.as_str() {
            "resolveCandidate" => resolve_candidate(&ctx, &params).await,
            "sourceAction" => source_action(&ctx, &params).await,
            other => json!({ "ok": false, "error": format!("unknown method: {other}") }),
        }
    }
}

fn is_firefox(bundle: &str) -> bool {
    bundle == FIREFOX || bundle == FIREFOX_DEV
}

fn source_name(bundle: &str) -> String {
    if bundle == FIREFOX_DEV {
        "firefox-dev".to_string()
    } else {
        "firefox".to_string()
    }
}

/// Walk Firefox's windows and extract the tab strip. Mirrors the heuristics the
/// old in-core `BrowserTabSources.axTabElements`/`axTabTitle`/`axTabURL` used:
/// a node is a tab when it is a radio button / button / tab whose subrole or
/// role-description marks it as a tab strip entry (or any `AXTab`).
async fn collect_tabs(ctx: &Context, pid: i64) -> Vec<Tab> {
    let nodes = ctx
        .ax_snapshot(pid, "windows", &[], COLLECT, MAX_NODES, false)
        .await;
    let window_titles = window_titles(&nodes);
    let mut tabs = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for node in &nodes {
        if !is_tab(node) {
            continue;
        }
        let fallback = window_titles
            .get(node.root)
            .map(String::as_str)
            .unwrap_or("");
        let Some(title) = tab_title(node, fallback) else {
            continue;
        };
        let url = tab_url(node);
        let key = format!("{}|{title}|{url}", node.root);
        if !seen.insert(key) {
            continue;
        }
        tabs.push(Tab {
            handle: node.handle,
            title,
            url,
        });
    }
    tabs
}

/// Window title per root index, taken from the `AXWindow` node the broker emits
/// as the first node of each root. Used as a tab-title fallback.
fn window_titles(nodes: &[AxNode]) -> Vec<String> {
    let mut titles: Vec<String> = Vec::new();
    for node in nodes {
        if node.attr("AXRole") == Some("AXWindow") {
            if node.root >= titles.len() {
                titles.resize(node.root + 1, String::new());
            }
            titles[node.root] = node.attr("AXTitle").unwrap_or("").to_string();
        }
    }
    titles
}

fn is_tab(node: &AxNode) -> bool {
    let role = node.attr("AXRole").unwrap_or("");
    if role == "AXTab" {
        return true;
    }
    let subrole = node.attr("AXSubrole").unwrap_or("");
    let role_desc = node.attr("AXRoleDescription").unwrap_or("").to_lowercase();
    let is_tab_button =
        subrole == "AXTabButton" || role_desc == "tab" || role_desc.contains("tab button");
    matches!(role, "AXRadioButton" | "AXButton") && is_tab_button
}

fn tab_title(node: &AxNode, fallback: &str) -> Option<String> {
    let raw = node
        .attr("AXTitle")
        .or_else(|| node.attr("AXDescription"))
        .or_else(|| node.attr("AXValue"))
        .unwrap_or(fallback);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn tab_url(node: &AxNode) -> String {
    node.attr("AXURL")
        .or_else(|| node.attr("AXDocument"))
        .unwrap_or("")
        .trim()
        .to_string()
}

/// One flashlight candidate for a tab. `source` drives both the browser-tab
/// precedence tier and the `@firefox` source filter; `payload` carries the url
/// so resolution can re-match the tab after a fresh snapshot.
fn candidate(tab: &Tab, source: &str, pid: i64) -> Value {
    let name = if tab.title.is_empty() {
        tab.url.clone()
    } else {
        tab.title.clone()
    };
    let mut value = json!({
        "kind": "browser_tab",
        "source_id": SOURCE_ID,
        "source": source,
        "name": name,
        "subtitle": "browser tab",
        "pid": pid,
        "payload": tab.url,
    });
    if !tab.url.is_empty() {
        value["url"] = json!(tab.url);
    }
    value
}

/// Resolve a flashlight pick: raise Firefox, then press the matching tab. The
/// candidate's handle from emit time may be stale (any later snapshot for the
/// pid supersedes it), so re-snapshot and match by url, then title, before
/// pressing. Falls back to `AXSelected = true` when `AXPress` is unsupported.
async fn resolve_candidate(ctx: &Context, params: &Value) -> Value {
    let candidate = params
        .get("candidate")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let Some(pid) = candidate.get("pid").and_then(Value::as_i64) else {
        return json!({ "did_resolve": false });
    };
    ctx.ax_activate(pid).await;
    let url = str_field(&candidate, "url");
    let name = str_field(&candidate, "name");
    let tabs = collect_tabs(ctx, pid).await;
    let target = tabs
        .iter()
        .find(|tab| !url.is_empty() && tab.url == url)
        .or_else(|| tabs.iter().find(|tab| tab.title == name));
    let Some(target) = target else {
        // App was still raised; report resolved so Flash keeps Firefox front.
        return json!({ "did_resolve": true, "target_pid": pid });
    };
    press(ctx, target.handle).await;
    json!({ "did_resolve": true, "target_pid": pid })
}

/// `tab_select` (numbered-tab jump): press the Nth tab in document order within
/// the first window that has at least that many tabs. Ports the old
/// `FirefoxTabsSource.tabSelect` semantics.
async fn source_action(ctx: &Context, params: &Value) -> Value {
    if str_field(params, "name") != "tab_select" {
        return json!({ "did_perform": false });
    }
    let index = params.get("index").and_then(Value::as_i64).unwrap_or(0);
    let pid = params
        .get("context")
        .and_then(|c| c.get("pid"))
        .and_then(Value::as_i64);
    let (Some(pid), true) = (pid, index > 0) else {
        return json!({ "did_perform": false });
    };
    ctx.ax_activate(pid).await;
    let tabs = collect_tabs(ctx, pid).await;
    let Some(target) = tabs.get((index - 1) as usize) else {
        return json!({ "did_perform": false });
    };
    let ok = press(ctx, target.handle).await;
    json!({ "did_perform": ok, "target_pid": pid })
}

/// Press a tab handle, falling back to selecting it when the element exposes no
/// press action.
async fn press(ctx: &Context, handle: u64) -> bool {
    if ctx.ax_perform(handle, "AXPress").await {
        return true;
    }
    ctx.ax_set(handle, "AXSelected", json!(true)).await
}

fn main() {
    run(Firefox);
}
