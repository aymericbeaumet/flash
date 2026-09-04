use std::collections::VecDeque;
use std::net::IpAddr;
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, Candidate, CommandRequest, Context,
    PerformResponse, RefreshGate,
};
use nix::ifaddrs::getifaddrs;
use nix::net::if_::InterfaceFlags;

const SOURCE_ADDRESSES: &str = "network.addresses";
const TRAFFIC_POLL: Duration = Duration::from_secs(2);
const DISCOVERY_POLL: Duration = Duration::from_secs(30);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const MIN_RATE_INTERVAL: Duration = Duration::from_millis(500);
const MAX_RATE_INTERVAL: Duration = Duration::from_secs(10);
const HISTORY_LEN: usize = 16;
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
    summary: String,
    details: String,
}

#[derive(Default)]
struct NetworkState {
    default_interface: Option<String>,
    previous: Option<TimedCounters>,
    rates: Option<TransferRates>,
    received_history: VecDeque<f64>,
    sent_history: VecDeque<f64>,
    catalog: Option<CatalogSnapshot>,
    last_discovery_attempt: Option<Instant>,
    last_traffic_success: Option<Instant>,
    last_status: Option<RenderedStatus>,
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
                push_history(&mut self.received_history, rates.received);
                push_history(&mut self.sent_history, rates.sent);
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

struct Network;

flash_plugin::plugin!(Network);

impl FlashPlugin for Network {
    async fn on_start(&self, ctx: Context) {
        refresh_network(&ctx, true).await;
        drop(ctx.interval(TRAFFIC_POLL, |ctx| async move {
            refresh_network(&ctx, false).await;
        }));
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => current_response(),
            "refresh" => {
                try_refresh_network(&ctx, true).await;
                current_response()
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_network(ctx: &Context, force_discovery: bool) {
    REFRESH_GATE
        .run(ctx, move |ctx, _applications| async move {
            refresh_network_locked(&ctx, force_discovery).await;
        })
        .await;
}

async fn try_refresh_network(ctx: &Context, force_discovery: bool) {
    let _ = REFRESH_GATE
        .try_run(ctx, move |ctx, _applications| async move {
            refresh_network_locked(&ctx, force_discovery).await;
        })
        .await;
}

async fn refresh_network_locked(ctx: &Context, force_discovery: bool) {
    let discovery_due = {
        let state = state();
        force_discovery
            || state
                .last_discovery_attempt
                .is_none_or(|last| last.elapsed() >= DISCOVERY_POLL)
    };

    let discovery = if discovery_due {
        let (interface, catalog) = tokio::join!(
            collect_default_interface(ctx),
            tokio::task::spawn_blocking(collect_catalog)
        );
        Some((interface, catalog))
    } else {
        None
    };

    let mut rows_to_publish = None;
    let mut discovery_failed = false;
    let (interface, log_discovery_failure) = {
        let mut state = state();
        if let Some((interface, catalog)) = discovery {
            state.last_discovery_attempt = Some(Instant::now());
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
        let argv = [
            NETSTAT.to_string(),
            "-bI".to_string(),
            interface.clone(),
            "-n".to_string(),
        ];
        let output = run_command(ctx, &argv, COMMAND_TIMEOUT).await;
        if output.ok {
            if let Some(counters) = parse_netstat_counters(&output.stdout, &interface) {
                state().apply_sample(TimedCounters {
                    interface,
                    counters,
                    sampled_at: Instant::now(),
                });
                traffic_failed = Some(false);
            } else {
                traffic_failed = Some(true);
            }
        } else {
            traffic_failed = Some(true);
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
        ctx.log("warn", "[network] netstat collection failed");
    }

    emit_status_if_changed(ctx);
}

fn current_response() -> PerformResponse {
    match render_details(&state()) {
        Some(details) => PerformResponse::ok().message(details),
        None => PerformResponse::fail("network metrics are not available yet"),
    }
}

fn emit_status_if_changed(ctx: &Context) {
    let rendered = {
        let mut state = state();
        let Some(rendered) = render_status(&state) else {
            return;
        };
        let Some(rendered) = status_update(&mut state.last_status, rendered) else {
            return;
        };
        rendered
    };
    ctx.status([("summary", rendered.summary), ("details", rendered.details)]);
}

fn status_update(
    last: &mut Option<RenderedStatus>,
    next: RenderedStatus,
) -> Option<RenderedStatus> {
    if last.as_ref() == Some(&next) {
        return None;
    }
    *last = Some(next.clone());
    Some(next)
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

fn parse_netstat_counters(output: &str, interface: &str) -> Option<NetCounters> {
    let mut received_index = None;
    let mut sent_index = None;
    let mut fallback = None;

    for line in output.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first() == Some(&"Name") {
            received_index = fields.iter().position(|field| *field == "Ibytes");
            sent_index = fields.iter().position(|field| *field == "Obytes");
            continue;
        }
        if fields.first() != Some(&interface) {
            continue;
        }
        let (Some(received_index), Some(sent_index)) = (received_index, sent_index) else {
            continue;
        };
        let counters = NetCounters {
            received: fields.get(received_index)?.parse().ok()?,
            sent: fields.get(sent_index)?.parse().ok()?,
        };
        if fields
            .get(2)
            .is_some_and(|network| network.starts_with("<Link#"))
        {
            return Some(counters);
        }
        fallback.get_or_insert(counters);
    }
    fallback
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

fn push_history(history: &mut VecDeque<f64>, value: f64) {
    if history.len() == HISTORY_LEN {
        history.pop_front();
    }
    history.push_back(value);
}

fn render_status(state: &NetworkState) -> Option<RenderedStatus> {
    let plain_details = render_details(state)?;
    let details = escape_status_text(&plain_details);
    let (received, sent) = state
        .rates
        .map(|rates| (compact_rate(rates.received), compact_rate(rates.sent)))
        .unwrap_or_else(|| ("—".to_string(), "—".to_string()));
    let combined: Vec<f64> = state
        .received_history
        .iter()
        .zip(&state.sent_history)
        .map(|(received, sent)| received.max(*sent))
        .collect();
    let chart = sparkline(&combined);
    let chart_suffix = if chart.is_empty() {
        String::new()
    } else {
        format!(" {chart}")
    };
    let visible = format!(
        "#[fg=colour45,bold]NET#[default] #[fg=colour39]↓{received}#[default] #[fg=colour214]↑{sent}#[default]{chart_suffix}"
    );
    Some(RenderedStatus {
        summary: inline_status_popup(&visible, &details),
        details,
    })
}

fn render_details(state: &NetworkState) -> Option<String> {
    if state.default_interface.is_none() && state.catalog.is_none() {
        return None;
    }
    let mut lines = vec!["Network".to_string()];
    lines.push(format!(
        "Interface: {}",
        state.default_interface.as_deref().unwrap_or("unavailable")
    ));
    if let Some(rates) = state.rates {
        lines.push(format!("Download: {}", format_rate(rates.received)));
        lines.push(format!("Upload: {}", format_rate(rates.sent)));
    } else {
        lines.push("Traffic: sampling…".to_string());
    }
    let received_history: Vec<f64> = state.received_history.iter().copied().collect();
    let sent_history: Vec<f64> = state.sent_history.iter().copied().collect();
    let received_chart = sparkline(&received_history);
    let sent_chart = sparkline(&sent_history);
    if !received_chart.is_empty() {
        lines.push(format!("Download history: {received_chart}"));
    }
    if !sent_chart.is_empty() {
        lines.push(format!("Upload history: {sent_chart}"));
    }
    if let Some(catalog) = &state.catalog {
        if let Some(hostname) = &catalog.hostname {
            lines.push(format!("Hostname: {hostname}"));
        }
        for address in catalog.addresses.iter().take(8) {
            lines.push(format!("{}: {}", address.interface_name, address.ip));
        }
        if catalog.addresses.len() > 8 {
            lines.push(format!("… and {} more", catalog.addresses.len() - 8));
        }
    }
    Some(lines.join("\n"))
}

fn compact_rate(bytes_per_second: f64) -> String {
    scaled_bytes(bytes_per_second, false)
}

fn format_rate(bytes_per_second: f64) -> String {
    format!("{}/s", scaled_bytes(bytes_per_second, true))
}

fn scaled_bytes(bytes: f64, spaced: bool) -> String {
    let separator = if spaced { " " } else { "" };
    let units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes.max(0.0);
    let mut unit = 0;
    while value >= 1024.0 && unit < units.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    let number = if unit == 0 || value >= 10.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    };
    format!("{number}{separator}{}", units[unit])
}

fn sparkline(values: &[f64]) -> String {
    const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let maximum = values.iter().copied().fold(0.0_f64, f64::max);
    values
        .iter()
        .map(|value| {
            if maximum <= f64::EPSILON {
                BARS[0]
            } else {
                let index = ((*value / maximum) * (BARS.len() - 1) as f64).floor() as usize;
                BARS[index.min(BARS.len() - 1)]
            }
        })
        .collect()
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
    use std::net::{Ipv4Addr, Ipv6Addr};

    use flash_plugin::CandidateEffect;

    use super::*;

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
    fn parses_link_row_without_summing_duplicate_address_rows() {
        let output = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\n\
en0 1500 <Link#14> aa:bb 10 0 12000 8 0 3400 0\n\
en0 1500 10.0/16 10.0.0.2 10 - 12000 8 - 3400 -\n";
        assert_eq!(
            parse_netstat_counters(output, "en0"),
            Some(NetCounters {
                received: 12_000,
                sent: 3_400
            })
        );
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
            received_history: VecDeque::from([10.0]),
            sent_history: VecDeque::from([20.0]),
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
        assert!(render_details(&state)
            .unwrap()
            .contains("Traffic: sampling…"));
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
    fn history_is_bounded_and_sparkline_scales() {
        let mut history = VecDeque::new();
        for value in 0..20 {
            push_history(&mut history, f64::from(value));
        }
        assert_eq!(history.len(), HISTORY_LEN);
        assert_eq!(history.front(), Some(&4.0));
        assert_eq!(sparkline(&[0.0, 1.0, 2.0, 3.0]), "▁▃▅█");
    }

    #[test]
    fn renders_styled_summary_with_inline_popup_and_escaped_details() {
        let mut state = NetworkState {
            default_interface: Some("en#0".to_string()),
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
        push_history(&mut state.received_history, 1.0);
        push_history(&mut state.sent_history, 0.5);
        let rendered = render_status(&state).unwrap();
        assert!(rendered.summary.starts_with("#[popup=inline:"));
        assert!(rendered.summary.contains("NET#[default]"));
        assert!(rendered.summary.contains("↓1.5MiB"));
        assert!(render_details(&state)
            .unwrap()
            .contains("Hostname: moria #[fg=colour196]"));
        assert!(rendered.details.contains("Interface: en##0"));
        assert!(rendered
            .details
            .contains("Hostname: moria ##[fg=colour196]"));
    }

    #[test]
    fn identical_rendered_status_is_suppressed() {
        let rendered = RenderedStatus {
            summary: "summary".to_string(),
            details: "details".to_string(),
        };
        let mut last = None;
        assert_eq!(
            status_update(&mut last, rendered.clone()),
            Some(rendered.clone())
        );
        assert_eq!(status_update(&mut last, rendered), None);
    }

    #[test]
    fn collection_failure_logs_once_until_a_success_rearms_it() {
        let mut logged = false;
        assert!(first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, false));
        assert!(first_failure(&mut logged, true));
    }
}
