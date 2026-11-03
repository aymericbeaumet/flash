//! The `plugin!` proc-macro: reads the crate's `manifest.json` (v2) at
//! compile time and generates the per-crate `FlashPlugin` trait plus the
//! `flash_plugin::Plugin` adapter that routes every wire request to the
//! matching trait method.
//!
//! `manifest.json` is the single source of truth. The macro inspects the
//! declared surfaces to decide which handler methods are *required*:
//! `sources` require `on_start`, a `query` evaluator requires the
//! synchronous `evaluate` hook, `hints` requires `on_hints` (`on_text_grid`
//! stays optional with an empty default), and the perform surfaces map one
//! handler per kind — `commands`/`bangs` require `on_command`, which also
//! receives the core commands a manifest declares under one of Flash's
//! topics, and `navigation` requires `on_navigate`.
//! `on_resolve` stays optional: a plugin whose rows carry only host-executed
//! effects never needs it. A manifest `lifecycle` of `publish_then_exit`
//! makes `on_start` the whole run: the generated adapter tells the runtime
//! to exit 0 once it returns.

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
    let type_errors = source_type_errors(&manifest);
    assert!(
        type_errors.is_empty(),
        "flash_plugin::plugin!: manifest.json {}",
        type_errors.join("; ")
    );
    let lifecycle_errors = lifecycle_errors(&manifest);
    assert!(
        lifecycle_errors.is_empty(),
        "flash_plugin::plugin!: manifest.json {}",
        lifecycle_errors.join("; ")
    );
    let exits_after_start = manifest_exits_after_start(&manifest);

    let on_start_decl = on_start_decl(manifest_has_warm_sources(&manifest));
    let evaluate_decl = evaluate_decl(manifest_has_query_evaluator(&manifest));
    let on_hints_decl = on_hints_decl(manifest_has_hints(&manifest));
    let on_command_decl = on_command_decl(manifest_has_command_surface(&manifest));
    let on_navigate_decl = on_navigate_decl(manifest_has_navigation(&manifest));
    let expanded = quote! {
        /// The plugin contract for this crate, specialized to its
        /// `manifest.json`. Implement the required methods (`sources` make
        /// `on_start` required; `query` makes the synchronous `evaluate`
        /// hook required; `hints` makes `on_hints` required;
        /// `commands`/`bangs` make `on_command` required; `navigation`
        /// makes `on_navigate` required); override any remaining defaulted
        /// handler the plugin serves.
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

            #on_hints_decl

            /// The focused app's visible text as a cell grid (`text_grid`),
            /// for a letter search in an app that publishes no
            /// Accessibility text. Optional: the empty default means no
            /// grid. Always live.
            fn on_text_grid(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::TextGridRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::TextGridResponse> + ::core::marker::Send
            {
                let _ = (ctx, request);
                async { ::flash_plugin::TextGridResponse::default() }
            }

            #on_command_decl

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

            fn on_hints(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::HintsRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::HintsResponse> + ::core::marker::Send
            {
                <Self as FlashPlugin>::on_hints(self, ctx, request)
            }

            fn on_text_grid(
                &self,
                ctx: ::flash_plugin::Context,
                request: ::flash_plugin::TextGridRequest,
            ) -> impl ::core::future::Future<Output = ::flash_plugin::TextGridResponse> + ::core::marker::Send
            {
                <Self as FlashPlugin>::on_text_grid(self, ctx, request)
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

            fn exits_after_start(&self) -> bool {
                #exits_after_start
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

/// Every `sources[]` entry declares one resource type, checked against
/// `protocol.json`'s `source_types` — the rules the host applies again at
/// load: one lowercase word, never one Flash feeds itself, and of a shared
/// type's fixed kind. One message per offending source.
fn source_type_errors(manifest: &Value) -> Vec<String> {
    let protocol: Value = serde_json::from_str(include_str!("../../protocol.json"))
        .expect("protocol.json is valid JSON");
    let table = &protocol["source_types"];
    let core: Vec<&str> = table["core"]
        .as_array()
        .map(|core| core.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let shared = table["shared"].as_object();
    let mut errors = Vec::new();
    for source in sources(manifest) {
        let name = source.get("name").and_then(Value::as_str).unwrap_or("?");
        let kind = source
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("default");
        let Some(ty) = source
            .get("type")
            .and_then(Value::as_str)
            .filter(|ty| !ty.is_empty())
        else {
            errors.push(format!(
                "source {name} has no type (one lowercase word such as tabs)"
            ));
            continue;
        };
        let mut chars = ty.chars();
        let valid = chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
        if !valid {
            errors.push(format!(
                "source {name} type {ty} is not one lowercase word (a letter, then letters or digits)"
            ));
        } else if core.contains(&ty) {
            errors.push(format!(
                "source {name} type {ty} is fed by Flash itself; plugins cannot declare it"
            ));
        } else if let Some(fixed) = shared
            .and_then(|shared| shared.get(ty))
            .and_then(Value::as_str)
            && fixed != kind
        {
            errors.push(format!(
                "source {name} type {ty} is a {fixed} type; this source is {kind}"
            ));
        }
    }
    errors
}

/// Sources are push-published catalogs, so any makes `on_start` required:
/// the hook runs after the initialize reply and publishes the initial catalog
/// when ready.
fn manifest_has_warm_sources(manifest: &Value) -> bool {
    !sources(manifest).is_empty()
}

/// The manifest `lifecycle` table of `protocol.json`.
fn lifecycle_contract() -> Value {
    let protocol: Value = serde_json::from_str(include_str!("../../protocol.json"))
        .expect("protocol.json is valid JSON");
    protocol["lifecycle"].clone()
}

/// `lifecycle: publish_then_exit` ends the run after `on_start`.
fn manifest_exits_after_start(manifest: &Value) -> bool {
    manifest.get("lifecycle").and_then(Value::as_str) == Some("publish_then_exit")
}

/// The `lifecycle` rules the host applies at load, checked at build time:
/// the one spelled value, `sources` beside it, and none of the surfaces a
/// live child serves (`protocol.json` `lifecycle.publish_then_exit.forbids`).
fn lifecycle_errors(manifest: &Value) -> Vec<String> {
    let Some(declared) = manifest.get("lifecycle") else {
        return Vec::new();
    };
    let contract = lifecycle_contract();
    let values: Vec<&str> = contract["values"]
        .as_array()
        .map(|values| values.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let Some(lifecycle) = declared.as_str().filter(|value| values.contains(value)) else {
        return vec![format!(
            "lifecycle must be {} (or absent: the surfaces decide)",
            values
                .iter()
                .map(|value| format!("\"{value}\""))
                .collect::<Vec<_>>()
                .join(" or ")
        )];
    };
    if !manifest_has_warm_sources(manifest) {
        return vec![format!("lifecycle {lifecycle} needs sources")];
    }
    let declared_surfaces: Vec<&str> = contract[lifecycle]["forbids"]
        .as_array()
        .map(|forbidden| {
            forbidden
                .iter()
                .filter_map(Value::as_str)
                .filter(|key| match manifest.get(key) {
                    Some(Value::Array(items)) => !items.is_empty(),
                    Some(Value::Object(_)) => true,
                    Some(_) => true,
                    None => false,
                })
                .collect()
        })
        .unwrap_or_default();
    if declared_surfaces.is_empty() {
        Vec::new()
    } else {
        vec![format!(
            "lifecycle {lifecycle} allows sources alone: remove {}",
            declared_surfaces.join(", ")
        )]
    }
}

fn manifest_has_query_evaluator(manifest: &Value) -> bool {
    matches!(manifest.get("query"), Some(Value::Object(_)))
}

fn manifest_has_hints(manifest: &Value) -> bool {
    matches!(manifest.get("hints"), Some(Value::Object(_)))
}

/// Whether the manifest declares a surface dispatched as
/// `perform {kind: "command"}`: `:`-commands or bangs (`bangs` is the list
/// of entries itself).
fn manifest_has_command_surface(manifest: &Value) -> bool {
    ["commands", "bangs"].iter().any(|surface| {
        manifest
            .get(surface)
            .and_then(Value::as_array)
            .is_some_and(|items| !items.is_empty())
    })
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
            /// Run a command (`perform {kind: "command"}`): a core command
            /// the manifest declares under one of Flash's topics, with the
            /// focused app as `context`; the plugin's own command; or a bang,
            /// which arrives with the plugin id as the command and its token
            /// as the subcommand.
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
    fn source_types_follow_the_protocol_rules() {
        let ok = json!({ "sources": [
            { "name": "a.tabs", "type": "tabs", "kind": "locations" },
            { "name": "a.things", "type": "things" },
        ] });
        assert_eq!(source_type_errors(&ok), Vec::<String>::new());
        let first = |manifest: Value| source_type_errors(&manifest).remove(0);
        assert!(first(json!({ "sources": [{ "name": "a.items" }] })).contains("has no type"));
        assert!(
            first(json!({ "sources": [{ "name": "a.items", "type": "emojis.glyphs" }] }))
                .contains("one lowercase word")
        );
        assert!(
            first(json!({ "sources": [{ "name": "a.apps", "type": "apps" }] }))
                .contains("fed by Flash")
        );
        assert!(
            first(json!({ "sources": [{ "name": "a.tabs", "type": "tabs" }] }))
                .contains("locations")
        );
    }

    #[test]
    fn sources_require_the_startup_hook() {
        let warm = json!({ "sources": [{ "name": "example.items" }] });
        assert!(manifest_has_warm_sources(&warm));

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
    fn command_surface_spans_commands_and_bangs() {
        assert!(manifest_has_command_surface(&json!({
            "commands": [{ "command": "x" }]
        })));
        // `bangs` is the list of entries itself.
        assert!(manifest_has_command_surface(&json!({
            "bangs": [{ "token": "y" }]
        })));
        assert!(!manifest_has_command_surface(&json!({ "bangs": [] })));
        // A core command the plugin performs is a `commands[]` entry too.
        assert!(manifest_has_command_surface(&json!({
            "commands": [{ "command": "tab", "subcommand": "close" }]
        })));
        // What an app does for Flash's own commands is host-served data.
        assert!(!manifest_has_command_surface(&json!({
            "bindings": { "app save": { "": "cmd+s" } }
        })));
        assert!(!manifest_has_command_surface(&json!({ "commands": [] })));
        assert!(!manifest_has_command_surface(&json!({})));
    }

    /// `lifecycle: publish_then_exit` ends the run after `on_start`; it needs
    /// `sources` and allows nothing a live child would serve. The value set
    /// and the forbidden surfaces come from `protocol.json`.
    #[test]
    fn a_publish_then_exit_lifecycle_is_a_catalog_alone() {
        let catalog = json!({
            "exec": ["./x"], "lifecycle": "publish_then_exit",
            "sources": [{ "name": "a.items", "type": "items" }],
            "watch_settings": ["file"],
            "bindings": { "app save": { "": "cmd+s" } },
        });
        assert_eq!(lifecycle_errors(&catalog), Vec::<String>::new());
        assert!(manifest_exits_after_start(&catalog));
        assert!(!manifest_exits_after_start(&json!({
            "sources": [{ "name": "a.items", "type": "items" }]
        })));
        assert_eq!(
            lifecycle_errors(&json!({
                "sources": [{ "name": "a.items", "type": "items" }]
            })),
            Vec::<String>::new()
        );
        let first = |manifest: Value| lifecycle_errors(&manifest).remove(0);
        assert!(
            first(json!({ "lifecycle": "resident" })).contains("must be \"publish_then_exit\"")
        );
        assert!(first(json!({ "lifecycle": true })).contains("must be \"publish_then_exit\""));
        assert!(
            first(json!({ "exec": ["./x"], "lifecycle": "publish_then_exit" }))
                .contains("needs sources")
        );
        for surface in [
            json!({ "hints": {} }),
            json!({ "query": {} }),
            json!({ "status": ["state"] }),
            json!({ "listen": ["core:config.changed"] }),
            json!({ "commands": [{ "command": "x", "subcommand": "go" }] }),
            json!({ "bangs": [{ "token": "x" }] }),
            json!({ "navigation": ["x"] }),
        ] {
            let mut manifest = json!({
                "exec": ["./x"], "lifecycle": "publish_then_exit",
                "sources": [{ "name": "a.items", "type": "items" }],
            });
            let key = surface.as_object().unwrap().keys().next().unwrap().clone();
            manifest[&key] = surface[&key].clone();
            let error = first(manifest);
            assert!(
                error.contains("allows sources alone") && error.contains(&key),
                "{key}: {error}"
            );
        }
    }

    #[test]
    fn perform_kind_sections_require_their_handlers() {
        assert!(manifest_has_navigation(&json!({ "navigation": ["tmux"] })));
        assert!(!manifest_has_navigation(&json!({})));
    }
}
