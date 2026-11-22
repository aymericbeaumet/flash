//! CPU load: cumulative scheduler ticks (`host_processor_info`, what
//! `iostat` samples) and the load averages (`getloadavg`).

use std::mem;
use std::ptr;

use super::SysError;

/// Cumulative scheduler ticks summed over every core.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct CpuTicks {
    pub(crate) user: u64,
    pub(crate) system: u64,
    pub(crate) idle: u64,
    pub(crate) nice: u64,
}

/// Share of the ticks accumulated between two samples, in percent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct CpuPercentages {
    /// User plus nice, matching `iostat`'s `us` column.
    pub(crate) user: f64,
    pub(crate) system: f64,
    pub(crate) idle: f64,
}

impl CpuTicks {
    /// Percentages over the interval from `previous` to `self`; `None` when no
    /// tick elapsed or a counter went backwards (reboot-scale wrap).
    pub(crate) fn percentages_since(&self, previous: &CpuTicks) -> Option<CpuPercentages> {
        let user = self.user.checked_sub(previous.user)?;
        let nice = self.nice.checked_sub(previous.nice)?;
        let system = self.system.checked_sub(previous.system)?;
        let idle = self.idle.checked_sub(previous.idle)?;
        let total = user + nice + system + idle;
        if total == 0 {
            return None;
        }
        let percent = |value: u64| value as f64 / total as f64 * 100.0;
        Some(CpuPercentages {
            user: percent(user + nice),
            system: percent(system),
            idle: percent(idle),
        })
    }
}

/// Current cumulative CPU ticks across all cores (`host_processor_info`).
// libc deprecates `mach_host_self` / `mach_task_self` in favour of the `mach2`
// crate; one more dependency for two symbols is not worth it here.
#[allow(deprecated)]
pub(crate) fn cpu_ticks() -> Result<CpuTicks, SysError> {
    let mut cpu_count: libc::natural_t = 0;
    let mut info: libc::processor_info_array_t = ptr::null_mut();
    let mut info_count: libc::mach_msg_type_number_t = 0;
    // SAFETY: every out-pointer targets a live local; the kernel allocates
    // `info` in this task and it is released below.
    let status = unsafe {
        libc::host_processor_info(
            libc::mach_host_self(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut cpu_count,
            &mut info,
            &mut info_count,
        )
    };
    if status != libc::KERN_SUCCESS || info.is_null() {
        return Err(SysError(format!(
            "host_processor_info failed with status {status}"
        )));
    }
    let states = libc::CPU_STATE_MAX as usize;
    // SAFETY: the kernel filled `info_count` integers at `info`.
    let values = unsafe { std::slice::from_raw_parts(info.cast_const(), info_count as usize) };
    let mut ticks = CpuTicks::default();
    for cpu in 0..cpu_count as usize {
        let base = cpu * states;
        if base + states > values.len() {
            break;
        }
        let tick = |state: libc::c_int| values[base + state as usize] as u32 as u64;
        ticks.user += tick(libc::CPU_STATE_USER);
        ticks.system += tick(libc::CPU_STATE_SYSTEM);
        ticks.idle += tick(libc::CPU_STATE_IDLE);
        ticks.nice += tick(libc::CPU_STATE_NICE);
    }
    // SAFETY: releases exactly the buffer host_processor_info handed us.
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            (info_count as usize * mem::size_of::<libc::integer_t>()) as libc::vm_size_t,
        );
    }
    Ok(ticks)
}

unsafe extern "C" {
    fn getloadavg(loadavg: *mut f64, nelem: libc::c_int) -> libc::c_int;
}

/// The 1, 5, and 15 minute load averages.
pub(crate) fn load_averages() -> Result<[f64; 3], SysError> {
    let mut out = [0f64; 3];
    // SAFETY: `out` holds the three doubles requested.
    let filled = unsafe { getloadavg(out.as_mut_ptr(), 3) };
    if filled != 3 {
        return Err(SysError(format!("getloadavg returned {filled}")));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_ticks_advance_and_percentages_sum_to_one_hundred() {
        let first = cpu_ticks().expect("ticks");
        std::thread::sleep(std::time::Duration::from_millis(30));
        let second = cpu_ticks().expect("ticks");
        let total = |ticks: &CpuTicks| ticks.user + ticks.system + ticks.idle + ticks.nice;
        assert!(total(&second) >= total(&first));
        let percentages = second.percentages_since(&first).expect("elapsed ticks");
        let sum = percentages.user + percentages.system + percentages.idle;
        assert!((sum - 100.0).abs() < 0.01, "sum {sum}");
        assert!(second.percentages_since(&second).is_none());
        assert!(
            first.percentages_since(&second).is_none(),
            "backwards counters reject"
        );
    }

    #[test]
    fn load_averages_are_finite_and_non_negative() {
        let load = load_averages().expect("load");
        assert!(load.iter().all(|value| value.is_finite() && *value >= 0.0));
    }
}
