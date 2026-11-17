//! Native macOS system sampling for the status monitors.
//!
//! The monitor plugins used to shell out (`iostat`, `vm_stat`, `sysctl`,
//! `netstat`, `ps`, `pmset`, `df`, and `ioreg` for GPU, battery and disk
//! statistics) — a fork, an exec, three pipes, and a wait per sample, and an
//! exec can stall for seconds while macOS's exec policy daemon is busy. These
//! readers use the kernel and framework interfaces those tools read
//! themselves: `host_processor_info`, `host_statistics64`, `sysctlbyname`,
//! the `NET_RT_IFLIST2` and `NET_RT_DUMP2` routing sysctls, libproc, the
//! IOKit registry, IOPowerSources, and `getfsstat`/`statfs`. Each call takes
//! microseconds and never blocks on a child. As with `process.rs` and
//! `runtime.rs`, the unsafe FFI stays inside the SDK; plugins call the safe
//! wrappers.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char};
use std::fmt;
use std::mem;
use std::ptr;

use crate::cf;

mod power;
mod routes;
mod storage;

pub use power::{PowerSource, PowerSources, SmartBattery, power_sources, smart_battery};
pub use routes::{DefaultRoute, RouteFamily, default_routes};
pub use storage::{BlockStorageStatistics, LocalVolume, block_storage_statistics, local_volumes};

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
        return Err(SysError(format!(
            "host_processor_info failed with status {status}"
        )));
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

unsafe extern "C" {
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
        return Err(SysError(format!(
            "host_statistics64 failed with status {status}"
        )));
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

/// Every visible process with its parent, as `(pid, ppid)`: what
/// `ps -axo pid=,ppid=` prints, read through libproc without a fork.
/// `PROC_PIDT_SHORTBSDINFO` is the flavor the kernel answers across users, so
/// root-owned ancestors such as `login` keep the tree connected. A process
/// that exits between the listing and its read is skipped.
pub fn process_parents() -> Result<Vec<(i32, i32)>, SysError> {
    // SAFETY: a null buffer asks for the current pid count.
    let count = unsafe { libc::proc_listallpids(ptr::null_mut(), 0) };
    if count <= 0 {
        return Err(SysError(format!("proc_listallpids returned {count}")));
    }
    // Headroom for processes started between the two calls.
    let mut pids = vec![0 as libc::pid_t; count as usize + 64];
    let bytes = (pids.len() * mem::size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: `pids` is `bytes` long; the call returns how many pids it wrote.
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast::<libc::c_void>(), bytes) };
    if filled <= 0 {
        return Err(SysError(format!("proc_listallpids returned {filled}")));
    }
    pids.truncate((filled as usize).min(pids.len()));
    let size = mem::size_of::<libc::proc_bsdshortinfo>() as libc::c_int;
    Ok(pids
        .into_iter()
        .filter_map(|pid| {
            // SAFETY: proc_bsdshortinfo is a plain C struct; zeroed is a valid buffer.
            let mut info: libc::proc_bsdshortinfo = unsafe { mem::zeroed() };
            // SAFETY: the buffer is exactly `size` bytes long.
            let written = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDT_SHORTBSDINFO,
                    0,
                    (&mut info as *mut libc::proc_bsdshortinfo).cast::<libc::c_void>(),
                    size,
                )
            };
            (written == size).then_some((pid, info.pbsi_ppid as i32))
        })
        .collect())
}

/// One GPU's registry identity and `PerformanceStatistics`: what
/// `ioreg -r -c IOAccelerator -l` prints for each accelerator.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GpuStatistics {
    /// IORegistry entry name, such as `AGXAcceleratorG16X`.
    pub name: String,
    /// The accelerator's `model` property (`Apple M4 Pro`) when it has one.
    pub model: Option<String>,
    /// Every numeric `PerformanceStatistics` entry, keyed as the driver
    /// publishes it (`Device Utilization %`, `Renderer Utilization %`, …).
    /// Utilization counters are optional: virtual GPUs may expose only memory
    /// and recovery statistics, regardless of the host CPU architecture.
    pub performance: BTreeMap<String, f64>,
}

type IoObject = libc::mach_port_t;

/// `kIOMainPortDefault`: `MACH_PORT_NULL` selects the default main port.
const IO_MAIN_PORT_DEFAULT: libc::mach_port_t = 0;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOServiceMatching(name: *const c_char) -> cf::CFTypeRef;
    fn IOServiceGetMatchingServices(
        main_port: libc::mach_port_t,
        matching: cf::CFTypeRef,
        existing: *mut IoObject,
    ) -> libc::kern_return_t;
    fn IOIteratorNext(iterator: IoObject) -> IoObject;
    fn IOObjectRelease(object: IoObject) -> libc::kern_return_t;
    fn IORegistryEntryGetName(entry: IoObject, name: *mut c_char) -> libc::kern_return_t;
    fn IORegistryEntryGetRegistryEntryID(entry: IoObject, id: *mut u64) -> libc::kern_return_t;
    fn IORegistryEntryCreateCFProperties(
        entry: IoObject,
        properties: *mut cf::CFTypeRef,
        allocator: cf::CFTypeRef,
        options: u32,
    ) -> libc::kern_return_t;
    fn IORegistryEntryCreateCFProperty(
        entry: IoObject,
        key: cf::CFTypeRef,
        allocator: cf::CFTypeRef,
        options: u32,
    ) -> cf::CFTypeRef;
}

/// An IOKit object reference, released on drop.
struct IoHandle(IoObject);

impl Drop for IoHandle {
    fn drop(&mut self) {
        // SAFETY: the handle owns this one reference.
        unsafe { IOObjectRelease(self.0) };
    }
}

/// Every registered service of IOKit class `class` (subclasses included), as
/// `ioreg -r -c <class>` lists them.
fn matching_services(class: &CStr) -> Result<Vec<IoHandle>, SysError> {
    let name = class.to_string_lossy();
    // SAFETY: a C class name; the matching dictionary is consumed by
    // IOServiceGetMatchingServices below.
    let matching = unsafe { IOServiceMatching(class.as_ptr()) };
    if matching.is_null() {
        return Err(SysError(format!("IOServiceMatching({name}) failed")));
    }
    let mut iterator: IoObject = 0;
    // SAFETY: consumes `matching` whatever it returns; `iterator` is ours on success.
    let status =
        unsafe { IOServiceGetMatchingServices(IO_MAIN_PORT_DEFAULT, matching, &mut iterator) };
    if status != libc::KERN_SUCCESS {
        return Err(SysError(format!(
            "IOServiceGetMatchingServices({name}) failed with status {status}"
        )));
    }
    let iterator = IoHandle(iterator);
    let mut services = Vec::new();
    loop {
        // SAFETY: `iterator` is live; each returned service is a +1 reference.
        let service = unsafe { IOIteratorNext(iterator.0) };
        if service == 0 {
            break;
        }
        services.push(IoHandle(service));
    }
    Ok(services)
}

/// Statistics for every `IOAccelerator` service (one per GPU driver
/// instance), read from the IOKit registry without a child process. An
/// empty list means the Mac publishes no accelerator.
pub fn gpu_statistics() -> Result<Vec<GpuStatistics>, SysError> {
    Ok(matching_services(c"IOAccelerator")?
        .iter()
        .map(accelerator_statistics)
        .collect())
}

fn accelerator_statistics(service: &IoHandle) -> GpuStatistics {
    // `io_name_t` is a 128-byte C string.
    let mut name = [0 as c_char; 128];
    // SAFETY: `name` is the io_name_t buffer the call fills, NUL-terminated.
    let name =
        if unsafe { IORegistryEntryGetName(service.0, name.as_mut_ptr()) } == libc::KERN_SUCCESS {
            // SAFETY: filled and NUL-terminated by the kernel above.
            unsafe { CStr::from_ptr(name.as_ptr()) }
                .to_string_lossy()
                .into_owned()
        } else {
            String::new()
        };
    let model = registry_property(service, "model")
        // SAFETY: a live property value owned by `Owned`.
        .and_then(|value| unsafe { cf::as_text(value.as_ptr()) });
    let performance = registry_property(service, "PerformanceStatistics")
        // SAFETY: a live property value owned by `Owned`.
        .map(|value| unsafe { cf::numeric_entries(value.as_ptr()) })
        .unwrap_or_default();
    GpuStatistics {
        name,
        model,
        performance,
    }
}

/// The registry entry ID: stable for the life of the entry and unique across
/// the registry (`ioreg` prints it as `id 0x…`).
fn registry_entry_id(entry: &IoHandle) -> Option<u64> {
    let mut id = 0u64;
    // SAFETY: `entry` is live and `id` is the one u64 the call writes.
    let status = unsafe { IORegistryEntryGetRegistryEntryID(entry.0, &mut id) };
    (status == libc::KERN_SUCCESS).then_some(id)
}

/// Every property of a registry entry, as one +1 CFDictionary.
fn registry_properties(entry: &IoHandle) -> Option<cf::Owned> {
    let mut properties: cf::CFTypeRef = ptr::null();
    // SAFETY: `entry` is live; on success `properties` is a +1 dictionary.
    let status =
        unsafe { IORegistryEntryCreateCFProperties(entry.0, &mut properties, ptr::null(), 0) };
    if status != libc::KERN_SUCCESS {
        return None;
    }
    // SAFETY: the Create rule hands the dictionary to us.
    unsafe { cf::Owned::new(properties) }
}

fn registry_property(entry: &IoHandle, key: &str) -> Option<cf::Owned> {
    let key = cf::string(key)?;
    // SAFETY: `entry` and `key` are live; the property copy is +1.
    unsafe {
        cf::Owned::new(IORegistryEntryCreateCFProperty(
            entry.0,
            key.as_ptr(),
            ptr::null(),
            0,
        ))
    }
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
    Ok(parse_iflist2(&sysctl_buffer(&mut mib, "NET_RT_IFLIST2")?))
}

/// A variable-length sysctl table: the size query, then the read into a
/// buffer with headroom for entries added in between (`netstat`'s own
/// approach), retried while the table outgrows it.
fn sysctl_buffer(mib: &mut [libc::c_int], name: &str) -> Result<Vec<u8>, SysError> {
    const ATTEMPTS: usize = 4;
    for _ in 0..ATTEMPTS {
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
            return Err(SysError(format!("sysctl({name}) size query failed")));
        }
        len += len / 2;
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
        if status == 0 {
            buffer.truncate(len);
            return Ok(buffer);
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOMEM) {
            break;
        }
    }
    Err(SysError(format!("sysctl({name}) failed")))
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
        assert!(
            first.percentages_since(&second).is_none(),
            "backwards counters reject"
        );
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
        assert!(
            counters.iter().any(|entry| entry.name == "lo0"),
            "{counters:?}"
        );
    }

    #[test]
    fn process_parents_match_this_process_and_launchd() {
        let parents = process_parents().expect("process table");
        let own = std::process::id() as i32;
        let parent = std::os::unix::process::parent_id() as i32;
        assert!(parents.contains(&(own, parent)), "own pid {own}");
        assert!(parents.contains(&(1, 0)), "launchd is visible across users");
    }

    #[test]
    fn gpu_statistics_read_the_accelerator_registry() {
        let accelerators = gpu_statistics().expect("IOKit registry");
        for accelerator in &accelerators {
            assert!(!accelerator.name.is_empty(), "{accelerator:?}");
            assert!(
                accelerator
                    .performance
                    .values()
                    .all(|value| value.is_finite()),
                "{accelerator:?}"
            );
            if let Some(utilization) = accelerator.performance.get("Device Utilization %") {
                assert!((0.0..=100.0).contains(utilization), "{accelerator:?}");
            }
        }
    }

    #[test]
    fn iflist2_parser_stops_on_truncated_records() {
        assert!(parse_iflist2(&[]).is_empty());
        assert!(parse_iflist2(&[0u8; 4]).is_empty());
    }
}
