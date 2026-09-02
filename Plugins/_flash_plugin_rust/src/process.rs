//! Process primitives: bounded subprocess capture under
//! [`run_command`](crate::run_command), plus the lifecycle-safe long-lived
//! child owned through [`spawn_managed`](crate::spawn_managed). The capture
//! layer stays public for plugins whose invocation shape the high-level runner
//! cannot express — tmux builds its own `Command` with a deliberately
//! unsandboxed environment and custom output budgets. Process-table listing
//! and signalling are host services
//! (`host.process_table` / `host.signal`) — plugins never fork `/bin/ps`
//! or `/bin/kill` and need no libproc access of their own.
//!
//! For capture, both output streams are drained concurrently. A timeout, a
//! read failure, or either stream exceeding its byte budget kills the
//! subprocess's entire process group so descendants cannot retain the pipes
//! and strand the plugin.

use std::io;
use std::process::ExitStatus;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::task::JoinHandle;

pub const TIMEOUT_STATUS: i32 = 124;
pub const OUTPUT_LIMIT_STATUS: i32 = 125;

/// Failure while owning a long-lived subprocess. Diagnostics deliberately
/// contain only the operation and OS error number: argv and process output may
/// carry user data and must never leak through plugin logs.
#[derive(Debug)]
pub enum ManagedChildError {
    EmptyArgv,
    Spawn(io::Error),
    Status(io::Error),
    Signal { signal: i32, source: io::Error },
    Wait(io::Error),
    ReapTimeout,
}

impl ManagedChildError {
    pub fn diagnostic(&self) -> String {
        match self {
            Self::EmptyArgv => "managed subprocess argv is empty".to_string(),
            Self::Spawn(error) => format!(
                "managed subprocess spawn failed os_error={}",
                os_error_code(error)
            ),
            Self::Status(error) => format!(
                "managed subprocess status failed os_error={}",
                os_error_code(error)
            ),
            Self::Signal { signal, source } => format!(
                "managed subprocess signal failed signal={signal} os_error={}",
                os_error_code(source)
            ),
            Self::Wait(error) => format!(
                "managed subprocess wait failed os_error={}",
                os_error_code(error)
            ),
            Self::ReapTimeout => "managed subprocess reap timed out".to_string(),
        }
    }
}

impl std::fmt::Display for ManagedChildError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.diagnostic())
    }
}

impl std::error::Error for ManagedChildError {}

/// One long-lived subprocess owned by a plugin. It always runs in a dedicated
/// process group so replacement and shutdown terminate descendants as well as
/// the direct child. Call [`terminate`](Self::terminate) on normal paths; Drop
/// is only a final kill-on-drop backstop when the runtime itself is unwinding.
pub struct ManagedChild {
    child: Option<Child>,
    process_group: i32,
}

impl ManagedChild {
    pub(crate) fn spawn(command: &mut Command) -> Result<Self, ManagedChildError> {
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .process_group(0);
        let child = command.spawn().map_err(ManagedChildError::Spawn)?;
        let process_group = child
            .id()
            .expect("a newly spawned managed subprocess has a pid")
            as i32;
        Ok(Self {
            child: Some(child),
            process_group,
        })
    }

    /// Direct child pid, retained after exit for diagnostics but never reused
    /// for signalling once the child has been reaped.
    pub fn id(&self) -> u32 {
        self.process_group as u32
    }

    /// Probe and reap an exited direct child. A false result is terminal for
    /// this handle; subsequent probes stay false.
    pub fn is_running(&mut self) -> Result<bool, ManagedChildError> {
        let Some(child) = self.child.as_mut() else {
            return Ok(false);
        };
        match child.try_wait().map_err(ManagedChildError::Status)? {
            Some(_) => {
                self.child = None;
                Ok(false)
            }
            None => Ok(true),
        }
    }

    /// Terminate the entire process group, wait up to `grace` for the direct
    /// child, then escalate to SIGKILL and explicitly reap it. ESRCH is benign:
    /// the process may have exited between the status probe and the signal.
    pub async fn terminate(&mut self, grace: Duration) -> Result<(), ManagedChildError> {
        if !self.is_running()? {
            return Ok(());
        }
        signal_process_group(self.process_group, libc::SIGTERM)?;
        let wait = {
            let child = self
                .child
                .as_mut()
                .expect("running managed subprocess retains its child handle");
            tokio::time::timeout(grace, child.wait()).await
        };
        match wait {
            Ok(Ok(_)) => {
                self.child = None;
                Ok(())
            }
            Ok(Err(error)) => {
                self.kill_and_reap().await;
                Err(ManagedChildError::Wait(error))
            }
            Err(_) => {
                signal_process_group(self.process_group, libc::SIGKILL)?;
                let child = self
                    .child
                    .as_mut()
                    .expect("unreaped managed subprocess retains its child handle");
                let _ = child.start_kill();
                match tokio::time::timeout(Duration::from_secs(1), child.wait()).await {
                    Ok(Ok(_)) => {
                        self.child = None;
                        Ok(())
                    }
                    Ok(Err(error)) => {
                        self.child = None;
                        Err(ManagedChildError::Wait(error))
                    }
                    Err(_) => Err(ManagedChildError::ReapTimeout),
                }
            }
        }
    }

    async fn kill_and_reap(&mut self) {
        let _ = signal_process_group(self.process_group, libc::SIGKILL);
        if let Some(child) = self.child.as_mut() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(Duration::from_secs(1), child.wait()).await;
        }
        self.child = None;
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = signal_process_group(self.process_group, libc::SIGKILL);
            let _ = child.start_kill();
        }
    }
}

fn signal_process_group(process_group: i32, signal: i32) -> Result<(), ManagedChildError> {
    // SAFETY: the process group id came from Child::id immediately after the
    // child was spawned with process_group(0). A negative pid targets exactly
    // that process group.
    let result = unsafe { libc::kill(-process_group, signal) };
    if result == 0 {
        return Ok(());
    }
    let source = io::Error::last_os_error();
    if source.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(ManagedChildError::Signal { signal, source })
}

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
    use crate::testing::Harness;

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

    #[tokio::test]
    async fn managed_child_uses_plugin_directories_and_reaps_on_terminate() {
        let harness = Harness::new("managed-child");
        let data_dir = harness.data_dir();
        tokio::fs::create_dir_all(&data_dir).await.unwrap();
        let record = data_dir.join("environment.txt");
        let script = format!(
            "printf '%s\\n%s' \"$PWD\" \"$HOME\" > {}; exec sleep 30",
            shell_quote(&record.to_string_lossy())
        );
        let argv = vec!["/bin/sh".to_string(), "-c".to_string(), script];
        let mut child = crate::spawn_managed(&harness.context(), &argv).unwrap();
        wait_for_file(&record).await;

        let recorded = tokio::fs::read_to_string(record).await.unwrap();
        let lines: Vec<&str> = recorded.lines().collect();
        let canonical_data_dir = tokio::fs::canonicalize(&data_dir).await.unwrap();
        assert_eq!(lines[0], canonical_data_dir.to_string_lossy());
        assert_eq!(lines[1], data_dir.join("home").to_string_lossy());
        assert!(child.is_running().unwrap());
        child.terminate(Duration::from_millis(200)).await.unwrap();
        assert!(!child.is_running().unwrap());
    }

    #[tokio::test]
    async fn managed_child_termination_reaches_descendants() {
        let harness = Harness::new("managed-group");
        let data_dir = harness.data_dir();
        tokio::fs::create_dir_all(&data_dir).await.unwrap();
        let pid_file = data_dir.join("descendant.pid");
        let script = format!(
            "sleep 30 & descendant=$!; printf '%s' \"$descendant\" > {}; wait",
            shell_quote(&pid_file.to_string_lossy())
        );
        let argv = vec!["/bin/sh".to_string(), "-c".to_string(), script];
        let mut child = crate::spawn_managed(&harness.context(), &argv).unwrap();
        wait_for_file(&pid_file).await;
        let descendant: i32 = tokio::fs::read_to_string(pid_file)
            .await
            .unwrap()
            .parse()
            .unwrap();

        child.terminate(Duration::from_millis(200)).await.unwrap();
        for _ in 0..20 {
            if !process_exists(descendant) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(!process_exists(descendant));
    }

    #[tokio::test]
    async fn managed_child_escalates_after_the_grace_period() {
        let harness = Harness::new("managed-escalation");
        tokio::fs::create_dir_all(harness.data_dir()).await.unwrap();
        let ready = harness.data_dir().join("ready");
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!(
                "trap '' TERM; : > {}; while :; do sleep 1; done",
                shell_quote(&ready.to_string_lossy())
            ),
        ];
        let mut child = crate::spawn_managed(&harness.context(), &argv).unwrap();
        wait_for_file(&ready).await;
        let pid = child.id() as i32;
        let started = tokio::time::Instant::now();
        child.terminate(Duration::from_millis(30)).await.unwrap();
        assert!(started.elapsed() >= Duration::from_millis(30));
        assert!(!process_exists(pid));
        assert!(!child.is_running().unwrap());
    }

    #[tokio::test]
    async fn managed_child_reaps_natural_exit() {
        let harness = Harness::new("managed-exit");
        tokio::fs::create_dir_all(harness.data_dir()).await.unwrap();
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exit 0".to_string(),
        ];
        let mut child = crate::spawn_managed(&harness.context(), &argv).unwrap();
        for _ in 0..20 {
            if !child.is_running().unwrap() {
                assert!(!child.is_running().unwrap());
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("managed child did not exit");
    }

    #[tokio::test]
    async fn managed_child_drop_kills_as_a_last_resort() {
        let harness = Harness::new("managed-drop");
        tokio::fs::create_dir_all(harness.data_dir()).await.unwrap();
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exec sleep 30".to_string(),
        ];
        let pid = {
            let child = crate::spawn_managed(&harness.context(), &argv).unwrap();
            let pid = child.id() as i32;
            assert!(process_exists(pid));
            pid
        };
        for _ in 0..50 {
            if !process_exists(pid) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(!process_exists(pid));
    }

    async fn wait_for_file(path: &std::path::Path) {
        for _ in 0..50 {
            if tokio::fs::try_exists(path).await.unwrap_or(false) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("timed out waiting for {}", path.display());
    }

    fn shell_quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\\''"))
    }

    fn process_exists(pid: i32) -> bool {
        // SAFETY: signal 0 performs a read-only existence check for this pid.
        unsafe { libc::kill(pid, 0) == 0 }
    }
}
