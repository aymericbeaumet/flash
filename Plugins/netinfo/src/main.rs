use std::net::IpAddr;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use flash_plugin::{run, Candidate, Context};
use nix::ifaddrs::getifaddrs;
use nix::net::if_::InterfaceFlags;

const SOURCE_ADDRESSES: &str = "netinfo.addresses";
const POLL_SECONDS: u64 = 30;
static LAST_PUBLISHED: LazyLock<Mutex<Option<CatalogSnapshot>>> =
    LazyLock::new(|| Mutex::new(None));

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

struct Netinfo;

flash_plugin::plugin!(Netinfo);

impl FlashPlugin for Netinfo {
    async fn on_start(&self, ctx: Context) {
        refresh_catalog(&ctx).await;
        drop(
            ctx.interval(Duration::from_secs(POLL_SECONDS), |ctx| async move {
                refresh_catalog(&ctx).await;
            }),
        );
    }
}

async fn refresh_catalog(ctx: &Context) {
    let snapshot = match tokio::task::spawn_blocking(collect_snapshot).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            ctx.log(
                "warn",
                &format!("[netinfo] collection task failed: {error}"),
            );
            return;
        }
    };

    if !replace_if_changed(&mut last_published(), &snapshot) {
        return;
    }

    let rows = snapshot.candidates();
    let count = rows.len();
    ctx.publish(rows);
    ctx.log_fields(
        "debug",
        "[netinfo] publish",
        std::collections::BTreeMap::from([
            (
                "outcome".to_string(),
                if count == 0 { "empty" } else { "ok" }.to_string(),
            ),
            ("rows".to_string(), count.to_string()),
        ]),
    );
}

fn last_published() -> std::sync::MutexGuard<'static, Option<CatalogSnapshot>> {
    LAST_PUBLISHED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn replace_if_changed(last: &mut Option<CatalogSnapshot>, next: &CatalogSnapshot) -> bool {
    if last.as_ref() == Some(next) {
        return false;
    }
    *last = Some(next.clone());
    true
}

fn collect_snapshot() -> CatalogSnapshot {
    let hostname = nix::unistd::gethostname()
        .ok()
        .and_then(|name| name.into_string().ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty());

    let mut addresses = Vec::new();
    if let Ok(interfaces) = getifaddrs() {
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
    }

    sort_addresses(&mut addresses);
    CatalogSnapshot {
        hostname,
        addresses,
    }
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
    run(Netinfo);
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
    fn link_local_filter_matches_go_plugin_behavior() {
        assert!(is_link_local(IpAddr::V4(Ipv4Addr::new(169, 254, 1, 2))));
        assert!(is_link_local(IpAddr::V6("fe80::1".parse().unwrap())));
        assert!(!is_link_local(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))));
        assert!(!is_link_local(IpAddr::V6(Ipv6Addr::LOCALHOST)));
    }

    #[test]
    fn hostname_precedes_copyable_interface_rows() {
        let snapshot = CatalogSnapshot {
            hostname: Some("moria".to_string()),
            addresses: vec![address("en0", "10.0.0.2".parse().unwrap())],
        };
        let rows = snapshot.candidates();
        assert_eq!(rows[0].title, "hostname moria");
        assert_eq!(rows[0].payload_str(), Some("moria"));
        assert_eq!(rows[1].title, "en0 10.0.0.2");
        assert_eq!(rows[1].meta("subtitle"), Some("IPv4 — en0"));
        assert_eq!(rows[1].payload_str(), Some("10.0.0.2"));
        match rows[1].effect.as_ref() {
            Some(CandidateEffect::CopyText { text }) => assert_eq!(text, "10.0.0.2"),
            other => panic!("unexpected effect: {other:?}"),
        }
    }

    #[test]
    fn change_gate_publishes_only_semantic_changes() {
        let mut last = None;
        let first = CatalogSnapshot {
            hostname: Some("moria".to_string()),
            addresses: Vec::new(),
        };
        assert!(replace_if_changed(&mut last, &first));
        assert!(!replace_if_changed(&mut last, &first));

        let empty = CatalogSnapshot::default();
        assert!(replace_if_changed(&mut last, &empty));
        assert!(!replace_if_changed(&mut last, &empty));
    }
}
