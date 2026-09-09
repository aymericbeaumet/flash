//! Outbound NDJSON emission: one shared bounded queue drained by a single
//! stdout writer. Responses, plugin→host requests, and notifications all
//! share it — ordering is submission order, with frame and aggregate byte
//! bounds (an oversized response is substituted with the canonical
//! `response exceeded outbound frame limit` error under the same id).

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::{mpsc, OwnedSemaphorePermit, Semaphore};

/// Wire frame cap, both directions (`quotas.frame_bytes` in protocol.json).
pub(crate) const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
pub(crate) const OUTBOUND_QUEUE_CAPACITY: usize = 64;
pub(crate) const OUTBOUND_QUEUE_BYTES: usize = 16 * 1024 * 1024;

pub(crate) struct OutboundFrame {
    pub(crate) payload: Vec<u8>,
    // The writer retains this reservation until the frame is flushed.
    _bytes: OwnedSemaphorePermit,
}

/// Canonical substitution error for an outbound response above the frame cap.
pub(crate) const FRAME_OVERFLOW_ERROR: &str = "response exceeded outbound frame limit";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EmitError {
    /// The frame could not be encoded or exceeded the cap.
    Rejected,
    /// The writer is gone (stdout closed or the emitter was shut down).
    Closed,
    /// A synchronous control reply cannot wait on the reader's own transport.
    Full,
}

/// Cloneable handle feeding the single stdout writer task. `close()` detaches
/// the queue so graceful shutdown can drain and exit even while detached
/// interval tasks still hold [`Context`](crate::Context) clones.
#[derive(Clone)]
pub(crate) struct Emitter {
    sender: Arc<Mutex<Option<mpsc::Sender<OutboundFrame>>>>,
    bytes: Arc<Semaphore>,
}

impl Emitter {
    pub(crate) fn new(sender: mpsc::Sender<OutboundFrame>) -> Self {
        Self {
            sender: Arc::new(Mutex::new(Some(sender))),
            bytes: Arc::new(Semaphore::new(OUTBOUND_QUEUE_BYTES)),
        }
    }

    fn encoded_len(value: &Value) -> Result<usize, EmitError> {
        let mut count = FrameSize(0);
        serde_json::to_writer(&mut count, value).map_err(|_| EmitError::Rejected)?;
        Ok(count.0 + 1)
    }

    fn encode(value: &Value, bytes: OwnedSemaphorePermit, length: usize) -> OutboundFrame {
        let mut payload = Vec::with_capacity(length);
        // Counting already proved this immutable JSON value serializable.
        serde_json::to_writer(&mut payload, value).expect("counted JSON serialization");
        payload.push(b'\n');
        OutboundFrame {
            payload,
            _bytes: bytes,
        }
    }

    fn sender(&self) -> Option<mpsc::Sender<OutboundFrame>> {
        self.sender.lock().ok().and_then(|sender| sender.clone())
    }

    async fn send(&self, value: &Value) -> Result<(), EmitError> {
        let length = Self::encoded_len(value)?;
        let sender = self.sender().ok_or(EmitError::Closed)?;
        let slot = sender.reserve().await.map_err(|_| EmitError::Closed)?;
        let bytes = self
            .bytes
            .clone()
            .acquire_many_owned(length as u32)
            .await
            .map_err(|_| EmitError::Closed)?;
        slot.send(Self::encode(value, bytes, length));
        Ok(())
    }

    fn try_send(&self, value: &Value) -> Result<(), EmitError> {
        let length = Self::encoded_len(value)?;
        let sender = self.sender().ok_or(EmitError::Closed)?;
        let slot = sender.try_reserve().map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => EmitError::Full,
            mpsc::error::TrySendError::Closed(_) => EmitError::Closed,
        })?;
        let bytes = self
            .bytes
            .clone()
            .try_acquire_many_owned(length as u32)
            .map_err(|_| EmitError::Full)?;
        slot.send(Self::encode(value, bytes, length));
        Ok(())
    }

    /// Emit a notification without blocking. Used for `publish`/`status`/`log`
    /// frames from sync call sites; a full queue or an oversized frame drops
    /// the notification with a content-free stderr diagnostic (stderr is the
    /// last-resort channel precisely because the frame itself cannot go out).
    pub(crate) fn notify(&self, method: &str, params: Value) {
        let value = json!({ "method": method, "params": params });
        match self.try_send(&value) {
            Err(EmitError::Rejected) => {
                eprintln!("[plugin] dropped oversized outbound {method} notification")
            }
            Err(EmitError::Full) => {
                eprintln!("[plugin] outbound queue full; dropped {method} notification")
            }
            _ => {}
        }
    }

    /// Emit a plugin→host request frame.
    pub(crate) async fn request(
        &self,
        id: u64,
        method: &str,
        params: Value,
    ) -> Result<(), EmitError> {
        self.send(&json!({ "id": id, "method": method, "params": params }))
            .await
    }

    /// Emit a response frame, substituting the canonical frame-overflow error
    /// (same id) when the encoded result would exceed the cap.
    pub(crate) async fn respond(&self, id: Value, result: Value) {
        if id.is_null() {
            return;
        }
        let response = json!({ "id": id.clone(), "result": result });
        if let Err(EmitError::Rejected) = self.send(&response).await {
            let fallback = json!({
                "id": id,
                "result": { "ok": false, "error": FRAME_OVERFLOW_ERROR },
            });
            // Failure here means stdout has closed; there is no remaining
            // protocol path to report.
            let _ = self.send(&fallback).await;
        }
    }

    /// Reader-side lifecycle/error replies never suspend reading. On a full
    /// writer queue the runtime closes the transport; silently losing a reply
    /// or waiting here could deadlock a handler's pending host RPC.
    pub(crate) fn try_respond(&self, id: Value, result: Value) -> Result<(), EmitError> {
        let response = json!({ "id": id.clone(), "result": result });
        match self.try_send(&response) {
            Err(EmitError::Rejected) => self.try_send(&json!({
                "id": id, "result": { "ok": false, "error": FRAME_OVERFLOW_ERROR }
            })),
            result => result,
        }
    }

    pub(crate) fn log(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.notify(
            "log",
            json!({ "level": level, "message": message, "fields": fields }),
        );
    }

    /// Detach the queue: buffered frames still drain, later emits become
    /// no-ops.
    pub(crate) fn close(&self) {
        self.bytes.close();
        if let Ok(mut sender) = self.sender.lock() {
            sender.take();
        }
    }
}

struct FrameSize(usize);

impl Write for FrameSize {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 = self.0.saturating_add(bytes.len());
        if self.0 > MAX_FRAME_BYTES {
            return Err(io::Error::other("outbound frame limit"));
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(frame: OutboundFrame) -> Value {
        serde_json::from_slice(&frame.payload).unwrap()
    }

    #[tokio::test]
    async fn oversized_response_becomes_the_canonical_overflow_error() {
        let (tx, mut rx) = mpsc::channel(4);
        let emitter = Emitter::new(tx);

        emitter
            .respond(json!(9), json!({ "value": "x".repeat(MAX_FRAME_BYTES) }))
            .await;

        let response = frame(rx.recv().await.unwrap());
        assert_eq!(response["id"], json!(9));
        assert_eq!(response["result"]["ok"], json!(false));
        assert_eq!(response["result"]["error"], json!(FRAME_OVERFLOW_ERROR));
    }

    #[tokio::test]
    async fn notifications_share_the_response_lane_in_submission_order() {
        let (tx, mut rx) = mpsc::channel(4);
        let emitter = Emitter::new(tx);

        emitter.notify("status", json!({ "segments": {} }));
        emitter.respond(json!(7), json!({ "ok": true })).await;

        assert_eq!(frame(rx.recv().await.unwrap())["method"], json!("status"));
        assert_eq!(frame(rx.recv().await.unwrap())["id"], json!(7));
    }

    #[tokio::test]
    async fn closing_the_emitter_releases_the_writer_despite_retained_clones() {
        let (tx, mut rx) = mpsc::channel(4);
        let emitter = Emitter::new(tx);
        let retained = emitter.clone();

        emitter.notify("log", json!({}));
        assert!(rx.recv().await.is_some());

        emitter.close();
        retained.notify("log", json!({}));
        assert!(rx.recv().await.is_none());
    }

    #[tokio::test]
    async fn full_queue_drops_notifications_without_blocking() {
        let (tx, _rx) = mpsc::channel(1);
        let emitter = Emitter::new(tx);

        emitter.notify("log", json!({ "n": 1 }));
        // Must return immediately instead of awaiting queue space.
        emitter.notify("log", json!({ "n": 2 }));
    }

    #[tokio::test]
    async fn byte_budget_includes_the_frame_held_by_the_writer() {
        let (tx, mut rx) = mpsc::channel(64);
        let emitter = Emitter::new(tx);
        let value = json!({ "data": "x".repeat(9 * 1024 * 1024) });
        emitter.try_send(&value).unwrap();
        let writing = rx.recv().await.unwrap();
        assert_eq!(emitter.try_send(&value), Err(EmitError::Full));
        drop(writing);
        emitter.try_send(&value).unwrap();
    }
}
