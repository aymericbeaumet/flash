use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

/// (bang, base_url, optional_query_param)
///
/// When `query_param` is set and the user typed `!<bang> <query>`, the URL
/// becomes `base_url?query_param=<encoded>` so the chat opens with the
/// prompt pre-filled. A bare `!<bang>` always opens the base URL.
///
/// Sorted alphabetically by bang so `lookup` can binary-search.
const PROVIDERS: &[(&str, &str, Option<&str>)] = &[
    ("chatgpt", "https://chatgpt.com/", Some("q")),
    ("claude", "https://claude.ai/new", Some("q")),
    ("copilot", "https://copilot.microsoft.com/", Some("q")),
    ("gemini", "https://gemini.google.com/app", Some("q")),
    ("grok", "https://grok.com/", Some("q")),
    ("perplexity", "https://www.perplexity.ai/search", Some("q")),
];

struct AiProviders;

flash_plugin::plugin!(AiProviders);

impl FlashPlugin for AiProviders {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        // Bang typed (`!claude` → `claude`) arrives as the subcommand; the
        // rest of the flashlight line is the query. This plugin is only
        // reached through the per-token shebang provider, so unknown
        // tokens shouldn't happen — but we surface them as errors anyway.
        let bang = command.subcommand.to_ascii_lowercase();
        let Some((_, base, query_param)) = lookup(&bang) else {
            return CommandResponse::error(format!("unknown ai provider: !{bang}"));
        };
        let query = command.query();
        let url = match (query_param, query.is_empty()) {
            (Some(param), false) => format!("{base}?{param}={}", percent_encode(&query)),
            _ => base.to_string(),
        };
        let open_result = run_command(
            &ctx,
            &["/usr/bin/open".to_string(), url],
            Duration::from_secs(10),
        )
        .await;
        // Auto-send: after the URL opens, wait long enough for the page's
        // input field to take focus, then synthesize Return so the
        // pre-filled prompt actually sends. Best-effort — if focus lands
        // somewhere else (URL bar, another app the user clicked into) the
        // keystroke goes there instead. Skipped when there's no query
        // (nothing to send) and when the open itself failed.
        if !query.is_empty() && open_result.ok {
            autosend_return(&ctx).await;
        }
        open_result.into_command()
    }
}

/// Post a Return key event after a load delay so the AI provider's
/// just-loaded composer sees the synthesized keystroke. The delay is
/// generous enough for cold-start browsers, short enough that the user
/// won't have time to click elsewhere on a warm one.
async fn autosend_return(ctx: &Context) {
    let script = r#"
        delay 1.5
        tell application "System Events" to key code 36
    "#;
    let _ = run_osascript(ctx, script, Duration::from_secs(5)).await;
}

#[derive(Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

impl CommandOutput {
    fn into_command(self) -> CommandResponse {
        CommandResponse {
            ok: self.ok,
            stdout: (!self.stdout.trim().is_empty()).then(|| shorten(&self.stdout)),
            error: (!self.ok && !self.stderr.trim().is_empty()).then(|| shorten(&self.stderr)),
            ..Default::default()
        }
    }
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

fn shorten(value: &str) -> String {
    const LIMIT: usize = 2000;
    let trimmed = value.trim();
    if trimmed.chars().count() <= LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(LIMIT - 3).collect();
    format!("{head}...")
}

fn lookup(bang: &str) -> Option<&'static (&'static str, &'static str, Option<&'static str>)> {
    PROVIDERS
        .binary_search_by(|entry| entry.0.cmp(bang))
        .ok()
        .map(|index| &PROVIDERS[index])
}

/// Percent-encode a query value for use in a URL query component (RFC
/// 3986 unreserved characters pass through, everything else becomes
/// `%XX`).
fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for &byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn main() {
    run(AiProviders);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn providers_are_alphabetically_sorted_for_binary_search() {
        for window in PROVIDERS.windows(2) {
            assert!(
                window[0].0 < window[1].0,
                "PROVIDERS must be sorted by bang for binary_search to work: \
                 {} ≥ {}",
                window[0].0,
                window[1].0
            );
        }
    }

    #[test]
    fn lookup_finds_every_registered_provider() {
        for (bang, _, _) in PROVIDERS {
            assert!(lookup(bang).is_some(), "lookup miss for !{bang}");
        }
        assert!(lookup("nonexistent").is_none());
    }

    #[test]
    fn percent_encode_passes_unreserved_and_escapes_the_rest() {
        assert_eq!(percent_encode("hello"), "hello");
        assert_eq!(percent_encode("hello world"), "hello%20world");
        assert_eq!(percent_encode("a/b?c=d"), "a%2Fb%3Fc%3Dd");
        assert_eq!(percent_encode("café"), "caf%C3%A9");
    }
}
