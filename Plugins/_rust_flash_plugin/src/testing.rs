//! In-memory test harness: drive plugin handlers directly from `cargo test`
//! with no host process, no wire framing, and no subprocess.
//!
//! [`Harness::new`] assembles a real [`Context`] whose emitter writes into
//! in-memory channels and whose data directory points at a unique
//! per-harness temp path. The path is not pre-created — handlers create the
//! directories they need, exactly as they do in production. Drive the
//! plugin by calling its handlers with [`Harness::context`], then assert on
//! the warm store through the context ([`Context::has_locations`],
//! [`Context::warm_locations`]) and on emitted frames through
//! [`Harness::drain_control`] / [`Harness::drain_telemetry`].

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;
use tokio::sync::mpsc;

use crate::context::{assemble_context, Context};
use crate::types::RunningApplication;
use crate::wire::Emitter;

/// Deliberately far above the production lane bounds (64/128) so a test
/// that emits many frames before draining never deadlocks on channel
/// backpressure.
const HARNESS_LANE_CAPACITY: usize = 4096;

/// Distinguishes concurrent harnesses within one test process so their
/// data directories never collide.
static HARNESS_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub struct Harness {
    context: Context,
    control_rx: mpsc::Receiver<Vec<u8>>,
    telemetry_rx: mpsc::Receiver<Vec<u8>>,
}

impl Harness {
    /// Harness with an empty `[plugin.<id>]` settings table.
    pub fn new(plugin_id: &str) -> Self {
        Self::with_config(plugin_id, Value::Object(Default::default()))
    }

    /// Harness whose context reads `config` as the plugin's settings table —
    /// the same JSON object shape `FLASH_PLUGIN_CONFIG` carries in
    /// production.
    pub fn with_config(plugin_id: &str, config: Value) -> Self {
        let (control_tx, control_rx) = mpsc::channel(HARNESS_LANE_CAPACITY);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(HARNESS_LANE_CAPACITY);
        let data_dir = std::env::temp_dir().join(format!(
            "flash-plugin-harness-{}-{}-{}",
            plugin_id,
            std::process::id(),
            HARNESS_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        ));
        let context = assemble_context(
            plugin_id.to_string(),
            "0.0.0-test".to_string(),
            data_dir,
            Emitter::new(control_tx, telemetry_tx),
            config,
        );
        Self {
            context,
            control_rx,
            telemetry_rx,
        }
    }

    /// A real, cloneable [`Context`] wired to this harness's channels.
    pub fn context(&self) -> Context {
        self.context.clone()
    }

    /// Root of this harness's (possibly not yet created) data directory.
    pub fn data_dir(&self) -> PathBuf {
        self.context.data_dir.clone()
    }

    /// Replace the running-application snapshot handlers observe through
    /// [`Context::running_applications`].
    pub fn set_running_applications(&self, applications: Vec<RunningApplication>) {
        self.context.set_running_applications(applications);
    }

    /// Drain and decode every frame queued on the control lane (responses,
    /// host RPC requests, status updates).
    pub fn drain_control(&mut self) -> Vec<Value> {
        drain(&mut self.control_rx)
    }

    /// Drain and decode every frame queued on the telemetry lane
    /// (`flash.log` notifications).
    pub fn drain_telemetry(&mut self) -> Vec<Value> {
        drain(&mut self.telemetry_rx)
    }
}

fn drain(rx: &mut mpsc::Receiver<Vec<u8>>) -> Vec<Value> {
    let mut frames = Vec::new();
    while let Ok(bytes) = rx.try_recv() {
        frames
            .push(rmp_serde::from_slice(&bytes).expect("harness frame must decode as MessagePack"));
    }
    frames
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Candidate;

    #[test]
    fn captures_warm_store_and_emitted_frames() {
        let mut harness = Harness::new("harness-self");
        let ctx = harness.context();

        ctx.set_locations("plugin:harness-self", vec![Candidate::new("row")]);
        ctx.log("info", "hello from the harness");

        assert!(ctx.has_locations("plugin:harness-self"));
        assert_eq!(ctx.warm_locations().len(), 1);
        let frames = harness.drain_telemetry();
        assert!(
            frames
                .iter()
                .any(|frame| frame.get("method").and_then(Value::as_str) == Some("flash.log")),
            "expected a flash.log frame, got: {frames:?}"
        );
    }

    #[test]
    fn data_dirs_are_unique_per_harness() {
        let a = Harness::new("same-id");
        let b = Harness::new("same-id");
        assert_ne!(a.data_dir(), b.data_dir());
    }
}
