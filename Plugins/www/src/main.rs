use std::collections::BTreeMap;
use std::time::Duration;

use flash_plugin::{run, Context, SourceActionRequest, SourceActionResponse};
use serde_json::{json, Value};

const URL_MAX_NODES: u64 = 400;
const BUTTON_MAX_NODES: u64 = 1_200;
const FOLLOW: &[&str] = &["AXChildren"];
const URL_COLLECT: &[&str] = &["AXRole", "AXURL", "AXDocument"];
const BUTTON_COLLECT: &[&str] = &[
    "AXRole",
    "AXTitle",
    "AXDescription",
    "AXHelp",
    "AXLabel",
    "AXValue",
];

struct Www;

flash_plugin::plugin!(Www);

impl FlashPlugin for Www {
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
            "[www] {} matched gmail url={}",
            action.wire_name(),
            shorten_url(&url)
        ),
    );
    let nodes = focused_button_snapshot(ctx, pid).await;
    let Some(handle) = gmail_button_handle(&nodes, action) else {
        ctx.log(
            "warn",
            &format!(
                "[www] {} found gmail thread but no {} button nodes={}",
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
                "[www] {} failed to press {} button handle={}",
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
        URL_COLLECT,
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
    for node in nodes {
        if !is_document_node(&node) {
            continue;
        }
        if let Some(url) = node.attr("AXURL").or_else(|| node.attr("AXDocument")) {
            let trimmed = url.trim();
            if is_gmail_open_thread_url(trimmed) {
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

fn is_gmail_open_thread_url(raw: &str) -> bool {
    let lower = raw.trim().to_ascii_lowercase();
    let without_scheme = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .unwrap_or(&lower);
    if without_scheme != "mail.google.com" && !without_scheme.starts_with("mail.google.com/") {
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

fn main() {
    run(Www);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{
        gmail_button_handle, gmail_button_score, is_gmail_open_thread_url, AxNode,
        GmailButtonAction,
    };

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
