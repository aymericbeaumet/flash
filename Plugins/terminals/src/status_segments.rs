//! Statusbar segments (`session` / `window` / `pane`) derived from the
//! attached client and published on change.

use std::sync::Mutex;

use flash_plugin::{Context, Markup};

use crate::clients::{TmuxClient, split_tmux_fields};

/// Values for the manifest-declared statusbar segments
/// (`#{flash.plugin.terminals.session}` / `.window` / `.pane`). Empty strings clear
/// the segments host-side.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct TmuxStatusSegments {
    session: String,
    window: String,
    pane: String,
}

/// Attached-client tmux state for the statusbar, derived from the same
/// `list-clients ; list-windows -a` inventory the candidate build already
/// fetched — no extra tmux I/O. The most recently active attached client
/// wins (`client_activity`), then its session's active window supplies the
/// window name (index when unnamed) and active-pane index.
pub(crate) fn status_segments(clients: &[TmuxClient], raw_windows: &str) -> TmuxStatusSegments {
    let Some(client) = clients.iter().max_by_key(|client| client.activity) else {
        return TmuxStatusSegments::default();
    };
    let mut segments = TmuxStatusSegments {
        session: client.session.clone(),
        ..TmuxStatusSegments::default()
    };
    for line in raw_windows.lines() {
        let parts = split_tmux_fields(line, 8);
        if parts.len() < 3 || parts[0] != client.session {
            continue;
        }
        if parts.get(5).map(|active| active.trim()) != Some("1") {
            continue;
        }
        let name = parts[2].trim();
        segments.window = if name.is_empty() {
            parts[1].trim().to_string()
        } else {
            name.to_string()
        };
        segments.pane = parts
            .get(6)
            .map(|pane| pane.trim().to_string())
            .unwrap_or_default();
        break;
    }
    segments
}

/// Emit the `session` / `window` / `pane` statusbar segments when their
/// values changed since the last publish. Piggybacks on the candidate
/// refresh — no timer of its own — and stays quiet on unchanged state so
/// refreshes do not spam the host's telemetry lane. Empty
/// values (no attached local client, no tmux server) clear the segments
/// host-side per the wire contract.
pub(crate) fn publish_status_segments(
    ctx: &Context,
    last_status: &Mutex<Option<TmuxStatusSegments>>,
    current: &TmuxStatusSegments,
) {
    let Ok(mut guard) = last_status.lock() else {
        return;
    };
    if guard.as_ref() == Some(current) {
        return;
    }
    *guard = Some(current.clone());
    ctx.status([
        ("session", Markup::text(&current.session)),
        ("window", Markup::text(&current.window)),
        ("pane", Markup::text(&current.pane)),
    ]);
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::test_support::client;

    #[test]
    fn status_segments_follow_the_most_recent_client_and_its_active_window() {
        let clients = vec![
            client("/dev/ttys000", "work", 100, 10),
            client("/dev/ttys001", "play", 200, 99),
        ];
        let raw = "work\t1\teditor\tnvim\t/w\t1\t2\n\
play\t1\tshell\tzsh\t/p\t0\t0\n\
play\t3\tflash\tzsh\t/p\t1\t4\n";

        assert_eq!(
            status_segments(&clients, raw),
            TmuxStatusSegments {
                session: "play".to_string(),
                window: "flash".to_string(),
                pane: "4".to_string(),
            }
        );
    }

    #[test]
    fn status_segments_fall_back_to_the_window_index_when_unnamed() {
        let clients = vec![client("/dev/ttys000", "work", 100, 10)];
        let raw = "work\t2\t\tzsh\t/w\t1\t0\n";

        let segments = status_segments(&clients, raw);
        assert_eq!(segments.session, "work");
        assert_eq!(segments.window, "2");
        assert_eq!(segments.pane, "0");
    }

    #[test]
    fn status_segments_clear_without_attached_clients() {
        assert_eq!(
            status_segments(&[], "work\t1\teditor\tnvim\t/w\t1\t0\n"),
            TmuxStatusSegments::default(),
            "no attached client publishes empty values, which clear the \
             segments host-side"
        );
    }

    #[test]
    fn published_status_segments_escape_hashes_in_tmux_names() {
        let mut harness = flash_plugin::testing::Harness::new("tmux");
        let last_status = Mutex::new(None);
        let segments = TmuxStatusSegments {
            session: "work #1".to_string(),
            window: "#[bold]logs".to_string(),
            pane: "0".to_string(),
        };

        publish_status_segments(&harness.context(), &last_status, &segments);
        publish_status_segments(&harness.context(), &last_status, &segments);

        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1, "unchanged segments stay off the wire");
        assert_eq!(frames[0]["session"], "work ##1");
        assert_eq!(frames[0]["window"], "##[bold]logs");
        assert_eq!(frames[0]["pane"], "0");
    }
}
