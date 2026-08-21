use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

use flash_plugin::{run, CommandRequest, Context, Event, PerformResponse};
use serde::{Deserialize, Serialize};

const STATE_FILE: &str = "marks.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct MarksState {
    /// Letter (single lowercase char or digit) → saved app context. The
    /// pid is the fast-path activation handle; the bundle id is the durable
    /// fallback when the original process is gone.
    entries: BTreeMap<String, MarkEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct MarkEntry {
    pid: i64,
    bundle_id: String,
}

struct Marks {
    state: Mutex<MarksState>,
    /// In-memory `bundle_id → pid` mirror, kept fresh from
    /// `core:apps.changed` / `core:apps.launched` / `core:apps.terminated`.
    /// Used by `jump_to_mark` when the saved pid is dead but the same bundle
    /// is still running under a fresh pid.
    apps: Mutex<HashMap<String, i64>>,
}

flash_plugin::plugin!(Marks);

impl FlashPlugin for Marks {
    async fn on_start(&self, ctx: Context) {
        if let Some(loaded) = read_state::<MarksState>(&ctx, STATE_FILE).await {
            if let Ok(mut state) = self.state.lock() {
                *state = loaded;
            }
        }
        replace_running_apps(self, &ctx);
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:flash.started"
                | "core:apps.changed"
                | "core:apps.launched"
                | "core:apps.terminated"
        ) {
            replace_running_apps(self, &ctx);
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "set_mark" => set_mark_command(self, &ctx, &command).await,
            "jump_to_mark" => jump_to_mark_command(self, &ctx, &command).await,
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

fn replace_running_apps(plugin: &Marks, ctx: &Context) {
    if let Ok(mut apps) = plugin.apps.lock() {
        apps.clear();
        for app in ctx.running_applications() {
            if !app.bundle_id.is_empty() && app.pid > 0 {
                apps.insert(app.bundle_id, app.pid);
            }
        }
    }
}

/// Pull `letter=X` from `args`. Verb args arrive as positional `["letter=a"]`
/// strings — same convention the host uses for all plugin-verb dispatches. The
/// letter is normalised to a single lowercase char/digit; anything else is
/// rejected so a typo doesn't quietly create a `letter=` slot.
fn parse_letter(command: &CommandRequest) -> Option<String> {
    for arg in &command.args {
        if let Some(value) = arg.strip_prefix("letter=") {
            let trimmed = value.trim();
            if trimmed.chars().count() != 1 {
                return None;
            }
            let ch = trimmed.chars().next()?;
            if !ch.is_alphanumeric() {
                return None;
            }
            return Some(ch.to_lowercase().to_string());
        }
    }
    None
}

async fn set_mark_command(
    plugin: &Marks,
    ctx: &Context,
    command: &CommandRequest,
) -> PerformResponse {
    let Some(letter) = parse_letter(command) else {
        return PerformResponse::fail("set_mark requires letter=<a-z|0-9>");
    };
    let Some(target) = ctx.normal_mode_target().await else {
        return PerformResponse::fail("no focused non-flash app");
    };
    let entry = MarkEntry {
        pid: target.pid,
        bundle_id: target.bundle_id.clone(),
    };
    let snapshot = {
        let Ok(mut state) = plugin.state.lock() else {
            return PerformResponse::fail("marks state lock poisoned");
        };
        state.entries.insert(letter.clone(), entry);
        state.clone()
    };
    write_state(ctx, STATE_FILE, &snapshot).await;
    ctx.log(
        "debug",
        &format!(
            "[marks] set letter={letter} pid={} bundle={}",
            target.pid, target.bundle_id
        ),
    );
    PerformResponse::ok()
}

async fn jump_to_mark_command(
    plugin: &Marks,
    ctx: &Context,
    command: &CommandRequest,
) -> PerformResponse {
    let Some(letter) = parse_letter(command) else {
        return PerformResponse::fail("jump_to_mark requires letter=<a-z|0-9>");
    };
    let mark = plugin
        .state
        .lock()
        .ok()
        .and_then(|state| state.entries.get(&letter).cloned());
    let Some(mark) = mark else {
        return PerformResponse::fail(format!("no mark for letter={letter}"));
    };
    // Pid is the fast path: if the original process is still alive, app
    // activation brings its windows to the front. If the pid is dead, fall
    // back to the durable bundle id via the running-apps mirror updated from
    // `core:apps.*` events.
    if ctx.activate(mark.pid).await {
        return PerformResponse::ok().target_pid(mark.pid);
    }
    let fallback_pid = plugin
        .apps
        .lock()
        .ok()
        .and_then(|apps| apps.get(&mark.bundle_id).copied());
    if let Some(pid) = fallback_pid {
        if ctx.activate(pid).await {
            let snapshot = {
                let Ok(mut state) = plugin.state.lock() else {
                    return PerformResponse::ok().target_pid(pid);
                };
                if let Some(entry) = state.entries.get_mut(&letter) {
                    entry.pid = pid;
                }
                state.clone()
            };
            write_state(ctx, STATE_FILE, &snapshot).await;
            return PerformResponse::ok().target_pid(pid);
        }
    }
    PerformResponse::fail(format!(
        "mark letter={letter} bundle={} unreachable",
        mark.bundle_id
    ))
}

async fn read_state<T: serde::de::DeserializeOwned>(ctx: &Context, name: &str) -> Option<T> {
    let raw = tokio::fs::read_to_string(ctx.share_dir().join(name))
        .await
        .ok()?;
    serde_json::from_str(&raw).ok()
}

async fn write_state<T: serde::Serialize>(ctx: &Context, name: &str, value: &T) -> bool {
    match serde_json::to_string(value) {
        Ok(raw) => tokio::fs::write(ctx.share_dir().join(name), raw)
            .await
            .is_ok(),
        Err(_) => false,
    }
}

fn main() {
    run(Marks {
        state: Mutex::new(MarksState::default()),
        apps: Mutex::new(HashMap::new()),
    });
}
