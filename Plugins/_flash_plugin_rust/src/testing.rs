//! In-memory test harness: drive plugin handlers directly from `cargo test`
//! with no host process, no wire framing, and no subprocess.
//!
//! [`Harness::new`] assembles a real [`Context`] whose emitter writes into an
//! in-memory queue and whose data directory points at a unique per-harness
//! temp path. The path is not pre-created — handlers create the directories
//! they need, exactly as they do in production. Drive the plugin by calling
//! its handlers with [`Harness::context`], then assert on the emitted
//! `publish`/`status`/`log` frames (and host RPC requests) through
//! [`Harness::drain`].

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;
use tokio::sync::mpsc;

use crate::context::{assemble_context, Context};
use crate::emit::Emitter;
use crate::types::{Candidate, RunningApplication};

/// Deliberately far above the production queue bound so a test that emits
/// many frames before draining never deadlocks on channel backpressure.
const HARNESS_QUEUE_CAPACITY: usize = 4096;

/// Distinguishes concurrent harnesses within one test process so their
/// data directories never collide.
static HARNESS_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub struct Harness {
    context: Context,
    rx: mpsc::Receiver<Vec<u8>>,
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
        let (tx, rx) = mpsc::channel(HARNESS_QUEUE_CAPACITY);
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
            Emitter::new(tx),
            config,
        );
        Self { context, rx }
    }

    /// A real, cloneable [`Context`] wired to this harness's queue.
    pub fn context(&self) -> Context {
        self.context.clone()
    }

    /// Root of this harness's (possibly not yet created) data directory.
    pub fn data_dir(&self) -> PathBuf {
        self.context.data_dir()
    }

    /// Replace the running-application snapshot handlers observe through
    /// [`Context::running_applications`].
    pub fn set_running_applications(&self, applications: Vec<RunningApplication>) {
        self.context.set_running_applications(applications);
    }

    /// Drain and decode every queued outbound frame — `publish`/`status`/
    /// `log` notifications and host RPC requests — in emission order.
    pub fn drain(&mut self) -> Vec<Value> {
        let mut frames = Vec::new();
        while let Ok(bytes) = self.rx.try_recv() {
            frames.push(serde_json::from_slice(&bytes).expect("harness frame must decode as JSON"));
        }
        frames
    }

    /// Drain and return the rows of the most recent `publish` notification;
    /// `None` when nothing was published since the last drain.
    pub fn drain_published_rows(&mut self) -> Option<Vec<Candidate>> {
        self.drain()
            .into_iter()
            .rev()
            .find(|frame| frame.get("method").and_then(Value::as_str) == Some("publish"))
            .and_then(|frame| {
                let rows = frame.get("params")?.get("rows")?.clone();
                serde_json::from_value(rows).ok()
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_published_rows_and_emitted_frames() {
        let mut harness = Harness::new("harness-self");
        let ctx = harness.context();

        ctx.publish(vec![Candidate::new("self.items", "row")]);
        ctx.log("info", "hello from the harness");

        let frames = harness.drain();
        assert_eq!(
            frames[0].get("method").and_then(Value::as_str),
            Some("publish")
        );
        assert_eq!(frames[1].get("method").and_then(Value::as_str), Some("log"));

        ctx.publish(vec![
            Candidate::new("self.items", "first"),
            Candidate::new("self.items", "second"),
        ]);
        let rows = harness.drain_published_rows().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].source, "self.items");
        assert!(harness.drain_published_rows().is_none());
    }

    #[test]
    fn data_dirs_are_unique_per_harness() {
        let a = Harness::new("same-id");
        let b = Harness::new("same-id");
        assert_ne!(a.data_dir(), b.data_dir());
    }
}
