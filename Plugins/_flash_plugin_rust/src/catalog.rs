//! A flashlight catalog of an Apple app's items, listed by the host behind a
//! grant Flash holds ([`AppItems`]): the consent rules and the relist
//! schedule the `notes`, `reminders` and `contacts` plugins share.
//!
//! The catalog keeps its last good rows in memory and answers a `search`
//! from them. It lists only while its app runs, and relists when that app
//! launches, when focus leaves it (the user may have just edited it), when
//! the flashlight opens (then only if the app is focused or the listing is a
//! minute old), and on its `refresh` command. Nothing polls. An event relists
//! what Flash may already read; only the user's own use of the catalog — a
//! query scoped to its source, or the `refresh` command — may have the host
//! show macOS's prompt, which the host refuses anywhere else.
//!
//! The source is live: the host shows what the last `search` answered. Rows
//! that change afterwards — a listing that lands after the reply, the one
//! that follows the user's answer to macOS's prompt, an app that quit — are
//! announced with [`Context::source_changed`], and the host pulls again if
//! the flashlight still shows them. Rows a waiting `search` is about to
//! answer with are that reply, and are not announced.
//!
//! A plugin declares one live `per_scope` source, listens to
//! `core:apps.launched`, `core:apps.terminated`, `core:focus.changed` and
//! `core:session.opened`, and hands its handlers to one [`ItemCatalog`]:
//! such a manifest keeps no process until the first query or command
//! (`protocol.json` `source_live`), and the host's snapshot of running apps,
//! sent to every new child, says whether the app runs then.

use std::collections::{BTreeMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::Poll;
use std::time::Duration;

use tokio::sync::{Notify, oneshot};

use crate::context::Context;
use crate::grant::GrantAccess;
use crate::items::{AppItem, AppItemListing, AppItems};
use crate::types::{
    Candidate, CommandRequest, Event, PerformResponse, SearchRequest, SearchResponse, host_events,
};

/// How long a search waits for the snapshot of running apps the host sends
/// a new child before anything else.
const SEED_WAIT: Duration = Duration::from_millis(300);
/// How long a search with nothing to show waits for a listing in flight:
/// inside the 1 s `search` deadline, with room for the reply's rows.
const SEARCH_WAIT: Duration = Duration::from_millis(700);
/// How long a search waits for one when it has rows to show: long enough
/// for a listing that is about to land, short enough that a slow app (a
/// Notes script takes seconds) does not hold back the last good rows.
const LOADED_SEARCH_WAIT: Duration = Duration::from_millis(200);
/// How long the `refresh` command waits for its listing: inside the
/// `perform` deadline.
const REFRESH_WAIT: Duration = Duration::from_secs(8);
/// How long an open macOS prompt is waited on. A later answer is read by
/// the next query.
const ASK_TIMEOUT: Duration = Duration::from_secs(600);
/// A listing this slow is logged as a warning.
const SLOW_REFRESH_MS: u64 = 1_000;

/// Why a catalog is being relisted. Events relist what Flash may already
/// read; only the user's own use of the catalog may ask macOS for access.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CatalogRequest {
    /// List again when access is granted.
    pub relist: bool,
    /// Ask macOS for access when Flash never asked.
    pub may_ask: bool,
}

impl CatalogRequest {
    /// The app launching, focus leaving it, a flashlight open.
    pub const EVENT: Self = Self {
        relist: true,
        may_ask: false,
    };
    /// A flashlight query scoped to the catalog: the user is using it.
    pub const QUERY: Self = Self {
        relist: false,
        may_ask: true,
    };
    /// The `refresh` command.
    pub const COMMAND: Self = Self {
        relist: true,
        may_ask: true,
    };

    /// Requests queued together run once, as their union.
    pub fn merged(self, other: Self) -> Self {
        Self {
            relist: self.relist || other.relist,
            may_ask: self.may_ask || other.may_ask,
        }
    }
}

/// What one request does to its catalog.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CatalogStep {
    List,
    /// Have the host show macOS's prompt, then list on a grant.
    Ask,
    /// The app is not running, or access is refused: the catalog is empty.
    Clear,
    /// Leave the rows as they are.
    Keep,
}

impl CatalogStep {
    pub fn of(request: CatalogRequest, running: bool, access: GrantAccess) -> Self {
        if !running {
            return Self::Clear;
        }
        match access {
            GrantAccess::Granted if request.relist => Self::List,
            GrantAccess::Granted => Self::Keep,
            GrantAccess::Undetermined if request.may_ask => Self::Ask,
            GrantAccess::Undetermined => Self::Keep,
            GrantAccess::Denied => Self::Clear,
        }
    }
}

/// When a catalog relists, besides its app launching and its `refresh`
/// command: when focus leaves its app, and when the flashlight opens — then
/// only if its app is focused or its listing began at least
/// [`SESSION_TTL_MS`](Self::SESSION_TTL_MS) ago, which bounds how stale a
/// change synced in the background can be.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CatalogSchedule {
    focused: Option<String>,
    listed_at_ms: Option<u64>,
}

impl CatalogSchedule {
    pub const SESSION_TTL_MS: u64 = 60_000;

    /// Record focus moving to `bundle_id`. True when it left `app`.
    pub fn focus(&mut self, bundle_id: Option<&str>, app: &str) -> bool {
        let previous = std::mem::replace(&mut self.focused, bundle_id.map(str::to_string));
        previous != self.focused && previous.as_deref() == Some(app)
    }

    /// Whether a flashlight open relists a catalog whose app is `app`: it
    /// runs, and it is focused, was never listed or was listed at least
    /// `SESSION_TTL_MS` before `now_ms`. A catalog that is due is marked as
    /// listed at `now_ms`, so a reopen does not queue it again.
    pub fn claim_on_open(&mut self, running: bool, app: &str, now_ms: u64) -> bool {
        let due = running
            && (self.focused.as_deref() == Some(app)
                || self.listed_at_ms.is_none_or(|listed_at| {
                    now_ms.saturating_sub(listed_at) >= Self::SESSION_TTL_MS
                }));
        if due {
            self.mark(now_ms);
        }
        due
    }

    pub fn mark(&mut self, now_ms: u64) {
        self.listed_at_ms = Some(now_ms);
    }
}

/// What one relist did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CatalogOutcome {
    Listed(usize),
    /// The app is not running: the catalog is empty.
    Cleared,
    /// Access is refused: the catalog is empty.
    Denied,
    /// Nothing to do yet: access was never asked and this request may not
    /// ask, or macOS cannot be asked now.
    Kept,
    /// The listing failed; the last good rows stay.
    Failed(String),
}

/// One row a plugin makes of an item, from the app's own words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CatalogRow {
    /// Selects the item in its app again.
    pub id: String,
    pub title: String,
    pub subtitle: String,
}

/// What a plugin says of its catalog.
#[derive(Clone, Copy)]
pub struct ItemCatalogSpec {
    /// The app whose items the host lists.
    pub app: AppItems,
    /// That app's bundle id: the catalog lists only while it runs, and
    /// `open` launches it.
    pub bundle_id: &'static str,
    /// The manifest `sources[].name` the rows carry.
    pub source: &'static str,
    /// The row kind the flashlight shows (`note`).
    pub kind: &'static str,
    /// The rows of a listing, in the order the flashlight shows them.
    pub rows: fn(Vec<AppItem>) -> Vec<CatalogRow>,
}

impl ItemCatalogSpec {
    /// The flashlight rows of a listing, in the plugin's order: an entry
    /// without an id or a title is dropped, and an id listed twice keeps
    /// its first row. A row carries its item's id as its payload.
    pub fn candidates(&self, items: Vec<AppItem>) -> Vec<Candidate> {
        let mut ids = HashSet::new();
        (self.rows)(items)
            .into_iter()
            .filter(|row| !row.id.is_empty() && !row.title.is_empty())
            .filter(|row| ids.insert(row.id.clone()))
            .map(|row| {
                Candidate::new(self.source, row.title)
                    .kind(self.kind)
                    .subtitle(row.subtitle)
                    .payload(row.id)
            })
            .collect()
    }
}

type Waiter = oneshot::Sender<CatalogOutcome>;

#[derive(Default)]
struct State {
    /// The host's snapshot of running apps arrived.
    seeded: bool,
    running: bool,
    /// The last good rows.
    rows: Arc<Vec<Candidate>>,
    /// A listing landed since the app launched or access changed.
    loaded: bool,
    /// Bumped when the app terminates: a listing begun before that is stale.
    generation: u64,
    schedule: CatalogSchedule,
    pending: Option<CatalogRequest>,
    waiters: Vec<Waiter>,
    /// The one task that runs the queued requests is alive.
    draining: bool,
    /// The requests waiting on macOS's open prompt.
    asking: Option<Vec<Waiter>>,
    /// The last access macOS reported, so a query need not ask again.
    known_access: Option<GrantAccess>,
    /// The searches that have not read their rows yet.
    searching: usize,
    /// The rows changed while a search waited, and the host was not told:
    /// that search's reply carries them.
    unannounced: bool,
    /// The rows changed and the host is told once the lock is released
    /// ([`Inner::announce`]).
    pending_announce: bool,
}

impl State {
    /// Replace the rows. True when the host must be told: they differ from
    /// the ones it may be showing, and no waiting search will answer with
    /// them.
    fn replace_rows(&mut self, rows: Vec<Candidate>) -> bool {
        if *self.rows == rows {
            return false;
        }
        self.rows = Arc::new(rows);
        if self.searching > 0 {
            self.unannounced = true;
            return false;
        }
        true
    }
}

/// One search between its arrival and its reading the rows it answers with.
/// Dropped before that — the SDK stops a handler at its deadline — it
/// announces the change it would have answered.
struct Searching<'a> {
    inner: &'a Inner,
    ctx: &'a Context,
    answered: bool,
}

impl<'a> Searching<'a> {
    fn begin(inner: &'a Inner, ctx: &'a Context) -> Self {
        inner.lock().searching += 1;
        Self {
            inner,
            ctx,
            answered: false,
        }
    }

    /// The rows this search answers with: the host has them from here on.
    fn rows(mut self) -> Vec<Candidate> {
        self.answered = true;
        let mut state = self.inner.lock();
        state.searching -= 1;
        if state.searching == 0 {
            state.unannounced = false;
        }
        state.rows.as_ref().clone()
    }
}

impl Drop for Searching<'_> {
    fn drop(&mut self) {
        if self.answered {
            return;
        }
        let announce = {
            let mut state = self.inner.lock();
            state.searching -= 1;
            state.searching == 0 && std::mem::take(&mut state.unannounced)
        };
        if announce {
            self.ctx.source_changed(self.inner.spec.source);
        }
    }
}

struct Inner {
    spec: ItemCatalogSpec,
    now_ms: Box<dyn Fn() -> u64 + Send + Sync>,
    state: Mutex<State>,
    /// Woken when the snapshot seeds `running` and when queued work is done.
    changed: Notify,
}

/// One plugin's catalog: its last good rows, its running-app gate and when
/// it relists. Handlers only record state and queue work; every host call
/// runs on one task, so requests queued while one runs merge into one more
/// run and no event handler ever waits on the app.
#[derive(Clone)]
pub struct ItemCatalog {
    inner: Arc<Inner>,
}

/// Milliseconds on a clock that keeps running while the Mac sleeps, so a
/// listing made before a night's sleep is stale after it.
fn continuous_ms() -> u64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `clock_gettime` writes only into the caller-owned `time`.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut time) };
    (time.tv_sec as u64) * 1_000 + (time.tv_nsec as u64) / 1_000_000
}

fn deliver(waiters: Vec<Waiter>, outcome: &CatalogOutcome) {
    for waiter in waiters {
        // A waiter that stopped waiting is no failure.
        let _ = waiter.send(outcome.clone());
    }
}

impl ItemCatalog {
    pub fn new(spec: ItemCatalogSpec) -> Self {
        Self::with_clock(spec, continuous_ms)
    }

    /// A catalog on `now_ms`, a millisecond clock: tests pass their own.
    pub fn with_clock(
        spec: ItemCatalogSpec,
        now_ms: impl Fn() -> u64 + Send + Sync + 'static,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                spec,
                now_ms: Box::new(now_ms),
                state: Mutex::new(State::default()),
                changed: Notify::new(),
            }),
        }
    }

    /// The last good rows.
    pub fn rows(&self) -> Vec<Candidate> {
        self.inner.lock().rows.as_ref().clone()
    }

    /// The host's events: the snapshot of running apps every new child
    /// gets (`core:apps.changed`), `core:apps.launched`,
    /// `core:apps.terminated`, `core:focus.changed` and
    /// `core:session.opened`. Records the event and queues the relist it
    /// calls for; never waits.
    pub fn on_event(&self, ctx: &Context, event: &Event) {
        let inner = &self.inner;
        let app = inner.spec.bundle_id;
        let ours = event.bundle_id.as_deref() == Some(app);
        match event.name.as_str() {
            host_events::APPS_CHANGED => {
                let running = ctx
                    .running_applications()
                    .iter()
                    .any(|application| application.bundle_id == app);
                let seeded = std::mem::replace(&mut inner.lock().seeded, true);
                let launched = inner.set_running(running);
                inner.announce(ctx);
                inner.changed.notify_waiters();
                if launched {
                    // A failed first listing is retried once.
                    inner.relist(ctx, !seeded);
                }
            }
            host_events::APPS_LAUNCHED if ours => {
                if inner.set_running(true) {
                    inner.relist(ctx, false);
                }
            }
            host_events::APPS_TERMINATED if ours => {
                inner.set_running(false);
                inner.announce(ctx);
            }
            host_events::FOCUS_CHANGED => {
                let left = {
                    let mut state = inner.lock();
                    state.schedule.focus(event.bundle_id.as_deref(), app) && state.running
                };
                if left {
                    inner.relist(ctx, false);
                }
            }
            host_events::SESSION_OPENED => {
                let now_ms = (inner.now_ms)();
                let due = {
                    let mut state = inner.lock();
                    let running = state.running;
                    state.schedule.claim_on_open(running, app, now_ms)
                };
                if due {
                    inner.request(ctx, CatalogRequest::EVENT, Vec::new());
                }
            }
            _ => {}
        }
    }

    /// The rows of the catalog's source: the last good ones, after a
    /// listing in flight when it lands within `LOADED_SEARCH_WAIT`, or
    /// within `SEARCH_WAIT` when there is nothing to show yet. A query
    /// names the catalog, so this is where macOS is first asked for
    /// access; once macOS answered and the rows are loaded, a query costs
    /// nothing.
    pub async fn search(&self, ctx: &Context, request: &SearchRequest) -> SearchResponse {
        let inner = &self.inner;
        if request.source != inner.spec.source {
            return SearchResponse::default();
        }
        let started = tokio::time::Instant::now();
        let searching = Searching::begin(inner, ctx);
        inner.wait_until(SEED_WAIT, |state| state.seeded).await;
        let wait = if inner.lock().loaded {
            LOADED_SEARCH_WAIT
        } else {
            SEARCH_WAIT
        };
        let deadline = started + wait;
        // A listing in flight says what macOS grants: it lands first.
        inner.wait_until_idle(deadline).await;
        let ask = {
            let state = inner.lock();
            if !state.running {
                drop(state);
                return SearchResponse::rows(searching.rows());
            }
            let settled = state.draining
                || state.asking.is_some()
                || state.known_access == Some(GrantAccess::Denied)
                || (state.known_access == Some(GrantAccess::Granted) && state.loaded);
            // A query never relists what is loaded; with nothing loaded it
            // lists as an event would.
            (!settled).then(|| {
                if state.loaded {
                    CatalogRequest::QUERY
                } else {
                    CatalogRequest::QUERY.merged(CatalogRequest::EVENT)
                }
            })
        };
        if let Some(request) = ask {
            inner.request(ctx, request, Vec::new());
            inner.wait_until_idle(deadline).await;
        }
        SearchResponse::rows(searching.rows())
    }

    /// Bring the app forward on the item a row names.
    pub async fn resolve(&self, ctx: &Context, row: &Candidate) -> PerformResponse {
        let Some(id) = row.payload_str().filter(|id| !id.is_empty()) else {
            return PerformResponse::fail("row carries no item");
        };
        match ctx.show_app_item(self.inner.spec.app, id).await {
            Ok(()) => PerformResponse::ok(),
            // The host logged why; the reason may name the item.
            Err(_) => PerformResponse::fail("the item could not be shown"),
        }
    }

    /// Relist now, asking macOS for access first when Flash never asked.
    /// `None`: the listing, or macOS's prompt, is still going.
    pub async fn refresh(&self, ctx: &Context) -> Option<CatalogOutcome> {
        let inner = &self.inner;
        inner.wait_until(SEED_WAIT, |state| state.seeded).await;
        let now_ms = (inner.now_ms)();
        inner.lock().schedule.mark(now_ms);
        let (waiter, outcome) = oneshot::channel();
        inner.request(ctx, CatalogRequest::COMMAND, vec![waiter]);
        tokio::time::timeout(REFRESH_WAIT, outcome).await.ok()?.ok()
    }

    /// The plugin's `open` and `refresh` commands. Their manifest entries
    /// declare no argument, so the host hands them none.
    pub async fn command(&self, ctx: &Context, command: &CommandRequest) -> PerformResponse {
        let name = command.name();
        match command.subcommand.as_str() {
            "open" => {
                if ctx.open_app(self.inner.spec.bundle_id).await {
                    PerformResponse::ok()
                } else {
                    PerformResponse::fail(format!("{name} failed"))
                }
            }
            "refresh" => match self.refresh(ctx).await {
                Some(CatalogOutcome::Listed(_) | CatalogOutcome::Cleared) => {
                    PerformResponse::ok().message(format!("{} refreshed", command.command))
                }
                // A refused or unanswered access request leaves the catalog
                // empty, without a message.
                Some(CatalogOutcome::Denied | CatalogOutcome::Kept) => PerformResponse::ok(),
                Some(CatalogOutcome::Failed(_)) => PerformResponse::fail(format!("{name} failed")),
                None => PerformResponse::ok().message(format!("{name} is still running")),
            },
            _ => PerformResponse::fail(format!("unknown command: {name}")),
        }
    }
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Record whether the app runs. True when it just launched.
    fn set_running(&self, running: bool) -> bool {
        let mut state = self.lock();
        let was_running = std::mem::replace(&mut state.running, running);
        if was_running && !running {
            // Termination is authoritative: the rows go at once, and a
            // listing begun before it is dropped when it lands.
            state.generation += 1;
            state.pending_announce |= state.replace_rows(Vec::new());
            state.loaded = false;
            state.known_access = None;
        }
        running && !was_running
    }

    /// Tell the host about rows that changed under the lock, once it is
    /// released.
    fn announce(&self, ctx: &Context) {
        if std::mem::take(&mut self.lock().pending_announce) {
            ctx.source_changed(self.spec.source);
        }
    }

    /// Relist for an event, marked as listed now. `retry`: list once more
    /// when this listing fails.
    fn relist(self: &Arc<Self>, ctx: &Context, retry: bool) {
        let now_ms = (self.now_ms)();
        self.lock().schedule.mark(now_ms);
        if !retry {
            self.request(ctx, CatalogRequest::EVENT, Vec::new());
            return;
        }
        let (waiter, outcome) = oneshot::channel();
        self.request(ctx, CatalogRequest::EVENT, vec![waiter]);
        let (inner, ctx) = (self.clone(), ctx.clone());
        tokio::spawn(async move {
            if let Ok(CatalogOutcome::Failed(_)) = outcome.await {
                inner.request(&ctx, CatalogRequest::EVENT, Vec::new());
            }
        });
    }

    /// Wait until `ready` holds, at most `limit`.
    async fn wait_until(&self, limit: Duration, ready: impl Fn(&State) -> bool) {
        let _ = tokio::time::timeout(limit, async {
            loop {
                let changed = self.changed.notified();
                tokio::pin!(changed);
                // Registered before the check, so a change between the two
                // is not missed.
                changed.as_mut().enable();
                if ready(&self.lock()) {
                    return;
                }
                changed.await;
            }
        })
        .await;
    }

    /// Wait until no queued request is running, at most until `deadline`.
    async fn wait_until_idle(&self, deadline: tokio::time::Instant) {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        self.wait_until(left, |state| !state.draining).await;
    }

    /// Queue `request`, or merge it into the one already queued.
    fn request(self: &Arc<Self>, ctx: &Context, request: CatalogRequest, waiters: Vec<Waiter>) {
        let start = {
            let mut state = self.lock();
            state.waiters.extend(waiters);
            state.pending = Some(match state.pending {
                Some(pending) => pending.merged(request),
                None => request,
            });
            !std::mem::replace(&mut state.draining, true)
        };
        if start {
            let (inner, ctx) = (self.clone(), ctx.clone());
            tokio::spawn(async move { inner.drain(&ctx).await });
        }
    }

    /// Run the queued requests, one at a time, until none is left.
    async fn drain(self: &Arc<Self>, ctx: &Context) {
        loop {
            let next = {
                let mut state = self.lock();
                match state.pending.take() {
                    Some(request) => Some((
                        request,
                        std::mem::take(&mut state.waiters),
                        state.running,
                        state.generation,
                    )),
                    None => {
                        state.draining = false;
                        None
                    }
                }
            };
            let Some((request, waiters, running, generation)) = next else {
                break;
            };
            self.run(ctx, request, waiters, running, generation).await;
        }
        self.changed.notify_waiters();
    }

    async fn run(
        self: &Arc<Self>,
        ctx: &Context,
        request: CatalogRequest,
        waiters: Vec<Waiter>,
        running: bool,
        generation: u64,
    ) {
        let started_ms = (self.now_ms)();
        let mut listed = None;
        // A request that lists reads the access with the listing: one round
        // trip, and a listing never asks.
        let access = if !running {
            Ok(GrantAccess::Undetermined)
        } else if request.relist {
            match ctx.app_items(self.spec.app).await {
                Ok(AppItemListing::Items { items, truncated }) => {
                    if truncated {
                        ctx.log(
                            "warn",
                            "[catalog] more items than one listing holds: later ones are not listed",
                        );
                    }
                    listed = Some(self.spec.candidates(items));
                    Ok(GrantAccess::Granted)
                }
                Ok(AppItemListing::NoAccess(access)) => Ok(access),
                Err(reason) => Err(reason),
            }
        } else {
            ctx.app_items_access(self.spec.app).await
        };
        let elapsed_ms = (self.now_ms)().saturating_sub(started_ms);
        let access = match access {
            Ok(access) => access,
            Err(reason) => {
                // The host logged why; the last good rows stay.
                ctx.log("warn", "[catalog] list failed");
                self.log(ctx, "failed", 0, elapsed_ms);
                deliver(waiters, &CatalogOutcome::Failed(reason));
                return;
            }
        };
        if running {
            self.lock().known_access = Some(access);
        }
        let outcome = match CatalogStep::of(request, running, access) {
            CatalogStep::Keep => CatalogOutcome::Kept,
            CatalogStep::Clear => {
                if running {
                    self.log(ctx, "denied", 0, elapsed_ms);
                }
                self.clear(
                    ctx,
                    if running {
                        CatalogOutcome::Denied
                    } else {
                        CatalogOutcome::Cleared
                    },
                )
            }
            CatalogStep::List => {
                let rows = listed.unwrap_or_default();
                let count = rows.len();
                let current = {
                    let mut state = self.lock();
                    // The app quit while it was listed: its termination
                    // already cleared it.
                    let current = state.generation == generation && state.running;
                    if current {
                        state.pending_announce |= state.replace_rows(rows);
                        state.loaded = true;
                    }
                    current
                };
                self.announce(ctx);
                if current {
                    let outcome = if count == 0 { "empty" } else { "ok" };
                    self.log(ctx, outcome, count, elapsed_ms);
                    CatalogOutcome::Listed(count)
                } else {
                    CatalogOutcome::Cleared
                }
            }
            CatalogStep::Ask => {
                self.ask(ctx, waiters).await;
                return;
            }
        };
        deliver(waiters, &outcome);
    }

    fn clear(&self, ctx: &Context, outcome: CatalogOutcome) -> CatalogOutcome {
        {
            let mut state = self.lock();
            state.pending_announce |= state.replace_rows(Vec::new());
            state.loaded = false;
        }
        self.announce(ctx);
        outcome
    }

    /// Have the host show macOS's prompt. The prompt stays up until the
    /// user answers: the queue stays free meanwhile, and the requests that
    /// need the answer wait for it.
    async fn ask(self: &Arc<Self>, ctx: &Context, waiters: Vec<Waiter>) {
        {
            let mut state = self.lock();
            if let Some(waiting) = state.asking.as_mut() {
                waiting.extend(waiters);
                return;
            }
            state.asking = Some(waiters);
        }
        let (inner, ctx) = (self.clone(), ctx.clone());
        let app = self.spec.app;
        let mut call: Pin<Box<dyn Future<Output = Result<GrantAccess, String>> + Send>> = {
            let ctx = ctx.clone();
            Box::pin(async move { ctx.request_app_items_access(app, ASK_TIMEOUT).await })
        };
        // Polled once here, so the request is written before the search or
        // the command that asked is answered: the host honours it only
        // while one of them is in flight.
        let first = std::future::poll_fn(|cx| Poll::Ready(call.as_mut().poll(cx))).await;
        tokio::spawn(async move {
            let answer = match first {
                Poll::Ready(answer) => answer,
                Poll::Pending => call.await,
            };
            let waiters = {
                let mut state = inner.lock();
                if let Ok(access @ (GrantAccess::Granted | GrantAccess::Denied)) = answer {
                    state.known_access = Some(access);
                }
                state.asking.take().unwrap_or_default()
            };
            match answer {
                // Listed on the queue, which answers whoever waited.
                Ok(GrantAccess::Granted) => inner.request(&ctx, CatalogRequest::EVENT, waiters),
                Ok(GrantAccess::Denied) => {
                    let outcome = inner.clear(&ctx, CatalogOutcome::Denied);
                    deliver(waiters, &outcome);
                }
                // macOS cannot be asked now, the host refused to ask, or
                // the prompt is still open: the next query reads the access
                // again.
                Ok(GrantAccess::Undetermined) | Err(_) => {
                    deliver(waiters, &CatalogOutcome::Kept);
                }
            }
            inner.changed.notify_waiters();
        });
    }

    fn log(&self, ctx: &Context, outcome: &str, rows: usize, elapsed_ms: u64) {
        let fields = BTreeMap::from([
            ("outcome".to_string(), outcome.to_string()),
            ("rows".to_string(), rows.to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
        ]);
        ctx.log_fields("debug", "[catalog] refresh", fields.clone());
        if elapsed_ms >= SLOW_REFRESH_MS {
            ctx.log_fields("warn", "[catalog] refresh slow", fields);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;
    use crate::types::RunningApplication;
    use serde_json::{Value, json};
    use std::sync::atomic::{AtomicU64, Ordering};

    const NOTES: &str = "com.apple.Notes";
    const SOURCE: &str = "notes.notes";

    fn rows(items: Vec<AppItem>) -> Vec<CatalogRow> {
        items
            .into_iter()
            .map(|item| CatalogRow {
                id: item.id,
                title: item.title,
                subtitle: "Note".to_string(),
            })
            .collect()
    }

    fn spec() -> ItemCatalogSpec {
        ItemCatalogSpec {
            app: AppItems::Notes,
            bundle_id: NOTES,
            source: SOURCE,
            kind: "note",
            rows,
        }
    }

    fn event(name: &str, bundle_id: Option<&str>) -> Event {
        Event {
            name: name.to_string(),
            bundle_id: bundle_id.map(str::to_string),
            ..Event::default()
        }
    }

    /// Let the tasks the handlers spawned run as far as they can.
    async fn settle() {
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
    }

    /// The host's side of `host.notes`: the access it says macOS grants and
    /// the notes it lists. It counts what the catalog asked of it.
    struct Host {
        harness: Harness,
        catalog: ItemCatalog,
        clock: Arc<AtomicU64>,
        access: GrantAccess,
        grants: bool,
        titles: Vec<&'static str>,
        failure: Option<&'static str>,
        accesses: usize,
        asks: usize,
        lists: usize,
        shown: Vec<String>,
        opened: Vec<String>,
        /// The `changed` notifications the catalog wrote, by source.
        changes: Vec<String>,
    }

    impl Host {
        fn new(access: GrantAccess) -> Self {
            let clock = Arc::new(AtomicU64::new(0));
            let now = clock.clone();
            Self {
                harness: Harness::new("notes"),
                catalog: ItemCatalog::with_clock(spec(), move || now.load(Ordering::Relaxed)),
                clock,
                access,
                grants: true,
                titles: vec!["Groceries"],
                failure: None,
                accesses: 0,
                asks: 0,
                lists: 0,
                shown: Vec::new(),
                opened: Vec::new(),
                changes: Vec::new(),
            }
        }

        fn ctx(&self) -> Context {
            self.harness.context()
        }

        fn send(&self, name: &str, bundle_id: Option<&str>) {
            self.catalog.on_event(&self.ctx(), &event(name, bundle_id));
        }

        /// The snapshot of running apps, with or without Notes.
        fn snapshot(&self, running: bool) {
            let applications = if running {
                vec![RunningApplication {
                    bundle_id: NOTES.to_string(),
                    pid: 7,
                    localized_name: "Notes".to_string(),
                }]
            } else {
                Vec::new()
            };
            self.harness.set_running_applications(applications);
            self.send(host_events::APPS_CHANGED, None);
        }

        fn reply(&mut self, method: &str, params: &Value) -> Value {
            if method == "host.open" {
                self.opened
                    .push(params["bundle_id"].as_str().unwrap().to_string());
                return json!({ "ok": true });
            }
            assert_eq!(method, "host.notes");
            match params["operation"].as_str().unwrap() {
                "access" => {
                    self.accesses += 1;
                    json!({ "ok": true, "access": self.access.as_str() })
                }
                "request_access" => {
                    if self.access == GrantAccess::Undetermined {
                        self.asks += 1;
                        self.access = if self.grants {
                            GrantAccess::Granted
                        } else {
                            GrantAccess::Denied
                        };
                    }
                    json!({ "ok": true, "access": self.access.as_str() })
                }
                "list" if self.access != GrantAccess::Granted => {
                    json!({ "ok": true, "access": self.access.as_str() })
                }
                "list" => {
                    self.lists += 1;
                    match self.failure {
                        Some(reason) => json!({ "ok": false, "error": reason }),
                        None => {
                            let items: Vec<Value> = self
                                .titles
                                .iter()
                                .enumerate()
                                .map(|(index, title)| json!({ "id": format!("note-{index}"), "title": title }))
                                .collect();
                            json!({ "ok": true, "access": "granted", "items": items })
                        }
                    }
                }
                "show" => {
                    self.shown.push(params["id"].as_str().unwrap().to_string());
                    json!({ "ok": true })
                }
                other => panic!("unexpected operation {other}"),
            }
        }

        /// Answer every host call the catalog makes until it stops asking.
        async fn serve(&mut self) {
            loop {
                settle().await;
                let frames = self.harness.drain();
                self.changes.extend(
                    frames
                        .iter()
                        .filter(|frame| frame["method"] == "changed")
                        .map(|frame| frame["params"]["source"].as_str().unwrap().to_string()),
                );
                let calls: Vec<(u64, String, Value)> = frames
                    .into_iter()
                    .filter_map(|frame| {
                        Some((
                            frame.get("id")?.as_u64()?,
                            frame.get("method")?.as_str()?.to_string(),
                            frame["params"].clone(),
                        ))
                    })
                    .collect();
                if calls.is_empty() {
                    return;
                }
                for (id, method, params) in calls {
                    let reply = self.reply(&method, &params);
                    self.harness.reply_host(id, reply);
                }
            }
        }

        fn titles(&self) -> Vec<String> {
            self.catalog
                .rows()
                .into_iter()
                .map(|row| row.title)
                .collect()
        }

        async fn search(&mut self) -> Vec<String> {
            let (catalog, ctx) = (self.catalog.clone(), self.ctx());
            let request = SearchRequest {
                source: SOURCE.to_string(),
                query: String::new(),
            };
            let task = tokio::spawn(async move { catalog.search(&ctx, &request).await });
            self.serve().await;
            task.await
                .unwrap()
                .rows
                .into_iter()
                .map(|row| row.title)
                .collect()
        }

        async fn refresh(&mut self) -> Option<CatalogOutcome> {
            let (catalog, ctx) = (self.catalog.clone(), self.ctx());
            let task = tokio::spawn(async move { catalog.refresh(&ctx).await });
            self.serve().await;
            task.await.unwrap()
        }

        async fn command(&mut self, subcommand: &str, args: &[&str]) -> PerformResponse {
            let (catalog, ctx) = (self.catalog.clone(), self.ctx());
            let command = CommandRequest {
                command: "notes".to_string(),
                subcommand: subcommand.to_string(),
                args: args.iter().map(|arg| arg.to_string()).collect(),
                ..CommandRequest::default()
            };
            let task = tokio::spawn(async move { catalog.command(&ctx, &command).await });
            self.serve().await;
            task.await.unwrap()
        }
    }

    // -- Rows ---------------------------------------------------------------

    /// An entry without an id or a title is dropped, and an id listed twice
    /// keeps its first row.
    #[test]
    fn rows_carry_their_source_kind_and_item() {
        let item = |id: &str, title: &str| AppItem {
            id: id.to_string(),
            title: title.to_string(),
            ..AppItem::default()
        };
        let rows = spec().candidates(vec![
            item("note-1", "First"),
            item("note-2", "Second"),
            item("note-1", "Renamed"),
            item("", "Missing id"),
            item("note-3", ""),
        ]);
        let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
        assert_eq!(titles, ["First", "Second"]);
        assert_eq!(
            serde_json::to_value(&rows[0]).unwrap(),
            json!({
                "source": "notes.notes", "title": "First",
                "metadata": { "kind": "note", "subtitle": "Note", "payload": "note-1" },
            })
        );
        assert!(spec().candidates(Vec::new()).is_empty());
    }

    // -- When they relist ---------------------------------------------------

    /// Only the user's own use of a catalog may ask macOS; a stopped app or
    /// a refusal is an empty catalog.
    #[test]
    fn steps_ask_only_when_the_user_uses_the_catalog() {
        use CatalogRequest as Request;
        use CatalogStep as Step;
        use GrantAccess::{Denied, Granted, Undetermined};
        for request in [Request::EVENT, Request::QUERY, Request::COMMAND] {
            for access in GrantAccess::ALL {
                assert_eq!(Step::of(request, false, access), Step::Clear);
            }
            assert_eq!(Step::of(request, true, Denied), Step::Clear);
        }
        assert_eq!(Step::of(Request::EVENT, true, Granted), Step::List);
        assert_eq!(Step::of(Request::EVENT, true, Undetermined), Step::Keep);
        assert_eq!(Step::of(Request::QUERY, true, Granted), Step::Keep);
        assert_eq!(Step::of(Request::QUERY, true, Undetermined), Step::Ask);
        assert_eq!(Step::of(Request::COMMAND, true, Granted), Step::List);
        assert_eq!(Step::of(Request::COMMAND, true, Undetermined), Step::Ask);
        assert_eq!(Request::EVENT.merged(Request::QUERY), Request::COMMAND);
        assert_eq!(Request::EVENT.merged(Request::EVENT), Request::EVENT);
    }

    #[test]
    fn leaving_the_catalogs_app_names_it_for_a_relist() {
        let mut schedule = CatalogSchedule::default();
        assert!(!schedule.focus(Some(NOTES), NOTES));
        assert!(!schedule.focus(Some(NOTES), NOTES), "no move");
        assert!(schedule.focus(Some("com.apple.reminders"), NOTES));
        assert!(!schedule.focus(Some("com.apple.Terminal"), NOTES));
        assert!(!schedule.focus(None, NOTES));
    }

    #[test]
    fn a_flashlight_open_relists_the_focused_catalog_and_a_stale_one() {
        let ttl = CatalogSchedule::SESSION_TTL_MS;
        let mut schedule = CatalogSchedule::default();
        // Never listed: a running catalog is due; a stopped one never is.
        assert!(!schedule.claim_on_open(false, NOTES, 0));
        assert!(schedule.claim_on_open(true, NOTES, 0));
        // Just listed: not due, unless its app is focused.
        assert!(!schedule.claim_on_open(true, NOTES, 0));
        schedule.focus(Some(NOTES), NOTES);
        assert!(schedule.claim_on_open(true, NOTES, 1));
        schedule.focus(Some("com.apple.Terminal"), NOTES);
        assert!(!schedule.claim_on_open(true, NOTES, ttl));
        assert!(schedule.claim_on_open(true, NOTES, ttl + 1));
        assert!(!schedule.claim_on_open(true, NOTES, ttl + 2));
    }

    // -- The catalog --------------------------------------------------------

    /// The snapshot a new child gets lists the catalog Flash may read; one
    /// never granted waits, unasked, and a stopped app is not read at all.
    #[tokio::test]
    async fn the_first_snapshot_lists_only_a_running_catalog_with_access() {
        let mut granted = Host::new(GrantAccess::Granted);
        granted.snapshot(true);
        granted.serve().await;
        assert_eq!(granted.titles(), ["Groceries"]);
        assert_eq!((granted.lists, granted.asks), (1, 0));

        let mut undetermined = Host::new(GrantAccess::Undetermined);
        undetermined.snapshot(true);
        undetermined.serve().await;
        assert_eq!(
            (undetermined.lists, undetermined.asks),
            (0, 0),
            "an event never asks"
        );
        assert!(undetermined.titles().is_empty());

        let mut stopped = Host::new(GrantAccess::Granted);
        stopped.snapshot(false);
        stopped.serve().await;
        assert_eq!((stopped.lists, stopped.accesses, stopped.asks), (0, 0, 0));
    }

    /// The first query naming the catalog asks once, then lists; later
    /// queries cost nothing.
    #[tokio::test]
    async fn the_first_scoped_query_asks_then_lists() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.asks, 0);
        // The prompt is open while the query is answered: it lists nothing
        // yet, and the listing follows the answer.
        assert_eq!(host.search().await, [] as [&str; 0]);
        assert_eq!((host.asks, host.lists), (1, 1));
        assert_eq!(host.search().await, ["Groceries"]);
        assert_eq!(host.search().await, ["Groceries"]);
        assert_eq!(
            (host.asks, host.lists, host.accesses),
            (1, 1, 0),
            "a query reads memory once access is settled"
        );
        // Another source is not this catalog's.
        let other = SearchRequest {
            source: "notes.other".to_string(),
            query: String::new(),
        };
        assert_eq!(host.catalog.search(&host.ctx(), &other).await.rows, []);
    }

    /// The request for access is written before the query that caused it is
    /// answered: the host honours it only while that search is in flight.
    #[tokio::test]
    async fn the_request_for_access_precedes_the_querys_answer() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.snapshot(true);
        host.serve().await;
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        let (id, _, params) = host.harness.next_host_request().await.unwrap();
        assert_eq!(params, json!({ "operation": "list" }));
        assert!(
            host.harness
                .reply_host(id, json!({ "ok": true, "access": "undetermined" }))
        );
        // Answered while the prompt is still open.
        assert_eq!(search.await.unwrap().rows, []);
        let asked: Vec<Value> = host
            .harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "host.notes")
            .collect();
        assert_eq!(asked.len(), 1, "written by the time the search answered");
        assert_eq!(asked[0]["params"], json!({ "operation": "request_access" }));
    }

    /// A refusal leaves the catalog empty and is never asked again.
    #[tokio::test]
    async fn a_refused_catalog_stays_empty_and_quiet() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.grants = false;
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.refresh().await, Some(CatalogOutcome::Denied));
        assert_eq!(host.search().await, [] as [&str; 0]);
        assert_eq!(host.search().await, [] as [&str; 0]);
        assert_eq!((host.asks, host.lists), (1, 0));
    }

    #[tokio::test]
    async fn queries_of_a_stopped_app_read_nothing() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.snapshot(false);
        assert_eq!(host.search().await, [] as [&str; 0]);
        assert_eq!((host.asks, host.lists, host.accesses), (0, 0, 0));
    }

    #[tokio::test]
    async fn refresh_outcomes() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(false);
        assert_eq!(
            host.refresh().await,
            Some(CatalogOutcome::Cleared),
            "Notes is not running"
        );
        assert_eq!(host.lists, 0);
        host.send(host_events::APPS_LAUNCHED, Some(NOTES));
        host.serve().await;
        assert_eq!(host.refresh().await, Some(CatalogOutcome::Listed(1)));
        // A failed listing keeps the last good rows.
        host.failure = Some("applescript status=124 timed out");
        assert_eq!(
            host.refresh().await,
            Some(CatalogOutcome::Failed(
                "applescript status=124 timed out".to_string()
            ))
        );
        assert_eq!(host.titles(), ["Groceries"]);
        // Access revoked since: the catalog empties.
        host.failure = None;
        host.access = GrantAccess::Denied;
        assert_eq!(host.refresh().await, Some(CatalogOutcome::Denied));
        assert!(host.titles().is_empty());
    }

    /// Termination clears at once, and a listing that began before it is
    /// dropped when it lands.
    #[tokio::test]
    async fn termination_drops_the_rows_and_the_listing_in_flight() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.titles(), ["Groceries"]);

        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let refresh = tokio::spawn(async move { catalog.refresh(&ctx).await });
        let (id, _, params) = host.harness.next_host_request().await.unwrap();
        assert_eq!(params, json!({ "operation": "list" }));
        host.send(host_events::APPS_TERMINATED, Some(NOTES));
        assert!(host.titles().is_empty());
        let late = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-0", "title": "Late" }],
        });
        assert!(host.harness.reply_host(id, late));
        assert_eq!(refresh.await.unwrap(), Some(CatalogOutcome::Cleared));
        assert!(host.titles().is_empty());
        // Another app quitting is not this one's.
        host.send(host_events::APPS_LAUNCHED, Some(NOTES));
        host.serve().await;
        host.send(host_events::APPS_TERMINATED, Some("com.apple.Terminal"));
        assert_eq!(host.titles(), ["Groceries"]);
    }

    #[tokio::test]
    async fn focus_leaving_and_flashlight_opens_relist() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.lists, 1);
        host.send(host_events::SESSION_OPENED, None);
        host.serve().await;
        assert_eq!(host.lists, 1, "listed under a minute ago");
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        host.serve().await;
        assert_eq!(host.lists, 2, "focus left Notes");
        host.clock
            .store(CatalogSchedule::SESSION_TTL_MS, Ordering::Relaxed);
        host.send(host_events::SESSION_OPENED, None);
        host.serve().await;
        assert_eq!(host.lists, 3, "a minute later");
        // While Notes has focus, every open relists it.
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::SESSION_OPENED, None);
        host.serve().await;
        assert_eq!(host.lists, 4);
    }

    /// Requests queued while one runs merge into one more run.
    #[tokio::test]
    async fn requests_queued_during_a_listing_run_once() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        for _ in 0..3 {
            host.send(host_events::FOCUS_CHANGED, Some(NOTES));
            host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        }
        let listed = json!({ "ok": true, "access": "granted", "items": [] });
        assert!(host.harness.reply_host(id, listed));
        host.serve().await;
        assert_eq!(host.lists, 1, "three focus moves, one more listing");
    }

    /// A failed first listing is retried once.
    #[tokio::test]
    async fn a_failed_first_listing_is_retried_once() {
        let mut host = Host::new(GrantAccess::Granted);
        host.failure = Some("boom");
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.lists, 2);
        assert!(host.titles().is_empty());
        // A later launch's failure is not.
        host.send(host_events::APPS_TERMINATED, Some(NOTES));
        host.send(host_events::APPS_LAUNCHED, Some(NOTES));
        host.serve().await;
        assert_eq!(host.lists, 3);
    }

    /// A query waits for a listing in flight, so the rows it answers are
    /// the ones just read; one that takes longer than a moment answers with
    /// the last good rows, and the listing lands for the next query.
    #[tokio::test]
    async fn a_query_waits_for_a_listing_in_flight_but_not_for_long() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        host.serve().await;
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = {
            let (catalog, ctx, request) = (catalog.clone(), ctx.clone(), request.clone());
            tokio::spawn(async move { catalog.search(&ctx, &request).await })
        };
        settle().await;
        assert!(!search.is_finished(), "it waits for the listing");
        let fresh = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-9", "title": "Fresh" }],
        });
        assert!(host.harness.reply_host(id, fresh));
        let rows = search.await.unwrap().rows;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "Fresh");

        // A listing that never lands in time: the last good rows answer.
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let started = std::time::Instant::now();
        let rows = catalog.search(&ctx, &request).await.rows;
        assert!(started.elapsed() >= LOADED_SEARCH_WAIT);
        assert!(
            started.elapsed() < SEARCH_WAIT,
            "the last good rows are not held back"
        );
        assert_eq!(rows[0].title, "Fresh");
        let later = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-9", "title": "Later" }],
        });
        assert!(host.harness.reply_host(id, later));
        settle().await;
        assert_eq!(host.titles(), ["Later"]);
    }

    /// With nothing to show yet, a query gives a slow first listing most of
    /// its deadline before it answers empty.
    #[tokio::test]
    async fn a_query_with_nothing_to_show_waits_longer() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let started = std::time::Instant::now();
        let rows = host.catalog.search(&host.ctx(), &request).await.rows;
        assert!(started.elapsed() >= SEARCH_WAIT);
        assert!(
            started.elapsed() < Duration::from_millis(950),
            "inside the deadline"
        );
        assert_eq!(rows, []);
        let listed = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-0", "title": "Groceries" }],
        });
        assert!(host.harness.reply_host(id, listed));
        host.serve().await;
        assert_eq!(host.titles(), ["Groceries"], "it lands for the next query");
        assert_eq!(host.lists, 0, "and is not read again");
    }

    /// A query on a cold child waits for the snapshot that says whether the
    /// app runs, then lists.
    #[tokio::test]
    async fn a_query_before_the_snapshot_waits_for_it() {
        let mut host = Host::new(GrantAccess::Granted);
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        settle().await;
        assert!(!search.is_finished());
        host.snapshot(true);
        host.serve().await;
        let rows = search.await.unwrap().rows;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].payload_str(), Some("note-0"));
        assert_eq!(host.lists, 1, "the snapshot's listing answers the query");
    }

    /// A query that arrives while the first listing is in flight is
    /// answered by it: nothing is listed twice.
    #[tokio::test]
    async fn a_query_during_the_first_listing_reads_it_once() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (id, _, params) = host.harness.next_host_request().await.unwrap();
        assert_eq!(params, json!({ "operation": "list" }));
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        settle().await;
        assert!(!search.is_finished());
        let listed = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-0", "title": "Groceries" }],
        });
        assert!(host.harness.reply_host(id, listed));
        assert_eq!(search.await.unwrap().rows.len(), 1);
        host.serve().await;
        assert_eq!((host.lists, host.accesses), (0, 0), "no second read");
    }

    // -- Telling the host --------------------------------------------------

    fn listing(titles: &[&str]) -> Value {
        let items: Vec<Value> = titles
            .iter()
            .enumerate()
            .map(|(index, title)| json!({ "id": format!("note-{index}"), "title": title }))
            .collect();
        json!({ "ok": true, "access": "granted", "items": items })
    }

    /// A listing slower than the query's wait answers it empty; when it
    /// lands, the host is told, so the rows appear without retyping.
    #[tokio::test]
    async fn a_listing_that_lands_after_the_query_tells_the_host() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        assert_eq!(host.catalog.search(&host.ctx(), &request).await.rows, []);
        host.serve().await;
        assert_eq!(host.changes, [] as [&str; 0], "nothing changed yet");
        assert!(host.harness.reply_host(id, listing(&["Groceries"])));
        host.serve().await;
        assert_eq!(host.changes, [SOURCE]);
        assert_eq!(host.search().await, ["Groceries"], "the pull it causes");
        assert_eq!(host.changes, [SOURCE], "answering says nothing more");
    }

    /// The rows a waiting query is about to answer with need no second
    /// pull: the listing is its reply.
    #[tokio::test]
    async fn a_listing_that_answers_a_waiting_query_is_not_announced() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        settle().await;
        assert!(host.harness.reply_host(id, listing(&["Groceries"])));
        assert_eq!(search.await.unwrap().rows.len(), 1);
        host.serve().await;
        assert_eq!(host.changes, [] as [&str; 0]);
    }

    /// A query the SDK dropped at its deadline never answered: the rows
    /// that changed while it waited are announced when it goes.
    #[tokio::test]
    async fn a_dropped_query_leaves_its_change_announced() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        let (first, _, _) = host.harness.next_host_request().await.unwrap();
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        settle().await;
        // A second listing is queued behind the first, so the query still
        // waits when the first one's rows land.
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        assert!(host.harness.reply_host(first, listing(&["Groceries"])));
        let (second, _, _) = host.harness.next_host_request().await.unwrap();
        assert_eq!(host.titles(), ["Groceries"]);
        assert!(!search.is_finished(), "it waits for the second listing");
        search.abort();
        assert!(search.await.unwrap_err().is_cancelled());
        assert!(host.harness.reply_host(second, listing(&["Groceries"])));
        host.serve().await;
        assert_eq!(host.changes, [SOURCE], "once, for the rows it never sent");
    }

    /// The query that raised macOS's prompt lists nothing; the listing that
    /// follows the user's answer tells the host, and a refusal changes
    /// nothing.
    #[tokio::test]
    async fn the_answer_to_the_prompt_tells_the_host() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.snapshot(true);
        host.serve().await;
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let request = SearchRequest {
            source: SOURCE.to_string(),
            query: String::new(),
        };
        let search = tokio::spawn(async move { catalog.search(&ctx, &request).await });
        let (id, _, params) = host.harness.next_host_request().await.unwrap();
        assert_eq!(params, json!({ "operation": "list" }));
        assert!(
            host.harness
                .reply_host(id, json!({ "ok": true, "access": "undetermined" }))
        );
        assert_eq!(search.await.unwrap().rows, [], "the prompt is open");
        let (ask, _, params) = host.harness.next_host_request().await.unwrap();
        assert_eq!(params, json!({ "operation": "request_access" }));
        host.serve().await;
        assert_eq!(host.changes, [] as [&str; 0], "nothing to show yet");
        // The user answers; the listing follows.
        host.access = GrantAccess::Granted;
        assert!(
            host.harness
                .reply_host(ask, json!({ "ok": true, "access": "granted" }))
        );
        host.serve().await;
        assert_eq!(host.titles(), ["Groceries"]);
        assert_eq!(host.changes, [SOURCE]);

        let mut refused = Host::new(GrantAccess::Undetermined);
        refused.grants = false;
        refused.snapshot(true);
        refused.serve().await;
        assert_eq!(refused.search().await, [] as [&str; 0]);
        assert_eq!(refused.asks, 1);
        assert_eq!(refused.changes, [] as [&str; 0], "empty before and after");
    }

    /// A relist tells the host only when its rows differ from the ones it
    /// replaces; rows that go (the app quit, access was revoked) differ too.
    #[tokio::test]
    async fn a_relist_tells_the_host_only_when_the_rows_differ() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        host.serve().await;
        assert_eq!(host.changes, [SOURCE], "the first rows");
        assert_eq!(host.refresh().await, Some(CatalogOutcome::Listed(1)));
        assert_eq!(host.changes, [SOURCE], "the same rows");
        host.titles = vec!["Groceries", "Taxes"];
        host.send(host_events::FOCUS_CHANGED, Some(NOTES));
        host.send(host_events::FOCUS_CHANGED, Some("com.apple.Terminal"));
        host.serve().await;
        assert_eq!(host.changes, [SOURCE, SOURCE], "a note was added");
        host.send(host_events::APPS_TERMINATED, Some(NOTES));
        host.serve().await;
        assert_eq!(host.changes, [SOURCE, SOURCE, SOURCE], "Notes quit");
        host.send(host_events::APPS_TERMINATED, Some(NOTES));
        host.serve().await;
        assert_eq!(host.changes.len(), 3, "already empty");

        let mut revoked = Host::new(GrantAccess::Granted);
        revoked.snapshot(true);
        revoked.serve().await;
        revoked.access = GrantAccess::Denied;
        assert_eq!(revoked.refresh().await, Some(CatalogOutcome::Denied));
        assert_eq!(revoked.changes, [SOURCE, SOURCE]);
    }

    // -- Commands and picks -------------------------------------------------

    #[tokio::test]
    async fn the_commands_open_the_app_and_relist() {
        let mut host = Host::new(GrantAccess::Undetermined);
        host.snapshot(true);
        host.serve().await;
        let opened = host.command("open", &[]).await;
        assert_eq!(serde_json::to_value(opened).unwrap(), json!({ "ok": true }));
        assert_eq!(host.opened, [NOTES]);

        // A command is the user's own use: it may ask.
        let refreshed = host.command("refresh", &[]).await;
        assert_eq!(refreshed.toast_message(), Some("notes refreshed"));
        assert_eq!((host.asks, host.lists), (1, 1));
        host.failure = Some("boom");
        let failed = host.command("refresh", &[]).await;
        assert_eq!(failed.error_message(), Some("notes refresh failed"));
        host.failure = None;
        host.access = GrantAccess::Denied;
        let denied = host.command("refresh", &[]).await;
        assert!(denied.is_ok());
        assert_eq!(denied.toast_message(), None, "a refusal says nothing");

        let unknown = host.command("delete", &[]).await;
        assert_eq!(
            unknown.error_message(),
            Some("unknown command: notes delete")
        );
        assert_eq!(host.lists, 2);
    }

    #[tokio::test]
    async fn picking_a_row_shows_its_item() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        host.serve().await;
        let row = host.catalog.rows().remove(0);
        let (catalog, ctx) = (host.catalog.clone(), host.ctx());
        let task = tokio::spawn(async move { catalog.resolve(&ctx, &row).await });
        host.serve().await;
        assert!(task.await.unwrap().is_ok());
        assert_eq!(host.shown, ["note-0"]);

        let bare = Candidate::new(SOURCE, "Groceries");
        let response = host.catalog.resolve(&host.ctx(), &bare).await;
        assert_eq!(response.error_message(), Some("row carries no item"));
        assert_eq!(host.shown.len(), 1);
    }

    /// The log counts rows and time, and never names an item.
    #[tokio::test]
    async fn the_log_names_no_item() {
        let mut host = Host::new(GrantAccess::Granted);
        host.snapshot(true);
        settle().await;
        let (id, _, _) = host.harness.next_host_request().await.unwrap();
        let listed = json!({
            "ok": true, "access": "granted", "items": [{ "id": "note-0", "title": "Groceries" }],
        });
        assert!(host.harness.reply_host(id, listed));
        settle().await;
        let logs: Vec<Value> = host
            .harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "log")
            .collect();
        assert_eq!(logs.len(), 1);
        assert_eq!(logs[0]["params"]["message"], "[catalog] refresh");
        assert_eq!(
            logs[0]["params"]["fields"],
            json!({ "outcome": "ok", "rows": "1", "elapsed_ms": "0" })
        );
        assert!(!logs[0].to_string().contains("Groceries"));
    }
}
