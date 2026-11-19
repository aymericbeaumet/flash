//! What an application bundle says about itself: the identifier and the
//! versions in its `Info.plist`, read through CoreFoundation without loading
//! the bundle, and the bundle a running executable belongs to.

use std::ffi::c_void;
use std::ptr;

/// The identity an `Info.plist` states. Every field is empty when the
/// bundle has none or cannot be read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct BundleInfo {
    /// `CFBundleIdentifier`.
    pub(crate) identifier: String,
    /// `CFBundleShortVersionString`.
    pub(crate) version: String,
    /// `CFBundleVersion`.
    pub(crate) build: String,
}

impl BundleInfo {
    /// The version as one label: `2.1 (42)`, the version alone when the
    /// build repeats it or is missing, the build alone without a version.
    pub(crate) fn version_label(&self) -> String {
        if self.version.is_empty() {
            self.build.clone()
        } else if self.build.is_empty() || self.build == self.version {
            self.version.clone()
        } else {
            format!("{} ({})", self.version, self.build)
        }
    }
}

/// The application bundle an executable runs from: the wrapper of
/// `<bundle>/Contents/MacOS/<executable>`, a helper's own bundle included.
/// Nil for an executable outside a bundle.
pub(crate) fn bundle_path(executable: &str) -> Option<&str> {
    let (directory, _) = executable.rsplit_once('/')?;
    let bundle = directory.strip_suffix("/Contents/MacOS")?;
    (!bundle.is_empty()).then_some(bundle)
}

type CFTypeRef = *const c_void;
type CFIndex = isize;

#[repr(C)]
#[derive(Clone, Copy)]
struct CFRange {
    location: CFIndex,
    length: CFIndex,
}

const STRING_ENCODING_UTF8: u32 = 0x0800_0100;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringCreateWithBytes(
        allocator: CFTypeRef,
        bytes: *const u8,
        length: CFIndex,
        encoding: u32,
        is_external_representation: u8,
    ) -> CFTypeRef;
    fn CFStringGetLength(string: CFTypeRef) -> CFIndex;
    fn CFStringGetBytes(
        string: CFTypeRef,
        range: CFRange,
        encoding: u32,
        loss_byte: u8,
        is_external_representation: u8,
        buffer: *mut u8,
        max_buffer_length: CFIndex,
        used_buffer_length: *mut CFIndex,
    ) -> CFIndex;
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: CFTypeRef,
        buffer: *const u8,
        length: CFIndex,
        is_directory: u8,
    ) -> CFTypeRef;
    fn CFBundleCopyInfoDictionaryInDirectory(bundle_url: CFTypeRef) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
}

/// A +1 reference from a CF Create/Copy function, released on drop.
struct Owned(CFTypeRef);

impl Owned {
    /// # Safety
    /// `reference` is null or a CF object the caller owns (Create/Copy rule)
    /// and hands over to the returned value.
    unsafe fn new(reference: CFTypeRef) -> Option<Self> {
        // Never build `Self(null)`: dropping it would release NULL, which
        // traps.
        (!reference.is_null()).then_some(Self(reference))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: `Owned` holds exactly one reference, released once here.
        unsafe { CFRelease(self.0) }
    }
}

fn string(value: &str) -> Option<Owned> {
    let length = CFIndex::try_from(value.len()).ok()?;
    // SAFETY: the bytes are valid UTF-8 for `length` bytes; the result is +1.
    unsafe {
        Owned::new(CFStringCreateWithBytes(
            ptr::null(),
            value.as_ptr(),
            length,
            STRING_ENCODING_UTF8,
            0,
        ))
    }
}

/// The UTF-8 contents of `value` when it is a CFString, else empty.
///
/// # Safety
/// `value` is null or a live CF object.
unsafe fn contents(value: CFTypeRef) -> String {
    // SAFETY: the caller guarantees a live object when non-null.
    if value.is_null() || unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
        return String::new();
    }
    let range = CFRange {
        location: 0,
        // SAFETY: `value` is a live CFString.
        length: unsafe { CFStringGetLength(value) },
    };
    let mut needed: CFIndex = 0;
    // SAFETY: a null buffer asks for the encoded length only.
    unsafe {
        CFStringGetBytes(
            value,
            range,
            STRING_ENCODING_UTF8,
            b'?',
            0,
            ptr::null_mut(),
            0,
            &mut needed,
        );
    }
    let Ok(capacity) = usize::try_from(needed) else {
        return String::new();
    };
    let mut bytes = vec![0u8; capacity];
    let mut used: CFIndex = 0;
    // SAFETY: the buffer is `needed` bytes long, the length passed.
    unsafe {
        CFStringGetBytes(
            value,
            range,
            STRING_ENCODING_UTF8,
            b'?',
            0,
            bytes.as_mut_ptr(),
            needed,
            &mut used,
        );
    }
    bytes.truncate(usize::try_from(used).unwrap_or(0));
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Read the bundle at `path`. A path that is no bundle, or one whose
/// `Info.plist` is missing or unreadable, answers the empty identity.
pub(crate) fn read(path: &str) -> BundleInfo {
    let Ok(length) = CFIndex::try_from(path.len()) else {
        return BundleInfo::default();
    };
    // SAFETY: the bytes are `length` long; both results follow the
    // Create/Copy rule and are released by `Owned`.
    let dictionary = unsafe {
        let Some(url) = Owned::new(CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            path.as_ptr(),
            length,
            1,
        )) else {
            return BundleInfo::default();
        };
        Owned::new(CFBundleCopyInfoDictionaryInDirectory(url.0))
    };
    let Some(dictionary) = dictionary else {
        return BundleInfo::default();
    };
    let value = |key: &str| {
        string(key).map_or_else(String::new, |key| {
            // SAFETY: both are live CF objects; the value is borrowed from
            // the dictionary, which outlives the copy `contents` makes.
            unsafe { contents(CFDictionaryGetValue(dictionary.0, key.0)) }
        })
    };
    BundleInfo {
        identifier: value("CFBundleIdentifier"),
        version: value("CFBundleShortVersionString"),
        build: value("CFBundleVersion"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_executable_names_the_bundle_that_wraps_it() {
        assert_eq!(
            bundle_path("/Applications/Editor.app/Contents/MacOS/editor"),
            Some("/Applications/Editor.app")
        );
        assert_eq!(
            bundle_path(
                "/Applications/Web.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
            ),
            Some("/Applications/Web.app/Contents/Frameworks/Helper.app")
        );
        assert_eq!(bundle_path("/usr/bin/true"), None);
        assert_eq!(bundle_path("/Contents/MacOS/editor"), None);
        assert_eq!(bundle_path("editor"), None);
    }

    #[test]
    fn the_version_label_joins_the_version_and_a_different_build() {
        let info = |version: &str, build: &str| BundleInfo {
            identifier: String::new(),
            version: version.into(),
            build: build.into(),
        };
        assert_eq!(info("2.1", "42").version_label(), "2.1 (42)");
        assert_eq!(info("2.1", "2.1").version_label(), "2.1");
        assert_eq!(info("2.1", "").version_label(), "2.1");
        assert_eq!(info("", "42").version_label(), "42");
        assert_eq!(info("", "").version_label(), "");
    }

    /// Finder ships with every macOS and states all three keys.
    #[test]
    fn a_system_application_states_its_identity() {
        let info = read("/System/Library/CoreServices/Finder.app");
        assert_eq!(info.identifier, "com.apple.finder");
        assert!(!info.version.is_empty(), "{info:?}");
        assert!(!info.build.is_empty(), "{info:?}");
        assert_eq!(read("/usr/bin"), BundleInfo::default());
        assert_eq!(read("/nonexistent/Nothing.app"), BundleInfo::default());
    }
}
