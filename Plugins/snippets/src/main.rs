//! User snippets from the file `[plugins.snippets] file` names, published as
//! `@snippets` rows the host types itself. `lifecycle: publish_then_exit`:
//! the process reads the file, publishes and exits; the host keeps the
//! catalog and runs it again when the setting or the file (`watch_settings`)
//! changes.

use flash_plugin::{Candidate, Context, run};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

const SOURCE_ITEMS: &str = "snippets.items";

/// Row/field caps keep the catalog far below the protocol's 10,000-row /
/// 4 MiB catalog quotas (titles 4 KiB, effect text 64 KiB) — one oversized
/// snippet must degrade to a skipped row, never make the host reject the
/// whole publish.
const MAX_SNIPPETS: usize = 2_000;
const MAX_NAME_BYTES: usize = 1_024;
const MAX_TEXT_BYTES: usize = 60 * 1_024;
const MAX_PREVIEW_CHARS: usize = 80;

// Compile-time guards: the caps above must stay inside the host's catalog
// quotas (10,000 rows; 4 KiB titles; 64 KiB effect text).
const _: () = assert!(MAX_SNIPPETS < 10_000);
const _: () = assert!(MAX_NAME_BYTES <= 4 * 1024);
const _: () = assert!(MAX_TEXT_BYTES < 64 * 1024);

struct Snippets;

flash_plugin::plugin!(Snippets);

impl FlashPlugin for Snippets {
    async fn on_start(&self, ctx: Context) {
        // The whole run: the file is the single source of truth, and every
        // outcome (including no `file` or an unreadable one) publishes
        // authoritatively, after the initialize reply. The host runs the
        // plugin again when `[plugins.snippets]` or the file changes.
        rebuild_catalog(&ctx).await;
    }
}

/// Rebuild the catalog from the `[plugins.snippets] file` and publish it.
/// The snippets live in that file, never in the settings: a plugin's
/// settings are flat values riding one environment variable. Config-driven
/// content has no transient-failure mode: whatever the file holds right now
/// is the authoritative snapshot (a broken file degrades to no rows, warned).
async fn rebuild_catalog(ctx: &Context) {
    let started_at = Instant::now();
    let file = file_snippets(ctx).await;
    let candidates = compose_candidates(ctx, file);
    let count = candidates.len();
    ctx.publish(candidates);
    log_rebuild(
        ctx,
        if count == 0 { "empty" } else { "ok" },
        count,
        started_at,
    );
}

// ---------------------------------------------------------------------------
// File reading
// ---------------------------------------------------------------------------

/// Snippets from the optional `[plugins.snippets] file` — a TOML or JSON file
/// of `name = text` entries at its top level. Every failure degrades to no
/// rows, warned.
async fn file_snippets(ctx: &Context) -> BTreeMap<String, String> {
    let configured = ctx.config_str("file");
    let configured = configured.trim();
    if configured.is_empty() {
        return BTreeMap::new();
    }
    let path = expand_tilde(configured, std::env::var("HOME").ok().as_deref());
    let raw = match tokio::fs::read_to_string(&path).await {
        Ok(raw) => raw,
        Err(error) => {
            ctx.log(
                "warn",
                &format!(
                    "[snippets] snippet file unreadable os_error={}",
                    error.raw_os_error().unwrap_or(-1)
                ),
            );
            return BTreeMap::new();
        }
    };
    match parse_snippet_file(&raw) {
        Ok((snippets, skipped)) => {
            if skipped > 0 {
                ctx.log(
                    "warn",
                    &format!("[snippets] {skipped} non-string file snippet value(s) skipped"),
                );
            }
            snippets
        }
        Err(reason) => {
            ctx.log(
                "warn",
                &format!("[snippets] snippet file rejected: {reason}"),
            );
            BTreeMap::new()
        }
    }
}

/// `~` / `~/…` expansion by hand — the scrubbed plugin environment has a real
/// `HOME`, but config values are written for the user's shell conventions.
fn expand_tilde(path: &str, home: Option<&str>) -> PathBuf {
    if let Some(home) = home {
        if path == "~" {
            return PathBuf::from(home);
        }
        if let Some(rest) = path.strip_prefix("~/") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(path)
}

/// Parse the external snippet file: JSON first (a JSON document is rarely
/// valid TOML, never vice versa), then TOML. Error strings stay content-free —
/// parser diagnostics can quote file content, so they are never forwarded.
fn parse_snippet_file(raw: &str) -> Result<(BTreeMap<String, String>, usize), &'static str> {
    let value = match serde_json::from_str::<Value>(raw) {
        Ok(value) => value,
        Err(_) => {
            let table = toml::from_str::<toml::Table>(raw).map_err(|_| "not valid JSON or TOML")?;
            serde_json::to_value(table).map_err(|_| "TOML table not representable as JSON")?
        }
    };
    let Some(object) = value.as_object() else {
        return Err("top level must be an object/table");
    };
    // The top level maps name → text; a nested table is a value that is not
    // text, skipped like any other.
    Ok(string_entries(object.clone().into_iter().collect()))
}

/// Keep string-valued entries; count everything else as skipped.
fn string_entries(table: BTreeMap<String, Value>) -> (BTreeMap<String, String>, usize) {
    let mut snippets = BTreeMap::new();
    let mut skipped = 0_usize;
    for (name, value) in table {
        match value.as_str() {
            Some(text) => {
                snippets.insert(name, text.to_string());
            }
            None => skipped += 1,
        }
    }
    (snippets, skipped)
}

// ---------------------------------------------------------------------------
// Candidate shaping
// ---------------------------------------------------------------------------

/// Shape the file's snippets into candidates, name-sorted for determinism.
fn compose_candidates(ctx: &Context, snippets: BTreeMap<String, String>) -> Vec<Candidate> {
    let total = snippets.len();
    let candidates: Vec<Candidate> = snippets
        .into_iter()
        .filter(|(name, text)| acceptable_snippet(name, text))
        .take(MAX_SNIPPETS)
        .map(|(name, text)| candidate(&name, &text))
        .collect();
    if candidates.len() < total {
        ctx.log(
            "warn",
            &format!(
                "[snippets] {} snippet(s) dropped (empty, oversized, or beyond the {MAX_SNIPPETS}-row cap)",
                total - candidates.len()
            ),
        );
    }
    candidates
}

/// One snippet row: selection makes the HOST type `text` into the focused app
/// (the `insert_text` effect) — the plugin itself needs no capabilities.
fn candidate(name: &str, text: &str) -> Candidate {
    Candidate::new(SOURCE_ITEMS, name)
        .insert_text(text)
        .kind("snippet")
        .subtitle(preview_of(text))
}

/// Within the per-field publication limits, and non-empty on both sides.
fn acceptable_snippet(name: &str, text: &str) -> bool {
    !name.trim().is_empty()
        && !text.is_empty()
        && name.len() <= MAX_NAME_BYTES
        && text.len() <= MAX_TEXT_BYTES
}

/// First line of the snippet, char-capped, with an ellipsis when the snippet
/// continues beyond what the preview shows.
fn preview_of(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or_default();
    let mut preview: String = first_line.chars().take(MAX_PREVIEW_CHARS).collect();
    if preview.len() < text.len() {
        preview.push('…');
    }
    preview
}

fn log_rebuild(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[snippets] catalog rebuild",
        BTreeMap::from([
            ("outcome".to_string(), outcome.to_string()),
            ("candidates".to_string(), count.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
        ]),
    );
}

fn main() {
    run(Snippets);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::CandidateEffect;
    use flash_plugin::testing::Harness;
    use serde_json::json;

    fn map(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
        entries
            .iter()
            .map(|(name, text)| (name.to_string(), text.to_string()))
            .collect()
    }

    // The publication-limit cap guards live as const asserts next to the
    // constants — clippy's assertions_on_constants rejects them in a test fn.

    #[test]
    fn tilde_expansion_covers_bare_prefixed_and_absolute_paths() {
        assert_eq!(
            expand_tilde("~", Some("/Users/me")),
            PathBuf::from("/Users/me")
        );
        assert_eq!(
            expand_tilde("~/snips.toml", Some("/Users/me")),
            PathBuf::from("/Users/me/snips.toml")
        );
        assert_eq!(
            expand_tilde("/etc/snips.json", Some("/Users/me")),
            PathBuf::from("/etc/snips.json")
        );
        // `~user` is not expanded — only the caller's own home is known.
        assert_eq!(
            expand_tilde("~other/x", Some("/Users/me")),
            PathBuf::from("~other/x")
        );
        assert_eq!(expand_tilde("~/x", None), PathBuf::from("~/x"));
    }

    #[test]
    fn snippet_files_parse_as_toml_or_json() {
        let toml = "shrug = \"¯\\\\_(ツ)_/¯\"\nsig = \"— A\"";
        let (snippets, skipped) = parse_snippet_file(toml).unwrap();
        assert_eq!(snippets, map(&[("shrug", "¯\\_(ツ)_/¯"), ("sig", "— A")]));
        assert_eq!(skipped, 0);

        let json = r#"{ "shrug": "s", "bad": 42 }"#;
        let (snippets, skipped) = parse_snippet_file(json).unwrap();
        assert_eq!(snippets, map(&[("shrug", "s")]));
        assert_eq!(skipped, 1);

        assert!(parse_snippet_file("not = valid = anything").is_err());
        assert!(parse_snippet_file("[1, 2]").is_err());
    }

    #[test]
    fn candidates_carry_the_insert_text_effect_and_source_labels() {
        let candidate = candidate("shrug", "¯\\_(ツ)_/¯");
        assert_eq!(candidate.title, "shrug");
        assert!(matches!(
            candidate.effect,
            Some(CandidateEffect::InsertText { ref text }) if text == "¯\\_(ツ)_/¯"
        ));
        assert_eq!(candidate.source, SOURCE_ITEMS);
        assert_eq!(candidate.meta("kind"), Some("snippet"));
    }

    #[test]
    fn previews_are_first_line_only_and_mark_continuation() {
        assert_eq!(preview_of("one line"), "one line");
        assert_eq!(preview_of("first\nsecond"), "first…");
        let long = "x".repeat(MAX_PREVIEW_CHARS + 10);
        let preview = preview_of(&long);
        assert_eq!(preview.chars().count(), MAX_PREVIEW_CHARS + 1);
        assert!(preview.ends_with('…'));
    }

    #[test]
    fn unusable_snippets_are_dropped_not_fatal() {
        let harness = Harness::new("snippets");
        let ctx = harness.context();
        let candidates = compose_candidates(
            &ctx,
            map(&[
                ("", "empty name"),
                ("  ", "blank name"),
                ("empty-text", ""),
                ("ok", "fine"),
            ]),
        );
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].title, "ok");

        let oversized = "x".repeat(MAX_TEXT_BYTES + 1);
        assert!(!acceptable_snippet("big", &oversized));
        assert!(!acceptable_snippet(&"n".repeat(MAX_NAME_BYTES + 1), "t"));
    }

    #[tokio::test]
    async fn rebuild_publishes_the_file_snippets_by_name() {
        let harness = Harness::new("snippets");
        let dir = harness.data_dir();
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let file = dir.join("snips.toml");
        tokio::fs::write(&file, "shrug = \"¯\\\\_(ツ)_/¯\"\nextra = \"e\"")
            .await
            .unwrap();

        let mut harness =
            Harness::with_config("snippets", json!({ "file": file.to_string_lossy() }));
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        let rows = harness.drain_published_rows().unwrap();
        let summary: Vec<(&str, Option<&str>)> = rows
            .iter()
            .map(|c| (c.title.as_str(), c.meta("subtitle")))
            .collect();
        assert_eq!(
            summary,
            vec![("extra", Some("e")), ("shrug", Some("¯\\_(ツ)_/¯"))]
        );
    }

    /// A plugin's settings are flat values (`FLASH_PLUGIN_CONFIG`): the host
    /// rejects a `[plugins.snippets.snippets]` table, so the plugin reads no
    /// `snippets` setting at all.
    #[tokio::test]
    async fn a_snippets_setting_is_never_read() {
        let mut harness = Harness::with_config(
            "snippets",
            json!({ "snippets": { "shrug": "¯\\_(ツ)_/¯" } }),
        );
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        assert!(harness.drain_published_rows().unwrap().is_empty());
    }

    /// One file shape: `name = text` at the top level. A table is a value
    /// that is not text, skipped like any other.
    #[test]
    fn a_table_in_the_file_is_not_a_snippet() {
        let (snippets, skipped) = parse_snippet_file("[snippets]\nshrug = \"s\"").unwrap();
        assert!(snippets.is_empty());
        assert_eq!(skipped, 1);
        let (snippets, skipped) =
            parse_snippet_file(r#"{ "snippets": { "shrug": "s" }, "sig": "A" }"#).unwrap();
        assert_eq!(snippets, map(&[("sig", "A")]));
        assert_eq!(skipped, 1);
    }

    #[tokio::test]
    async fn empty_config_publishes_an_authoritative_empty_catalog() {
        let mut harness = Harness::new("snippets");
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        let rows = harness.drain_published_rows().unwrap();
        assert!(rows.is_empty());
    }

    /// `lifecycle: publish_then_exit`: the process answers initialize,
    /// publishes the file's snippets and exits 0 on its own; the host keeps
    /// the rows and runs it again when the setting or the file changes.
    #[tokio::test]
    async fn the_run_ends_once_the_catalog_is_published() {
        use flash_plugin::testing::WireHarness;
        let dir = std::env::temp_dir().join(format!("flash-snippets-wire-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let file = dir.join("snips.toml");
        tokio::fs::write(&file, "shrug = \"s\"").await.unwrap();
        let mut wire =
            WireHarness::with_config(Snippets, json!({ "file": file.to_string_lossy() }));
        wire.send(json!({ "id": 1, "method": "initialize", "params": { "protocol_version": 1 } }))
            .await;
        assert_eq!(wire.recv_response(1).await["ok"], true);
        let publish = wire.recv_notification("publish").await;
        assert_eq!(publish["rows"][0]["title"], "shrug");
        let rest = wire.finished().await;
        assert!(
            rest.iter().all(|frame| frame["method"] == "log"),
            "{rest:?}"
        );
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }
}
