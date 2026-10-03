//! Follows local tmux servers through control mode instead of re-reading
//! their inventory on a timer.
//!
//! Each local server a user's client is attached to gets one observer: a
//! `tmux -C attach-session` client that never receives pane output
//! (`no-output`), never sizes a window (`ignore-size`), moves to another
//! session rather than leaving when its own is destroyed
//! (`no-detach-on-destroy`, tmux 3.6; older releases ignore it and the
//! observer reattaches), never starts a server (`-N`) and never applies
//! `update-environment` to a session (`-E`; without it, attaching would strip
//! `SSH_AUTH_SOCK` and the like from the session's environment). It follows
//! the session the most recently active user client shows, so it marks no
//! other session attached, and reports every notification that can change
//! the inventory. Servers without a user client are never attached:
//! attaching would mark them attached, run their client hooks and keep
//! `destroy-unattached` sessions alive.
//!
//! The observer is deliberately not `read-only`. tmux resolves a command
//! that names no client (`tmux send-keys -t pane …` from a script outside
//! tmux) against the most recently active client, which is the observer
//! from its attach until the user's next keystroke; a read-only observer
//! would fail such commands with "client is read-only". Only this process
//! writes to the observer, and only `switch-client`.
//!
//! The observer's stdin is a pipe only this process holds. Closing it — on
//! stop, on shutdown, or by this process dying — makes tmux drop the client;
//! `kill_on_drop` backs that up.

use std::collections::{BTreeMap, HashMap};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use flash_plugin::{Context, PollPriority};
use regex::Regex;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};
use tokio::sync::watch;
use tokio::task::JoinHandle;

/// tmux 3.2 added `-N`, client flags and the notifications followed here.
const MIN_VERSION: (u32, u32) = (3, 2);
const CLIENT_FLAGS: &str = "no-output,ignore-size,no-detach-on-destroy";
/// Longest line kept; the rest of a longer one is dropped. Its leading words,
/// which decide the reaction, survive.
const LINE_LIMIT: usize = 64 * 1024;
/// An observer attached this long ended for a reason of its own (a user
/// detached it, its session was destroyed before tmux 3.6): it reattaches at
/// once.
const STABLE_AFTER: Duration = Duration::from_secs(30);
/// Reattach delays after observers that ended sooner.
const RETRY_DELAYS_SECS: [u64; 4] = [1, 5, 15, 60];
/// How long a client may take to leave once its stdin closed.
const EXIT_GRACE: Duration = Duration::from_secs(2);
/// Shutdown's share of the SDK's 750 ms shutdown deadline.
const SHUTDOWN_GRACE: Duration = Duration::from_millis(500);

/// Whether `tmux -V` output names a release that supports observers.
/// Builds naming no numbered release (`tmux master`) are current.
pub(crate) fn supports_observers(version_output: &str) -> bool {
    let Some(version) = version_output.trim().strip_prefix("tmux ") else {
        return false;
    };
    let version = version.strip_prefix("next-").unwrap_or(version);
    if !version.starts_with(|c: char| c.is_ascii_digit()) {
        return !version.is_empty();
    }
    let mut parts = version.split('.');
    let number = |part: Option<&str>| {
        part.map(|part| part.trim_end_matches(|c: char| !c.is_ascii_digit()))
            .and_then(|part| part.parse::<u32>().ok())
    };
    match (number(parts.next()), number(parts.next())) {
        (Some(major), Some(minor)) => (major, minor) >= MIN_VERSION,
        (Some(major), None) => major > MIN_VERSION.0,
        _ => false,
    }
}

/// A tmux session id: `$` and digits, safe to pass unquoted on argv and
/// single-quoted in a command line.
pub(crate) fn is_session_id(value: &str) -> bool {
    value
        .strip_prefix('$')
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

/// The pane ids of a `window_layout`, in layout order: its leaf cells are
/// `WxH,X,Y,ID`, split cells `WxH,X,Y` followed by `{`/`[`.
fn layout_pane_ids(layout: &str) -> String {
    static LEAF: OnceLock<Regex> = OnceLock::new();
    let leaf = LEAF.get_or_init(|| Regex::new(r"\d+x\d+,\d+,\d+,(\d+)").expect("tmux layout leaf"));
    leaf.captures_iter(layout)
        .filter_map(|leaf| leaf.get(1))
        .map(|id| id.as_str())
        .collect::<Vec<_>>()
        .join(",")
}

/// What an observer does after one line of its client.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ControlReaction {
    /// The inventory may have changed: re-read it.
    pub(crate) refresh: bool,
    /// The client is leaving (`%exit`).
    pub(crate) exit: bool,
}

const REFRESH: ControlReaction = ControlReaction {
    refresh: true,
    exit: false,
};
const IGNORE: ControlReaction = ControlReaction {
    refresh: false,
    exit: false,
};

/// Reads a control client's stdout line by line.
#[derive(Default)]
pub(crate) struct ControlStream {
    /// Inside a `%begin` … `%end`/`%error` command reply: its lines are
    /// command output, not notifications.
    in_reply: bool,
    /// The session this client shows, from `%session-changed`.
    session_id: Option<String>,
    /// Each window's pane ids in layout order, from `%layout-change`.
    panes: HashMap<String, String>,
}

impl ControlStream {
    pub(crate) fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    pub(crate) fn feed(&mut self, line: &str) -> ControlReaction {
        let mut words = line.split(' ');
        let name = words.next().unwrap_or_default();
        if self.in_reply {
            self.in_reply = !matches!(name, "%end" | "%error");
            return IGNORE;
        }
        match name {
            "%begin" => {
                self.in_reply = true;
                IGNORE
            }
            "%exit" => ControlReaction {
                refresh: false,
                exit: true,
            },
            // The client itself moved: on attach, when it follows a user
            // client, or when its session was destroyed.
            "%session-changed" => {
                self.session_id = words
                    .next()
                    .filter(|id| is_session_id(id))
                    .map(str::to_string);
                self.panes.clear();
                REFRESH
            }
            "%window-close" | "%unlinked-window-close" => {
                if let Some(window) = words.next() {
                    self.panes.remove(window);
                }
                REFRESH
            }
            // Reported for the followed session's windows. A resize only
            // changes the geometry; panes added, closed or reordered change
            // the active pane's index the status segment shows.
            "%layout-change" => {
                let (Some(window), Some(layout)) = (words.next(), words.next()) else {
                    return IGNORE;
                };
                let panes = layout_pane_ids(layout);
                if self.panes.get(window) == Some(&panes) {
                    return IGNORE;
                }
                self.panes.insert(window.to_string(), panes);
                REFRESH
            }
            "%sessions-changed"
            | "%session-renamed"
            | "%session-window-changed"
            | "%client-session-changed"
            | "%client-detached"
            | "%window-add"
            | "%window-renamed"
            | "%unlinked-window-add"
            | "%unlinked-window-renamed"
            | "%window-pane-changed" => REFRESH,
            // Pane output (suppressed by `no-output` anyway), pane modes,
            // paste buffers, messages, flow control, subscriptions, notifications
            // added by later releases and anything malformed change nothing
            // the inventory reads.
            _ => IGNORE,
        }
    }
}

/// The command moving the observer onto `wanted`, unless it is not attached
/// yet, already there, or already asked to go there.
pub(crate) fn follow_command(
    current: Option<&str>,
    wanted: &str,
    requested: Option<&str>,
) -> Option<String> {
    let current = current?;
    if !is_session_id(wanted) || current == wanted || requested == Some(wanted) {
        return None;
    }
    Some(format!("switch-client -E -t '{wanted}'\n"))
}

/// Newline-terminated lines of at most `limit` bytes; the rest of a longer
/// line is dropped. Progress lives in `self`, so a `select!` may drop
/// [`next_line`](Self::next_line) between reads without losing bytes.
pub(crate) struct BoundedLines<R> {
    reader: BufReader<R>,
    line: Vec<u8>,
    limit: usize,
}

impl<R: AsyncRead + Unpin> BoundedLines<R> {
    pub(crate) fn new(reader: R, limit: usize) -> Self {
        Self {
            reader: BufReader::new(reader),
            line: Vec::new(),
            limit,
        }
    }

    /// The next line without its newline; `None` at the end of the stream,
    /// dropping an unterminated fragment (tmux terminates every line).
    pub(crate) async fn next_line(&mut self) -> std::io::Result<Option<String>> {
        loop {
            let available = self.reader.fill_buf().await?;
            if available.is_empty() {
                return Ok(None);
            }
            let (chunk, consumed, complete) = match available.iter().position(|&b| b == b'\n') {
                Some(end) => (&available[..end], end + 1, true),
                None => (available, available.len(), false),
            };
            let room = self.limit.saturating_sub(self.line.len());
            self.line.extend_from_slice(&chunk[..chunk.len().min(room)]);
            self.reader.consume(consumed);
            if complete {
                let line = String::from_utf8_lossy(&self.line).into_owned();
                self.line.clear();
                return Ok(Some(line));
            }
        }
    }
}

pub(crate) fn observer_argv(tmux_path: &str, socket: &str, session_id: &str) -> Vec<String> {
    let mut args = vec!["-N", "-C", "attach-session", "-E", "-f", CLIENT_FLAGS];
    if is_session_id(session_id) {
        args.extend(["-t", session_id]);
    }
    crate::tmux_socket_argv(tmux_path, socket, &args)
}

/// The observers, one per followed server, keyed by socket path.
#[derive(Default)]
pub(crate) struct ControlObservers {
    running: Mutex<BTreeMap<String, Observer>>,
}

struct Observer {
    /// The session to follow. Dropping it stops the observer.
    follow: watch::Sender<String>,
    task: JoinHandle<()>,
}

impl ControlObservers {
    /// Converge on `plan` — socket path to the session id to follow:
    /// observers start for new servers (`start` spawns one), follow the
    /// planned session on the others, and stop for servers the plan no
    /// longer names. True when the set of followed servers changed.
    pub(crate) fn reconcile<F>(&self, plan: &BTreeMap<String, String>, mut start: F) -> bool
    where
        F: FnMut(&str, watch::Receiver<String>) -> JoinHandle<()>,
    {
        let mut running = self.running.lock().unwrap_or_else(|e| e.into_inner());
        let before = running.len();
        running.retain(|socket, observer| match plan.get(socket) {
            Some(session) if !observer.task.is_finished() => {
                observer.follow.send_if_modified(|current| {
                    let changed = current != session;
                    if changed {
                        current.clone_from(session);
                    }
                    changed
                });
                true
            }
            _ => false,
        });
        let mut changed = running.len() != before;
        for (socket, session) in plan {
            if running.contains_key(socket) {
                continue;
            }
            let (follow, receiver) = watch::channel(session.clone());
            let task = start(socket, receiver);
            running.insert(socket.clone(), Observer { follow, task });
            changed = true;
        }
        changed
    }

    pub(crate) fn count(&self) -> usize {
        self.running.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// Stop every observer and wait, bounded, for their clients to leave.
    pub(crate) async fn shutdown(&self) {
        let observers =
            std::mem::take(&mut *self.running.lock().unwrap_or_else(|e| e.into_inner()));
        let tasks: Vec<_> = observers
            .into_values()
            .map(|observer| observer.task)
            .collect();
        let _ = tokio::time::timeout(SHUTDOWN_GRACE, async {
            for task in tasks {
                let _ = task.await;
            }
        })
        .await;
    }
}

/// Keep one observer attached to `socket` until `follow` closes. `changed`
/// runs for every notification that can change the inventory and whenever
/// the client leaves on its own.
pub(crate) async fn observe(
    ctx: Context,
    tmux_path: String,
    socket: String,
    mut follow: watch::Receiver<String>,
    changed: Arc<dyn Fn() + Send + Sync>,
) {
    let mut failures = 0usize;
    loop {
        if follow.has_changed().is_err() {
            return;
        }
        let started = Instant::now();
        let status = match attach(&tmux_path, &socket, &mut follow, changed.as_ref()).await {
            Attachment::Stopped => return,
            Attachment::Ended(status) => status,
        };
        let attached_for = started.elapsed();
        failures = if attached_for >= STABLE_AFTER {
            0
        } else {
            failures + 1
        };
        ctx.log_fields(
            "debug",
            "[tmux] observer ended",
            BTreeMap::from([
                (
                    "attached_ms".to_string(),
                    attached_for.as_millis().to_string(),
                ),
                (
                    "status".to_string(),
                    status.map_or("none".to_string(), |s| s.to_string()),
                ),
                ("failures".to_string(), failures.to_string()),
            ]),
        );
        // Its session or server may have gone away with it.
        changed();
        if failures == 0 {
            continue;
        }
        let delay = RETRY_DELAYS_SECS[(failures - 1).min(RETRY_DELAYS_SECS.len() - 1)];
        // The backoff waits on the host's clock: `Low`, a reattach nobody
        // is waiting on. A new session to follow abandons the wait, which
        // releases its deadline.
        tokio::select! {
            () = ctx.wait(Duration::from_secs(delay), PollPriority::Low) => {}
            // A new session to follow retries at once; a closed plan stops.
            closed = follow.changed() => if closed.is_err() { return; },
        }
    }
}

enum Attachment {
    /// The plan dropped the server; the client is gone.
    Stopped,
    /// The client left on its own, with this exit status.
    Ended(Option<i32>),
}

async fn attach(
    tmux_path: &str,
    socket: &str,
    follow: &mut watch::Receiver<String>,
    changed: &(dyn Fn() + Send + Sync),
) -> Attachment {
    let session = follow.borrow_and_update().clone();
    let argv = observer_argv(tmux_path, socket, &session);
    let mut command = tokio::process::Command::new(&argv[0]);
    command
        .args(&argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let Ok(mut child) = command.spawn() else {
        return Attachment::Ended(None);
    };
    let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Attachment::Ended(None);
    };
    let mut lines = BoundedLines::new(stdout, LINE_LIMIT);
    let mut stream = ControlStream::default();
    let mut requested: Option<String> = None;
    let stopped = loop {
        tokio::select! {
            line = lines.next_line() => {
                let Ok(Some(line)) = line else { break false };
                let reaction = stream.feed(&line);
                if reaction.refresh {
                    changed();
                }
                if reaction.exit {
                    break false;
                }
            }
            closed = follow.changed() => if closed.is_err() { break true; },
        }
        let wanted = follow.borrow().clone();
        if let Some(command) = follow_command(stream.session_id(), &wanted, requested.as_deref()) {
            requested = Some(wanted);
            if stdin.write_all(command.as_bytes()).await.is_err() {
                break false;
            }
        }
    };
    // End of input detaches the client.
    drop(stdin);
    drop(lines);
    let status = match tokio::time::timeout(EXIT_GRACE, child.wait()).await {
        Ok(status) => status.ok().and_then(|status| status.code()),
        Err(_) => {
            let _ = child.kill().await;
            None
        }
    };
    if stopped {
        Attachment::Stopped
    } else {
        Attachment::Ended(status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observers_need_tmux_3_2() {
        for supported in [
            "tmux 3.2",
            "tmux 3.2a",
            "tmux 3.7b\n",
            "tmux next-3.8",
            "tmux 4.0",
            "tmux master",
            "tmux openbsd-7.6",
        ] {
            assert!(supports_observers(supported), "{supported}");
        }
        for unsupported in [
            "tmux 3.1c",
            "tmux 2.9a",
            "tmux 3",
            "",
            "tmux ",
            "screen 4.9",
        ] {
            assert!(!supports_observers(unsupported), "{unsupported}");
        }
    }

    #[test]
    fn session_ids_are_dollar_digits() {
        assert!(is_session_id("$0"));
        assert!(is_session_id("$12"));
        for invalid in ["", "$", "0", "$1a", "$-1", "main", "$1 ", "'$1'"] {
            assert!(!is_session_id(invalid), "{invalid}");
        }
    }

    #[test]
    fn layouts_yield_their_pane_ids_in_order() {
        assert_eq!(layout_pane_ids("b25f,80x24,0,0,2"), "2");
        assert_eq!(
            layout_pane_ids("c19b,80x24,0,0[80x12,0,0,1,80x11,0,13,5]"),
            "1,5"
        );
        assert_eq!(
            layout_pane_ids("1234,160x40,0,0{80x40,0,0,3,79x40,81,0[79x20,81,0,4,79x19,81,21,7]}"),
            "3,4,7"
        );
        assert_eq!(layout_pane_ids("garbage"), "");
    }

    fn feed_all(stream: &mut ControlStream, lines: &[&str]) -> Vec<ControlReaction> {
        lines.iter().map(|line| stream.feed(line)).collect()
    }

    #[test]
    fn inventory_notifications_refresh_and_the_rest_are_ignored() {
        let mut stream = ControlStream::default();
        for line in [
            "%sessions-changed",
            "%session-renamed $1 work",
            "%session-window-changed $1 @3",
            "%client-session-changed /dev/ttys001 $2 other",
            "%client-detached /dev/ttys001",
            "%window-add @4",
            "%window-close @4",
            "%window-renamed @3 vim",
            "%unlinked-window-add @5",
            "%unlinked-window-close @5",
            "%unlinked-window-renamed @5 zsh",
            "%window-pane-changed @3 %9",
        ] {
            assert_eq!(stream.feed(line), REFRESH, "{line}");
        }
        for line in [
            "%output %1 hello",
            "%extended-output %1 12 : hello",
            "%pane-mode-changed %1",
            "%paste-buffer-changed buffer0",
            "%paste-buffer-deleted buffer0",
            "%message hello",
            "%config-error bad",
            "%pause %1",
            "%continue %1",
            "%subscription-changed name $1 @1 1 %1 : value",
            "%a-notification-from-the-future @1",
            "%layout-change",
            "%layout-change @1",
            "not a notification",
            "",
            "%",
        ] {
            assert_eq!(stream.feed(line), IGNORE, "{line:?}");
        }
    }

    #[test]
    fn command_replies_are_output_not_notifications() {
        let mut stream = ControlStream::default();
        let reactions = feed_all(
            &mut stream,
            &[
                "%begin 1790803054 294 1",
                "%window-add @1",
                "%exit",
                "%end 1790803054 294 1",
                "%window-add @1",
                "%begin 1790803054 295 1",
                "can't find session: $9",
                "%error 1790803054 295 1",
                "%exit",
            ],
        );
        assert_eq!(
            reactions,
            [
                IGNORE,
                IGNORE,
                IGNORE,
                IGNORE,
                REFRESH,
                IGNORE,
                IGNORE,
                IGNORE,
                ControlReaction {
                    refresh: false,
                    exit: true
                },
            ]
        );
    }

    #[test]
    fn the_stream_tracks_its_own_session() {
        let mut stream = ControlStream::default();
        assert_eq!(stream.session_id(), None);
        assert_eq!(stream.feed("%session-changed $3 work"), REFRESH);
        assert_eq!(stream.session_id(), Some("$3"));
        assert_eq!(stream.feed("%session-changed bogus"), REFRESH);
        assert_eq!(stream.session_id(), None);
    }

    #[test]
    fn only_a_pane_set_change_makes_a_layout_change_count() {
        let mut stream = ControlStream::default();
        let split = "%layout-change @1 c19b,80x24,0,0[80x12,0,0,1,80x11,0,13,5] c19b,80x24,0,0[80x12,0,0,1,80x11,0,13,5] *";
        let resized = "%layout-change @1 d2a1,120x40,0,0[120x20,0,0,1,120x19,0,21,5] d2a1,120x40,0,0[120x20,0,0,1,120x19,0,21,5] *";
        let swapped = "%layout-change @1 d2a1,120x40,0,0[120x20,0,0,5,120x19,0,21,1] d2a1,120x40,0,0[120x20,0,0,5,120x19,0,21,1] *";
        let closed = "%layout-change @1 b25f,120x40,0,0,5 b25f,120x40,0,0,5 *";
        assert_eq!(stream.feed(split), REFRESH, "first sighting");
        assert_eq!(stream.feed(resized), IGNORE, "resize");
        assert_eq!(stream.feed(swapped), REFRESH, "reordered");
        assert_eq!(stream.feed(closed), REFRESH, "pane closed");
        assert_eq!(stream.feed(closed), IGNORE);
        assert_eq!(stream.feed("%window-close @1"), REFRESH);
        assert_eq!(stream.feed(closed), REFRESH, "forgotten with its window");
        assert_eq!(stream.feed("%session-changed $2 other"), REFRESH);
        assert_eq!(stream.feed(closed), REFRESH, "forgotten with its session");
    }

    #[test]
    fn the_observer_follows_once_attached_and_asks_once() {
        assert_eq!(follow_command(None, "$2", None), None, "not attached yet");
        assert_eq!(
            follow_command(Some("$2"), "$2", None),
            None,
            "already there"
        );
        assert_eq!(
            follow_command(Some("$1"), "$2", None).as_deref(),
            Some("switch-client -E -t '$2'\n")
        );
        assert_eq!(follow_command(Some("$1"), "$2", Some("$2")), None, "asked");
        assert_eq!(
            follow_command(Some("$2"), "$1", Some("$2")).as_deref(),
            Some("switch-client -E -t '$1'\n"),
            "back again"
        );
        assert_eq!(follow_command(Some("$1"), "main", None), None, "not an id");
    }

    #[test]
    fn the_observer_argv_never_starts_a_server_or_touches_the_environment() {
        let argv = observer_argv("/bin/tmux", "/tmp/tmux-501/default", "$4");
        let tail = &argv[argv.iter().position(|arg| arg == "/bin/tmux").unwrap()..];
        assert_eq!(
            tail,
            [
                "/bin/tmux",
                "-S",
                "/tmp/tmux-501/default",
                "-N",
                "-C",
                "attach-session",
                "-E",
                "-f",
                "no-output,ignore-size,no-detach-on-destroy",
                "-t",
                "$4",
            ]
        );
        let untargeted = observer_argv("/bin/tmux", "/tmp/s", "bogus");
        assert!(!untargeted.contains(&"-t".to_string()));
    }

    #[tokio::test]
    async fn long_lines_are_truncated_and_reads_resume_after_cancellation() {
        let input: &[u8] = b"%window-add @1\n%window-renamed @1 abcdefghijklmnop\nshort\ntail";
        let mut lines = BoundedLines::new(input, 24);
        assert_eq!(
            lines.next_line().await.unwrap().as_deref(),
            Some("%window-add @1")
        );
        assert_eq!(
            lines.next_line().await.unwrap().as_deref(),
            Some("%window-renamed @1 abcde")
        );
        assert_eq!(lines.next_line().await.unwrap().as_deref(), Some("short"));
        assert_eq!(lines.next_line().await.unwrap(), None, "unterminated tail");

        // Bytes arrive in pieces; a read cancelled mid-line loses nothing.
        let (mut writer, reader) = tokio::io::duplex(64);
        let mut lines = BoundedLines::new(reader, LINE_LIMIT);
        writer.write_all(b"%sessions-").await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), lines.next_line())
                .await
                .is_err()
        );
        writer.write_all(b"changed\n").await.unwrap();
        assert_eq!(
            lines.next_line().await.unwrap().as_deref(),
            Some("%sessions-changed")
        );
        drop(writer);
        assert_eq!(lines.next_line().await.unwrap(), None);
    }
}
