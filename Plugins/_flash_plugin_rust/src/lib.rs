//! Strongly-typed tokio scaffolding for Flash plugins.
//!
//! This crate speaks the NDJSON wire protocol over stdin/stdout — UTF-8, one
//! JSON object per newline-terminated line — plus request/response
//! correlation, the immediate-initialize lifecycle, the unified `perform`
//! dispatch, the push-based `publish`/`status`/`log` notifications, and the
//! typed host RPC client. Everything a plugin touches is a typed value.

mod context;
mod emit;
pub mod process;
mod runtime;
pub mod testing;
mod types;

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

pub use context::{
    applescript_quote, run_command, run_osascript, shorten, spawn_managed, CommandOutput, Context,
    NormalModeTarget, RefreshGate,
};
pub use process::{ManagedChild, ManagedChildError};
pub use runtime::{run, Plugin};
pub use types::{
    candidate_metadata, ActionContext, ActionRequest, Candidate, CandidateEffect, CommandRequest,
    EvaluateRequest, EvaluateResponse, Event, Frame, HintsRequest, HintsResponse, JumpTarget,
    NavigateRequest, Perform, PerformResponse, Priority, QueryAnswer, RunningApplication,
    SearchRequest, SearchResponse, TERMINAL_LINK_ROLE,
};
