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
//! would fail such commands with "client is read-only".
//!
//! An attached observer is also the server's command channel. Spawning a
//! tmux client costs a fork and an exec, and an exec can stall for seconds
//! while macOS's exec policy daemon is busy; a line written to the observer
//! runs as fast as a key binding. Only this process writes to the observer:
//! `switch-client` to follow, and the commands [`ControlObservers::run`]
//! routes. Each request is its command line followed by a marker line, and
//! every reply block flagged as answering this client (`%begin … 1`) up to
//! the marker's reply belongs to the request. Hooks reply with flag `0`, so
//! their output never lands in a request's. A request that cannot be written
//! (no attached observer, a full queue) is left to a spawned client; one
//! written but unanswered fails rather than running twice.
//!
//! The observer's stdin is a pipe only this process holds. Closing it — on
//! stop, on shutdown, or by this process dying — makes tmux drop the client;
//! `kill_on_drop` backs that up.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use flash_plugin::{Context, PollPriority};
use regex::Regex;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};
use tokio::process::ChildStdin;
use tokio::sync::{Notify, mpsc, oneshot, watch};
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
/// Requests waiting for an observer's stdin; a full queue spawns instead.
const COMMAND_QUEUE: usize = 64;
/// Requests written and still waiting for their marker.
const MAX_IN_FLIGHT: usize = 64;
/// Output kept from one request, like a spawned client's stdout limit.
const REPLY_LIMIT: usize = 8 * 1024 * 1024;

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
    /// A command written by this process finished with this block.
    pub(crate) block: Option<ControlBlock>,
}

const REFRESH: ControlReaction = ControlReaction {
    refresh: true,
    exit: false,
    block: None,
};
const IGNORE: ControlReaction = ControlReaction {
    refresh: false,
    exit: false,
    block: None,
};

/// One command's reply to a line this process wrote: its output, ended by
/// `%end` (`ok`) or `%error`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ControlBlock {
    pub(crate) ok: bool,
    /// Every output line, newline-terminated as a spawned client prints it.
    pub(crate) output: String,
}

/// An open `%begin` … `%end`/`%error` block.
struct OpenBlock {
    /// `<time> <number>`, which the closing guard repeats, so pane text that
    /// merely starts with `%end` stays output. Empty when the opening guard
    /// was malformed: then any closing guard ends it.
    guard: String,
    /// The output so far of a block answering this client; `None` for the
    /// attach command's and hooks' blocks, whose output nobody reads.
    output: Option<String>,
    overflow: bool,
}

impl OpenBlock {
    fn append(&mut self, line: &str) {
        let Some(output) = &mut self.output else {
            return;
        };
        if self.overflow || output.len() + line.len() + 1 > REPLY_LIMIT {
            self.overflow = true;
            output.clear();
            return;
        }
        output.push_str(line);
        output.push('\n');
    }

    fn close(self, ok: bool) -> Option<ControlBlock> {
        let output = self.output?;
        Some(if self.overflow {
            ControlBlock {
                ok: false,
                output: format!("control reply exceeded {REPLY_LIMIT} bytes\n"),
            }
        } else {
            ControlBlock { ok, output }
        })
    }
}

/// `<time> <number>` and whether flags say this client wrote the command,
/// from the arguments of a `%begin`, `%end` or `%error` line.
fn split_guard(arguments: &str) -> (String, bool) {
    let mut fields = arguments.split(' ');
    match (fields.next(), fields.next(), fields.next()) {
        (Some(time), Some(number), Some(flags)) => (format!("{time} {number}"), flags == "1"),
        _ => (String::new(), false),
    }
}

/// Whether `line` closes a block, and how: `%end` (`true`) or `%error`.
fn closing_guard(line: &str) -> Option<(bool, String)> {
    let (ok, arguments) = if let Some(arguments) = line.strip_prefix("%end") {
        (true, arguments)
    } else {
        (false, line.strip_prefix("%error")?)
    };
    if !arguments.is_empty() && !arguments.starts_with(' ') {
        return None;
    }
    Some((ok, split_guard(arguments.trim_start()).0))
}

/// Reads a control client's stdout line by line.
#[derive(Default)]
pub(crate) struct ControlStream {
    /// Inside a `%begin` … `%end`/`%error` command reply: its lines are
    /// command output, not notifications.
    block: Option<OpenBlock>,
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
        if let Some(open) = &mut self.block {
            if let Some((ok, guard)) = closing_guard(line)
                && (open.guard.is_empty() || guard == open.guard)
            {
                let block = self.block.take().and_then(|open| open.close(ok));
                return ControlReaction { block, ..IGNORE };
            }
            open.append(line);
            return IGNORE;
        }
        let mut words = line.split(' ');
        let name = words.next().unwrap_or_default();
        match name {
            "%begin" => {
                let (guard, answers_this_client) = split_guard(line["%begin".len()..].trim_start());
                self.block = Some(OpenBlock {
                    guard,
                    output: answers_this_client.then(String::new),
                    overflow: false,
                });
                IGNORE
            }
            "%exit" => ControlReaction {
                exit: true,
                ..IGNORE
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
    Some(format!("switch-client -E -t '{wanted}'"))
}

/// One argument as tmux's command parser reads it back verbatim: single
/// quotes, or double quotes with escapes once it holds a control character
/// (a mouse report), which single quotes cannot carry on one line.
fn quote_argument(argument: &str) -> String {
    if !argument
        .chars()
        .any(|character| character.is_ascii_control())
    {
        return format!("'{}'", argument.replace('\'', r"'\''"));
    }
    let mut quoted = String::with_capacity(argument.len() + 2);
    quoted.push('"');
    for character in argument.chars() {
        match character {
            '\\' | '"' | '$' => {
                quoted.push('\\');
                quoted.push(character);
            }
            control if control.is_ascii_control() => {
                quoted.push_str(&format!("\\{:03o}", control as u32));
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

/// The control-mode line running `args`, a spawned client's argv after the
/// global options: a standalone `;` separates commands, every other argument
/// is quoted. `None` when a command would be empty — an empty line detaches
/// a control client.
pub(crate) fn command_line(args: &[&str]) -> Option<String> {
    let mut commands = Vec::new();
    for command in args.split(|argument| *argument == ";") {
        if command.is_empty() {
            return None;
        }
        commands.push(
            command
                .iter()
                .map(|argument| quote_argument(argument))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    Some(commands.join(" ; "))
}

/// What a request's commands printed, shaped like a spawned client's exit:
/// `ok` unless a command failed, `%end` output as stdout and `%error` output
/// as stderr.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ControlReply {
    pub(crate) ok: bool,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
}

impl ControlReply {
    fn failed(detail: impl Into<String>) -> Self {
        Self {
            ok: false,
            stdout: String::new(),
            stderr: detail.into(),
        }
    }
}

/// How a request ended.
#[derive(Debug)]
enum Delivery {
    Replied(ControlReply),
    /// Never written: a spawned client may run it instead.
    Unsent,
    /// Written, but the client left or lost track before its marker came.
    Lost,
}

struct ControlRequest {
    line: String,
    reply: oneshot::Sender<Delivery>,
}

/// One request written to the client and waiting for its marker.
struct InFlight<W> {
    marker: String,
    reply: ControlReply,
    overflow: bool,
    waiter: W,
}

/// Pairs the blocks answering this client with the requests written, in
/// order. A request is its command line and then a marker line; every block
/// before the marker's own reply belongs to it, however many commands the
/// line held.
struct ReplyRouter<W> {
    in_flight: VecDeque<InFlight<W>>,
}

impl<W> Default for ReplyRouter<W> {
    fn default() -> Self {
        Self {
            in_flight: VecDeque::new(),
        }
    }
}

impl<W> ReplyRouter<W> {
    fn push(&mut self, marker: String, waiter: W) {
        self.in_flight.push_back(InFlight {
            marker,
            reply: ControlReply {
                ok: true,
                stdout: String::new(),
                stderr: String::new(),
            },
            overflow: false,
            waiter,
        });
    }

    fn len(&self) -> usize {
        self.in_flight.len()
    }

    /// The requests `block` completes: the one whose marker it is, with its
    /// reply, after any older one whose marker never came (`None`). Other
    /// blocks join the oldest request's reply.
    fn route(&mut self, block: ControlBlock) -> Vec<(W, Option<ControlReply>)> {
        let marker = block
            .ok
            .then(|| block.output.strip_suffix('\n'))
            .flatten()
            .and_then(|output| {
                self.in_flight
                    .iter()
                    .position(|request| request.marker == output)
            });
        if let Some(position) = marker {
            let mut done: Vec<_> = self
                .in_flight
                .drain(..position)
                .map(|lost| (lost.waiter, None))
                .collect();
            if let Some(request) = self.in_flight.pop_front() {
                done.push((request.waiter, Some(request.reply)));
            }
            return done;
        }
        if let Some(request) = self.in_flight.front_mut() {
            let reply = &mut request.reply;
            if request.overflow {
                return Vec::new();
            }
            if reply.stdout.len() + reply.stderr.len() + block.output.len() > REPLY_LIMIT {
                request.overflow = true;
                *reply =
                    ControlReply::failed(format!("control reply exceeded {REPLY_LIMIT} bytes\n"));
            } else if block.ok {
                reply.stdout.push_str(&block.output);
            } else {
                reply.ok = false;
                reply.stderr.push_str(&block.output);
            }
        }
        Vec::new()
    }

    fn drain(&mut self) -> impl Iterator<Item = W> + '_ {
        self.in_flight.drain(..).map(|request| request.waiter)
    }
}

/// Writes requests to one attached client in order.
struct RequestWriter {
    stdin: ChildStdin,
    router: ReplyRouter<Option<oneshot::Sender<Delivery>>>,
    sequence: u64,
}

impl RequestWriter {
    /// Write `line` and its marker; `waiter` hears how it ended.
    async fn write(
        &mut self,
        line: &str,
        waiter: Option<oneshot::Sender<Delivery>>,
    ) -> std::io::Result<()> {
        self.sequence += 1;
        let marker = format!("flash-tmux-reply-{}-{}", std::process::id(), self.sequence);
        let request = format!("{line}\ndisplay-message -p '{marker}'\n");
        self.router.push(marker, waiter);
        self.stdin.write_all(request.as_bytes()).await
    }

    fn route(&mut self, block: ControlBlock) {
        for (waiter, reply) in self.router.route(block) {
            if let Some(waiter) = waiter {
                let _ = waiter.send(reply.map_or(Delivery::Lost, Delivery::Replied));
            }
        }
    }
}

/// How requests reach an attached observer.
#[derive(Clone)]
pub(crate) struct CommandChannel {
    sender: mpsc::Sender<ControlRequest>,
    /// Abandons the attachment: a request went unanswered.
    reset: Arc<Notify>,
}

/// The attached observer's channel, or `None` while it is attaching,
/// reattaching or gone.
pub(crate) type ChannelSlot = Arc<Mutex<Option<CommandChannel>>>;

fn publish(slot: &ChannelSlot, channel: Option<CommandChannel>) {
    *slot.lock().unwrap_or_else(|e| e.into_inner()) = channel;
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
    channel: ChannelSlot,
}

impl ControlObservers {
    /// Run `args` (a spawned client's argv after its global options) on the
    /// server at `socket` through its attached observer. `None` when no
    /// observer could take it — none attached, a full queue, or arguments a
    /// line cannot carry — and a spawned client should run it instead. A
    /// written request that times out fails, and its observer reattaches.
    pub(crate) async fn run(
        &self,
        socket: &str,
        args: &[&str],
        timeout: Duration,
    ) -> Option<ControlReply> {
        let line = command_line(args)?;
        let channel = {
            let running = self.running.lock().unwrap_or_else(|e| e.into_inner());
            let slot = running.get(socket)?.channel.lock();
            slot.unwrap_or_else(|e| e.into_inner()).clone()?
        };
        let (reply, delivery) = oneshot::channel();
        channel
            .sender
            .try_send(ControlRequest { line, reply })
            .ok()?;
        match tokio::time::timeout(timeout, delivery).await {
            Ok(Ok(Delivery::Replied(reply))) => Some(reply),
            Ok(Ok(Delivery::Unsent)) => None,
            Ok(Ok(Delivery::Lost) | Err(_)) => Some(ControlReply::failed(
                "tmux control client left before replying",
            )),
            Err(_) => {
                channel.reset.notify_one();
                Some(ControlReply::failed(format!(
                    "tmux control reply timed out timeout_ms={}",
                    timeout.as_millis()
                )))
            }
        }
    }

    /// The sockets whose observer currently takes commands.
    pub(crate) fn attached_sockets(&self) -> Vec<String> {
        self.running
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|(_, observer)| {
                observer
                    .channel
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .is_some()
            })
            .map(|(socket, _)| socket.clone())
            .collect()
    }

    /// Converge on `plan` — socket path to the session id to follow:
    /// observers start for new servers (`start` spawns one, publishing its
    /// command channel in the slot while attached), follow the planned
    /// session on the others, and stop for servers the plan no longer names.
    /// True when the set of followed servers changed.
    pub(crate) fn reconcile<F>(&self, plan: &BTreeMap<String, String>, mut start: F) -> bool
    where
        F: FnMut(&str, watch::Receiver<String>, ChannelSlot) -> JoinHandle<()>,
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
            let channel = ChannelSlot::default();
            let task = start(socket, receiver, Arc::clone(&channel));
            running.insert(
                socket.clone(),
                Observer {
                    follow,
                    task,
                    channel,
                },
            );
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

/// Keep one observer attached to `socket` until `follow` closes, publishing
/// its command channel in `channel` while attached. `changed` runs for every
/// notification that can change the inventory and whenever the client
/// leaves on its own.
pub(crate) async fn observe(
    ctx: Context,
    tmux_path: String,
    socket: String,
    mut follow: watch::Receiver<String>,
    channel: ChannelSlot,
    changed: Arc<dyn Fn() + Send + Sync>,
) {
    let mut failures = 0usize;
    loop {
        if follow.has_changed().is_err() {
            return;
        }
        let started = Instant::now();
        let attachment = attach(&tmux_path, &socket, &mut follow, &channel, changed.as_ref()).await;
        let status = match attachment {
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
    slot: &ChannelSlot,
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
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Attachment::Ended(None);
    };
    let mut lines = BoundedLines::new(stdout, LINE_LIMIT);
    let mut stream = ControlStream::default();
    let mut writer = RequestWriter {
        stdin,
        router: ReplyRouter::default(),
        sequence: 0,
    };
    let (sender, mut requests) = mpsc::channel::<ControlRequest>(COMMAND_QUEUE);
    let reset = Arc::new(Notify::new());
    let mut published = false;
    let mut requested: Option<String> = None;
    let stopped = loop {
        tokio::select! {
            line = lines.next_line() => {
                let Ok(Some(line)) = line else { break false };
                let reaction = stream.feed(&line);
                if let Some(block) = reaction.block {
                    writer.route(block);
                }
                if reaction.refresh {
                    changed();
                }
                if reaction.exit {
                    break false;
                }
                // Attached: the server takes commands from this client now.
                if !published && stream.session_id().is_some() {
                    publish(
                        slot,
                        Some(CommandChannel {
                            sender: sender.clone(),
                            reset: Arc::clone(&reset),
                        }),
                    );
                    published = true;
                }
            }
            request = requests.recv(), if writer.router.len() < MAX_IN_FLIGHT => {
                let Some(request) = request else { break false };
                if writer.write(&request.line, Some(request.reply)).await.is_err() {
                    break false;
                }
            }
            () = reset.notified() => break false,
            closed = follow.changed() => if closed.is_err() { break true; },
        }
        let wanted = follow.borrow().clone();
        if let Some(command) = follow_command(stream.session_id(), &wanted, requested.as_deref()) {
            requested = Some(wanted);
            if writer.write(&command, None).await.is_err() {
                break false;
            }
        }
    };
    // New requests spawn their own client from here on; queued ones may
    // too, since they never reached this one. Written ones are lost.
    publish(slot, None);
    drop(sender);
    requests.close();
    while let Ok(request) = requests.try_recv() {
        let _ = request.reply.send(Delivery::Unsent);
    }
    for waiter in writer.router.drain().flatten() {
        let _ = waiter.send(Delivery::Lost);
    }
    // End of input detaches the client.
    drop(writer);
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

    fn block(ok: bool, output: &str) -> ControlReaction {
        ControlReaction {
            block: Some(ControlBlock {
                ok,
                output: output.to_string(),
            }),
            ..IGNORE
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
                block(true, "%window-add @1\n%exit\n"),
                REFRESH,
                IGNORE,
                IGNORE,
                block(false, "can't find session: $9\n"),
                ControlReaction {
                    exit: true,
                    ..IGNORE
                },
            ]
        );
    }

    #[test]
    fn only_replies_to_this_client_carry_output() {
        let mut stream = ControlStream::default();
        let reactions = feed_all(
            &mut stream,
            &[
                // The attach command's own reply and a hook's.
                "%begin 1790803054 289 0",
                "%end 1790803054 289 0",
                "%begin 1790803054 298 0",
                "hooked-after-select",
                "%end 1790803054 298 0",
                "%begin 1790803054 299 1",
                "",
                "%end 1790803054 299 1",
            ],
        );
        assert_eq!(
            reactions,
            [
                IGNORE,
                IGNORE,
                IGNORE,
                IGNORE,
                IGNORE,
                IGNORE,
                IGNORE,
                block(true, "\n")
            ]
        );
    }

    #[test]
    fn pane_text_that_looks_like_a_guard_stays_output() {
        let mut stream = ControlStream::default();
        let reactions = feed_all(
            &mut stream,
            &[
                "%begin 1790803054 300 1",
                "%end 1790803054 12 1",
                "%error",
                "%endless",
                "%end 1790803054 300 1",
            ],
        );
        assert_eq!(
            reactions.last(),
            Some(&block(true, "%end 1790803054 12 1\n%error\n%endless\n"))
        );
        // A malformed opening guard still ends at the next closing one.
        assert_eq!(stream.feed("%begin"), IGNORE);
        assert_eq!(stream.feed("%window-add @1"), IGNORE);
        assert_eq!(stream.feed("%end 1790803054 301 1"), IGNORE);
        assert_eq!(stream.feed("%window-add @1"), REFRESH);
    }

    #[test]
    fn oversized_replies_fail_without_keeping_their_output() {
        let mut stream = ControlStream::default();
        stream.feed("%begin 1 2 1");
        let line = "x".repeat(LINE_LIMIT);
        for _ in 0..=REPLY_LIMIT / LINE_LIMIT {
            stream.feed(&line);
        }
        let reaction = stream.feed("%end 1 2 1");
        let reply = reaction.block.expect("a reply");
        assert!(!reply.ok);
        assert!(reply.output.starts_with("control reply exceeded"));
    }

    #[test]
    fn command_lines_quote_every_argument_and_keep_separators() {
        assert_eq!(
            command_line(&[
                "display-message",
                "-c",
                "/dev/ttys001",
                "-p",
                "#{session_name}"
            ])
            .as_deref(),
            Some("'display-message' '-c' '/dev/ttys001' '-p' '#{session_name}'")
        );
        assert_eq!(
            command_line(&["list-clients", "-F", "a|||b", ";", "list-windows", "-a"]).as_deref(),
            Some("'list-clients' '-F' 'a|||b' ; 'list-windows' '-a'")
        );
        assert_eq!(
            command_line(&["new-window", "-c", "/Users/me/it's here; ok"]).as_deref(),
            Some(r"'new-window' '-c' '/Users/me/it'\''s here; ok'")
        );
        assert_eq!(
            command_line(&["send-keys", "-l", "\u{1b}[<64;1;1M\n\"$x\\"]).as_deref(),
            Some(r#"'send-keys' '-l' "\033[<64;1;1M\012\"\$x\\""#)
        );
        let empties: [&[&str]; 4] = [&[], &[";"], &["list-clients", ";"], &[";", "list-clients"]];
        for empty in empties {
            assert_eq!(command_line(empty), None, "{empty:?}");
        }
    }

    /// A control client answering like tmux: the attach reply, then one
    /// block per line with flag `1`, a hook block with flag `0` after
    /// `list-windows`, an error for `kill-window`, and no answer once
    /// `stall` arrives.
    const FAKE_CONTROL_CLIENT: &str = r#"#!/bin/sh
printf '%%begin 1 1 0\n%%end 1 1 0\n%%session-changed $0 main\n'
n=1
while IFS= read -r line; do
  n=$((n + 1))
  case "$line" in
    "display-message -p '"*)
      marker=${line#"display-message -p '"}
      marker=${marker%"'"}
      printf '%%begin 1 %s 1\n%s\n%%end 1 %s 1\n' "$n" "$marker" "$n" ;;
    "'list-windows'"*)
      printf '%%begin 1 %s 1\n0 @1\n1 @2\n%%end 1 %s 1\n' "$n" "$n"
      printf '%%begin 1 9%s 0\nhook output\n%%end 1 9%s 0\n%%window-add @3\n' "$n" "$n" ;;
    "'kill-window'"*)
      printf "%%begin 1 %s 1\ncan't find window: 9\n%%error 1 %s 1\n" "$n" "$n" ;;
    "'stall'"*)
      exec sleep 30 ;;
    *)
      printf '%%begin 1 %s 1\n%%end 1 %s 1\n' "$n" "$n" ;;
  esac
done
"#;

    #[tokio::test]
    async fn requests_ride_the_attached_client_until_one_goes_unanswered() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!(
            "flash-tmux-control-{}-{:?}",
            std::process::id(),
            Instant::now()
        ));
        tokio::fs::create_dir_all(&directory).await.unwrap();
        let fake = directory.join("tmux");
        tokio::fs::write(&fake, FAKE_CONTROL_CLIENT).await.unwrap();
        tokio::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755))
            .await
            .unwrap();
        let fake = fake.to_string_lossy().into_owned();

        let observers = ControlObservers::default();
        let socket = "/tmp/flash-tmux-fake/default";
        let timeout = Duration::from_secs(5);
        assert_eq!(
            observers.run(socket, &["list-clients"], timeout).await,
            None,
            "nothing attached: a spawned client runs it"
        );

        let notified = Arc::new(Notify::new());
        let plan = BTreeMap::from([(socket.to_string(), "$0".to_string())]);
        observers.reconcile(&plan, |socket, mut follow, slot| {
            let fake = fake.clone();
            let socket = socket.to_string();
            let notified = Arc::clone(&notified);
            tokio::spawn(async move {
                let changed = move || notified.notify_one();
                attach(&fake, &socket, &mut follow, &slot, &changed).await;
            })
        });
        tokio::time::timeout(timeout, notified.notified())
            .await
            .expect("attached");
        assert_eq!(observers.attached_sockets(), [socket]);

        let windows = observers
            .run(
                socket,
                &[
                    "list-windows",
                    "-t",
                    "main:",
                    "-F",
                    "#{window_index} #{window_id}",
                ],
                timeout,
            )
            .await;
        assert_eq!(
            windows,
            Some(ControlReply {
                ok: true,
                stdout: "0 @1\n1 @2\n".to_string(),
                stderr: String::new(),
            }),
            "the hook's output stays out"
        );
        let (moved, failed) = tokio::join!(
            observers.run(socket, &["next-window", "-t", "main:"], timeout),
            observers.run(socket, &["kill-window", "-t", "main:9"], timeout),
        );
        assert_eq!(moved.map(|reply| reply.ok), Some(true));
        assert_eq!(
            failed,
            Some(ControlReply {
                ok: false,
                stdout: String::new(),
                stderr: "can't find window: 9\n".to_string(),
            })
        );

        let stalled = observers
            .run(socket, &["stall"], Duration::from_millis(200))
            .await
            .expect("written");
        assert!(!stalled.ok);
        assert!(stalled.stderr.contains("timed out"), "{}", stalled.stderr);
        for _ in 0..100 {
            if observers.attached_sockets().is_empty() {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(
            observers.attached_sockets().is_empty(),
            "an unanswered request abandons the client"
        );
        assert_eq!(
            observers.run(socket, &["list-clients"], timeout).await,
            None
        );

        observers.shutdown().await;
        tokio::fs::remove_dir_all(directory).await.unwrap();
    }

    #[test]
    fn replies_belong_to_the_request_whose_marker_follows_them() {
        let mut router = ReplyRouter::default();
        router.push("m1".to_string(), 1);
        router.push("m2".to_string(), 2);
        let output = |ok: bool, text: &str| ControlBlock {
            ok,
            output: text.to_string(),
        };
        assert!(router.route(output(true, "client\n")).is_empty());
        assert!(router.route(output(true, "window\n")).is_empty());
        assert_eq!(
            router.route(output(true, "m1\n")),
            [(
                1,
                Some(ControlReply {
                    ok: true,
                    stdout: "client\nwindow\n".to_string(),
                    stderr: String::new(),
                })
            )]
        );
        assert!(
            router
                .route(output(false, "can't find window: 9\n"))
                .is_empty()
        );
        assert_eq!(
            router.route(output(true, "m2\n")),
            [(
                2,
                Some(ControlReply {
                    ok: false,
                    stdout: String::new(),
                    stderr: "can't find window: 9\n".to_string(),
                })
            )]
        );
        assert_eq!(router.len(), 0);
    }

    #[test]
    fn a_marker_overtaking_an_older_one_loses_the_older_request() {
        let mut router = ReplyRouter::default();
        router.push("m1".to_string(), 1);
        router.push("m2".to_string(), 2);
        router.push("m3".to_string(), 3);
        let done = router.route(ControlBlock {
            ok: true,
            output: "m2\n".to_string(),
        });
        assert_eq!(done.len(), 2);
        assert_eq!(done[0], (1, None));
        assert_eq!(done[1].0, 2);
        // A failed command printing a marker is not that marker.
        assert!(
            router
                .route(ControlBlock {
                    ok: false,
                    output: "m3\n".to_string(),
                })
                .is_empty()
        );
        assert_eq!(router.drain().collect::<Vec<_>>(), [3]);
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
            Some("switch-client -E -t '$2'")
        );
        assert_eq!(follow_command(Some("$1"), "$2", Some("$2")), None, "asked");
        assert_eq!(
            follow_command(Some("$2"), "$1", Some("$2")).as_deref(),
            Some("switch-client -E -t '$1'"),
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
