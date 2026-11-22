//! Per-interface traffic counters: the byte columns of `netstat -b`, read
//! through the `NET_RT_IFLIST2` sysctl netstat itself walks.

use std::mem;
use std::ptr;

use super::SysError;
use super::sysctl::sysctl_buffer;

/// Lifetime byte counters of one network interface (64-bit, as `netstat -b`
/// reports them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InterfaceCounters {
    pub(crate) name: String,
    pub(crate) received_bytes: u64,
    pub(crate) sent_bytes: u64,
}

/// Byte counters for every interface, from the `NET_RT_IFLIST2` routing
/// sysctl (one `RTM_IFINFO2` record per interface, each followed by its
/// link-level `sockaddr_dl` carrying the name).
pub(crate) fn interface_counters() -> Result<Vec<InterfaceCounters>, SysError> {
    let mut mib = [libc::CTL_NET, libc::PF_ROUTE, 0, 0, libc::NET_RT_IFLIST2, 0];
    Ok(parse_iflist2(&sysctl_buffer(&mut mib, "NET_RT_IFLIST2")?))
}

/// Walks the routing-socket record stream. Pure over the bytes so it is
/// testable against a captured dump.
fn parse_iflist2(buffer: &[u8]) -> Vec<InterfaceCounters> {
    const SDL_NLEN_OFFSET: usize = 5;
    const SDL_DATA_OFFSET: usize = 8;
    let header_len = mem::size_of::<libc::if_msghdr2>();
    let mut out = Vec::new();
    let mut offset = 0;
    while offset + mem::size_of::<libc::if_msghdr>() <= buffer.len() {
        // SAFETY: bounds checked above; `read_unaligned` tolerates the packed stream.
        let header: libc::if_msghdr =
            unsafe { ptr::read_unaligned(buffer.as_ptr().add(offset).cast::<libc::if_msghdr>()) };
        let message_len = header.ifm_msglen as usize;
        if message_len == 0 || offset + message_len > buffer.len() {
            break;
        }
        if i32::from(header.ifm_type) == libc::RTM_IFINFO2 && message_len >= header_len {
            // SAFETY: `message_len >= header_len` keeps the read inside the record.
            let message: libc::if_msghdr2 = unsafe {
                ptr::read_unaligned(buffer.as_ptr().add(offset).cast::<libc::if_msghdr2>())
            };
            let sdl = offset + header_len;
            let end = offset + message_len;
            if sdl + SDL_DATA_OFFSET <= end {
                let name_len = buffer[sdl + SDL_NLEN_OFFSET] as usize;
                let name_start = sdl + SDL_DATA_OFFSET;
                if name_len > 0 && name_start + name_len <= end {
                    out.push(InterfaceCounters {
                        name: String::from_utf8_lossy(&buffer[name_start..name_start + name_len])
                            .into_owned(),
                        received_bytes: message.ifm_data.ifi_ibytes,
                        sent_bytes: message.ifm_data.ifi_obytes,
                    });
                }
            }
        }
        offset += message_len;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interface_counters_include_loopback() {
        let counters = interface_counters().expect("interfaces");
        assert!(
            counters.iter().any(|entry| entry.name == "lo0"),
            "{counters:?}"
        );
    }

    #[test]
    fn iflist2_parser_stops_on_truncated_records() {
        assert!(parse_iflist2(&[]).is_empty());
        assert!(parse_iflist2(&[0u8; 4]).is_empty());
    }
}
