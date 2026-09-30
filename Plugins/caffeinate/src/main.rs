use std::io;
use std::mem;
use std::os::fd::{AsFd, AsRawFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use flash_plugin::{
    CommandRequest, Context, ManagedChild, ManagedChildError, PerformResponse, StatusValue, run,
    spawn_managed,
};
use nix::errno::Errno;
use nix::libc::timespec;
use nix::sys::event::{EvFlags, EventFilter, FilterFlag, KEvent, Kqueue};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

const CAFFEINATE: &str = "/usr/bin/caffeinate";
const TERMINATION_GRACE: Duration = Duration::from_millis(250);
const USAGE: &str = "usage: caffeinate on|toggle [minutes]";

struct Caffeinate {
    state: Arc<Mutex<AssertionState>>,
    expiry_task: Mutex<Option<JoinHandle<()>>>,
    next_token: AtomicU64,
    command_prefix: Vec<String>,
}

impl Default for Caffeinate {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(AssertionState::Stopped)),
            expiry_task: Mutex::new(None),
            next_token: AtomicU64::new(0),
            command_prefix: vec![CAFFEINATE.to_string()],
        }
    }
}

enum AssertionState {
    Stopped,
    Indefinite { child: ManagedChild },
    Timed { token: u64, child: ManagedChild },
    ShuttingDown,
}

impl AssertionState {
    fn child_mut(&mut self) -> Option<&mut ManagedChild> {
        match self {
            Self::Stopped | Self::ShuttingDown => None,
            Self::Indefinite { child } | Self::Timed { child, .. } => Some(child),
        }
    }

    fn pid(&self) -> Option<u32> {
        match self {
            Self::Stopped | Self::ShuttingDown => None,
            Self::Indefinite { child } | Self::Timed { child, .. } => Some(child.id()),
        }
    }

    fn is_token(&self, expected: u64) -> bool {
        matches!(self, Self::Timed { token, .. } if *token == expected)
    }
}

flash_plugin::plugin!(Caffeinate);

impl FlashPlugin for Caffeinate {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let starts = matches!(command.subcommand.as_str(), "on" | "toggle");
        let minutes = match parse_minutes(&command.args) {
            Ok(minutes) => minutes,
            Err(()) if starts => return PerformResponse::fail(USAGE),
            Err(()) => None,
        };
        let mut expiry = None;
        let mut replace_expiry = false;
        let mut state = self.state.lock().await;
        if matches!(*state, AssertionState::ShuttingDown) {
            return PerformResponse::fail("plugin is shutting down");
        }
        if let Err(error) = reconcile(&mut state) {
            return PerformResponse::fail(error.diagnostic());
        }
        let response = match command.subcommand.as_str() {
            "" | "status" => performed(&state),
            "on" => match self.start(&ctx, &mut state, minutes).await {
                Ok(timer) => {
                    expiry = timer;
                    replace_expiry = true;
                    emit_state(&ctx, &state);
                    performed(&state)
                }
                Err(error) => {
                    replace_expiry = true;
                    PerformResponse::fail(error.diagnostic())
                }
            },
            "off" => match stop(&mut state).await {
                Ok(()) => {
                    replace_expiry = true;
                    emit_state(&ctx, &state);
                    performed(&state)
                }
                Err(error) => {
                    replace_expiry = true;
                    PerformResponse::fail(error.diagnostic())
                }
            },
            "toggle" if state.pid().is_some() => match stop(&mut state).await {
                Ok(()) => {
                    replace_expiry = true;
                    emit_state(&ctx, &state);
                    performed(&state)
                }
                Err(error) => {
                    replace_expiry = true;
                    PerformResponse::fail(error.diagnostic())
                }
            },
            "toggle" => match self.start(&ctx, &mut state, minutes).await {
                Ok(timer) => {
                    expiry = timer;
                    replace_expiry = true;
                    emit_state(&ctx, &state);
                    performed(&state)
                }
                Err(error) => {
                    replace_expiry = true;
                    PerformResponse::fail(error.diagnostic())
                }
            },
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        };
        // Keep replacement of the process and its timer inside the state
        // critical section. Perform handlers may run concurrently; doing
        // this after unlocking could let an older command abort the newer
        // assertion's expiry task.
        if replace_expiry {
            let mut task = self.expiry_task.lock().await;
            if let Some(previous) = task.take() {
                previous.abort();
            }
            *task = expiry.map(|(token, delay)| {
                schedule_expiry(self.state.clone(), ctx.clone(), token, delay)
            });
        }
        response
    }

    async fn on_shutdown(&self, _ctx: Context) {
        if let Some(task) = self.expiry_task.lock().await.take() {
            task.abort();
        }
        let mut state = self.state.lock().await;
        let _ = terminate_into(&mut state, AssertionState::ShuttingDown).await;
    }
}

impl Caffeinate {
    async fn start(
        &self,
        ctx: &Context,
        state: &mut AssertionState,
        minutes: Option<u64>,
    ) -> Result<Option<(u64, Duration)>, ManagedChildError> {
        stop(state).await?;
        let seconds = minutes.map(|minutes| minutes * 60);
        let mut argv = self.command_prefix.clone();
        argv.extend(caffeinate_args(std::process::id(), seconds));
        let child = spawn_managed(ctx, &argv)?;
        watch_exit(self.state.clone(), ctx.clone(), child.id());
        let Some(seconds) = seconds else {
            *state = AssertionState::Indefinite { child };
            return Ok(None);
        };
        let token = self.next_token.fetch_add(1, Ordering::Relaxed) + 1;
        *state = AssertionState::Timed { token, child };
        let delay = Some(Duration::from_secs(seconds))
            .filter(|delay| tokio::time::Instant::now().checked_add(*delay).is_some());
        Ok(delay.map(|delay| (token, delay)))
    }
}

/// The optional `[minutes]` argument, a whole number; `Err` for anything
/// else rather than silently keeping the Mac awake indefinitely.
fn parse_minutes(args: &[String]) -> Result<Option<u64>, ()> {
    args.first()
        .map(|argument| argument.parse::<u32>().map(u64::from).map_err(|_| ()))
        .transpose()
}

/// Display and idle sleep prevented, for `seconds` if bounded. `-w` ties the
/// assertion to this plugin: should the plugin die without reaping it (a
/// crash, a SIGKILL past the shutdown grace), caffeinate exits with it
/// instead of keeping the Mac awake with no owner.
fn caffeinate_args(plugin_pid: u32, seconds: Option<u64>) -> Vec<String> {
    let mut args = vec!["-di".to_string(), "-w".to_string(), plugin_pid.to_string()];
    if let Some(seconds) = seconds {
        args.push("-t".to_string());
        args.push(seconds.to_string());
    }
    args
}

fn reconcile(state: &mut AssertionState) -> Result<(), ManagedChildError> {
    let Some(child) = state.child_mut() else {
        return Ok(());
    };
    if !child.is_running()? {
        *state = AssertionState::Stopped;
    }
    Ok(())
}

async fn stop(state: &mut AssertionState) -> Result<(), ManagedChildError> {
    terminate_into(state, AssertionState::Stopped).await
}

async fn terminate_into(
    state: &mut AssertionState,
    replacement: AssertionState,
) -> Result<(), ManagedChildError> {
    let mut previous = mem::replace(state, replacement);
    let Some(child) = previous.child_mut() else {
        return Ok(());
    };
    child.terminate(TERMINATION_GRACE).await
}

fn performed(state: &AssertionState) -> PerformResponse {
    match state.pid() {
        Some(pid) => PerformResponse::ok().message(format!("caffeinate on (pid {pid})")),
        None => PerformResponse::ok().message("caffeinate off"),
    }
}

fn emit_state(ctx: &Context, state: &AssertionState) {
    let value = if state.pid().is_some() {
        StatusValue::text("on")
    } else {
        StatusValue::empty()
    };
    ctx.status([("state", value)]);
}

/// Clear the status the moment the assertion's process exits on its own —
/// killed, or its `-t` bound reached — rather than at the next command.
/// Stopping or replacing it exits it too; the pid check makes that a no-op.
fn watch_exit(state: Arc<Mutex<AssertionState>>, ctx: Context, pid: u32) {
    tokio::spawn(async move {
        if exited(pid).await.is_err() {
            // No watch: the next command still reconciles.
            return;
        }
        let mut state = state.lock().await;
        if state.pid() != Some(pid) {
            return;
        }
        if reconcile(&mut state).is_ok() && state.pid().is_none() {
            emit_state(&ctx, &state);
        }
    });
}

/// `Kqueue` exposes `AsFd`; Tokio's reactor wants `AsRawFd`.
struct Queue(Kqueue);

impl AsRawFd for Queue {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_fd().as_raw_fd()
    }
}

const NO_WAIT: timespec = timespec {
    tv_sec: 0,
    tv_nsec: 0,
};

/// Resolves when `pid` exits: kqueue's `EVFILT_PROC`/`NOTE_EXIT`, waited on
/// through Tokio's reactor, so nothing polls. The child stays unreaped until
/// `reconcile`, so its pid cannot be reused meanwhile.
async fn exited(pid: u32) -> io::Result<()> {
    // Readable only: a kqueue descriptor rejects a write filter.
    let queue = AsyncFd::with_interest(Queue(Kqueue::new()?), Interest::READABLE)?;
    let exit = KEvent::new(
        pid as usize,
        EventFilter::EVFILT_PROC,
        EvFlags::EV_ADD | EvFlags::EV_ONESHOT,
        FilterFlag::NOTE_EXIT,
        0,
        0,
    );
    match queue.get_ref().0.kevent(&[exit], &mut [], Some(NO_WAIT)) {
        Ok(_) => {}
        // Already gone.
        Err(Errno::ESRCH) => return Ok(()),
        Err(error) => return Err(error.into()),
    }
    loop {
        let mut ready = queue.readable().await?;
        let mut events = [exit];
        let count = queue.get_ref().0.kevent(&[], &mut events, Some(NO_WAIT))?;
        ready.clear_ready();
        if count > 0 {
            return Ok(());
        }
    }
}

fn schedule_expiry(
    state: Arc<Mutex<AssertionState>>,
    ctx: Context,
    token: u64,
    delay: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        let mut state = state.lock().await;
        if !state.is_token(token) {
            return;
        }
        let _ = stop(&mut state).await;
        emit_state(&ctx, &state);
    })
}

fn main() {
    run(Caffeinate::default());
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    async fn fixture() -> (Caffeinate, Harness) {
        let harness = Harness::new("caffeinate-test");
        tokio::fs::create_dir_all(harness.data_dir()).await.unwrap();
        let script = harness.data_dir().join("fake-caffeinate.sh");
        tokio::fs::write(&script, "trap 'exit 0' TERM\nwhile :; do sleep 1; done\n")
            .await
            .unwrap();
        let plugin = Caffeinate {
            command_prefix: vec!["/bin/sh".to_string(), script.to_string_lossy().into_owned()],
            ..Caffeinate::default()
        };
        (plugin, harness)
    }

    fn command(subcommand: &str, args: &[&str]) -> CommandRequest {
        CommandRequest {
            command: "caffeinate".to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            raw: String::new(),
        }
    }

    async fn invoke(
        plugin: &Caffeinate,
        harness: &Harness,
        subcommand: &str,
        args: &[&str],
    ) -> PerformResponse {
        plugin
            .on_command(harness.context(), command(subcommand, args))
            .await
    }

    #[tokio::test]
    async fn on_replaces_the_previous_process_and_off_reaps_it() {
        let (plugin, harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "on", &[]).await.is_ok());
        let first_pid = plugin.state.lock().await.pid().unwrap();

        assert!(invoke(&plugin, &harness, "on", &[]).await.is_ok());
        let second_pid = plugin.state.lock().await.pid().unwrap();
        assert_ne!(first_pid, second_pid);

        assert!(invoke(&plugin, &harness, "off", &[]).await.is_ok());
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Stopped
        ));
    }

    #[tokio::test]
    async fn toggle_moves_between_indefinite_and_stopped() {
        let (plugin, harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "toggle", &[]).await.is_ok());
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Indefinite { .. }
        ));
        assert!(invoke(&plugin, &harness, "toggle", &[]).await.is_ok());
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Stopped
        ));
    }

    #[tokio::test]
    async fn zero_minute_assertion_expires_reaps_and_clears_status() {
        let (plugin, mut harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "on", &["0"]).await.is_ok());
        for _ in 0..50 {
            if matches!(*plugin.state.lock().await, AssertionState::Stopped) {
                let frames = harness.drain_status();
                assert_eq!(frames.last().unwrap()["state"], "");
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("timed assertion did not expire");
    }

    /// A caffeinate that dies on its own (killed, or its `-t` ran out) clears
    /// the status as it exits, not at the next command.
    #[tokio::test]
    async fn an_assertion_that_dies_clears_its_status_without_a_command() {
        let (plugin, mut harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "on", &[]).await.is_ok());
        let pid = plugin.state.lock().await.pid().unwrap();
        assert_eq!(harness.drain_status().last().unwrap()["state"], "on");
        let killed = tokio::process::Command::new("/bin/kill")
            .args(["-9", &pid.to_string()])
            .status()
            .await
            .unwrap();
        assert!(killed.success());
        for _ in 0..200 {
            if matches!(*plugin.state.lock().await, AssertionState::Stopped) {
                assert_eq!(harness.drain_status().last().unwrap()["state"], "");
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("a dead assertion kept its status");
    }

    #[tokio::test]
    async fn replacement_aborts_the_previous_expiry_task() {
        let (plugin, harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "on", &["1"]).await.is_ok());
        assert!(plugin.expiry_task.lock().await.is_some());

        assert!(invoke(&plugin, &harness, "on", &[]).await.is_ok());
        assert!(plugin.expiry_task.lock().await.is_none());
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Indefinite { .. }
        ));

        plugin.on_shutdown(harness.context()).await;
    }

    #[tokio::test]
    async fn shutdown_reaps_the_owned_assertion() {
        let (plugin, harness) = fixture().await;
        assert!(invoke(&plugin, &harness, "on", &[]).await.is_ok());
        let pid = plugin.state.lock().await.pid().unwrap();
        plugin.on_shutdown(harness.context()).await;
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::ShuttingDown
        ));
        assert!(pid > 0);

        let response = invoke(&plugin, &harness, "on", &[]).await;
        assert_eq!(response.error_message(), Some("plugin is shutting down"));
    }

    #[test]
    fn the_assertion_is_tied_to_the_plugin_and_bounded_by_minutes() {
        assert_eq!(caffeinate_args(42, None), ["-di", "-w", "42"]);
        assert_eq!(
            caffeinate_args(42, Some(300)),
            ["-di", "-w", "42", "-t", "300"]
        );
        assert_eq!(parse_minutes(&[]), Ok(None));
        assert_eq!(parse_minutes(&["5".to_string()]), Ok(Some(5)));
        for invalid in ["-5", "1h", "", "4294967296"] {
            assert_eq!(parse_minutes(&[invalid.to_string()]), Err(()), "{invalid}");
        }
    }

    #[tokio::test]
    async fn invalid_minutes_fail_without_starting_a_process() {
        let (plugin, harness) = fixture().await;
        for subcommand in ["on", "toggle"] {
            let response = invoke(&plugin, &harness, subcommand, &["-5"]).await;
            assert_eq!(response.error_message(), Some(USAGE));
        }
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Stopped
        ));
        assert!(invoke(&plugin, &harness, "off", &["-5"]).await.is_ok());
    }

    #[tokio::test]
    async fn unknown_commands_fail_without_starting_a_process() {
        let (plugin, harness) = fixture().await;
        let response = invoke(&plugin, &harness, "wat", &[]).await;
        assert_eq!(response.error_message(), Some("unknown subcommand: wat"));
        assert!(matches!(
            *plugin.state.lock().await,
            AssertionState::Stopped
        ));
    }
}
