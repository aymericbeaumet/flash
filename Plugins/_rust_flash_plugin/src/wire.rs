//! Length-prefixed MessagePack framing: the outbound control/telemetry lanes,
//! their frame-size bounds, and the emitter/receiver pair the serve loop and
//! [`Context`](crate::Context) share.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::mpsc;

pub(crate) const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
pub(crate) const MAX_TELEMETRY_FRAME_BYTES: usize = 256 * 1024;
pub(crate) const CONTROL_QUEUE_CAPACITY: usize = 64;
pub(crate) const TELEMETRY_QUEUE_CAPACITY: usize = 128;

/// Protocol responses and plugin→host calls use a bounded control lane.
/// Telemetry/status notifications use a separate bounded lane. The writer
/// always drains ready control frames first, so log storms cannot delay a
/// `sources.snapshot`, query, heartbeat, or shutdown response.
#[derive(Clone)]
pub(crate) struct Emitter {
    senders: Arc<Mutex<EmitterSenders>>,
    telemetry_drops: Arc<AtomicU64>,
}

struct EmitterSenders {
    control: Option<mpsc::Sender<Vec<u8>>>,
    telemetry: Option<mpsc::Sender<Vec<u8>>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FrameEncodingError {
    Serialization,
    Oversized {
        encoded_bytes: usize,
        limit_bytes: usize,
    },
}

impl FrameEncodingError {
    fn reason(self) -> &'static str {
        match self {
            FrameEncodingError::Serialization => "serialization_failed",
            FrameEncodingError::Oversized { .. } => "frame_too_large",
        }
    }

    fn response_error(self) -> &'static str {
        match self {
            FrameEncodingError::Serialization => "plugin response serialization failed",
            FrameEncodingError::Oversized { .. } => "plugin response exceeded outbound frame limit",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ControlSendError {
    Encoding(FrameEncodingError),
    Closed,
}

pub(crate) struct OutboundReceiver {
    control: mpsc::Receiver<Vec<u8>>,
    telemetry: mpsc::Receiver<Vec<u8>>,
    control_open: bool,
    telemetry_open: bool,
}

impl OutboundReceiver {
    pub(crate) fn new(
        control: mpsc::Receiver<Vec<u8>>,
        telemetry: mpsc::Receiver<Vec<u8>>,
    ) -> Self {
        Self {
            control,
            telemetry,
            control_open: true,
            telemetry_open: true,
        }
    }

    pub(crate) async fn recv(&mut self) -> Option<Vec<u8>> {
        while self.control_open || self.telemetry_open {
            tokio::select! {
                biased;
                payload = self.control.recv(), if self.control_open => {
                    match payload {
                        Some(payload) => return Some(payload),
                        None => self.control_open = false,
                    }
                }
                payload = self.telemetry.recv(), if self.telemetry_open => {
                    match payload {
                        Some(payload) => return Some(payload),
                        None => self.telemetry_open = false,
                    }
                }
            }
        }
        None
    }
}

impl Emitter {
    pub(crate) fn new(control: mpsc::Sender<Vec<u8>>, telemetry: mpsc::Sender<Vec<u8>>) -> Self {
        Self {
            senders: Arc::new(Mutex::new(EmitterSenders {
                control: Some(control),
                telemetry: Some(telemetry),
            })),
            telemetry_drops: Arc::new(AtomicU64::new(0)),
        }
    }

    fn encode(value: &Value, limit_bytes: usize) -> Result<Vec<u8>, FrameEncodingError> {
        let payload = rmp_serde::to_vec(value).map_err(|_| FrameEncodingError::Serialization)?;
        if payload.len() > limit_bytes {
            return Err(FrameEncodingError::Oversized {
                encoded_bytes: payload.len(),
                limit_bytes,
            });
        }
        Ok(payload)
    }

    fn report_frame_rejection(&self, lane: &'static str, error: FrameEncodingError) {
        let mut fields = BTreeMap::from([
            ("lane".to_string(), lane.to_string()),
            ("reason".to_string(), error.reason().to_string()),
        ]);
        match error {
            FrameEncodingError::Serialization => {
                eprintln!(
                    "[plugin] outbound frame rejected lane={lane} reason={}",
                    error.reason(),
                );
            }
            FrameEncodingError::Oversized {
                encoded_bytes,
                limit_bytes,
            } => {
                fields.insert("encoded_bytes".to_string(), encoded_bytes.to_string());
                fields.insert("limit_bytes".to_string(), limit_bytes.to_string());
                eprintln!(
                    "[plugin] outbound frame rejected lane={lane} reason={} limit_bytes={limit_bytes}",
                    error.reason(),
                );
            }
        }

        // stderr is the last-resort diagnostic channel when the rejected frame
        // itself cannot traverse stdout. Never include the original payload.
        let diagnostic = json!({
            "jsonrpc": "2.0",
            "method": "flash.log",
            "params": {
                "level": "warn",
                "message": "[plugin] outbound frame rejected",
                "fields": fields,
            },
        });
        if let Ok(payload) = Self::encode(&diagnostic, MAX_TELEMETRY_FRAME_BYTES) {
            self.try_send_telemetry(payload);
        }
    }

    async fn send_control(&self, lane: &'static str, value: Value) -> Result<(), ControlSendError> {
        let payload = match Self::encode(&value, MAX_FRAME_BYTES) {
            Ok(payload) => payload,
            Err(error) => {
                self.report_frame_rejection(lane, error);
                return Err(ControlSendError::Encoding(error));
            }
        };
        let sender = self
            .senders
            .lock()
            .ok()
            .and_then(|senders| senders.control.clone())
            .ok_or(ControlSendError::Closed)?;
        sender
            .send(payload)
            .await
            .map_err(|_| ControlSendError::Closed)
    }

    fn try_send_telemetry(&self, payload: Vec<u8>) {
        let sender = self
            .senders
            .lock()
            .ok()
            .and_then(|senders| senders.telemetry.clone());
        let Some(sender) = sender else {
            return;
        };
        match sender.try_send(payload) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                let dropped = self.telemetry_drops.fetch_add(1, Ordering::Relaxed) + 1;
                if dropped == 1 || dropped.is_power_of_two() {
                    eprintln!(
                        "[plugin] outbound telemetry queue full; dropped_frames={dropped} capacity={TELEMETRY_QUEUE_CAPACITY}"
                    );
                }
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {}
        }
    }

    /// Close both shared output lanes even when detached plugin tasks still
    /// retain `Context` clones. Queued frames drain first; later emits become
    /// no-ops. This lets graceful shutdown finish without waiting for interval
    /// loops that the tokio runtime will cancel as it drops.
    pub(crate) fn close(&self) {
        if let Ok(mut senders) = self.senders.lock() {
            senders.control.take();
            senders.telemetry.take();
        }
    }

    pub(crate) fn notify(&self, method: &str, params: Value) {
        let value = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        match Self::encode(&value, MAX_TELEMETRY_FRAME_BYTES) {
            Ok(payload) => self.try_send_telemetry(payload),
            Err(error) => self.report_frame_rejection("telemetry", error),
        }
    }

    pub(crate) async fn request(
        &self,
        id: u64,
        method: &str,
        params: Value,
    ) -> Result<(), ControlSendError> {
        self.send_control(
            "host_request",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            }),
        )
        .await
    }

    pub(crate) async fn respond(&self, id: Value, result: Value) {
        if id.is_null() {
            return;
        }
        let response = json!({ "jsonrpc": "2.0", "id": id.clone(), "result": result });
        if let Err(error) = self.send_control("response", response).await {
            let ControlSendError::Encoding(encoding_error) = error else {
                return;
            };
            let fallback = json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "ok": false,
                    "error": encoding_error.response_error(),
                },
            });
            // The fallback is fixed-size and content-free. Failure here means
            // stdout has closed; there is no remaining protocol path to report.
            let _ = self.send_control("response_error", fallback).await;
        }
    }

    pub(crate) fn log(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.notify(
            "flash.log",
            json!({ "level": level, "message": message, "fields": fields }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn control_responses_overtake_queued_telemetry() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter.notify("status.updated", json!({ "segments": {} }));
        emitter.respond(json!(7), json!({ "ok": true })).await;

        let first = outbound.recv().await.unwrap();
        let first: Value = rmp_serde::from_slice(&first).unwrap();
        assert_eq!(first.get("id"), Some(&json!(7)));

        let second = outbound.recv().await.unwrap();
        let second: Value = rmp_serde::from_slice(&second).unwrap();
        assert_eq!(
            second.get("method").and_then(Value::as_str),
            Some("status.updated")
        );
    }

    #[tokio::test]
    async fn outbound_telemetry_queue_is_bounded() {
        let (control_tx, _control_rx) = mpsc::channel(1);
        let (telemetry_tx, _telemetry_rx) = mpsc::channel(1);
        let emitter = Emitter::new(control_tx, telemetry_tx);

        emitter.notify("status.updated", json!({ "segments": {} }));
        emitter.notify("status.updated", json!({ "segments": {} }));

        assert_eq!(emitter.telemetry_drops.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn oversized_response_becomes_small_explicit_error() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter
            .respond(json!(9), json!({ "value": "x".repeat(MAX_FRAME_BYTES) }))
            .await;

        let payload = outbound.recv().await.unwrap();
        let response: Value = rmp_serde::from_slice(&payload).unwrap();
        assert_eq!(response.get("id"), Some(&json!(9)));
        assert_eq!(
            response.pointer("/result/error").and_then(Value::as_str),
            Some("plugin response exceeded outbound frame limit")
        );
    }

    #[tokio::test]
    async fn oversized_notification_emits_content_free_warning() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter.notify(
            "status.updated",
            json!({ "value": "x".repeat(MAX_TELEMETRY_FRAME_BYTES) }),
        );

        let payload = outbound.recv().await.unwrap();
        let warning: Value = rmp_serde::from_slice(&payload).unwrap();
        assert_eq!(
            warning.get("method").and_then(Value::as_str),
            Some("flash.log")
        );
        assert_eq!(
            warning.pointer("/params/message").and_then(Value::as_str),
            Some("[plugin] outbound frame rejected")
        );
        assert!(warning.to_string().len() < 1_000);
    }

    #[tokio::test]
    async fn closing_emitter_releases_writer_despite_retained_context_clone() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);
        let retained = emitter.clone();

        emitter.notify("before.close", json!({}));
        assert!(outbound.recv().await.is_some());

        emitter.close();
        retained.notify("after.close", json!({}));
        assert!(outbound.recv().await.is_none());
    }
}
