use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{run, Candidate, CommandRequest, CommandResponse, Context};

// Sorted `BANGS: &[(&str, &str)]` generated from bangs.tsv at build time.
include!(concat!(env!("OUT_DIR"), "/bangs_generated.rs"));

const SOURCE_ID: &str = "plugin:searchengines";

struct SearchEngines;

flash_plugin::plugin!(SearchEngines);

impl FlashPlugin for SearchEngines {
    /// Publish every BANGS entry as a kind="bang" candidate so the host
    /// flashlight can show them as suggestion rows (with proper prefix
    /// ranking via `CandidateFinder.fieldScoreNormalized`). Without
    /// this, only aiproviders' explicit-token bangs surface as
    /// candidates and a typed `!goo` couldn't surface `!google` —
    /// dispatch worked via the catch-all but the user saw no prefix
    /// match. Catch-all routing still handles unknown tokens at submit
    /// time; this is purely about visibility.
    async fn on_start(&self, ctx: Context) {
        let candidates: Vec<Candidate> = BANGS
            .iter()
            .map(|(token, _)| {
                Candidate::new(format!("!{token}"))
                    .kind("bang")
                    .source_id(SOURCE_ID)
                    .source("searchengines.bangs")
                    .subtitle("search engine bang")
                    .payload(token.to_string())
            })
            .collect();
        ctx.set_locations(SOURCE_ID, candidates);
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        // The bang the user typed (`!r` → `r`) arrives as the subcommand; the
        // rest of the flashlight line is the query. There is no `:` command:
        // this plugin is reached only through the catch-all shebang provider.
        let bang = command.subcommand.to_ascii_lowercase();
        let Some(template) = lookup(&bang) else {
            return CommandResponse::error(format!("unknown bang: !{bang}"));
        };
        let url = template.replace("{{{s}}}", &percent_encode(&command.query()));
        run_command(
            &ctx,
            &["/usr/bin/open".to_string(), url],
            Duration::from_secs(10),
        )
        .await
        .into_command()
    }
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

/// The URL template for `bang`, or `None` when no bang matches.
fn lookup(bang: &str) -> Option<&'static str> {
    BANGS
        .binary_search_by(|&(trigger, _)| trigger.cmp(bang))
        .ok()
        .map(|index| BANGS[index].1)
}

/// Percent-encode a query for use in a URL query component. Encodes every
/// byte that is not an unreserved character (RFC 3986).
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
    run(SearchEngines);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn includes_googlemaps_bang() {
        assert_eq!(
            lookup("googlemaps"),
            Some("https://www.google.com/maps/search/{{{s}}}")
        );
    }
}
