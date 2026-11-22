//! GPU utilization: every accelerator's `PerformanceStatistics`, read from
//! the IOKit registry.

use std::collections::BTreeMap;

use super::SysError;
use super::cf;
use super::iokit::{IoHandle, matching_services, registry_entry_name, registry_property};

/// One GPU's registry identity and `PerformanceStatistics`: what
/// `ioreg -r -c IOAccelerator -l` prints for each accelerator.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct GpuStatistics {
    /// IORegistry entry name, such as `AGXAcceleratorG16X`.
    pub(crate) name: String,
    /// The accelerator's `model` property (`Apple M4 Pro`) when it has one.
    pub(crate) model: Option<String>,
    /// Every numeric `PerformanceStatistics` entry, keyed as the driver
    /// publishes it (`Device Utilization %`, `Renderer Utilization %`, …).
    /// Utilization counters are optional: virtual GPUs may expose only memory
    /// and recovery statistics, regardless of the host CPU architecture.
    pub(crate) performance: BTreeMap<String, f64>,
}

/// Statistics for every `IOAccelerator` service (one per GPU driver
/// instance), read from the IOKit registry without a child process. An
/// empty list means the Mac publishes no accelerator.
pub(crate) fn gpu_statistics() -> Result<Vec<GpuStatistics>, SysError> {
    Ok(matching_services(c"IOAccelerator")?
        .iter()
        .map(accelerator_statistics)
        .collect())
}

fn accelerator_statistics(service: &IoHandle) -> GpuStatistics {
    let name = registry_entry_name(service);
    let model = registry_property(service, "model")
        // SAFETY: a live property value owned by `Owned`.
        .and_then(|value| unsafe { cf::as_text(value.as_ptr()) });
    let performance = registry_property(service, "PerformanceStatistics")
        // SAFETY: a live property value owned by `Owned`.
        .map(|value| unsafe { cf::numeric_entries(value.as_ptr()) })
        .unwrap_or_default();
    GpuStatistics {
        name,
        model,
        performance,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_statistics_read_the_accelerator_registry() {
        let accelerators = gpu_statistics().expect("IOKit registry");
        for accelerator in &accelerators {
            assert!(!accelerator.name.is_empty(), "{accelerator:?}");
            assert!(
                accelerator
                    .performance
                    .values()
                    .all(|value| value.is_finite()),
                "{accelerator:?}"
            );
            if let Some(utilization) = accelerator.performance.get("Device Utilization %") {
                assert!((0.0..=100.0).contains(utilization), "{accelerator:?}");
            }
        }
    }
}
