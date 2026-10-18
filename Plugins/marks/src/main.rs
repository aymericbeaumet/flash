use flash_plugin::{CommandRequest, Context, PerformResponse, RunningApplication, run};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use tokio::sync::Mutex;

const STATE_FILE: &str = "marks.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct MarksState {
    /// ASCII letter or digit → saved app context. The
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
}

flash_plugin::plugin!(Marks);

impl FlashPlugin for Marks {
    async fn on_start(&self, ctx: Context) {
        if let Some(loaded) = read_state::<MarksState>(&ctx, STATE_FILE).await {
            *self.state.lock().await = loaded;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "set" => set_mark_command(self, &ctx, &command).await,
            "jump" => jump_to_mark_command(self, &ctx, &command).await,
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

/// A slot is one ASCII letter or digit: `flash marks set a`, or
/// `--letter=a`. Anything else is rejected so a typo does not create a slot.
fn parse_letter(command: &CommandRequest) -> Option<String> {
    fn one_letter(value: &str) -> Option<String> {
        let trimmed = value.trim();
        if trimmed.chars().count() != 1 {
            return None;
        }
        let ch = trimmed.chars().next()?;
        if !ch.is_ascii_alphanumeric() {
            return None;
        }
        Some(ch.to_ascii_lowercase().to_string())
    }
    for arg in &command.args {
        let body = arg.strip_prefix("--").unwrap_or(arg.as_str());
        if let Some(value) = body.strip_prefix("letter=") {
            return one_letter(value);
        }
    }
    if command.args.len() == 1 {
        return one_letter(&command.args[0]);
    }
    None
}

async fn set_mark_command(
    plugin: &Marks,
    ctx: &Context,
    command: &CommandRequest,
) -> PerformResponse {
    let Some(letter) = parse_letter(command) else {
        return PerformResponse::fail("usage: marks set <a-z|0-9>");
    };
    let Some(target) = ctx.normal_mode_target().await else {
        return PerformResponse::fail("no focused non-flash app");
    };
    let entry = MarkEntry {
        pid: target.pid,
        bundle_id: target.bundle_id.clone(),
    };
    let mut state = plugin.state.lock().await;
    let mut next = state.clone();
    next.entries.insert(letter.clone(), entry);
    if !write_state(ctx, STATE_FILE, &next).await {
        return PerformResponse::fail("could not save mark");
    }
    *state = next;
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
        return PerformResponse::fail("usage: marks jump <a-z|0-9>");
    };
    let mark = plugin.state.lock().await.entries.get(&letter).cloned();
    let Some(mark) = mark else {
        return PerformResponse::fail(format!("no mark for letter={letter}"));
    };
    if let Some(pid) = running_pid_for_mark(&mark, &ctx.running_applications())
        && ctx.activate(pid).await
    {
        let mut state = plugin.state.lock().await;
        if let Some(entry) = state.entries.get(&letter)
            && entry.pid == mark.pid
            && entry.bundle_id == mark.bundle_id
            && pid != mark.pid
        {
            let mut next = state.clone();
            next.entries.get_mut(&letter).expect("checked above").pid = pid;
            if write_state(ctx, STATE_FILE, &next).await {
                *state = next;
            }
        }
        return PerformResponse::ok().target_pid(pid);
    }
    if ctx.open_app(&mark.bundle_id).await {
        return PerformResponse::ok();
    }
    PerformResponse::fail(format!(
        "mark letter={letter} bundle={} unreachable",
        mark.bundle_id
    ))
}

fn running_pid_for_mark(mark: &MarkEntry, apps: &[RunningApplication]) -> Option<i64> {
    apps.iter()
        .find(|app| app.pid == mark.pid && app.bundle_id == mark.bundle_id)
        .or_else(|| {
            apps.iter()
                .find(|app| app.pid > 0 && app.bundle_id == mark.bundle_id)
        })
        .map(|app| app.pid)
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
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::json;
    use std::sync::Arc;

    fn command(args: &[&str]) -> CommandRequest {
        CommandRequest {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            ..CommandRequest::default()
        }
    }

    #[test]
    fn slots_are_ascii_letters_and_digits_only() {
        assert_eq!(parse_letter(&command(&["A"])), Some("a".to_string()));
        assert_eq!(parse_letter(&command(&["7"])), Some("7".to_string()));
        assert_eq!(
            parse_letter(&command(&["--letter=z"])),
            Some("z".to_string())
        );
        assert_eq!(parse_letter(&command(&["é"])), None);
        assert_eq!(parse_letter(&command(&["٢"])), None);
    }

    #[test]
    fn saved_pid_must_still_belong_to_the_marked_bundle() {
        let mark = MarkEntry {
            pid: 17,
            bundle_id: "com.example.editor".to_string(),
        };
        let apps = vec![
            RunningApplication {
                pid: 17,
                bundle_id: "com.example.other".to_string(),
                ..RunningApplication::default()
            },
            RunningApplication {
                pid: 29,
                bundle_id: "com.example.editor".to_string(),
                ..RunningApplication::default()
            },
        ];
        assert_eq!(running_pid_for_mark(&mark, &apps), Some(29));
    }

    #[tokio::test]
    async fn jump_launches_the_saved_bundle_when_it_is_not_running() {
        let plugin = Marks {
            state: Mutex::new(MarksState {
                entries: BTreeMap::from([(
                    "a".to_string(),
                    MarkEntry {
                        pid: 17,
                        bundle_id: "com.example.editor".to_string(),
                    },
                )]),
            }),
        };
        let mut host = Harness::new("marks");
        let ctx = host.context();
        let request =
            tokio::spawn(
                async move { jump_to_mark_command(&plugin, &ctx, &command(&["a"])).await },
            );

        let (id, method, params) = host.next_host_request().await.expect("host request");
        assert_eq!(method, "host.open");
        assert_eq!(params, json!({ "bundle_id": "com.example.editor" }));
        assert!(host.reply_host(id, json!({ "ok": true })));
        assert_eq!(
            serde_json::to_value(request.await.expect("command task")).expect("response"),
            json!({ "ok": true })
        );
    }

    #[tokio::test]
    async fn failed_save_does_not_claim_or_keep_a_mark() {
        let plugin = Arc::new(Marks {
            state: Mutex::new(MarksState::default()),
        });
        let mut host = Harness::new("marks");
        let ctx = host.context();
        let request = tokio::spawn({
            let plugin = Arc::clone(&plugin);
            async move { set_mark_command(&plugin, &ctx, &command(&["a"])).await }
        });

        let (id, method, _) = host.next_host_request().await.expect("host request");
        assert_eq!(method, "host.normal_mode_target");
        assert!(host.reply_host(
            id,
            json!({ "present": true, "pid": 17, "bundle_id": "com.example.editor" })
        ));
        let response =
            serde_json::to_value(request.await.expect("command task")).expect("response");
        assert_eq!(
            response,
            json!({ "ok": false, "error": "could not save mark" })
        );
        assert!(plugin.state.lock().await.entries.is_empty());
    }
}
