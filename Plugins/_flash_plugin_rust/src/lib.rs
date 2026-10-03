//! Strongly-typed tokio scaffolding for Flash plugins.
//!
//! This crate speaks the NDJSON wire protocol over stdin/stdout — UTF-8, one
//! JSON object per newline-terminated line — plus request/response
//! correlation, the immediate-initialize lifecycle, the unified `perform`
//! dispatch, the push-based `publish`/`status`/`log` notifications, and the
//! typed host RPC client. Everything a plugin touches is a typed value.

mod context;
mod deadline;
mod emit;
mod events;
mod framing;
mod observed;
mod poll;
pub mod process;
mod runtime;
mod settle;
pub mod status;
pub mod sys;
pub mod testing;
mod trace;
mod types;
mod wire;

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

pub use context::{
    AppWatch, CommandOutput, Context, NormalModeTarget, RefreshGate, applescript_quote,
    run_command, run_command_with_slow_threshold, run_osascript, shorten, spawn_managed,
};
pub use observed::ObservedCadences;
pub use poll::{Deadline, PollHandle, PollPriority};
pub use process::{ManagedChild, ManagedChildError};
pub use runtime::{Plugin, run};
pub use settle::Settle;
pub use status::{
    Align, Color, Column, History, MAX_INLINE_PREVIEW_ENCODED_BYTES, Markup, Preview,
    PreviewTooLarge, Published, StatusCarousel, StatusSegment, StatusValue, Style, Table,
};
pub use types::{
    ActionContext, ActionRequest, Candidate, CandidateEffect, CommandRequest, EvaluateRequest,
    EvaluateResponse, Event, Frame, HintsRequest, HintsResponse, JumpTarget, NavigateRequest,
    Perform, PerformResponse, Priority, QueryAnswer, RunningApplication, SearchRequest,
    SearchResponse, TERMINAL_LINK_ROLE, ax_notifications, candidate_metadata, host_events,
};
