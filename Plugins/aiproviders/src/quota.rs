//! The weekly AI quotas, rendered as only the metric (`6%↻22h`).
//!
//! A reading, once stored, stays until a newer sample replaces it: a missing
//! file, a failed fetch, or an expired token never becomes an em dash. Every
//! tracked window is weekly, so once a stored reset has passed the window
//! rolls forward: the quota is full and the countdown points at the
//! following reset. The dash is only for a provider that has never produced
//! a weekly window.
//!
//! Every provider is read through what its own CLI already stored: Claude
//! Code's OAuth credentials, `codex app-server`, and Grok's auth file. A
//! token is only ever read and sent to its own issuer, never refreshed or
//! written. Everything here is pure except the fetchers at the bottom.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tokio::process::Command;

pub const UNKNOWN: &str = "\u{2014}";
pub const ARROW: char = '\u{21bb}';
/// A fetched reading is reused for two minutes.
pub const FETCH_TTL: u64 = 120;
/// A failed fetch waits five minutes before the next attempt.
pub const RETRY_SECONDS: u64 = 300;
pub const WEEK_SECONDS: u64 = 7 * 86_400;
/// Epochs at or above this are milliseconds.
const MILLIS_THRESHOLD: f64 = 100_000_000_000.0;
const MINUTE: u64 = 60;
const HOUR: u64 = 3_600;
const DAY: i64 = 86_400;

pub const GROK_USAGE_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
/// The login Keychain item Claude Code keeps its OAuth credentials in.
pub const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";
const CURL: &str = "/usr/bin/curl";
const SECURITY: &str = "/usr/bin/security";
const FETCH_TIMEOUT: Duration = Duration::from_secs(6);
pub const STDOUT_LIMIT: usize = 1024 * 1024;
pub const STDERR_LIMIT: usize = 64 * 1024;

/// One quota segment. The manifest `status` names are these segments.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Quota {
    Claude,
    Codex,
    Grok,
}

impl Quota {
    pub const ALL: [Quota; 3] = [Quota::Claude, Quota::Codex, Quota::Grok];

    pub fn segment(self) -> &'static str {
        match self {
            Quota::Claude => "claude",
            Quota::Codex => "codex",
            Quota::Grok => "grok",
        }
    }

    pub fn from_segment(segment: &str) -> Option<Quota> {
        Quota::ALL
            .into_iter()
            .find(|quota| quota.segment() == segment)
    }
}

/// One provider's stored state: the last weekly window, when it was fetched,
/// and when a failed fetch may be retried. Percentages and times only.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Entry {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used_percent: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<u64>,
}

impl Entry {
    /// A freshly parsed weekly window.
    pub fn window(used_percent: f64, resets_at: Option<u64>) -> Self {
        Self {
            used_percent: Some(used_percent),
            resets_at,
            ..Self::default()
        }
    }

    pub fn has_reading(&self) -> bool {
        self.used_percent.is_some()
    }
}

/// Every provider's entry, as persisted in the plugin's data directory.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct QuotaState {
    entries: BTreeMap<Quota, Entry>,
}

impl QuotaState {
    pub fn get(&self, quota: Quota) -> Option<&Entry> {
        self.entries.get(&quota)
    }

    pub fn entry(&self, quota: Quota) -> Entry {
        self.get(quota).cloned().unwrap_or_default()
    }

    pub fn set(&mut self, quota: Quota, entry: Entry) {
        self.entries.insert(quota, entry);
    }

    /// Lenient per provider, like the script: an unreadable entry is no
    /// reading, and the others survive it.
    pub fn from_json(bytes: &[u8]) -> Self {
        let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
            return Self::default();
        };
        let entries = Quota::ALL
            .into_iter()
            .filter_map(|quota| {
                let object = root.get(quota.segment())?.as_object()?;
                let integer = |key: &str| object.get(key).and_then(Value::as_u64);
                Some((
                    quota,
                    Entry {
                        used_percent: object.get("used_percent").and_then(Value::as_f64),
                        resets_at: integer("resets_at"),
                        fetched_at: integer("fetched_at"),
                        retry_at: integer("retry_at"),
                    },
                ))
            })
            .collect();
        Self { entries }
    }

    pub fn to_json(&self) -> Vec<u8> {
        let object: BTreeMap<&str, &Entry> = self
            .entries
            .iter()
            .map(|(quota, entry)| (quota.segment(), entry))
            .collect();
        let mut bytes = serde_json::to_vec(&object).unwrap_or_default();
        bytes.push(b'\n');
        bytes
    }
}

// -- Rendering --------------------------------------------------------------

/// Whole percent left, capped at 99 so the bar never widens to `100%`.
pub fn remaining_percent(used: f64) -> i64 {
    (100 - used.floor() as i64).clamp(0, 100).min(99)
}

/// The machine's UTC offset, in seconds, at `epoch`.
pub fn local_utc_offset(epoch: u64) -> i64 {
    let Ok(time) = libc::time_t::try_from(epoch) else {
        return 0;
    };
    // SAFETY: `localtime_r` writes only into the caller-owned `tm`, which
    // is plain old data; a null return leaves it unused.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&time, &mut tm).is_null() {
            0
        } else {
            tm.tm_gmtoff
        }
    }
}

fn local_day(epoch: u64, offset: &dyn Fn(u64) -> i64) -> i64 {
    (epoch as i64 + offset(epoch)).div_euclid(DAY)
}

/// `30min`, `20h`, then whole local calendar days (`1d` at least).
pub fn quota_reset_delay(now: u64, reset: u64, offset: &dyn Fn(u64) -> i64) -> String {
    let remaining = reset.saturating_sub(now);
    if remaining < HOUR {
        return format!("{}min", remaining / MINUTE);
    }
    if remaining < DAY as u64 {
        return format!("{}h", remaining / HOUR);
    }
    let days = local_day(reset, offset) - local_day(now, offset);
    format!("{}d", days.max(1))
}

/// The used percentage and reset of the window open at `now`: a weekly
/// window whose reset has passed rolls forward, full, to its next reset.
pub fn current_window(entry: &Entry, now: u64) -> Option<(f64, Option<u64>)> {
    let used = entry.used_percent?;
    let Some(mut reset) = entry.resets_at else {
        return Some((used, None));
    };
    if reset <= now {
        reset += ((now - reset) / WEEK_SECONDS + 1) * WEEK_SECONDS;
        return Some((0.0, Some(reset)));
    }
    Some((used, Some(reset)))
}

pub fn metric(entry: Option<&Entry>, now: u64, offset: &dyn Fn(u64) -> i64) -> String {
    let Some((used, reset)) = entry.and_then(|entry| current_window(entry, now)) else {
        return UNKNOWN.to_string();
    };
    let mut text = format!("{}%", remaining_percent(used));
    if let Some(reset) = reset {
        text.push(ARROW);
        text.push_str(&quota_reset_delay(now, reset, offset));
    }
    text
}

// -- Parsing ----------------------------------------------------------------

pub fn usage_percent(value: Option<&Value>) -> Option<f64> {
    let value = value?.as_f64()?;
    (value.is_finite() && (0.0..=100.0).contains(&value)).then_some(value)
}

/// Seconds since the epoch from a number (milliseconds when at least 1e11)
/// or an RFC 3339 string.
pub fn parse_epoch(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(number) => {
            let seconds = match number.as_u64() {
                Some(integer) => integer,
                None => {
                    let float = number.as_f64()?;
                    if !float.is_finite() || float < 0.0 {
                        return None;
                    }
                    float as u64
                }
            };
            Some(if seconds as f64 >= MILLIS_THRESHOLD {
                seconds / 1_000
            } else {
                seconds
            })
        }
        Value::String(text) => parse_rfc3339(text),
        _ => None,
    }
}

/// A usage window from any provider's spelling of the used percentage and
/// the reset.
pub fn window_from(value: Option<&Value>) -> Option<Entry> {
    let object = value?.as_object()?;
    let used = ["used_percent", "used_percentage", "usedPercent"]
        .into_iter()
        .find_map(|key| usage_percent(object.get(key)))?;
    let reset = match object.get("resets_at") {
        None | Some(Value::Null) if object.contains_key("resetsAt") => object.get("resetsAt"),
        reset => reset,
    };
    Some(Entry::window(used, parse_epoch(reset)))
}

/// The weekly window of the Claude usage response: `seven_day`'s
/// `utilization`, a percentage that can pass 100 once the limit is hit.
pub fn parse_claude_usage(raw: &str) -> Option<Entry> {
    let root: Value = serde_json::from_str(raw).ok()?;
    let week = root.get("seven_day")?.as_object()?;
    let used = week
        .get("utilization")?
        .as_f64()
        .filter(|used| used.is_finite() && *used >= 0.0)?;
    Some(Entry::window(
        used.min(100.0),
        parse_epoch(week.get("resets_at")),
    ))
}

/// The weekly Grok Build window of the billing response.
pub fn parse_grok_usage(raw: &str) -> Option<Entry> {
    let root: Value = serde_json::from_str(raw).ok()?;
    let config = root.get("config")?.as_object()?;
    let period = config.get("currentPeriod")?.as_object()?;
    if period.get("type").and_then(Value::as_str) != Some("USAGE_PERIOD_TYPE_WEEKLY") {
        return None;
    }
    let reset =
        parse_epoch(period.get("end")).or_else(|| parse_epoch(config.get("billingPeriodEnd")));
    let used = config
        .get("productUsage")
        .and_then(Value::as_array)
        .and_then(|products| {
            products
                .iter()
                .filter_map(Value::as_object)
                .find(|entry| entry.get("product").and_then(Value::as_str) == Some("GrokBuild"))
        })
        .map(|entry| usage_percent(entry.get("usagePercent")).unwrap_or(0.0))
        .unwrap_or(0.0);
    Some(Entry::window(used, reset))
}

/// The weekly window (a day or longer) of `account/rateLimits/read`, the
/// reply with id 2 in `codex app-server` output.
pub fn parse_codex_rate_limits(raw: &str) -> Option<Entry> {
    let value = raw.lines().find_map(|line| {
        serde_json::from_str::<Value>(line)
            .ok()
            .filter(|value| value.get("id").and_then(Value::as_f64) == Some(2.0))
    })?;
    let result = value.get("result")?.as_object()?;
    let codex = result
        .get("rateLimitsByLimitId")
        .and_then(Value::as_object)
        .and_then(|limits| limits.get("codex"))
        .filter(|codex| codex.is_object())
        .or_else(|| result.get("rateLimits"))?
        .as_object()?;
    ["primary", "secondary"].into_iter().find_map(|key| {
        let window = codex.get(key)?;
        let minutes = window.get("windowDurationMins")?.as_i64()?;
        (minutes >= 1_440)
            .then(|| window_from(Some(window)))
            .flatten()
    })
}

pub fn parse_rfc3339(value: &str) -> Option<u64> {
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

// -- Refresh decisions --------------------------------------------------------

/// Whether a reading is old enough to fetch again, honouring a retry delay.
pub fn due(entry: &Entry, now: u64) -> bool {
    if entry.retry_at.is_some_and(|retry_at| now < retry_at) {
        return false;
    }
    entry
        .fetched_at
        .is_none_or(|fetched_at| now.saturating_sub(fetched_at) >= FETCH_TTL)
}

/// A fetched provider asks again only without a reading or once it is due.
pub fn wants_fetch(entry: &Entry, now: u64) -> bool {
    !entry.has_reading() || due(entry, now)
}

/// A Codex fetch: success replaces the entry, failure keeps it and waits
/// five minutes.
pub fn after_codex(mut entry: Entry, now: u64, window: Option<Entry>) -> Entry {
    match window {
        Some(window) => fetched(window, now),
        None => {
            entry.retry_at = Some(now + RETRY_SECONDS);
            entry
        }
    }
}

/// What a fetch with a stored access token (Claude, Grok) produced.
#[derive(Clone, Debug, PartialEq)]
pub enum TokenFetch {
    Window(Entry),
    /// Every stored token has expired: the provider's own CLI renews it
    /// (`claude`, `grok`), so the next tick just rereads the credentials.
    Expired,
    Failed,
}

pub fn after_token_fetch(mut entry: Entry, now: u64, fetch: TokenFetch) -> Entry {
    match fetch {
        TokenFetch::Window(window) => fetched(window, now),
        TokenFetch::Expired => {
            entry.retry_at = None;
            entry
        }
        TokenFetch::Failed => {
            entry.retry_at = Some(now + RETRY_SECONDS);
            entry
        }
    }
}

fn fetched(mut window: Entry, now: u64) -> Entry {
    window.fetched_at = Some(now);
    window.retry_at = None;
    window
}

// -- Credentials ----------------------------------------------------------------

pub fn safe_header_value(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && byte != b'"' && byte != b'\\')
}

/// The access token to use: among the credentials whose `key` is a safe
/// header value, the one expiring last, else one without an expiry. The
/// flag tells that every dated token has expired. The refresh token is
/// never read.
pub fn select_grok_token(credentials: &Value, now: u64) -> (Option<String>, bool) {
    let Some(credentials) = credentials.as_object() else {
        return (None, false);
    };
    let mut usable: Option<(u64, &str)> = None;
    let mut expired = false;
    for entry in credentials.values().filter_map(Value::as_object) {
        let Some(token) = entry
            .get("key")
            .and_then(Value::as_str)
            .filter(|token| safe_header_value(token))
        else {
            continue;
        };
        let expires_at = entry
            .get("expires_at")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339);
        match expires_at {
            Some(expires_at) if expires_at <= now => expired = true,
            None => {
                usable.get_or_insert((0, token));
            }
            Some(expires_at) => {
                if usable.is_none_or(|(best, _)| expires_at > best) {
                    usable = Some((expires_at, token));
                }
            }
        }
    }
    match usable {
        Some((_, token)) => (Some(token.to_string()), false),
        None => (None, expired),
    }
}

/// The curl config fed on stdin, so the token never reaches argv.
pub fn grok_curl_config(token: &str) -> String {
    format!(
        "header = \"Authorization: Bearer {token}\"\n\
         header = \"Accept: application/json\"\n\
         header = \"x-grok-client-identifier: grok-shell\"\n\
         header = \"X-XAI-Token-Auth: xai-grok-cli\"\n"
    )
}

/// Claude Code's OAuth access token, and whether it has expired. Its
/// `expiresAt` is in milliseconds; the refresh token is never read.
pub fn select_claude_token(credentials: &Value, now: u64) -> (Option<String>, bool) {
    let Some(oauth) = credentials.get("claudeAiOauth").and_then(Value::as_object) else {
        return (None, false);
    };
    let Some(token) = oauth
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|token| safe_header_value(token))
    else {
        return (None, false);
    };
    match parse_epoch(oauth.get("expiresAt")) {
        Some(expires_at) if expires_at <= now => (None, true),
        _ => (Some(token.to_string()), false),
    }
}

/// The curl config fed on stdin, so the token never reaches argv.
pub fn claude_curl_config(token: &str) -> String {
    format!(
        "header = \"Authorization: Bearer {token}\"\n\
         header = \"anthropic-beta: {CLAUDE_OAUTH_BETA}\"\n\
         header = \"Accept: application/json\"\n"
    )
}

/// curl's `\n%{http_code}` trailer split from the body: the body of a 200.
pub fn ok_body(stdout: &str) -> Option<&str> {
    let (body, status) = stdout.rsplit_once('\n')?;
    (status.trim() == "200").then_some(body)
}

// -- Fetchers -------------------------------------------------------------------

/// Where Claude Code keeps its OAuth credentials: the login Keychain item
/// it writes on macOS, read through `security` (which Claude Code's item
/// trusts), else its credentials file.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClaudeCredentials {
    pub keychain_service: Option<&'static str>,
    pub file: Option<PathBuf>,
}

impl ClaudeCredentials {
    /// Claude Code's own locations for this user.
    pub fn claude_code(home: Option<&Path>) -> Self {
        Self {
            keychain_service: Some(CLAUDE_KEYCHAIN_SERVICE),
            file: home.map(|home| home.join(".claude/.credentials.json")),
        }
    }

    async fn read(&self) -> Option<Value> {
        if let Some(service) = self.keychain_service {
            let mut command = Command::new(SECURITY);
            command.args(["find-generic-password", "-s", service, "-w"]);
            if let Ok(output) = flash_plugin::process::capture(
                &mut command,
                None,
                FETCH_TIMEOUT,
                STDOUT_LIMIT,
                STDERR_LIMIT,
            )
            .await
                && output.status.success()
                && let Ok(credentials) = serde_json::from_slice::<Value>(&output.stdout)
            {
                return Some(credentials);
            }
        }
        let bytes = tokio::fs::read(self.file.as_ref()?).await.ok()?;
        serde_json::from_slice(&bytes).ok()
    }
}

/// A read-only usage request with the OAuth access token Claude Code
/// already stored. Neither the Keychain item nor the file is ever written,
/// and the refresh token is never used: running `claude` renews the token.
pub async fn fetch_claude(credentials: &ClaudeCredentials, url: &str, now: u64) -> TokenFetch {
    let Some(stored) = credentials.read().await else {
        return TokenFetch::Failed;
    };
    let (token, expired) = select_claude_token(&stored, now);
    drop(stored);
    let Some(token) = token else {
        return if expired {
            TokenFetch::Expired
        } else {
            TokenFetch::Failed
        };
    };
    let config = claude_curl_config(&token);
    drop(token);
    match curl_get(url, config)
        .await
        .as_deref()
        .and_then(parse_claude_usage)
    {
        Some(window) => TokenFetch::Window(window),
        None => TokenFetch::Failed,
    }
}

/// A read-only billing request with the access token already in the auth
/// file. The file is never written and its refresh token never used.
pub async fn fetch_grok(auth_file: &Path, now: u64) -> TokenFetch {
    let Ok(bytes) = tokio::fs::read(auth_file).await else {
        return TokenFetch::Failed;
    };
    let Ok(credentials) = serde_json::from_slice::<Value>(&bytes) else {
        return TokenFetch::Failed;
    };
    drop(bytes);
    let (token, expired) = select_grok_token(&credentials, now);
    drop(credentials);
    let Some(token) = token else {
        return if expired {
            TokenFetch::Expired
        } else {
            TokenFetch::Failed
        };
    };
    let config = grok_curl_config(&token);
    drop(token);
    match curl_get(GROK_USAGE_URL, config)
        .await
        .as_deref()
        .and_then(parse_grok_usage)
    {
        Some(window) => TokenFetch::Window(window),
        None => TokenFetch::Failed,
    }
}

/// GET `url` with the headers of `config`, fed to curl on stdin: the body
/// of a 200, else nothing.
async fn curl_get(url: &str, config: String) -> Option<String> {
    let mut command = Command::new(CURL);
    command.args([
        "-sS",
        "--max-time",
        "5",
        "-w",
        "\n%{http_code}",
        "-K",
        "-",
        url,
    ]);
    let output = flash_plugin::process::capture(
        &mut command,
        Some(config.into_bytes()),
        FETCH_TIMEOUT,
        STDOUT_LIMIT,
        STDERR_LIMIT,
    )
    .await
    .ok()?;
    ok_body(&String::from_utf8_lossy(&output.stdout)).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Europe/Paris in October 2026, before the end of summer time: the
    /// script's self-test runs with `TZ=Europe/Paris`.
    fn paris(_: u64) -> i64 {
        2 * 3_600
    }

    /// `datetime(2026, 10, d, h, m)` in Paris summer time.
    fn paris_at(day: u64, hour: u64, minute: u64) -> u64 {
        let midnight_utc = parse_rfc3339(&format!("2026-10-{day:02}T00:00:00Z")).unwrap();
        midnight_utc + hour * 3_600 + minute * 60 - 2 * 3_600
    }

    const SHOWN: u64 = 1_791_290_827;

    fn window(used: f64, reset: Option<u64>) -> Entry {
        Entry::window(used, reset)
    }

    #[test]
    fn remaining_percent_floors_used_and_caps_at_99() {
        assert_eq!(remaining_percent(94.0), 6, "94 used is 6 remaining");
        assert_eq!(remaining_percent(91.0), 9, "91 used is 9 remaining");
        assert_eq!(remaining_percent(0.0), 99, "unused quota caps at 99");
        assert_eq!(remaining_percent(100.0), 0, "a full window is 0");
        assert_eq!(
            remaining_percent(85.9),
            15,
            "floor the used percentage before subtracting"
        );
    }

    #[test]
    fn reset_delays_count_minutes_hours_then_local_calendar_days() {
        let now = paris_at(6, 10, 0);
        assert_eq!(
            quota_reset_delay(now, paris_at(8, 9, 0), &paris),
            "2d",
            "47 hours landing the day after tomorrow is 2d"
        );
        assert_eq!(
            quota_reset_delay(now, paris_at(7, 11, 0), &paris),
            "1d",
            "25 hours landing tomorrow is 1d"
        );
        assert_eq!(
            quota_reset_delay(now, paris_at(7, 6, 0), &paris),
            "20h",
            "a reset under a day stays in hours when it falls tomorrow"
        );
        assert_eq!(
            quota_reset_delay(now, now + 30 * 60, &paris),
            "30min",
            "under an hour is minutes"
        );
    }

    #[test]
    fn metrics_render_like_the_script() {
        assert_eq!(
            metric(Some(&window(94.0, Some(1_791_370_800))), SHOWN, &paris),
            "6%↻22h",
            "claude sample renders 6% with a 22 hour reset"
        );
        assert_eq!(
            metric(Some(&window(91.0, Some(1_791_380_696))), SHOWN, &paris),
            "9%↻1d",
            "grok sample renders 9% resetting tomorrow"
        );
        assert_eq!(
            metric(Some(&window(94.0, Some(SHOWN - 45 * 60))), SHOWN, &paris),
            "99%↻7d",
            "a window whose reset has passed rolls to a full week ending a week later"
        );
        assert_eq!(
            metric(
                Some(&window(94.0, Some(SHOWN - WEEK_SECONDS - 3_600))),
                SHOWN,
                &paris
            ),
            "99%↻7d",
            "a window stale by more than a week rolls to the next future reset"
        );
        assert_eq!(
            metric(Some(&window(91.0, None)), SHOWN, &paris),
            "9%",
            "a reading without a reset keeps the percentage alone"
        );
        assert_eq!(
            metric(None, SHOWN, &paris),
            UNKNOWN,
            "a provider with no sample is an em dash"
        );
        assert_eq!(
            metric(Some(&Entry::default()), SHOWN, &paris),
            UNKNOWN,
            "an entry without a reading (only a retry time) is an em dash"
        );
    }

    #[test]
    fn the_window_rolls_forward_at_the_reset_instant() {
        let entry = window(94.0, Some(1_791_370_800));
        assert_eq!(
            metric(Some(&entry), 1_791_370_799, &paris),
            "6%↻0min",
            "a second before the reset the old window still shows"
        );
        assert_eq!(
            metric(Some(&entry), 1_791_370_800, &paris),
            "99%↻7d",
            "at the reset instant the window rolls to the next week"
        );
        assert_eq!(
            current_window(&entry, 1_791_370_800),
            Some((0.0, Some(1_791_370_800 + WEEK_SECONDS)))
        );
    }

    #[test]
    fn epochs_accept_rfc3339_and_milliseconds() {
        let grok_reset = parse_rfc3339("2026-10-07T13:44:56Z").unwrap();
        assert_eq!(
            parse_rfc3339("2026-10-07T13:44:56.858074+00:00"),
            Some(grok_reset),
            "fractional RFC3339 parses to seconds"
        );
        assert_eq!(
            parse_epoch(Some(&json!(grok_reset * 1_000))),
            Some(grok_reset),
            "millisecond resets count as seconds"
        );
        assert_eq!(parse_epoch(Some(&json!(grok_reset))), Some(grok_reset));
        assert_eq!(parse_epoch(Some(&json!(12.9))), Some(12));
        assert_eq!(parse_epoch(Some(&json!(-1))), None);
        assert_eq!(parse_epoch(Some(&json!(true))), None);
        assert_eq!(parse_epoch(Some(&json!("not-a-date"))), None);
        assert_eq!(parse_epoch(None), None);
        assert_eq!(parse_rfc3339("1970-01-02T01:30:00+01:30"), Some(86_400));
    }

    #[test]
    fn usage_percent_rejects_anything_but_a_bounded_number() {
        assert_eq!(usage_percent(Some(&json!(42))), Some(42.0));
        assert_eq!(usage_percent(Some(&json!(0.5))), Some(0.5));
        for invalid in [
            json!(true),
            json!(-1),
            json!(100.5),
            json!("50"),
            json!(null),
        ] {
            assert_eq!(usage_percent(Some(&invalid)), None, "{invalid}");
        }
        assert_eq!(usage_percent(None), None);
    }

    #[test]
    fn grok_billing_keeps_the_weekly_grok_build_window() {
        let grok_reset = parse_rfc3339("2026-10-07T13:44:56Z").unwrap();
        let body = json!({
            "config": {
                "currentPeriod": {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-10-07T13:44:56.858074+00:00",
                },
                "productUsage": [{"product": "GrokBuild", "usagePercent": 91}],
            }
        })
        .to_string();
        assert_eq!(
            parse_grok_usage(&body),
            Some(window(91.0, Some(grok_reset))),
            "grok billing weekly window"
        );
        assert_eq!(ok_body(&format!("{body}\n200")), Some(body.as_str()));
        assert_eq!(ok_body(&format!("{body}\n401")), None);
        assert_eq!(ok_body("\n000"), None);

        let fallback = json!({
            "config": {
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY"},
                "billingPeriodEnd": grok_reset * 1_000,
                "productUsage": [{"product": "Other", "usagePercent": 50}],
            }
        })
        .to_string();
        assert_eq!(
            parse_grok_usage(&fallback),
            Some(window(0.0, Some(grok_reset))),
            "the billing period end stands in, and no Grok Build usage is 0"
        );
        let monthly = json!({
            "config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY"}}
        })
        .to_string();
        assert_eq!(parse_grok_usage(&monthly), None);
    }

    #[test]
    fn codex_keeps_the_weekly_window_of_either_shape() {
        let by_id = json!({
            "id": 2,
            "result": {
                "rateLimitsByLimitId": {
                    "codex": {
                        "primary": {"usedPercent": 85, "windowDurationMins": 10080, "resetsAt": 1_791_626_816},
                        "secondary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 18000},
                    }
                }
            },
        });
        assert_eq!(
            parse_codex_rate_limits(&format!("{{\"id\":1,\"result\":{{}}}}\n{by_id}\n")),
            Some(window(85.0, Some(1_791_626_816))),
            "codex keeps the weekly window and ignores the session"
        );
        let single = json!({
            "id": 2,
            "result": {
                "rateLimits": {
                    "primary": {"usedPercent": 89, "windowDurationMins": 10080, "resetsAt": 1_791_626_816}
                }
            },
        });
        assert_eq!(
            parse_codex_rate_limits(&single.to_string()),
            Some(window(89.0, Some(1_791_626_816))),
            "codex accepts the rateLimits object the app-server returns"
        );
        let session_only = json!({
            "id": 2,
            "result": {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300}}},
        });
        assert_eq!(parse_codex_rate_limits(&session_only.to_string()), None);
        assert_eq!(parse_codex_rate_limits("not json\n"), None);
    }

    #[test]
    fn claude_reads_the_weekly_window_of_the_oauth_usage_response() {
        let body = json!({
            "five_hour": {"utilization": 15.0, "resets_at": "2026-10-06T19:30:00.123456+00:00"},
            "seven_day": {"utilization": 94.0, "resets_at": "2026-10-07T13:40:00.943679+00:00"},
            "seven_day_oauth_apps": null,
            "seven_day_opus": {"utilization": 0.0, "resets_at": null},
        })
        .to_string();
        assert_eq!(
            parse_claude_usage(&body),
            Some(window(94.0, Some(1_791_380_400))),
            "the seven-day window, its fractional RFC 3339 reset read to the second"
        );
        assert_eq!(
            parse_claude_usage(r#"{"seven_day":{"utilization":104.5,"resets_at":null}}"#),
            Some(window(100.0, None)),
            "past the limit reads as full"
        );
        assert_eq!(
            parse_claude_usage(r#"{"five_hour":{"utilization":4}}"#),
            None
        );
        assert_eq!(
            parse_claude_usage(r#"{"seven_day":{"utilization":-1}}"#),
            None
        );
        assert_eq!(parse_claude_usage("not json"), None);
    }

    #[test]
    fn claude_uses_the_stored_access_token_until_it_expires() {
        let credentials = |expires_at: Value| {
            json!({"claudeAiOauth": {
                "accessToken": "access-value",
                "refreshToken": "refresh-value",
                "expiresAt": expires_at,
                "scopes": ["user:inference", "user:profile"],
            }})
        };
        assert_eq!(
            select_claude_token(&credentials(json!((SHOWN + 60) * 1_000)), SHOWN),
            (Some("access-value".to_string()), false),
            "expiresAt is in milliseconds"
        );
        assert_eq!(
            select_claude_token(&credentials(json!(SHOWN * 1_000)), SHOWN),
            (None, true),
            "an expired token is never sent and never refreshed"
        );
        assert_eq!(
            select_claude_token(&credentials(Value::Null), SHOWN),
            (Some("access-value".to_string()), false)
        );
        assert_eq!(
            select_claude_token(
                &json!({"claudeAiOauth": {"accessToken": "a\"b", "expiresAt": 0}}),
                SHOWN
            ),
            (None, false),
            "a token that could escape the curl config is no token"
        );
        assert_eq!(select_claude_token(&json!({}), SHOWN), (None, false));
        let config = claude_curl_config("access-value");
        assert!(config.contains("header = \"Authorization: Bearer access-value\"\n"));
        assert!(config.contains("header = \"anthropic-beta: oauth-2025-04-20\"\n"));
        assert!(!config.contains("refresh"));
    }

    #[test]
    fn windows_accept_every_spelling_of_used_and_reset() {
        for used_key in ["used_percent", "used_percentage", "usedPercent"] {
            assert_eq!(
                window_from(Some(&json!({ used_key: 12, "resets_at": 10 }))),
                Some(window(12.0, Some(10)))
            );
        }
        assert_eq!(
            window_from(Some(&json!({ "usedPercent": 12, "resetsAt": 10 }))),
            Some(window(12.0, Some(10)))
        );
        assert_eq!(
            window_from(Some(
                &json!({ "usedPercent": 12, "resets_at": null, "resetsAt": 10 })
            )),
            Some(window(12.0, Some(10)))
        );
        assert_eq!(
            window_from(Some(&json!({ "usedPercent": 12 }))),
            Some(window(12.0, None))
        );
        assert_eq!(window_from(Some(&json!({ "resets_at": 10 }))), None);
        assert_eq!(window_from(Some(&json!([]))), None);
    }

    #[test]
    fn an_expired_claude_token_keeps_the_last_percentage() {
        let reading = after_token_fetch(
            Entry::default(),
            SHOWN,
            TokenFetch::Window(window(94.0, Some(1_791_370_800))),
        );
        assert_eq!(reading.fetched_at, Some(SHOWN));
        let kept = after_token_fetch(reading.clone(), SHOWN + 60, TokenFetch::Expired);
        assert_eq!(
            kept, reading,
            "an expired claude token keeps the last percentage"
        );
        assert_eq!(metric(Some(&kept), SHOWN + 60, &paris), "6%↻22h");
        assert_eq!(
            metric(Some(&kept), 1_791_370_800, &paris),
            "99%↻7d",
            "at the reset instant the window rolls to the next week"
        );
    }

    #[test]
    fn failed_fetches_keep_the_last_reading_and_wait() {
        let reading = window(91.0, Some(1_791_380_696));
        let failed = after_codex(reading.clone(), SHOWN, None);
        assert_eq!(failed.used_percent, Some(91.0));
        assert_eq!(failed.retry_at, Some(SHOWN + RETRY_SECONDS));
        assert!(!wants_fetch(&failed, SHOWN + 60), "retry delay holds");
        assert!(wants_fetch(&failed, SHOWN + RETRY_SECONDS));

        let failed = after_token_fetch(reading.clone(), SHOWN, TokenFetch::Failed);
        assert_eq!(failed.used_percent, Some(91.0));
        assert_eq!(failed.retry_at, Some(SHOWN + RETRY_SECONDS));

        let expired = after_token_fetch(failed, SHOWN + 400, TokenFetch::Expired);
        assert_eq!(
            expired.used_percent,
            Some(91.0),
            "an expired token keeps it"
        );
        assert_eq!(
            expired.retry_at, None,
            "and rereads the auth file next tick"
        );
        assert_eq!(metric(Some(&expired), SHOWN, &paris), "9%↻1d");

        let fresh = after_token_fetch(expired, SHOWN + 500, TokenFetch::Window(window(20.0, None)));
        assert_eq!(
            fresh,
            Entry {
                used_percent: Some(20.0),
                resets_at: None,
                fetched_at: Some(SHOWN + 500),
                retry_at: None,
            },
            "a newer sample replaces the entry wholesale"
        );
    }

    #[test]
    fn fetches_wait_out_the_ttl_once_a_reading_exists() {
        let mut entry = window(10.0, None);
        assert!(wants_fetch(&Entry::default(), SHOWN), "no reading fetches");
        let without_reading = Entry {
            retry_at: Some(SHOWN + 100),
            ..Entry::default()
        };
        assert!(
            wants_fetch(&without_reading, SHOWN),
            "without a reading the retry delay does not hold, as in the script"
        );
        assert!(wants_fetch(&entry, SHOWN), "a reading never fetched is due");
        entry.fetched_at = Some(SHOWN);
        assert!(!wants_fetch(&entry, SHOWN + FETCH_TTL - 1));
        assert!(wants_fetch(&entry, SHOWN + FETCH_TTL));
    }

    #[test]
    fn grok_token_selection_prefers_the_latest_unexpired_safe_key() {
        let now = parse_rfc3339("2026-10-20T00:00:00Z").unwrap();
        let credentials = json!({
            "a": {"key": "old", "expires_at": "2026-10-21T00:00:00Z", "refresh_token": "r1"},
            "b": {"key": "new", "expires_at": "2026-10-22T00:00:00Z", "refresh_token": "r2"},
            "c": {"key": "gone", "expires_at": "2026-10-19T00:00:00Z"},
            "d": {"key": "bad\"quote", "expires_at": "2026-10-30T00:00:00Z"},
            "e": "not an object",
        });
        assert_eq!(
            select_grok_token(&credentials, now),
            (Some("new".to_string()), false)
        );
        let only_expired = json!({"a": {"key": "gone", "expires_at": "2026-10-19T00:00:00Z"}});
        assert_eq!(select_grok_token(&only_expired, now), (None, true));
        let undated = json!({"a": {"key": "forever"}});
        assert_eq!(
            select_grok_token(&undated, now),
            (Some("forever".to_string()), false)
        );
        let dated_beats_undated = json!({
            "a": {"key": "forever"},
            "b": {"key": "dated", "expires_at": "2026-10-22T00:00:00Z"},
        });
        assert_eq!(
            select_grok_token(&dated_beats_undated, now),
            (Some("dated".to_string()), false)
        );
        assert_eq!(select_grok_token(&json!({}), now), (None, false));
        assert_eq!(select_grok_token(&json!([]), now), (None, false));
    }

    #[test]
    fn header_values_reject_anything_that_could_escape_the_curl_config() {
        assert!(safe_header_value("abc.DEF-123_~"));
        for unsafe_value in ["", "a b", "a\"b", "a\\b", "a\nb", "é"] {
            assert!(!safe_header_value(unsafe_value), "{unsafe_value:?}");
        }
        let config = grok_curl_config("tok");
        assert_eq!(config.lines().count(), 4);
        assert!(config.starts_with("header = \"Authorization: Bearer tok\"\n"));
    }

    #[test]
    fn state_round_trips_only_percentages_and_times() {
        let mut state = QuotaState::default();
        state.set(
            Quota::Claude,
            Entry {
                used_percent: Some(94.0),
                resets_at: Some(1_791_370_800),
                fetched_at: Some(SHOWN),
                retry_at: None,
            },
        );
        state.set(
            Quota::Grok,
            Entry {
                retry_at: Some(SHOWN + RETRY_SECONDS),
                ..Entry::default()
            },
        );
        let bytes = state.to_json();
        assert_eq!(
            String::from_utf8(bytes.clone()).unwrap(),
            "{\"claude\":{\"used_percent\":94.0,\"resets_at\":1791370800,\"fetched_at\":1791290827},\"grok\":{\"retry_at\":1791291127}}\n"
        );
        assert_eq!(QuotaState::from_json(&bytes), state);
        let lenient = QuotaState::from_json(
            br#"{"claude":{"used_percent":"x","resets_at":5},"codex":{"used_percent":40},"grok":7}"#,
        );
        assert_eq!(lenient.entry(Quota::Claude).used_percent, None);
        assert_eq!(lenient.entry(Quota::Claude).resets_at, Some(5));
        assert_eq!(lenient.entry(Quota::Codex).used_percent, Some(40.0));
        assert_eq!(lenient.get(Quota::Grok), None);
        assert_eq!(QuotaState::from_json(b"garbage"), QuotaState::default());
    }

    #[test]
    fn segments_name_the_quotas() {
        let names: Vec<_> = Quota::ALL.iter().map(|quota| quota.segment()).collect();
        assert_eq!(names, ["claude", "codex", "grok"]);
        for quota in Quota::ALL {
            assert_eq!(Quota::from_segment(quota.segment()), Some(quota));
        }
        assert_eq!(Quota::from_segment("claude_label"), None);
    }

    #[test]
    fn the_local_offset_is_a_whole_number_of_minutes() {
        let offset = local_utc_offset(SHOWN);
        assert_eq!(offset % 60, 0);
        assert!(offset.abs() <= 14 * 3_600);
    }
}
