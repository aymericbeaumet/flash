//! The host, played for the tests: it lands the deadlines the plugin
//! registers, answers its host calls, the process table among them, and
//! keeps what it emitted.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::Duration;

use flash_plugin::testing::Harness;
use serde_json::{Value, json};

use crate::table::testing::FakeMachine;

pub(crate) struct Host {
    pub(crate) harness: Harness,
    /// The scripted Mac whose processes answer `host.process_table`.
    machine: Arc<FakeMachine>,
    /// Deadlines already landed: each fires once.
    landed: BTreeSet<String>,
    /// Deadlines seen and not landed yet (`answer_until_waiting`).
    pending: Vec<String>,
    /// The reply to `host.normal_mode_target`.
    pub(crate) target: Value,
    /// The reply to `host.process_signal`. Nil: the kernel's, which takes
    /// the signal of a process the scripted Mac runs and knows no other.
    pub(crate) signal: Option<Value>,
    /// When set, every `host.process_table` request fails with it.
    pub(crate) failure: Option<String>,
    /// The params of every `host.process_table` request, in order.
    pub(crate) reads: Vec<Value>,
    /// Every other host call the plugin made, as `(method, params)`.
    pub(crate) calls: Vec<(String, Value)>,
}

impl Host {
    pub(crate) fn new(config: Value, machine: &Arc<FakeMachine>) -> Self {
        Self {
            harness: Harness::with_config("processes", config),
            machine: machine.clone(),
            landed: BTreeSet::new(),
            pending: Vec::new(),
            target: json!({ "ok": true, "present": false }),
            signal: None,
            failure: None,
            reads: Vec::new(),
            calls: Vec::new(),
        }
    }

    /// Answer one host call; false when `frame` is none.
    fn answer(&mut self, frame: &Value) -> bool {
        let (Some(id), Some(method)) = (frame["id"].as_u64(), frame["method"].as_str()) else {
            return false;
        };
        let reply = match method {
            "host.process_table" => {
                self.reads.push(frame["params"].clone());
                match &self.failure {
                    Some(reason) => json!({ "ok": false, "error": reason }),
                    None => self.machine.reply(&frame["params"]),
                }
            }
            _ => {
                self.calls
                    .push((method.to_string(), frame["params"].clone()));
                match method {
                    "host.normal_mode_target" => self.target.clone(),
                    "host.process_signal" => self.signal.clone().unwrap_or_else(|| {
                        match self.machine.runs(frame["params"]["pid"].as_i64()) {
                            true => json!({ "ok": true }),
                            false => json!({ "ok": false, "error": "No such process" }),
                        }
                    }),
                    _ => json!({ "ok": false, "error": "not scripted" }),
                }
            }
        };
        assert!(self.harness.reply_host(id, reply));
        true
    }

    /// The one-shot deadlines `frame` registers that were not seen before.
    fn deadlines(&mut self, frame: &Value) -> Vec<String> {
        let mut names = Vec::new();
        if frame["method"] == "poll"
            && let Some(registrations) = frame["params"]["registrations"].as_object()
        {
            for (name, registration) in registrations {
                if registration.get("after").is_some() && self.landed.insert(name.clone()) {
                    names.push(name.clone());
                }
            }
        }
        names
    }

    /// Run the plugin until it has nothing left to do: every one-shot
    /// deadline lands as soon as it is registered and every host call is
    /// answered. The frames it emitted meanwhile, in order, host calls
    /// aside.
    pub(crate) async fn settle(&mut self) -> Vec<Value> {
        for name in std::mem::take(&mut self.pending) {
            self.harness.deliver_poll_tick(&name);
        }
        let mut emitted = Vec::new();
        let mut quiet = 0;
        while quiet < 20 {
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
            let frames = self.harness.drain();
            if frames.is_empty() {
                quiet += 1;
                // A blocking read (an app's metadata) finishes on its own
                // thread.
                std::thread::sleep(Duration::from_millis(1));
                continue;
            }
            quiet = 0;
            for frame in frames {
                if self.answer(&frame) {
                    continue;
                }
                for name in self.deadlines(&frame) {
                    self.harness.deliver_poll_tick(&name);
                }
                emitted.push(frame);
            }
        }
        emitted
    }

    /// Run the plugin until it waits on a deadline, answering its host
    /// calls and landing nothing: the next `settle` lands it. For what
    /// happens to the machine inside a window.
    pub(crate) async fn answer_until_waiting(&mut self) {
        for _ in 0..1_000 {
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
            for frame in self.harness.drain() {
                if self.answer(&frame) {
                    continue;
                }
                let names = self.deadlines(&frame);
                self.pending.extend(names);
            }
            if !self.pending.is_empty() {
                return;
            }
        }
        panic!("the plugin registered no deadline");
    }

    /// The host's tick of the cadence `name`, run to its end.
    pub(crate) async fn tick(&mut self, name: &str) -> Vec<Value> {
        self.harness.deliver_poll_tick(name);
        self.settle().await
    }
}

/// The segment maps of the `status` frames among `frames`, in order.
pub(crate) fn statuses(frames: &[Value]) -> Vec<Value> {
    frames
        .iter()
        .filter(|frame| frame["method"] == "status")
        .map(|frame| frame["params"]["segments"].clone())
        .collect()
}

/// The cadences (`every`) of each `poll` frame among `frames`, in order:
/// the one-shot deadlines come and go between them.
pub(crate) fn cadences(frames: &[Value]) -> Vec<Value> {
    let mut sets: Vec<Value> = Vec::new();
    for frame in frames.iter().filter(|frame| frame["method"] == "poll") {
        let cadences: serde_json::Map<String, Value> = frame["params"]["registrations"]
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(_, registration)| registration.get("every").is_some())
            .map(|(name, registration)| (name.clone(), registration.clone()))
            .collect();
        let set = Value::Object(cadences);
        if sets.last() != Some(&set) {
            sets.push(set);
        }
    }
    sets
}

/// The one-shot deadlines (`after`) registered across `frames`, each once.
pub(crate) fn deadlines(frames: &[Value]) -> Vec<Value> {
    let mut seen = BTreeSet::new();
    let mut deadlines = Vec::new();
    for frame in frames.iter().filter(|frame| frame["method"] == "poll") {
        for (name, registration) in frame["params"]["registrations"]
            .as_object()
            .into_iter()
            .flatten()
        {
            if registration.get("after").is_some() && seen.insert(name.clone()) {
                deadlines.push(registration.clone());
            }
        }
    }
    deadlines
}

pub(crate) fn segments(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}
