//! The machine and session actions: lock, sleep, restart, shut down, log
//! out, empty the Trash, dark mode and the screen saver.
//!
//! The mechanisms stay in the host. This plugin owns the command words, the
//! `@system` rows and their wording, and asks for each action through
//! `host.system_action`. The four that cannot be undone declare `confirm`,
//! on their manifest command and on their row: the host asks the question
//! and honours the action only inside the perform the user confirmed, so
//! nothing here can restart the Mac unprompted.

use flash_plugin::{
    Candidate, CommandRequest, Context, PerformResponse, SearchRequest, SearchResponse,
    SystemAction, SystemActionOutcome, run,
};

/// The plugin's one source, live and `per_scope`: nine fixed rows, pulled
/// when a query names `@system` and filtered by the host.
const SOURCE: &str = "system.actions";

/// One action as the user meets it: a command and a flashlight row.
struct Entry {
    action: SystemAction,
    /// The two words of `flash <command>`, and the row's payload.
    command: &'static str,
    title: &'static str,
    subtitle: &'static str,
    /// Extra words the flashlight matches besides the title: synonyms, and
    /// the words the action is commonly typed as.
    aliases: &'static [&'static str],
    /// The question asked first, for an action nothing undoes: the row's
    /// `confirm`, and the same text as the command's in the manifest.
    confirm: Option<&'static str>,
}

/// Every action, in the order the rows list them.
const ENTRIES: [Entry; 9] = [
    Entry {
        action: SystemAction::LockScreen,
        command: "screen lock",
        title: "Lock screen",
        subtitle: "Require password and keep apps running",
        aliases: &["lock", "screen", "secure", "password"],
        confirm: None,
    },
    Entry {
        action: SystemAction::Sleep,
        command: "system sleep",
        title: "Sleep Mac",
        subtitle: "Put the machine to sleep",
        aliases: &["sleep", "suspend", "standby"],
        confirm: None,
    },
    Entry {
        action: SystemAction::DisplaySleep,
        command: "display sleep",
        title: "Turn display off",
        subtitle: "Sleep the display without sleeping the machine",
        aliases: &["displaysleep", "display", "screen", "off"],
        confirm: None,
    },
    Entry {
        action: SystemAction::Restart,
        command: "system restart",
        title: "Restart Mac",
        subtitle: "Ask macOS to restart",
        aliases: &["restart", "reboot"],
        confirm: Some("Restart this Mac?"),
    },
    Entry {
        action: SystemAction::Shutdown,
        command: "system shutdown",
        title: "Shut down Mac",
        subtitle: "Ask macOS to power off",
        aliases: &["shutdown", "power", "poweroff", "halt"],
        confirm: Some("Shut down this Mac?"),
    },
    Entry {
        action: SystemAction::Logout,
        command: "system logout",
        title: "Log out",
        subtitle: "End the current macOS login session",
        aliases: &["logout", "sign out", "signout"],
        confirm: Some("Log out of macOS?"),
    },
    Entry {
        action: SystemAction::EmptyTrash,
        command: "trash empty",
        title: "Empty Trash",
        subtitle: "Ask Finder to empty the Trash",
        aliases: &["trash", "bin", "garbage"],
        confirm: Some("Empty the Trash?"),
    },
    Entry {
        action: SystemAction::ToggleAppearance,
        command: "appearance toggle",
        title: "Toggle dark mode",
        subtitle: "Switch between light and dark appearance",
        aliases: &["dark", "appearance", "light"],
        confirm: None,
    },
    Entry {
        action: SystemAction::Screensaver,
        command: "screensaver start",
        title: "Start screen saver",
        subtitle: "Launch ScreenSaverEngine",
        aliases: &["screensaver", "screen saver", "screensave"],
        confirm: None,
    },
];

fn entry(command: &str) -> Option<&'static Entry> {
    ENTRIES.iter().find(|entry| entry.command == command)
}

/// The `@system` rows. Selecting one runs its action; one that cannot be
/// undone carries the question the host asks first.
fn rows() -> Vec<Candidate> {
    ENTRIES
        .iter()
        .map(|entry| {
            let row = Candidate::new(SOURCE, entry.title)
                .kind("system_action")
                .subtitle(entry.subtitle)
                .aliases(entry.aliases.iter().copied().chain([entry.command]))
                .payload(entry.command)
                .finishes_command(true);
            match entry.confirm {
                Some(prompt) => row.confirm(prompt),
                None => row,
            }
        })
        .collect()
}

/// Ask the host for the action. A failure is the command's words and the
/// host's reason, which the host shows and hands to whoever ran it.
async fn perform(ctx: &Context, entry: &Entry) -> PerformResponse {
    match ctx.system_action(entry.action).await {
        Ok(SystemActionOutcome::Done) => PerformResponse::ok(),
        // macOS has the request and has not answered: Finder emptying a full
        // Trash, or an Automation prompt still open. Not a failure.
        Ok(SystemActionOutcome::Pending) => {
            PerformResponse::ok().message(format!("{}: macOS has not answered yet", entry.command))
        }
        Err(reason) => PerformResponse::fail(format!("{} failed: {reason}", entry.command)),
    }
}

struct System;

flash_plugin::plugin!(System);

impl FlashPlugin for System {
    async fn on_search(&self, _ctx: Context, request: SearchRequest) -> SearchResponse {
        if request.source != SOURCE {
            return SearchResponse::default();
        }
        SearchResponse::rows(rows())
    }

    async fn on_command(&self, ctx: Context, request: CommandRequest) -> PerformResponse {
        let name = request.name();
        let Some(entry) = entry(&name) else {
            return PerformResponse::fail(format!("unknown command: {name}"));
        };
        // None of these commands takes an argument.
        if !request.args.is_empty() {
            return PerformResponse::fail(format!("usage: {name}"));
        }
        perform(&ctx, entry).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        match row.payload_str().and_then(entry) {
            Some(entry) => perform(&ctx, entry).await,
            None => PerformResponse::fail("unknown system action"),
        }
    }
}

fn main() {
    run(System);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::{Harness, WireHarness};
    use serde_json::{Value, json};

    fn manifest() -> Value {
        serde_json::from_str(include_str!("../manifest.json")).unwrap()
    }

    fn request(words: &str, args: &[&str]) -> CommandRequest {
        let (command, subcommand) = words.split_once(' ').unwrap();
        CommandRequest {
            command: command.to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            ..CommandRequest::default()
        }
    }

    /// Run `request` against a host that answers its one call with `reply`:
    /// the action the host was asked for, then the command's reply.
    async fn run_command(request: CommandRequest, reply: Value) -> (Value, Value) {
        let mut harness = Harness::new("system");
        let ctx = harness.context();
        let task = tokio::spawn(async move { System.on_command(ctx, request).await });
        let (id, method, params) = harness.next_host_request().await.expect("a host call");
        assert_eq!(method, "host.system_action");
        assert!(harness.reply_host(id, reply));
        (params, serde_json::to_value(task.await.unwrap()).unwrap())
    }

    /// The manifest declares exactly the commands the plugin runs, and asks
    /// the same question before a command as before its row.
    #[test]
    fn the_manifest_declares_every_command_and_its_question() {
        let manifest = manifest();
        let declared: Vec<(String, Option<String>)> = manifest["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|command| {
                (
                    format!(
                        "{} {}",
                        command["command"].as_str().unwrap(),
                        command["subcommand"].as_str().unwrap()
                    ),
                    command["confirm"].as_str().map(str::to_string),
                )
            })
            .collect();
        let mut expected: Vec<(String, Option<String>)> = ENTRIES
            .iter()
            .map(|entry| (entry.command.to_string(), entry.confirm.map(str::to_string)))
            .collect();
        let mut sorted = declared.clone();
        sorted.sort();
        expected.sort();
        assert_eq!(sorted, expected);
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SOURCE, "type": "system", "live": "per_scope" }])
        );
        assert_eq!(manifest["capabilities"], json!(["system_actions"]));
        assert!(manifest.get("sandbox").is_none(), "the default sandbox");
    }

    /// A question is asked exactly for what the host treats as destructive.
    #[test]
    fn only_what_cannot_be_undone_asks_first() {
        for entry in &ENTRIES {
            assert_eq!(
                entry.confirm.is_some(),
                entry.action.is_destructive(),
                "{}",
                entry.command
            );
        }
        let asking: Vec<&str> = ENTRIES.iter().filter_map(|entry| entry.confirm).collect();
        assert_eq!(
            asking,
            [
                "Restart this Mac?",
                "Shut down this Mac?",
                "Log out of macOS?",
                "Empty the Trash?"
            ]
        );
        let actions: Vec<SystemAction> = ENTRIES.iter().map(|entry| entry.action).collect();
        for action in SystemAction::ALL {
            assert_eq!(
                actions.iter().filter(|listed| **listed == action).count(),
                1,
                "{action:?}"
            );
        }
    }

    #[test]
    fn the_rows_are_the_actions_with_their_words_and_questions() {
        let rows = rows();
        let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
        assert_eq!(
            titles,
            [
                "Lock screen",
                "Sleep Mac",
                "Turn display off",
                "Restart Mac",
                "Shut down Mac",
                "Log out",
                "Empty Trash",
                "Toggle dark mode",
                "Start screen saver",
            ]
        );
        assert!(rows.iter().all(|row| row.source == SOURCE));
        let restart = &rows[3];
        assert_eq!(restart.meta("kind"), Some("system_action"));
        assert_eq!(restart.meta("subtitle"), Some("Ask macOS to restart"));
        assert_eq!(
            restart.meta("aliases"),
            Some("restart reboot system restart")
        );
        assert_eq!(restart.payload_str(), Some("system restart"));
        assert_eq!(restart.meta("finishes_command"), Some("1"));
        assert_eq!(restart.confirm.as_deref(), Some("Restart this Mac?"));
        let lock = &rows[0];
        assert_eq!(
            lock.meta("aliases"),
            Some("lock screen secure password screen lock")
        );
        assert_eq!(lock.confirm, None);
        let asking: Vec<&str> = rows
            .iter()
            .filter(|row| row.confirm.is_some())
            .map(|row| row.title.as_str())
            .collect();
        assert_eq!(
            asking,
            ["Restart Mac", "Shut down Mac", "Log out", "Empty Trash"]
        );
    }

    #[tokio::test]
    async fn each_command_asks_the_host_for_its_action() {
        for entry in &ENTRIES {
            let (params, response) =
                run_command(request(entry.command, &[]), json!({ "ok": true })).await;
            assert_eq!(params, json!({ "action": entry.action.as_str() }));
            assert_eq!(response, json!({ "ok": true }), "{}", entry.command);
        }
    }

    /// The host's reason reaches the user as the command's failure, the
    /// refusal of an unconfirmed destructive action included.
    #[tokio::test]
    async fn a_failure_says_what_failed_and_why() {
        let (_, response) = run_command(
            request("system sleep", &[]),
            json!({ "ok": false, "error": "power management unavailable" }),
        )
        .await;
        assert_eq!(
            response,
            json!({ "ok": false, "error": "system sleep failed: power management unavailable" })
        );
        let (params, response) = run_command(
            request("system restart", &[]),
            json!({ "ok": false, "error": flash_plugin::CONFIRMATION_REQUIRED_ERROR }),
        )
        .await;
        assert_eq!(params, json!({ "action": "restart" }));
        assert_eq!(
            response,
            json!({
                "ok": false,
                "error": "system restart failed: requires a perform the user confirmed"
            })
        );
    }

    /// macOS still at it when the wait ends is no failure.
    #[tokio::test]
    async fn an_action_macos_has_not_answered_yet_is_not_a_failure() {
        let (_, response) = run_command(
            request("trash empty", &[]),
            json!({ "ok": false, "error": "host call timed out" }),
        )
        .await;
        assert_eq!(
            response,
            json!({ "ok": true, "message": "trash empty: macOS has not answered yet" })
        );
    }

    #[tokio::test]
    async fn an_argument_or_an_unknown_word_asks_the_host_nothing() {
        let mut harness = Harness::new("system");
        for (words, args, error) in [
            ("screen lock", vec!["--now"], "usage: screen lock"),
            ("system restart", vec!["now"], "usage: system restart"),
            (
                "system hibernate",
                vec![],
                "unknown command: system hibernate",
            ),
        ] {
            let response = System
                .on_command(harness.context(), request(words, &args))
                .await;
            assert_eq!(
                serde_json::to_value(response).unwrap(),
                json!({ "ok": false, "error": error })
            );
        }
        let unknown = System
            .on_resolve(
                harness.context(),
                Candidate::new(SOURCE, "Hibernate").payload("system hibernate"),
            )
            .await;
        assert_eq!(unknown.error_message(), Some("unknown system action"));
        assert_eq!(harness.drain(), Vec::<Value>::new(), "no host call");
    }

    /// Over the wire, through the generated routing: a search answers the
    /// rows without the plugin having published anything, and a row comes
    /// back in its resolve to run its action.
    #[tokio::test]
    async fn a_search_lists_the_rows_and_a_resolved_row_runs_its_action() {
        let mut wire = WireHarness::new(System);
        wire.send(json!({ "id": 1, "method": "initialize", "params": { "protocol_version": 1 } }))
            .await;
        assert_eq!(wire.recv_response(1).await["ok"], true);
        wire.send(json!({
            "id": 2, "method": "search", "deadline_ms": 1000,
            "params": { "source": SOURCE, "query": "" }
        }))
        .await;
        let reply = wire.recv().await;
        assert_eq!(reply["id"], 2, "nothing is published first: {reply}");
        let listed = reply["result"]["rows"].as_array().unwrap().clone();
        assert_eq!(listed.len(), ENTRIES.len());
        assert_eq!(listed[3]["confirm"], "Restart this Mac?");
        assert!(listed[0].get("confirm").is_none());

        wire.send(json!({
            "id": 3, "method": "search",
            "params": { "source": "system.other", "query": "" }
        }))
        .await;
        assert_eq!(
            wire.recv_response(3).await,
            json!({ "ok": true, "rows": [] })
        );

        wire.send(json!({ "id": 4, "method": "perform", "params": {
            "kind": "resolve", "row": listed[3], "confirmed": true
        }}))
        .await;
        let call = wire.recv().await;
        assert_eq!(call["method"], "host.system_action");
        assert_eq!(call["params"], json!({ "action": "restart" }));
        wire.send(json!({ "id": call["id"], "result": { "ok": true } }))
            .await;
        assert_eq!(wire.recv_response(4).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }
}
