//! The `plugin!` proc-macro: reads the crate's `manifest.json` at compile time
//! and generates the per-crate `FlashPlugin` trait plus the `flash_plugin::Plugin`
//! adapter that routes every wire request to the matching trait method.
//!
//! `manifest.json` is the single source of truth. The macro inspects the
//! declared surfaces to decide which handler methods are *required*: commands
//! or shebangs require `on_command`, candidate sources require `on_start`, and
//! a `queries` provider requires the synchronous `query_evaluate` hook.

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

    let has_candidate_sources = manifest_has_candidate_sources(&manifest);
    let on_start_decl = on_start_decl(has_candidate_sources);
    let on_command_decl = on_command_decl(manifest_has_command(&manifest));
    let query_evaluate_decl = query_evaluate_decl(manifest_has_query_evaluator(&manifest));
    let expanded = quote! {
        /// The plugin contract for this crate, specialized to its `manifest.json`.
        /// Implement the required methods (`sources` makes `on_start` required;
        /// commands/shebangs make `on_command` required; `queries` makes the
        /// synchronous `query_evaluate` hook required); override any remaining
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

            #on_command_decl

            #query_evaluate_decl

            /// Resolve a flashlight candidate the plugin emitted.
            fn resolve_candidate(
                &self,
                ctx: ::flash_plugin::Context,
                candidate: ::flash_plugin::Candidate,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::ResolveResponse> + ::core::marker::Send
            {
                let _ = (ctx, candidate);
                async { ::flash_plugin::ResolveResponse::unresolved() }
            }

            /// Produce hint targets for the focused app.
            fn discover_targets(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::DiscoverRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::DiscoverResponse> + ::core::marker::Send
            {
                let _ = (ctx, request);
                async { ::flash_plugin::DiscoverResponse::default() }
            }

            /// Perform a source action (e.g. tab select/cycle).
            fn source_action(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::SourceActionRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::SourceActionResponse> + ::core::marker::Send
            {
                let _ = (ctx, request);
                async { ::flash_plugin::SourceActionResponse::unhandled() }
            }

            /// Restore a movement-history route whose URL scheme this plugin registered.
            fn restore_navigation(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::NavigationRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::SourceActionResponse> + ::core::marker::Send
            {
                let _ = (ctx, request);
                async { ::flash_plugin::SourceActionResponse::unhandled() }
            }

            /// Act on a hint target the plugin emitted (a notification; no reply).
            fn activate_target(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::ActivateRequest,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                let _ = (ctx, request);
                async {}
            }

            /// Clean up just before the process exits.
            fn on_shutdown(
                &self,
                ctx: ::flash_plugin::Context,
                reason: ::std::string::String,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                let _ = (ctx, reason);
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

            fn requires_initial_locations(&self) -> bool {
                #has_candidate_sources
            }

            fn on_event(
                &self,
                ctx: ::flash_plugin::Context,
                event: ::flash_plugin::Event,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                <Self as FlashPlugin>::on_event(self, ctx, event)
            }

            fn on_shutdown(
                &self,
                ctx: ::flash_plugin::Context,
                reason: ::std::string::String,
            ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send {
                <Self as FlashPlugin>::on_shutdown(self, ctx, reason)
            }

            fn handle(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::Request,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::Response> + ::core::marker::Send {
                async move {
                    match request {
                        ::flash_plugin::Request::Command(command) => ::flash_plugin::Response::Command(
                            <Self as FlashPlugin>::on_command(self, ctx, command).await,
                        ),
                        ::flash_plugin::Request::ResolveCandidate(candidate) => {
                            ::flash_plugin::Response::Resolve(
                                <Self as FlashPlugin>::resolve_candidate(self, ctx, candidate).await,
                            )
                        }
                        ::flash_plugin::Request::DiscoverTargets(request) => {
                            ::flash_plugin::Response::Discover(
                                <Self as FlashPlugin>::discover_targets(self, ctx, request).await,
                            )
                        }
                        ::flash_plugin::Request::SourceAction(request) => {
                            ::flash_plugin::Response::SourceAction(
                                <Self as FlashPlugin>::source_action(self, ctx, request).await,
                            )
                        }
                        ::flash_plugin::Request::RestoreNavigation(request) => {
                            ::flash_plugin::Response::SourceAction(
                                <Self as FlashPlugin>::restore_navigation(self, ctx, request).await,
                            )
                        }
                        ::flash_plugin::Request::ActivateTarget(request) => {
                            <Self as FlashPlugin>::activate_target(self, ctx, request).await;
                            ::flash_plugin::Response::None
                        }
                        ::flash_plugin::Request::QueryEvaluate(request) => {
                            ::flash_plugin::Response::QueryEvaluate(
                                <Self as FlashPlugin>::query_evaluate(self, request),
                            )
                        }
                        ::flash_plugin::Request::Unknown { method } => ::flash_plugin::Response::Command(
                            ::flash_plugin::CommandResponse::error(::std::format!(
                                "unknown method: {method}"
                            )),
                        ),
                    }
                }
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

/// Whether the manifest declares a command or shebang surface — either makes
/// `on_command` a required trait method.
fn manifest_has_command(manifest: &Value) -> bool {
    section_has_items(manifest, "commands") || section_has_items(manifest, "shebangs")
}

fn manifest_has_candidate_sources(manifest: &Value) -> bool {
    manifest
        .get("sources")
        .and_then(Value::as_array)
        .map(|sources| !sources.is_empty())
        .unwrap_or(false)
}

fn manifest_has_query_evaluator(manifest: &Value) -> bool {
    matches!(manifest.get("queries"), Some(Value::Object(_)))
}

fn section_has_items(manifest: &Value, section: &str) -> bool {
    manifest
        .get(section)
        .and_then(|value| value.get("items"))
        .and_then(Value::as_array)
        .map(|items| !items.is_empty())
        .unwrap_or(false)
}

/// `on_command` is required (no default body) when the manifest declares a
/// command surface, and defaulted otherwise.
fn on_command_decl(required: bool) -> TokenStream2 {
    let signature = quote! {
        /// Run a `:`-command or shebang the plugin registered.
        fn on_command(
            &self,
            ctx: ::flash_plugin::Context,
            command: ::flash_plugin::CommandRequest,
        ) -> impl ::core::future::Future<Output = ::flash_plugin::CommandResponse> + ::core::marker::Send
    };
    if required {
        quote! { #signature; }
    } else {
        quote! {
            #signature {
                let _ = (ctx, command);
                async { ::flash_plugin::CommandResponse::error("plugin declares no commands") }
            }
        }
    }
}

/// Query evaluation is deliberately synchronous and receives no Context. This
/// makes filesystem, subprocess, network, and host RPC I/O unavailable through
/// the SDK surface used on every flashlight keystroke.
fn query_evaluate_decl(required: bool) -> TokenStream2 {
    let signature = quote! {
        /// Return ephemeral answer candidates for one exact input.
        fn query_evaluate(
            &self,
            request: ::flash_plugin::QueryEvaluateRequest,
        ) -> ::flash_plugin::QueryEvaluateResponse
    };
    if required {
        quote! { #signature; }
    } else {
        quote! {
            #signature {
                let _ = request;
                ::flash_plugin::QueryEvaluateResponse::default()
            }
        }
    }
}

/// `on_start` is required when the manifest declares candidate sources. The SDK
/// runtime additionally verifies that it publishes the canonical aggregate
/// `plugin:<id>` warm-store key before the initialize response succeeds.
fn on_start_decl(required: bool) -> TokenStream2 {
    let signature = quote! {
        /// Seed this plugin's canonical aggregate warm store (`plugin:<id>`)
        /// before initialization completes. Publish an authoritative empty
        /// snapshot when no rows exist.
        fn on_start(
            &self,
            ctx: ::flash_plugin::Context,
        ) -> impl ::core::future::Future<Output = ()> + ::core::marker::Send
    };
    if required {
        quote! { #signature; }
    } else {
        quote! {
            #signature {
                let _ = ctx;
                async {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{manifest_has_candidate_sources, manifest_has_query_evaluator};
    use serde_json::json;

    #[test]
    fn candidate_sources_require_startup_hook() {
        assert!(manifest_has_candidate_sources(&json!({
            "sources": [{"name": "example.items"}]
        })));
        assert!(!manifest_has_candidate_sources(&json!({"sources": []})));
        assert!(!manifest_has_candidate_sources(&json!({})));
    }

    #[test]
    fn queries_require_synchronous_evaluator() {
        assert!(manifest_has_query_evaluator(&json!({"queries": {}})));
        assert!(!manifest_has_query_evaluator(&json!({})));
    }
}
