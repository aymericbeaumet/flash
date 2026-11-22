//! Keep the Mac awake.
//!
//! `caffeinate on` takes, in this process, the power assertions
//! `/usr/bin/caffeinate -dimsu` takes; `off`, the end of a `--minutes` bound
//! and shutdown release them, and powerd drops them with the process
//! whatever ends it. The `state` segment is `on` while a hold lasts.

mod power;
mod state;

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::status::StatusValue;
use flash_plugin::{
    CommandRequest, Context, Deadline, PerformAlert, PerformResponse, PollPriority, run,
};

use power::{AssertionId, IoKitPower, Power, PowerError};
use state::{Effect, Request, State};

/// The longest deadline the host arms (`poll.max_seconds`): a longer bound
/// is counted down a day at a time.
const MAX_DEADLINE_SECONDS: u64 = 86_400;

/// The hold and what it took: the state, the assertions powerd holds for it
/// and the deadline of its bound.
struct Keeper {
    state: State,
    held: Vec<AssertionId>,
    power: Box<dyn Power>,
    expiry: Option<Deadline>,
}

type Shared = Arc<Mutex<Keeper>>;

fn lock(shared: &Shared) -> MutexGuard<'_, Keeper> {
    shared
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct Caffeinate {
    keeper: Shared,
}

impl Caffeinate {
    fn new(power: Box<dyn Power>) -> Self {
        Self {
            keeper: Arc::new(Mutex::new(Keeper {
                state: State::default(),
                held: Vec::new(),
                power,
                expiry: None,
            })),
        }
    }
}

/// The request a command names. `on` and `toggle` take `--minutes`, which
/// the manifest declares as a whole number from 1; `off` and `status`
/// declare no argument. The host holds every invocation to that before the
/// command arrives.
fn parse(command: &CommandRequest) -> Result<Request, String> {
    let name = command.name();
    match name.as_str() {
        "caffeinate on" => minutes(command, &name).map(Request::On),
        "caffeinate toggle" => minutes(command, &name).map(Request::Toggle),
        "caffeinate off" => Ok(Request::Off),
        "caffeinate status" => Ok(Request::Status),
        _ => Err(format!("unknown command: {name}")),
    }
}

/// The `--minutes` bound, when one was given. The usage answers a number
/// the declaration would have refused.
fn minutes(command: &CommandRequest, name: &str) -> Result<Option<u32>, String> {
    if command.value("minutes").is_none() {
        return Ok(None);
    }
    command
        .integer("minutes")
        .and_then(|minutes| u32::try_from(minutes).ok())
        .filter(|minutes| *minutes > 0)
        .map(Some)
        .ok_or_else(|| format!("usage: {name} [--minutes=<n>]"))
}

/// What a request answers once the Mac is, or is not, held awake. On, off
/// and toggle change the state, so their alert shows wherever they ran;
/// `status` asks, and its answer is the command's output alone.
fn reply(request: Request, on: bool) -> PerformResponse {
    let state = if on { "on" } else { "off" };
    let response = PerformResponse::ok().message(format!("caffeinate {state}"));
    if request == Request::Status {
        return response;
    }
    response.alert(PerformAlert::value("caffeinate", state).widest_value("off"))
}

fn publish(ctx: &Context, on: bool) {
    let value = if on {
        StatusValue::text("on")
    } else {
        StatusValue::empty()
    };
    ctx.status([("state", value)]);
}

/// One transition, its effects, and the change it made: whether the Mac is
/// held awake afterwards.
fn apply(
    shared: &Shared,
    ctx: &Context,
    change: impl FnOnce(&mut State) -> Vec<Effect>,
) -> Result<bool, PowerError> {
    let mut keeper = lock(shared);
    let was_on = keeper.state.is_on();
    let mut failure = None;
    for effect in change(&mut keeper.state) {
        match effect {
            Effect::Release => {
                if let Some(expiry) = keeper.expiry.take() {
                    expiry.cancel();
                }
                let held = std::mem::take(&mut keeper.held);
                keeper.power.release(&held);
            }
            Effect::Acquire(hold) => match keeper.power.acquire(hold.seconds) {
                Ok(held) => {
                    keeper.held = held;
                    if let Some(seconds) = hold.seconds {
                        arm(&mut keeper, shared, ctx, hold.generation, seconds);
                    }
                }
                Err(error) => {
                    keeper.state.acquisition_failed(hold.generation);
                    failure = Some(error);
                }
            },
        }
    }
    let is_on = keeper.state.is_on();
    if is_on != was_on {
        publish(ctx, is_on);
        ctx.log(
            "info",
            if is_on {
                "[caffeinate] on"
            } else {
                "[caffeinate] off"
            },
        );
    }
    match failure {
        Some(error) => Err(error),
        None => Ok(is_on),
    }
}

/// Arm the deadline that ends hold `generation` in `remaining` seconds, on
/// the host's clock. `low`: powerd already enforces the bound, so a late
/// tick only delays the status value.
fn arm(keeper: &mut Keeper, shared: &Shared, ctx: &Context, generation: u64, remaining: u64) {
    let step = remaining.min(MAX_DEADLINE_SECONDS);
    let left = remaining - step;
    let shared = shared.clone();
    keeper.expiry = Some(ctx.after(
        Duration::from_secs(step),
        PollPriority::Low,
        move |ctx| async move {
            if left == 0 {
                // A power failure cannot happen here: an expiry releases.
                let _ = apply(&shared, &ctx, |state| state.expire(generation));
                return;
            }
            let mut keeper = lock(&shared);
            if keeper.state.hold().map(|hold| hold.generation) == Some(generation) {
                arm(&mut keeper, &shared, &ctx, generation, left);
            }
        },
    ));
}

flash_plugin::plugin!(Caffeinate);

impl FlashPlugin for Caffeinate {
    /// A restarted plugin holds nothing: say so before a surface keeps
    /// showing the previous run's `on`.
    async fn on_start(&self, ctx: Context) {
        publish(&ctx, lock(&self.keeper).state.is_on());
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let request = match parse(&command) {
            Ok(request) => request,
            Err(usage) => return PerformResponse::fail(usage),
        };
        match apply(&self.keeper, &ctx, |state| state.apply(request)) {
            Ok(on) => reply(request, on),
            Err(error) => PerformResponse::fail(error.to_string()),
        }
    }

    async fn on_shutdown(&self, ctx: Context) {
        let _ = apply(&self.keeper, &ctx, |state| state.apply(Request::Off));
    }
}

fn main() {
    run(Caffeinate::new(Box::new(IoKitPower)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::{Value, json};

    /// What the stubbed powerd saw.
    #[derive(Default)]
    struct Calls {
        acquired: Vec<Option<u64>>,
        released: Vec<Vec<AssertionId>>,
        next_id: AssertionId,
        failure: Option<PowerError>,
    }

    struct StubPower(Arc<Mutex<Calls>>);

    impl Power for StubPower {
        fn acquire(&mut self, seconds: Option<u64>) -> Result<Vec<AssertionId>, PowerError> {
            let mut calls = self.0.lock().unwrap();
            if let Some(failure) = calls.failure {
                return Err(failure);
            }
            calls.acquired.push(seconds);
            calls.next_id += 1;
            Ok(vec![calls.next_id])
        }

        fn release(&mut self, assertions: &[AssertionId]) {
            self.0.lock().unwrap().released.push(assertions.to_vec());
        }
    }

    fn fixture() -> (Caffeinate, Arc<Mutex<Calls>>, Harness) {
        let calls = Arc::new(Mutex::new(Calls::default()));
        let plugin = Caffeinate::new(Box::new(StubPower(calls.clone())));
        (plugin, calls, Harness::new("caffeinate"))
    }

    fn command(subcommand: &str, args: &[&str]) -> CommandRequest {
        CommandRequest {
            command: "caffeinate".to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            ..CommandRequest::default()
        }
    }

    async fn invoke(
        plugin: &Caffeinate,
        harness: &Harness,
        subcommand: &str,
        args: &[&str],
    ) -> Value {
        let response = plugin
            .on_command(harness.context(), command(subcommand, args))
            .await;
        serde_json::to_value(response).unwrap()
    }

    fn changed(state: &str) -> Value {
        json!({ "ok": true, "message": format!("caffeinate {state}"), "alert": {
            "title": "caffeinate", "value": state, "widest_value": "off"
        } })
    }

    /// What the plugin sent since the last look: each `state` it published,
    /// and the deadline its last registration set holds, as `(name, seconds)`.
    struct Sent {
        states: Vec<String>,
        /// `None` when no set was registered; `Some(None)` for an empty one.
        deadline: Option<Option<(String, f64)>>,
    }

    fn sent(harness: &mut Harness) -> Sent {
        let mut sent = Sent {
            states: Vec::new(),
            deadline: None,
        };
        for frame in harness.drain() {
            match frame["method"].as_str() {
                Some("status") => sent.states.push(
                    frame["params"]["segments"]["state"]
                        .as_str()
                        .expect("a state")
                        .to_string(),
                ),
                Some("poll") => {
                    let registrations = frame["params"]["registrations"].as_object().unwrap();
                    assert!(registrations.len() <= 1, "{registrations:?}");
                    sent.deadline = Some(registrations.iter().next().map(|(name, entry)| {
                        assert_eq!(entry["priority"], "low");
                        (name.clone(), entry["after"].as_f64().unwrap())
                    }));
                }
                _ => {}
            }
        }
        sent
    }

    #[test]
    fn commands_parse_their_minutes() {
        let cases = [
            ("on", vec![], Request::On(None)),
            ("on", vec!["--minutes=30"], Request::On(Some(30))),
            ("off", vec![], Request::Off),
            ("toggle", vec![], Request::Toggle(None)),
            ("toggle", vec!["--minutes=1"], Request::Toggle(Some(1))),
            ("status", vec![], Request::Status),
            (
                "on",
                vec!["--minutes=4294967295"],
                Request::On(Some(u32::MAX)),
            ),
        ];
        for (subcommand, args, request) in cases {
            assert_eq!(
                parse(&command(subcommand, &args)),
                Ok(request),
                "{subcommand} {args:?}"
            );
        }
    }

    /// The host holds `--minutes` to its declaration; a number outside it
    /// still takes nothing here.
    #[test]
    fn a_bound_outside_the_declaration_is_refused_with_the_usage() {
        for subcommand in ["on", "toggle"] {
            let usage = format!("usage: caffeinate {subcommand} [--minutes=<n>]");
            for args in [
                vec!["--minutes=0"],
                vec!["--minutes=-5"],
                vec!["--minutes=1h"],
                vec!["--minutes="],
                vec!["--minutes=4294967296"],
            ] {
                assert_eq!(
                    parse(&command(subcommand, &args)),
                    Err(usage.clone()),
                    "{subcommand} {args:?}"
                );
            }
        }
        assert_eq!(
            parse(&command("wat", &[])),
            Err("unknown command: caffeinate wat".to_string())
        );
    }

    /// The manifest declares what `parse` reads: `--minutes` on `on` and
    /// `toggle`, a whole number from 1 to the largest bound it holds.
    #[test]
    fn the_manifest_declares_the_minutes_the_commands_read() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        for command in manifest["commands"].as_array().unwrap() {
            let bounded = matches!(command["subcommand"].as_str(), Some("on" | "toggle"));
            let expected = if bounded {
                json!([{
                    "name": "minutes", "type": "integer", "min": 1, "max": u32::MAX,
                    "description": "How long to keep the Mac awake"
                }])
            } else {
                Value::Null
            };
            assert_eq!(command["args"], expected, "{}", command["subcommand"]);
        }
    }

    #[tokio::test]
    async fn a_refused_command_takes_no_assertion() {
        let (plugin, calls, mut harness) = fixture();
        assert_eq!(
            invoke(&plugin, &harness, "on", &["--minutes=0"]).await,
            json!({ "ok": false, "error": "usage: caffeinate on [--minutes=<n>]" })
        );
        assert!(calls.lock().unwrap().acquired.is_empty());
        let sent = sent(&mut harness);
        assert_eq!(sent.states, Vec::<String>::new());
        assert_eq!(sent.deadline, None);
    }

    /// On, off and toggle show the state they left wherever they ran;
    /// `status` only answers.
    #[tokio::test]
    async fn the_state_is_every_commands_output() {
        let (plugin, calls, mut harness) = fixture();
        assert_eq!(
            invoke(&plugin, &harness, "status", &[]).await,
            json!({ "ok": true, "message": "caffeinate off" })
        );
        assert_eq!(invoke(&plugin, &harness, "off", &[]).await, changed("off"));
        assert_eq!(
            invoke(&plugin, &harness, "toggle", &[]).await,
            changed("on")
        );
        assert_eq!(
            invoke(&plugin, &harness, "status", &[]).await,
            json!({ "ok": true, "message": "caffeinate on" })
        );
        assert_eq!(calls.lock().unwrap().acquired, [None]);
        // Toggle ignores its minutes to stop.
        assert_eq!(
            invoke(&plugin, &harness, "toggle", &["--minutes=5"]).await,
            changed("off")
        );
        assert_eq!(calls.lock().unwrap().released, [[1]]);
        let sent = sent(&mut harness);
        assert_eq!(sent.states, ["on", ""]);
        assert_eq!(sent.deadline, None, "an unbounded hold arms nothing");
    }

    #[tokio::test]
    async fn a_bounded_hold_arms_its_expiry_and_releases_when_it_fires() {
        let (plugin, calls, mut harness) = fixture();
        assert_eq!(
            invoke(&plugin, &harness, "on", &["--minutes=2"]).await,
            changed("on")
        );
        assert_eq!(calls.lock().unwrap().acquired, [Some(120)]);
        let armed = sent(&mut harness);
        assert_eq!(armed.states, ["on"]);
        let (name, seconds) = armed.deadline.flatten().expect("the bound's deadline");
        assert_eq!(seconds, 120.0);

        harness
            .deliver_poll_tick(&name)
            .expect("the deadline fires")
            .await
            .unwrap();
        assert_eq!(calls.lock().unwrap().released, [[1]]);
        assert_eq!(sent(&mut harness).states, [""]);
        assert_eq!(
            invoke(&plugin, &harness, "status", &[]).await["message"],
            "caffeinate off"
        );
    }

    #[tokio::test]
    async fn replacing_a_hold_cancels_its_expiry_and_ignores_its_late_fire() {
        let (plugin, calls, mut harness) = fixture();
        invoke(&plugin, &harness, "on", &["--minutes=1"]).await;
        let armed = sent(&mut harness);
        assert_eq!(armed.states, ["on"]);
        let (name, _) = armed.deadline.flatten().expect("the bound's deadline");
        assert_eq!(invoke(&plugin, &harness, "on", &[]).await, changed("on"));
        assert_eq!(calls.lock().unwrap().acquired, [Some(60), None]);
        assert_eq!(calls.lock().unwrap().released, [[1]]);
        let replaced = sent(&mut harness);
        assert_eq!(
            replaced.deadline,
            Some(None),
            "the replaced hold's deadline is cancelled"
        );
        assert_eq!(
            replaced.states,
            Vec::<String>::new(),
            "replacing a hold never reads as off in between"
        );
        assert!(
            harness.deliver_poll_tick(&name).is_none(),
            "a cancelled deadline runs nothing"
        );
        assert_eq!(
            invoke(&plugin, &harness, "status", &[]).await["message"],
            "caffeinate on"
        );

        assert_eq!(
            invoke(&plugin, &harness, "toggle", &[]).await,
            changed("off")
        );
        assert_eq!(calls.lock().unwrap().released, [[1], [2]]);
        assert_eq!(sent(&mut harness).states, [""]);
    }

    /// The host arms a day at most: a longer bound is counted down in
    /// steps, and only the last one releases.
    #[tokio::test]
    async fn a_bound_longer_than_a_day_is_counted_down_in_steps() {
        let (plugin, calls, mut harness) = fixture();
        // 36 hours.
        invoke(&plugin, &harness, "on", &["--minutes=2160"]).await;
        assert_eq!(calls.lock().unwrap().acquired, [Some(129_600)]);
        let armed = sent(&mut harness);
        assert_eq!(armed.states, ["on"]);
        let (first, seconds) = armed.deadline.flatten().expect("the first step");
        assert_eq!(seconds, 86_400.0);
        harness
            .deliver_poll_tick(&first)
            .expect("the first step fires")
            .await
            .unwrap();
        assert!(calls.lock().unwrap().released.is_empty());
        let stepped = sent(&mut harness);
        assert_eq!(stepped.states, Vec::<String>::new(), "still held");
        let (second, seconds) = stepped.deadline.flatten().expect("the second step");
        assert_eq!(seconds, 43_200.0);
        harness
            .deliver_poll_tick(&second)
            .expect("the last step fires")
            .await
            .unwrap();
        assert_eq!(calls.lock().unwrap().released, [[1]]);
        assert_eq!(sent(&mut harness).states, [""]);
    }

    #[tokio::test]
    async fn a_failed_assertion_reports_and_holds_nothing() {
        let (plugin, calls, mut harness) = fixture();
        calls.lock().unwrap().failure = Some(PowerError(0xE000_02BDu32 as i32));
        assert_eq!(
            invoke(&plugin, &harness, "on", &["--minutes=5"]).await,
            json!({ "ok": false, "error": "caffeinate: power assertion failed (0xe00002bd)" })
        );
        let sent = sent(&mut harness);
        assert_eq!(sent.deadline, None);
        assert_eq!(sent.states, Vec::<String>::new());
        assert_eq!(
            invoke(&plugin, &harness, "status", &[]).await["message"],
            "caffeinate off"
        );
    }

    #[tokio::test]
    async fn shutdown_releases_the_hold() {
        let (plugin, calls, mut harness) = fixture();
        invoke(&plugin, &harness, "on", &["--minutes=30"]).await;
        assert!(sent(&mut harness).deadline.flatten().is_some());
        plugin.on_shutdown(harness.context()).await;
        assert_eq!(calls.lock().unwrap().released, [[1]]);
        let stopped = sent(&mut harness);
        assert_eq!(stopped.deadline, Some(None), "its deadline is cancelled");
        assert_eq!(stopped.states, [""]);
    }

    /// A started plugin says it holds nothing, so a surface drops the `on`
    /// a previous run left.
    #[tokio::test]
    async fn a_started_plugin_publishes_that_it_holds_nothing() {
        let (plugin, calls, mut harness) = fixture();
        plugin.on_start(harness.context()).await;
        assert_eq!(sent(&mut harness).states, [""]);
        assert!(calls.lock().unwrap().acquired.is_empty());
    }

    /// The commands the manifest declares are the ones parsed here.
    #[test]
    fn the_manifest_declares_exactly_the_parsed_commands() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let mut declared: Vec<&str> = manifest["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| {
                assert_eq!(entry["command"], "caffeinate");
                entry["subcommand"].as_str().unwrap()
            })
            .collect();
        declared.sort_unstable();
        assert_eq!(declared, ["off", "on", "status", "toggle"]);
        for subcommand in declared {
            assert!(parse(&command(subcommand, &[])).is_ok(), "{subcommand}");
        }
        assert_eq!(manifest["status"], json!(["state"]));
    }
}
