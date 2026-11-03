//! CoreFoundation glue for the framework readers (`sys::gpu_statistics`,
//! `sys::power_sources`, `sys::smart_battery`, …). Crate-private: plugins
//! only ever see owned Rust values, and every CF reference created here is
//! released by [`Owned`].

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::ptr;

pub(crate) type CFTypeRef = *const c_void;
type CFIndex = isize;
type Boolean = u8;

#[repr(C)]
#[derive(Clone, Copy)]
struct CFRange {
    location: CFIndex,
    length: CFIndex,
}

const STRING_ENCODING_UTF8: u32 = 0x0800_0100;
const NUMBER_SINT64_TYPE: CFIndex = 4;
const NUMBER_FLOAT64_TYPE: CFIndex = 6;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFDataGetTypeID() -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFArrayGetTypeID() -> usize;

    fn CFStringCreateWithBytes(
        allocator: CFTypeRef,
        bytes: *const u8,
        length: CFIndex,
        encoding: u32,
        is_external_representation: Boolean,
    ) -> CFTypeRef;
    fn CFStringGetLength(string: CFTypeRef) -> CFIndex;
    fn CFStringGetBytes(
        string: CFTypeRef,
        range: CFRange,
        encoding: u32,
        loss_byte: u8,
        is_external_representation: Boolean,
        buffer: *mut u8,
        max_buffer_length: CFIndex,
        used_buffer_length: *mut CFIndex,
    ) -> CFIndex;
    fn CFNumberGetValue(number: CFTypeRef, number_type: CFIndex, value: *mut c_void) -> Boolean;
    fn CFDataGetLength(data: CFTypeRef) -> CFIndex;
    fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
    fn CFBooleanGetValue(boolean: CFTypeRef) -> Boolean;
    fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
    fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFDictionaryGetCount(dictionary: CFTypeRef) -> CFIndex;
    fn CFDictionaryGetKeysAndValues(
        dictionary: CFTypeRef,
        keys: *mut CFTypeRef,
        values: *mut CFTypeRef,
    );
}

/// A +1 reference from a CF Create/Copy function, released on drop.
pub(crate) struct Owned(CFTypeRef);

impl Owned {
    /// # Safety
    /// `reference` is null or a CF object the caller owns (Create/Copy rule)
    /// and hands over to the returned value.
    pub(crate) unsafe fn new(reference: CFTypeRef) -> Option<Self> {
        // Never build `Self(null)`, even transiently: dropping it would
        // release NULL, which traps.
        if reference.is_null() {
            None
        } else {
            Some(Self(reference))
        }
    }

    pub(crate) fn as_ptr(&self) -> CFTypeRef {
        self.0
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: `Owned` holds exactly one reference, released once here.
        unsafe { CFRelease(self.0) }
    }
}

/// A new CFString holding `value`.
pub(crate) fn string(value: &str) -> Option<Owned> {
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

/// # Safety
/// `value` is null or a live CF object.
unsafe fn is_type(value: CFTypeRef, type_id: usize) -> bool {
    // SAFETY: the caller guarantees a live object when non-null.
    !value.is_null() && unsafe { CFGetTypeID(value) } == type_id
}

/// The UTF-8 contents of a CFString.
///
/// # Safety
/// `string` is a live CFString.
unsafe fn string_contents(string: CFTypeRef) -> Option<String> {
    let range = CFRange {
        location: 0,
        // SAFETY: the caller guarantees a live CFString.
        length: unsafe { CFStringGetLength(string) },
    };
    let mut needed: CFIndex = 0;
    // SAFETY: a null buffer asks for the encoded length only.
    unsafe {
        CFStringGetBytes(
            string,
            range,
            STRING_ENCODING_UTF8,
            0,
            0,
            ptr::null_mut(),
            0,
            &mut needed,
        )
    };
    let mut buffer = vec![0u8; usize::try_from(needed).ok()?];
    let mut used: CFIndex = 0;
    // SAFETY: `buffer` holds the `needed` bytes measured above.
    let converted = unsafe {
        CFStringGetBytes(
            string,
            range,
            STRING_ENCODING_UTF8,
            0,
            0,
            buffer.as_mut_ptr(),
            needed,
            &mut used,
        )
    };
    if converted != range.length {
        return None;
    }
    buffer.truncate(usize::try_from(used).ok()?);
    String::from_utf8(buffer).ok()
}

/// A CFString's contents, or `None` for any other type.
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn as_string(value: CFTypeRef) -> Option<String> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFStringGetTypeID()) } {
        return None;
    }
    // SAFETY: `value` is a live CFString.
    unsafe { string_contents(value) }
}

/// Text from a CFString, or from CFData holding NUL-terminated UTF-8 (how
/// some drivers publish `model`).
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn as_text(value: CFTypeRef) -> Option<String> {
    // SAFETY: forwarded caller guarantee.
    if let Some(text) = unsafe { as_string(value) } {
        return Some(text);
    }
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFDataGetTypeID()) } {
        return None;
    }
    // SAFETY: `value` is a live CFData; its byte pointer is valid for its length.
    let bytes = unsafe {
        let length = usize::try_from(CFDataGetLength(value)).ok()?;
        let start = CFDataGetBytePtr(value);
        if length == 0 || start.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts(start, length)
        }
    };
    let text = bytes.split(|byte| *byte == 0).next().unwrap_or_default();
    std::str::from_utf8(text).ok().map(ToOwned::to_owned)
}

/// A CFNumber as `f64`, or `None` for any other type.
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn as_f64(value: CFTypeRef) -> Option<f64> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFNumberGetTypeID()) } {
        return None;
    }
    let mut number = 0f64;
    // SAFETY: `value` is a live CFNumber and `number` holds one float64.
    // A `false` return only flags a lossy conversion, which is acceptable.
    unsafe {
        CFNumberGetValue(
            value,
            NUMBER_FLOAT64_TYPE,
            (&mut number as *mut f64).cast::<c_void>(),
        )
    };
    Some(number)
}

/// The string-keyed numeric entries of a CFDictionary; other keys and
/// values (nested dictionaries, strings, data) are skipped.
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn numeric_entries(value: CFTypeRef) -> BTreeMap<String, f64> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFDictionaryGetTypeID()) } {
        return BTreeMap::new();
    }
    // SAFETY: `value` is a live CFDictionary.
    let count = usize::try_from(unsafe { CFDictionaryGetCount(value) }).unwrap_or(0);
    let mut keys: Vec<CFTypeRef> = vec![ptr::null(); count];
    let mut values: Vec<CFTypeRef> = vec![ptr::null(); count];
    // SAFETY: both buffers hold `count` entries; the references are borrowed
    // from the dictionary, which outlives this call.
    unsafe { CFDictionaryGetKeysAndValues(value, keys.as_mut_ptr(), values.as_mut_ptr()) };
    keys.into_iter()
        .zip(values)
        .filter_map(|(key, value)| {
            // SAFETY: borrowed entries of the live dictionary.
            let key = unsafe { as_string(key) }?;
            // SAFETY: as above.
            let number = unsafe { as_f64(value) }?;
            Some((key, number))
        })
        .collect()
}

/// A CFNumber as `i64` (a fraction truncates toward zero), or `None` for any
/// other type.
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn as_i64(value: CFTypeRef) -> Option<i64> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFNumberGetTypeID()) } {
        return None;
    }
    let mut number = 0i64;
    // SAFETY: `value` is a live CFNumber and `number` holds one SInt64.
    // A `false` return only flags a lossy conversion (a truncated fraction).
    unsafe {
        CFNumberGetValue(
            value,
            NUMBER_SINT64_TYPE,
            (&mut number as *mut i64).cast::<c_void>(),
        )
    };
    Some(number)
}

/// A CFBoolean's value, or `None` for any other type.
///
/// # Safety
/// `value` is null or a live CF object.
pub(crate) unsafe fn as_bool(value: CFTypeRef) -> Option<bool> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(value, CFBooleanGetTypeID()) } {
        return None;
    }
    // SAFETY: `value` is a live CFBoolean.
    Some(unsafe { CFBooleanGetValue(value) } != 0)
}

/// The value a CFDictionary stores under the string `key`, borrowed from the
/// dictionary (Get rule); null when the key is absent or `dictionary` is not
/// a dictionary.
///
/// # Safety
/// `dictionary` is null or a live CF object; the result lives only as long
/// as the dictionary.
pub(crate) unsafe fn dictionary_value(dictionary: CFTypeRef, key: &str) -> CFTypeRef {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(dictionary, CFDictionaryGetTypeID()) } {
        return ptr::null();
    }
    let Some(key) = string(key) else {
        return ptr::null();
    };
    // SAFETY: both are live; the value is borrowed from the dictionary.
    unsafe { CFDictionaryGetValue(dictionary, key.as_ptr()) }
}

/// The elements of a CFArray, borrowed from it (Get rule); empty for any
/// other type.
///
/// # Safety
/// `array` is null or a live CF object; the elements live only as long as
/// the array.
pub(crate) unsafe fn array_values(array: CFTypeRef) -> Vec<CFTypeRef> {
    // SAFETY: a type query on a null-or-live object (caller guarantee).
    if !unsafe { is_type(array, CFArrayGetTypeID()) } {
        return Vec::new();
    }
    // SAFETY: `array` is a live CFArray.
    let count = unsafe { CFArrayGetCount(array) };
    (0..count)
        // SAFETY: every index is inside the live array's bounds.
        .map(|index| unsafe { CFArrayGetValueAtIndex(array, index) })
        .collect()
}

/// Owned CF values for tests that feed the readers synthetic registry and
/// power-source dictionaries.
#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFTypeDictionaryKeyCallBacks: c_void;
        static kCFTypeDictionaryValueCallBacks: c_void;
        static kCFTypeArrayCallBacks: c_void;
        static kCFBooleanTrue: CFTypeRef;
        static kCFBooleanFalse: CFTypeRef;
        fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
        fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: CFIndex) -> CFTypeRef;
        fn CFNumberCreate(
            allocator: CFTypeRef,
            number_type: CFIndex,
            value: *const c_void,
        ) -> CFTypeRef;
        fn CFArrayCreate(
            allocator: CFTypeRef,
            values: *const CFTypeRef,
            count: CFIndex,
            callbacks: *const c_void,
        ) -> CFTypeRef;
        fn CFDictionaryCreate(
            allocator: CFTypeRef,
            keys: *const CFTypeRef,
            values: *const CFTypeRef,
            count: CFIndex,
            key_callbacks: *const c_void,
            value_callbacks: *const c_void,
        ) -> CFTypeRef;
    }

    pub(crate) fn text(value: &str) -> Owned {
        string(value).expect("CFString")
    }

    pub(crate) fn data(bytes: &[u8]) -> Owned {
        // SAFETY: `bytes` is valid for its length; the result is +1.
        unsafe {
            Owned::new(CFDataCreate(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len() as CFIndex,
            ))
        }
        .expect("CFData")
    }

    pub(crate) fn integer(value: i64) -> Owned {
        // SAFETY: `value` is one SInt64; the result is +1.
        unsafe {
            Owned::new(CFNumberCreate(
                ptr::null(),
                NUMBER_SINT64_TYPE,
                (&value as *const i64).cast::<c_void>(),
            ))
        }
        .expect("CFNumber")
    }

    pub(crate) fn float(value: f64) -> Owned {
        // SAFETY: `value` is one Float64; the result is +1.
        unsafe {
            Owned::new(CFNumberCreate(
                ptr::null(),
                NUMBER_FLOAT64_TYPE,
                (&value as *const f64).cast::<c_void>(),
            ))
        }
        .expect("CFNumber")
    }

    pub(crate) fn boolean(value: bool) -> Owned {
        // SAFETY: the CFBoolean singletons are immortal; the retain makes
        // the reference ours to release.
        unsafe {
            let singleton = if value {
                kCFBooleanTrue
            } else {
                kCFBooleanFalse
            };
            Owned::new(CFRetain(singleton))
        }
        .expect("CFBoolean")
    }

    pub(crate) fn array(values: &[&Owned]) -> Owned {
        let values: Vec<CFTypeRef> = values.iter().map(|value| value.as_ptr()).collect();
        // SAFETY: `values` holds live CF objects the CFType callbacks retain;
        // the result is +1.
        unsafe {
            Owned::new(CFArrayCreate(
                ptr::null(),
                values.as_ptr(),
                values.len() as CFIndex,
                &raw const kCFTypeArrayCallBacks,
            ))
        }
        .expect("CFArray")
    }

    pub(crate) fn dictionary(entries: &[(&Owned, &Owned)]) -> Owned {
        let keys: Vec<CFTypeRef> = entries.iter().map(|(key, _)| key.as_ptr()).collect();
        let values: Vec<CFTypeRef> = entries.iter().map(|(_, value)| value.as_ptr()).collect();
        // SAFETY: both arrays hold `entries.len()` live CF objects; the
        // CFType callbacks retain them, and the result is +1.
        unsafe {
            Owned::new(CFDictionaryCreate(
                ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                entries.len() as CFIndex,
                &raw const kCFTypeDictionaryKeyCallBacks,
                &raw const kCFTypeDictionaryValueCallBacks,
            ))
        }
        .expect("CFDictionary")
    }

    /// A dictionary keyed by strings, the shape every registry and
    /// power-source table uses.
    pub(crate) fn table(entries: &[(&str, Owned)]) -> Owned {
        let keys: Vec<Owned> = entries.iter().map(|(key, _)| text(key)).collect();
        let pairs: Vec<(&Owned, &Owned)> = keys
            .iter()
            .zip(entries.iter().map(|(_, value)| value))
            .collect();
        dictionary(&pairs)
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;

    #[test]
    fn strings_round_trip_and_reject_other_types() {
        for value in ["", "plain", "Apple M4 Pro", "日本語 😀", "nul\0inside"] {
            let string = string(value).expect("CFString");
            // SAFETY: live CF objects created above.
            unsafe {
                assert_eq!(as_string(string.as_ptr()).as_deref(), Some(value));
                assert_eq!(as_text(string.as_ptr()).as_deref(), Some(value));
                assert_eq!(as_f64(string.as_ptr()), None);
                assert!(numeric_entries(string.as_ptr()).is_empty());
            }
        }
        // SAFETY: null is an accepted input everywhere.
        unsafe {
            assert_eq!(as_string(ptr::null()), None);
            assert_eq!(as_text(ptr::null()), None);
            assert_eq!(as_f64(ptr::null()), None);
            assert!(numeric_entries(ptr::null()).is_empty());
        }
    }

    #[test]
    fn data_text_stops_at_the_first_nul_and_requires_utf8() {
        // SAFETY: live CFData objects.
        unsafe {
            assert_eq!(
                as_text(data(b"AMD Radeon Pro 5500M\0\0").as_ptr()).as_deref(),
                Some("AMD Radeon Pro 5500M")
            );
            assert_eq!(
                as_text(data(b"no terminator").as_ptr()).as_deref(),
                Some("no terminator")
            );
            assert_eq!(as_text(data(b"").as_ptr()).as_deref(), Some(""));
            assert_eq!(as_text(data(b"\xff\xfe").as_ptr()), None);
            assert_eq!(as_string(data(b"text").as_ptr()), None);
        }
    }

    #[test]
    fn numeric_entries_keep_string_keyed_numbers_only() {
        let device = string("Device Utilization %").unwrap();
        let renderer = string("Renderer Utilization %").unwrap();
        let label = string("label").unwrap();
        let fifty_nine = integer(59);
        let forty_seven = integer(47);
        let text = string("not a number").unwrap();
        let numeric_key = integer(1);
        let nested = dictionary(&[(&device, &fifty_nine)]);
        let nested_key = string("nested").unwrap();
        let statistics = dictionary(&[
            (&device, &fifty_nine),
            (&renderer, &forty_seven),
            (&label, &text),
            (&numeric_key, &forty_seven),
            (&nested_key, &nested),
        ]);
        // SAFETY: live CF objects created above.
        let entries = unsafe { numeric_entries(statistics.as_ptr()) };
        assert_eq!(
            entries,
            BTreeMap::from([
                ("Device Utilization %".to_string(), 59.0),
                ("Renderer Utilization %".to_string(), 47.0),
            ])
        );
        // SAFETY: as above.
        assert_eq!(unsafe { as_f64(fifty_nine.as_ptr()) }, Some(59.0));
    }

    #[test]
    fn integers_and_booleans_read_only_their_own_types() {
        let large = integer(1_700_000_000_000);
        let negative = integer(-1);
        let fraction = float(79.6);
        let yes = boolean(true);
        let no = boolean(false);
        let word = text("true");
        // SAFETY: live CF objects created above, or null.
        unsafe {
            assert_eq!(as_i64(large.as_ptr()), Some(1_700_000_000_000));
            assert_eq!(as_i64(negative.as_ptr()), Some(-1));
            assert_eq!(as_i64(fraction.as_ptr()), Some(79), "fractions truncate");
            assert_eq!(as_i64(yes.as_ptr()), None);
            assert_eq!(as_i64(word.as_ptr()), None);
            assert_eq!(as_i64(ptr::null()), None);
            assert_eq!(as_bool(yes.as_ptr()), Some(true));
            assert_eq!(as_bool(no.as_ptr()), Some(false));
            assert_eq!(as_bool(large.as_ptr()), None);
            assert_eq!(as_bool(word.as_ptr()), None);
            assert_eq!(as_bool(ptr::null()), None);
        }
    }

    #[test]
    fn dictionary_values_and_array_elements_are_borrowed_by_key_and_index() {
        let adapter = table(&[("Watts", integer(85)), ("Name", text("USB-C"))]);
        let sources = array(&[&integer(1), &text("two"), &adapter]);
        let properties = table(&[
            ("CycleCount", integer(255)),
            ("AdapterDetails", adapter),
            ("Sources", sources),
        ]);
        // SAFETY: live CF objects created above; borrowed values are used
        // while `properties` lives.
        unsafe {
            let cycles = dictionary_value(properties.as_ptr(), "CycleCount");
            assert_eq!(as_i64(cycles), Some(255));
            let details = dictionary_value(properties.as_ptr(), "AdapterDetails");
            assert_eq!(as_i64(dictionary_value(details, "Watts")), Some(85));
            assert!(dictionary_value(properties.as_ptr(), "Missing").is_null());
            assert!(
                dictionary_value(cycles, "Watts").is_null(),
                "not a dictionary"
            );
            assert!(dictionary_value(ptr::null(), "Watts").is_null());

            let elements = array_values(dictionary_value(properties.as_ptr(), "Sources"));
            assert_eq!(elements.len(), 3);
            assert_eq!(as_i64(elements[0]), Some(1));
            assert_eq!(as_string(elements[1]).as_deref(), Some("two"));
            assert_eq!(as_i64(dictionary_value(elements[2], "Watts")), Some(85));
            assert!(array_values(properties.as_ptr()).is_empty(), "not an array");
            assert!(array_values(ptr::null()).is_empty());
            assert!(array_values(array(&[]).as_ptr()).is_empty());
        }
    }
}
