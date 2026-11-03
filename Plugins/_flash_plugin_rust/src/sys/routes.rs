//! Default routes from the kernel routing table: the `default` rows of
//! `netstat -rn -f inet|inet6`, read through the `NET_RT_DUMP2` sysctl that
//! netstat itself walks.

use std::ffi::CStr;
use std::mem;
use std::ptr;

use super::{SysError, sysctl_buffer};

/// `RTAX_*` slots of the sockaddrs that follow a routing message.
const RTAX_DST: usize = 0;
const RTAX_NETMASK: usize = 2;
const RTAX_MAX: usize = libc::RTAX_MAX as usize;

/// The routing table to read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteFamily {
    Ipv4,
    Ipv6,
}

impl RouteFamily {
    fn address_family(self) -> libc::c_int {
        match self {
            Self::Ipv4 => libc::AF_INET,
            Self::Ipv6 => libc::AF_INET6,
        }
    }
}

/// One default route's outgoing interface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefaultRoute {
    /// The interface's kernel index (`rtm_index`).
    pub interface_index: u16,
    /// The interface name (`en0`, `netstat`'s `Netif`); `None` when the index
    /// no longer names an interface.
    pub interface: Option<String>,
}

/// Every default route of `family`, in the order `netstat -rn` lists them:
/// the primary route first, then the interface-scoped ones.
pub fn default_routes(family: RouteFamily) -> Result<Vec<DefaultRoute>, SysError> {
    let mut mib = [
        libc::CTL_NET,
        libc::PF_ROUTE,
        0,
        family.address_family(),
        libc::NET_RT_DUMP2,
        0,
    ];
    let table = sysctl_buffer(&mut mib, "NET_RT_DUMP2")?;
    Ok(default_route_indexes(&table, family)
        .into_iter()
        .map(|interface_index| DefaultRoute {
            interface_index,
            interface: interface_name(interface_index),
        })
        .collect())
}

fn interface_name(index: u16) -> Option<String> {
    let mut name = [0 as libc::c_char; libc::IF_NAMESIZE];
    // SAFETY: `name` is the IF_NAMESIZE buffer the call fills, NUL-terminated.
    let filled = unsafe { libc::if_indextoname(u32::from(index), name.as_mut_ptr()) };
    if filled.is_null() {
        return None;
    }
    // SAFETY: filled and NUL-terminated by the call above.
    let name = unsafe { CStr::from_ptr(name.as_ptr()) }.to_str().ok()?;
    (!name.is_empty()).then(|| name.to_string())
}

/// `rtm_index` of every row `netstat -rn` prints as `default` for `family`,
/// in table order. Pure over the sysctl bytes so it is testable against a
/// synthetic dump.
fn default_route_indexes(table: &[u8], family: RouteFamily) -> Vec<u16> {
    let header_len = mem::size_of::<libc::rt_msghdr2>();
    let mut indexes = Vec::new();
    let mut offset = 0;
    while offset + header_len <= table.len() {
        // SAFETY: bounds checked above; `read_unaligned` tolerates the packed stream.
        let header: libc::rt_msghdr2 =
            unsafe { ptr::read_unaligned(table.as_ptr().add(offset).cast::<libc::rt_msghdr2>()) };
        let message_len = usize::from(header.rtm_msglen);
        if message_len < header_len || offset + message_len > table.len() {
            break;
        }
        // netstat hides protocol-cloned routes unless `-a`.
        let cloned = header.rtm_flags & libc::RTF_WASCLONED != 0
            && header.rtm_parentflags & libc::RTF_PRCLONING != 0;
        let addresses = route_addresses(
            &table[offset + header_len..offset + message_len],
            header.rtm_addrs,
        );
        if !cloned && is_default(&addresses, header.rtm_flags, family) {
            indexes.push(header.rtm_index);
        }
        offset += message_len;
    }
    indexes
}

/// The sockaddrs after a routing message header, by `RTAX_*` slot (netstat's
/// `get_rtaddrs`): each present one spans `sa_len` bytes, padded to four.
fn route_addresses(region: &[u8], present: libc::c_int) -> [Option<&[u8]>; RTAX_MAX] {
    let mut addresses = [None; RTAX_MAX];
    let mut position = 0;
    for (slot, address) in addresses.iter_mut().enumerate() {
        if present & (1 << slot) == 0 {
            continue;
        }
        let Some(&len) = region.get(position) else {
            break;
        };
        let len = usize::from(len);
        *address = Some(&region[position..(position + len).min(region.len())]);
        position += if len == 0 { 4 } else { 1 + ((len - 1) | 3) };
    }
    addresses
}

/// A sockaddr copied into a zeroed buffer, as netstat `bcopy`s it: bytes
/// past `sa_len` (or an absent one entirely) read as zero.
fn sockaddr<const N: usize>(address: Option<&[u8]>) -> [u8; N] {
    let mut copy = [0u8; N];
    if let Some(bytes) = address {
        let len = bytes.len().min(N);
        copy[..len].copy_from_slice(&bytes[..len]);
    }
    copy
}

/// netstat's `default` test: the unspecified destination under an all-zero
/// (or zero-length) mask; IPv6 host routes never qualify.
fn is_default(
    addresses: &[Option<&[u8]>; RTAX_MAX],
    flags: libc::c_int,
    family: RouteFamily,
) -> bool {
    let Some(destination) = addresses[RTAX_DST] else {
        return false;
    };
    match family {
        RouteFamily::Ipv4 => {
            // sockaddr_in: len, family, port[2], addr[4], zero[8].
            let destination: [u8; 16] = sockaddr(Some(destination));
            let mask: [u8; 16] = sockaddr(addresses[RTAX_NETMASK]);
            i32::from(destination[1]) == libc::AF_INET
                && destination[4..8] == [0; 4]
                && (mask[0] == 0 || mask[4..8] == [0; 4])
        }
        RouteFamily::Ipv6 => {
            // sockaddr_in6: len, family, port[2], flowinfo[4], addr[16], scope[4].
            let destination: [u8; 28] = sockaddr(Some(destination));
            let mask: [u8; 28] = sockaddr(addresses[RTAX_NETMASK]);
            let prefix: u32 = if mask[0] == 0 {
                0
            } else {
                mask[8..24].iter().copied().map(prefix_bits).sum()
            };
            i32::from(destination[1]) == libc::AF_INET6
                && flags & libc::RTF_HOST == 0
                && prefix == 0
                && destination[8..24] == [0; 16]
        }
    }
}

/// Leading one bits of a contiguous mask byte; netstat counts any other
/// byte as zero.
fn prefix_bits(byte: u8) -> u32 {
    match byte {
        0xff => 8,
        0xfe => 7,
        0xfc => 6,
        0xf8 => 5,
        0xf0 => 4,
        0xe0 => 3,
        0xc0 => 2,
        0x80 => 1,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RTF_UP: libc::c_int = 0x1;
    const RTF_GATEWAY: libc::c_int = 0x2;
    const RTF_STATIC: libc::c_int = 0x800;
    const RTF_IFSCOPE: libc::c_int = 0x0100_0000;

    fn ipv4(address: [u8; 4]) -> Vec<u8> {
        let mut sockaddr = vec![16, libc::AF_INET as u8, 0, 0];
        sockaddr.extend_from_slice(&address);
        sockaddr.extend_from_slice(&[0; 8]);
        sockaddr
    }

    /// A kernel-style netmask: `sa_len` covers only the significant bytes.
    fn ipv4_mask(prefix: [u8; 4]) -> Vec<u8> {
        let significant = prefix
            .iter()
            .rposition(|byte| *byte != 0)
            .map_or(0, |at| at + 1);
        if significant == 0 {
            return vec![0];
        }
        let mut sockaddr = vec![(4 + significant) as u8, 0xff, 0, 0];
        sockaddr.extend_from_slice(&prefix[..significant]);
        sockaddr
    }

    fn ipv6(address: [u8; 16]) -> Vec<u8> {
        let mut sockaddr = vec![28, libc::AF_INET6 as u8, 0, 0, 0, 0, 0, 0];
        sockaddr.extend_from_slice(&address);
        sockaddr.extend_from_slice(&[0; 4]);
        sockaddr
    }

    fn ipv6_mask(prefix: usize) -> Vec<u8> {
        let mut address = [0u8; 16];
        for bit in 0..prefix {
            address[bit / 8] |= 0x80 >> (bit % 8);
        }
        ipv6(address)
    }

    fn link(index: u8) -> Vec<u8> {
        vec![
            20,
            libc::AF_LINK as u8,
            index,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ]
    }

    /// One `rt_msghdr2` record with its sockaddrs, each padded to four bytes.
    fn record(
        index: u16,
        flags: libc::c_int,
        parent_flags: libc::c_int,
        addresses: &[(usize, Vec<u8>)],
    ) -> Vec<u8> {
        let mut body = Vec::new();
        let mut present = 0;
        for (slot, sockaddr) in addresses {
            present |= 1 << slot;
            body.extend_from_slice(sockaddr);
            let padded = if sockaddr[0] == 0 {
                4
            } else {
                1 + ((usize::from(sockaddr[0]) - 1) | 3)
            };
            body.resize(body.len() + padded - sockaddr.len(), 0);
        }
        // SAFETY: rt_msghdr2 is a plain C struct; zeroed is a valid value.
        let mut header: libc::rt_msghdr2 = unsafe { mem::zeroed() };
        let header_len = mem::size_of::<libc::rt_msghdr2>();
        header.rtm_msglen = (header_len + body.len()) as u16;
        header.rtm_version = 5;
        header.rtm_type = 0x14;
        header.rtm_index = index;
        header.rtm_flags = flags;
        header.rtm_parentflags = parent_flags;
        header.rtm_addrs = present;
        // SAFETY: viewing the plain C struct's bytes.
        let mut bytes = unsafe {
            std::slice::from_raw_parts(
                (&header as *const libc::rt_msghdr2).cast::<u8>(),
                header_len,
            )
        }
        .to_vec();
        bytes.extend_from_slice(&body);
        bytes
    }

    const GATEWAY: usize = 1;

    #[test]
    fn ipv4_defaults_come_in_table_order_and_other_routes_are_skipped() {
        let gateway = ipv4([192, 168, 1, 1]);
        let table = [
            record(
                4,
                RTF_UP | RTF_GATEWAY | RTF_STATIC,
                0,
                &[
                    (RTAX_DST, ipv4([0; 4])),
                    (GATEWAY, gateway.clone()),
                    (RTAX_NETMASK, ipv4_mask([0; 4])),
                ],
            ),
            record(
                4,
                RTF_UP,
                0,
                &[
                    (RTAX_DST, ipv4([192, 168, 1, 0])),
                    (GATEWAY, link(4)),
                    (RTAX_NETMASK, ipv4_mask([255, 255, 255, 0])),
                ],
            ),
            // A scoped default for another interface, without a netmask.
            record(
                22,
                RTF_UP | RTF_GATEWAY | RTF_IFSCOPE,
                0,
                &[(RTAX_DST, ipv4([0; 4])), (GATEWAY, link(22))],
            ),
            // Unspecified destination under a non-zero mask is not default.
            record(
                9,
                RTF_UP,
                0,
                &[
                    (RTAX_DST, ipv4([0; 4])),
                    (GATEWAY, gateway.clone()),
                    (RTAX_NETMASK, ipv4_mask([255, 0, 0, 0])),
                ],
            ),
            // Protocol-cloned routes are hidden like `netstat` without `-a`.
            record(
                7,
                RTF_UP | libc::RTF_WASCLONED,
                libc::RTF_PRCLONING,
                &[(RTAX_DST, ipv4([0; 4])), (GATEWAY, gateway)],
            ),
            // No destination at all.
            record(8, RTF_UP, 0, &[(GATEWAY, link(8))]),
        ]
        .concat();
        assert_eq!(default_route_indexes(&table, RouteFamily::Ipv4), [4, 22]);
        assert!(default_route_indexes(&table, RouteFamily::Ipv6).is_empty());
    }

    #[test]
    fn ipv6_default_is_the_unspecified_network_with_a_zero_prefix() {
        let mut loopback = [0u8; 16];
        loopback[15] = 1;
        let mut link_local = [0u8; 16];
        link_local[..2].copy_from_slice(&[0xfe, 0x80]);
        let table = [
            record(
                1,
                RTF_UP | libc::RTF_HOST,
                0,
                &[(RTAX_DST, ipv6(loopback)), (GATEWAY, ipv6(loopback))],
            ),
            record(
                5,
                RTF_UP,
                0,
                &[
                    (RTAX_DST, ipv6(link_local)),
                    (GATEWAY, link(5)),
                    (RTAX_NETMASK, ipv6_mask(64)),
                ],
            ),
            record(
                14,
                RTF_UP | RTF_GATEWAY,
                0,
                &[
                    (RTAX_DST, ipv6([0; 16])),
                    (GATEWAY, ipv6(link_local)),
                    (RTAX_NETMASK, vec![0]),
                ],
            ),
            record(
                15,
                RTF_UP | RTF_GATEWAY,
                0,
                &[
                    (RTAX_DST, ipv6([0; 16])),
                    (GATEWAY, link(15)),
                    (RTAX_NETMASK, ipv6_mask(0)),
                ],
            ),
            // `::` as a host route, and `::/8`, are not default.
            record(
                16,
                RTF_UP | libc::RTF_HOST,
                0,
                &[(RTAX_DST, ipv6([0; 16])), (GATEWAY, link(16))],
            ),
            record(
                17,
                RTF_UP,
                0,
                &[
                    (RTAX_DST, ipv6([0; 16])),
                    (GATEWAY, link(17)),
                    (RTAX_NETMASK, ipv6_mask(8)),
                ],
            ),
        ]
        .concat();
        assert_eq!(default_route_indexes(&table, RouteFamily::Ipv6), [14, 15]);
    }

    #[test]
    fn truncated_or_malformed_dumps_stop_without_reading_past_the_end() {
        let full = record(
            4,
            RTF_UP,
            0,
            &[(RTAX_DST, ipv4([0; 4])), (RTAX_NETMASK, ipv4_mask([0; 4]))],
        );
        assert!(default_route_indexes(&[], RouteFamily::Ipv4).is_empty());
        assert!(default_route_indexes(&full[..full.len() - 1], RouteFamily::Ipv4).is_empty());
        let mut zero_length = full.clone();
        zero_length[0] = 0;
        zero_length[1] = 0;
        assert!(default_route_indexes(&zero_length, RouteFamily::Ipv4).is_empty());
        // Sockaddrs claiming more bytes than the record holds are clipped.
        let addresses = route_addresses(&[16, libc::AF_INET as u8, 0], 1);
        assert_eq!(addresses[RTAX_DST], Some(&[16, libc::AF_INET as u8, 0][..]));
        assert!(route_addresses(&[], 0b111).iter().all(Option::is_none));
    }

    /// Tolerant of the host's connectivity: offline, there is no default.
    #[test]
    fn default_routes_name_interfaces_the_kernel_counts() {
        let interfaces: Vec<String> = crate::sys::interface_counters()
            .expect("interfaces")
            .into_iter()
            .map(|counters| counters.name)
            .collect();
        for family in [RouteFamily::Ipv4, RouteFamily::Ipv6] {
            for route in default_routes(family).expect("routing table") {
                let name = route
                    .interface
                    .expect("a live default route names its interface");
                assert!(interfaces.contains(&name), "{name} not in {interfaces:?}");
            }
        }
    }
}
