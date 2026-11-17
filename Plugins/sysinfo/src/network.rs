//! Network: default-route traffic from the interface counters `netstat -bI`
//! prints, sampled every second while a traffic segment is shown; the
//! interface, routes, addresses and Wi-Fi name rediscovered on every
//! `core:network.changed`. The address catalog feeds `network.addresses`.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::status::{
    bytes_iec, bytes_iec_compact, rate_cells4, rate_iec, sparkline_padded, sparkline_scaled,
};
use flash_plugin::{
    Candidate, Color, Context, History, Markup, PerformResponse, PollHandle, PollPriority, Preview,
    Published, RefreshGate, StatusValue, sys,
};
use nix::ifaddrs::getifaddrs;
use nix::net::if_::InterfaceFlags;
use tokio::task::JoinHandle;

use crate::common::{
    HISTORY_SAMPLES, SummaryMode, configured_summary_mode, first_failure, lock, plain, rate_series,
    whole_rate,
};

/// The `core:status.observed` prefix of this domain's segments.
pub(crate) const PREFIX: &str = "network_";
/// The published segments, in manifest order.
pub(crate) const SEGMENTS: [&str; 8] = [
    "network_summary",
    "network_label",
    "network_details",
    "network_down_bps",
    "network_up_bps",
    "network_down_history",
    "network_up_history",
    "network_address",
];

const SOURCE_ADDRESSES: &str = "network.addresses";
/// Traffic sampling cadence, registered with the host only while a surface
/// shows one of [`TRAFFIC_SEGMENTS`]: byte counters have no change event.
/// Interface, route, address and SSID discovery feeds the `network.addresses`
/// catalog and the `address` segment whether or not a surface shows the
/// plugin, so it runs at start, on every `core:network.changed` and on
/// `:sysinfo refresh`, and never on a timer.
const TRAFFIC_POLL: Duration = Duration::from_secs(1);
/// The segments the traffic sample feeds, as the domain names them (without
/// the `network_` prefix); `address` follows discovery alone.
const TRAFFIC_SEGMENTS: [&str; 7] = [
    "summary",
    "label",
    "details",
    "down_bps",
    "up_bps",
    "down_history",
    "up_history",
];
const MIN_RATE_INTERVAL: Duration = Duration::from_millis(500);
const MAX_RATE_INTERVAL: Duration = Duration::from_secs(10);

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
        let [
            summary,
            label,
            details,
            down_bps,
            up_bps,
            down_history,
            up_history,
            address,
        ] = SEGMENTS;
        [
            (
                summary,
                StatusValue::text(self.summary.clone()).with_preview(self.details.clone()),
            ),
            (label, StatusValue::text(self.label.clone())),
            (details, StatusValue::text(self.details.render())),
            (down_bps, plain(&self.raw.down_bps)),
            (up_bps, plain(&self.raw.up_bps)),
            (down_history, plain(&self.raw.down_history)),
            (up_history, plain(&self.raw.up_history)),
            (address, plain(&self.raw.address)),
        ]
    }
}

#[derive(Default)]
struct NetworkState {
    default_interface: Option<String>,
    wifi_ssid: Option<String>,
    previous: Option<TimedCounters>,
    rates: Option<TransferRates>,
    received_history: History<HISTORY_SAMPLES>,
    sent_history: History<HISTORY_SAMPLES>,
    catalog: Option<CatalogSnapshot>,
    last_traffic_success: Option<Instant>,
    /// A surface shows a traffic-fed segment: only then is traffic sampled.
    traffic_observed: bool,
    /// Registered on first observation, re-armed or cancelled in place after.
    traffic_poll: Option<PollHandle>,
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

/// What one refresh collects. Traffic is sampled only while observed.
#[derive(Clone, Copy)]
struct Pass {
    discover: bool,
    sample: bool,
}

const STARTUP: Pass = Pass {
    discover: true,
    sample: true,
};
const DISCOVERY: Pass = Pass {
    discover: true,
    sample: false,
};
const TRAFFIC_TICK: Pass = Pass {
    discover: false,
    sample: true,
};

#[derive(Clone, Default)]
pub(crate) struct Network {
    state: Arc<Mutex<NetworkState>>,
    gate: RefreshGate,
}

impl Network {
    /// Discovery plus a first traffic sample; nothing registers a cadence
    /// until a traffic segment is observed.
    pub(crate) async fn start(&self, ctx: &Context) {
        self.refresh_pass(ctx, STARTUP).await;
    }

    /// `core:network.changed`: interfaces, addresses, routes or DNS changed,
    /// so rediscover off the event worker, where an observation never waits
    /// behind it.
    pub(crate) fn network_changed(&self, ctx: &Context) {
        let ctx = ctx.clone();
        let network = self.clone();
        tokio::spawn(async move {
            network.refresh_pass(&ctx, DISCOVERY).await;
        });
    }

    /// `core:status.observed`, reduced to this domain's segments.
    pub(crate) fn observe(&self, ctx: &Context, segments: &[String]) {
        drop(self.observe_traffic(ctx, segments));
    }

    /// The details of the last discovery and sample.
    pub(crate) fn show(&self) -> PerformResponse {
        self.current_response()
    }

    /// Discovery with a Wi-Fi read that may ask for Location, returning at
    /// once while a refresh is running.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        let wifi_ssid = ctx.wifi_ssid(true).await;
        self.try_refresh_pass(ctx, STARTUP, wifi_ssid).await;
    }

    /// The visible summary of the last discovery and sample.
    pub(crate) fn summary(&self, ctx: &Context) -> Option<Markup> {
        render_status(&self.state(), configured_summary_mode(ctx)).map(|rendered| rendered.summary)
    }

    /// Apply the host's observed segment set: the traffic cadence is armed
    /// only while a traffic-fed segment is observed and cancelled as soon as
    /// none is, clearing the rates so showing them again never reads stale
    /// figures. Returns the immediate sample when traffic just became
    /// observed.
    fn observe_traffic(&self, ctx: &Context, segments: &[String]) -> Option<JoinHandle<()>> {
        let observed = segments
            .iter()
            .any(|segment| TRAFFIC_SEGMENTS.contains(&segment.as_str()));
        {
            let mut state = self.state();
            if state.traffic_observed == observed {
                return None;
            }
            state.traffic_observed = observed;
            if observed {
                match &state.traffic_poll {
                    Some(poll) => poll.set_period(TRAFFIC_POLL),
                    None => {
                        let network = self.clone();
                        // `High`: one-second rates on screen tick visibly.
                        state.traffic_poll =
                            Some(ctx.interval(TRAFFIC_POLL, PollPriority::High, move |ctx| {
                                let network = network.clone();
                                async move {
                                    network.refresh_pass(&ctx, TRAFFIC_TICK).await;
                                }
                            }));
                    }
                }
            } else {
                if let Some(poll) = &state.traffic_poll {
                    poll.cancel();
                }
                state.reset_rates();
            }
        }
        if !observed {
            self.emit_status_if_changed(ctx);
            return None;
        }
        let ctx = ctx.clone();
        let network = self.clone();
        Some(tokio::spawn(async move {
            network.refresh_pass(&ctx, TRAFFIC_TICK).await;
        }))
    }

    async fn refresh_pass(&self, ctx: &Context, pass: Pass) {
        self.gate
            .run(ctx, move |ctx, _applications| async move {
                self.refresh_locked(&ctx, pass, WiFiSSIDRead::Passive).await;
            })
            .await;
    }

    async fn try_refresh_pass(&self, ctx: &Context, pass: Pass, wifi_ssid: Option<String>) {
        let _ = self
            .gate
            .try_run(ctx, move |ctx, _applications| async move {
                self.refresh_locked(&ctx, pass, WiFiSSIDRead::Prefetched(wifi_ssid))
                    .await;
            })
            .await;
    }

    async fn refresh_locked(&self, ctx: &Context, pass: Pass, wifi_ssid_read: WiFiSSIDRead) {
        let discovery_due = pass.discover;

        let discovery = if discovery_due {
            let wifi_ssid = async move {
                match wifi_ssid_read {
                    WiFiSSIDRead::Passive => ctx.wifi_ssid(false).await,
                    WiFiSSIDRead::Prefetched(wifi_ssid) => wifi_ssid,
                }
            };
            // The routing table is one in-process sysctl read.
            let interface = collect_default_interface();
            let (wifi_ssid, catalog) =
                tokio::join!(wifi_ssid, tokio::task::spawn_blocking(collect_catalog));
            Some((interface, wifi_ssid, catalog))
        } else {
            None
        };

        let mut rows_to_publish = None;
        let mut discovery_failed = false;
        let (interface, log_discovery_failure) = {
            let mut state = self.state();
            if let Some((interface, wifi_ssid, catalog)) = discovery {
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
            let log_failure = discovery_due
                && first_failure(&mut state.discovery_failure_logged, discovery_failed);
            (state.default_interface.clone(), log_failure)
        };

        if let Some(rows) = rows_to_publish {
            ctx.publish(rows);
        }
        if log_discovery_failure {
            ctx.log(
                "warn",
                "[sysinfo] routing table or address discovery failed",
            );
        }

        let mut traffic_failed = None;
        if let Some(interface) = interface.filter(|_| pass.sample && self.state().traffic_observed)
        {
            // Lifetime byte counters straight from the routing sysctl — the same
            // 64-bit figures `netstat -bI` prints, without a subprocess per second.
            match interface_counters(&interface) {
                Some(counters) => {
                    let mut state = self.state();
                    // Checked again under the lock: observation may have ended
                    // while the counters were read.
                    if state.traffic_observed {
                        state.apply_sample(TimedCounters {
                            interface,
                            counters,
                            sampled_at: Instant::now(),
                        });
                    }
                    traffic_failed = Some(false);
                }
                None => traffic_failed = Some(true),
            }
        }
        let log_traffic_failure = {
            let mut state = self.state();
            let log_failure = traffic_failed
                .is_some_and(|failed| first_failure(&mut state.traffic_failure_logged, failed));
            state.expire_stale_rates(Instant::now());
            log_failure
        };
        if log_traffic_failure {
            ctx.log("warn", "[sysinfo] traffic counters unavailable");
        }

        self.emit_status_if_changed(ctx);
    }

    fn current_response(&self) -> PerformResponse {
        match render_preview(&self.state()) {
            Some(preview) => PerformResponse::ok().message(preview.render_plain()),
            None => PerformResponse::fail("network metrics are not available yet"),
        }
    }

    fn emit_status_if_changed(&self, ctx: &Context) {
        let segments = {
            let mut state = self.state();
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

    fn state(&self) -> MutexGuard<'_, NetworkState> {
        lock(&self.state)
    }
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

/// The interface of the first default route `netstat -rn` lists: IPv4's,
/// else IPv6's (an IPv6-only network), read from the kernel routing table.
fn collect_default_interface() -> Option<String> {
    [sys::RouteFamily::Ipv4, sys::RouteFamily::Ipv6]
        .into_iter()
        .find_map(|family| first_default_interface(&sys::default_routes(family).ok()?))
}

/// The first default route's interface that is a plain interface name; a
/// route whose interface is gone or oddly named is skipped.
fn first_default_interface(routes: &[sys::DefaultRoute]) -> Option<String> {
    routes
        .iter()
        .filter_map(|route| route.interface.as_deref())
        .find(|interface| {
            !interface.is_empty()
                && interface
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
        .map(str::to_string)
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
        // The template owns the name and the width (`#[label]NET #[default]#{p-4:…}`).
        // The host trims a status value, so the reserved cells live in `p-4`.
        label: Markup::text(rate.trim()),
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

fn history_chart(history: &History<HISTORY_SAMPLES>) -> String {
    sparkline_padded(&sparkline_scaled(history), HISTORY_SAMPLES)
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::net::{Ipv4Addr, Ipv6Addr};

    use flash_plugin::CandidateEffect;
    use flash_plugin::testing::Harness;
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn segments_carry_the_domain_prefix_in_manifest_order() {
        let state = NetworkState {
            default_interface: Some("en0".to_string()),
            ..NetworkState::default()
        };
        let status = render_status(&state, SummaryMode::Compact).unwrap();
        assert_eq!(status.segments().map(|(name, _)| name), SEGMENTS);
        assert!(SEGMENTS.iter().all(|name| name.starts_with(PREFIX)));
        // The traffic filter reads the names the domain sees: prefix-free.
        assert!(
            TRAFFIC_SEGMENTS
                .iter()
                .all(|name| SEGMENTS.contains(&format!("{PREFIX}{name}").as_str()))
        );
    }

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

    fn history(values: impl IntoIterator<Item = f64>) -> History<HISTORY_SAMPLES> {
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
            (None, "—"),
            (Some(0.0), "0B"),
            (Some(9.0), "9B"),
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
            assert_eq!(status.label.as_str(), expected);
            assert!(!status.label.as_str().contains("#["));
            let wire = wire(&status);
            assert!(wire["network_summary"].contains("popup="));
            assert_eq!(wire["network_label"], status.label.as_str());
        }
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
    fn default_interface_is_the_first_plainly_named_default_route() {
        let route = |interface_index: u16, interface: Option<&str>| sys::DefaultRoute {
            interface_index,
            interface: interface.map(str::to_string),
        };
        assert_eq!(
            first_default_interface(&[route(14, Some("en0")), route(21, Some("utun3"))]).as_deref(),
            Some("en0")
        );
        assert_eq!(
            first_default_interface(&[route(14, Some("en0;open"))]),
            None
        );
        assert_eq!(
            first_default_interface(&[
                route(9, None),
                route(10, Some("")),
                route(11, Some("en 1")),
                route(23, Some("utun6")),
            ])
            .as_deref(),
            Some("utun6")
        );
        assert_eq!(first_default_interface(&[]), None);
    }

    /// Tolerant of the host's connectivity: offline, there is no default
    /// route; online, its interface is one the address catalog can match.
    #[test]
    fn default_interface_reads_this_macs_routing_table() {
        if let Some(interface) = collect_default_interface() {
            assert!(
                sys::interface_counters()
                    .expect("interfaces")
                    .iter()
                    .any(|counters| counters.name == interface),
                "{interface}"
            );
        }
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
        assert!(
            state.expire_stale_rates(sampled_at + MAX_RATE_INTERVAL + Duration::from_millis(1))
        );
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
            received_history: history((0..HISTORY_SAMPLES).map(|value| value as f64)),
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
        assert_eq!(chart.chars().count(), HISTORY_SAMPLES);
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
        assert!(wire["network_summary"].starts_with("#[popup=inline:"));
        assert!(wire["network_summary"].ends_with("]#[fg=#EBCB8B]NET#[default]#[nopopup]"));
        assert!(!wire["network_summary"].contains("↓1.5MiB"));
        assert_eq!(
            visible_summary(&state, SummaryMode::Compact).as_str(),
            "#[fg=#EBCB8B]NET#[default]"
        );
        assert!(
            !visible_summary(&state, SummaryMode::Full)
                .as_str()
                .contains("Studio")
        );
        assert_eq!(
            visible_summary(&state, SummaryMode::Full).as_str(),
            "#[fg=#EBCB8B]NET#[default] #[fg=colour39]↓1.5MiB#[default] #[fg=colour214]↑2.0KiB#[default] █"
        );
        assert!(
            rendered
                .details
                .render_plain()
                .contains("Hostname      moria #[fg=colour196]")
        );
        assert_eq!(
            wire["network_details"],
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
        assert!(!wire["network_details"].ends_with('\n'));
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
        assert_eq!(HISTORY_SAMPLES, 20);
    }

    #[tokio::test]
    async fn identical_rendered_status_is_suppressed() {
        let mut harness = Harness::new("sysinfo");
        let ctx = harness.context();
        let network = Network::default();
        *network.state() = NetworkState {
            default_interface: Some("en0".to_string()),
            ..NetworkState::default()
        };

        network.emit_status_if_changed(&ctx);
        network.emit_status_if_changed(&ctx);
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["network_label"], "—");
        assert!(frames[0]["network_summary"].starts_with("#[popup=inline:"));
        assert!(frames[0]["network_details"].starts_with("#[fg=#EBCB8B]Network#[default]\n"));
        for raw in [
            "network_down_bps",
            "network_up_bps",
            "network_down_history",
            "network_up_history",
            "network_address",
        ] {
            assert_eq!(frames[0][raw], "", "unknown {raw} clears its segment");
        }

        network.state().rates = Some(TransferRates {
            received: 600_000.0,
            sent: 600_000.0,
        });
        network.emit_status_if_changed(&ctx);
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["network_label"], "1.2M");
        assert_eq!(frames[0]["network_down_bps"], "600000");
        assert_eq!(frames[0]["network_up_bps"], "600000");
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
            "—"
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
            "1.2M"
        );
    }

    // -- Scenarios over the SDK harness with a scripted host ----------------

    fn polls(frames: &[Value]) -> Vec<Value> {
        frames
            .iter()
            .filter(|frame| frame["method"] == "poll")
            .map(|frame| frame["params"]["registrations"].clone())
            .collect()
    }

    fn segments(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    /// The one-second traffic sample runs only while a surface shows a
    /// segment it feeds; discovery keeps the address catalog regardless.
    #[tokio::test]
    async fn traffic_is_sampled_only_while_a_traffic_segment_is_observed() {
        let mut harness = Harness::new("sysinfo");
        let ctx = harness.context();
        let network = Network::default();
        network.state().default_interface = Some("lo0".to_string());

        // `address` follows discovery alone: no traffic cadence.
        assert!(
            network
                .observe_traffic(&ctx, &segments(&["address"]))
                .is_none()
        );
        assert!(polls(&harness.drain()).is_empty());

        // Showing the label arms the cadence and samples at once.
        let sample = network
            .observe_traffic(&ctx, &segments(&["address", "label"]))
            .expect("sample");
        sample.await.unwrap();
        assert_eq!(
            polls(&harness.drain()),
            [json!({ "i0": { "every": 1.0, "priority": "high" } })]
        );
        assert!(
            network.state().previous.is_some(),
            "the first sample seeds the rate"
        );
        assert!(
            network
                .observe_traffic(&ctx, &segments(&["label", "summary"]))
                .is_none()
        );
        assert!(polls(&harness.drain()).is_empty(), "still armed");

        // Nothing traffic-fed observed: the cadence is cancelled and the
        // rates are cleared rather than left to go stale.
        network.state().rates = Some(TransferRates {
            received: 600_000.0,
            sent: 600_000.0,
        });
        assert!(
            network
                .observe_traffic(&ctx, &segments(&["address"]))
                .is_none()
        );
        let frames = harness.drain();
        assert_eq!(polls(&frames), [json!({})]);
        let status = frames
            .iter()
            .rfind(|frame| frame["method"] == "status")
            .expect("cleared status");
        assert_eq!(status["params"]["segments"]["network_down_bps"], "");
        assert!(network.state().rates.is_none() && network.state().previous.is_none());

        // A tick that raced the change does not sample.
        network.refresh_pass(&ctx, TRAFFIC_TICK).await;
        assert!(network.state().previous.is_none());
    }

    /// Discovery follows `core:network.changed`: startup registers no
    /// cadence at all.
    #[tokio::test]
    async fn startup_registers_no_cadence() {
        let mut harness = Harness::new("sysinfo");
        let ctx = harness.context();
        let network = Network::default();
        let started = network.clone();
        let startup = tokio::spawn(async move { started.start(&ctx).await });
        let (id, _, _) = harness.next_host_request().await.expect("wifi read");
        assert!(harness.reply_host(id, json!({ "ok": true, "present": false })));
        startup.await.unwrap();
        assert!(polls(&harness.drain()).is_empty());
    }

    /// A network change re-runs discovery — interface, addresses and a
    /// passive SSID read — whether or not traffic is observed.
    #[tokio::test]
    async fn a_network_change_rediscovers_the_network() {
        let mut harness = Harness::new("sysinfo");
        let network = Network::default();
        network.network_changed(&harness.context());
        let (id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": false }))
        );
        assert!(harness.reply_host(
            id,
            json!({ "ok": true, "present": true, "ssid": "Atelier" })
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while network.state().wifi_ssid.as_deref() != Some("Atelier") {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("rediscovered");
        assert!(polls(&harness.drain()).is_empty(), "no cadence either");
    }

    #[tokio::test]
    async fn startup_reads_wifi_passively_and_the_ssid_reaches_details_and_commands() {
        let mut harness = Harness::new("sysinfo");
        let ctx = harness.context();
        let network = Network::default();
        let started = network.clone();
        let startup = tokio::spawn(async move { started.start(&ctx).await });

        let (id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(method, "host.wifi_info");
        assert_eq!(params, json!({ "request_authorization": false }));
        assert!(harness.reply_host(
            id,
            json!({ "ok": true, "present": true, "ssid": "Atelier" })
        ));
        startup.await.unwrap();

        let status = harness.drain_status();
        let details = &status.last().expect("initial status")["network_details"];
        assert!(
            details.contains("Wi-Fi") && details.contains("Atelier"),
            "{details}"
        );

        let show = network.show();
        assert!(show.is_ok());
        let message = show.toast_message().expect("toast").to_string();
        assert!(message.contains("Network"), "{message}");

        // An explicit refresh asks for authorization and reflects the new SSID.
        let ctx = harness.context();
        let refreshed = network.clone();
        let refresh = tokio::spawn(async move { refreshed.refresh(&ctx).await });
        let (id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": true }))
        );
        assert!(harness.reply_host(id, json!({ "ok": true, "present": true, "ssid": "Office" })));
        refresh.await.unwrap();
        let shown = network.show();
        assert!(shown.is_ok());
        let message = shown.toast_message().expect("toast").to_string();
        assert!(message.contains("Wi-Fi         Office"), "{message}");
    }

    #[tokio::test]
    async fn explicit_refresh_requests_authorization_while_startup_holds_the_gate() {
        let mut harness = Harness::new("sysinfo");
        let ctx = harness.context();
        let network = Network::default();
        let started = network.clone();
        let startup = tokio::spawn(async move { started.start(&ctx).await });
        let (startup_id, method, params) = harness.next_host_request().await.expect("wifi read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": false }))
        );

        // The startup refresh is still awaiting its Wi-Fi reply, so it owns
        // the gate; the user's refresh must not queue behind it.
        let ctx = harness.context();
        let refreshed = network.clone();
        let refresh = tokio::spawn(async move { refreshed.refresh(&ctx).await });
        let (id, method, params) = harness
            .next_host_request()
            .await
            .expect("authorization read");
        assert_eq!(
            (method.as_str(), params),
            ("host.wifi_info", json!({ "request_authorization": true }))
        );
        assert!(harness.reply_host(id, json!({ "ok": true, "present": false })));
        // Returning at all is the contract: the user's refresh completed
        // while the startup refresh still owned the gate.
        refresh
            .await
            .expect("refresh must not queue behind the startup gate");

        assert!(harness.reply_host(startup_id, json!({ "ok": true, "present": false })));
        startup.await.unwrap();
        let status = harness.drain_status();
        assert!(!status.last().expect("initial status")["network_summary"].is_empty());
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
        assert_eq!(wire["network_down_bps"], "1572864");
        assert_eq!(wire["network_up_bps"], "2048");
        assert_eq!(wire["network_down_history"], "0 1536 1025");
        assert_eq!(wire["network_up_history"], "10 20 2048");
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
