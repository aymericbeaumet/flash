//! The two `sysctl` shapes the readers share: one fixed-size value by name,
//! and a variable-length table by MIB.

use std::ffi::CString;
use std::mem;
use std::ptr;

use super::SysError;

/// One fixed-size value, as `sysctl -n <name>` prints it.
pub(super) fn sysctl_value<T: Copy>(name: &str) -> Result<T, SysError> {
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

/// A variable-length sysctl table: the size query, then the read into a
/// buffer with headroom for entries added in between (`netstat`'s own
/// approach), retried while the table outgrows it.
pub(super) fn sysctl_buffer(mib: &mut [libc::c_int], name: &str) -> Result<Vec<u8>, SysError> {
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
