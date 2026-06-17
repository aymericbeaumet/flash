use std::collections::BTreeMap;

use flash_plugin::{
    run, Candidate, Context, Event, ResolveResponse, SourceActionRequest, SourceActionResponse,
};
use serde_json::{json, Value};

const SOURCE_ID: &str = "plugin:firefox";
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

flash_plugin::plugin!(Firefox);

impl FlashPlugin for Firefox {
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.snapshot" => {
                let apps = event
                    .running_applications
                    .iter()
                    .filter(|app| is_firefox(&app.bundle_id))
                    .map(|app| (app.bundle_id.clone(), app.pid))
                    .collect::<Vec<_>>();
                refresh_snapshot(&ctx, apps).await;
            }
            "core:focus.changed" | "core:ax.changed" => {
                let bundle = event.bundle_id.unwrap_or_default();
                let Some(pid) = event.pid else {
                    return;
                };
                if is_firefox(&bundle) {
                    refresh_snapshot(&ctx, vec![(bundle, pid)]).await;
                }
            }
            _ => {}
        }
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }

    async fn source_action(
        &self,
        ctx: Context,
        request: SourceActionRequest,
    ) -> SourceActionResponse {
        perform_source_action(&ctx, &request).await
    }
}

async fn refresh_snapshot(ctx: &Context, apps: Vec<(String, i64)>) {
    let mut candidates = Vec::new();
    for (bundle, pid) in apps {
        let source = source_name(&bundle);
        let tabs = collect_tabs(ctx, pid).await;
        candidates.extend(tabs.iter().map(|tab| candidate(tab, &source, pid)));
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

fn is_firefox(bundle: &str) -> bool {
    bundle == FIREFOX || bundle == FIREFOX_DEV
}

/// Plugin sources follow `<plugin>.<subsource>`. The release vs
/// developer edition distinction lives in the bundle id, not the
/// source label — both surface as `firefox.tabs` so `@firefox` /
/// `@firefox.tabs` filter them together.
fn source_name(_bundle: &str) -> String {
    "firefox.tabs".to_string()
}

/// Walk Firefox's windows and extract the tab strip. Mirrors the heuristics the
/// old in-core `BrowserTabSources.axTabElements`/`axTabTitle`/`axTabURL` used:
/// a node is a tab when it is a radio button / button / tab whose subrole or
/// role-description marks it as a tab strip entry (or any `AXTab`).
async fn collect_tabs(ctx: &Context, pid: i64) -> Vec<Tab> {
    let nodes = ax_snapshot(ctx, pid, "windows", &[], COLLECT, MAX_NODES, false).await;
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
fn candidate(tab: &Tab, source: &str, pid: i64) -> Candidate {
    let name = if tab.title.is_empty() {
        tab.url.clone()
    } else {
        tab.title.clone()
    };
    let mut candidate = Candidate::new(name)
        .kind("browser_tab")
        .source_id(SOURCE_ID)
        .source(source)
        .subtitle("browser tab")
        .pid(pid)
        .payload(tab.url.clone());
    if !tab.url.is_empty() {
        candidate = candidate.url(tab.url.clone());
    }
    candidate
}

/// Resolve a flashlight pick: raise Firefox, then press the matching tab. The
/// candidate's handle from emit time may be stale (any later snapshot for the
/// pid supersedes it), so re-snapshot and match by url, then title, before
/// pressing. Falls back to `AXSelected = true` when `AXPress` is unsupported.
async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let Some(pid) = candidate.pid_value() else {
        return ResolveResponse::unresolved();
    };
    activate_app(ctx, pid).await;
    let url = candidate.url_value().unwrap_or("");
    let name = candidate.title.as_str();
    let tabs = collect_tabs(ctx, pid).await;
    let target = tabs
        .iter()
        .find(|tab| !url.is_empty() && tab.url == url)
        .or_else(|| tabs.iter().find(|tab| tab.title == name));
    let Some(target) = target else {
        // App was still raised; report resolved so Flash keeps Firefox front.
        return ResolveResponse::resolved(Some(pid));
    };
    press(ctx, target.handle).await;
    ResolveResponse::resolved(Some(pid))
}

/// `tab_select` (numbered-tab jump): press the Nth tab in document order within
/// the first window that has at least that many tabs. Ports the old
/// `FirefoxTabsSource.tabSelect` semantics.
async fn perform_source_action(
    ctx: &Context,
    action: &SourceActionRequest,
) -> SourceActionResponse {
    if action.name != "tab_select" {
        return SourceActionResponse::unhandled();
    }
    let index = action.index.unwrap_or(0);
    let (Some(pid), true) = (action.context.pid, index > 0) else {
        return SourceActionResponse::unhandled();
    };
    activate_app(ctx, pid).await;
    let tabs = collect_tabs(ctx, pid).await;
    let Some(target) = tabs.get((index - 1) as usize) else {
        return SourceActionResponse::unhandled();
    };
    // Firefox owns this tab_select claim either way: a successful press is
    // `performed`, but a failed press must be `failed` (not `unhandled`) so
    // the host doesn't fall back to a ⌘<digit> keystroke that switches the
    // wrong tab.
    if press(ctx, target.handle).await {
        SourceActionResponse::performed(Some(pid))
    } else {
        SourceActionResponse::failed(Some(pid))
    }
}

/// Press a tab handle, falling back to selecting it when the element exposes no
/// press action.
async fn press(ctx: &Context, handle: u64) -> bool {
    if ax_perform(ctx, handle, "AXPress").await {
        return true;
    }
    ax_set(ctx, handle, "AXSelected", true).await
}

#[derive(Clone, Debug)]
struct AxNode {
    handle: u64,
    root: usize,
    attrs: BTreeMap<String, String>,
}

impl AxNode {
    fn from_value(value: &Value) -> Option<Self> {
        let handle = value.get("handle")?.as_u64()?;
        let root = value.get("root").and_then(Value::as_u64).unwrap_or(0) as usize;
        let attrs = value
            .get("attrs")
            .and_then(Value::as_object)
            .map(|map| {
                map.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self {
            handle,
            root,
            attrs,
        })
    }

    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

async fn activate_app(ctx: &Context, pid: i64) -> bool {
    ctx.call_host("app.activate", json!({ "pid": pid }))
        .await
        .get("ok")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

async fn ax_snapshot(
    ctx: &Context,
    pid: i64,
    roots: &str,
    follow: &[&str],
    collect: &[&str],
    max_nodes: u64,
    geometry: bool,
) -> Vec<AxNode> {
    let result = ctx
        .call_host(
            "ax.snapshot",
            json!({
                "pid": pid,
                "roots": roots,
                "follow": follow,
                "collect": collect,
                "max_nodes": max_nodes,
                "geometry": geometry,
            }),
        )
        .await;
    result
        .get("nodes")
        .and_then(Value::as_array)
        .map(|nodes| nodes.iter().filter_map(AxNode::from_value).collect())
        .unwrap_or_default()
}

async fn ax_perform(ctx: &Context, handle: u64, action: &str) -> bool {
    ctx.call_host("ax.perform", json!({ "handle": handle, "action": action }))
        .await
        .get("ok")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

async fn ax_set(ctx: &Context, handle: u64, attribute: &str, value: bool) -> bool {
    ctx.call_host(
        "ax.set",
        json!({ "handle": handle, "attribute": attribute, "value": value }),
    )
    .await
    .get("ok")
    .and_then(Value::as_bool)
    .unwrap_or(false)
}

fn main() {
    run(Firefox);
}
