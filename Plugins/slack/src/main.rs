use std::collections::HashSet;
use std::time::Duration;

use flash_plugin::{
    run, AxNode, Candidate, CommandRequest, CommandResponse, Context, Event, ResolveResponse,
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

flash_plugin::plugin!(Slack);

impl FlashPlugin for Slack {
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.snapshot" => {
                let pids = event
                    .running_applications
                    .iter()
                    .filter(|app| SLACK_BUNDLES.contains(&app.bundle_id.as_str()))
                    .map(|app| app.pid)
                    .collect::<Vec<_>>();
                refresh_snapshot(&ctx, pids).await;
            }
            "core:focus.changed" | "core:ax.changed" => {
                let bundle = event.bundle_id.unwrap_or_default();
                let Some(pid) = event.pid else {
                    return;
                };
                if SLACK_BUNDLES.contains(&bundle.as_str()) {
                    refresh_snapshot(&ctx, vec![pid]).await;
                }
            }
            _ => {}
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        self.invoke_command(&ctx, &command).await
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }
}

async fn refresh_snapshot(ctx: &Context, pids: Vec<i64>) {
    let mut candidates = Vec::new();
    for pid in pids {
        let channels = collect_channels(ctx, pid).await;
        candidates.extend(channels.iter().map(|channel| candidate(&channel.name, pid)));
    }
    ctx.emit_snapshot(CHANNEL_SOURCE_ID, candidates);
}

impl Slack {
    async fn invoke_command(&self, ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
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
                return CommandResponse::error(format!("unknown subcommand: {other}"));
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .into_command()
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
        .source("slack.channels")
        .subtitle("Slack channel")
        .pid(pid)
        .payload(name)
}

/// Resolve a pick: raise Slack, re-snapshot (the emit-time handle may be
/// stale), find the channel by name, and press it. Falls back to selecting it.
async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
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

/// Derive a channel name from a node's collected attributes. Only nodes
/// whose attributes carry a literal `#`-prefixed token are accepted; the
/// older "any attribute contains the word channel" fallbacks produced
/// button labels like `#Add` / `#More` / `#Edit` from strings such as
/// "Add channel" or "channels and DMs".
fn channel_name(node: &AxNode) -> Option<String> {
    for attr in CHANNEL_COLLECT {
        let Some(raw) = node.attr(attr) else { continue };
        if let Some(channel) = parse_channel_name(raw) {
            return Some(channel);
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
    None
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
    fn rejects_button_labels_without_hash() {
        // Strings like these used to produce `#Add` / `#Edit` / `#More`
        // via the channel-keyword fallback; they must not match now.
        assert_eq!(parse_channel_name("Add channel"), None);
        assert_eq!(parse_channel_name("Edit channel description"), None);
        assert_eq!(parse_channel_name("More options for channels"), None);
        assert_eq!(parse_channel_name("channels and DMs"), None);
        assert_eq!(parse_channel_name("general, channel"), None);
        assert_eq!(parse_channel_name("just text"), None);
    }
}
