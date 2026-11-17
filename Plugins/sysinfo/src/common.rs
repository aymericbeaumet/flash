//! What every domain shares: the one `[plugins.sysinfo] summary_mode`
//! setting, raw-segment formatting, the once-per-episode failure log and the
//! per-collector gate.

use std::sync::{Mutex, MutexGuard};

use flash_plugin::{Context, History, Markup, StatusValue};

/// Every domain keeps this many fast samples for its chart and history.
pub(crate) const HISTORY_SAMPLES: usize = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SummaryMode {
    Compact,
    Full,
}

/// The configured mode and whether the value was one the setting accepts.
pub(crate) fn parse_summary_mode(configured: &str) -> (SummaryMode, bool) {
    match configured {
        "" | "compact" => (SummaryMode::Compact, true),
        "full" => (SummaryMode::Full, true),
        _ => (SummaryMode::Compact, false),
    }
}

pub(crate) fn configured_summary_mode(ctx: &Context) -> SummaryMode {
    parse_summary_mode(&ctx.config_str("summary_mode")).0
}

/// Logged once at start: the five domains read one setting.
pub(crate) fn warn_invalid_summary_mode(ctx: &Context) {
    if !parse_summary_mode(&ctx.config_str("summary_mode")).1 {
        ctx.log(
            "warn",
            "[sysinfo] summary_mode must be compact or full; using compact",
        );
    }
}

/// A raw segment's value as literal text: no styling and no preview.
pub(crate) fn plain(value: &str) -> StatusValue {
    StatusValue::text(Markup::text(value))
}

/// True on the first failure of an episode; a success re-arms the log.
pub(crate) fn first_failure(already_logged: &mut bool, failed: bool) -> bool {
    if failed {
        let first = !*already_logged;
        *already_logged = true;
        first
    } else {
        *already_logged = false;
        false
    }
}

/// Rounded to the nearest integer and clamped to 0–100; NaN reads as 0.
pub(crate) fn whole_percent(value: f64) -> u8 {
    if value > 0.0 {
        value.min(100.0).round() as u8
    } else {
        0
    }
}

/// The retained percentages as space-separated integers, oldest first.
pub(crate) fn percent_series<const N: usize>(history: &History<N>) -> String {
    history
        .iter()
        .map(|sample| whole_percent(sample).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whole bytes per second, rounded; NaN or a negative rate reads as 0.
pub(crate) fn whole_rate(bytes_per_second: f64) -> u64 {
    if bytes_per_second > 0.0 {
        bytes_per_second.round() as u64
    } else {
        0
    }
}

/// The retained rates as space-separated whole bytes per second, oldest
/// first.
pub(crate) fn rate_series<const N: usize>(history: &History<N>) -> String {
    history
        .iter()
        .map(|sample| whole_rate(sample).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether a collection waits for a busy collector or skips the sample.
#[derive(Clone, Copy)]
pub(crate) enum GatePolicy {
    Wait,
    SkipIfBusy,
}

pub(crate) fn begin_collection(
    gate: &tokio::sync::Mutex<()>,
) -> Option<tokio::sync::MutexGuard<'_, ()>> {
    gate.try_lock().ok()
}

pub(crate) async fn acquire_collection<'a>(
    gate: &'a tokio::sync::Mutex<()>,
    policy: GatePolicy,
) -> Option<tokio::sync::MutexGuard<'a, ()>> {
    match policy {
        GatePolicy::Wait => Some(gate.lock().await),
        GatePolicy::SkipIfBusy => begin_collection(gate),
    }
}

/// A domain's state, poisoned or not.
pub(crate) fn lock<T>(state: &Mutex<T>) -> MutexGuard<'_, T> {
    state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// This domain's observed segments as the domain names them:
/// `cpu_percent` reaches the cpu domain as `percent`.
pub(crate) fn domain_segments(segments: &[String], prefix: &str) -> Vec<String> {
    segments
        .iter()
        .filter_map(|segment| segment.strip_prefix(prefix))
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn an_invalid_summary_mode_warns_once_under_the_plugin_name() {
        let mut harness = flash_plugin::testing::Harness::with_config(
            "sysinfo",
            serde_json::json!({ "summary_mode": "dense" }),
        );
        warn_invalid_summary_mode(&harness.context());
        let logs: Vec<String> = harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "log")
            .map(|frame| frame["params"]["message"].to_string())
            .collect();
        assert_eq!(logs.len(), 1, "{logs:?}");
        assert!(
            logs[0].contains("[sysinfo] summary_mode must be compact or full; using compact"),
            "{logs:?}"
        );
        let mut valid = flash_plugin::testing::Harness::with_config(
            "sysinfo",
            serde_json::json!({ "summary_mode": "full" }),
        );
        warn_invalid_summary_mode(&valid.context());
        assert_eq!(configured_summary_mode(&valid.context()), SummaryMode::Full);
        assert!(valid.drain().is_empty());
    }

    #[test]
    fn collection_failure_logs_once_until_a_success_rearms_it() {
        let mut logged = false;
        assert!(first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, false));
        assert!(first_failure(&mut logged, true));
    }

    #[test]
    fn an_in_flight_collection_is_skipped_instead_of_queued() {
        let gate = tokio::sync::Mutex::new(());
        let held = begin_collection(&gate).expect("first collection");
        assert!(begin_collection(&gate).is_none());
        drop(held);
        assert!(begin_collection(&gate).is_some());
    }

    #[test]
    fn raw_figures_round_and_clamp() {
        assert_eq!(whole_percent(f64::NAN), 0);
        assert_eq!(whole_percent(-3.0), 0);
        assert_eq!(whole_percent(0.5), 1);
        assert_eq!(whole_percent(250.0), 100);
        assert_eq!(whole_rate(f64::NAN), 0);
        assert_eq!(whole_rate(-5.0), 0);
        assert_eq!(whole_rate(1_234.5), 1235);
    }

    #[test]
    fn series_keep_the_newest_samples_oldest_first() {
        let mut history = History::<HISTORY_SAMPLES>::new();
        for value in 0..25 {
            history.push(f64::from(value));
        }
        let expected = (5..25).map(|value| value.to_string()).collect::<Vec<_>>();
        assert_eq!(percent_series(&history), expected.join(" "));
        let mut rates = History::<HISTORY_SAMPLES>::new();
        for value in 0..25 {
            rates.push(f64::from(value) * 1_000.0);
        }
        let expected = (5..25)
            .map(|value| (value * 1_000).to_string())
            .collect::<Vec<_>>();
        assert_eq!(rate_series(&rates), expected.join(" "));
        assert_eq!(percent_series(&History::<HISTORY_SAMPLES>::new()), "");
    }

    #[test]
    fn observed_segments_reach_their_domain_without_the_prefix() {
        let observed: Vec<String> = ["cpu_percent", "cpu_label", "memory_history", "power_state"]
            .iter()
            .map(|name| name.to_string())
            .collect();
        assert_eq!(domain_segments(&observed, "cpu_"), ["percent", "label"]);
        assert_eq!(domain_segments(&observed, "memory_"), ["history"]);
        assert!(domain_segments(&observed, "disks_").is_empty());
    }
}
