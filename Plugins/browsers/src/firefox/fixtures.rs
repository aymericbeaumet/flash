//! Builders shared by the Firefox engine's unit tests.

use flash_plugin::testing::Harness;
use serde_json::{Value, json};
use tokio::task::JoinHandle;

use super::strip::{AxWindow, Strip, Tab};

pub(super) fn tab(root: usize, title: &str, url: &str) -> Tab {
    Tab {
        root,
        title: title.into(),
        url: url.into(),
        ..Tab::default()
    }
}

/// `windows` AX windows (none main) holding `tabs`.
pub(super) fn strip(windows: usize, tabs: Vec<Tab>) -> Strip {
    Strip {
        windows: vec![AxWindow::default(); windows],
        tabs,
    }
}

/// A `host.ax_snapshot` reply: one untitled window holding `(title, url,
/// selected)` tabs, each exposing its URL.
pub(super) fn ax_reply(tabs: &[(&str, &str, bool)]) -> Value {
    let mut nodes = vec![json!({
        "handle": 1,
        "root": 0,
        "attrs": {"AXRole": "AXWindow", "AXMain": "1"},
    })];
    for (offset, (title, url, selected)) in tabs.iter().enumerate() {
        nodes.push(json!({
            "handle": 10 + offset,
            "parent": 1,
            "root": 0,
            "attrs": {
                "AXRole": "AXTab",
                "AXTitle": title,
                "AXURL": url,
                "AXSelected": if *selected { "1" } else { "0" },
            },
        }));
    }
    json!({"ok": true, "nodes": nodes})
}

/// Play the host for `task`: answer each of its host calls with
/// `reply(method)` until it finishes. Returns its output and the methods it
/// called before finishing, in order.
pub(super) async fn serve_host<T>(
    harness: &mut Harness,
    mut task: JoinHandle<T>,
    mut reply: impl FnMut(&str) -> Value,
) -> (T, Vec<String>) {
    let mut methods = Vec::new();
    loop {
        tokio::select! {
            biased;
            done = &mut task => return (done.expect("task completes"), methods),
            frame = harness.next_frame() => {
                let frame = frame.expect("a frame within the harness deadline");
                if let (Some(id), Some(method)) = (frame["id"].as_u64(), frame["method"].as_str()) {
                    harness.reply_host(id, reply(method));
                    methods.push(method.to_string());
                } else if frame["method"] == "poll" {
                    // Play the host's clock: a waited-on deadline is due now.
                    for (name, entry) in frame["params"]["registrations"].as_object().unwrap() {
                        if entry.get("after").is_some() {
                            drop(harness.deliver_poll_tick(name));
                        }
                    }
                }
            }
        }
    }
}
