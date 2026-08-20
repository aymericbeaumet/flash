use flash_plugin::{run, Candidate, Context, Event};
use serde_json::Value;
use std::collections::BTreeMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

const SOURCE_ID: &str = "plugin:snippets";
const SOURCE_ITEMS: &str = "snippets.items";

/// Row/field caps keep the catalog far below the SDK's 10,000-row / 4 MiB
/// publication limits (titles 4 KiB, effect text 64 KiB) — one oversized
/// snippet must degrade to a skipped row, never reject the whole snapshot.
const MAX_SNIPPETS: usize = 2_000;
const MAX_NAME_BYTES: usize = 1_024;
const MAX_TEXT_BYTES: usize = 60 * 1_024;
const MAX_PREVIEW_CHARS: usize = 80;

// Compile-time guards: the caps above must stay inside the SDK publication
// limits (10,000 rows; 4 KiB titles; 64 KiB effect text).
const _: () = assert!(MAX_SNIPPETS < 10_000);
const _: () = assert!(MAX_NAME_BYTES <= 4 * 1024);
const _: () = assert!(MAX_TEXT_BYTES < 64 * 1024);

/// Fingerprint of the last published catalog, used to signal
/// `sources.invalidated` only when a rebuild actually changed content.
static LAST_FINGERPRINT: Mutex<Option<u64>> = Mutex::new(None);
static REBUILD_GATE: LazyLock<tokio::sync::Mutex<()>> =
    LazyLock::new(|| tokio::sync::Mutex::new(()));

struct Snippets;

flash_plugin::plugin!(Snippets);

impl FlashPlugin for Snippets {
    async fn on_start(&self, ctx: Context) {
        // The config is the single source of truth: every outcome (including
        // an unset table or an unreadable file) publishes authoritatively, so
        // initialize never blocks and never fails the readiness gate.
        rebuild_catalog(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        // The inline table rides FLASH_PLUGIN_CONFIG (the host restarts the
        // process when `[plugin.snippets]` itself changes); this re-read is
        // what picks up edits to the external `file` catalog.
        if event.name == "core:config.changed" {
            rebuild_catalog(&ctx).await;
        }
    }
}

/// Rebuild the catalog from the inline `[plugin.snippets.snippets]` table plus
/// the optional external `file`, and publish it. Config-driven content has no
/// transient-failure mode: whatever the config resolves to right now is the
/// authoritative snapshot (a broken file degrades to its rows missing, warned).
async fn rebuild_catalog(ctx: &Context) {
    let _guard = REBUILD_GATE.lock().await;
    let started_at = Instant::now();
    let inline = inline_snippets(ctx);
    let file = file_snippets(ctx).await;
    let candidates = compose_candidates(ctx, file, inline);
    let count = candidates.len();
    publish(ctx, candidates);
    log_rebuild(
        ctx,
        if count == 0 { "empty" } else { "ok" },
        count,
        started_at,
    );
}

/// Publish the snapshot and, when a previous publication existed with
/// different content, tell the host the warm catalog is stale.
fn publish(ctx: &Context, candidates: Vec<Candidate>) {
    let fingerprint = fingerprint_of(&candidates);
    let previous = LAST_FINGERPRINT
        .lock()
        .map(|mut last| last.replace(fingerprint))
        .unwrap_or(None);
    ctx.set_locations(SOURCE_ID, candidates);
    if previous.is_some_and(|last| last != fingerprint) {
        ctx.invalidate_sources();
    }
}

fn fingerprint_of(candidates: &[Candidate]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for candidate in candidates {
        candidate.title.hash(&mut hasher);
        candidate.meta("subtitle").hash(&mut hasher);
    }
    hasher.finish()
}

// ---------------------------------------------------------------------------
// Config reading
// ---------------------------------------------------------------------------

/// The `[plugin.snippets.snippets]` table: name → text. Non-string values are
/// skipped (warned content-free), not fatal.
fn inline_snippets(ctx: &Context) -> BTreeMap<String, String> {
    let table = ctx
        .config_json::<BTreeMap<String, Value>>("snippets")
        .unwrap_or_default();
    let (snippets, skipped) = string_entries(table);
    if skipped > 0 {
        ctx.log(
            "warn",
            &format!("[snippets] {skipped} non-string inline snippet value(s) skipped"),
        );
    }
    snippets
}

/// Snippets from the optional `[plugin.snippets] file` — a TOML or JSON file
/// of the same shape (either `name = text` at the top level or nested under a
/// `snippets` table). Every failure degrades to no file rows, warned.
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
    // Same shape as `[plugin.snippets]`: a nested `snippets` table when
    // present, otherwise the top level itself maps name → text.
    let table = match object.get("snippets").and_then(Value::as_object) {
        Some(nested) => nested.clone(),
        None => object.clone(),
    };
    Ok(string_entries(table.into_iter().collect()))
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

/// Merge file and inline snippets (inline wins on a name collision — the
/// user's own `[plugin.snippets.snippets]` table is the more local override)
/// and shape them into candidates, name-sorted for determinism.
fn compose_candidates(
    ctx: &Context,
    file: BTreeMap<String, String>,
    inline: BTreeMap<String, String>,
) -> Vec<Candidate> {
    let mut merged = file;
    merged.extend(inline);
    let total = merged.len();
    let candidates: Vec<Candidate> = merged
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
    Candidate::new(name)
        .insert_text(text)
        .kind("snippet")
        .source_id(SOURCE_ID)
        .source(SOURCE_ITEMS)
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
    use flash_plugin::testing::Harness;
    use flash_plugin::CandidateEffect;
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
    fn snippet_files_parse_as_toml_or_json_flat_or_nested() {
        let toml_flat = "shrug = \"¯\\\\_(ツ)_/¯\"\nsig = \"— A\"";
        let (snippets, skipped) = parse_snippet_file(toml_flat).unwrap();
        assert_eq!(snippets, map(&[("shrug", "¯\\_(ツ)_/¯"), ("sig", "— A")]));
        assert_eq!(skipped, 0);

        let toml_nested = "[snippets]\nshrug = \"s\"";
        let (snippets, _) = parse_snippet_file(toml_nested).unwrap();
        assert_eq!(snippets, map(&[("shrug", "s")]));

        let json_flat = r#"{ "shrug": "s", "bad": 42 }"#;
        let (snippets, skipped) = parse_snippet_file(json_flat).unwrap();
        assert_eq!(snippets, map(&[("shrug", "s")]));
        assert_eq!(skipped, 1);

        let json_nested = r#"{ "snippets": { "shrug": "s" } }"#;
        let (snippets, _) = parse_snippet_file(json_nested).unwrap();
        assert_eq!(snippets, map(&[("shrug", "s")]));

        assert!(parse_snippet_file("not = valid = anything").is_err());
        assert!(parse_snippet_file("[1, 2]").is_err());
    }

    #[test]
    fn inline_snippets_override_file_snippets_on_collision() {
        let harness = Harness::new("snippets");
        let ctx = harness.context();
        let candidates = compose_candidates(
            &ctx,
            map(&[("shrug", "from file"), ("only-file", "f")]),
            map(&[("shrug", "from inline")]),
        );
        let summary: Vec<(&str, Option<&str>)> = candidates
            .iter()
            .map(|c| (c.title.as_str(), c.meta("subtitle")))
            .collect();
        assert_eq!(
            summary,
            vec![("only-file", Some("f")), ("shrug", Some("from inline")),]
        );
    }

    #[test]
    fn candidates_carry_the_insert_text_effect_and_source_labels() {
        let candidate = candidate("shrug", "¯\\_(ツ)_/¯");
        assert_eq!(candidate.title, "shrug");
        assert!(matches!(
            candidate.effect,
            Some(CandidateEffect::InsertText { ref text }) if text == "¯\\_(ツ)_/¯"
        ));
        assert_eq!(candidate.meta("source"), Some(SOURCE_ITEMS));
        assert_eq!(candidate.meta("source_id"), Some(SOURCE_ID));
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
            BTreeMap::new(),
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
    async fn rebuild_publishes_inline_config_snippets() {
        let harness = Harness::with_config(
            "snippets",
            json!({ "snippets": { "shrug": "¯\\_(ツ)_/¯", "sig": "— A" } }),
        );
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        assert!(ctx.has_locations(SOURCE_ID));
        let titles: Vec<String> = ctx.warm_locations().into_iter().map(|c| c.title).collect();
        assert_eq!(titles, vec!["shrug", "sig"]);
    }

    #[tokio::test]
    async fn rebuild_reads_the_external_file_and_inline_overrides_it() {
        let harness = Harness::new("snippets");
        let dir = harness.data_dir();
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let file = dir.join("snips.toml");
        tokio::fs::write(&file, "shrug = \"file\"\nextra = \"e\"")
            .await
            .unwrap();

        let harness = Harness::with_config(
            "snippets",
            json!({
                "file": file.to_string_lossy(),
                "snippets": { "shrug": "inline" },
            }),
        );
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        let warm = ctx.warm_locations();
        let summary: Vec<(&str, Option<&str>)> = warm
            .iter()
            .map(|c| (c.title.as_str(), c.meta("subtitle")))
            .collect();
        assert_eq!(
            summary,
            vec![("extra", Some("e")), ("shrug", Some("inline"))]
        );
    }

    #[tokio::test]
    async fn empty_config_publishes_an_authoritative_empty_catalog() {
        let harness = Harness::new("snippets");
        let ctx = harness.context();
        rebuild_catalog(&ctx).await;
        assert!(ctx.has_locations(SOURCE_ID));
        assert!(ctx.warm_locations().is_empty());
    }
}
