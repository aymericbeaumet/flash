use std::collections::BTreeMap;
use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{
    run, CommandRequest, CommandResponse, Context, SourceActionRequest, SourceActionResponse,
};
use serde_json::{json, Value};

const URL_MAX_NODES: u64 = 400;
const BUTTON_MAX_NODES: u64 = 1_200;
const FOLLOW: &[&str] = &["AXChildren"];
const FIREFOX_URL_COLLECT: &[&str] = &[
    "AXRole",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXURL",
    "AXDocument",
];
const BUTTON_COLLECT: &[&str] = &[
    "AXRole",
    "AXTitle",
    "AXDescription",
    "AXHelp",
    "AXLabel",
    "AXValue",
];
const SAFARI_BUNDLES: &[&str] = &["com.apple.Safari", "com.apple.SafariTechnologyPreview"];
const FIREFOX_BUNDLES: &[&str] = &["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition"];
const CHROMIUM_BUNDLES: &[&str] = &[
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext",
    "com.operasoftware.OperaDeveloper",
];

struct Gmail;

flash_plugin::plugin!(Gmail);

impl FlashPlugin for Gmail {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "inbox" => navigate_to_gmail_route(&ctx, "inbox").await,
            "starred" => navigate_to_gmail_route(&ctx, "starred").await,
            "snoozed" => navigate_to_gmail_route(&ctx, "snoozed").await,
            "sent" => navigate_to_gmail_route(&ctx, "sent").await,
            "drafts" => navigate_to_gmail_route(&ctx, "drafts").await,
            "all" => navigate_to_gmail_route(&ctx, "all").await,
            "tasks" => navigate_to_gmail_route(&ctx, "tasks").await,
            "label" => navigate_to_gmail_route(&ctx, "label").await,
            other => CommandResponse::error(format!("unknown gmail subcommand: {other}")),
        }
    }

    async fn source_action(
        &self,
        ctx: Context,
        request: SourceActionRequest,
    ) -> SourceActionResponse {
        match request.name.as_str() {
            "resource_archive" => archive_resource(&ctx, &request).await,
            "resource_next" => navigate_resource(&ctx, &request, ResourceDirection::Next).await,
            "resource_previous" => {
                navigate_resource(&ctx, &request, ResourceDirection::Previous).await
            }
            _ => SourceActionResponse::unhandled(),
        }
    }
}

async fn navigate_to_gmail_route(ctx: &Context, route: &str) -> CommandResponse {
    navigate_to_computed_gmail_url(ctx, |current_url| gmail_route_url(current_url, route)).await
}

async fn navigate_to_computed_gmail_url(
    ctx: &Context,
    destination: impl FnOnce(&str) -> Option<String>,
) -> CommandResponse {
    let Some(target) = ctx.normal_mode_target().await else {
        return CommandResponse::error("no focused browser target for gmail navigation");
    };
    let Some(current_url) = focused_gmail_url(ctx, target.pid).await else {
        return CommandResponse::error("focused browser target is not exposing a gmail url");
    };
    let Some(destination) = destination(&current_url) else {
        return CommandResponse::error(format!("cannot build gmail route from {current_url}"));
    };
    let Some(route) = gmail_route_fragment(&destination) else {
        return CommandResponse::error(format!("cannot soft navigate gmail route: {destination}"));
    };
    ctx.log(
        "debug",
        &format!(
            "[gmail] navigate from={} to={}",
            shorten_url(&current_url),
            shorten_url(&destination)
        ),
    );
    let result =
        soft_navigate_browser_url(ctx, &target.bundle_id, target.pid, &destination, route).await;
    if result.ok && result.stdout.trim() == "ok" {
        CommandResponse::ok().target_pid(target.pid)
    } else {
        ctx.log(
            "warn",
            &format!("[gmail] navigation failed stderr={}", result.stderr.trim()),
        );
        CommandResponse::error(format!("gmail navigation failed: {}", result.stderr.trim()))
    }
}

async fn focused_gmail_url(ctx: &Context, pid: i64) -> Option<String> {
    let nodes = ax_snapshot(
        ctx,
        pid,
        "windows",
        FOLLOW,
        FIREFOX_URL_COLLECT,
        URL_MAX_NODES,
        false,
    )
    .await;
    gmail_document_url(&nodes).map(str::to_string)
}

async fn archive_resource(ctx: &Context, request: &SourceActionRequest) -> SourceActionResponse {
    perform_gmail_button_action(ctx, request, GmailButtonAction::Archive).await
}

async fn navigate_resource(
    ctx: &Context,
    request: &SourceActionRequest,
    direction: ResourceDirection,
) -> SourceActionResponse {
    let action = match direction {
        ResourceDirection::Next => GmailButtonAction::Next,
        ResourceDirection::Previous => GmailButtonAction::Previous,
    };
    perform_gmail_button_action(ctx, request, action).await
}

async fn perform_gmail_button_action(
    ctx: &Context,
    request: &SourceActionRequest,
    action: GmailButtonAction,
) -> SourceActionResponse {
    let Some(pid) = request.context.pid else {
        return SourceActionResponse::unhandled();
    };
    let Some(url) = focused_gmail_thread_url(ctx, pid).await else {
        return SourceActionResponse::unhandled();
    };
    ctx.log(
        "debug",
        &format!(
            "[gmail] {} matched gmail url={}",
            action.wire_name(),
            shorten_url(&url)
        ),
    );
    let nodes = focused_button_snapshot(ctx, pid).await;
    let Some(handle) = gmail_button_handle(&nodes, action) else {
        ctx.log(
            "warn",
            &format!(
                "[gmail] {} found gmail thread but no {} button nodes={}",
                action.wire_name(),
                action.label(),
                nodes.len()
            ),
        );
        return SourceActionResponse::failed(Some(pid));
    };
    if !activate_app(ctx, pid).await {
        return SourceActionResponse::failed(Some(pid));
    }
    tokio::time::sleep(Duration::from_millis(25)).await;
    if ax_perform(ctx, handle, "AXPress").await {
        SourceActionResponse::performed(Some(pid))
    } else {
        ctx.log(
            "warn",
            &format!(
                "[gmail] {} failed to press {} button handle={}",
                action.wire_name(),
                action.label(),
                handle
            ),
        );
        SourceActionResponse::failed(Some(pid))
    }
}

async fn focused_gmail_thread_url(ctx: &Context, pid: i64) -> Option<String> {
    let nodes = ax_snapshot(
        ctx,
        pid,
        "windows",
        FOLLOW,
        FIREFOX_URL_COLLECT,
        URL_MAX_NODES,
        false,
    )
    .await;
    gmail_thread_url(&nodes).map(str::to_string)
}

async fn focused_button_snapshot(ctx: &Context, pid: i64) -> Vec<AxNode> {
    ax_snapshot(
        ctx,
        pid,
        "windows",
        FOLLOW,
        BUTTON_COLLECT,
        BUTTON_MAX_NODES,
        false,
    )
    .await
}

fn gmail_thread_url(nodes: &[AxNode]) -> Option<&str> {
    gmail_document_url(nodes).filter(|url| is_gmail_open_thread_url(url))
}

fn gmail_document_url(nodes: &[AxNode]) -> Option<&str> {
    for node in nodes {
        if !is_document_node(&node) {
            continue;
        }
        if let Some(url) = node.attr("AXURL").or_else(|| node.attr("AXDocument")) {
            let trimmed = url.trim();
            if is_gmail_url(trimmed) {
                return Some(trimmed);
            }
        }
    }
    None
}

fn is_document_node(node: &AxNode) -> bool {
    matches!(node.attr("AXRole"), Some("AXWebArea" | "AXDocument"))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ResourceDirection {
    Next,
    Previous,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GmailButtonAction {
    Archive,
    Next,
    Previous,
}

impl GmailButtonAction {
    fn wire_name(self) -> &'static str {
        match self {
            Self::Archive => "resource_archive",
            Self::Next => "resource_next",
            Self::Previous => "resource_previous",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Archive => "archive",
            Self::Next => "next",
            Self::Previous => "previous",
        }
    }

    fn text_score(self, raw: &str) -> Option<u8> {
        match self {
            Self::Archive => {
                action_text_score(raw, &["archive", "archiver"], &["archive", "archiver"])
            }
            Self::Next => action_text_score(
                raw,
                &["older", "next", "older conversation", "next conversation"],
                &["older", "next conversation", "next", "plus ancien"],
            ),
            Self::Previous => action_text_score(
                raw,
                &[
                    "newer",
                    "previous",
                    "newer conversation",
                    "previous conversation",
                ],
                &[
                    "newer",
                    "previous conversation",
                    "previous",
                    "plus récent",
                    "plus recent",
                ],
            ),
        }
    }
}

fn gmail_button_handle(nodes: &[AxNode], action: GmailButtonAction) -> Option<u64> {
    nodes
        .iter()
        .filter_map(|node| gmail_button_score(node, action).map(|score| (score, node.handle)))
        .min_by_key(|(score, _)| *score)
        .map(|(_, handle)| handle)
}

fn gmail_button_score(node: &AxNode, action: GmailButtonAction) -> Option<(u8, u8, u8)> {
    let role = node.attr("AXRole")?;
    let role_score = match role {
        "AXButton" | "AXMenuButton" => 0,
        "AXLink" => 1,
        "AXGroup" => 2,
        _ => return None,
    };
    let mut best_text_score: Option<(u8, u8)> = None;
    for (attribute_score, attribute) in ["AXTitle", "AXDescription", "AXHelp", "AXLabel", "AXValue"]
        .iter()
        .enumerate()
    {
        let Some(value) = node.attr(attribute) else {
            continue;
        };
        let Some(text_score) = action.text_score(value) else {
            continue;
        };
        let candidate = (text_score, attribute_score as u8);
        if best_text_score.map_or(true, |best| candidate < best) {
            best_text_score = Some(candidate);
        }
    }
    best_text_score.map(|(text_score, attribute_score)| (text_score, role_score, attribute_score))
}

fn action_text_score(raw: &str, exact: &[&str], prefixes: &[&str]) -> Option<u8> {
    let text = raw.trim().to_ascii_lowercase();
    if exact.iter().any(|candidate| text == *candidate) {
        return Some(0);
    }
    if prefixes.iter().any(|candidate| {
        text.starts_with(&format!("{candidate} ")) || text.starts_with(&format!("{candidate}("))
    }) {
        return Some(1);
    }
    if prefixes.iter().any(|candidate| text.contains(candidate)) {
        return Some(2);
    }
    None
}

fn gmail_route_url(raw: &str, route: &str) -> Option<String> {
    let trimmed = raw.trim();
    if !is_gmail_url(trimmed) {
        return None;
    }
    let route = route.trim_matches('/');
    if route.is_empty() {
        return None;
    }
    let base = trimmed
        .split_once('#')
        .map(|(base, _)| base)
        .unwrap_or(trimmed);
    let normalized_base = if base.ends_with('/') || base.contains('?') {
        base.to_string()
    } else {
        format!("{base}/")
    };
    Some(format!("{normalized_base}#{route}"))
}

fn gmail_route_fragment(raw: &str) -> Option<&str> {
    let route = raw.trim().split_once('#')?.1.trim_matches('/');
    (!route.is_empty()).then_some(route)
}

fn is_gmail_url(raw: &str) -> bool {
    let lower = raw.trim().to_ascii_lowercase();
    let without_scheme = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .unwrap_or(&lower);
    without_scheme == "mail.google.com" || without_scheme.starts_with("mail.google.com/")
}

fn is_gmail_open_thread_url(raw: &str) -> bool {
    let lower = raw.trim().to_ascii_lowercase();
    let without_scheme = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .unwrap_or(&lower);
    if !is_gmail_url(raw) {
        return false;
    }
    let Some((_, route)) = without_scheme.split_once('#') else {
        return false;
    };
    let route = route
        .split(['?', '&'])
        .next()
        .unwrap_or("")
        .trim_matches('/');
    let parts = route
        .split('/')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    let Some(first) = parts.first().copied() else {
        return false;
    };
    if matches!(first, "settings" | "contacts" | "tasks" | "chat" | "meet") {
        return false;
    }
    if matches!(first, "label" | "search" | "category") && parts.len() < 3 {
        return false;
    }
    parts
        .last()
        .copied()
        .map(looks_like_gmail_thread_id)
        .unwrap_or(false)
}

fn looks_like_gmail_thread_id(raw: &str) -> bool {
    let value = raw.trim();
    value.len() >= 8
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
}

fn shorten_url(raw: &str) -> String {
    const LIMIT: usize = 120;
    if raw.chars().count() <= LIMIT {
        return raw.to_string();
    }
    raw.chars().take(LIMIT).collect::<String>() + "..."
}

#[derive(Clone, Debug, Default)]
struct AxNode {
    handle: u64,
    _root: usize,
    attrs: BTreeMap<String, String>,
    _frame: Option<[f64; 4]>,
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
                    .filter_map(|(key, value)| {
                        value
                            .as_str()
                            .map(|string| (key.clone(), string.to_string()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let frame = value
            .get("frame")
            .and_then(Value::as_array)
            .and_then(|values| {
                if values.len() != 4 {
                    return None;
                }
                Some([
                    values[0].as_f64()?,
                    values[1].as_f64()?,
                    values[2].as_f64()?,
                    values[3].as_f64()?,
                ])
            });
        Some(Self {
            handle,
            _root: root,
            attrs,
            _frame: frame,
        })
    }

    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

#[derive(Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

async fn soft_navigate_browser_url(
    ctx: &Context,
    bundle_id: &str,
    pid: i64,
    destination: &str,
    route: &str,
) -> CommandOutput {
    let _ = activate_app(ctx, pid).await;
    tokio::time::sleep(Duration::from_millis(25)).await;
    let script = gmail_soft_navigation_script(route);
    if SAFARI_BUNDLES.contains(&bundle_id) {
        return soft_navigate_safari_route(ctx, bundle_id, &script).await;
    }
    if CHROMIUM_BUNDLES.contains(&bundle_id) {
        return soft_navigate_chromium_route(ctx, bundle_id, &script).await;
    }
    if FIREFOX_BUNDLES.contains(&bundle_id) {
        return soft_navigate_firefox_url(ctx, pid, destination).await;
    }
    CommandOutput {
        ok: false,
        stderr: format!("unsupported browser for soft gmail navigation: {bundle_id}"),
        _status: -1,
        ..Default::default()
    }
}

async fn soft_navigate_firefox_url(ctx: &Context, pid: i64, destination: &str) -> CommandOutput {
    if gmail_route_is_current(ctx, pid, destination).await {
        return CommandOutput {
            ok: true,
            stdout: "ok\n".to_string(),
            ..Default::default()
        };
    }
    let nodes = ax_snapshot(
        ctx,
        pid,
        "windows",
        FOLLOW,
        FIREFOX_URL_COLLECT,
        URL_MAX_NODES,
        false,
    )
    .await;
    let Some(handle) = firefox_address_bar_handle(&nodes) else {
        return CommandOutput {
            ok: false,
            stderr: "firefox address bar not found".to_string(),
            _status: -1,
            ..Default::default()
        };
    };
    if !activate_app(ctx, pid).await {
        return CommandOutput {
            ok: false,
            stderr: "firefox activation failed".to_string(),
            _status: -1,
            ..Default::default()
        };
    }
    tokio::time::sleep(Duration::from_millis(25)).await;
    if !ax_set_bool(ctx, handle, "AXFocused", true).await {
        return CommandOutput {
            ok: false,
            stderr: "firefox address bar focus failed".to_string(),
            _status: -1,
            ..Default::default()
        };
    }
    tokio::time::sleep(Duration::from_millis(25)).await;
    if !replace_focused_text_and_submit(ctx, pid, destination).await {
        return CommandOutput {
            ok: false,
            stderr: "firefox address bar input failed".to_string(),
            _status: -1,
            ..Default::default()
        };
    }
    verify_firefox_navigation(ctx, pid, destination).await
}

async fn verify_firefox_navigation(ctx: &Context, pid: i64, destination: &str) -> CommandOutput {
    let expected = gmail_route_fragment(destination).unwrap_or("");
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(150)).await;
        if let Some(current) = focused_gmail_url(ctx, pid).await {
            if gmail_route_fragment(&current) == Some(expected) {
                return CommandOutput {
                    ok: true,
                    stdout: "ok\n".to_string(),
                    ..Default::default()
                };
            }
        }
    }
    let observed = focused_gmail_url(ctx, pid)
        .await
        .unwrap_or_else(|| "<missing>".to_string());
    CommandOutput {
        ok: false,
        stderr: format!(
            "firefox gmail navigation did not reach {} (observed {})",
            shorten_url(destination),
            shorten_url(&observed)
        ),
        _status: -1,
        ..Default::default()
    }
}

async fn gmail_route_is_current(ctx: &Context, pid: i64, destination: &str) -> bool {
    let Some(expected) = gmail_route_fragment(destination) else {
        return false;
    };
    focused_gmail_url(ctx, pid)
        .await
        .and_then(|current| gmail_route_fragment(&current).map(|route| route == expected))
        .unwrap_or(false)
}

async fn soft_navigate_safari_route(ctx: &Context, bundle_id: &str, js: &str) -> CommandOutput {
    let script = format!(
        r#"
tell application {app}
  activate
  if (count of windows) is 0 then
    return "missing"
  end if
  return do JavaScript {js} in current tab of front window
end tell
"#,
        app = applescript_quote(canonical_app_name(bundle_id)),
        js = applescript_quote(js)
    );
    run_osascript(ctx, &script, Duration::from_secs(5)).await
}

async fn soft_navigate_chromium_route(ctx: &Context, bundle_id: &str, js: &str) -> CommandOutput {
    let script = format!(
        r#"
tell application {app}
  activate
  if (count of windows) is 0 then
    return "missing"
  end if
  return execute active tab of front window javascript {js}
end tell
"#,
        app = applescript_quote(canonical_app_name(bundle_id)),
        js = applescript_quote(js)
    );
    run_osascript(ctx, &script, Duration::from_secs(5)).await
}

fn firefox_address_bar_handle(nodes: &[AxNode]) -> Option<u64> {
    for node in nodes {
        if node.attr("AXRole") != Some("AXComboBox") {
            continue;
        }
        let value = node.attr("AXValue").unwrap_or("").trim();
        if is_gmail_url(value) {
            return Some(node.handle);
        }
    }
    for node in nodes {
        if node.attr("AXRole") != Some("AXComboBox") {
            continue;
        }
        let description = node
            .attr("AXDescription")
            .unwrap_or("")
            .to_ascii_lowercase();
        if description.contains("enter address") || description.contains("search with") {
            return Some(node.handle);
        }
    }
    None
}

async fn replace_focused_text_and_submit(ctx: &Context, pid: i64, text: &str) -> bool {
    ctx.call_host_timeout(
        "input.replace_text_and_submit",
        json!({ "pid": pid, "text": text, "require_focused_role": "AXComboBox" }),
        Duration::from_secs(2),
    )
    .await
    .get("ok")
    .and_then(Value::as_bool)
    .unwrap_or(false)
}

fn gmail_soft_navigation_script(route: &str) -> String {
    let hash = format!("#{}", route.trim_matches('/'));
    format!(
        r#"(function() {{
  var target = {};
  if (window.location.hash === target) {{
    return "ok";
  }}
  window.location.hash = target;
  return "ok";
}})();"#,
        javascript_string(&hash)
    )
}

fn javascript_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}

fn canonical_app_name(bundle_id: &str) -> &'static str {
    match bundle_id {
        "com.apple.SafariTechnologyPreview" => "Safari Technology Preview",
        "com.apple.Safari" => "Safari",
        "org.mozilla.firefoxdeveloperedition" => "Firefox Developer Edition",
        "org.mozilla.firefox" => "Firefox",
        "com.google.Chrome" => "Google Chrome",
        "com.google.Chrome.canary" => "Google Chrome Canary",
        "com.google.Chrome.beta" => "Google Chrome Beta",
        "com.google.Chrome.dev" => "Google Chrome Dev",
        "org.chromium.Chromium" => "Chromium",
        "com.brave.Browser" => "Brave Browser",
        "com.brave.Browser.beta" => "Brave Browser Beta",
        "com.brave.Browser.nightly" => "Brave Browser Nightly",
        "com.microsoft.edgemac" => "Microsoft Edge",
        "com.microsoft.edgemac.Beta" => "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev" => "Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary" => "Microsoft Edge Canary",
        "company.thebrowser.Browser" => "Arc",
        "com.vivaldi.Vivaldi" => "Vivaldi",
        "com.operasoftware.Opera" => "Opera",
        "com.operasoftware.OperaNext" => "Opera Next",
        "com.operasoftware.OperaDeveloper" => "Opera Developer",
        _ => "Google Chrome",
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

async fn ax_set_bool(ctx: &Context, handle: u64, attribute: &str, value: bool) -> bool {
    ctx.call_host(
        "ax.set",
        json!({ "handle": handle, "attribute": attribute, "value": value }),
    )
    .await
    .get("ok")
    .and_then(Value::as_bool)
    .unwrap_or(false)
}

async fn run_osascript(ctx: &Context, script: &str, timeout: Duration) -> CommandOutput {
    run_command(
        ctx,
        &[
            "/usr/bin/osascript".to_string(),
            "-e".to_string(),
            script.to_string(),
        ],
        timeout,
    )
    .await
}

async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> CommandOutput {
    let Some((program, args)) = argv.split_first() else {
        return CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            _status: -1,
            ..Default::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .current_dir(&ctx.data_dir)
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .env(
            "PATH",
            format!(
                "{}:{}",
                ctx.bin_dir().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CommandOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            _status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CommandOutput {
            ok: false,
            stderr: err.to_string(),
            _status: -1,
            ..Default::default()
        },
        Err(_) => CommandOutput {
            ok: false,
            stderr: format!("timed out after {}ms", timeout.as_millis()),
            _status: 124,
            ..Default::default()
        },
    }
}

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn main() {
    run(Gmail);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{
        firefox_address_bar_handle, gmail_button_handle, gmail_button_score, gmail_route_fragment,
        gmail_route_url, gmail_soft_navigation_script, is_gmail_open_thread_url, is_gmail_url,
        AxNode, GmailButtonAction,
    };

    #[test]
    fn gmail_urls_match_mail_google_only() {
        assert!(is_gmail_url("https://mail.google.com/mail/u/0/#inbox"));
        assert!(is_gmail_url("http://mail.google.com/mail/u/0/#inbox"));
        assert!(is_gmail_url("mail.google.com/mail/u/0/#inbox"));
        assert!(!is_gmail_url("https://calendar.google.com/calendar/u/0/r"));
        assert!(!is_gmail_url("https://notmail.google.com/mail/u/0/#inbox"));
    }

    #[test]
    fn gmail_route_urls_preserve_account_base() {
        assert_eq!(
            gmail_route_url(
                "https://mail.google.com/mail/u/1/#search/from%3Ame/FMfcgzGtwPLdPabc",
                "inbox"
            ),
            Some("https://mail.google.com/mail/u/1/#inbox".to_string())
        );
        assert_eq!(
            gmail_route_url(
                "https://mail.google.com/mail/u/0/?tab=rm&ogbl#category/social/FMfcgzGtwPLdPabc",
                "/inbox/"
            ),
            Some("https://mail.google.com/mail/u/0/?tab=rm&ogbl#inbox".to_string())
        );
        assert_eq!(
            gmail_route_url("https://mail.google.com/mail/u/2", "inbox"),
            Some("https://mail.google.com/mail/u/2/#inbox".to_string())
        );
        assert_eq!(
            gmail_route_url("https://calendar.google.com/calendar/u/0/r", "inbox"),
            None
        );
    }

    #[test]
    fn gmail_route_fragments_extract_hash_routes() {
        assert_eq!(
            gmail_route_fragment("https://mail.google.com/mail/u/0/#inbox"),
            Some("inbox")
        );
        assert_eq!(
            gmail_route_fragment("https://mail.google.com/mail/u/0/#label/Work/"),
            Some("label/Work")
        );
        assert_eq!(
            gmail_route_fragment("https://mail.google.com/mail/u/0/"),
            None
        );
    }

    #[test]
    fn soft_navigation_script_changes_hash_only() {
        let script = gmail_soft_navigation_script("label/Work");

        assert!(script.contains("\"#label/Work\""));
        assert!(script.contains("window.location.hash = target"));
        assert!(!script.contains("window.location.href"));
        assert!(!script.contains("window.location.assign"));
        assert!(!script.contains("window.open"));
    }

    #[test]
    fn firefox_address_bar_prefers_gmail_combo_box() {
        let nodes = vec![
            node(
                1,
                &[
                    ("AXRole", "AXComboBox"),
                    ("AXDescription", "Search with Google or enter address"),
                ],
            ),
            node(
                2,
                &[
                    ("AXRole", "AXComboBox"),
                    ("AXValue", "mail.google.com/mail/u/0/#inbox"),
                ],
            ),
        ];

        assert_eq!(firefox_address_bar_handle(&nodes), Some(2));
    }

    #[test]
    fn gmail_thread_urls_are_archiveable() {
        for url in [
            "https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwPLdPabc",
            "https://mail.google.com/mail/u/0/#all/18f14df7a6c43b2a",
            "https://mail.google.com/mail/u/0/#label/Work/FMfcgzGtwPLdPabc",
            "https://mail.google.com/mail/u/0/#search/from%3Ame/FMfcgzGtwPLdPabc",
            "https://mail.google.com/mail/u/0/#category/social/FMfcgzGtwPLdPabc",
        ] {
            assert!(is_gmail_open_thread_url(url), "{url}");
        }
    }

    #[test]
    fn gmail_non_thread_urls_are_noops() {
        for url in [
            "https://mail.google.com/mail/u/0/#inbox",
            "https://mail.google.com/mail/u/0/#all",
            "https://mail.google.com/mail/u/0/#label/Work",
            "https://mail.google.com/mail/u/0/#search/from%3Ame",
            "https://mail.google.com/mail/u/0/#category/social",
            "https://mail.google.com/mail/u/0/#settings/general",
            "https://mail.google.com/mail/u/0/",
            "https://calendar.google.com/calendar/u/0/r",
        ] {
            assert!(!is_gmail_open_thread_url(url), "{url}");
        }
    }

    #[test]
    fn archive_button_prefers_exact_button_label() {
        let nodes = vec![
            node(
                1,
                &[
                    ("AXRole", "AXGroup"),
                    ("AXDescription", "Move to archive folder"),
                ],
            ),
            node(2, &[("AXRole", "AXButton"), ("AXDescription", "Archive")]),
            node(
                3,
                &[("AXRole", "AXButton"), ("AXDescription", "Archive (e)")],
            ),
        ];

        assert_eq!(
            gmail_button_handle(&nodes, GmailButtonAction::Archive),
            Some(2)
        );
        assert_eq!(
            gmail_button_score(&nodes[1], GmailButtonAction::Archive),
            Some((0, 0, 1))
        );
    }

    #[test]
    fn archive_button_ignores_unrelated_controls() {
        let nodes = vec![
            node(1, &[("AXRole", "AXButton"), ("AXDescription", "Delete")]),
            node(
                2,
                &[("AXRole", "AXStaticText"), ("AXDescription", "Archive")],
            ),
        ];

        assert_eq!(
            gmail_button_handle(&nodes, GmailButtonAction::Archive),
            None
        );
    }

    #[test]
    fn gmail_navigation_buttons_match_newer_and_older_labels() {
        let nodes = vec![
            node(1, &[("AXRole", "AXButton"), ("AXDescription", "Older")]),
            node(2, &[("AXRole", "AXButton"), ("AXDescription", "Newer")]),
        ];

        assert_eq!(
            gmail_button_handle(&nodes, GmailButtonAction::Next),
            Some(1)
        );
        assert_eq!(
            gmail_button_handle(&nodes, GmailButtonAction::Previous),
            Some(2)
        );
    }

    fn node(handle: u64, attrs: &[(&str, &str)]) -> AxNode {
        AxNode {
            handle,
            _root: 0,
            attrs: attrs
                .iter()
                .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
                .collect::<BTreeMap<_, _>>(),
            _frame: None,
        }
    }
}
