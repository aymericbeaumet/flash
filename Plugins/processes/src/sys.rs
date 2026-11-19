//! The kernel's view of the processes, read through libproc with no
//! subprocess: resource use, task counters, descriptor lists and executable
//! paths. The plugin's sandbox opens these reads for other processes through
//! the manifest's `process_info` capability; without it they answer `EPERM`.
//! The unsafe FFI stays in this module, behind [`Kernel`], and the
//! [`bundle`](crate::bundle) reader beside it. Only this plugin reads these
//! per-process interfaces, so they live here; the pid list, which the
//! terminals plugin walks too, is the SDK's (`flash_plugin::sys`).

use std::ffi::{CStr, c_void};
use std::mem;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::bundle::{self, BundleInfo};

/// One `proc_pid_rusage` read of a pid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Usage {
    /// Cumulative user and system CPU time, in nanoseconds.
    pub(crate) cpu_ns: u64,
    pub(crate) resident_bytes: u64,
    pub(crate) disk_read_bytes: u64,
    pub(crate) disk_write_bytes: u64,
    /// When the process started, in Mach absolute time: with the pid, the
    /// identity of one process, which a reused pid does not share.
    pub(crate) start_abstime: u64,
}

/// What the plugin asks the kernel and the file system. The live reader is
/// [`Libproc`]; tests script their own.
pub(crate) trait Kernel: Send + Sync {
    /// Every visible pid, in the kernel's order. Empty only when the read
    /// failed: the reading process itself is always listed.
    fn pids(&self) -> Vec<i32>;
    fn children(&self, parent: i32) -> Vec<i32>;
    /// Nil when the pid is gone or not this user's to inspect.
    fn usage(&self, pid: i32) -> Option<Usage>;
    /// The executable's path.
    fn path(&self, pid: i32) -> Option<String>;
    fn thread_count(&self, pid: i32) -> usize;
    /// Open socket descriptors, unix-domain ones included.
    fn socket_count(&self, pid: i32) -> usize;
    /// Seconds since the process started, by the wall clock.
    fn uptime_seconds(&self, pid: i32) -> u64;
    /// Physical memory, the denominator of every memory share. Never zero.
    fn physical_memory(&self) -> u64;
    /// The identity an application bundle's `Info.plist` states.
    fn bundle_info(&self, bundle_path: &str) -> BundleInfo;
}

/// The last component of an executable's path: the process's name, as
/// Activity Monitor and `top` show it.
pub(crate) fn basename(path: &str) -> Option<String> {
    let name = path.trim_end_matches('/').rsplit('/').next()?;
    (!name.is_empty()).then(|| name.to_string())
}

/// libproc, sysctl and CoreFoundation.
pub(crate) struct Libproc;

#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

unsafe extern "C" {
    fn mach_timebase_info(info: *mut MachTimebase) -> libc::c_int;
}

/// Mach absolute-time ticks to nanoseconds, with the conversion read once.
fn nanoseconds(ticks: u64) -> u64 {
    static TIMEBASE: OnceLock<(u64, u64)> = OnceLock::new();
    let (numer, denom) = *TIMEBASE.get_or_init(|| {
        let mut info = MachTimebase { numer: 0, denom: 0 };
        // SAFETY: `info` is a valid out-parameter for the call.
        let status = unsafe { mach_timebase_info(&mut info) };
        if status == 0 && info.denom != 0 {
            (u64::from(info.numer), u64::from(info.denom))
        } else {
            (1, 1)
        }
    });
    ((u128::from(ticks) * u128::from(numer)) / u128::from(denom)).min(u128::from(u64::MAX)) as u64
}

/// One fixed-size `proc_pidinfo` flavor, or nil when the kernel wrote less.
fn pid_info<T>(pid: i32, flavor: libc::c_int) -> Option<T> {
    let size = mem::size_of::<T>() as libc::c_int;
    // SAFETY: every flavor read here is a plain C struct, for which zeroed
    // memory is a valid value.
    let mut info: T = unsafe { mem::zeroed() };
    // SAFETY: the buffer is exactly `size` bytes long.
    let written =
        unsafe { libc::proc_pidinfo(pid, flavor, 0, (&mut info as *mut T).cast::<c_void>(), size) };
    (written == size).then_some(info)
}

impl Kernel for Libproc {
    fn pids(&self) -> Vec<i32> {
        flash_plugin::sys::process_ids().unwrap_or_default()
    }

    fn children(&self, parent: i32) -> Vec<i32> {
        // SAFETY: a null buffer asks for the count of children.
        let count = unsafe { libc::proc_listchildpids(parent, std::ptr::null_mut(), 0) };
        if count <= 0 {
            return Vec::new();
        }
        // Headroom for children started between the two calls.
        let mut pids = vec![0 as libc::pid_t; count as usize + 16];
        let bytes = (pids.len() * mem::size_of::<libc::pid_t>()) as libc::c_int;
        // SAFETY: `pids` is `bytes` long; the call returns how many it wrote.
        let filled =
            unsafe { libc::proc_listchildpids(parent, pids.as_mut_ptr().cast::<c_void>(), bytes) };
        if filled <= 0 {
            return Vec::new();
        }
        pids.truncate((filled as usize).min(pids.len()));
        pids.retain(|pid| *pid > 0);
        pids
    }

    fn usage(&self, pid: i32) -> Option<Usage> {
        // SAFETY: rusage_info_v4 is a plain C struct; zeroed is valid.
        let mut info: libc::rusage_info_v4 = unsafe { mem::zeroed() };
        // SAFETY: the buffer is a rusage_info_v4, the flavor asked for.
        let status = unsafe {
            libc::proc_pid_rusage(
                pid,
                libc::RUSAGE_INFO_V4,
                (&mut info as *mut libc::rusage_info_v4).cast::<libc::rusage_info_t>(),
            )
        };
        (status == 0).then(|| Usage {
            cpu_ns: nanoseconds(info.ri_user_time.wrapping_add(info.ri_system_time)),
            resident_bytes: info.ri_resident_size,
            disk_read_bytes: info.ri_diskio_bytesread,
            disk_write_bytes: info.ri_diskio_byteswritten,
            start_abstime: info.ri_proc_start_abstime,
        })
    }

    fn path(&self, pid: i32) -> Option<String> {
        let mut buffer = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: the buffer is as long as the size passed.
        let written = unsafe {
            libc::proc_pidpath(
                pid,
                buffer.as_mut_ptr().cast::<c_void>(),
                buffer.len() as u32,
            )
        };
        if written <= 0 {
            return None;
        }
        let path = CStr::from_bytes_until_nul(&buffer).ok()?.to_string_lossy();
        (!path.is_empty()).then(|| path.into_owned())
    }

    fn thread_count(&self, pid: i32) -> usize {
        pid_info::<libc::proc_taskinfo>(pid, libc::PROC_PIDTASKINFO)
            .map_or(0, |info| info.pti_threadnum.max(0) as usize)
    }

    /// From the descriptor list alone. Resolving each socket's family costs
    /// one `proc_pidfdinfo` per descriptor, tens of thousands of syscalls
    /// per sample for a browser's helper tree, so the count includes
    /// unix-domain sockets and stays two syscalls per pid.
    fn socket_count(&self, pid: i32) -> usize {
        // SAFETY: a null buffer asks for the size of the list.
        let required =
            unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if required <= 0 {
            return 0;
        }
        let stride = mem::size_of::<libc::proc_fdinfo>();
        let capacity = required as usize / stride + 16;
        let mut descriptors = vec![
            libc::proc_fdinfo {
                proc_fd: 0,
                proc_fdtype: 0,
            };
            capacity
        ];
        // SAFETY: the buffer holds `capacity` descriptors, the size passed.
        let filled = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDLISTFDS,
                0,
                descriptors.as_mut_ptr().cast::<c_void>(),
                (capacity * stride) as libc::c_int,
            )
        };
        if filled <= 0 {
            return 0;
        }
        let count = (filled as usize / stride).min(descriptors.len());
        descriptors[..count]
            .iter()
            .filter(|descriptor| descriptor.proc_fdtype == libc::PROX_FDTYPE_SOCKET as u32)
            .count()
    }

    fn uptime_seconds(&self, pid: i32) -> u64 {
        let Some(info) = pid_info::<libc::proc_bsdinfo>(pid, libc::PROC_PIDTBSDINFO) else {
            return 0;
        };
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |now| now.as_secs().saturating_sub(info.pbi_start_tvsec))
    }

    fn physical_memory(&self) -> u64 {
        static TOTAL: OnceLock<u64> = OnceLock::new();
        *TOTAL.get_or_init(|| {
            let mut bytes: u64 = 0;
            let mut size = mem::size_of::<u64>();
            // SAFETY: the name is NUL-terminated and the buffer is `size`
            // bytes long.
            let status = unsafe {
                libc::sysctlbyname(
                    c"hw.memsize".as_ptr(),
                    (&mut bytes as *mut u64).cast::<c_void>(),
                    &mut size,
                    std::ptr::null_mut(),
                    0,
                )
            };
            if status == 0 { bytes.max(1) } else { 1 }
        })
    }

    fn bundle_info(&self, bundle_path: &str) -> BundleInfo {
        bundle::read(bundle_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_process_is_named_after_its_executable() {
        assert_eq!(
            basename("/Applications/Safari.app/Contents/MacOS/Safari").as_deref(),
            Some("Safari")
        );
        assert_eq!(basename("zsh").as_deref(), Some("zsh"));
        assert_eq!(basename("/"), None);
        assert_eq!(basename(""), None);
    }

    /// The live reads, on this process: unsandboxed here, and under the
    /// plugin's profile in the host's sandbox tests.
    #[test]
    fn libproc_reads_this_process_and_its_parent() {
        let kernel = Libproc;
        let own = std::process::id() as i32;
        let parent = std::os::unix::process::parent_id() as i32;
        let pids = kernel.pids();
        assert!(pids.contains(&own), "own pid {own}");
        assert!(pids.contains(&parent), "parent pid {parent}");
        assert!(kernel.children(parent).contains(&own));
        let usage = kernel.usage(own).expect("own usage");
        assert!(usage.resident_bytes > 0);
        assert!(usage.start_abstime > 0);
        assert!(kernel.usage(parent).is_some(), "another process's usage");
        let path = kernel.path(own).expect("own path");
        assert!(path.starts_with('/'), "{path}");
        assert!(kernel.thread_count(own) >= 1);
        assert!(kernel.uptime_seconds(parent) >= kernel.uptime_seconds(own));
        assert!(kernel.physical_memory() > 1 << 30);
        assert_eq!(kernel.usage(i32::MAX), None, "no such process");
        assert_eq!(kernel.path(i32::MAX), None);
        assert_eq!(kernel.thread_count(i32::MAX), 0);
        assert_eq!(kernel.socket_count(i32::MAX), 0);
        assert_eq!(kernel.children(i32::MAX), Vec::<i32>::new());
    }
}
