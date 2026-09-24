//! Notes, Reminders and Contacts catalogs. Each app is one [`Engine`] in a
//! table; the running-app gate, the 60 s poll, the union publish and the
//! `open`/`refresh` commands are shared.

use std::collections::{BTreeMap, HashSet};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};

const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
const LIST_TIMEOUT: Duration = Duration::from_secs(30);
const SELECT_TIMEOUT: Duration = Duration::from_secs(10);
const CONTACTS_APP: &str = "/System/Applications/Contacts.app";

/// One AppleScript-backed catalog: the app it lists, the flashlight source
/// its rows belong to, and the scripts that list and select those rows.
struct Engine {
    /// Manifest command verb; also the log tag.
    command: &'static str,
    bundle_id: &'static str,
    source: &'static str,
    kind: &'static str,
    list_script: &'static str,
    /// Parses one trimmed listing line; `None` rejects it.
    parse_line: fn(&str) -> Option<Row>,
    /// Activates the app and shows the row with this id.
    select_script: fn(&str) -> String,
}

/// One accepted listing line.
struct Row {
    id: String,
    title: String,
    subtitle: String,
}

/// Round-tripped through the host so resolution can reselect the entry.
#[derive(Serialize, Deserialize)]
struct Payload {
    id: String,
}

static ENGINES: [Engine; 3] = [
    Engine {
        command: "notes",
        bundle_id: "com.apple.Notes",
        source: "notes.notes",
        kind: "note",
        list_script: NOTES_LIST,
        parse_line: parse_note,
        select_script: |id| show_by_id("Notes", "note", id),
    },
    Engine {
        command: "reminders",
        bundle_id: "com.apple.reminders",
        source: "reminders.tasks",
        kind: "reminder",
        list_script: REMINDERS_LIST,
        parse_line: parse_reminder,
        select_script: |id| show_by_id("Reminders", "reminder", id),
    },
    Engine {
        command: "contacts",
        bundle_id: "com.apple.AddressBook",
        source: "contacts.cards",
        kind: "contact",
        list_script: CONTACTS_LIST,
        parse_line: parse_contact,
        select_script: select_contact,
    },
];

const NOTES_LIST: &str = r#"
if application "Notes" is not running then return ""
tell application "Notes"
  set output to {}
  repeat with acc in accounts
    try
      repeat with n in notes of acc
        set the end of output to ((id of n as text) & tab & (name of n as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"#;

const REMINDERS_LIST: &str = r#"
if application "Reminders" is not running then return ""
tell application "Reminders"
  set output to {}
  repeat with l in lists
    try
      repeat with r in (reminders of l whose completed is false)
        set the end of output to ((id of r as text) & tab & (name of l as text) & tab & (name of r as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"#;

const CONTACTS_LIST: &str = r#"
on safeName(p)
  try
    set n to name of p
    if n is missing value then return ""
    return n
  on error
    return ""
  end try
end safeName

if application "/System/Applications/Contacts.app" is not running then return ""
tell application "/System/Applications/Contacts.app"
  set acc to {}
  repeat with p in people
    set n to my safeName(p)
    if n is not "" then set end of acc to n
  end repeat
  set AppleScript's text item delimiters to linefeed
  return acc as text
end tell
"#;

fn show_by_id(app: &str, noun: &str, id: &str) -> String {
    let quoted = applescript_quote(id);
    format!(
        r#"
tell application "{app}"
  activate
  try
    show {noun} id {quoted}
  end try
end tell
"#
    )
}

fn select_contact(name: &str) -> String {
    let quoted = applescript_quote(name);
    format!(
        r#"
tell application "{CONTACTS_APP}"
  activate
  set candidates to every person whose name is {quoted}
  if (count of candidates) > 0 then
    set the selection to (item 1 of candidates)
  end if
end tell
"#
    )
}

fn parse_note(line: &str) -> Option<Row> {
    let (id, title) = line.split_once('\t')?;
    Some(Row {
        id: id.trim().to_string(),
        title: title.trim().to_string(),
        subtitle: "Note".to_string(),
    })
}

fn parse_reminder(line: &str) -> Option<Row> {
    let mut parts = line.splitn(3, '\t');
    let (id, list, title) = (parts.next()?, parts.next()?, parts.next()?);
    Some(Row {
        id: id.trim().to_string(),
        title: title.trim().to_string(),
        subtitle: format!("Reminder — {}", list.trim()),
    })
}

fn parse_contact(line: &str) -> Option<Row> {
    Some(Row {
        id: line.to_string(),
        title: line.to_string(),
        subtitle: "Contact".to_string(),
    })
}

impl Engine {
    fn is_running(&self, applications: &[RunningApplication]) -> bool {
        applications
            .iter()
            .any(|application| application.bundle_id == self.bundle_id)
    }

    /// Rows for one listing, in output order, trimmed, deduplicated by id.
    fn candidates(&self, output: &str) -> Vec<Candidate> {
        let mut seen = HashSet::new();
        output
            .lines()
            .filter_map(|line| (self.parse_line)(line.trim()))
            .filter(|row| {
                !row.id.is_empty() && !row.title.is_empty() && seen.insert(row.id.clone())
            })
            .map(|row| {
                Candidate::new(self.source, row.title)
                    .kind(self.kind)
                    .subtitle(row.subtitle)
                    .payload_json(&Payload { id: row.id })
            })
            .collect()
    }
}

/// Index of the engine whose `key` equals `value`.
fn engine_by(key: fn(&Engine) -> &'static str, value: &str) -> Option<usize> {
    ENGINES.iter().position(|engine| key(engine) == value)
}

static GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

/// Process-local last-good rows per engine. `publish` replaces the whole
/// catalog, so every refresh re-emits the union of all engines.
static CATALOG: LazyLock<Mutex<Vec<Vec<Candidate>>>> =
    LazyLock::new(|| Mutex::new(vec![Vec::new(); ENGINES.len()]));

fn catalog() -> MutexGuard<'static, Vec<Vec<Candidate>>> {
    CATALOG.lock().unwrap_or_else(PoisonError::into_inner)
}

fn union(catalog: &[Vec<Candidate>]) -> Vec<Candidate> {
    catalog.iter().flatten().cloned().collect()
}

struct Apple;

flash_plugin::plugin!(Apple);

impl FlashPlugin for Apple {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply, so a slow listing never delays the
        // handshake. A failed listing publishes nothing for that engine — the
        // host keeps its last-good catalog — and retries once in the
        // background before the poll takes over.
        if !refresh(&ctx, 0..ENGINES.len()).await {
            log_degraded_initial(&ctx);
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh(&retry_ctx, 0..ENGINES.len()).await;
            });
        }
        drop(
            ctx.interval(Duration::from_secs(POLL_SECONDS), |ctx| async move {
                refresh(&ctx, 0..ENGINES.len()).await;
            }),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        let engine = event
            .bundle_id
            .as_deref()
            .and_then(|bundle_id| engine_by(|engine| engine.bundle_id, bundle_id));
        match (event.name.as_str(), engine) {
            ("core:apps.terminated", Some(index)) => clear(&ctx, index).await,
            ("core:apps.launched", Some(index)) => {
                refresh(&ctx, [index]).await;
            }
            ("core:config.changed", _) => {
                refresh(&ctx, 0..ENGINES.len()).await;
            }
            _ => {}
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let Some(index) = engine_by(|engine| engine.command, &command.command) else {
            return PerformResponse::fail(format!("unknown command: {}", command.command));
        };
        let engine = &ENGINES[index];
        match command.subcommand.as_str() {
            "open" => {
                if ctx.open_app(engine.bundle_id).await {
                    PerformResponse::ok()
                } else {
                    PerformResponse::fail(format!("host.open {} failed", engine.bundle_id))
                }
            }
            "refresh" => {
                if refresh(&ctx, [index]).await {
                    PerformResponse::ok().message(format!("{} refreshed", engine.command))
                } else {
                    PerformResponse::fail(format!("{} refresh failed", engine.command))
                }
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        let Some(index) = engine_by(|engine| engine.source, &row.source) else {
            return PerformResponse::unhandled();
        };
        let engine = &ENGINES[index];
        let id = row
            .payload_as::<Payload>()
            .map(|payload| payload.id)
            .unwrap_or_default();
        if id.is_empty() {
            return PerformResponse::unhandled();
        }
        let result = run_osascript(&ctx, &(engine.select_script)(&id), SELECT_TIMEOUT).await;
        if result.ok {
            PerformResponse::ok()
        } else {
            PerformResponse::fail(format!("{} selection failed", engine.kind))
        }
    }
}

/// Lists every engine in `indices` under the gate, then publishes the union
/// of all engines' rows. A stopped app is an authoritative empty; a failed
/// listing keeps that engine's last-good rows, and when every listing failed
/// nothing is published so the host keeps its last-good catalog. Returns
/// whether every listing succeeded.
async fn refresh(ctx: &Context, indices: impl IntoIterator<Item = usize>) -> bool {
    GATE.run(ctx, |ctx, running| async move {
        let (mut succeeded, mut failed) = (0, 0);
        for index in indices {
            let engine = &ENGINES[index];
            let started_at = Instant::now();
            let rows = if engine.is_running(&running) {
                let result = run_osascript(&ctx, engine.list_script, LIST_TIMEOUT).await;
                if !result.ok {
                    ctx.log(
                        "warn",
                        &format!(
                            "[apple] {} list failed: {}",
                            engine.command,
                            result.stderr.trim()
                        ),
                    );
                    log_refresh(&ctx, engine, "failed", 0, started_at);
                    failed += 1;
                    continue;
                }
                engine.candidates(&result.stdout)
            } else {
                Vec::new()
            };
            let outcome = if rows.is_empty() { "empty" } else { "ok" };
            log_refresh(&ctx, engine, outcome, rows.len(), started_at);
            catalog()[index] = rows;
            succeeded += 1;
        }
        if succeeded > 0 {
            ctx.publish(union(&catalog()));
        }
        failed == 0
    })
    .await
}

/// Termination is authoritative and needs no AppleScript round trip.
async fn clear(ctx: &Context, index: usize) {
    GATE.run(ctx, |ctx, _running| async move {
        catalog()[index].clear();
        ctx.publish(union(&catalog()));
    })
    .await;
}

fn log_refresh(ctx: &Context, engine: &Engine, outcome: &str, rows: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("engine".to_string(), engine.command.to_string()),
        ("outcome".to_string(), outcome.to_string()),
        ("rows".to_string(), rows.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[apple] refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[apple] refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[apple] initial catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

fn main() {
    run(Apple);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(command: &str) -> &'static Engine {
        &ENGINES[engine_by(|engine| engine.command, command).expect("known engine")]
    }

    fn titles(candidates: &[Candidate]) -> Vec<&str> {
        candidates
            .iter()
            .map(|candidate| candidate.title.as_str())
            .collect()
    }

    fn sources(candidates: &[Candidate]) -> Vec<&str> {
        candidates
            .iter()
            .map(|candidate| candidate.source.as_str())
            .collect()
    }

    fn running(bundle_id: &str) -> RunningApplication {
        RunningApplication {
            bundle_id: bundle_id.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn engines_are_keyed_by_command_bundle_id_and_source() {
        for (command, bundle_id, source) in [
            ("notes", "com.apple.Notes", "notes.notes"),
            ("reminders", "com.apple.reminders", "reminders.tasks"),
            ("contacts", "com.apple.AddressBook", "contacts.cards"),
        ] {
            let index = engine_by(|engine| engine.command, command);
            assert!(index.is_some());
            assert_eq!(engine_by(|engine| engine.bundle_id, bundle_id), index);
            assert_eq!(engine_by(|engine| engine.source, source), index);
        }
        assert_eq!(engine_by(|engine| engine.command, "shortcuts"), None);
    }

    #[test]
    fn successful_empty_output_is_an_authoritative_empty_snapshot() {
        for (command, noise) in [
            ("notes", " \nmalformed\n"),
            ("reminders", " \nmalformed\n"),
            ("contacts", " \n\t\n"),
        ] {
            assert!(engine(command).candidates("").is_empty());
            assert!(engine(command).candidates(noise).is_empty());
        }
    }

    #[test]
    fn note_listing_rejects_malformed_rows_and_deduplicates_ids() {
        let candidates = engine("notes").candidates(
            "note-1\tFirst\nmalformed\nnote-2\t Second \nnote-1\tRenamed\n\tMissing ID\n",
        );
        assert_eq!(titles(&candidates), ["First", "Second"]);
        let first = &candidates[0];
        assert_eq!(first.source, "notes.notes");
        assert_eq!(first.meta("kind"), Some("note"));
        assert_eq!(first.meta("subtitle"), Some("Note"));
        assert_eq!(first.payload_as::<Payload>().unwrap().id, "note-1");
    }

    #[test]
    fn reminder_listing_preserves_order_trims_fields_and_deduplicates_ids() {
        let candidates = engine("reminders").candidates(
            "rem-1\tInbox\tBuy milk\nmalformed\nrem-2\t Work \t Ship release \nrem-1\tInbox\tDuplicate\n\tMissing\tID\n",
        );
        assert_eq!(titles(&candidates), ["Buy milk", "Ship release"]);
        let first = &candidates[0];
        assert_eq!(first.source, "reminders.tasks");
        assert_eq!(first.meta("kind"), Some("reminder"));
        assert_eq!(first.meta("subtitle"), Some("Reminder — Inbox"));
        assert_eq!(first.payload_as::<Payload>().unwrap().id, "rem-1");
        assert_eq!(candidates[1].meta("subtitle"), Some("Reminder — Work"));
    }

    #[test]
    fn contact_listing_trims_and_deduplicates_names() {
        let candidates =
            engine("contacts").candidates("Ada Lovelace\n Grace Hopper \nAda Lovelace\n");
        assert_eq!(titles(&candidates), ["Ada Lovelace", "Grace Hopper"]);
        let first = &candidates[0];
        assert_eq!(first.source, "contacts.cards");
        assert_eq!(first.meta("kind"), Some("contact"));
        assert_eq!(first.meta("subtitle"), Some("Contact"));
        assert_eq!(first.payload_as::<Payload>().unwrap().id, "Ada Lovelace");
    }

    #[test]
    fn running_app_gate_matches_only_the_engines_own_app() {
        for engine in &ENGINES {
            assert!(!engine.is_running(&[]));
            assert!(engine.is_running(&[running(engine.bundle_id)]));
            for other in ENGINES
                .iter()
                .filter(|other| other.bundle_id != engine.bundle_id)
            {
                assert!(!engine.is_running(&[running(other.bundle_id)]));
            }
            assert!(!engine.is_running(&[running("com.apple.TextEdit")]));
        }
    }

    #[test]
    fn selection_scripts_quote_the_identifier() {
        let id = "x\"y\\z";
        assert!((engine("notes").select_script)(id).contains("show note id \"x\\\"y\\\\z\""));
        assert!(
            (engine("reminders").select_script)(id).contains("show reminder id \"x\\\"y\\\\z\"")
        );
        assert!((engine("contacts").select_script)(id).contains("whose name is \"x\\\"y\\\\z\""));
    }

    #[test]
    fn contacts_scripts_use_the_canonical_system_application() {
        let tell = "tell application \"/System/Applications/Contacts.app\"";
        assert!(engine("contacts").list_script.contains(tell));
        assert!((engine("contacts").select_script)("Ada").contains(tell));
    }

    #[test]
    fn one_engines_refresh_keeps_the_other_engines_rows_in_table_order() {
        let mut catalog = vec![Vec::new(); ENGINES.len()];
        catalog[1] = engine("reminders").candidates("rem-1\tInbox\tBuy milk\n");
        catalog[2] = engine("contacts").candidates("Ada Lovelace\n");
        assert_eq!(
            sources(&union(&catalog)),
            ["reminders.tasks", "contacts.cards"]
        );
        catalog[0] = engine("notes").candidates("note-1\tFirst\n");
        assert_eq!(
            sources(&union(&catalog)),
            ["notes.notes", "reminders.tasks", "contacts.cards"]
        );
        catalog[1].clear();
        assert_eq!(sources(&union(&catalog)), ["notes.notes", "contacts.cards"]);
    }
}
