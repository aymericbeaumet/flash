//! Disk activity and capacity: the `IOBlockStorageDriver` statistics
//! `ioreg -r -c IOBlockStorageDriver` prints, and the local volumes `df -l`
//! lists (`getfsstat`, then a fresh `statfs` per mount).

use std::ffi::{CStr, CString, c_char};
use std::mem;
use std::ptr;

use super::{SysError, matching_services, registry_entry_id, registry_property};
use crate::cf;

/// One block-storage driver's lifetime transfer counters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockStorageStatistics {
    /// The driver's registry entry ID (`ioreg`'s `id 0x…`): a stable key
    /// while the device stays attached.
    pub registry_id: u64,
    /// `Statistics` → `Bytes (Read)` since the driver attached.
    pub bytes_read: Option<u64>,
    /// `Statistics` → `Bytes (Write)` since the driver attached.
    pub bytes_written: Option<u64>,
}

/// Counters for every `IOBlockStorageDriver` (one per attached disk, disk
/// image included), read from the IOKit registry.
pub fn block_storage_statistics() -> Result<Vec<BlockStorageStatistics>, SysError> {
    Ok(matching_services(c"IOBlockStorageDriver")?
        .iter()
        .filter_map(|driver| {
            let registry_id = registry_entry_id(driver)?;
            let statistics = registry_property(driver, "Statistics");
            let statistics = statistics.as_ref().map_or(ptr::null(), cf::Owned::as_ptr);
            // SAFETY: a live dictionary owned by `statistics`, or null.
            Some(unsafe { block_storage_from(registry_id, statistics) })
        })
        .collect())
}

/// # Safety
/// `statistics` is null or a live CF object.
unsafe fn block_storage_from(
    registry_id: u64,
    statistics: cf::CFTypeRef,
) -> BlockStorageStatistics {
    let counter = |key: &str| {
        // SAFETY: borrowed from the live dictionary (caller guarantee).
        unsafe { cf::as_i64(cf::dictionary_value(statistics, key)) }
            .and_then(|value| u64::try_from(value).ok())
    };
    BlockStorageStatistics {
        registry_id,
        bytes_read: counter("Bytes (Read)"),
        bytes_written: counter("Bytes (Write)"),
    }
}

/// One mounted local file system's size, in its own block units.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalVolume {
    /// Where it is mounted (`f_mntonname`), as `df`'s `Mounted on`.
    pub mount_point: String,
    /// The fundamental block size in bytes (`f_bsize`).
    pub block_size: u32,
    /// Total blocks (`f_blocks`).
    pub blocks: u64,
    /// Blocks available to an unprivileged user (`f_bavail`).
    pub blocks_available: u64,
}

/// Every mount `df -l` lists, in mount-table order: file systems whose type
/// the kernel registers as local (network types such as `nfs` and `smbfs`
/// are left out; `devfs` and `autofs` are too, as `df -l` leaves them out),
/// each re-read with `statfs` for current figures and falling back to the
/// mount table's cached ones when that fails.
pub fn local_volumes() -> Result<Vec<LocalVolume>, SysError> {
    let remote = remote_filesystem_types();
    Ok(mount_table()?
        .iter()
        .filter(|mount| !remote.contains(&c_text(&mount.f_fstypename)))
        .map(|mount| volume(&restat(mount).unwrap_or(*mount)))
        .collect())
}

/// `getfsstat(MNT_NOWAIT)`: the kernel's cached figures for every mount,
/// without waiting on any file system.
fn mount_table() -> Result<Vec<libc::statfs>, SysError> {
    // SAFETY: a null buffer asks for the mount count.
    let count = unsafe { libc::getfsstat(ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    let Ok(count) = usize::try_from(count) else {
        return Err(SysError("getfsstat count failed".into()));
    };
    // Headroom for mounts added between the two calls.
    // SAFETY: statfs is a plain C struct; zeroed is a valid value.
    let mut mounts = vec![unsafe { mem::zeroed::<libc::statfs>() }; count + 8];
    let bytes = libc::c_int::try_from(mounts.len() * mem::size_of::<libc::statfs>())
        .map_err(|_| SysError("getfsstat buffer too large".into()))?;
    // SAFETY: `mounts` is `bytes` long; the call returns how many it filled.
    let filled = unsafe { libc::getfsstat(mounts.as_mut_ptr(), bytes, libc::MNT_NOWAIT) };
    let Ok(filled) = usize::try_from(filled) else {
        return Err(SysError("getfsstat failed".into()));
    };
    mounts.truncate(filled);
    Ok(mounts)
}

/// A current `statfs` of the mount point, as `df` takes for every mount it
/// lists.
fn restat(mount: &libc::statfs) -> Option<libc::statfs> {
    let path = CString::new(c_text(&mount.f_mntonname)).ok()?;
    // SAFETY: statfs is a plain C struct; zeroed is a valid buffer.
    let mut fresh: libc::statfs = unsafe { mem::zeroed() };
    // SAFETY: a NUL-terminated path and a statfs-sized buffer.
    let status = unsafe { libc::statfs(path.as_ptr(), &mut fresh) };
    (status == 0).then_some(fresh)
}

fn volume(mount: &libc::statfs) -> LocalVolume {
    LocalVolume {
        mount_point: c_text(&mount.f_mntonname),
        block_size: mount.f_bsize,
        blocks: mount.f_blocks,
        blocks_available: mount.f_bavail,
    }
}

/// `struct vfsconf` from `<sys/mount.h>`, as the `VFS_CONF` sysctl fills it.
#[repr(C)]
struct VfsConf {
    reserved1: u32,
    name: [c_char; 15],
    type_number: libc::c_int,
    reference_count: libc::c_int,
    flags: libc::c_int,
    reserved2: u32,
    reserved3: u32,
}

const VFS_GENERIC: libc::c_int = 0;
const VFS_MAXTYPENUM: libc::c_int = 1;
const VFS_CONF: libc::c_int = 2;

/// Names of the registered file-system types without `MNT_LOCAL`: the
/// exclusion list `df -l` builds (`makenetvfslist`). Empty when the table
/// cannot be read, which, as in `df`, excludes nothing.
fn remote_filesystem_types() -> Vec<String> {
    let mut mib = [libc::CTL_VFS, VFS_GENERIC, VFS_MAXTYPENUM];
    let mut type_count: libc::c_int = 0;
    let mut len = mem::size_of::<libc::c_int>();
    // SAFETY: the buffer is one c_int, `len` bytes long.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            (&mut type_count as *mut libc::c_int).cast::<libc::c_void>(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return Vec::new();
    }
    (0..type_count)
        .filter_map(|type_number| {
            let mut mib = [libc::CTL_VFS, VFS_GENERIC, VFS_CONF, type_number];
            // SAFETY: VfsConf is a plain C struct; zeroed is a valid buffer.
            let mut conf: VfsConf = unsafe { mem::zeroed() };
            let mut len = mem::size_of::<VfsConf>();
            // SAFETY: the buffer is one VfsConf, `len` bytes long. Unused
            // type numbers fail and are skipped, as in `df`.
            let status = unsafe {
                libc::sysctl(
                    mib.as_mut_ptr(),
                    mib.len() as libc::c_uint,
                    (&mut conf as *mut VfsConf).cast::<libc::c_void>(),
                    &mut len,
                    ptr::null_mut(),
                    0,
                )
            };
            (status == 0 && conf.flags & libc::MNT_LOCAL == 0).then(|| c_text(&conf.name))
        })
        .collect()
}

/// A fixed C character array up to its first NUL (or its end), lossily
/// decoded.
fn c_text(chars: &[c_char]) -> String {
    // SAFETY: c_char and u8 share size and alignment.
    let bytes = unsafe { std::slice::from_raw_parts(chars.as_ptr().cast::<u8>(), chars.len()) };
    match CStr::from_bytes_until_nul(bytes) {
        Ok(text) => text.to_string_lossy().into_owned(),
        Err(_) => String::from_utf8_lossy(bytes).into_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cf::fixtures::*;

    #[test]
    fn statistics_read_the_byte_counters_and_reject_negative_or_missing_ones() {
        let statistics = table(&[
            ("Bytes (Read)", integer(1_869_000_000_000)),
            ("Bytes (Write)", integer(1_759_000_000_000)),
            ("Operations (Read)", integer(42)),
        ]);
        let partial = table(&[("Bytes (Read)", integer(-1)), ("Bytes (Write)", text("9"))]);
        // SAFETY: live dictionaries, then null.
        unsafe {
            assert_eq!(
                block_storage_from(0x1_0000_0c6f, statistics.as_ptr()),
                BlockStorageStatistics {
                    registry_id: 0x1_0000_0c6f,
                    bytes_read: Some(1_869_000_000_000),
                    bytes_written: Some(1_759_000_000_000),
                }
            );
            assert_eq!(
                block_storage_from(7, partial.as_ptr()),
                BlockStorageStatistics {
                    registry_id: 7,
                    bytes_read: None,
                    bytes_written: None,
                }
            );
            assert_eq!(
                block_storage_from(8, ptr::null()),
                BlockStorageStatistics {
                    registry_id: 8,
                    bytes_read: None,
                    bytes_written: None,
                }
            );
        }
    }

    #[test]
    fn c_text_stops_at_the_first_nul_or_the_array_end() {
        let chars = |text: &[u8]| text.iter().map(|byte| *byte as c_char).collect::<Vec<_>>();
        assert_eq!(c_text(&chars(b"apfs\0\0\0")), "apfs");
        assert_eq!(
            c_text(&chars(b"/Volumes/Backup Drive\0junk")),
            "/Volumes/Backup Drive"
        );
        assert_eq!(c_text(&chars(b"fifteen-chars-x")), "fifteen-chars-x");
        assert_eq!(c_text(&chars(b"")), "");
    }

    #[test]
    fn vfsconf_matches_the_c_layout() {
        assert_eq!(mem::size_of::<VfsConf>(), 40);
        assert_eq!(mem::offset_of!(VfsConf, flags), 28);
    }

    #[test]
    fn block_storage_statistics_cover_the_startup_disk() {
        let drivers = block_storage_statistics().expect("IOKit registry");
        assert!(
            drivers
                .iter()
                .any(|driver| driver.bytes_read.is_some() && driver.bytes_written.is_some()),
            "{drivers:?}"
        );
        let mut ids: Vec<u64> = drivers.iter().map(|driver| driver.registry_id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), drivers.len(), "registry ids are unique");
    }

    #[test]
    fn local_volumes_include_the_startup_volume_and_leave_out_network_types() {
        let remote = remote_filesystem_types();
        assert!(remote.iter().any(|name| name == "nfs"), "{remote:?}");
        assert!(
            !remote.iter().any(|name| name == "apfs" || name == "hfs"),
            "{remote:?}"
        );

        let volumes = local_volumes().expect("mount table");
        let root = volumes
            .iter()
            .find(|volume| volume.mount_point == "/")
            .expect("the root volume is local");
        assert!(root.block_size > 0 && root.blocks > 0, "{root:?}");
        assert!(root.blocks_available <= root.blocks, "{root:?}");
    }
}
