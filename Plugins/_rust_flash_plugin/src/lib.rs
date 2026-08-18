//! Strongly-typed tokio scaffolding for Flash plugins.
//!
//! This crate speaks the length-prefixed MessagePack wire protocol over
//! stdin/stdout — a 4-byte big-endian payload length followed by a
//! MessagePack-encoded value — plus request/response correlation, the
//! `initialize`/`heartbeat`/`shutdown` lifecycle, and structured logging.
//! Everything a plugin touches is a typed value: a plugin receives a
//! [`Request`] / [`Event`] and returns a [`Response`].

mod context;
mod limits;
pub mod process;
mod runtime;
mod types;
mod wire;

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

pub use context::{
    applescript_quote, run_command, run_osascript, shorten, CommandOutput, Context,
    NormalModeTarget, RefreshGate,
};
pub use runtime::{run, Plugin};
pub use types::{
    candidate_metadata, ActionContext, ActivateRequest, Candidate, CandidateEffect, CommandRequest,
    CommandResponse, DiscoverRequest, DiscoverResponse, Event, Frame, JumpTarget,
    NavigationRequest, Priority, QueryAnswer, QueryEvaluateRequest, QueryEvaluateResponse, Request,
    ResolveResponse, Response, RunningApplication, SourceActionRequest, SourceActionResponse,
};
