//! The host, played for the tests: it lands the deadlines the plugin
//! registers, answers its host calls and keeps what it emitted.

use std::collections::BTreeSet;
use std::time::Duration;

use flash_plugin::testing::Harness;
use serde_json::{Value, json};

pub(crate) struct Host {
    pub(crate) harness: Harness,
    /// Deadlines already landed: each fires once.
    landed: BTreeSet<String>,
    /// The reply to `host.normal_mode_target`.
    pub(crate) target: Value,
    /// The reply to `host.process_signal`.
    pub(crate) signal: Value,
    /// Every host call the plugin made, as `(method, params)`.
    pub(crate) calls: Vec<(String, Value)>,
}

impl Host {
    pub(crate) fn new(config: Value) -> Self {
        Self {
            harness: Harness::with_config("processes", config),
            landed: BTreeSet::new(),
            target: json!({ "ok": true, "present": false }),
            signal: json!({ "ok": true }),
            calls: Vec::new(),
        }
    }

    /// Run the plugin until it has nothing left to do: every one-shot
    /// deadline lands as soon as it is registered and every host call is
    /// answered. The frames it emitted meanwhile, in order, host calls
    /// aside.
    pub(crate) async fn settle(&mut self) -> Vec<Value> {
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
                if let (Some(id), Some(method)) = (frame["id"].as_u64(), frame["method"].as_str()) {
                    self.calls
                        .push((method.to_string(), frame["params"].clone()));
                    let reply = match method {
                        "host.normal_mode_target" => self.target.clone(),
                        "host.process_signal" => self.signal.clone(),
                        _ => json!({ "ok": false, "error": "not scripted" }),
                    };
                    assert!(self.harness.reply_host(id, reply));
                    continue;
                }
                if frame["method"] == "poll"
                    && let Some(registrations) = frame["params"]["registrations"].as_object()
                {
                    for (name, registration) in registrations {
                        if registration.get("after").is_some() && self.landed.insert(name.clone()) {
                            self.harness.deliver_poll_tick(name);
                        }
                    }
                }
                emitted.push(frame);
            }
        }
        emitted
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
