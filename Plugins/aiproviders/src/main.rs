//! AI-provider launcher and quota status owner.
//!
//! Quota refreshes run after the protocol handshake and never on status-bar
//! rendering or popup hover. The plugin immediately republishes its sanitized
//! last-good cache, republishes changed rendered status at minute boundaries,
//! then refreshes Anthropic every ten minutes and OpenAI every two minutes.
//! Only percentages, reset epochs, window lengths, and fetch time are persisted
//! in the plugin cache; credential rotations write back only to their owning
//! stores, and raw responses stay in memory.
//!
//! Claude Code keeps OAuth credentials in the login keychain, while Codex owns
//! its auth behind `codex app-server`. Those interfaces require subprocesses
//! that a deny-default plugin profile cannot access, so the manifest follows
//! the bundled GitHub plugin's `subprocess` posture. Tokens are passed through
//! stdin, never argv or logs.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flash_plugin::process;
use flash_plugin::{run, run_osascript, CommandRequest, Context, PerformResponse, RefreshGate};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{OnceCell, RwLock};

const AUTOSEND_DELAY: Duration = Duration::from_millis(2_500);
const AUTOSEND_SCRIPT: &str = r#"tell application "System Events" to key code 36"#;

const STATUS_PUBLISH_INTERVAL: Duration = Duration::from_secs(60);
const USAGE_REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const ANTHROPIC_USAGE_TTL: u64 = 600;
const ANTHROPIC_RETRY_SECONDS: u64 = 300;
const OPENAI_USAGE_TTL: u64 = 120;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(6);
const COMMAND_STDOUT_LIMIT: usize = 1024 * 1024;
const COMMAND_STDERR_LIMIT: usize = 64 * 1024;
const ANTHROPIC_CACHE: &str = "anthropic-usage-v1.json";
const OPENAI_CACHE: &str = "openai-usage-v1.json";
const ASTRA_RATE_LIMIT_ID: &str = "codex_bengalfox";
const ANTHROPIC_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const ANTHROPIC_TOKEN_URL: &str = "https://platform.claude.com/v1/oauth/token";
const CLAUDE_OAUTH_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

static USAGE_REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static CODEX_PATH: LazyLock<OnceCell<Option<PathBuf>>> = LazyLock::new(OnceCell::new);
static ANTHROPIC_RETRY_AT: AtomicU64 = AtomicU64::new(0);

/// Sorted by bang token so lookup stays allocation-free.
const PROVIDERS: &[(&str, &str, &str)] = &[
    ("chatgpt", "https://chatgpt.com/", "q"),
    ("claude", "https://claude.ai/new", "q"),
    ("copilot", "https://copilot.microsoft.com/", "q"),
    ("gemini", "https://gemini.google.com/app", "q"),
    ("grok", "https://grok.com/", "q"),
    ("perplexity", "https://www.perplexity.ai/search", "q"),
];

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct WindowUsage {
    used_percent: f64,
    resets_at: Option<u64>,
    window_minutes: u64,
}

impl WindowUsage {
    fn new(used_percent: f64, resets_at: Option<u64>, window_minutes: u64) -> Self {
        Self {
            used_percent,
            resets_at,
            window_minutes,
        }
    }

    fn valid(&self) -> bool {
        self.used_percent.is_finite()
            && (0.0..=100.0).contains(&self.used_percent)
            && self.window_minutes > 0
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct AnthropicUsage {
    updated_at: u64,
    shared_session: Option<WindowUsage>,
    claude_week: Option<WindowUsage>,
    fable_week: Option<WindowUsage>,
}

impl AnthropicUsage {
    fn sanitize(mut self) -> Option<Self> {
        self.shared_session = self.shared_session.filter(WindowUsage::valid);
        self.claude_week = self.claude_week.filter(WindowUsage::valid);
        self.fable_week = self.fable_week.filter(WindowUsage::valid);
        (self.shared_session.is_some() || self.claude_week.is_some() || self.fable_week.is_some())
            .then_some(self)
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct UsageWindows {
    session: Option<WindowUsage>,
    weekly: Option<WindowUsage>,
}

impl UsageWindows {
    fn sanitize(mut self) -> Self {
        self.session = self.session.filter(WindowUsage::valid);
        self.weekly = self.weekly.filter(WindowUsage::valid);
        self
    }

    fn is_empty(&self) -> bool {
        self.session.is_none() && self.weekly.is_none()
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct OpenAIUsage {
    updated_at: u64,
    openai: UsageWindows,
    astra: UsageWindows,
}

impl OpenAIUsage {
    fn sanitize(mut self) -> Option<Self> {
        self.openai = self.openai.sanitize();
        self.astra = self.astra.sanitize();
        (!self.openai.is_empty() || !self.astra.is_empty()).then_some(self)
    }
}

#[derive(Clone, Debug, Default)]
struct UsageState {
    anthropic: Option<AnthropicUsage>,
    openai: Option<OpenAIUsage>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct StatusSegments {
    claude_label: String,
    claude_details: String,
    codex_label: String,
    codex_details: String,
}

#[derive(Debug, Default)]
struct UsageRuntime {
    state: UsageState,
    published: Option<StatusSegments>,
}

impl UsageRuntime {
    fn status_update(&mut self, now: u64) -> Option<StatusSegments> {
        let segments = render_status_segments(&self.state, now);
        if self.published.as_ref() == Some(&segments) {
            return None;
        }
        self.published = Some(segments.clone());
        Some(segments)
    }
}

impl StatusSegments {
    #[cfg(test)]
    fn all(&self) -> [&str; 4] {
        [
            &self.claude_label,
            &self.claude_details,
            &self.codex_label,
            &self.codex_details,
        ]
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn fresh(updated_at: u64, ttl: u64, now: u64) -> bool {
    updated_at <= now.saturating_add(60) && now.saturating_sub(updated_at) < ttl
}

async fn load_usage_state(ctx: &Context) -> UsageState {
    let anthropic = load_json::<AnthropicUsage>(&ctx.data_dir().join(ANTHROPIC_CACHE))
        .await
        .and_then(AnthropicUsage::sanitize);
    let openai = load_json::<OpenAIUsage>(&ctx.data_dir().join(OPENAI_CACHE))
        .await
        .and_then(OpenAIUsage::sanitize);
    UsageState { anthropic, openai }
}

async fn load_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let bytes = tokio::fs::read(path).await.ok()?;
    serde_json::from_slice(&bytes).ok()
}

async fn write_json<T: Serialize>(path: &Path, value: &T) -> bool {
    let Ok(bytes) = serde_json::to_vec(value) else {
        return false;
    };
    let Some(parent) = path.parent() else {
        return false;
    };
    if tokio::fs::create_dir_all(parent).await.is_err() {
        return false;
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    if tokio::fs::write(&temporary, bytes).await.is_err() {
        return false;
    }
    if tokio::fs::rename(&temporary, path).await.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
        return false;
    }
    true
}

fn publish_status(ctx: &Context, segments: &StatusSegments) {
    ctx.status([
        ("claude_label", segments.claude_label.as_str()),
        ("claude_details", segments.claude_details.as_str()),
        ("codex_label", segments.codex_label.as_str()),
        ("codex_details", segments.codex_details.as_str()),
    ]);
}

async fn publish_current_status(ctx: &Context, shared: &Arc<RwLock<UsageRuntime>>) {
    let segments = shared.write().await.status_update(unix_now());
    if let Some(segments) = segments {
        publish_status(ctx, &segments);
    }
}

async fn refresh_usage(ctx: &Context, shared: &Arc<RwLock<UsageRuntime>>) {
    let shared = Arc::clone(shared);
    USAGE_REFRESH_GATE
        .run(ctx, move |ctx, _applications| async move {
            let now = unix_now();
            let mut state = shared.read().await.state.clone();
            let refresh_anthropic = state
                .anthropic
                .as_ref()
                .is_none_or(|usage| !fresh(usage.updated_at, ANTHROPIC_USAGE_TTL, now))
                && now >= ANTHROPIC_RETRY_AT.load(Ordering::Relaxed);
            let refresh_openai = state
                .openai
                .as_ref()
                .is_none_or(|usage| !fresh(usage.updated_at, OPENAI_USAGE_TTL, now));

            let anthropic = async {
                if refresh_anthropic {
                    fetch_anthropic_usage(now).await
                } else {
                    None
                }
            };
            let openai = async {
                if refresh_openai {
                    fetch_openai_usage(now).await
                } else {
                    None
                }
            };
            let (anthropic, openai) = tokio::join!(anthropic, openai);

            if let Some(usage) = anthropic {
                ANTHROPIC_RETRY_AT.store(0, Ordering::Relaxed);
                let _ = write_json(&ctx.data_dir().join(ANTHROPIC_CACHE), &usage).await;
                state.anthropic = Some(usage);
            } else if refresh_anthropic {
                ANTHROPIC_RETRY_AT.store(
                    now.saturating_add(ANTHROPIC_RETRY_SECONDS),
                    Ordering::Relaxed,
                );
            }
            if let Some(usage) = openai {
                let _ = write_json(&ctx.data_dir().join(OPENAI_CACHE), &usage).await;
                state.openai = Some(usage);
            }
            shared.write().await.state = state;
            publish_current_status(&ctx, &shared).await;
        })
        .await;
}

fn parse_anthropic_usage(raw: &str, now: u64) -> Option<AnthropicUsage> {
    let root: Value = serde_json::from_str(raw).ok()?;
    let shared_session = anthropic_window(root.get("five_hour")?, 300);
    let claude_week = anthropic_window(root.get("seven_day")?, 10_080);
    let fable_week = root
        .get("limits")
        .and_then(Value::as_array)
        .and_then(|limits| {
            limits.iter().find(|limit| {
                limit.get("kind").and_then(Value::as_str) == Some("weekly_scoped")
                    && limit
                        .pointer("/scope/model/display_name")
                        .and_then(Value::as_str)
                        .is_some_and(|name| name.eq_ignore_ascii_case("fable"))
            })
        })
        .and_then(|limit| {
            usage_percent(limit.get("percent")?).map(|used| {
                WindowUsage::new(
                    used,
                    limit
                        .get("resets_at")
                        .and_then(Value::as_str)
                        .and_then(parse_rfc3339_epoch),
                    10_080,
                )
            })
        });

    AnthropicUsage {
        updated_at: now,
        shared_session,
        claude_week,
        fable_week,
    }
    .sanitize()
}

fn anthropic_window(value: &Value, window_minutes: u64) -> Option<WindowUsage> {
    let used = usage_percent(value.get("utilization")?)?;
    let resets_at = value
        .get("resets_at")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_epoch);
    Some(WindowUsage::new(used, resets_at, window_minutes))
}

fn parse_openai_rate_limits(raw: &str, now: u64) -> Option<OpenAIUsage> {
    let result = raw.lines().find_map(|line| {
        let value: Value = serde_json::from_str(line).ok()?;
        (value.get("id").and_then(Value::as_u64) == Some(2))
            .then(|| value.get("result").cloned())
            .flatten()
    })?;
    let openai = result
        .pointer("/rateLimitsByLimitId/codex")
        .or_else(|| result.get("rateLimits"))
        .map(rate_limit_windows)
        .unwrap_or_default();
    let astra = result
        .pointer(&format!("/rateLimitsByLimitId/{ASTRA_RATE_LIMIT_ID}"))
        .map(rate_limit_windows)
        .unwrap_or_default();
    OpenAIUsage {
        updated_at: now,
        openai,
        astra,
    }
    .sanitize()
}

fn rate_limit_windows(limits: &Value) -> UsageWindows {
    let mut windows = [limits.get("primary"), limits.get("secondary")]
        .into_iter()
        .flatten()
        .filter_map(codex_window);
    let weekly = windows
        .clone()
        .find(|window| window.window_minutes >= 1_440);
    let session = windows.find(|window| window.window_minutes < 1_440);
    UsageWindows { session, weekly }.sanitize()
}

fn codex_window(value: &Value) -> Option<WindowUsage> {
    let used = usage_percent(value.get("usedPercent")?)?;
    let window_minutes = value.get("windowDurationMins")?.as_u64()?;
    let resets_at = value.get("resetsAt").and_then(Value::as_u64);
    Some(WindowUsage::new(used, resets_at, window_minutes))
}

fn usage_percent(value: &Value) -> Option<f64> {
    let value = value.as_f64()?;
    (value.is_finite() && (0.0..=100.0).contains(&value)).then_some(value)
}

fn render_status_segments(state: &UsageState, now: u64) -> StatusSegments {
    let (shared_session, claude_week, fable_week) = state
        .anthropic
        .as_ref()
        .map(|usage| {
            (
                usage.shared_session.as_ref(),
                usage.claude_week.as_ref(),
                usage.fable_week.as_ref(),
            )
        })
        .unwrap_or((None, None, None));
    let (openai_session, openai_week, astra_session, astra_week) = state
        .openai
        .as_ref()
        .map(|usage| {
            (
                usage.openai.session.as_ref(),
                usage.openai.weekly.as_ref(),
                usage.astra.session.as_ref(),
                usage.astra.weekly.as_ref(),
            )
        })
        .unwrap_or((None, None, None, None));
    let openai_session_label = usage_window_label(openai_session, "5-hour");
    let openai_week_label = usage_window_label(openai_week, "7-day");
    let astra_session_label = usage_window_label(astra_session, "5-hour");
    let astra_week_label = usage_window_label(astra_week, "7-day");
    let heading = "#[fg=colour245]Provider  Window         Left  Reset#[default]";
    let claude_details = [
        "#[fg=#EBCB8B]Claude quotas#[default]".to_string(),
        heading.to_string(),
        popup_row("Claude", "5-hour", shared_session, None, now),
        popup_row("", "7-day", claude_week, shared_session, now),
        popup_row("  Fable", "7-day", fable_week, shared_session, now),
    ]
    .join("\n");
    let codex_details = [
        "#[fg=#EBCB8B]Codex quotas#[default]".to_string(),
        heading.to_string(),
        popup_row("Codex", &openai_session_label, openai_session, None, now),
        popup_row("", &openai_week_label, openai_week, openai_session, now),
        popup_row("  Astra", &astra_session_label, astra_session, None, now),
        popup_row("", &astra_week_label, astra_week, astra_session, now),
    ]
    .join("\n");
    StatusSegments {
        claude_label: quota_label(
            "Cld",
            [shared_session, claude_week].into_iter().filter(|_| {
                state
                    .anthropic
                    .as_ref()
                    .is_some_and(|usage| fresh(usage.updated_at, 2 * ANTHROPIC_USAGE_TTL, now))
            }),
        ),
        claude_details,
        codex_label: quota_label(
            "Cdx",
            [openai_session, openai_week].into_iter().filter(|_| {
                state
                    .openai
                    .as_ref()
                    .is_some_and(|usage| fresh(usage.updated_at, 2 * OPENAI_USAGE_TTL, now))
            }),
        ),
        codex_details,
    }
}

fn quota_label<'a>(
    label: &str,
    windows: impl IntoIterator<Item = Option<&'a WindowUsage>>,
) -> String {
    let metric = windows
        .into_iter()
        .flatten()
        .map(|window| remaining_percent(window.used_percent))
        .min()
        .map(|remaining| format!("{remaining:>3}%"))
        .unwrap_or_else(|| "   —".to_string());
    format!("#[fg=#EBCB8B]{label} #[fg=colour245]{metric}#[default]")
}

fn usage_window_label(usage: Option<&WindowUsage>, fallback: &str) -> String {
    usage
        .map(|window| window_label(window.window_minutes))
        .unwrap_or_else(|| fallback.to_string())
}

fn styled_remaining(
    weekly: Option<&WindowUsage>,
    session: Option<&WindowUsage>,
    now: u64,
) -> String {
    let Some(weekly) = weekly else {
        return "   —".to_string();
    };
    let remaining = remaining_percent(weekly.used_percent);
    let value = format!("{remaining:>3}%");
    if remaining < 20 || session.is_some_and(|window| remaining_percent(window.used_percent) == 0) {
        format!("#[fg=colour196]{value}#[default]")
    } else if ahead_of_weekly_pace(weekly, now) {
        format!("#[fg=#D08770]{value}#[default]")
    } else {
        value
    }
}

fn popup_row(
    provider: &str,
    window_label: &str,
    usage: Option<&WindowUsage>,
    pace_session: Option<&WindowUsage>,
    now: u64,
) -> String {
    let remaining = styled_remaining(usage, pace_session, now);
    let reset = usage
        .and_then(|window| window.resets_at)
        .map(|reset| relative_duration(reset.saturating_sub(now)))
        .unwrap_or_else(|| "—".to_string());
    format!("#[fg=colour245]{provider:<8}  {window_label:<13}#[default]  {remaining}  {reset}")
}

fn ahead_of_weekly_pace(window: &WindowUsage, now: u64) -> bool {
    if window.window_minutes != 10_080 {
        return false;
    }
    let Some(reset) = window.resets_at else {
        return false;
    };
    let duration = window.window_minutes * 60;
    let remaining = reset.saturating_sub(now);
    if remaining > duration {
        return false;
    }
    let elapsed = duration - remaining;
    let allowed_days = (elapsed / 86_400 + 1).min(7);
    window.used_percent * 7.0 > allowed_days as f64 * 100.0
}

fn remaining_percent(used: f64) -> u8 {
    (100_i64 - used.floor() as i64).clamp(0, 100) as u8
}

fn relative_duration(seconds: u64) -> String {
    if seconds < 3_600 {
        format!("{}min", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3_600)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

fn window_label(minutes: u64) -> String {
    if minutes >= 1_440 && minutes.is_multiple_of(1_440) {
        format!("{}-day", minutes / 1_440)
    } else if minutes >= 60 && minutes.is_multiple_of(60) {
        format!("{}-hour", minutes / 60)
    } else {
        format!("{minutes}-minute")
    }
}

fn parse_rfc3339_epoch(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return None;
    }
    let year = decimal(bytes.get(0..4)?)? as i64;
    let month = decimal(bytes.get(5..7)?)? as i64;
    let day = decimal(bytes.get(8..10)?)? as i64;
    let hour = decimal(bytes.get(11..13)?)? as i64;
    let minute = decimal(bytes.get(14..16)?)? as i64;
    let second = decimal(bytes.get(17..19)?)? as i64;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let zone_index = value[19..].find(['Z', '+', '-']).map(|index| index + 19)?;
    let offset = match bytes[zone_index] {
        b'Z' if zone_index + 1 == bytes.len() => 0,
        b'+' | b'-' if zone_index + 6 == bytes.len() && bytes[zone_index + 3] == b':' => {
            let offset_hour = decimal(&bytes[zone_index + 1..zone_index + 3])? as i64;
            let offset_minute = decimal(&bytes[zone_index + 4..zone_index + 6])? as i64;
            if offset_hour > 23 || offset_minute > 59 {
                return None;
            }
            let seconds = offset_hour * 3_600 + offset_minute * 60;
            if bytes[zone_index] == b'+' {
                seconds
            } else {
                -seconds
            }
        }
        _ => return None,
    };
    let days = days_from_civil(year, month, day)?;
    let epoch = days * 86_400 + hour * 3_600 + minute * 60 + second - offset;
    u64::try_from(epoch).ok()
}

fn decimal(bytes: &[u8]) -> Option<u64> {
    bytes.iter().try_fold(0_u64, |value, byte| {
        byte.is_ascii_digit()
            .then_some(value * 10 + u64::from(byte - b'0'))
    })
}

fn days_from_civil(year: i64, month: i64, day: i64) -> Option<i64> {
    let leap = |year: i64| year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days_in_month = match month {
        2 if leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return None,
    };
    if day < 1 || day > days_in_month {
        return None;
    }
    let adjusted_year = year - i64::from(month <= 2);
    let era = if adjusted_year >= 0 {
        adjusted_year
    } else {
        adjusted_year - 399
    } / 400;
    let year_of_era = adjusted_year - era * 400;
    let shifted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

#[derive(Debug)]
struct CapturedOutput {
    stdout: String,
}

async fn capture(
    program: &Path,
    args: &[&str],
    stdin: Option<Vec<u8>>,
    timeout: Duration,
) -> Option<CapturedOutput> {
    let mut command = Command::new(program);
    command.args(args);
    let output = process::capture(
        &mut command,
        stdin,
        timeout,
        COMMAND_STDOUT_LIMIT,
        COMMAND_STDERR_LIMIT,
    )
    .await
    .ok()?;
    output.status.success().then(|| CapturedOutput {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
    })
}

#[derive(Debug)]
enum CredentialStore {
    Keychain { account: String, service: String },
    File(PathBuf),
}

#[derive(Debug)]
struct ClaudeCredentials {
    value: Value,
    store: CredentialStore,
}

async fn fetch_anthropic_usage(now: u64) -> Option<AnthropicUsage> {
    let token = claude_access_token(now).await?;
    let mut curl_config = format!(
        "header = \"Authorization: Bearer {token}\"\n\
         header = \"Content-Type: application/json\"\n\
         header = \"anthropic-version: 2023-06-01\"\n\
         header = \"anthropic-beta: oauth-2025-04-20\"\n\
         header = \"anthropic-client-platform: macos\"\n\
         header = \"User-Agent: claude-code/flash-status\"\n"
    );
    if let Some(organization) = claude_organization_uuid().await {
        curl_config.push_str(&format!(
            "header = \"x-organization-uuid: {organization}\"\n"
        ));
    }
    let response = capture(
        Path::new("/usr/bin/curl"),
        &["-fsS", "--max-time", "5", "-K", "-", ANTHROPIC_USAGE_URL],
        Some(curl_config.into_bytes()),
        COMMAND_TIMEOUT,
    )
    .await?;
    parse_anthropic_usage(&response.stdout, now)
}

async fn claude_access_token(now: u64) -> Option<String> {
    let mut credentials = load_claude_credentials().await?;
    let expires_at = credentials
        .value
        .pointer("/claudeAiOauth/expiresAt")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    if expires_at <= now.saturating_add(120).saturating_mul(1_000) {
        refresh_claude_credentials(&mut credentials, now).await?;
    }
    credentials
        .value
        .pointer("/claudeAiOauth/accessToken")
        .and_then(Value::as_str)
        .filter(|token| safe_header_value(token))
        .map(str::to_string)
}

async fn load_claude_credentials() -> Option<ClaudeCredentials> {
    let user = std::env::var("USER")
        .ok()
        .filter(|value| safe_keychain_name(value))
        .unwrap_or_else(|| "claude-code-user".to_string());
    let service = "Claude Code-credentials".to_string();
    let output = capture(
        Path::new("/usr/bin/security"),
        &["find-generic-password", "-a", &user, "-s", &service, "-w"],
        None,
        Duration::from_secs(3),
    )
    .await;
    if let Some(output) = output {
        if let Ok(value) = serde_json::from_str(output.stdout.trim()) {
            return Some(ClaudeCredentials {
                value,
                store: CredentialStore::Keychain {
                    account: user,
                    service,
                },
            });
        }
    }

    let home = user_home()?;
    let path = home.join(".claude/.credentials.json");
    let value = load_json(&path).await?;
    Some(ClaudeCredentials {
        value,
        store: CredentialStore::File(path),
    })
}

async fn refresh_claude_credentials(credentials: &mut ClaudeCredentials, now: u64) -> Option<()> {
    let refresh_token = credentials
        .value
        .pointer("/claudeAiOauth/refreshToken")
        .and_then(Value::as_str)?;
    if !safe_header_value(refresh_token) {
        return None;
    }
    let body = serde_json::to_vec(&json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLAUDE_OAUTH_CLIENT_ID,
    }))
    .ok()?;
    let response = capture(
        Path::new("/usr/bin/curl"),
        &[
            "-fsS",
            "--max-time",
            "5",
            "-H",
            "Accept: application/json",
            "-H",
            "Content-Type: application/json",
            "-H",
            "anthropic-beta: oauth-2025-04-20",
            "-H",
            "User-Agent: anthropic-sdk-typescript/0.94.0 userOAuthProvider",
            "--data-binary",
            "@-",
            ANTHROPIC_TOKEN_URL,
        ],
        Some(body),
        COMMAND_TIMEOUT,
    )
    .await?;
    let refreshed: Value = serde_json::from_str(&response.stdout).ok()?;
    let access_token = refreshed.get("access_token")?.as_str()?;
    if access_token.is_empty() || !safe_header_value(access_token) {
        return None;
    }
    let refresh_token = refreshed
        .get("refresh_token")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(refresh_token)
        .to_string();
    let expires_in = refreshed
        .get("expires_in")
        .and_then(Value::as_u64)
        .unwrap_or(3_600);
    let oauth = credentials
        .value
        .get_mut("claudeAiOauth")?
        .as_object_mut()?;
    oauth.insert("accessToken".to_string(), json!(access_token));
    oauth.insert("refreshToken".to_string(), json!(refresh_token));
    oauth.insert(
        "expiresAt".to_string(),
        json!(now.saturating_add(expires_in).saturating_mul(1_000)),
    );
    if let Some(refresh_expires_in) = refreshed
        .get("refresh_token_expires_in")
        .and_then(Value::as_u64)
    {
        oauth.insert(
            "refreshTokenExpiresAt".to_string(),
            json!(now.saturating_add(refresh_expires_in).saturating_mul(1_000)),
        );
    }
    let _ = store_claude_credentials(credentials).await;
    Some(())
}

async fn store_claude_credentials(credentials: &ClaudeCredentials) -> bool {
    let Ok(body) = serde_json::to_vec(&credentials.value) else {
        return false;
    };
    match &credentials.store {
        CredentialStore::Keychain { account, service } => capture(
            Path::new("/usr/bin/security"),
            &[
                "add-generic-password",
                "-U",
                "-a",
                account,
                "-s",
                service,
                "-w",
            ],
            Some(body),
            Duration::from_secs(3),
        )
        .await
        .is_some(),
        CredentialStore::File(path) => write_secret(path, &body).await,
    }
}

async fn write_secret(path: &Path, body: &[u8]) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    if tokio::fs::create_dir_all(parent).await.is_err() {
        return false;
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let opened = tokio::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .await;
    let Ok(mut file) = opened else {
        return false;
    };
    if file.write_all(body).await.is_err() || file.flush().await.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
        return false;
    }
    drop(file);
    if tokio::fs::rename(&temporary, path).await.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
        return false;
    }
    true
}

async fn claude_organization_uuid() -> Option<String> {
    let home = user_home()?;
    let preferred = home.join(".claude/.config.json");
    let path = if tokio::fs::metadata(&preferred).await.is_ok() {
        preferred
    } else {
        home.join(".claude.json")
    };
    let value: Value = load_json(&path).await?;
    value
        .pointer("/oauthAccount/organizationUuid")
        .and_then(Value::as_str)
        .filter(|value| safe_header_value(value))
        .map(str::to_string)
}

fn user_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn safe_header_value(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && byte != b'"' && byte != b'\\')
}

fn safe_keychain_name(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

async fn fetch_openai_usage(now: u64) -> Option<OpenAIUsage> {
    let codex = resolved_codex_path().await?;
    let input = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{",
        "\"clientInfo\":{\"name\":\"flash-aiproviders\",\"version\":\"1\"},",
        "\"capabilities\":{\"experimentalApi\":true,\"requestAttestation\":false}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\"}\n"
    );
    let response = capture_codex_rate_limits(&codex, input).await?;
    parse_openai_rate_limits(&response, now)
}

async fn capture_codex_rate_limits(codex: &Path, input: &str) -> Option<String> {
    let mut command = Command::new(codex);
    command
        .args(["app-server", "--stdio"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    stdin.write_all(input.as_bytes()).await.ok()?;
    stdin.flush().await.ok()?;
    let stdout = child.stdout.take()?.take((COMMAND_STDOUT_LIMIT + 1) as u64);
    let mut lines = BufReader::new(stdout).lines();
    let response = tokio::time::timeout(COMMAND_TIMEOUT, async {
        while let Some(line) = lines.next_line().await.ok()? {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if value.get("id").and_then(Value::as_u64) == Some(2) {
                    return Some(line);
                }
            }
        }
        None
    })
    .await
    .ok()
    .flatten();
    drop(stdin);
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_secs(1), child.wait()).await;
    response
}

async fn resolved_codex_path() -> Option<PathBuf> {
    CODEX_PATH.get_or_init(find_codex).await.clone()
}

async fn find_codex() -> Option<PathBuf> {
    let home = user_home();
    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/opt/local/bin/codex"),
        PathBuf::from("/usr/bin/codex"),
    ];
    if let Some(home) = &home {
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".local/share/mise/shims/codex"));
    }
    if let Some(path) = find_on_path("codex") {
        candidates.push(path);
    }
    for path in candidates {
        if executable_file(&path).await {
            return Some(path);
        }
    }

    let mut mise_candidates = vec![
        PathBuf::from("/opt/homebrew/bin/mise"),
        PathBuf::from("/opt/local/bin/mise"),
    ];
    if let Some(home) = &home {
        mise_candidates.push(home.join(".local/bin/mise"));
    }
    if let Some(path) = find_on_path("mise") {
        mise_candidates.push(path);
    }
    for mise in mise_candidates {
        if !executable_file(&mise).await {
            continue;
        }
        if let Some(output) = capture(&mise, &["which", "codex"], None, COMMAND_TIMEOUT).await {
            let path = PathBuf::from(output.stdout.trim());
            if executable_file(&path).await {
                return Some(path);
            }
        }
    }

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let output = capture(
        Path::new(&shell),
        &["-lic", "command -v codex"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let path = PathBuf::from(output.stdout.lines().next()?.trim());
    executable_file(&path).await.then_some(path)
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

async fn executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    tokio::fs::metadata(path)
        .await
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

struct AiProviders {
    usage: Arc<RwLock<UsageRuntime>>,
}

impl Default for AiProviders {
    fn default() -> Self {
        Self {
            usage: Arc::new(RwLock::new(UsageRuntime::default())),
        }
    }
}

flash_plugin::plugin!(AiProviders);

impl FlashPlugin for AiProviders {
    async fn on_start(&self, ctx: Context) {
        let cached = load_usage_state(&ctx).await;
        *self.usage.write().await = UsageRuntime {
            state: cached,
            published: None,
        };
        publish_current_status(&ctx, &self.usage).await;

        let refresh_ctx = ctx.clone();
        let refresh_usage_state = Arc::clone(&self.usage);
        tokio::spawn(async move {
            refresh_usage(&refresh_ctx, &refresh_usage_state).await;
        });
        let publish_usage_state = Arc::clone(&self.usage);
        drop(ctx.interval(STATUS_PUBLISH_INTERVAL, move |ctx| {
            let usage = Arc::clone(&publish_usage_state);
            async move {
                publish_current_status(&ctx, &usage).await;
            }
        }));
        let refresh_usage_state = Arc::clone(&self.usage);
        drop(ctx.interval(USAGE_REFRESH_INTERVAL, move |ctx| {
            let usage = Arc::clone(&refresh_usage_state);
            async move {
                refresh_usage(&ctx, &usage).await;
            }
        }));
    }

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
    run(AiProviders::default());
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

    #[test]
    fn anthropic_usage_parses_claude_fable_and_the_shared_session() {
        let usage = parse_anthropic_usage(
            r#"{
              "five_hour":{"utilization":20.4,"resets_at":"1970-01-01T03:00:00Z"},
              "seven_day":{"utilization":47.2,"resets_at":"1970-01-06T00:00:00Z"},
              "limits":[
                {"kind":"weekly_scoped","scope":{"model":{"display_name":"Other"}},"percent":4},
                {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":90.1,"resets_at":"1970-01-05T00:00:00Z"}
              ]
            }"#,
            0,
        )
        .expect("valid Anthropic usage");

        assert_eq!(usage.updated_at, 0);
        assert_eq!(usage.shared_session.unwrap().used_percent, 20.4);
        assert_eq!(usage.claude_week.unwrap().resets_at, Some(5 * 86_400));
        assert_eq!(usage.fable_week.unwrap().used_percent, 90.1);
    }

    #[test]
    fn openai_usage_classifies_base_and_astra_windows_by_duration() {
        let usage = parse_openai_rate_limits(
            concat!(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"rateLimitsByLimitId\":{",
                "\"codex\":{\"primary\":{\"usedPercent\":46.1,\"resetsAt\":432000,\"windowDurationMins\":10080}},",
                "\"codex_bengalfox\":{",
                "\"primary\":{\"usedPercent\":35.9,\"resetsAt\":18000,\"windowDurationMins\":300},",
                "\"secondary\":{\"usedPercent\":12.5,\"resetsAt\":604800,\"windowDurationMins\":10080}",
                "}}}}\n"
            ),
            0,
        )
        .expect("valid OpenAI rate limits");

        assert!(usage.openai.session.is_none());
        assert_eq!(usage.openai.weekly.unwrap().used_percent, 46.1);
        assert_eq!(usage.astra.session.unwrap().window_minutes, 300);
        assert_eq!(usage.astra.weekly.unwrap().used_percent, 12.5);
    }

    #[test]
    fn status_segments_split_providers_and_show_the_tightest_shared_quota() {
        let state = UsageState {
            anthropic: Some(AnthropicUsage {
                updated_at: 0,
                shared_session: Some(WindowUsage::new(20.4, Some(10_800), 300)),
                claude_week: Some(WindowUsage::new(47.2, Some(432_000), 10_080)),
                fable_week: Some(WindowUsage::new(90.1, Some(345_600), 10_080)),
            }),
            openai: Some(OpenAIUsage {
                updated_at: 0,
                openai: UsageWindows {
                    session: Some(WindowUsage::new(35.9, Some(18_000), 300)),
                    weekly: Some(WindowUsage::new(46.1, Some(432_000), 10_080)),
                },
                astra: UsageWindows {
                    session: Some(WindowUsage::new(12.0, Some(10_800), 300)),
                    weekly: Some(WindowUsage::new(99.0, Some(604_800), 10_080)),
                },
            }),
        };
        let segments = render_status_segments(&state, 0);
        assert_eq!(
            segments.claude_label,
            "#[fg=#EBCB8B]Cld #[fg=colour245] 53%#[default]"
        );
        assert_eq!(
            segments.codex_label,
            "#[fg=#EBCB8B]Cdx #[fg=colour245] 54%#[default]"
        );
        assert!(segments.claude_details.contains("Claude"));
        assert!(segments.claude_details.contains("Fable"));
        assert!(!segments.claude_details.contains("Codex"));
        assert!(segments.codex_details.contains("Codex"));
        assert!(segments.codex_details.contains("Astra"));
        assert!(!segments.codex_details.contains("Claude"));
        for label in [&segments.claude_label, &segments.codex_label] {
            assert!(!label.contains("#[popup="));
            assert!(!label.contains("#[link="));
        }
    }

    #[test]
    fn quota_labels_reserve_four_columns_including_unavailable_and_full() {
        for (used, expected) in [(0.0, "100%"), (91.0, "  9%"), (100.0, "  0%")] {
            let window = WindowUsage::new(used, None, 300);
            assert_eq!(
                quota_label("Cld", [Some(&window)]),
                format!("#[fg=#EBCB8B]Cld #[fg=colour245]{expected}#[default]")
            );
        }
        let segments = render_status_segments(&UsageState::default(), 0);
        assert_eq!(
            segments.claude_label,
            "#[fg=#EBCB8B]Cld #[fg=colour245]   —#[default]"
        );
        assert_eq!(
            segments.codex_label,
            "#[fg=#EBCB8B]Cdx #[fg=colour245]   —#[default]"
        );
        assert!(!segments.all().iter().any(|value| value.contains("?%")));
    }

    #[test]
    fn stale_quota_labels_become_unavailable_without_discarding_cached_details() {
        let state = UsageState {
            anthropic: Some(AnthropicUsage {
                updated_at: 1_000,
                shared_session: Some(WindowUsage::new(25.0, None, 300)),
                ..AnthropicUsage::default()
            }),
            openai: Some(OpenAIUsage {
                updated_at: 1_000,
                openai: UsageWindows {
                    session: Some(WindowUsage::new(40.0, None, 300)),
                    weekly: None,
                },
                ..OpenAIUsage::default()
            }),
        };
        let current = render_status_segments(&state, 1_000);
        assert!(current.claude_label.contains(" 75%"));
        assert!(current.codex_label.contains(" 60%"));
        let old = render_status_segments(&state, 1_000 + 2 * ANTHROPIC_USAGE_TTL);
        assert!(old.claude_label.contains("   —"));
        assert!(old.codex_label.contains("   —"));
        assert!(old.claude_details.contains("75%"));
        assert!(old.codex_details.contains("60%"));
    }

    #[test]
    fn runtime_publishes_only_changed_rendered_status() {
        let mut runtime = UsageRuntime {
            state: UsageState {
                openai: Some(OpenAIUsage {
                    updated_at: 0,
                    openai: UsageWindows {
                        session: None,
                        weekly: Some(WindowUsage::new(25.0, Some(3_600), 10_080)),
                    },
                    astra: UsageWindows::default(),
                }),
                ..UsageState::default()
            },
            published: None,
        };

        assert!(runtime.status_update(0).is_some());
        assert!(runtime.status_update(0).is_none());
        assert!(runtime.status_update(60).is_some());
        assert!(runtime.status_update(60).is_none());
    }

    #[test]
    fn publishing_and_provider_fetching_have_independent_cadences() {
        assert_eq!(STATUS_PUBLISH_INTERVAL, Duration::from_secs(60));
        assert_eq!(USAGE_REFRESH_INTERVAL, Duration::from_secs(60));
        assert_eq!(ANTHROPIC_USAGE_TTL, 600);
        assert_eq!(OPENAI_USAGE_TTL, 120);
    }

    #[test]
    fn rfc3339_parser_handles_zulu_and_offsets() {
        assert_eq!(parse_rfc3339_epoch("1970-01-02T00:00:00Z"), Some(86_400));
        assert_eq!(
            parse_rfc3339_epoch("1970-01-02T01:30:00+01:30"),
            Some(86_400)
        );
        assert_eq!(parse_rfc3339_epoch("not-a-date"), None);
    }
}
