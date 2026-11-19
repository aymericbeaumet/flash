//! Power-management assertions, behind a seam so the keep-awake is tested
//! without holding the test machine awake.
//!
//! The assertions belong to this process: powerd drops them when it exits,
//! however it exits, so a crashed plugin never leaves the Mac awake. The
//! unsafe FFI stays inside this module.

use std::ffi::c_void;
use std::fmt;
use std::ptr;

/// One assertion powerd holds for this process.
pub type AssertionId = u32;

/// An IOKit power-assertion call that failed, with its `IOReturn`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PowerError(pub i32);

impl fmt::Display for PowerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "caffeinate: power assertion failed (0x{:08x})",
            self.0 as u32
        )
    }
}

pub trait Power: Send {
    /// Take every assertion `caffeinate -dimsu` takes; `seconds` bounds
    /// them.
    fn acquire(&mut self, seconds: Option<u64>) -> Result<Vec<AssertionId>, PowerError>;
    fn release(&mut self, assertions: &[AssertionId]);
}

/// The name powerd lists the assertions under (`pmset -g assertions`).
pub const ASSERTION_NAME: &str = "Flash caffeinate";

/// What `/usr/bin/caffeinate -dimsu [-t seconds]` holds: the display (`-d`),
/// idle system sleep (`-i`), the disk (`-m`) and system sleep on AC (`-s`);
/// [`IoKitPower`] adds the user-activity declaration that wakes the display
/// (`-u`).
pub const ASSERTION_TYPES: [&str; 4] = [
    "PreventUserIdleDisplaySleep",
    "PreventUserIdleSystemSleep",
    "PreventDiskIdle",
    "PreventSystemSleep",
];

type CFTypeRef = *const c_void;

const STRING_ENCODING_UTF8: u32 = 0x0800_0100;
/// `kIOReturnSuccess`.
const IO_RETURN_SUCCESS: i32 = 0;
/// `kIOReturnNoMemory`, for a string CoreFoundation could not make.
const IO_RETURN_NO_MEMORY: i32 = 0xE000_02BDu32 as i32;
/// `kIOPMUserActiveLocal`: the user is at this Mac.
const USER_ACTIVE_LOCAL: u32 = 0;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFStringCreateWithBytes(
        allocator: CFTypeRef,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        is_external_representation: u8,
    ) -> CFTypeRef;
}

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOPMAssertionCreateWithDescription(
        assertion_type: CFTypeRef,
        name: CFTypeRef,
        details: CFTypeRef,
        human_readable_reason: CFTypeRef,
        localization_bundle_path: CFTypeRef,
        timeout: f64,
        timeout_action: CFTypeRef,
        assertion_id: *mut AssertionId,
    ) -> i32;
    fn IOPMAssertionDeclareUserActivity(
        name: CFTypeRef,
        user_type: u32,
        assertion_id: *mut AssertionId,
    ) -> i32;
    fn IOPMAssertionRelease(assertion_id: AssertionId) -> i32;
}

/// A +1 CFString, released on drop.
struct CfString(CFTypeRef);

impl CfString {
    fn new(value: &str) -> Result<Self, PowerError> {
        // SAFETY: the bytes are valid UTF-8 for their length; the result is
        // a +1 reference or null.
        let reference = unsafe {
            CFStringCreateWithBytes(
                ptr::null(),
                value.as_ptr(),
                value.len() as isize,
                STRING_ENCODING_UTF8,
                0,
            )
        };
        if reference.is_null() {
            Err(PowerError(IO_RETURN_NO_MEMORY))
        } else {
            Ok(Self(reference))
        }
    }
}

impl Drop for CfString {
    fn drop(&mut self) {
        // SAFETY: holds exactly one reference, released once here.
        unsafe { CFRelease(self.0) }
    }
}

/// IOKit's assertions. A bound is powerd's own timeout, which turns the
/// assertions off at the deadline even while the host holds the plugin's
/// deadlines for a locked screen.
pub struct IoKitPower;

impl Power for IoKitPower {
    fn acquire(&mut self, seconds: Option<u64>) -> Result<Vec<AssertionId>, PowerError> {
        let name = CfString::new(ASSERTION_NAME)?;
        // Zero is no timeout.
        let timeout = seconds.unwrap_or(0) as f64;
        let mut taken = Vec::with_capacity(ASSERTION_TYPES.len() + 1);
        for assertion_type in ASSERTION_TYPES {
            let assertion_type = match CfString::new(assertion_type) {
                Ok(assertion_type) => assertion_type,
                Err(error) => {
                    self.release(&taken);
                    return Err(error);
                }
            };
            let mut id: AssertionId = 0;
            // SAFETY: live CFStrings, null for the optional ones, and `id` is
            // the one assertion id the call writes.
            let status = unsafe {
                IOPMAssertionCreateWithDescription(
                    assertion_type.0,
                    name.0,
                    ptr::null(),
                    ptr::null(),
                    ptr::null(),
                    timeout,
                    ptr::null(),
                    &mut id,
                )
            };
            if status != IO_RETURN_SUCCESS {
                self.release(&taken);
                return Err(PowerError(status));
            }
            taken.push(id);
        }
        // Wakes a sleeping display. powerd may decline it (a closed lid);
        // the hold stands without it.
        let mut activity: AssertionId = 0;
        // SAFETY: a live CFString and the one assertion id the call writes.
        let status =
            unsafe { IOPMAssertionDeclareUserActivity(name.0, USER_ACTIVE_LOCAL, &mut activity) };
        if status == IO_RETURN_SUCCESS {
            taken.push(activity);
        }
        Ok(taken)
    }

    fn release(&mut self, assertions: &[AssertionId]) {
        for id in assertions {
            // SAFETY: an id this process created; releasing a released one
            // is an error powerd reports, nothing more.
            unsafe { IOPMAssertionRelease(*id) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_names_its_io_return() {
        assert_eq!(
            PowerError(IO_RETURN_NO_MEMORY).to_string(),
            "caffeinate: power assertion failed (0xe00002bd)"
        );
    }
}
