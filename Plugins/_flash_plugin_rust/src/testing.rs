//! In-memory test harnesses: drive a plugin from `cargo test` with no host
//! process and no subprocess.
//!
//! [`Harness`] calls handlers directly. [`Harness::new`] assembles a real
//! [`Context`] whose emitter writes into an in-memory queue and whose data
//! directory points at a unique per-harness temp path. The path is not
//! pre-created — handlers create the directories they need, exactly as they
//! do in production. Drive the plugin by calling its handlers with
//! [`Harness::context`], script the host side of its RPCs with
//! [`Harness::next_host_request`] / [`Harness::reply_host`], then assert on
//! the emitted `publish`/`status`/`log` frames through [`Harness::drain`].
//!
//! [`WireHarness`] runs the real serve loop over in-memory NDJSON streams,
//! so a test speaks to the plugin exactly as the host does: write frames
//! with [`WireHarness::send`], read replies and notifications with
//! [`WireHarness::recv`], and end the session with
//! [`WireHarness::close_stdin`] + [`WireHarness::finished`].

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, ReadHalf, WriteHalf};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::context::{assemble_context, Context, PluginEnv};
use crate::emit::{Emitter, OutboundFrame};
use crate::runtime::{serve_streams, Plugin};
use crate::types::{Candidate, RunningApplication};

/// Deliberately far above the production queue bound so a test that emits
/// many frames before draining never deadlocks on channel backpressure.
const HARNESS_QUEUE_CAPACITY: usize = 4096;
/// Every harness wait is bounded: a plugin that never answers fails the test
/// instead of hanging it.
const HARNESS_DEADLINE: Duration = Duration::from_secs(2);
/// In-memory pipe capacity per direction. The serve loop drains its input
/// continuously, so frames larger than this still stream through.
const WIRE_BUFFER_BYTES: usize = 1024 * 1024;

/// Distinguishes concurrent harnesses within one test process so their
/// data directories never collide.
static HARNESS_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// The environment a harness-owned plugin sees: a unique data directory and
/// the given settings table.
pub(crate) fn test_env(plugin_id: &str, config: Value) -> PluginEnv {
    PluginEnv {
        plugin_id: plugin_id.to_string(),
        version: "0.0.0-test".to_string(),
        data_dir: Some(std::env::temp_dir().join(format!(
            "flash-plugin-harness-{}-{}-{}",
            plugin_id,
            std::process::id(),
            HARNESS_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        ))),
        config,
    }
}

fn decode(frame: &OutboundFrame) -> Value {
    serde_json::from_slice(&frame.payload).expect("harness frame must decode as JSON")
}

pub struct Harness {
    context: Context,
    rx: mpsc::Receiver<OutboundFrame>,
    /// Frames read past while awaiting a host request; the next `drain`
    /// returns them first so emission order is preserved.
    skipped: Vec<Value>,
}

impl Harness {
    /// Harness with an empty `[plugin.<id>]` settings table.
    pub fn new(plugin_id: &str) -> Self {
        Self::with_config(plugin_id, json!({}))
    }

    /// Harness whose context reads `config` as the plugin's settings table —
    /// the same JSON object shape `FLASH_PLUGIN_CONFIG` carries in
    /// production.
    pub fn with_config(plugin_id: &str, config: Value) -> Self {
        let (tx, rx) = mpsc::channel(HARNESS_QUEUE_CAPACITY);
        let context = assemble_context(test_env(plugin_id, config), Emitter::new(tx));
        Self {
            context,
            rx,
            skipped: Vec::new(),
        }
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
        let mut frames = std::mem::take(&mut self.skipped);
        while let Ok(frame) = self.rx.try_recv() {
            frames.push(decode(&frame));
        }
        frames
    }

    /// Await the plugin's next host RPC request as `(id, method, params)`,
    /// keeping any notification emitted before it for a later
    /// [`drain`](Harness::drain). `None` when no request arrives within the
    /// harness deadline.
    pub async fn next_host_request(&mut self) -> Option<(u64, String, Value)> {
        tokio::time::timeout(HARNESS_DEADLINE, async {
            loop {
                let frame = decode(&self.rx.recv().await?);
                match (
                    frame.get("id").and_then(Value::as_u64),
                    frame.get("method").and_then(Value::as_str),
                ) {
                    (Some(id), Some(method)) => {
                        let params = frame.get("params").cloned().unwrap_or(Value::Null);
                        return Some((id, method.to_string(), params));
                    }
                    _ => self.skipped.push(frame),
                }
            }
        })
        .await
        .ok()
        .flatten()
    }

    /// Answer host RPC `id` the way the host would, waking the handler that
    /// awaits it. `false` when no call awaits that id.
    pub fn reply_host(&self, id: u64, result: Value) -> bool {
        self.context.resolve_host_call(id, result)
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

    /// Drain and return every `status` notification's segment map, in
    /// emission order, as the rendered wire strings.
    pub fn drain_status(&mut self) -> Vec<BTreeMap<String, String>> {
        self.drain()
            .into_iter()
            .filter(|frame| frame.get("method").and_then(Value::as_str) == Some("status"))
            .filter_map(|frame| {
                let segments = frame.get("params")?.get("segments")?.as_object()?;
                Some(
                    segments
                        .iter()
                        .filter_map(|(name, value)| {
                            Some((name.clone(), value.as_str()?.to_string()))
                        })
                        .collect(),
                )
            })
            .collect()
    }
}

/// The real serve loop over in-memory stdin/stdout, driven frame by frame.
/// Construct it inside a tokio runtime (`#[tokio::test]`).
pub struct WireHarness {
    stdin: WriteHalf<DuplexStream>,
    stdout: BufReader<ReadHalf<DuplexStream>>,
    server: JoinHandle<()>,
}

impl WireHarness {
    /// Serve `plugin` with an empty settings table.
    pub fn new<P: Plugin>(plugin: P) -> Self {
        Self::with_config(plugin, json!({}))
    }

    /// Serve `plugin` with `config` as its `[plugin.<id>]` settings table.
    pub fn with_config<P: Plugin>(plugin: P, config: Value) -> Self {
        let (host, child) = tokio::io::duplex(WIRE_BUFFER_BYTES);
        let (input, output) = tokio::io::split(child);
        let server = tokio::spawn(serve_streams(
            plugin,
            test_env("wire", config),
            input,
            output,
        ));
        let (stdout, stdin) = tokio::io::split(host);
        Self {
            stdin,
            stdout: BufReader::new(stdout),
            server,
        }
    }

    /// Write one frame as a newline-terminated JSON line.
    pub async fn send(&mut self, frame: Value) {
        let mut line = serde_json::to_vec(&frame).expect("frame encodes as JSON");
        line.push(b'\n');
        self.send_raw(&line).await;
    }

    /// Write raw bytes: wire noise, several frames in one write, or an
    /// unterminated record.
    pub async fn send_raw(&mut self, bytes: &[u8]) {
        tokio::time::timeout(HARNESS_DEADLINE, self.stdin.write_all(bytes))
            .await
            .expect("plugin must keep draining stdin")
            .expect("plugin stdin is open");
    }

    /// The next frame the plugin wrote, decoded. Panics when nothing arrives
    /// within the harness deadline or the plugin closed stdout.
    pub async fn recv(&mut self) -> Value {
        let mut line = String::new();
        let read = tokio::time::timeout(HARNESS_DEADLINE, self.stdout.read_line(&mut line))
            .await
            .expect("plugin must write within the harness deadline")
            .expect("plugin stdout is readable");
        assert!(read > 0, "plugin closed stdout");
        serde_json::from_str(&line).expect("plugin frames are JSON")
    }

    /// The `result` of the reply to request `id`. Notifications arriving
    /// first are dropped; any other reply is a test failure, because replies
    /// must correlate exactly.
    pub async fn recv_response(&mut self, id: u64) -> Value {
        loop {
            let frame = self.recv().await;
            if frame.get("method").is_some() {
                continue;
            }
            assert_eq!(frame["id"], json!(id), "unexpected reply: {frame}");
            return frame["result"].clone();
        }
    }

    /// The `params` of the next `method` notification. Other notifications
    /// arriving first are dropped; a reply is a test failure.
    pub async fn recv_notification(&mut self, method: &str) -> Value {
        loop {
            let frame = self.recv().await;
            assert!(
                frame.get("id").is_none(),
                "unexpected reply while awaiting a {method} notification: {frame}"
            );
            if frame["method"] == method {
                return frame["params"].clone();
            }
        }
    }

    /// Half-close the plugin's stdin — the shutdown signal.
    pub async fn close_stdin(&mut self) {
        self.stdin.shutdown().await.expect("plugin stdin closes");
    }

    /// Wait for the serve loop to return and collect every frame it still
    /// wrote (shutdown logs included), in order.
    pub async fn finished(mut self) -> Vec<Value> {
        tokio::time::timeout(HARNESS_DEADLINE, async {
            let mut frames = Vec::new();
            loop {
                let mut line = String::new();
                if self
                    .stdout
                    .read_line(&mut line)
                    .await
                    .expect("plugin stdout is readable")
                    == 0
                {
                    break;
                }
                frames.push(serde_json::from_str(&line).expect("plugin frames are JSON"));
            }
            self.server.await.expect("serve loop completes");
            frames
        })
        .await
        .expect("plugin runtime must finish within the harness deadline")
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
    fn drains_rendered_status_segments_in_order() {
        use crate::status::{Preview, StatusValue};

        let mut harness = Harness::new("harness-status");
        let ctx = harness.context();

        ctx.status([("state", "on")]);
        ctx.log("info", "between");
        ctx.status([(
            "summary",
            StatusValue::text("CPU").with_preview(Preview::from_markup("body")),
        )]);

        let statuses = harness.drain_status();
        assert_eq!(statuses.len(), 2);
        assert_eq!(statuses[0]["state"], "on");
        assert_eq!(statuses[1]["summary"], "#[popup=inline:body]CPU#[nopopup]");
        assert!(harness.drain_status().is_empty());
    }

    #[test]
    fn data_dirs_are_unique_per_harness() {
        let a = Harness::new("same-id");
        let b = Harness::new("same-id");
        assert_ne!(a.data_dir(), b.data_dir());
    }

    #[tokio::test]
    async fn host_requests_are_scripted_without_losing_earlier_notifications() {
        let mut harness = Harness::new("harness-host");
        let ctx = harness.context();
        ctx.log("info", "before the call");
        let call = tokio::spawn(async move { ctx.storage_get("k").await });

        let (id, method, params) = harness.next_host_request().await.unwrap();
        assert_eq!(
            (method.as_str(), params),
            ("host.storage_get", json!({ "key": "k" }))
        );
        assert!(harness.reply_host(id, json!({ "ok": true, "value": "v" })));
        assert!(
            !harness.reply_host(id, json!({ "ok": true })),
            "each call resolves once"
        );
        assert_eq!(call.await.unwrap().as_deref(), Some("v"));

        assert_eq!(harness.drain()[0]["params"]["message"], "before the call");
        assert!(harness.next_host_request().await.is_none());
    }
}
