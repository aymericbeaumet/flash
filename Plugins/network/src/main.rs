use std::net::{IpAddr, Ipv4Addr};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::status::{
    bytes_iec, bytes_iec_compact, rate_cells4, rate_iec, sparkline_padded, sparkline_scaled,
};
use flash_plugin::{
    run, run_command, sys, Candidate, Color, CommandRequest, Context, History, Markup,
    PerformResponse, Preview, Published, RefreshGate, StatusValue,
};
use nix::ifaddrs::getifaddrs;
use nix::net::if_::InterfaceFlags;

const SOURCE_ADDRESSES: &str = "network.addresses";
const TRAFFIC_POLL: Duration = Duration::from_secs(1);
const DISCOVERY_POLL: Duration = Duration::from_secs(30);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const MIN_RATE_INTERVAL: Duration = Duration::from_millis(500);
const MAX_RATE_INTERVAL: Duration = Duration::from_secs(10);
const HISTORY_LEN: usize = 20;
const NETSTAT: &str = "/usr/sbin/netstat";

static STATE: LazyLock<Mutex<NetworkState>> = LazyLock::new(|| Mutex::new(NetworkState::default()));
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

#[derive(Clone, Debug, PartialEq, Eq)]
struct NetworkAddress {
    interface_name: String,
    ip: IpAddr,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CatalogSnapshot {
    hostname: Option<String>,
    addresses: Vec<NetworkAddress>,
}

impl CatalogSnapshot {
    fn candidates(&self) -> Vec<Candidate> {
        let mut rows =
            Vec::with_capacity(self.addresses.len() + usize::from(self.hostname.is_some()));
        if let Some(hostname) = &self.hostname {
            rows.push(network_row(
                format!("hostname {hostname}"),
                "local hostname",
                hostname,
            ));
        }
        rows.extend(self.addresses.iter().map(|address| {
            let family = match address.ip {
                IpAddr::V4(_) => "IPv4",
                IpAddr::V6(_) => "IPv6",
            };
            let ip = address.ip.to_string();
            network_row(
                format!("{} {ip}", address.interface_name),
                format!("{family} — {}", address.interface_name),
                ip,
            )
        }));
        rows
    }
}

fn network_row(
    title: impl Into<String>,
    subtitle: impl Into<String>,
    copy_text: impl Into<String>,
) -> Candidate {
    let copy_text = copy_text.into();
    Candidate::new(SOURCE_ADDRESSES, title)
        .kind("network_address")
        .subtitle(subtitle)
        .payload(&copy_text)
        .copy_text(copy_text)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NetCounters {
    received: u64,
    sent: u64,
}

#[derive(Clone, Debug)]
struct TimedCounters {
    interface: String,
    counters: NetCounters,
    sampled_at: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct TransferRates {
    received: f64,
    sent: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RenderedStatus {
    summary: Markup,
    label: Markup,
    details: Preview,
    raw: RawMetrics,
}

/// Plain values without markup, for templates and widgets that scale or chart
/// numbers themselves. An empty value clears its segment: no current rate or
/// no known address is unknown, not zero.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct RawMetrics {
    /// Default-route interface rates in whole bytes per second.
    down_bps: String,
    up_bps: String,
    /// The retained rate samples as space-separated whole bytes per second,
    /// oldest first.
    down_history: String,
    up_history: String,
    /// First IPv4 address of the default-route interface.
    address: String,
}

impl RenderedStatus {
    fn segments(&self) -> [(&'static str, StatusValue); 8] {
        [
            (
                "summary",
                StatusValue::text(self.summary.clone()).with_preview(self.details.clone()),
            ),
            ("label", StatusValue::text(self.label.clone())),
            ("details", StatusValue::text(self.details.render())),
            ("down_bps", plain(&self.raw.down_bps)),
            ("up_bps", plain(&self.raw.up_bps)),
            ("down_history", plain(&self.raw.down_history)),
            ("up_history", plain(&self.raw.up_history)),
            ("address", plain(&self.raw.address)),
        ]
    }
}

/// A raw segment's value as literal text: no styling and no preview.
fn plain(value: &str) -> StatusValue {
    StatusValue::text(Markup::text(value))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SummaryMode {
    Compact,
    Full,
}

fn parse_summary_mode(configured: &str) -> (SummaryMode, bool) {
    match configured {
        "" | "compact" => (SummaryMode::Compact, true),
        "full" => (SummaryMode::Full, true),
        _ => (SummaryMode::Compact, false),
    }
}

fn configured_summary_mode(ctx: &Context) -> SummaryMode {
    parse_summary_mode(&ctx.config_str("summary_mode")).0
}

fn warn_invalid_summary_mode(ctx: &Context) {
    if !parse_summary_mode(&ctx.config_str("summary_mode")).1 {
        ctx.log(
            "warn",
            "[network] summary_mode must be compact or full; using compact",
        );
    }
}

#[derive(Default)]
struct NetworkState {
    default_interface: Option<String>,
    wifi_ssid: Option<String>,
    previous: Option<TimedCounters>,
    rates: Option<TransferRates>,
    received_history: History<HISTORY_LEN>,
    sent_history: History<HISTORY_LEN>,
    catalog: Option<CatalogSnapshot>,
    last_discovery_attempt: Option<Instant>,
    last_traffic_success: Option<Instant>,
    published: Published<RenderedStatus>,
    discovery_failure_logged: bool,
    traffic_failure_logged: bool,
}

impl NetworkState {
    fn set_interface(&mut self, interface: String) {
        if self.default_interface.as_deref() == Some(interface.as_str()) {
            return;
        }
        self.default_interface = Some(interface);
        self.reset_rates();
    }

    fn apply_sample(&mut self, sample: TimedCounters) {
        self.last_traffic_success = Some(sample.sampled_at);
        let Some(previous) = self.previous.as_ref() else {
            self.previous = Some(sample);
            return;
        };
        match calculate_rates(previous, &sample) {
            RateDecision::TooSoon => {}
            RateDecision::Reset => {
                self.previous = Some(sample);
                self.rates = None;
                self.received_history.clear();
                self.sent_history.clear();
            }
            RateDecision::Rates(rates) => {
                self.previous = Some(sample);
                self.rates = Some(rates);
                self.received_history.push(rates.received);
                self.sent_history.push(rates.sent);
            }
        }
    }

    fn reset_rates(&mut self) {
        self.previous = None;
        self.rates = None;
        self.received_history.clear();
        self.sent_history.clear();
    }

    fn expire_stale_rates(&mut self, now: Instant) -> bool {
        let stale = self.rates.is_some()
            && self.last_traffic_success.is_some_and(|sampled_at| {
                now.saturating_duration_since(sampled_at) > MAX_RATE_INTERVAL
            });
        if !stale {
            return false;
        }
        self.rates = None;
        self.received_history.clear();
        self.sent_history.clear();
        true
    }
}

enum RateDecision {
    TooSoon,
    Reset,
    Rates(TransferRates),
}

enum WiFiSSIDRead {
    Passive,
    Prefetched(Option<String>),
}

struct Network;

flash_plugin::plugin!(Network);

impl FlashPlugin for Network {
    async fn on_start(&self, ctx: Context) {
        warn_invalid_summary_mode(&ctx);
        refresh_network(&ctx, true).await;
        drop(ctx.interval(TRAFFIC_POLL, |ctx| async move {
            refresh_network(&ctx, false).await;
        }));
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => current_response(),
            "refresh" => {
                let wifi_ssid = ctx.wifi_ssid(true).await;
                try_refresh_network(&ctx, true, wifi_ssid).await;
                current_response()
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_network(ctx: &Context, force_discovery: bool) {
    REFRESH_GATE
        .run(ctx, move |ctx, _applications| async move {
            refresh_network_locked(&ctx, force_discovery, WiFiSSIDRead::Passive).await;
        })
        .await;
}

async fn try_refresh_network(ctx: &Context, force_discovery: bool, wifi_ssid: Option<String>) {
    let _ = REFRESH_GATE
        .try_run(ctx, move |ctx, _applications| async move {
            refresh_network_locked(&ctx, force_discovery, WiFiSSIDRead::Prefetched(wifi_ssid))
                .await;
        })
        .await;
}

async fn refresh_network_locked(
    ctx: &Context,
    force_discovery: bool,
    wifi_ssid_read: WiFiSSIDRead,
) {
    let discovery_due = {
        let state = state();
        force_discovery
            || state
                .last_discovery_attempt
                .is_none_or(|last| last.elapsed() >= DISCOVERY_POLL)
    };

    let discovery = if discovery_due {
        let wifi_ssid = async move {
            match wifi_ssid_read {
                WiFiSSIDRead::Passive => ctx.wifi_ssid(false).await,
                WiFiSSIDRead::Prefetched(wifi_ssid) => wifi_ssid,
            }
        };
        let (interface, wifi_ssid, catalog) = tokio::join!(
            collect_default_interface(ctx),
            wifi_ssid,
            tokio::task::spawn_blocking(collect_catalog)
        );
        Some((interface, wifi_ssid, catalog))
    } else {
        None
    };

    let mut rows_to_publish = None;
    let mut discovery_failed = false;
    let (interface, log_discovery_failure) = {
        let mut state = state();
        if let Some((interface, wifi_ssid, catalog)) = discovery {
            state.last_discovery_attempt = Some(Instant::now());
            state.wifi_ssid = wifi_ssid;
            if let Some(interface) = interface {
                state.set_interface(interface);
            } else {
                discovery_failed = true;
            }

            match catalog {
                Ok(Ok(catalog)) => {
                    if state.catalog.as_ref() != Some(&catalog) {
                        rows_to_publish = Some(catalog.candidates());
                        state.catalog = Some(catalog);
                    }
                }
                Ok(Err(())) | Err(_) => discovery_failed = true,
            }
        }
        let log_failure =
            discovery_due && first_failure(&mut state.discovery_failure_logged, discovery_failed);
        (state.default_interface.clone(), log_failure)
    };

    if let Some(rows) = rows_to_publish {
        ctx.publish(rows);
    }
    if log_discovery_failure {
        ctx.log(
            "warn",
            "[network] routing table or address discovery failed",
        );
    }

    let mut traffic_failed = None;
    if let Some(interface) = interface {
        // Lifetime byte counters straight from the routing sysctl — the same
        // 64-bit figures `netstat -bI` prints, without a subprocess per second.
        match interface_counters(&interface) {
            Some(counters) => {
                state().apply_sample(TimedCounters {
                    interface,
                    counters,
                    sampled_at: Instant::now(),
                });
                traffic_failed = Some(false);
            }
            None => traffic_failed = Some(true),
        }
    }
    let log_traffic_failure = {
        let mut state = state();
        let log_failure = traffic_failed
            .is_some_and(|failed| first_failure(&mut state.traffic_failure_logged, failed));
        state.expire_stale_rates(Instant::now());
        log_failure
    };
    if log_traffic_failure {
        ctx.log("warn", "[network] traffic counters unavailable");
    }

    emit_status_if_changed(ctx);
}

fn current_response() -> PerformResponse {
    match render_preview(&state()) {
        Some(preview) => PerformResponse::ok().message(preview.render_plain()),
        None => PerformResponse::fail("network metrics are not available yet"),
    }
}

fn emit_status_if_changed(ctx: &Context) {
    let segments = {
        let mut state = state();
        let Some(rendered) = render_status(&state, configured_summary_mode(ctx)) else {
            return;
        };
        let Some(rendered) = state.published.update(rendered) else {
            return;
        };
        rendered.segments()
    };
    ctx.status(segments);
}

fn first_failure(already_logged: &mut bool, failed: bool) -> bool {
    if failed {
        let first = !*already_logged;
        *already_logged = true;
        first
    } else {
        *already_logged = false;
        false
    }
}

fn state() -> MutexGuard<'static, NetworkState> {
    STATE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn collect_catalog() -> Result<CatalogSnapshot, ()> {
    let hostname = nix::unistd::gethostname()
        .ok()
        .and_then(|name| name.into_string().ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty());

    let interfaces = getifaddrs().map_err(|_| ())?;
    let mut addresses = Vec::new();
    for interface in interfaces {
        if !interface.flags.contains(InterfaceFlags::IFF_UP) {
            continue;
        }
        let Some(address) = interface.address else {
            continue;
        };
        let ip = if let Some(address) = address.as_sockaddr_in() {
            IpAddr::V4(address.ip())
        } else if let Some(address) = address.as_sockaddr_in6() {
            IpAddr::V6(address.ip())
        } else {
            continue;
        };
        if is_link_local(ip) {
            continue;
        }
        addresses.push(NetworkAddress {
            interface_name: interface.interface_name,
            ip,
        });
    }
    sort_addresses(&mut addresses);
    addresses.dedup();
    Ok(CatalogSnapshot {
        hostname,
        addresses,
    })
}

async fn collect_default_interface(ctx: &Context) -> Option<String> {
    let ipv4_argv = [
        NETSTAT.to_string(),
        "-rn".to_string(),
        "-f".to_string(),
        "inet".to_string(),
    ];
    let ipv4 = run_command(ctx, &ipv4_argv, COMMAND_TIMEOUT).await;
    if ipv4.ok {
        if let Some(interface) = parse_default_interface(&ipv4.stdout) {
            return Some(interface);
        }
    }

    let ipv6_argv = [
        NETSTAT.to_string(),
        "-rn".to_string(),
        "-f".to_string(),
        "inet6".to_string(),
    ];
    let ipv6 = run_command(ctx, &ipv6_argv, COMMAND_TIMEOUT).await;
    ipv6.ok
        .then(|| parse_default_interface(&ipv6.stdout))
        .flatten()
}

fn parse_default_interface(output: &str) -> Option<String> {
    let mut columns = None;
    for line in output.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first() == Some(&"Destination") {
            columns = Some((
                fields.iter().position(|field| *field == "Destination")?,
                fields.iter().position(|field| *field == "Netif")?,
            ));
            continue;
        }
        let Some((destination_index, interface_index)) = columns else {
            continue;
        };
        if fields.get(destination_index) != Some(&"default") {
            continue;
        }
        let interface = *fields.get(interface_index)?;
        if !interface.is_empty()
            && interface
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Some(interface.to_string());
        }
    }
    None
}

fn interface_counters(interface: &str) -> Option<NetCounters> {
    sys::interface_counters()
        .ok()?
        .into_iter()
        .find(|entry| entry.name == interface)
        .map(|entry| NetCounters {
            received: entry.received_bytes,
            sent: entry.sent_bytes,
        })
}

fn calculate_rates(previous: &TimedCounters, current: &TimedCounters) -> RateDecision {
    if previous.interface != current.interface {
        return RateDecision::Reset;
    }
    let elapsed = current
        .sampled_at
        .saturating_duration_since(previous.sampled_at);
    if elapsed < MIN_RATE_INTERVAL {
        return RateDecision::TooSoon;
    }
    if elapsed > MAX_RATE_INTERVAL
        || current.counters.received < previous.counters.received
        || current.counters.sent < previous.counters.sent
    {
        return RateDecision::Reset;
    }
    let seconds = elapsed.as_secs_f64();
    RateDecision::Rates(TransferRates {
        received: (current.counters.received - previous.counters.received) as f64 / seconds,
        sent: (current.counters.sent - previous.counters.sent) as f64 / seconds,
    })
}

fn render_status(state: &NetworkState, summary_mode: SummaryMode) -> Option<RenderedStatus> {
    let details = render_preview(state)?;
    let rate = state.rates.map_or_else(
        || "   —".to_string(),
        |rates| rate_cells4(rates.received + rates.sent),
    );
    Some(RenderedStatus {
        summary: visible_summary(state, summary_mode),
        label: Markup::colored("NET", Color::TITLE) + " " + Markup::colored(rate, Color::MUTED),
        details,
        raw: raw_metrics(state),
    })
}

fn raw_metrics(state: &NetworkState) -> RawMetrics {
    let (down_bps, up_bps) = state
        .rates
        .map(|rates| {
            (
                whole_rate(rates.received).to_string(),
                whole_rate(rates.sent).to_string(),
            )
        })
        .unwrap_or_default();
    RawMetrics {
        down_bps,
        up_bps,
        down_history: rate_series(&state.received_history),
        up_history: rate_series(&state.sent_history),
        address: default_route_ipv4(state)
            .map(|ip| ip.to_string())
            .unwrap_or_default(),
    }
}

/// Whole bytes per second, rounded; NaN or a negative rate reads as 0.
fn whole_rate(bytes_per_second: f64) -> u64 {
    if bytes_per_second > 0.0 {
        bytes_per_second.round() as u64
    } else {
        0
    }
}

fn rate_series(history: &History<HISTORY_LEN>) -> String {
    history
        .iter()
        .map(|sample| whole_rate(sample).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The default-route interface's first IPv4 address in catalog order, from
/// the discovery pass that already feeds `network.addresses`.
fn default_route_ipv4(state: &NetworkState) -> Option<Ipv4Addr> {
    let interface = state.default_interface.as_deref()?;
    state
        .catalog
        .as_ref()?
        .addresses
        .iter()
        .find_map(|address| match address.ip {
            IpAddr::V4(ip) if address.interface_name == interface => Some(ip),
            _ => None,
        })
}

fn render_preview(state: &NetworkState) -> Option<Preview> {
    if state.default_interface.is_none() && state.wifi_ssid.is_none() && state.catalog.is_none() {
        return None;
    }
    let catalog = state.catalog.as_ref();
    let counters = state
        .previous
        .as_ref()
        .filter(|sample| Some(sample.interface.as_str()) == state.default_interface.as_deref())
        .map(|sample| sample.counters);
    let mut preview = Preview::new()
        .title("Network")
        .row("Wi-Fi", text_or_dash(state.wifi_ssid.as_deref()))
        .row(
            "Interface",
            text_or_dash(state.default_interface.as_deref()),
        )
        .row(
            "Download",
            rate_cell(state.rates.map(|rates| rates.received)),
        )
        .row("Upload", rate_cell(state.rates.map(|rates| rates.sent)))
        .row(
            "Received",
            counters.map_or_else(|| "—".to_string(), |counters| bytes_iec(counters.received)),
        )
        .row(
            "Sent",
            counters.map_or_else(|| "—".to_string(), |counters| bytes_iec(counters.sent)),
        )
        .note("Totals since interface reset · default route only")
        .row(
            "Down peak",
            state
                .received_history
                .iter()
                .reduce(f64::max)
                .map_or_else(|| "—".to_string(), rate_iec),
        )
        .row(
            "Up peak",
            state
                .sent_history
                .iter()
                .reduce(f64::max)
                .map_or_else(|| "—".to_string(), rate_iec),
        )
        .row("Down history", history_chart(&state.received_history))
        .row("Up history", history_chart(&state.sent_history))
        .row(
            "Hostname",
            text_or_dash(catalog.and_then(|catalog| catalog.hostname.as_deref())),
        );
    if let Some(catalog) = catalog {
        for (index, address) in catalog.addresses.iter().take(8).enumerate() {
            preview = preview.row(
                format!("Address {}", index + 1),
                Markup::text(format!("{}  {}", address.interface_name, address.ip)),
            );
        }
        if catalog.addresses.len() > 8 {
            preview = preview.row("More", format!("{} addresses", catalog.addresses.len() - 8));
        }
    }
    Some(preview)
}

fn text_or_dash(value: Option<&str>) -> Markup {
    value.map_or_else(|| Markup::raw("—"), Markup::text)
}

fn rate_cell(bytes_per_second: Option<f64>) -> String {
    format!(
        "{:>12}",
        bytes_per_second.map_or_else(|| "—".to_string(), rate_iec)
    )
}

fn history_chart(history: &History<HISTORY_LEN>) -> String {
    sparkline_padded(&sparkline_scaled(history), HISTORY_LEN)
}

fn visible_summary(state: &NetworkState, summary_mode: SummaryMode) -> Markup {
    let label = Markup::colored("NET", Color::TITLE);
    if summary_mode == SummaryMode::Compact {
        return label;
    }
    let (received, sent) = state.rates.map_or_else(
        || ("—".to_string(), "—".to_string()),
        |rates| {
            (
                bytes_iec_compact(rates.received),
                bytes_iec_compact(rates.sent),
            )
        },
    );
    let chart = sparkline_scaled(
        state
            .received_history
            .iter()
            .zip(&state.sent_history)
            .map(|(received, sent)| received.max(sent)),
    );
    let mut summary = label
        + " "
        + Markup::colored(format!("↓{received}"), Color::INBOUND)
        + " "
        + Markup::colored(format!("↑{sent}"), Color::OUTBOUND);
    if !chart.is_empty() {
        summary += format!(" {chart}");
    }
    summary
}

fn is_link_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_link_local(),
        IpAddr::V6(ip) => ip.is_unicast_link_local(),
    }
}

fn sort_addresses(addresses: &mut [NetworkAddress]) {
    addresses.sort_by_key(|address| {
        (
            address.ip.is_loopback(),
            matches!(address.ip, IpAddr::V6(_)),
            address.interface_name.clone(),
            address.ip.to_string(),
        )
    });
}

fn main() {
    run(Network);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::net::{Ipv4Addr, Ipv6Addr};

    use flash_plugin::testing::Harness;
    use flash_plugin::CandidateEffect;
    use serde_json::json;

    use super::*;

    #[test]
    fn details_show_current_interface_totals_and_recent_peaks() {
        let state = NetworkState {
            default_interface: Some("en0".to_string()),
            previous: Some(TimedCounters {
                interface: "en0".to_string(),
                sampled_at: Instant::now(),
                counters: NetCounters {
                    received: 3 << 30,
                    sent: 1 << 30,
                },
            }),
            received_history: history([1024.0, 2048.0]),
            sent_history: history([512.0, 1024.0]),
            ..NetworkState::default()
        };
        let details = render_preview(&state).unwrap().render_plain();
        assert!(details.contains("Received      3.0 GiB"), "{details}");
        assert!(details.contains("Sent          1.0 GiB"), "{details}");
        assert!(details.contains("Down peak     2.0 KiB/s"), "{details}");
        assert!(details.contains("Up peak       1.0 KiB/s"), "{details}");
        assert!(details.lines().all(|line| line.chars().count() <= 50));
        let changed = NetworkState {
            default_interface: Some("utun0".to_string()),
            ..state
        };
        let details = render_preview(&changed).unwrap().render_plain();
        assert!(
            !details.contains("3.0 GiB"),
            "old interface counters must not leak: {details}"
        );
    }

    fn history(values: impl IntoIterator<Item = f64>) -> History<HISTORY_LEN> {
        let mut history = History::new();
        values.into_iter().for_each(|value| history.push(value));
        history
    }

    fn wire(status: &RenderedStatus) -> BTreeMap<&'static str, String> {
        status
            .segments()
            .into_iter()
            .map(|(name, value)| (name, value.render().unwrap()))
            .collect()
    }

    #[test]
    fn label_keeps_aggregate_rate_width_across_units_and_sampling() {
        for (rate, expected) in [
            (None, "   —"),
            (Some(0.0), "  0B"),
            (Some(9.0), "  9B"),
            (Some(999.0), "999B"),
            (Some(999.96), "1.0K"),
            (Some(1200.0), "1.2K"),
            (Some(1_200_000.0), "1.2M"),
            (Some(1_200_000_000.0), "1.2G"),
            (Some(f64::MAX), "999P"),
        ] {
            let state = NetworkState {
                default_interface: Some("en0".to_string()),
                rates: rate.map(|rate| TransferRates {
                    received: rate * 0.75,
                    sent: rate * 0.25,
                }),
                ..NetworkState::default()
            };
            let status = render_status(&state, SummaryMode::Full).unwrap();
            assert_eq!(
                status.label.as_str(),
                format!("#[fg=#EBCB8B]NET#[default] #[fg=colour245]{expected}#[default]")
            );
            let wire = wire(&status);
            assert!(wire["summary"].contains("popup="));
            assert_eq!(wire["label"], status.label.as_str());
        }
    }

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    fn address(interface_name: &str, ip: IpAddr) -> NetworkAddress {
        NetworkAddress {
            interface_name: interface_name.to_string(),
            ip,
        }
    }

    fn sample(interface: &str, received: u64, sent: u64, sampled_at: Instant) -> TimedCounters {
        TimedCounters {
            interface: interface.to_string(),
            counters: NetCounters { received, sent },
            sampled_at,
        }
    }

    #[test]
    fn parses_default_interface_from_routing_table_without_accepting_shell_syntax() {
        let output = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n\
default 10.10.0.1 UGScg en0\n\
10.10/16 link#14 UCS en0 !\n";
        assert_eq!(parse_default_interface(output).as_deref(), Some("en0"));
        let invalid = "Destination Gateway Flags Netif\ndefault gateway UGScg en0;open\n";
        assert_eq!(parse_default_interface(invalid), None);
        let ipv6 = "Internet6:\nDestination Gateway Flags Netif Expire\n\
default fe80::%utun6 UGcIg utun6\n";
        assert_eq!(parse_default_interface(ipv6).as_deref(), Some("utun6"));
    }

    #[test]
    fn rates_use_actual_elapsed_time() {
        let start = Instant::now();
        let previous = sample("en0", 1_000, 2_000, start);
        let current = sample("en0", 11_000, 7_000, start + Duration::from_secs(5));
        let RateDecision::Rates(rates) = calculate_rates(&previous, &current) else {
            panic!("expected rates");
        };
        assert_eq!(rates.received, 2_000.0);
        assert_eq!(rates.sent, 1_000.0);
    }

    #[test]
    fn resets_on_counter_rollback_interface_change_or_wake_gap() {
        let start = Instant::now();
        let previous = sample("en0", 1_000, 2_000, start);
        assert!(matches!(
            calculate_rates(
                &previous,
                &sample("en0", 900, 3_000, start + Duration::from_secs(2))
            ),
            RateDecision::Reset
        ));
        assert!(matches!(
            calculate_rates(
                &previous,
                &sample("utun3", 2_000, 3_000, start + Duration::from_secs(2))
            ),
            RateDecision::Reset
        ));
        assert!(matches!(
            calculate_rates(
                &previous,
                &sample("en0", 2_000, 3_000, start + Duration::from_secs(11))
            ),
            RateDecision::Reset
        ));
    }

    #[test]
    fn stale_rates_expire_without_discarding_address_catalog() {
        let sampled_at = Instant::now();
        let catalog = CatalogSnapshot {
            hostname: Some("moria".to_string()),
            addresses: vec![address("en0", "10.0.0.2".parse().unwrap())],
        };
        let mut state = NetworkState {
            default_interface: Some("en0".to_string()),
            rates: Some(TransferRates {
                received: 10.0,
                sent: 20.0,
            }),
            received_history: history([10.0]),
            sent_history: history([20.0]),
            catalog: Some(catalog.clone()),
            last_traffic_success: Some(sampled_at),
            ..NetworkState::default()
        };

        assert!(!state.expire_stale_rates(sampled_at + MAX_RATE_INTERVAL));
        assert!(state.expire_stale_rates(sampled_at + MAX_RATE_INTERVAL + Duration::from_millis(1)));
        assert_eq!(state.rates, None);
        assert!(state.received_history.is_empty());
        assert!(state.sent_history.is_empty());
        assert_eq!(state.catalog, Some(catalog));
        let plain = render_preview(&state).unwrap().render_plain();
        assert!(plain.contains(&format!("Download{}—", " ".repeat(17))));
        assert!(plain.contains("Hostname      moria"));
    }

    #[test]
    fn address_order_is_ipv4_then_ipv6_with_loopback_last() {
        let mut addresses = vec![
            address("lo0", IpAddr::V4(Ipv4Addr::LOCALHOST)),
            address("en1", "2001:db8::2".parse().unwrap()),
            address("en0", "10.0.0.20".parse().unwrap()),
            address("en0", "10.0.0.3".parse().unwrap()),
            address("en0", "2001:db8::1".parse().unwrap()),
        ];
        sort_addresses(&mut addresses);
        let ordered: Vec<String> = addresses
            .iter()
            .map(|address| format!("{} {}", address.interface_name, address.ip))
            .collect();
        assert_eq!(
            ordered,
            [
                "en0 10.0.0.20",
                "en0 10.0.0.3",
                "en0 2001:db8::1",
                "en1 2001:db8::2",
                "lo0 127.0.0.1",
            ]
        );
    }

    #[test]
    fn link_local_filter_matches_interface_expectations() {
        assert!(is_link_local(IpAddr::V4(Ipv4Addr::new(169, 254, 1, 2))));
        assert!(is_link_local(IpAddr::V6("fe80::1".parse().unwrap())));
        assert!(!is_link_local(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))));
        assert!(!is_link_local(IpAddr::V6(Ipv6Addr::LOCALHOST)));
    }

    #[test]
    fn hostname_precedes_copyable_interface_rows_under_renamed_source() {
        let snapshot = CatalogSnapshot {
            hostname: Some("moria".to_string()),
            addresses: vec![address("en0", "10.0.0.2".parse().unwrap())],
        };
        let rows = snapshot.candidates();
        assert_eq!(rows[0].source, "network.addresses");
        assert_eq!(rows[0].title, "hostname moria");
        assert_eq!(rows[0].payload_str(), Some("moria"));
        assert_eq!(rows[1].title, "en0 10.0.0.2");
        match rows[1].effect.as_ref() {
            Some(CandidateEffect::CopyText { text }) => assert_eq!(text, "10.0.0.2"),
            other => panic!("unexpected effect: {other:?}"),
        }
    }

    #[test]
    fn plain_reply_is_the_preview_without_markers() {
        let state = NetworkState {
            default_interface: Some("en0".to_string()),
            wifi_ssid: Some("Studio #[fg=colour196]".to_string()),
            received_history: history((0..HISTORY_LEN).map(|value| value as f64)),
            ..NetworkState::default()
        };

        let plain = render_preview(&state).unwrap().render_plain();
        assert_eq!(plain.lines().next(), Some("Network"));
        assert!(plain.contains("Wi-Fi         Studio #[fg=colour196]"));
        assert!(!plain.contains("#[default]"));
        let chart = plain
            .lines()
            .find_map(|line| line.strip_prefix("Down history  "))
            .unwrap();
        assert_eq!(chart.chars().count(), HISTORY_LEN);
        assert!(!chart.contains('·'));
    }

    #[test]
    fn renders_styled_summary_with_inline_popup_and_escaped_details() {
        let mut state = NetworkState {
            default_interface: Some("en#0".to_string()),
            wifi_ssid: Some("Studio #[fg=colour196]".to_string()),
            rates: Some(TransferRates {
                received: 1_572_864.0,
                sent: 2_048.0,
            }),
            catalog: Some(CatalogSnapshot {
                hostname: Some("moria #[fg=colour196]".to_string()),
                addresses: vec![address("en#0", "10.0.0.2".parse().unwrap())],
            }),
            ..NetworkState::default()
        };
        state.received_history.push(1.0);
        state.sent_history.push(0.5);
        let rendered = render_status(&state, SummaryMode::Compact).unwrap();
        let wire = wire(&rendered);
        assert!(wire["summary"].starts_with("#[popup=inline:"));
        assert!(wire["summary"].ends_with("]#[fg=#EBCB8B]NET#[default]#[nopopup]"));
        assert!(!wire["summary"].contains("↓1.5MiB"));
        assert_eq!(
            visible_summary(&state, SummaryMode::Compact).as_str(),
            "#[fg=#EBCB8B]NET#[default]"
        );
        assert!(!visible_summary(&state, SummaryMode::Full)
            .as_str()
            .contains("Studio"));
        assert_eq!(
            visible_summary(&state, SummaryMode::Full).as_str(),
            "#[fg=#EBCB8B]NET#[default] #[fg=colour39]↓1.5MiB#[default] #[fg=colour214]↑2.0KiB#[default] █"
        );
        assert!(rendered
            .details
            .render_plain()
            .contains("Hostname      moria #[fg=colour196]"));
        assert_eq!(
            wire["details"],
            "#[fg=#EBCB8B]Network#[default]\n\
#[fg=colour245]Wi-Fi         #[default]Studio ##[fg=colour196]\n\
#[fg=colour245]Interface     #[default]en##0\n\
#[fg=colour245]Download      #[default]   1.5 MiB/s\n\
#[fg=colour245]Upload        #[default]   2.0 KiB/s\n\
#[fg=colour245]Received      #[default]—\n\
#[fg=colour245]Sent          #[default]—\n\
#[fg=colour245]Totals since interface reset · default route only#[default]\n\
#[fg=colour245]Down peak     #[default]1 B/s\n\
#[fg=colour245]Up peak       #[default]0 B/s\n\
#[fg=colour245]Down history  #[default]···················█\n\
#[fg=colour245]Up history    #[default]···················█\n\
#[fg=colour245]Hostname      #[default]moria ##[fg=colour196]\n\
#[fg=colour245]Address 1     #[default]en##0  10.0.0.2"
        );
        assert!(!wire["details"].ends_with('\n'));
    }

    #[test]
    fn popup_details_have_one_styled_title_then_the_network_body() {
        let state = NetworkState {
            default_interface: Some("en0".to_string()),
            wifi_ssid: Some("Atelier".to_string()),
            ..NetworkState::default()
        };

        assert_eq!(
            render_status(&state, SummaryMode::Compact)
                .unwrap()
                .details
                .render()
                .as_str(),
            "#[fg=#EBCB8B]Network#[default]\n\
#[fg=colour245]Wi-Fi         #[default]Atelier\n\
#[fg=colour245]Interface     #[default]en0\n\
#[fg=colour245]Download      #[default]           —\n\
#[fg=colour245]Upload        #[default]           —\n\
#[fg=colour245]Received      #[default]—\n\
#[fg=colour245]Sent          #[default]—\n\
#[fg=colour245]Totals since interface reset · default route only#[default]\n\
#[fg=colour245]Down peak     #[default]—\n\
#[fg=colour245]Up peak       #[default]—\n\
#[fg=colour245]Down history  #[default]····················\n\
#[fg=colour245]Up history    #[default]····················\n\
#[fg=colour245]Hostname      #[default]—"
        );
        assert_eq!(TRAFFIC_POLL, Duration::from_secs(1));
        assert_eq!(DISCOVERY_POLL, Duration::from_secs(30));
        assert_eq!(HISTORY_LEN, 20);
    }

    #[tokio::test]
    async fn identical_rendered_status_is_suppressed() {
        // Shares the process-wide `STATE` with the scenarios below.
        let _guard = SCENARIO.lock().await;
        let mut harness = Harness::new("network");
        let ctx = harness.context();
        *state() = NetworkState {
            default_interface: Some("en0".to_string()),
            ..NetworkState::default()
        };

        emit_status_if_changed(&ctx);
        emit_status_if_changed(&ctx);
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert_eq!(
            frames[0]["label"],
            "#[fg=#EBCB8B]NET#[default] #[fg=colour245]   —#[default]"
        );
        assert!(frames[0]["summary"].starts_with("#[popup=inline:"));
        assert!(frames[0]["details"].starts_with("#[fg=#EBCB8B]Network#[default]\n"));
        for raw in [
            "down_bps",
            "up_bps",
            "down_history",
            "up_history",
            "address",
        ] {
            assert_eq!(frames[0][raw], "", "unknown {raw} clears its segment");
        }

        state().rates = Some(TransferRates {
            received: 600_000.0,
            sent: 600_000.0,
        });
        emit_status_if_changed(&ctx);
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert_eq!(
            frames[0]["label"],
            "#[fg=#EBCB8B]NET#[default] #[fg=colour245]1.2M#[default]"
        );
        assert_eq!(frames[0]["down_bps"], "600000");
        assert_eq!(frames[0]["up_bps"], "600000");
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
    fn label_sums_download_and_upload_without_changing_width_while_sampling() {
        let mut state = NetworkState {
            default_interface: Some("en0".into()),
            ..NetworkState::default()
        };
        assert_eq!(
            render_status(&state, SummaryMode::Compact)
                .unwrap()
                .label
                .as_str(),
            "#[fg=#EBCB8B]NET#[default] #[fg=colour245]   —#[default]"
        );
        state.rates = Some(TransferRates {
            received: 600_000.0,
            sent: 600_000.0,
        });
        assert_eq!(
            render_status(&state, SummaryMode::Compact)
                .unwrap()
                .label
                .as_str(),
            "#[fg=#EBCB8B]NET#[default] #[fg=colour245]1.2M#[default]"
        );
    }

    // -- Scenarios over the SDK harness with a scripted host ----------------

    /// The plugin's `STATE`/`REFRESH_GATE` statics are process-wide, so the
    /// scenarios below serialize on this lock and start from a fresh state.
    static SCENARIO: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    async fn scenario_harness() -> (tokio::sync::MutexGuard<'static, ()>, Harness) {
        let guard = SCENARIO.lock().await;
        *state() = NetworkState::default();
        let harness = Harness::new("network");
        // run_command uses the data dir as cwd; create it like the host does.
        tokio::fs::create_dir_all(harness.data_dir()).await.unwrap();
        (guard, harness)
    }

    fn command(subcommand: &str) -> CommandRequest {
        CommandRequest {
            command: "network".to_string(),
            subcommand: subcommand.to_string(),
            raw: format!(":network {subcommand}"),
            ..CommandRequest::default()
        }
    }

    #[tokio::test]
    async fn startup_reads_wifi_passively_and_the_ssid_reaches_details_and_commands() {
        let (_guard, mut harness) = scenario_harness().await;
        let ctx = harness.context();
        let startup = tokio::spawn(async move { Network.on_start(ctx).await });

        let (id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(method, "host.wifi_info");
        assert_eq!(params, json!({ "request_authorization": false }));
        assert!(harness.reply_host(
            id,
            json!({ "ok": true, "present": true, "ssid": "Atelier" })
        ));
        startup.await.unwrap();

        let status = harness.drain_status();
        let details = &status.last().expect("initial status")["details"];
        assert!(
            details.contains("Wi-Fi") && details.contains("Atelier"),
            "{details}"
        );

        let bare = Network.on_command(harness.context(), command("")).await;
        assert!(bare.is_ok());
        let message = bare.toast_message().expect("toast").to_string();
        assert!(message.contains("Network"), "{message}");

        // An explicit refresh asks for authorization and reflects the new SSID.
        let ctx = harness.context();
        let refresh =
            tokio::spawn(async move { Network.on_command(ctx, command("refresh")).await });
        let (id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": true }))
        );
        assert!(harness.reply_host(id, json!({ "ok": true, "present": true, "ssid": "Office" })));
        let response = refresh.await.unwrap();
        assert!(response.is_ok());
        let message = response.toast_message().expect("toast").to_string();
        assert!(message.contains("Wi-Fi         Office"), "{message}");
    }

    #[tokio::test]
    async fn explicit_refresh_requests_authorization_while_startup_holds_the_gate() {
        let (_guard, mut harness) = scenario_harness().await;
        let ctx = harness.context();
        let startup = tokio::spawn(async move { Network.on_start(ctx).await });
        let (startup_id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": false }))
        );

        // The startup refresh is still awaiting its Wi-Fi reply, so it owns
        // the gate; the user's refresh must not queue behind it.
        let ctx = harness.context();
        let refresh =
            tokio::spawn(async move { Network.on_command(ctx, command("refresh")).await });
        let (id, method, params) = harness
            .next_host_request()
            .await
            .expect("authorization read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": true }))
        );
        assert!(harness.reply_host(id, json!({ "ok": true, "present": false })));
        // Answering at all is the contract: the user's refresh completed while
        // the startup refresh still owned the gate. Whether anything was
        // collectible depends on the host's interfaces, so the ok/fail shape
        // of the reply is deliberately not pinned here.
        refresh
            .await
            .expect("refresh must not queue behind the startup gate");

        assert!(harness.reply_host(startup_id, json!({ "ok": true, "present": false })));
        startup.await.unwrap();
        let status = harness.drain_status();
        assert!(!status.last().expect("initial status")["summary"].is_empty());
    }

    #[test]
    fn raw_segments_carry_whole_byte_rates_and_histories_oldest_first() {
        let state = NetworkState {
            default_interface: Some("en0".to_string()),
            rates: Some(TransferRates {
                received: 1_572_864.0,
                sent: 2_048.4,
            }),
            received_history: history([0.0, 1_536.4, 1_024.5]),
            sent_history: history([10.0, 20.0, 2_048.4]),
            ..NetworkState::default()
        };
        let wire = wire(&render_status(&state, SummaryMode::Compact).unwrap());
        assert_eq!(wire["down_bps"], "1572864");
        assert_eq!(wire["up_bps"], "2048");
        assert_eq!(wire["down_history"], "0 1536 1025");
        assert_eq!(wire["up_history"], "10 20 2048");

        let long = history((0..25).map(|value| f64::from(value) * 1_000.0));
        let expected = (5..25)
            .map(|value| (value * 1_000).to_string())
            .collect::<Vec<_>>();
        assert_eq!(rate_series(&long), expected.join(" "));
    }

    #[test]
    fn idle_traffic_publishes_zero_while_unknown_rates_clear() {
        let mut state = NetworkState {
            default_interface: Some("en0".to_string()),
            rates: Some(TransferRates {
                received: 0.0,
                sent: 0.4,
            }),
            received_history: history([0.0, 0.0]),
            sent_history: history([0.0, 0.4]),
            ..NetworkState::default()
        };
        let raw = raw_metrics(&state);
        assert_eq!((raw.down_bps.as_str(), raw.up_bps.as_str()), ("0", "0"));
        assert_eq!(raw.down_history, "0 0");
        assert_eq!(raw.up_history, "0 0");

        state.last_traffic_success = Some(Instant::now());
        assert!(state.expire_stale_rates(Instant::now() + MAX_RATE_INTERVAL * 2));
        assert_eq!(raw_metrics(&state), RawMetrics::default());
        assert_eq!(whole_rate(f64::NAN), 0);
        assert_eq!(whole_rate(-1.0), 0);
    }

    #[test]
    fn address_is_the_default_route_interfaces_first_ipv4() {
        let mut addresses = vec![
            address("lo0", IpAddr::V4(Ipv4Addr::LOCALHOST)),
            address("en1", "10.0.0.9".parse().unwrap()),
            address("en0", "2001:db8::1".parse().unwrap()),
            address("en0", "192.168.1.20".parse().unwrap()),
        ];
        sort_addresses(&mut addresses);
        let mut state = NetworkState {
            default_interface: Some("en0".to_string()),
            catalog: Some(CatalogSnapshot {
                hostname: None,
                addresses,
            }),
            ..NetworkState::default()
        };
        assert_eq!(raw_metrics(&state).address, "192.168.1.20");

        state.default_interface = Some("utun4".to_string());
        assert_eq!(raw_metrics(&state).address, "", "an IPv6-only route clears");
        state.default_interface = None;
        assert_eq!(raw_metrics(&state).address, "");
    }
}
