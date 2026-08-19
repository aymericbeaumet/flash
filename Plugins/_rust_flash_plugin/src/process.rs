//! Process primitives: bounded subprocess capture (the low-level layer under
//! the SDK's [`run_command`](crate::run_command), public for plugins whose
//! invocation shape the high-level runner cannot express — tmux builds its
//! own `Command` with a deliberately unsandboxed environment and custom
//! output budgets), plus a libproc-backed process-table sampler and signal
//! sender so plugins never need `/bin/ps` or `/bin/kill` subprocesses (both
//! hostile to a deny-default seatbelt profile; ps is setgid).
//!
//! For capture, both output streams are drained concurrently. A timeout, a
//! read failure, or either stream exceeding its byte budget kills the
//! subprocess's entire process group so descendants cannot retain the pipes
//! and strand the plugin.

use std::collections::HashMap;
use std::io;
use std::process::ExitStatus;
use std::sync::LazyLock;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::task::JoinHandle;

/// One row of the system process table, sampled via libproc. Processes the
/// kernel hides from this uid are skipped — exactly the set the caller
/// could neither inspect nor signal anyway.
#[derive(Clone, Debug)]
pub struct ProcessSample {
    pub pid: i32,
    /// Executable basename from `proc_pidpath` (e.g. "Google Chrome").
    pub comm: String,
    /// Instantaneous CPU percent over the sample window.
    pub cpu_percent: f32,
    /// Resident memory as a percent of physical RAM.
    pub mem_percent: f32,
}

/// List visible processes with an instantaneous CPU measurement over
/// `sample_window` (two libproc rusage snapshots bracketing an async
/// sleep — the syscalls themselves are microseconds, so nothing blocks the
/// runtime). Requires the `process_info` sandbox allowance.
pub async fn list_processes(sample_window: Duration) -> Vec<ProcessSample> {
    let first: HashMap<i32, u64> = all_pids()
        .into_iter()
        .filter_map(|pid| Some((pid, rusage(pid)?.cpu_ns)))
        .collect();
    tokio::time::sleep(sample_window).await;
    let window_ns = sample_window.as_nanos().max(1) as f64;
    let total_memory = physical_memory_bytes().max(1) as f64;
    let mut rows = Vec::new();
    for pid in all_pids() {
        let Some(usage) = rusage(pid) else { continue };
        let Some(comm) = executable_basename(pid) else {
            continue;
        };
        let cpu_percent = first
            .get(&pid)
            .map(|&previous| {
                let delta = usage.cpu_ns.saturating_sub(previous) as f64;
                ((delta / window_ns) * 100.0) as f32
            })
            .unwrap_or(0.0);
        rows.push(ProcessSample {
            pid,
            comm,
            cpu_percent,
            mem_percent: ((usage.resident_bytes as f64 / total_memory) * 100.0) as f32,
        });
    }
    rows
}

/// Send SIGTERM without a `/bin/kill` subprocess. Errors carry the OS
/// message (EPERM: not this uid's process; ESRCH: already gone). Requires
/// the `signal` sandbox allowance.
pub fn terminate_pid(pid: i32) -> io::Result<()> {
    // Safety: kill(2) takes a plain pid + signal number; no memory crosses
    // the boundary.
    if unsafe { libc::kill(pid, libc::SIGTERM) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

struct PidUsage {
    cpu_ns: u64,
    resident_bytes: u64,
}

fn all_pids() -> Vec<i32> {
    // Safety: first call sizes the table, second fills a buffer we own; the
    // kernel may report more pids between the calls, so over-allocate.
    unsafe {
        let count = libc::proc_listallpids(std::ptr::null_mut(), 0);
        if count <= 0 {
            return Vec::new();
        }
        let capacity = (count as usize) + 64;
        let mut pids = vec![0 as libc::c_int; capacity];
        let filled = libc::proc_listallpids(
            pids.as_mut_ptr().cast(),
            (capacity * std::mem::size_of::<libc::c_int>()) as libc::c_int,
        );
        if filled <= 0 {
            return Vec::new();
        }
        pids.truncate(filled as usize);
        pids.retain(|&pid| pid > 0);
        pids
    }
}

fn rusage(pid: i32) -> Option<PidUsage> {
    // Safety: proc_pid_rusage fills the struct we own; RUSAGE_INFO_V2 is the
    // smallest flavor carrying both cpu times and resident size.
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::uninit();
    let rc = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V2,
            info.as_mut_ptr().cast::<libc::rusage_info_t>().cast(),
        )
    };
    if rc != 0 {
        return None;
    }
    let info = unsafe { info.assume_init() };
    Some(PidUsage {
        cpu_ns: mach_ticks_to_ns(info.ri_user_time.saturating_add(info.ri_system_time)),
        resident_bytes: info.ri_resident_size,
    })
}

fn executable_basename(pid: i32) -> Option<String> {
    // Safety: proc_pidpath writes a NUL-terminated path into our buffer.
    let mut buffer = [0u8; 4096];
    let len = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if len <= 0 {
        return None;
    }
    let path = String::from_utf8_lossy(&buffer[..len as usize]).into_owned();
    let comm = path.rsplit('/').next().unwrap_or(&path).to_string();
    (!comm.is_empty()).then_some(comm)
}

// libc deprecates its mach_timebase_info in favor of the mach2 crate; one
// struct + one call does not justify a new dependency.
#[allow(deprecated)]
static MACH_TIMEBASE: LazyLock<(u64, u64)> = LazyLock::new(|| {
    // Safety: mach_timebase_info fills the struct we own; on failure fall
    // back to 1/1 (already-nanoseconds).
    let mut info = libc::mach_timebase_info { numer: 0, denom: 0 };
    let rc = unsafe { libc::mach_timebase_info(&mut info) };
    if rc == 0 && info.numer > 0 && info.denom > 0 {
        (info.numer as u64, info.denom as u64)
    } else {
        (1, 1)
    }
});

fn mach_ticks_to_ns(ticks: u64) -> u64 {
    let (numer, denom) = *MACH_TIMEBASE;
    (ticks as u128 * numer as u128 / denom as u128) as u64
}

fn physical_memory_bytes() -> u64 {
    // Safety: sysctlbyname fills the u64 we own; hw.memsize is a stable key.
    let mut bytes: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    let name = c"hw.memsize";
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut bytes as *mut u64).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 {
        bytes
    } else {
        0
    }
}

pub const TIMEOUT_STATUS: i32 = 124;
pub const OUTPUT_LIMIT_STATUS: i32 = 125;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stream {
    Stdout,
    Stderr,
}

impl Stream {
    fn label(self) -> &'static str {
        match self {
            Self::Stdout => "stdout",
            Self::Stderr => "stderr",
        }
    }
}

#[derive(Debug)]
pub enum CaptureError {
    Spawn(io::Error),
    Stdin(io::Error),
    Wait(io::Error),
    Read { stream: Stream, source: io::Error },
    Task { name: &'static str },
    Timeout { timeout: Duration },
    OutputLimit { stream: Stream, limit: usize },
}

impl CaptureError {
    /// A content-free diagnostic: it identifies only the failure class, stream,
    /// configured budget, and OS error number. It never includes argv, output,
    /// stdin, paths, tokens, or other command-owned text.
    pub fn diagnostic(&self) -> String {
        match self {
            Self::Spawn(error) => {
                format!("subprocess spawn failed os_error={}", os_error_code(error))
            }
            Self::Stdin(error) => format!(
                "subprocess stdin write failed os_error={}",
                os_error_code(error)
            ),
            Self::Wait(error) => {
                format!("subprocess wait failed os_error={}", os_error_code(error))
            }
            Self::Read { stream, source } => format!(
                "subprocess {} read failed os_error={}",
                stream.label(),
                os_error_code(source)
            ),
            Self::Task { name } => format!("subprocess {name} task failed"),
            Self::Timeout { timeout } => {
                format!("subprocess timed out timeout_ms={}", timeout.as_millis())
            }
            Self::OutputLimit { stream, limit } => {
                format!("subprocess {} exceeded limit_bytes={limit}", stream.label())
            }
        }
    }

    pub fn status(&self) -> i32 {
        match self {
            Self::Timeout { .. } => TIMEOUT_STATUS,
            Self::OutputLimit { .. } => OUTPUT_LIMIT_STATUS,
            _ => -1,
        }
    }
}

fn os_error_code(error: &io::Error) -> String {
    error
        .raw_os_error()
        .map(|code| code.to_string())
        .unwrap_or_else(|| "none".to_string())
}

#[derive(Debug)]
pub struct CaptureOutput {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Spawn and capture `command` under a single wall-clock budget.
///
/// `stdin` is owned so its write can run concurrently with both output
/// readers. Callers must bound it before invoking this function.
pub async fn capture(
    command: &mut Command,
    stdin: Option<Vec<u8>>,
    timeout: Duration,
    stdout_limit: usize,
    stderr_limit: usize,
) -> Result<CaptureOutput, CaptureError> {
    command
        .stdin(if stdin.is_some() {
            std::process::Stdio::piped()
        } else {
            std::process::Stdio::null()
        })
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        // A dedicated group lets timeout/overflow termination include any
        // descendants that inherited stdout/stderr.
        .process_group(0);

    let mut child = command.spawn().map_err(CaptureError::Spawn)?;
    let stdout = child
        .stdout
        .take()
        .expect("bounded capture configured stdout as piped");
    let stderr = child
        .stderr
        .take()
        .expect("bounded capture configured stderr as piped");
    let mut stdout_task = tokio::spawn(read_bounded(stdout, Stream::Stdout, stdout_limit));
    let mut stderr_task = tokio::spawn(read_bounded(stderr, Stream::Stderr, stderr_limit));
    let mut stdin_task = stdin.map(|input| {
        let mut pipe = child
            .stdin
            .take()
            .expect("bounded capture configured stdin as piped");
        tokio::spawn(async move {
            pipe.write_all(&input).await?;
            pipe.shutdown().await
        })
    });

    let result = tokio::time::timeout(timeout, async {
        let stdout = await_reader(&mut stdout_task, Stream::Stdout);
        let stderr = await_reader(&mut stderr_task, Stream::Stderr);
        let stdin = await_stdin(&mut stdin_task);
        let (stdout, stderr, ()) = tokio::try_join!(stdout, stderr, stdin)?;
        // Reap only after both pipes close. Until then the unreaped child keeps
        // its pid/process-group id reserved, so an overflow cannot race pid
        // reuse before `terminate` targets the group.
        let status = child.wait().await.map_err(CaptureError::Wait)?;
        Ok(CaptureOutput {
            status,
            stdout,
            stderr,
        })
    })
    .await;

    match result {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => {
            terminate(&mut child).await;
            stdout_task.abort();
            stderr_task.abort();
            if let Some(task) = stdin_task {
                task.abort();
            }
            Err(error)
        }
        Err(_) => {
            terminate(&mut child).await;
            stdout_task.abort();
            stderr_task.abort();
            if let Some(task) = stdin_task {
                task.abort();
            }
            Err(CaptureError::Timeout { timeout })
        }
    }
}

async fn await_reader(
    task: &mut JoinHandle<Result<Vec<u8>, CaptureError>>,
    stream: Stream,
) -> Result<Vec<u8>, CaptureError> {
    task.await.map_err(|_| CaptureError::Task {
        name: stream.label(),
    })?
}

async fn await_stdin(
    task: &mut Option<JoinHandle<Result<(), io::Error>>>,
) -> Result<(), CaptureError> {
    let Some(task) = task else {
        return Ok(());
    };
    task.await
        .map_err(|_| CaptureError::Task { name: "stdin" })?
        .map_err(CaptureError::Stdin)
}

async fn read_bounded<R>(
    mut reader: R,
    stream: Stream,
    limit: usize,
) -> Result<Vec<u8>, CaptureError>
where
    R: AsyncRead + Unpin,
{
    let mut output = Vec::with_capacity(limit.min(64 * 1024));
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        // Read at most one byte beyond the remaining budget. That detects an
        // overflow without temporarily allocating an attacker-controlled tail.
        let read_limit = limit.saturating_sub(output.len()).saturating_add(1);
        let size = read_limit.min(buffer.len());
        let read = reader
            .read(&mut buffer[..size])
            .await
            .map_err(|source| CaptureError::Read { stream, source })?;
        if read == 0 {
            return Ok(output);
        }
        let remaining = limit.saturating_sub(output.len());
        if read > remaining {
            return Err(CaptureError::OutputLimit { stream, limit });
        }
        output.extend_from_slice(&buffer[..read]);
    }
}

async fn terminate(child: &mut Child) {
    if let Some(group) = child.id().map(|pid| pid as i32) {
        // SAFETY: `group` came from Child::id and the child was spawned into a
        // fresh process group whose id equals its pid. A negative pid targets
        // exactly that group.
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_secs(1), child.wait()).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(source: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(source);
        command
    }

    #[tokio::test]
    async fn accepts_exact_stream_limits_and_drains_both_pipes() {
        let mut command = shell("printf 12345678; printf abcdefgh >&2");
        let output = capture(&mut command, None, Duration::from_secs(1), 8, 8)
            .await
            .expect("capture");
        assert!(output.status.success());
        assert_eq!(output.stdout, b"12345678");
        assert_eq!(output.stderr, b"abcdefgh");
    }

    #[tokio::test]
    async fn rejects_first_byte_beyond_stdout_limit() {
        let mut command = shell("printf 123456789; sleep 5");
        let started = tokio::time::Instant::now();
        let error = capture(&mut command, None, Duration::from_secs(3), 8, 8)
            .await
            .expect_err("stdout overflow");
        assert!(matches!(
            error,
            CaptureError::OutputLimit {
                stream: Stream::Stdout,
                limit: 8
            }
        ));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn rejects_first_byte_beyond_stderr_limit() {
        let mut command = shell("printf abcdefghi >&2; sleep 5");
        let error = capture(&mut command, None, Duration::from_secs(3), 8, 8)
            .await
            .expect_err("stderr overflow");
        assert_eq!(
            error.diagnostic(),
            "subprocess stderr exceeded limit_bytes=8"
        );
        assert!(matches!(
            error,
            CaptureError::OutputLimit {
                stream: Stream::Stderr,
                limit: 8
            }
        ));
    }

    #[tokio::test]
    async fn timeout_covers_descendants_that_keep_pipes_open() {
        let mut command = shell("(sleep 5) & exit 0");
        let started = tokio::time::Instant::now();
        let error = capture(&mut command, None, Duration::from_millis(100), 8, 8)
            .await
            .expect_err("pipe-holding descendant must hit deadline");
        assert!(matches!(error, CaptureError::Timeout { .. }));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn writes_stdin_while_draining_output() {
        let mut command = shell("cat; printf err >&2");
        let output = capture(
            &mut command,
            Some(b"input".to_vec()),
            Duration::from_secs(1),
            5,
            3,
        )
        .await
        .expect("capture");
        assert_eq!(output.stdout, b"input");
        assert_eq!(output.stderr, b"err");
    }
}
