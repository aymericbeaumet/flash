//! The process tree, for a plugin that runs outside the sandbox.
//!
//! A fork and exec can stall for seconds while macOS's exec policy daemon is
//! busy, so a plugin that maps a terminal to its tmux client reads every
//! process's parent through libproc here instead of spawning `ps`. No
//! sandbox profile opens another process, the pid list included: under one
//! this answers an error, and a sandboxed plugin asks the host
//! (`Context::processes`, `host.process_table`). As with `process.rs` and
//! `runtime.rs`, the unsafe FFI stays inside the SDK; readers only one
//! plugin uses live in that plugin (the `sysinfo` monitors' kernel and
//! IOKit samplers are `Plugins/sysinfo/src/sys/`).

use std::fmt;
use std::mem;
use std::ptr;

/// A failed kernel query, carrying the call and status for the log line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SysError(String);

impl fmt::Display for SysError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SysError {}

/// Every visible pid, in the kernel's order: what `ps -axo pid=` prints, read
/// through libproc without a fork.
fn process_ids() -> Result<Vec<i32>, SysError> {
    // SAFETY: a null buffer asks for the current pid count.
    let count = unsafe { libc::proc_listallpids(ptr::null_mut(), 0) };
    if count <= 0 {
        return Err(SysError(format!("proc_listallpids returned {count}")));
    }
    // Headroom for processes started between the two calls.
    let mut pids = vec![0 as libc::pid_t; count as usize + 64];
    let bytes = (pids.len() * mem::size_of::<libc::pid_t>()) as libc::c_int;
    // SAFETY: `pids` is `bytes` long; the call returns how many pids it wrote.
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast::<libc::c_void>(), bytes) };
    if filled <= 0 {
        return Err(SysError(format!("proc_listallpids returned {filled}")));
    }
    pids.truncate((filled as usize).min(pids.len()));
    pids.retain(|pid| *pid > 0);
    Ok(pids)
}

/// Every visible process with its parent, as `(pid, ppid)`: what
/// `ps -axo pid=,ppid=` prints, read through libproc without a fork.
/// `PROC_PIDT_SHORTBSDINFO` is the flavor the kernel answers across users, so
/// root-owned ancestors such as `login` keep the tree connected. A process
/// that exits between the listing and its read is skipped. Only an
/// unsandboxed plugin can call it: a plugin's profile denies the pid list
/// and every other process.
pub fn process_parents() -> Result<Vec<(i32, i32)>, SysError> {
    let size = mem::size_of::<libc::proc_bsdshortinfo>() as libc::c_int;
    Ok(process_ids()?
        .into_iter()
        .filter_map(|pid| {
            // SAFETY: proc_bsdshortinfo is a plain C struct; zeroed is a valid buffer.
            let mut info: libc::proc_bsdshortinfo = unsafe { mem::zeroed() };
            // SAFETY: the buffer is exactly `size` bytes long.
            let written = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDT_SHORTBSDINFO,
                    0,
                    (&mut info as *mut libc::proc_bsdshortinfo).cast::<libc::c_void>(),
                    size,
                )
            };
            (written == size).then_some((pid, info.pbsi_ppid as i32))
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_ids_list_this_process_and_launchd_once_each() {
        let pids = process_ids().expect("pid list");
        let own = std::process::id() as i32;
        assert_eq!(pids.iter().filter(|pid| **pid == own).count(), 1);
        assert_eq!(pids.iter().filter(|pid| **pid == 1).count(), 1);
        assert!(pids.iter().all(|pid| *pid > 0), "no kernel placeholder");
    }

    #[test]
    fn process_parents_match_this_process_and_launchd() {
        let parents = process_parents().expect("process table");
        let own = std::process::id() as i32;
        let parent = std::os::unix::process::parent_id() as i32;
        assert!(parents.contains(&(own, parent)), "own pid {own}");
        assert!(parents.contains(&(1, 0)), "launchd is visible across users");
    }
}
