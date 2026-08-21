//! Outbound NDJSON emission: one shared bounded queue drained by a single
//! stdout writer. Responses, plugin→host requests, and notifications all
//! share it — ordering is submission order, and the only frame policy is the
//! 10 MiB cap (an oversized response is substituted with the canonical
//! `response exceeded outbound frame limit` error under the same id).

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::mpsc;

/// Wire frame cap, both directions (`quotas.frame_bytes` in protocol.json).
pub(crate) const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
pub(crate) const OUTBOUND_QUEUE_CAPACITY: usize = 1024;

/// Canonical substitution error for an outbound response above the frame cap.
pub(crate) const FRAME_OVERFLOW_ERROR: &str = "response exceeded outbound frame limit";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EmitError {
    /// The frame could not be encoded or exceeded the cap.
    Rejected,
    /// The writer is gone (stdout closed or the emitter was shut down).
    Closed,
}

/// Cloneable handle feeding the single stdout writer task. `close()` detaches
/// the queue so graceful shutdown can drain and exit even while detached
/// interval tasks still hold [`Context`](crate::Context) clones.
#[derive(Clone)]
pub(crate) struct Emitter {
    sender: Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>>,
}

impl Emitter {
    pub(crate) fn new(sender: mpsc::Sender<Vec<u8>>) -> Self {
        Self {
            sender: Arc::new(Mutex::new(Some(sender))),
        }
    }

    fn encode(value: &Value) -> Option<Vec<u8>> {
        let mut payload = serde_json::to_vec(value).ok()?;
        if payload.len() > MAX_FRAME_BYTES {
            return None;
        }
        payload.push(b'\n');
        Some(payload)
    }

    fn sender(&self) -> Option<mpsc::Sender<Vec<u8>>> {
        self.sender.lock().ok().and_then(|sender| sender.clone())
    }

    async fn send(&self, value: &Value) -> Result<(), EmitError> {
        let payload = Self::encode(value).ok_or(EmitError::Rejected)?;
        let sender = self.sender().ok_or(EmitError::Closed)?;
        sender.send(payload).await.map_err(|_| EmitError::Closed)
    }

    /// Emit a notification without blocking. Used for `publish`/`status`/`log`
    /// frames from sync call sites; a full queue or an oversized frame drops
    /// the notification with a content-free stderr diagnostic (stderr is the
    /// last-resort channel precisely because the frame itself cannot go out).
    pub(crate) fn notify(&self, method: &str, params: Value) {
        let value = json!({ "method": method, "params": params });
        let Some(payload) = Self::encode(&value) else {
            eprintln!("[plugin] dropped oversized outbound {method} notification");
            return;
        };
        let Some(sender) = self.sender() else {
            return;
        };
        if let Err(mpsc::error::TrySendError::Full(_)) = sender.try_send(payload) {
            eprintln!("[plugin] outbound queue full; dropped {method} notification");
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

    pub(crate) fn log(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.notify(
            "log",
            json!({ "level": level, "message": message, "fields": fields }),
        );
    }

    /// Detach the queue: buffered frames still drain, later emits become
    /// no-ops.
    pub(crate) fn close(&self) {
        if let Ok(mut sender) = self.sender.lock() {
            sender.take();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload: Vec<u8>) -> Value {
        serde_json::from_slice(&payload).unwrap()
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
}
