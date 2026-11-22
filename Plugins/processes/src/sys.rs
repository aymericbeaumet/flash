//! What the plugin reads of the Mac it runs on: the size of its memory, the
//! wall clock and an application bundle's `Info.plist`. Nothing here reads a
//! process. The table is the host's (`host.process_table`, through
//! `flash_plugin`), and the plugin's sandbox denies it every process but
//! its own. The unsafe FFI stays in this module, behind [`Machine`], and
//! the [`bundle`](crate::bundle) reader beside it.

use std::ffi::c_void;
use std::mem;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::bundle::{self, BundleInfo};

/// What the plugin asks the machine and the file system. The live one is
/// [`ThisMac`]; tests script their own.
pub(crate) trait Machine: Send + Sync {
    /// Physical memory, the denominator of every memory share. Never zero.
    fn physical_memory(&self) -> u64;
    /// The wall clock, in Unix seconds: what a start time is subtracted
    /// from.
    fn now(&self) -> u64;
    /// The identity an application bundle's `Info.plist` states.
    fn bundle_info(&self, bundle_path: &str) -> BundleInfo;
}

/// sysctl, the system clock and CoreFoundation.
pub(crate) struct ThisMac;

impl Machine for ThisMac {
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

    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |now| now.as_secs())
    }

    fn bundle_info(&self, bundle_path: &str) -> BundleInfo {
        bundle::read(bundle_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The live reads, none of which names a process: unsandboxed here, and
    /// under the plugin's profile in the host's sandbox tests.
    #[test]
    fn this_mac_states_its_memory_and_its_clock() {
        let mac = ThisMac;
        assert!(mac.physical_memory() > 1 << 30);
        assert!(mac.now() > 1_700_000_000);
    }
}
