use std::time::Duration;

use flash_plugin::{run, run_osascript, CommandRequest, Context, PerformResponse};
use serde_json::json;

const AUTOSEND_DELAY: Duration = Duration::from_millis(2_500);
const AUTOSEND_SCRIPT: &str = r#"tell application "System Events" to key code 36"#;

/// Sorted by bang token so lookup stays allocation-free.
const PROVIDERS: &[(&str, &str, &str)] = &[
    ("chatgpt", "https://chatgpt.com/", "q"),
    ("claude", "https://claude.ai/new", "q"),
    ("copilot", "https://copilot.microsoft.com/", "q"),
    ("gemini", "https://gemini.google.com/app", "q"),
    ("grok", "https://grok.com/", "q"),
    ("perplexity", "https://www.perplexity.ai/search", "q"),
];

struct AiProviders;

flash_plugin::plugin!(AiProviders);

impl FlashPlugin for AiProviders {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let bang = command.subcommand.to_ascii_lowercase();
        let Some((_, base, parameter)) = lookup(&bang) else {
            return PerformResponse::fail(format!("unknown ai provider: !{bang}"));
        };
        let query = command.query();
        let url = provider_url(base, parameter, &query);
        let opened = ctx.call_host("host.open", json!({ "url": url })).await;
        if opened.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
            let error = opened
                .get("error")
                .and_then(serde_json::Value::as_str)
                .filter(|error| !error.is_empty())
                .unwrap_or("host.open failed");
            return PerformResponse::fail(error);
        }
        if !query.is_empty() {
            tokio::time::sleep(AUTOSEND_DELAY).await;
            let _ = run_osascript(&ctx, AUTOSEND_SCRIPT, Duration::from_secs(10)).await;
        }
        PerformResponse::ok()
    }
}

fn lookup(bang: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
    PROVIDERS
        .binary_search_by(|entry| entry.0.cmp(bang))
        .ok()
        .map(|index| &PROVIDERS[index])
}

fn provider_url(base: &str, parameter: &str, query: &str) -> String {
    if query.is_empty() {
        base.to_string()
    } else {
        format!("{base}?{parameter}={}", percent_encode(query))
    }
}

/// Match `urllib.parse.quote`'s default query-value behavior: RFC 3986
/// unreserved bytes and `/` pass through, every other UTF-8 byte is `%XX`.
fn percent_encode(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn main() {
    run(AiProviders);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_table_is_sorted_and_complete() {
        assert!(PROVIDERS.windows(2).all(|pair| pair[0].0 < pair[1].0));
        for (bang, _, _) in PROVIDERS {
            assert!(lookup(bang).is_some());
        }
        assert!(lookup("unknown").is_none());
    }

    #[test]
    fn query_encoding_matches_python_quote_defaults() {
        assert_eq!(percent_encode("hello world"), "hello%20world");
        assert_eq!(percent_encode("a/b?c=d"), "a/b%3Fc%3Dd");
        assert_eq!(percent_encode("café"), "caf%C3%A9");
        assert_eq!(percent_encode("-_.~"), "-_.~");
    }

    #[test]
    fn bare_provider_uses_base_and_query_uses_q_parameter() {
        assert_eq!(
            provider_url("https://example.test/", "q", ""),
            "https://example.test/"
        );
        assert_eq!(
            provider_url("https://example.test/", "q", "hello world"),
            "https://example.test/?q=hello%20world"
        );
    }

    #[test]
    fn autosend_preserves_the_load_delay_and_return_key() {
        assert_eq!(AUTOSEND_DELAY, Duration::from_millis(2_500));
        assert_eq!(
            AUTOSEND_SCRIPT,
            r#"tell application "System Events" to key code 36"#
        );
    }
}
