//! Native macOS system sampling for the status monitors.
//!
//! The monitor plugins used to shell out (`iostat`, `vm_stat`, `sysctl`,
//! `netstat`) once per second each — a fork, an exec, three pipes, and a wait
//! per sample. These readers use the kernel interfaces those tools read
//! themselves: `host_processor_info`, `host_statistics64`, `sysctlbyname`, and
//! the `NET_RT_IFLIST2` routing sysctl. Each call is a few microseconds and
//! never blocks on a child. As with `process.rs` and `runtime.rs`, the unsafe
//! FFI stays inside the SDK; plugins call the safe wrappers.

use std::ffi::CString;
use std::fmt;
use std::mem;
use std::ptr;

/// A failed kernel query, carrying the call and status for the log line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SysError(String);

impl fmt::Display for SysError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SysError {}

/// Cumulative scheduler ticks summed over every core.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CpuTicks {
    pub user: u64,
    pub system: u64,
    pub idle: u64,
    pub nice: u64,
}

/// Share of the ticks accumulated between two samples, in percent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CpuPercentages {
    /// User plus nice, matching `iostat`'s `us` column.
    pub user: f64,
    pub system: f64,
    pub idle: f64,
}

impl CpuTicks {
    pub fn total(&self) -> u64 {
        self.user + self.system + self.idle + self.nice
    }

    /// Percentages over the interval from `previous` to `self`; `None` when no
    /// tick elapsed or a counter went backwards (reboot-scale wrap).
    pub fn percentages_since(&self, previous: &CpuTicks) -> Option<CpuPercentages> {
        let user = self.user.checked_sub(previous.user)?;
        let nice = self.nice.checked_sub(previous.nice)?;
        let system = self.system.checked_sub(previous.system)?;
        let idle = self.idle.checked_sub(previous.idle)?;
        let total = user + nice + system + idle;
        if total == 0 {
            return None;
        }
        let percent = |value: u64| value as f64 / total as f64 * 100.0;
        Some(CpuPercentages {
            user: percent(user + nice),
            system: percent(system),
            idle: percent(idle),
        })
    }
}

/// Current cumulative CPU ticks across all cores (`host_processor_info`).
// libc deprecates `mach_host_self` / `mach_task_self` in favour of the `mach2`
// crate; one more dependency for two symbols is not worth it here.
#[allow(deprecated)]
pub fn cpu_ticks() -> Result<CpuTicks, SysError> {
    let mut cpu_count: libc::natural_t = 0;
    let mut info: libc::processor_info_array_t = ptr::null_mut();
    let mut info_count: libc::mach_msg_type_number_t = 0;
    // SAFETY: every out-pointer targets a live local; the kernel allocates
    // `info` in this task and it is released below.
    let status = unsafe {
        libc::host_processor_info(
            libc::mach_host_self(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut cpu_count,
            &mut info,
            &mut info_count,
        )
    };
    if status != libc::KERN_SUCCESS || info.is_null() {
        return Err(SysError(format!("host_processor_info failed with status {status}")));
    }
    let states = libc::CPU_STATE_MAX as usize;
    // SAFETY: the kernel filled `info_count` integers at `info`.
    let values = unsafe { std::slice::from_raw_parts(info.cast_const(), info_count as usize) };
    let mut ticks = CpuTicks::default();
    for cpu in 0..cpu_count as usize {
        let base = cpu * states;
        if base + states > values.len() {
            break;
        }
        let tick = |state: libc::c_int| values[base + state as usize] as u32 as u64;
        ticks.user += tick(libc::CPU_STATE_USER);
        ticks.system += tick(libc::CPU_STATE_SYSTEM);
        ticks.idle += tick(libc::CPU_STATE_IDLE);
        ticks.nice += tick(libc::CPU_STATE_NICE);
    }
    // SAFETY: releases exactly the buffer host_processor_info handed us.
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            (info_count as usize * mem::size_of::<libc::integer_t>()) as libc::vm_size_t,
        );
    }
    Ok(ticks)
}

extern "C" {
    fn getloadavg(loadavg: *mut f64, nelem: libc::c_int) -> libc::c_int;
}

/// The 1, 5, and 15 minute load averages.
pub fn load_averages() -> Result<[f64; 3], SysError> {
    let mut out = [0f64; 3];
    // SAFETY: `out` holds the three doubles requested.
    let filled = unsafe { getloadavg(out.as_mut_ptr(), 3) };
    if filled != 3 {
        return Err(SysError(format!("getloadavg returned {filled}")));
    }
    Ok(out)
}

/// Physical memory composition in pages plus swap in bytes
/// (`host_statistics64` + `hw.memsize` + `vm.swapusage`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemoryStats {
    pub total_bytes: u64,
    pub page_size: u64,
    pub free_pages: u64,
    pub speculative_pages: u64,
    pub wired_pages: u64,
    pub compressor_pages: u64,
    pub swap_total_bytes: u64,
    pub swap_used_bytes: u64,
}

fn sysctl_value<T: Copy>(name: &str) -> Result<T, SysError> {
    let cname = CString::new(name).map_err(|_| SysError(format!("bad sysctl name {name:?}")))?;
    // SAFETY: `T` is a plain C value type the caller chose for this sysctl;
    // a zeroed instance is a valid buffer for the kernel to fill.
    let mut value: T = unsafe { mem::zeroed() };
    let mut len = mem::size_of::<T>();
    // SAFETY: the buffer is exactly `len` bytes long.
    let status = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            (&mut value as *mut T).cast::<libc::c_void>(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if status != 0 || len != mem::size_of::<T>() {
        return Err(SysError(format!("sysctlbyname({name}) failed")));
    }
    Ok(value)
}

/// Current memory statistics.
#[allow(deprecated)]
pub fn memory_stats() -> Result<MemoryStats, SysError> {
    // SAFETY: vm_statistics64 is a plain C struct; zeroed is a valid buffer.
    let mut stats: libc::vm_statistics64 = unsafe { mem::zeroed() };
    let mut count: libc::mach_msg_type_number_t = libc::HOST_VM_INFO64_COUNT;
    // SAFETY: `count` bounds the write into `stats`.
    let status = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            (&mut stats as *mut libc::vm_statistics64).cast::<libc::integer_t>(),
            &mut count,
        )
    };
    if status != libc::KERN_SUCCESS {
        return Err(SysError(format!("host_statistics64 failed with status {status}")));
    }
    // SAFETY: plain libc query.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if page_size <= 0 {
        return Err(SysError("sysconf(_SC_PAGESIZE) failed".into()));
    }
    let total_bytes: u64 = sysctl_value("hw.memsize")?;
    let swap: libc::xsw_usage = sysctl_value("vm.swapusage")?;
    Ok(MemoryStats {
        total_bytes,
        page_size: page_size as u64,
        free_pages: u64::from(stats.free_count),
        speculative_pages: u64::from(stats.speculative_count),
        wired_pages: u64::from(stats.wire_count),
        compressor_pages: u64::from(stats.compressor_page_count),
        swap_total_bytes: swap.xsu_total,
        swap_used_bytes: swap.xsu_used,
    })
}

/// Lifetime byte counters of one network interface (64-bit, as `netstat -b`
/// reports them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceCounters {
    pub name: String,
    pub received_bytes: u64,
    pub sent_bytes: u64,
}

/// Byte counters for every interface, from the `NET_RT_IFLIST2` routing
/// sysctl (one `RTM_IFINFO2` record per interface, each followed by its
/// link-level `sockaddr_dl` carrying the name).
pub fn interface_counters() -> Result<Vec<InterfaceCounters>, SysError> {
    let mut mib = [libc::CTL_NET, libc::PF_ROUTE, 0, 0, libc::NET_RT_IFLIST2, 0];
    let mut len: libc::size_t = 0;
    // SAFETY: a null buffer with a length out-pointer asks for the size.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            ptr::null_mut(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return Err(SysError("sysctl(NET_RT_IFLIST2) size query failed".into()));
    }
    let mut buffer = vec![0u8; len];
    // SAFETY: `buffer` is `len` bytes long and `len` is updated to the bytes written.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast::<libc::c_void>(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return Err(SysError("sysctl(NET_RT_IFLIST2) failed".into()));
    }
    buffer.truncate(len);
    Ok(parse_iflist2(&buffer))
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
    fn cpu_ticks_advance_and_percentages_sum_to_one_hundred() {
        let first = cpu_ticks().expect("ticks");
        std::thread::sleep(std::time::Duration::from_millis(30));
        let second = cpu_ticks().expect("ticks");
        assert!(second.total() >= first.total());
        let percentages = second.percentages_since(&first).expect("elapsed ticks");
        let sum = percentages.user + percentages.system + percentages.idle;
        assert!((sum - 100.0).abs() < 0.01, "sum {sum}");
        assert!(second.percentages_since(&second).is_none());
        assert!(first.percentages_since(&second).is_none(), "backwards counters reject");
    }

    #[test]
    fn load_averages_are_finite_and_non_negative() {
        let load = load_averages().expect("load");
        assert!(load.iter().all(|value| value.is_finite() && *value >= 0.0));
    }

    #[test]
    fn memory_stats_are_internally_consistent() {
        let stats = memory_stats().expect("memory");
        assert!(stats.total_bytes > 0);
        assert!(stats.page_size >= 4096);
        assert!(stats.wired_pages * stats.page_size <= stats.total_bytes);
        assert!(stats.swap_used_bytes <= stats.swap_total_bytes);
    }

    #[test]
    fn interface_counters_include_loopback() {
        let counters = interface_counters().expect("interfaces");
        assert!(counters.iter().any(|entry| entry.name == "lo0"), "{counters:?}");
    }

    #[test]
    fn iflist2_parser_stops_on_truncated_records() {
        assert!(parse_iflist2(&[]).is_empty());
        assert!(parse_iflist2(&[0u8; 4]).is_empty());
    }
}
