//! Memory composition: the page counts `vm_stat` prints
//! (`host_statistics64`), with the installed memory, swap usage and
//! available-memory level `sysctl` reports.

use std::mem;

use super::SysError;
use super::sysctl::sysctl_value;

/// Physical memory composition in pages plus swap in bytes
/// (`host_statistics64` + `hw.memsize` + `vm.swapusage`), with the kernel's
/// available-memory level (`kern.memorystatus_level`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct MemoryStats {
    pub(crate) total_bytes: u64,
    pub(crate) page_size: u64,
    pub(crate) free_pages: u64,
    pub(crate) speculative_pages: u64,
    pub(crate) wired_pages: u64,
    pub(crate) compressor_pages: u64,
    pub(crate) swap_total_bytes: u64,
    pub(crate) swap_used_bytes: u64,
    /// The percentage of memory the kernel counts as available, as read;
    /// `None` when the sysctl does not answer. The composition stands
    /// without it.
    pub(crate) pressure_level: Option<i32>,
}

/// Current memory statistics.
#[allow(deprecated)]
pub(crate) fn memory_stats() -> Result<MemoryStats, SysError> {
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
    let pressure_level = sysctl_value::<i32>("kern.memorystatus_level").ok();
    Ok(MemoryStats {
        total_bytes,
        page_size: page_size as u64,
        free_pages: u64::from(stats.free_count),
        speculative_pages: u64::from(stats.speculative_count),
        wired_pages: u64::from(stats.wire_count),
        compressor_pages: u64::from(stats.compressor_page_count),
        swap_total_bytes: swap.xsu_total,
        swap_used_bytes: swap.xsu_used,
        pressure_level,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_stats_are_internally_consistent() {
        let stats = memory_stats().expect("memory");
        assert!(stats.total_bytes > 0);
        assert!(stats.page_size >= 4096);
        assert!(stats.wired_pages * stats.page_size <= stats.total_bytes);
        assert!(stats.swap_used_bytes <= stats.swap_total_bytes);
        let level = stats.pressure_level.expect("kern.memorystatus_level");
        assert!((0..=100).contains(&level), "{level}");
    }
}
