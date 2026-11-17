//! Battery and power-source state: IOPowerSources (what `pmset -g batt`
//! prints) and the `AppleSmartBattery` registry entry (what
//! `ioreg -r -c AppleSmartBattery -l` prints).

use super::{SysError, matching_services, registry_properties};
use crate::cf;

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> cf::CFTypeRef;
    fn IOPSCopyPowerSourcesList(blob: cf::CFTypeRef) -> cf::CFTypeRef;
    fn IOPSGetPowerSourceDescription(blob: cf::CFTypeRef, source: cf::CFTypeRef) -> cf::CFTypeRef;
    fn IOPSGetProvidingPowerSourceType(blob: cf::CFTypeRef) -> cf::CFTypeRef;
}

/// The power-source snapshot `pmset -g batt` prints: what powers the Mac,
/// and every internal battery or UPS macOS reports, in its order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PowerSources {
    /// `AC Power`, `Battery Power` or `UPS Power`
    /// (`IOPSGetProvidingPowerSourceType`); `None` when macOS names none.
    pub providing: Option<String>,
    /// One description per internal battery or UPS; empty on a Mac with
    /// neither.
    pub sources: Vec<PowerSource>,
}

/// One power source's description (`IOPSGetPowerSourceDescription`). A field
/// is `None` when the source does not publish it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PowerSource {
    /// `Power Source State`: `AC Power`, `Battery Power` or `Off Line`.
    pub state: Option<String>,
    /// `Current Capacity`, out of `Max Capacity` (percent on Apple batteries).
    pub current_capacity: Option<i64>,
    pub max_capacity: Option<i64>,
    /// `Is Charging`.
    pub is_charging: Option<bool>,
    /// `Is Charged`.
    pub is_charged: Option<bool>,
    /// `Is Finishing Charge`.
    pub is_finishing_charge: Option<bool>,
    /// `Time to Empty` in minutes; -1 while macOS is still estimating.
    pub time_to_empty: Option<i64>,
    /// `Time to Full Charge` in minutes; -1 while macOS is still estimating.
    pub time_to_full_charge: Option<i64>,
}

/// The current power-source snapshot, from IOPowerSources (powerd's
/// `com.apple.PowerManagement.control` service).
pub fn power_sources() -> Result<PowerSources, SysError> {
    // SAFETY: a Copy-rule snapshot, released by `Owned`.
    let blob = unsafe { cf::Owned::new(IOPSCopyPowerSourcesInfo()) }
        .ok_or_else(|| SysError("IOPSCopyPowerSourcesInfo returned no snapshot".into()))?;
    // SAFETY: `blob` is live; the type string is borrowed from it.
    let providing = unsafe { cf::as_string(IOPSGetProvidingPowerSourceType(blob.as_ptr())) };
    // SAFETY: `blob` is live; the list is a +1 array released by `Owned`.
    let list = unsafe { cf::Owned::new(IOPSCopyPowerSourcesList(blob.as_ptr())) };
    let sources = list
        .map(|list| {
            // SAFETY: the elements are borrowed from the live list.
            unsafe { cf::array_values(list.as_ptr()) }
                .into_iter()
                .filter_map(|source| {
                    // SAFETY: `blob` and `source` are live; the description
                    // is borrowed from `blob`.
                    let description =
                        unsafe { IOPSGetPowerSourceDescription(blob.as_ptr(), source) };
                    // SAFETY: a live description dictionary (or null, skipped).
                    (!description.is_null()).then(|| unsafe { power_source(description) })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(PowerSources { providing, sources })
}

/// # Safety
/// `description` is null or a live CF object.
unsafe fn power_source(description: cf::CFTypeRef) -> PowerSource {
    // SAFETY: values are borrowed from the live description (caller
    // guarantee) and read before this function returns.
    let value = |key: &str| unsafe { cf::dictionary_value(description, key) };
    // SAFETY: every value is null or a live CF object borrowed above.
    unsafe {
        PowerSource {
            state: cf::as_string(value("Power Source State")),
            current_capacity: cf::as_i64(value("Current Capacity")),
            max_capacity: cf::as_i64(value("Max Capacity")),
            is_charging: cf::as_bool(value("Is Charging")),
            is_charged: cf::as_bool(value("Is Charged")),
            is_finishing_charge: cf::as_bool(value("Is Finishing Charge")),
            time_to_empty: cf::as_i64(value("Time to Empty")),
            time_to_full_charge: cf::as_i64(value("Time to Full Charge")),
        }
    }
}

/// The `AppleSmartBattery` registry properties the power monitor shows. A
/// field is `None` when the battery does not publish it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SmartBattery {
    /// `CycleCount`.
    pub cycle_count: Option<i64>,
    /// `DesignCapacity`, in mAh.
    pub design_capacity: Option<i64>,
    /// `AppleRawMaxCapacity`: today's full-charge capacity, in mAh.
    pub raw_max_capacity: Option<i64>,
    /// `NominalChargeCapacity`, in mAh.
    pub nominal_charge_capacity: Option<i64>,
    /// `Temperature`, in hundredths of a degree Celsius.
    pub temperature: Option<i64>,
    /// `AdapterDetails` → `Watts`: the connected adapter's rating.
    pub adapter_watts: Option<i64>,
    /// `BatteryHealthCondition`, when macOS flags one.
    pub health_condition: Option<String>,
}

/// The first `AppleSmartBattery` service's properties, read from the IOKit
/// registry; `Ok(None)` on a Mac without a battery.
pub fn smart_battery() -> Result<Option<SmartBattery>, SysError> {
    let Some(service) = matching_services(c"AppleSmartBattery")?.into_iter().next() else {
        return Ok(None);
    };
    let properties = registry_properties(&service)
        .ok_or_else(|| SysError("AppleSmartBattery properties are unavailable".into()))?;
    // SAFETY: a live dictionary owned by `properties`.
    Ok(Some(unsafe { smart_battery_from(properties.as_ptr()) }))
}

/// Top-level keys only: `BatteryData` nests its own copies of some of them.
///
/// # Safety
/// `properties` is null or a live CF object.
unsafe fn smart_battery_from(properties: cf::CFTypeRef) -> SmartBattery {
    // SAFETY: values are borrowed from the live table (caller guarantee) and
    // read before this function returns.
    let value = |key: &str| unsafe { cf::dictionary_value(properties, key) };
    // SAFETY: every value is null or a live CF object borrowed above.
    unsafe {
        SmartBattery {
            cycle_count: cf::as_i64(value("CycleCount")),
            design_capacity: cf::as_i64(value("DesignCapacity")),
            raw_max_capacity: cf::as_i64(value("AppleRawMaxCapacity")),
            nominal_charge_capacity: cf::as_i64(value("NominalChargeCapacity")),
            temperature: cf::as_i64(value("Temperature")),
            adapter_watts: cf::as_i64(cf::dictionary_value(value("AdapterDetails"), "Watts")),
            health_condition: cf::as_string(value("BatteryHealthCondition")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cf::fixtures::*;

    #[test]
    fn power_source_descriptions_read_typed_fields() {
        let description = table(&[
            ("Power Source State", text("AC Power")),
            ("Current Capacity", integer(73)),
            ("Max Capacity", integer(100)),
            ("Is Charging", boolean(true)),
            ("Is Charged", boolean(false)),
            ("Is Finishing Charge", boolean(false)),
            ("Time to Empty", integer(0)),
            ("Time to Full Charge", integer(84)),
            ("Name", text("InternalBattery-0")),
        ]);
        // SAFETY: a live dictionary.
        assert_eq!(
            unsafe { power_source(description.as_ptr()) },
            PowerSource {
                state: Some("AC Power".into()),
                current_capacity: Some(73),
                max_capacity: Some(100),
                is_charging: Some(true),
                is_charged: Some(false),
                is_finishing_charge: Some(false),
                time_to_empty: Some(0),
                time_to_full_charge: Some(84),
            }
        );
    }

    #[test]
    fn power_source_fields_of_the_wrong_type_or_absent_read_as_none() {
        let description = table(&[
            ("Power Source State", integer(1)),
            ("Current Capacity", text("73")),
            ("Is Charging", integer(1)),
            ("Time to Empty", integer(-1)),
        ]);
        // SAFETY: a live dictionary, then null.
        unsafe {
            assert_eq!(
                power_source(description.as_ptr()),
                PowerSource {
                    time_to_empty: Some(-1),
                    ..PowerSource::default()
                }
            );
            assert_eq!(power_source(std::ptr::null()), PowerSource::default());
        }
    }

    #[test]
    fn smart_battery_reads_top_level_properties_and_the_adapter_rating() {
        let properties = table(&[
            ("CycleCount", integer(255)),
            ("DesignCapacity", integer(8579)),
            ("AppleRawMaxCapacity", integer(7328)),
            ("NominalChargeCapacity", integer(7572)),
            ("MaxCapacity", integer(100)),
            ("Temperature", integer(3013)),
            ("BatteryHealthCondition", text("Check Battery")),
            ("SerialNumber", text("SECRET")),
            (
                "AdapterDetails",
                table(&[("Watts", integer(85)), ("Name", text("USB-C"))]),
            ),
            (
                "BatteryData",
                table(&[("CycleCount", integer(9)), ("DesignCapacity", integer(1))]),
            ),
        ]);
        // SAFETY: a live dictionary.
        assert_eq!(
            unsafe { smart_battery_from(properties.as_ptr()) },
            SmartBattery {
                cycle_count: Some(255),
                design_capacity: Some(8579),
                raw_max_capacity: Some(7328),
                nominal_charge_capacity: Some(7572),
                temperature: Some(3013),
                adapter_watts: Some(85),
                health_condition: Some("Check Battery".into()),
            }
        );
    }

    #[test]
    fn smart_battery_without_an_adapter_or_condition_leaves_them_unset() {
        let properties = table(&[
            ("CycleCount", integer(3)),
            ("AdapterDetails", table(&[("FamilyCode", integer(0))])),
            ("BatteryHealthCondition", integer(0)),
        ]);
        // SAFETY: a live dictionary, then null.
        unsafe {
            assert_eq!(
                smart_battery_from(properties.as_ptr()),
                SmartBattery {
                    cycle_count: Some(3),
                    ..SmartBattery::default()
                }
            );
            assert_eq!(
                smart_battery_from(std::ptr::null()),
                SmartBattery::default()
            );
        }
    }

    /// Tolerant of the host: a laptop reports its battery, a desktop reports
    /// no source and no `AppleSmartBattery` service — never an error.
    #[test]
    fn power_sources_and_battery_registry_read_this_mac() {
        let snapshot = power_sources().expect("IOPowerSources");
        if let Some(providing) = snapshot.providing.as_deref() {
            assert!(
                ["AC Power", "Battery Power", "UPS Power"].contains(&providing),
                "{snapshot:?}"
            );
        }
        for source in &snapshot.sources {
            if let (Some(current), Some(maximum)) = (source.current_capacity, source.max_capacity) {
                assert!(
                    maximum > 0 && (0..=maximum).contains(&current),
                    "{source:?}"
                );
            }
        }
        let battery = smart_battery().expect("IOKit registry");
        let Some(battery) = battery else {
            return;
        };
        assert!(
            snapshot
                .sources
                .iter()
                .any(|source| source.current_capacity.is_some()),
            "a battery is listed as a power source: {snapshot:?}"
        );
        assert!(
            battery.design_capacity.is_some_and(|mah| mah > 0),
            "{battery:?}"
        );
        assert!(
            battery.cycle_count.is_some_and(|cycles| cycles >= 0),
            "{battery:?}"
        );
        if let Some(temperature) = battery.temperature {
            assert!((0..10_000).contains(&temperature), "{battery:?}");
        }
    }
}
