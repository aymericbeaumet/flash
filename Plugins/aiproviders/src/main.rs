//! AI-provider launcher and quota status owner.
//!
//! Quota refreshes run after the protocol handshake and never on status-bar
//! rendering or popup hover. The plugin immediately republishes its sanitized
//! last-good cache, then refreshes Anthropic every ten minutes and Codex every
//! two minutes. Only percentages, reset epochs, window lengths, and fetch time
//! are persisted; OAuth credentials and raw responses stay in memory.
//!
//! Claude Code keeps OAuth credentials in the login keychain, while Codex owns
//! its auth behind `codex app-server`. Those interfaces require subprocesses
//! that a deny-default plugin profile cannot access, so the manifest follows
//! the bundled GitHub plugin's `subprocess` posture. Tokens are passed through
//! stdin, never argv or logs.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::LazyLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flash_plugin::process;
use flash_plugin::{run, run_osascript, CommandRequest, Context, PerformResponse, RefreshGate};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::OnceCell;

const AUTOSEND_DELAY: Duration = Duration::from_millis(2_500);
const AUTOSEND_SCRIPT: &str = r#"tell application "System Events" to key code 36"#;

const STATUS_REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const ANTHROPIC_USAGE_TTL: u64 = 600;
const ANTHROPIC_RETRY_SECONDS: u64 = 300;
const CODEX_USAGE_TTL: u64 = 120;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(6);
const COMMAND_STDOUT_LIMIT: usize = 1024 * 1024;
const COMMAND_STDERR_LIMIT: usize = 64 * 1024;
const ANTHROPIC_CACHE: &str = "anthropic-usage-v1.json";
const CODEX_CACHE: &str = "codex-usage-v1.json";
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
struct CodexUsage {
    updated_at: u64,
    session: Option<WindowUsage>,
    weekly: Option<WindowUsage>,
}

impl CodexUsage {
    fn sanitize(mut self) -> Option<Self> {
        self.session = self.session.filter(WindowUsage::valid);
        self.weekly = self.weekly.filter(WindowUsage::valid);
        (self.session.is_some() || self.weekly.is_some()).then_some(self)
    }
}

#[derive(Clone, Debug, Default)]
struct UsageState {
    anthropic: Option<AnthropicUsage>,
    codex: Option<CodexUsage>,
}

#[derive(Debug, PartialEq, Eq)]
struct StatusSegments {
    claude_usage: String,
    claude_usage_details: String,
    fable_usage: String,
    fable_usage_details: String,
    codex_usage: String,
    codex_usage_details: String,
}

impl StatusSegments {
    #[cfg(test)]
    fn all(&self) -> [&str; 6] {
        [
            &self.claude_usage,
            &self.claude_usage_details,
            &self.fable_usage,
            &self.fable_usage_details,
            &self.codex_usage,
            &self.codex_usage_details,
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
    let codex = load_json::<CodexUsage>(&ctx.data_dir().join(CODEX_CACHE))
        .await
        .and_then(CodexUsage::sanitize);
    UsageState { anthropic, codex }
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

fn publish_status(ctx: &Context, state: &UsageState, now: u64) {
    let segments = render_status_segments(state, now);
    ctx.status([
        ("claude_usage", segments.claude_usage.as_str()),
        (
            "claude_usage_details",
            segments.claude_usage_details.as_str(),
        ),
        ("fable_usage", segments.fable_usage.as_str()),
        ("fable_usage_details", segments.fable_usage_details.as_str()),
        ("codex_usage", segments.codex_usage.as_str()),
        ("codex_usage_details", segments.codex_usage_details.as_str()),
    ]);
}

async fn refresh_usage(ctx: &Context) {
    USAGE_REFRESH_GATE
        .run(ctx, |ctx, _applications| async move {
            let now = unix_now();
            let mut state = load_usage_state(&ctx).await;
            let refresh_anthropic = state
                .anthropic
                .as_ref()
                .is_none_or(|usage| !fresh(usage.updated_at, ANTHROPIC_USAGE_TTL, now))
                && now >= ANTHROPIC_RETRY_AT.load(Ordering::Relaxed);
            let refresh_codex = state
                .codex
                .as_ref()
                .is_none_or(|usage| !fresh(usage.updated_at, CODEX_USAGE_TTL, now));

            let anthropic = async {
                if refresh_anthropic {
                    fetch_anthropic_usage(now).await
                } else {
                    None
                }
            };
            let codex = async {
                if refresh_codex {
                    fetch_codex_usage(now).await
                } else {
                    None
                }
            };
            let (anthropic, codex) = tokio::join!(anthropic, codex);

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
            if let Some(usage) = codex {
                let _ = write_json(&ctx.data_dir().join(CODEX_CACHE), &usage).await;
                state.codex = Some(usage);
            }
            publish_status(&ctx, &state, now);
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

fn parse_codex_rate_limits(raw: &str, now: u64) -> Option<CodexUsage> {
    let result = raw.lines().find_map(|line| {
        let value: Value = serde_json::from_str(line).ok()?;
        (value.get("id").and_then(Value::as_u64) == Some(2))
            .then(|| value.get("result").cloned())
            .flatten()
    })?;
    let limits = result
        .pointer("/rateLimitsByLimitId/codex")
        .or_else(|| result.get("rateLimits"))?;
    let mut windows = [limits.get("primary"), limits.get("secondary")]
        .into_iter()
        .flatten()
        .filter_map(codex_window);
    let weekly = windows
        .clone()
        .find(|window| window.window_minutes >= 1_440);
    let session = windows.find(|window| window.window_minutes < 1_440);
    CodexUsage {
        updated_at: now,
        session,
        weekly,
    }
    .sanitize()
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
    let (shared_session, claude_week, fable_week, anthropic_updated) = state
        .anthropic
        .as_ref()
        .map(|usage| {
            (
                usage.shared_session.as_ref(),
                usage.claude_week.as_ref(),
                usage.fable_week.as_ref(),
                Some(usage.updated_at),
            )
        })
        .unwrap_or((None, None, None, None));
    let (codex_session, codex_week, codex_updated) = state
        .codex
        .as_ref()
        .map(|usage| {
            (
                usage.session.as_ref(),
                usage.weekly.as_ref(),
                Some(usage.updated_at),
            )
        })
        .unwrap_or((None, None, None));

    StatusSegments {
        claude_usage: compact_window(claude_week, shared_session, now),
        claude_usage_details: usage_details(
            shared_session.map(|window| ("5-hour".to_string(), window)),
            claude_week.map(|window| ("7-day".to_string(), window)),
            anthropic_updated,
            now,
        ),
        fable_usage: compact_window(fable_week, shared_session, now),
        fable_usage_details: usage_details(
            shared_session.map(|window| ("Shared 5-hour".to_string(), window)),
            fable_week.map(|window| ("7-day".to_string(), window)),
            anthropic_updated,
            now,
        ),
        codex_usage: compact_window(codex_week, codex_session, now),
        codex_usage_details: usage_details(
            codex_session.map(|window| (window_label(window.window_minutes), window)),
            codex_week.map(|window| (window_label(window.window_minutes), window)),
            codex_updated,
            now,
        ),
    }
}

fn compact_window(weekly: Option<&WindowUsage>, session: Option<&WindowUsage>, now: u64) -> String {
    let Some(weekly) = weekly else {
        return "—".to_string();
    };
    let remaining = remaining_percent(weekly.used_percent);
    let mut value = format!("{remaining}%");
    if let Some(reset) = weekly.resets_at {
        value.push('↻');
        value.push_str(&relative_duration(reset.saturating_sub(now)));
    }
    if remaining < 20 || session.is_some_and(|window| remaining_percent(window.used_percent) == 0) {
        format!("#[fg=colour196]{value}#[default]")
    } else if ahead_of_weekly_pace(weekly, now) {
        format!("#[fg=#D08770]{value}#[default]")
    } else {
        value
    }
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

fn usage_details(
    session: Option<(String, &WindowUsage)>,
    weekly: Option<(String, &WindowUsage)>,
    updated_at: Option<u64>,
    now: u64,
) -> String {
    let mut lines = Vec::with_capacity(3);
    if let Some((label, window)) = session {
        lines.push(detail_line(&label, window, now));
    }
    if let Some((label, window)) = weekly {
        lines.push(detail_line(&label, window, now));
    }
    if lines.is_empty() {
        return "Usage unavailable".to_string();
    }
    if let Some(updated_at) = updated_at {
        lines.push(format!("Updated {}", cache_age(updated_at, now)));
    }
    lines.join("\n")
}

fn detail_line(label: &str, window: &WindowUsage, now: u64) -> String {
    let mut line = format!(
        "{label} {}% remaining",
        remaining_percent(window.used_percent)
    );
    if let Some(reset) = window.resets_at {
        line.push_str(" · resets in ");
        line.push_str(&relative_duration(reset.saturating_sub(now)));
    }
    line
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

fn cache_age(updated_at: u64, now: u64) -> String {
    let seconds = now.saturating_sub(updated_at);
    if seconds < 60 {
        "now".to_string()
    } else if seconds < 3_600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h ago", seconds / 3_600)
    } else {
        format!("{}d ago", seconds / 86_400)
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

async fn fetch_codex_usage(now: u64) -> Option<CodexUsage> {
    let codex = resolved_codex_path().await?;
    let input = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{",
        "\"clientInfo\":{\"name\":\"flash-aiproviders\",\"version\":\"1\"},",
        "\"capabilities\":{\"experimentalApi\":true,\"requestAttestation\":false}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\"}\n"
    );
    let response = capture_codex_rate_limits(&codex, input).await?;
    parse_codex_rate_limits(&response, now)
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

struct AiProviders;

flash_plugin::plugin!(AiProviders);

impl FlashPlugin for AiProviders {
    async fn on_start(&self, ctx: Context) {
        let cached = load_usage_state(&ctx).await;
        publish_status(&ctx, &cached, unix_now());

        let refresh_ctx = ctx.clone();
        tokio::spawn(async move {
            refresh_usage(&refresh_ctx).await;
        });
        drop(ctx.interval(STATUS_REFRESH_INTERVAL, |ctx| async move {
            refresh_usage(&ctx).await;
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
    fn codex_usage_classifies_windows_by_duration_not_slot() {
        let usage = parse_codex_rate_limits(
            concat!(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"rateLimits\":{",
                "\"primary\":{\"usedPercent\":35.9,\"resetsAt\":18000,\"windowDurationMins\":300},",
                "\"secondary\":{\"usedPercent\":46.1,\"resetsAt\":432000,\"windowDurationMins\":10080}",
                "}}}\n"
            ),
            0,
        )
        .expect("valid Codex rate limits");

        assert_eq!(usage.session.unwrap().window_minutes, 300);
        assert_eq!(usage.weekly.unwrap().used_percent, 46.1);
    }

    #[test]
    fn status_segments_are_compact_rich_and_never_use_question_marks() {
        let state = UsageState {
            anthropic: Some(AnthropicUsage {
                updated_at: 0,
                shared_session: Some(WindowUsage::new(20.4, Some(10_800), 300)),
                claude_week: Some(WindowUsage::new(47.2, Some(432_000), 10_080)),
                fable_week: Some(WindowUsage::new(90.1, Some(345_600), 10_080)),
            }),
            codex: Some(CodexUsage {
                updated_at: 0,
                session: Some(WindowUsage::new(35.9, Some(18_000), 300)),
                weekly: Some(WindowUsage::new(46.1, Some(432_000), 10_080)),
            }),
        };

        let segments = render_status_segments(&state, 0);
        assert_eq!(segments.claude_usage, "#[fg=#D08770]53%↻5d#[default]");
        assert_eq!(segments.codex_usage, "#[fg=#D08770]54%↻5d#[default]");
        assert!(segments.fable_usage.contains("10%↻4d"));
        assert_eq!(
            segments.claude_usage_details,
            "5-hour 80% remaining · resets in 3h\n7-day 53% remaining · resets in 5d\nUpdated now"
        );
        assert_eq!(
            segments.fable_usage_details,
            "Shared 5-hour 80% remaining · resets in 3h\n7-day 10% remaining · resets in 4d\nUpdated now"
        );
        assert_eq!(
            segments.codex_usage_details,
            "5-hour 65% remaining · resets in 5h\n7-day 54% remaining · resets in 5d\nUpdated now"
        );
        assert!(!segments.all().iter().any(|value| value.contains('?')));
    }

    #[test]
    fn unavailable_segments_are_explicit_and_never_ambiguous() {
        let segments = render_status_segments(&UsageState::default(), 0);
        assert_eq!(segments.claude_usage, "—");
        assert_eq!(segments.fable_usage, "—");
        assert_eq!(segments.codex_usage, "—");
        assert_eq!(segments.claude_usage_details, "Usage unavailable");
        assert!(!segments.all().iter().any(|value| value.contains('?')));
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
