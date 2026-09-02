use std::mem;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use flash_plugin::{
    run, spawn_managed, CommandRequest, Context, ManagedChild, ManagedChildError, PerformResponse,
};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

const CAFFEINATE: &str = "/usr/bin/caffeinate";
const TERMINATION_GRACE: Duration = Duration::from_millis(250);

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
        let minutes = command
            .args
            .first()
            .and_then(|argument| argument.parse::<i128>().ok());
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
        minutes: Option<i128>,
    ) -> Result<Option<(u64, Duration)>, ManagedChildError> {
        stop(state).await?;
        let mut argv = self.command_prefix.clone();
        argv.push("-di".to_string());
        let seconds = minutes.map(|value| value.saturating_mul(60));
        if let Some(seconds) = seconds {
            argv.push("-t".to_string());
            argv.push(seconds.to_string());
        }
        let child = spawn_managed(ctx, &argv)?;
        let Some(seconds) = seconds else {
            *state = AssertionState::Indefinite { child };
            return Ok(None);
        };
        let token = self.next_token.fetch_add(1, Ordering::Relaxed) + 1;
        *state = AssertionState::Timed { token, child };
        let delay = u64::try_from(seconds)
            .ok()
            .map(Duration::from_secs)
            .filter(|delay| tokio::time::Instant::now().checked_add(*delay).is_some());
        Ok(delay.map(|delay| (token, delay)))
    }
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
    ctx.status([("state", if state.pid().is_some() { "on" } else { "" })]);
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
                let frames = harness.drain();
                assert_eq!(frames.last().unwrap()["params"]["segments"]["state"], "");
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("timed assertion did not expire");
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
