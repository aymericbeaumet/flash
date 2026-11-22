//! Native macOS system sampling for the status monitors.
//!
//! The monitors used to shell out (`iostat`, `vm_stat`, `sysctl`, `netstat`,
//! `pmset`, `df`, and `ioreg` for GPU, battery and disk statistics) — a
//! fork, an exec, three pipes, and a wait per sample, and an exec can stall
//! for seconds while macOS's exec policy daemon is busy. These readers use
//! the kernel and framework interfaces those tools read themselves:
//! `host_processor_info`, `host_statistics64`, `sysctlbyname`, the
//! `NET_RT_IFLIST2` and `NET_RT_DUMP2` routing sysctls, the IOKit registry,
//! IOPowerSources, and `getfsstat`/`statfs`. Each call takes microseconds
//! and never blocks on a child. The unsafe FFI stays inside this module; the
//! domains call the safe wrappers. Only this plugin reads these interfaces,
//! so they live here rather than in the SDK, whose `flash_plugin::sys` keeps
//! what several plugins share.

use std::fmt;

mod cf;
mod cpu;
mod gpu;
mod interfaces;
mod iokit;
mod memory;
mod power;
mod routes;
mod storage;
mod sysctl;

pub(crate) use cpu::{CpuTicks, cpu_ticks, load_averages};
pub(crate) use gpu::{GpuStatistics, gpu_statistics};
pub(crate) use interfaces::interface_counters;
pub(crate) use memory::{MemoryStats, memory_stats};
// The power domain reads a source through `PowerSources::sources`; only its
// tests name the type.
#[cfg(test)]
pub(crate) use power::PowerSource;
pub(crate) use power::{PowerSources, SmartBattery, power_sources, smart_battery};
pub(crate) use routes::{DefaultRoute, RouteFamily, default_routes};
pub(crate) use storage::{
    BlockStorageStatistics, LocalVolume, block_storage_statistics, local_volumes,
};

/// A failed kernel query, carrying the call and status for the log line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SysError(String);

impl fmt::Display for SysError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SysError {}
