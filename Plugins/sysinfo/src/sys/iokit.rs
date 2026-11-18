//! IOKit registry access shared by the GPU, disk and battery readers: the
//! services of a class and their properties, as `ioreg -r -c <class> -l`
//! prints them.

use std::ffi::{CStr, c_char};
use std::ptr;

use super::SysError;
use super::cf;

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
pub(super) struct IoHandle(IoObject);

impl Drop for IoHandle {
    fn drop(&mut self) {
        // SAFETY: the handle owns this one reference.
        unsafe { IOObjectRelease(self.0) };
    }
}

/// Every registered service of IOKit class `class` (subclasses included), as
/// `ioreg -r -c <class>` lists them.
pub(super) fn matching_services(class: &CStr) -> Result<Vec<IoHandle>, SysError> {
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

/// The registry entry name, such as `AGXAcceleratorG16X`; empty when the
/// registry does not answer.
pub(super) fn registry_entry_name(entry: &IoHandle) -> String {
    // `io_name_t` is a 128-byte C string.
    let mut name = [0 as c_char; 128];
    // SAFETY: `name` is the io_name_t buffer the call fills, NUL-terminated.
    if unsafe { IORegistryEntryGetName(entry.0, name.as_mut_ptr()) } != libc::KERN_SUCCESS {
        return String::new();
    }
    // SAFETY: filled and NUL-terminated by the kernel above.
    unsafe { CStr::from_ptr(name.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

/// The registry entry ID: stable for the life of the entry and unique across
/// the registry (`ioreg` prints it as `id 0x…`).
pub(super) fn registry_entry_id(entry: &IoHandle) -> Option<u64> {
    let mut id = 0u64;
    // SAFETY: `entry` is live and `id` is the one u64 the call writes.
    let status = unsafe { IORegistryEntryGetRegistryEntryID(entry.0, &mut id) };
    (status == libc::KERN_SUCCESS).then_some(id)
}

/// Every property of a registry entry, as one +1 CFDictionary.
pub(super) fn registry_properties(entry: &IoHandle) -> Option<cf::Owned> {
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

pub(super) fn registry_property(entry: &IoHandle, key: &str) -> Option<cf::Owned> {
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
