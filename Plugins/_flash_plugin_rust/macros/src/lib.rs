//! The `plugin!` proc-macro: reads the crate's `manifest.json` (v2) at
//! compile time and generates the per-crate `FlashPlugin` trait plus the
//! `flash_plugin::Plugin` adapter that routes every wire request to the
//! matching trait method.
//!
//! `manifest.json` is the single source of truth. The macro inspects the
//! declared surfaces to decide which handler methods are *required*: warm
//! sources require `on_start`, `live: true` sources require `on_search`, a
//! `query` evaluator requires the synchronous `evaluate` hook, `hints`
//! requires `on_hints`, and the perform surfaces map one handler per kind —
//! `commands`/`bangs`/RPC-dispatched `verbs` require `on_command`, `actions`
//! requires `on_action`, `navigation` requires `on_navigate`. `on_resolve`
//! stays optional: a plugin whose rows carry only host-executed effects never
//! needs it.

use proc_macro::TokenStream;
use proc_macro2::{Ident, TokenStream as TokenStream2};
use quote::quote;
use serde_json::Value;
use std::path::PathBuf;

/// `flash_plugin::plugin!(MyPlugin);` — generate the typed plugin surface for
/// the type `MyPlugin` from this crate's `manifest.json`.
#[proc_macro]
pub fn plugin(input: TokenStream) -> TokenStream {
    let ty = parse_type(input.into());
    let manifest = load_manifest();

    let on_start_decl = on_start_decl(manifest_has_warm_sources(&manifest));
    let evaluate_decl = evaluate_decl(manifest_has_query_evaluator(&manifest));
    let on_search_decl = on_search_decl(manifest_has_live_sources(&manifest));
    let on_hints_decl = on_hints_decl(manifest_has_hints(&manifest));
    let on_command_decl = on_command_decl(manifest_has_command_surface(&manifest));
    let on_action_decl = on_action_decl(manifest_has_actions(&manifest));
    let on_navigate_decl = on_navigate_decl(manifest_has_navigation(&manifest));
    let expanded = quote! {
        /// The plugin contract for this crate, specialized to its
        /// `manifest.json`. Implement the required methods (warm sources make
        /// `on_start` required; live sources make `on_search` required;
        /// `query` makes the synchronous `evaluate` hook required; `hints`
        /// makes `on_hints` required; `commands`/`bangs`/RPC verbs make
        /// `on_command` required; `actions` makes `on_action` required;
        /// `navigation` makes `on_navigate` required); override any remaining
        /// defaulted handler the plugin serves.
        pub trait FlashPlugin: ::core::marker::Send + ::core::marker::Sync + 'static {
            #on_start_decl

            /// Handle a subscribed host event (`core:focus.changed`, …).
            fn on_event(
                &self,
                ctx: ::flash_plugin::Context,
                event: ::flash_plugin::Event,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                let _ = (ctx, event);
                async {}
            }

            #evaluate_decl

            #on_search_decl

            #on_hints_decl

            #on_command_decl

            #on_action_decl

            #on_navigate_decl

            /// Resolve a catalog row this plugin published
            /// (`perform {kind: "resolve"}`). Rows must resolve from their own
            /// content: a restarted plugin still answers for rows published
            /// before the restart.
            fn on_resolve(
                &self,
                ctx: ::flash_plugin::Context,
                row: ::flash_plugin::Candidate,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::PerformResponse> + ::core::marker::Send
            {
                let _ = (ctx, row);
                async { ::flash_plugin::PerformResponse::unhandled() }
            }

            /// Clean up on stdin EOF, just before the process exits.
            fn on_shutdown(
                &self,
                ctx: ::flash_plugin::Context,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                let _ = ctx;
                async {}
            }
        }

        impl ::flash_plugin::Plugin for #ty {
            fn on_start(
                &self,
                ctx: ::flash_plugin::Context,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                <Self as FlashPlugin>::on_start(self, ctx)
            }

            fn on_event(
                &self,
                ctx: ::flash_plugin::Context,
                event: ::flash_plugin::Event,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                <Self as FlashPlugin>::on_event(self, ctx, event)
            }

            fn evaluate(
                &self,
                request: ::flash_plugin::EvaluateRequest,
            ) -> ::flash_plugin::EvaluateResponse {
                <Self as FlashPlugin>::evaluate(self, request)
            }

            fn on_search(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::SearchRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::SearchResponse> + ::core::marker::Send
            {
                <Self as FlashPlugin>::on_search(self, ctx, request)
            }

            fn on_hints(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::HintsRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::HintsResponse> + ::core::marker::Send
            {
                <Self as FlashPlugin>::on_hints(self, ctx, request)
            }

            fn perform(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::Perform,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::PerformResponse> + ::core::marker::Send
            {
                async move {
                    match request {
                        ::flash_plugin::Perform::Resolve(row) => {
                            <Self as FlashPlugin>::on_resolve(self, ctx, row).await
                        }
                        ::flash_plugin::Perform::Command(command) => {
                            <Self as FlashPlugin>::on_command(self, ctx, command).await
                        }
                        ::flash_plugin::Perform::Action(action) => {
                            <Self as FlashPlugin>::on_action(self, ctx, action).await
                        }
                        ::flash_plugin::Perform::Navigate(request) => {
                            <Self as FlashPlugin>::on_navigate(self, ctx, request).await
                        }
                    }
                }
            }

            fn on_shutdown(
                &self,
                ctx: ::flash_plugin::Context,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                <Self as FlashPlugin>::on_shutdown(self, ctx)
            }
        }

        const _: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/manifest.json"));
    };

    expanded.into()
}

/// Pull the first identifier out of the macro input — the plugin type name.
fn parse_type(input: TokenStream2) -> Ident {
    input
        .into_iter()
        .find_map(|tt| match tt {
            proc_macro2::TokenTree::Ident(ident) => Some(ident),
            _ => None,
        })
        .unwrap_or_else(|| {
            panic!("flash_plugin::plugin! expects a type name, e.g. plugin!(Clipboard)")
        })
}

/// Read and parse this crate's `manifest.json` at macro-expansion time. Cargo
/// sets `CARGO_MANIFEST_DIR` to the *caller* crate's root for each rustc run, so
/// this resolves to the plugin's own manifest.
fn load_manifest() -> Value {
    let dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("flash_plugin::plugin!: CARGO_MANIFEST_DIR is not set");
    let path = PathBuf::from(dir).join("manifest.json");
    // Compile-time proc-macro expansion — not on an async runtime, so blocking
    // I/O is correct here.
    #[allow(clippy::disallowed_methods)]
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|err| {
        panic!(
            "flash_plugin::plugin!: cannot read {}: {err}",
            path.display()
        )
    });
    serde_json::from_str(&raw).unwrap_or_else(|err| {
        panic!(
            "flash_plugin::plugin!: invalid JSON in {}: {err}",
            path.display()
        )
    })
}

fn sources(manifest: &Value) -> &[Value] {
    manifest
        .get("sources")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn source_is_live(source: &Value) -> bool {
    source.get("live").and_then(Value::as_bool) == Some(true)
}

/// Warm (push-published) sources make `on_start` required: the hook runs
/// after the initialize reply and publishes the initial catalog when ready.
fn manifest_has_warm_sources(manifest: &Value) -> bool {
    sources(manifest)
        .iter()
        .any(|source| !source_is_live(source))
}

fn manifest_has_live_sources(manifest: &Value) -> bool {
    sources(manifest).iter().any(source_is_live)
}

fn manifest_has_query_evaluator(manifest: &Value) -> bool {
    matches!(manifest.get("query"), Some(Value::Object(_)))
}

fn manifest_has_hints(manifest: &Value) -> bool {
    matches!(manifest.get("hints"), Some(Value::Object(_)))
}

/// Whether the manifest declares a surface dispatched as
/// `perform {kind: "command"}`: `:`-commands, bangs, or verbs without a
/// host-handled fixed keystroke.
fn manifest_has_command_surface(manifest: &Value) -> bool {
    let commands = manifest
        .get("commands")
        .and_then(Value::as_array)
        .map(|items| !items.is_empty())
        .unwrap_or(false);
    let bangs = manifest
        .get("bangs")
        .and_then(|bangs| bangs.get("items"))
        .and_then(Value::as_array)
        .map(|items| !items.is_empty())
        .unwrap_or(false);
    let rpc_verbs = manifest
        .get("verbs")
        .and_then(Value::as_array)
        .map(|verbs| verbs.iter().any(|verb| verb.get("keystrokes").is_none()))
        .unwrap_or(false);
    commands || bangs || rpc_verbs
}

fn manifest_has_actions(manifest: &Value) -> bool {
    manifest
        .get("actions")
        .and_then(Value::as_array)
        .map(|actions| !actions.is_empty())
        .unwrap_or(false)
}

fn manifest_has_navigation(manifest: &Value) -> bool {
    manifest
        .get("navigation")
        .and_then(Value::as_array)
        .map(|schemes| !schemes.is_empty())
        .unwrap_or(false)
}

/// Wrap `signature` as required (no default body) or defaulted with `body`.
fn declare(signature: TokenStream2, body: TokenStream2, required: bool) -> TokenStream2 {
    if required {
        quote! { #signature; }
    } else {
        quote! { #signature { #body } }
    }
}

fn on_start_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Refresh and [`publish`](::flash_plugin::Context::publish) this
            /// plugin's warm catalog. Runs after the initialize reply; the
            /// flashlight reads the host store and never waits on it.
            fn on_start(
                &self,
                ctx: ::flash_plugin::Context,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send
        },
        quote! {
            let _ = ctx;
            async {}
        },
        required,
    )
}

/// Query evaluation is deliberately synchronous and receives no Context. This
/// makes filesystem, subprocess, network, and host RPC I/O unavailable through
/// the SDK surface used on every flashlight keystroke.
fn evaluate_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Return ephemeral answer candidates for one exact input.
            fn evaluate(
                &self,
                request: ::flash_plugin::EvaluateRequest,
            ) -> ::flash_plugin::EvaluateResponse
        },
        quote! {
            let _ = request;
            ::flash_plugin::EvaluateResponse::default()
        },
        required,
    )
}

/// `on_search` is required when the manifest declares any `live: true`
/// source. Unlike `evaluate` it is async — live sources exist precisely
/// because their work can't be precomputed.
fn on_search_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Answer one explicitly scoped query against this plugin's
            /// `live: true` sources. The host drops late replies; return
            /// complete catalog-shaped rows.
            fn on_search(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::SearchRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::SearchResponse> + ::core::marker::Send
        },
        quote! {
            let _ = (ctx, request);
            async { ::flash_plugin::SearchResponse::default() }
        },
        required,
    )
}

fn on_hints_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Produce hint targets for the focused app. Always live.
            fn on_hints(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::HintsRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::HintsResponse> + ::core::marker::Send
        },
        quote! {
            let _ = (ctx, request);
            async { ::flash_plugin::HintsResponse::default() }
        },
        required,
    )
}

fn on_command_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Run a `:`-command, bang, or verb the plugin registered
            /// (`perform {kind: "command"}`).
            fn on_command(
                &self,
                ctx: ::flash_plugin::Context,
                command: ::flash_plugin::CommandRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::PerformResponse> + ::core::marker::Send
        },
        quote! {
            let _ = (ctx, command);
            async { ::flash_plugin::PerformResponse::unhandled() }
        },
        required,
    )
}

fn on_action_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Perform a source action (e.g. tab select/cycle)
            /// (`perform {kind: "action"}`).
            fn on_action(
                &self,
                ctx: ::flash_plugin::Context,
                action: ::flash_plugin::ActionRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::PerformResponse> + ::core::marker::Send
        },
        quote! {
            let _ = (ctx, action);
            async { ::flash_plugin::PerformResponse::unhandled() }
        },
        required,
    )
}

fn on_navigate_decl(required: bool) -> TokenStream2 {
    declare(
        quote! {
            /// Restore a movement-history route whose URL scheme this plugin
            /// registered (`perform {kind: "navigate"}`).
            fn on_navigate(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::NavigateRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::PerformResponse> + ::core::marker::Send
        },
        quote! {
            let _ = (ctx, request);
            async { ::flash_plugin::PerformResponse::unhandled() }
        },
        required,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn warm_sources_require_the_startup_hook_and_live_sources_require_search() {
        let warm = json!({ "sources": [{ "name": "example.items" }] });
        assert!(manifest_has_warm_sources(&warm));
        assert!(!manifest_has_live_sources(&warm));

        let live = json!({ "sources": [{ "name": "example.results", "live": true }] });
        assert!(!manifest_has_warm_sources(&live));
        assert!(manifest_has_live_sources(&live));

        assert!(!manifest_has_warm_sources(&json!({ "sources": [] })));
        assert!(!manifest_has_warm_sources(&json!({})));
    }

    #[test]
    fn query_and_hints_sections_require_their_handlers() {
        assert!(manifest_has_query_evaluator(&json!({ "query": {} })));
        assert!(!manifest_has_query_evaluator(&json!({})));
        assert!(manifest_has_hints(&json!({ "hints": {} })));
        assert!(!manifest_has_hints(&json!({})));
    }

    #[test]
    fn command_surface_spans_commands_bangs_and_rpc_verbs() {
        assert!(manifest_has_command_surface(&json!({
            "commands": [{ "command": "x" }]
        })));
        assert!(manifest_has_command_surface(&json!({
            "bangs": { "command": "x", "items": [{ "token": "y" }] }
        })));
        // A verb without a fixed keystroke needs plugin RPC dispatch; one
        // with a keystroke is handled entirely host-side.
        assert!(manifest_has_command_surface(&json!({
            "verbs": [{ "name": "set_mark" }]
        })));
        assert!(!manifest_has_command_surface(&json!({
            "verbs": [{ "name": "save", "keystrokes": { "": "cmd+s" } }]
        })));
        assert!(!manifest_has_command_surface(&json!({ "commands": [] })));
        assert!(!manifest_has_command_surface(&json!({})));
    }

    #[test]
    fn perform_kind_sections_require_their_handlers() {
        assert!(manifest_has_actions(&json!({ "actions": ["tab_select"] })));
        assert!(!manifest_has_actions(&json!({ "actions": [] })));
        assert!(manifest_has_navigation(&json!({ "navigation": ["tmux"] })));
        assert!(!manifest_has_navigation(&json!({})));
    }
}
