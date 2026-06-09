use std::collections::HashSet;
use std::time::Duration;

use flash_plugin::{
    run, AxNode, Candidate, CommandRequest, CommandResponse, Context, Event, Plugin, Request,
    ResolveResponse, Response,
};

const CHANNEL_SOURCE_ID: &str = "plugin:slack.channels";
const SLACK_BUNDLES: &[&str] = &[
    "com.tinyspeck.slackmacgap",
    "com.tinyspeck.slackmacgap.direct",
];
/// Attributes the AX broker reads for every node; the channel-name heuristics
/// run over these in-plugin. Mirrors the old in-core `slackChannelName` reads.
const CHANNEL_COLLECT: &[&str] = &[
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXHelp",
    "AXIdentifier",
    "AXRoleDescription",
];
/// Slack's Electron tree is deep (collapsed sections, DMs, huddles, threads,
/// the workspace switcher). The visit budget matches the old walk so busy
/// workspaces don't silently truncate.
const MAX_NODES: u64 = 30_000;

struct Slack;

impl Plugin for Slack {
    // Slack focused → re-walk its AX tree and republish the channel list as
    // flashlight candidates. The host gates surfacing on the active app (the
    // manifest's `bundle_ids`), matching the old SlackSource.
    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name != "focus.changed" {
            return;
        }
        let bundle = event.bundle_id.unwrap_or_default();
        if !SLACK_BUNDLES.contains(&bundle.as_str()) {
            return;
        }
        let Some(pid) = event.pid else {
            return;
        };
        let channels = collect_channels(&ctx, pid).await;
        let candidates = channels
            .iter()
            .map(|channel| candidate(&channel.name, pid))
            .collect();
        ctx.emit_snapshot(CHANNEL_SOURCE_ID, candidates);
    }

    async fn handle(&self, ctx: Context, request: Request) -> Response {
        match request {
            Request::Command(cmd) => self.invoke_command(&ctx, &cmd).await,
            Request::ResolveCandidate(candidate) => {
                resolve_candidate(&ctx, &candidate).await.into()
            }
            _ => CommandResponse::error("unsupported request").into(),
        }
    }
}

impl Slack {
    async fn invoke_command(&self, ctx: &Context, cmd: &CommandRequest) -> Response {
        // `[plugin.slack] cli = "/path/to/slack"` overrides the executable;
        // defaults to `slack` on PATH.
        let cli = {
            let configured = ctx.config_str("cli");
            if configured.is_empty() {
                "slack".to_string()
            } else {
                configured
            }
        };
        let (argv, timeout): (Vec<String>, u64) = match cmd.subcommand.as_str() {
            "login" => (vec![cli, "login".into()], 300),
            "version" => (vec![cli, "version".into()], 120),
            "run" => (prepend(&cli, &cmd.args), 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}")).into();
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .into()
    }
}

struct Channel {
    handle: u64,
    name: String,
}

/// Walk Slack's windows and pull every channel entry out of the AX tree.
async fn collect_channels(ctx: &Context, pid: i64) -> Vec<Channel> {
    let nodes = ctx
        .ax_snapshot(pid, "windows", &[], CHANNEL_COLLECT, MAX_NODES, false)
        .await;
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for node in &nodes {
        let Some(name) = channel_name(node) else {
            continue;
        };
        if seen.insert(name.clone()) {
            out.push(Channel {
                handle: node.handle,
                name,
            });
        }
    }
    out
}

fn candidate(name: &str, pid: i64) -> Candidate {
    Candidate::new(name)
        .kind("slack_channel")
        .source_id(CHANNEL_SOURCE_ID)
        .source("slack")
        .subtitle("Slack channel")
        .pid(pid)
        .payload(name)
}

/// Resolve a pick: raise Slack, re-snapshot (the emit-time handle may be
/// stale), find the channel by name, and press it. Falls back to selecting it.
async fn resolve_candidate(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let Some(pid) = candidate.pid else {
        return ResolveResponse::unresolved();
    };
    let name = candidate.name.as_str();
    ctx.ax_activate(pid).await;
    let channels = collect_channels(ctx, pid).await;
    if let Some(target) = channels.iter().find(|c| c.name == name) {
        if !ctx.ax_perform(target.handle, "AXPress").await {
            ctx.ax_set(target.handle, "AXSelected", true).await;
        }
    }
    ResolveResponse::resolved(Some(pid))
}

/// Derive a channel name from a node's collected attributes, applying the same
/// heuristics the old in-core `SlackSource.slackChannelName` used.
fn channel_name(node: &AxNode) -> Option<String> {
    let values: Vec<&str> = CHANNEL_COLLECT
        .iter()
        .filter_map(|attr| node.attr(attr))
        .collect();
    for raw in &values {
        if let Some(channel) = parse_channel_name(raw) {
            return Some(channel);
        }
    }
    if values.iter().any(|v| v.to_lowercase().contains("channel")) {
        for raw in &values {
            if let Some(channel) = parse_bare_channel_name(raw) {
                return Some(channel);
            }
        }
    }
    None
}

fn is_separator(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            ',' | ':' | ';' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | '|' | '•' | '·'
        )
}

fn clean_channel_token(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect()
}

fn is_reserved(token: &str, words: &[&str]) -> bool {
    let lowered = token.to_lowercase();
    words.contains(&lowered.as_str())
}

fn parse_channel_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let tokens: Vec<&str> = trimmed
        .split(is_separator)
        .filter(|t| !t.is_empty())
        .collect();
    for (index, token) in tokens.iter().enumerate() {
        if *token == "#" {
            if let Some(next) = tokens.get(index + 1) {
                let cleaned = clean_channel_token(next);
                if !cleaned.is_empty() {
                    return Some(format!("#{cleaned}"));
                }
            }
        }
        if let Some(rest) = token.strip_prefix('#') {
            let cleaned = clean_channel_token(rest);
            if !cleaned.is_empty() {
                return Some(format!("#{cleaned}"));
            }
        }
    }

    if !trimmed.to_lowercase().contains("channel") {
        return None;
    }
    const RESERVED: &[&str] = &[
        "channel", "channels", "public", "private", "unread", "threads", "mentions",
    ];
    for token in &tokens {
        let cleaned = clean_channel_token(token);
        if cleaned.is_empty() || is_reserved(&cleaned, RESERVED) {
            continue;
        }
        return Some(format!("#{cleaned}"));
    }
    None
}

fn parse_bare_channel_name(raw: &str) -> Option<String> {
    let cleaned = clean_channel_token(raw.trim());
    if cleaned.is_empty() {
        return None;
    }
    if is_reserved(&cleaned, &["channel", "channels", "public", "private"]) {
        return None;
    }
    if cleaned.chars().count() > 80 {
        return None;
    }
    Some(format!("#{cleaned}"))
}

fn prepend(program: &str, args: &[String]) -> Vec<String> {
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(program.to_string());
    argv.extend_from_slice(args);
    argv
}

fn main() {
    run(Slack);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hash_prefixed_names() {
        assert_eq!(parse_channel_name("# general").as_deref(), Some("#general"));
        assert_eq!(
            parse_channel_name("#release-notes").as_deref(),
            Some("#release-notes")
        );
    }

    #[test]
    fn falls_back_to_channel_keyword() {
        assert_eq!(
            parse_channel_name("general, channel").as_deref(),
            Some("#general")
        );
        assert_eq!(parse_channel_name("just text").as_deref(), None);
    }

    #[test]
    fn bare_channel_names() {
        assert_eq!(
            parse_bare_channel_name("release_notes").as_deref(),
            Some("#release_notes")
        );
        assert_eq!(parse_bare_channel_name("channel"), None);
        assert_eq!(parse_bare_channel_name(""), None);
    }
}
