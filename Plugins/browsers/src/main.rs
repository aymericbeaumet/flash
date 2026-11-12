//! Browser tab catalogs, tab actions, and browser history and bookmarks. One
//! engine table maps every supported bundle id to how its tabs are read and
//! driven: AppleScript for Chromium-family browsers and Safari
//! ([`applescript`]), the Accessibility tab strip plus the session store for
//! Firefox ([`firefox`]). Every tab row carries a `flash-browser://` route
//! ([`route`]) that movement history restores through `on_navigate`. The
//! table also names which editions' profile stores feed the per-browser
//! history and bookmark sources ([`history`]). Every source is published
//! alone (`publish_source`), when its own rows change: a tab switch costs
//! the host a browser's tab rows, never the history behind them.

mod applescript;
mod ax;
mod firefox;
mod history;
mod lz4;
mod route;
mod session_store;

use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use applescript::{CHROMIUM, Dialect, ListedTab, SAFARI, TabIdentity, TabSlot};
use firefox::StripPosition;
use flash_plugin::{
    AppWatch, Candidate, CommandRequest, Context, Event, NavigateRequest, PerformResponse,
    PollPriority, RefreshGate, RunningApplication, Settle, ax_notifications, run,
};
use route::TabRoute;
use serde::{Deserialize, Serialize};
use tokio::task::JoinSet;

/// Nothing polls: app lifecycle, focus into or out of a browser, a browser's
/// retitled or new windows, and flashlight opens drive every refresh. A tab
/// switch, open, close or navigation in the focused tab retitles its window
/// (`AXTitleChanged`), as does a background tab renaming itself. Web content
/// posts element creation, destruction and value changes on every keystroke
/// and DOM update, so those are ignored: a background tab opened or closed
/// without retitling anything catches up at the next focus change or
/// flashlight open.
const AX_REFRESH_NOTIFICATIONS: [&str; 2] = [
    ax_notifications::TITLE_CHANGED,
    ax_notifications::WINDOW_CREATED,
];
/// A page load retitles its window several times, so a burst refreshes once
/// it has been quiet this long…
const AX_SETTLE: Duration = Duration::from_millis(300);
/// …or this long after it began, whichever comes first.
const AX_MAX_WAIT: Duration = Duration::from_secs(10);
/// Event bursts (a launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
const REPEAT_WARNING_INTERVAL: Duration = Duration::from_secs(60);
/// A refresh cycle at least this long warns (at most once per
/// `REPEAT_WARNING_INTERVAL`); its `listings` field names the slow browser.
const SLOW_REFRESH: Duration = Duration::from_secs(1);
const LIST_TIMEOUT: Duration = Duration::from_secs(10);
const ACTION_TIMEOUT: Duration = Duration::from_secs(5);
/// The host rejects a catalog over this many rows (or 4 MiB) whole, counted
/// over every source after a per-source publish is merged. Tabs and history
/// are separate sources with their own caps, so their sum stays inside.
const HOST_CATALOG_ROWS: usize = 10_000;
/// Tab rows across every running browser; `history::TOTAL_ROWS_LIMIT` caps
/// the rest.
const TAB_ROWS_LIMIT: usize = 3_000;
const _: () = assert!(TAB_ROWS_LIMIT + history::TOTAL_ROWS_LIMIT <= HOST_CATALOG_ROWS);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// One pending coalesced event refresh at a time: the first event opens an
/// `EVENT_DEBOUNCE` window and every event inside it joins the refresh.
/// `Normal` on both: the tab catalog feeds the flashlight, which nobody
/// watches refresh.
static EVENT_BURST: Settle<()> = Settle::new(EVENT_DEBOUNCE, EVENT_DEBOUNCE, PollPriority::Normal);
/// A refresh reads every running browser, so only events touching one
/// schedule it: focus changes elsewhere cannot change a tab list.
static BROWSER_EVENTS: AppWatch = AppWatch::new();
/// Pending `core:ax.changed` burst from a focused browser.
static AX_BURST: Settle<i64> = Settle::new(AX_SETTLE, AX_MAX_WAIT, PollPriority::Normal);
static REFRESH_LOG_STATE: LazyLock<Mutex<RefreshLogState>> =
    LazyLock::new(|| Mutex::new(RefreshLogState::default()));
/// Each running browser's last listed rows behind the one published catalog.
static CATALOG: LazyLock<Mutex<TabCatalog>> = LazyLock::new(|| Mutex::new(TabCatalog::default()));
/// Consecutive listing failures per browser process: a failing browser warns
/// once per streak, not on every cycle.
static LISTING_STREAKS: LazyLock<Mutex<ListingStreaks>> =
    LazyLock::new(|| Mutex::new(ListingStreaks::default()));

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// How one browser family's tabs are read and driven.
#[derive(Clone, Copy)]
enum Engine {
    /// Scripted over Apple Events in this dialect.
    AppleScript(&'static Dialect),
    /// Firefox: no tab scripting dictionary, so tabs come from the
    /// Accessibility tab strip and the session store, and selection goes
    /// through host key chords and the AX broker.
    Gecko,
}

/// The profile store an edition's history and bookmarks are read from
/// ([`history`]). Editions without one (Chrome Canary, Beta and Dev keep
/// their own profiles; the other browsers are not read) contribute tabs
/// only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HistoryStore {
    /// `places.sqlite` of the newest Firefox profile, shared by the Gecko
    /// editions.
    Firefox,
    /// `History` and `Bookmarks` of Chrome's `Default` profile.
    Chrome,
}

/// One supported browser edition: its bundle ID, the `<vendor>.tabs`
/// source its rows carry (each of type `tabs`), its engine, and the history
/// store it owns, if any.
struct Browser {
    bundle_id: &'static str,
    source: &'static str,
    engine: Engine,
    history: Option<HistoryStore>,
}

impl Browser {
    /// The same edition, reading its history and bookmarks from `store`.
    const fn with_history(mut self, store: HistoryStore) -> Self {
        self.history = Some(store);
        self
    }
}

const fn scripted(
    bundle_id: &'static str,
    source: &'static str,
    dialect: &'static Dialect,
) -> Browser {
    Browser {
        bundle_id,
        source,
        engine: Engine::AppleScript(dialect),
        history: None,
    }
}

const fn gecko(bundle_id: &'static str) -> Browser {
    Browser {
        bundle_id,
        // Release, Developer Edition and Nightly filter together.
        source: "firefox.tabs",
        engine: Engine::Gecko,
        // The newest profile's places.sqlite, whichever edition wrote it.
        history: Some(HistoryStore::Firefox),
    }
}

#[rustfmt::skip]
const BROWSERS: &[Browser] = &[
    scripted("com.google.Chrome", "chrome.tabs", &CHROMIUM).with_history(HistoryStore::Chrome),
    scripted("com.google.Chrome.canary", "chrome.tabs", &CHROMIUM),
    scripted("com.google.Chrome.beta", "chrome.tabs", &CHROMIUM),
    scripted("com.google.Chrome.dev", "chrome.tabs", &CHROMIUM),
    scripted("org.chromium.Chromium", "chromium.tabs", &CHROMIUM),
    scripted("com.brave.Browser", "brave.tabs", &CHROMIUM),
    scripted("com.brave.Browser.beta", "brave.tabs", &CHROMIUM),
    scripted("com.brave.Browser.nightly", "brave.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Beta", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Dev", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Canary", "edge.tabs", &CHROMIUM),
    scripted("company.thebrowser.Browser", "arc.tabs", &CHROMIUM),
    scripted("com.vivaldi.Vivaldi", "vivaldi.tabs", &CHROMIUM),
    scripted("com.operasoftware.Opera", "opera.tabs", &CHROMIUM),
    scripted("com.operasoftware.OperaNext", "opera.tabs", &CHROMIUM),
    scripted("com.operasoftware.OperaDeveloper", "opera.tabs", &CHROMIUM),
    scripted("com.apple.Safari", "safari.tabs", &SAFARI),
    scripted("com.apple.SafariTechnologyPreview", "safari.tabs", &SAFARI),
    gecko("org.mozilla.firefox"),
    gecko("org.mozilla.firefoxdeveloperedition"),
    gecko("org.mozilla.nightly"),
];

fn browser_for(bundle_id: &str) -> Option<&'static Browser> {
    BROWSERS
        .iter()
        .find(|browser| browser.bundle_id == bundle_id)
}

/// A running edition.
struct RunningBrowser {
    browser: &'static Browser,
    pid: i64,
}

/// The running browsers to list, in host order. AppleScript addresses an app
/// by bundle id, not pid, so every instance of a scripted browser (the
/// automation or headless Chrome instances tooling launches beside the
/// user's) answers with the same tabs: only the first in host order is kept,
/// or each would publish a duplicate of every row. Firefox is read per pid.
fn running_browsers(running: &[RunningApplication]) -> Vec<RunningBrowser> {
    let mut scripted_bundles = HashSet::new();
    running
        .iter()
        .filter(|app| app.pid > 0)
        .filter_map(|app| {
            let browser = browser_for(&app.bundle_id)?;
            Some(RunningBrowser {
                browser,
                pid: app.pid,
            })
        })
        .filter(|app| match app.browser.engine {
            Engine::AppleScript(_) => scripted_bundles.insert(app.browser.bundle_id),
            Engine::Gecko => true,
        })
        .collect()
}

/// Round-tripped through the host so `on_resolve` can re-find the tab after
/// unrelated refreshes, even across a plugin restart.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct TabPayload {
    bundle_id: String,
    /// The raw URL as listed (the host's copy of the row URL is re-encoded).
    #[serde(default)]
    url: String,
    /// A scripted tab's title as listed, empty included (the row shows the
    /// URL in its place): with the URL, the identity a pick selects by.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    title: String,
    /// Firefox strip position, for the key fast path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    strip: Option<StripPosition>,
    /// A scripted browser's window and tab indexes at listing, so a pick
    /// selects the listed one of several identical tabs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    slot: Option<TabSlot>,
}

/// One tab row. A tab without a title shows its URL.
fn tab_candidate(
    browser: &Browser,
    pid: i64,
    title: &str,
    url: &str,
    current: bool,
    payload: &TabPayload,
) -> Candidate {
    // Titles keep the browser's whitespace for the select identity; the row
    // shows them trimmed.
    let display = if title.trim().is_empty() {
        url
    } else {
        title.trim()
    };
    let mut candidate = Candidate::new(browser.source, display)
        .kind("browser_tab")
        .location()
        .subtitle("browser tab")
        .bundle_id(browser.bundle_id)
        .pid(pid)
        .payload_json(payload)
        .current_location(current);
    if let Some(route) = TabRoute::new(pid, url, title) {
        candidate = candidate.navigation_url(route.to_url());
    }
    if !url.is_empty() {
        candidate = candidate.url(url);
        if let Some(aliases) = url_aliases(url) {
            candidate = candidate.aliases([aliases]);
        }
    }
    candidate
}

/// A performed pick or restore, naming the route it landed on.
fn performed(pid: i64, route: Option<TabRoute>) -> PerformResponse {
    let response = PerformResponse::ok().target_pid(pid);
    match route {
        Some(route) => response.navigation_url(route.to_url()),
        None => response,
    }
}

/// One source's rows, to publish with `publish_source`.
type SourceRows = (String, Vec<Candidate>);

/// Per-browser rows behind the plugin's tab sources. A publish is
/// proportional to the change: each listing goes out as soon as it lands,
/// as the one source its browser's rows carry (`chrome.tabs`,
/// `firefox.tabs`, …), so a tab switch costs the host a few rows, never the
/// thousands of history and bookmark rows, which [`history`] publishes
/// under their own sources on their own refresh. Editions sharing a source
/// are merged in running order; a slow or failing browser never holds back
/// the others' tabs, and a failed read keeps that browser's previous rows
/// instead of dropping them from the host store.
#[derive(Default)]
struct TabCatalog {
    /// Each browser process's last successful listing, by pid.
    rows: HashMap<i64, Vec<Candidate>>,
    /// Each tab source's last published rows.
    published: HashMap<String, Vec<Candidate>>,
}

impl TabCatalog {
    /// Forget browsers that are no longer running (`running` is the cycle's
    /// complete host snapshot).
    fn retain_running(&mut self, running: &[i64]) {
        self.rows.retain(|pid, _| running.contains(pid));
    }

    /// Record one listing task's results. `Some(rows)` replaces that
    /// browser's rows (an empty list is an authoritative zero-tab result);
    /// `None` is a transient failure that keeps its previous rows. Returns
    /// the sources to publish — those whose merged rows, every running
    /// browser's in `running` order so completion timing cannot reorder
    /// them, differ from their last publish — when at least one read
    /// succeeded.
    fn record(
        &mut self,
        running: &[i64],
        listings: Vec<(i64, Option<Vec<Candidate>>)>,
    ) -> Vec<SourceRows> {
        let mut succeeded = false;
        for (pid, rows) in listings {
            if let Some(rows) = rows {
                self.rows.insert(pid, rows);
                succeeded = true;
            }
        }
        if !succeeded {
            // Publish nothing: the host keeps its last-good catalog.
            return Vec::new();
        }
        self.changed_sources(running)
    }

    /// No browser running: every tab source still published empties.
    fn clear(&mut self) -> Vec<SourceRows> {
        self.rows.clear();
        self.changed_sources(&[])
    }

    /// Every running browser's rows in running order, within
    /// [`TAB_ROWS_LIMIT`].
    fn merged(&self, running: &[i64]) -> Vec<Candidate> {
        running
            .iter()
            .filter_map(|pid| self.rows.get(pid))
            .flatten()
            .take(TAB_ROWS_LIMIT)
            .cloned()
            .collect()
    }

    fn kept_rows(&self, pid: i64) -> usize {
        self.rows.get(&pid).map_or(0, Vec::len)
    }

    /// The sources whose rows differ from their last publish, in the order
    /// the merged rows name them, each becoming that publish. A source whose
    /// last tab closed, or whose browser quit, publishes empty once.
    fn changed_sources(&mut self, running: &[i64]) -> Vec<SourceRows> {
        let mut by_source: Vec<SourceRows> = Vec::new();
        for row in self.merged(running) {
            match by_source
                .iter_mut()
                .find(|(source, _)| *source == row.source)
            {
                Some((_, rows)) => rows.push(row),
                None => by_source.push((row.source.clone(), vec![row])),
            }
        }
        let mut emptied: Vec<String> = self
            .published
            .iter()
            .filter(|(source, rows)| {
                !rows.is_empty() && !by_source.iter().any(|(name, _)| name == *source)
            })
            .map(|(source, _)| source.clone())
            .collect();
        emptied.sort();
        by_source.extend(emptied.into_iter().map(|source| (source, Vec::new())));
        let changed: Vec<SourceRows> = by_source
            .into_iter()
            .filter(|(source, rows)| self.published.get(source) != Some(rows))
            .collect();
        for (source, rows) in &changed {
            self.published.insert(source.clone(), rows.clone());
        }
        changed
    }
}

/// Where a browser's listing stands relative to its failure streak.
#[derive(Debug, PartialEq, Eq)]
enum ListingHealth {
    Healthy,
    FailureStarted,
    StillFailing { failures: u32 },
    Recovered { failures: u32 },
}

#[derive(Default)]
struct ListingStreaks {
    failures: HashMap<i64, u32>,
}

impl ListingStreaks {
    fn retain_running(&mut self, running: &[i64]) {
        self.failures.retain(|pid, _| running.contains(pid));
    }

    fn observe(&mut self, pid: i64, ok: bool) -> ListingHealth {
        if ok {
            return match self.failures.remove(&pid) {
                Some(failures) => ListingHealth::Recovered { failures },
                None => ListingHealth::Healthy,
            };
        }
        let failures = self.failures.entry(pid).or_insert(0);
        *failures += 1;
        if *failures == 1 {
            ListingHealth::FailureStarted
        } else {
            ListingHealth::StillFailing {
                failures: *failures,
            }
        }
    }
}

#[derive(Default)]
struct RefreshLogState {
    outcome: String,
    slow: bool,
    last_slow_warning: Option<Instant>,
}

impl RefreshLogState {
    /// The level to log a refresh cycle at, `None` to stay quiet. Failures
    /// are logged per browser, once per streak (`log_listing`), so a cycle
    /// warns only when slow, at most once per `REPEAT_WARNING_INTERVAL`; an
    /// outcome change is info and a changed catalog debug.
    fn level(
        &mut self,
        outcome: &str,
        slow: bool,
        changed: bool,
        now: Instant,
    ) -> Option<&'static str> {
        let transition = self.outcome != outcome || (self.slow && !slow);
        let slow_warning = slow
            && self
                .last_slow_warning
                .is_none_or(|last| now.duration_since(last) >= REPEAT_WARNING_INTERVAL);
        self.outcome = outcome.to_string();
        self.slow = slow;
        if slow_warning {
            self.last_slow_warning = Some(now);
            Some("warn")
        } else if transition {
            Some("info")
        } else {
            changed.then_some("debug")
        }
    }
}

struct Browsers;

flash_plugin::plugin!(Browsers);

impl FlashPlugin for Browsers {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply; a failed first cycle publishes
        // nothing (the host keeps last-good) and retries in the background.
        if !refresh_locations(&ctx).await {
            ctx.log(
                "warn",
                "[browsers] initial warm catalog degraded outcome=unpublished_failure candidates=0 retry=immediate_background",
            );
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_locations(&retry_ctx).await;
            });
        }
        // The tab sources are published first; the history sources follow
        // once their stores are copied and read, each on its own.
        history::start(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if ax_change_touches_browser(&event) {
            schedule_ax_refresh(&ctx, event.pid.unwrap_or_default());
        } else if BROWSER_EVENTS.touches(
            &event,
            || ctx.running_applications(),
            |bundle| browser_for(bundle).is_some(),
        ) {
            schedule_refresh(&ctx);
        }
        history::on_event(&ctx, &event).await;
    }

    /// A bang arrives with the plugin id as its command; anything else is a
    /// core command the manifest declares (`tab select`, the tab moves),
    /// asked in the focused browser.
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        if command.command == "browsers" {
            return history::bang_command(&command);
        }
        perform_command(&ctx, &command).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }

    async fn on_navigate(&self, ctx: Context, request: NavigateRequest) -> PerformResponse {
        restore_navigation(&ctx, &request).await
    }
}

/// Whether `event` is an AX change in a supported browser that can change
/// its tab list.
fn ax_change_touches_browser(event: &Event) -> bool {
    event.is_ax_change(&AX_REFRESH_NOTIFICATIONS)
        && event
            .bundle_id
            .as_deref()
            .is_some_and(|bundle| browser_for(bundle).is_some())
}

/// Refresh once the browser's AX burst settles.
fn schedule_ax_refresh(ctx: &Context, pid: i64) {
    let refresh_ctx = ctx.clone();
    AX_BURST.schedule(ctx, pid, move |_| async move {
        refresh_locations(&refresh_ctx).await;
    });
}

/// Coalesce an event burst into one refresh `EVENT_DEBOUNCE` out.
fn schedule_refresh(ctx: &Context) {
    let refresh_ctx = ctx.clone();
    EVENT_BURST.schedule(ctx, (), move |_| async move {
        refresh_locations(&refresh_ctx).await;
    });
}

async fn refresh_locations(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            refresh_locations_for_apps(&ctx, running_browsers(&running)).await
        })
        .await
}

/// One listing task's results — each pid it read, `None` for a failed read —
/// and how long the task took.
struct Listing {
    results: Vec<(i64, Option<Vec<Candidate>>)>,
    elapsed: Duration,
}

async fn timed<F>(listing: F) -> Listing
where
    F: std::future::Future<Output = Vec<(i64, Option<Vec<Candidate>>)>>,
{
    let started_at = Instant::now();
    let results = listing.await;
    Listing {
        results,
        elapsed: started_at.elapsed(),
    }
}

async fn refresh_locations_for_apps(ctx: &Context, apps: Vec<RunningBrowser>) -> bool {
    let started_at = Instant::now();
    // A complete running-app snapshot with no matching browser is authoritative:
    // clear dead tab rows.
    if apps.is_empty() {
        let changed = publish_catalog(ctx, TabCatalog::clear);
        log_refresh(
            ctx,
            "empty",
            &RefreshSummary::default(),
            "",
            started_at,
            changed,
        );
        return true;
    }
    let running: Vec<i64> = apps.iter().map(|app| app.pid).collect();
    lock(&CATALOG).retain_running(&running);
    lock(&LISTING_STREAKS).retain_running(&running);
    // Browsers are independent and each read costs hundreds of ms, so they
    // run concurrently: one in-process script per scripted edition (scripts
    // overlap while each waits on its browser's reply), one task walking
    // every running Firefox (they share the session-store read). The cycle
    // holds the refresh gate until every listing lands, so concurrency stays
    // bounded to one read per running browser.
    let mut listings = JoinSet::new();
    let firefoxes: Vec<(&'static Browser, i64)> = apps
        .iter()
        .filter(|app| matches!(app.browser.engine, Engine::Gecko))
        .map(|app| (app.browser, app.pid))
        .collect();
    if !firefoxes.is_empty() {
        listings.spawn(timed(firefox::list_tabs(ctx.clone(), firefoxes)));
    }
    for app in &apps {
        if let Engine::AppleScript(dialect) = app.browser.engine {
            let ctx = ctx.clone();
            let (browser, pid) = (app.browser, app.pid);
            listings.spawn(timed(async move {
                vec![(pid, list_scripted(&ctx, browser, dialect, pid).await)]
            }));
        }
    }
    // Publish each listing as it lands. `Some([])` is an authoritative
    // zero-tab result; `None` (or a pid whose task never reported) is the
    // only transient-failure signal.
    let mut outcomes: HashMap<i64, (Option<usize>, Duration)> = HashMap::new();
    let mut changed = false;
    while let Some(joined) = listings.join_next().await {
        let Ok(listing) = joined else {
            continue;
        };
        let counts: Vec<(i64, Option<usize>)> = listing
            .results
            .iter()
            .map(|(pid, rows)| (*pid, rows.as_ref().map(Vec::len)))
            .collect();
        let published = publish_catalog(ctx, |catalog| catalog.record(&running, listing.results));
        changed |= published;
        for (pid, count) in counts {
            outcomes.insert(pid, (count, listing.elapsed));
            if let Some(app) = apps.iter().find(|app| app.pid == pid) {
                log_listing(ctx, app, count, listing.elapsed, published);
            }
        }
    }
    let listed: Vec<String> = apps
        .iter()
        .map(|app| match outcomes.get(&app.pid) {
            Some((Some(count), elapsed)) => {
                format!(
                    "{}:ok:{count}:{}ms",
                    app.browser.source,
                    elapsed.as_millis()
                )
            }
            Some((None, elapsed)) => {
                format!("{}:failed:{}ms", app.browser.source, elapsed.as_millis())
            }
            None => format!("{}:failed", app.browser.source),
        })
        .collect();
    let successful_apps = outcomes
        .values()
        .filter(|(count, _)| count.is_some())
        .count();
    let summary = RefreshSummary::of(&lock(&CATALOG).merged(&running));
    let outcome = if successful_apps == 0 {
        "failed"
    } else if successful_apps < apps.len() {
        "partial"
    } else if summary.count == 0 {
        "empty"
    } else {
        "ok"
    };
    log_refresh(
        ctx,
        outcome,
        &summary,
        &listed.join(" "),
        started_at,
        changed,
    );
    successful_apps > 0
}

async fn list_scripted(
    ctx: &Context,
    browser: &'static Browser,
    dialect: &'static Dialect,
    pid: i64,
) -> Option<Vec<Candidate>> {
    let listing = ctx
        .applescript(&dialect.list_operation(browser.bundle_id), LIST_TIMEOUT)
        .await
        .ok()?;
    let rows = applescript::parse_tab_list(&listing)
        .iter()
        .map(|tab| scripted_row(browser, pid, tab))
        .collect();
    Some(rows)
}

/// One scripted tab's row: every listed tab is its own row, its payload
/// naming the slot it was listed at.
fn scripted_row(browser: &Browser, pid: i64, tab: &ListedTab) -> Candidate {
    let payload = TabPayload {
        bundle_id: browser.bundle_id.to_string(),
        url: tab.url.clone(),
        title: tab.title.clone(),
        strip: None,
        slot: Some(tab.slot),
    };
    tab_candidate(browser, pid, &tab.title, &tab.url, tab.current, &payload)
}

/// Apply one catalog update and publish each source it changed, under the
/// catalog lock so publishes leave in the order they were decided. True
/// when anything was published.
fn publish_catalog(ctx: &Context, update: impl FnOnce(&mut TabCatalog) -> Vec<SourceRows>) -> bool {
    let mut catalog = lock(&CATALOG);
    let publishes = update(&mut catalog);
    let changed = !publishes.is_empty();
    for (source, rows) in publishes {
        ctx.publish_source(&source, rows);
    }
    changed
}

/// One browser's listing outcome: a failure warns once per streak (the SDK
/// separately rate-limits the osascript error itself), a recovery is info,
/// and everything else is debug.
fn log_listing(
    ctx: &Context,
    app: &RunningBrowser,
    count: Option<usize>,
    elapsed: Duration,
    published: bool,
) {
    let health = lock(&LISTING_STREAKS).observe(app.pid, count.is_some());
    let (level, outcome) = match (health, count) {
        (ListingHealth::FailureStarted, _) => (
            "warn",
            format!(
                "outcome=failed kept_rows={}",
                lock(&CATALOG).kept_rows(app.pid)
            ),
        ),
        (ListingHealth::StillFailing { failures }, _) => (
            "debug",
            format!(
                "outcome=failed failures={failures} kept_rows={}",
                lock(&CATALOG).kept_rows(app.pid)
            ),
        ),
        (ListingHealth::Recovered { failures }, Some(count)) => (
            "info",
            format!("outcome=ok count={count} recovered_after_failures={failures}"),
        ),
        (_, Some(count)) if published => ("debug", format!("outcome=ok count={count}")),
        _ => return,
    };
    ctx.log(
        level,
        &format!(
            "[browsers] listing source={} pid={} {outcome} elapsed_ms={} published={published}",
            app.browser.source,
            app.pid,
            elapsed.as_millis()
        ),
    );
}

/// Content-free shape of a published catalog: its row count and the rows
/// per source in catalog order (`chrome.tabs:12 firefox.tabs:9`).
#[derive(Default)]
struct RefreshSummary {
    count: usize,
    sources: String,
}

impl RefreshSummary {
    fn of(rows: &[Candidate]) -> Self {
        let mut counts: Vec<(&str, usize)> = Vec::new();
        for row in rows {
            match counts.iter_mut().find(|(source, _)| *source == row.source) {
                Some((_, count)) => *count += 1,
                None => counts.push((&row.source, 1)),
            }
        }
        Self {
            count: rows.len(),
            sources: counts
                .iter()
                .map(|(source, count)| format!("{source}:{count}"))
                .collect::<Vec<_>>()
                .join(" "),
        }
    }
}

/// One line per refresh cycle: the merged catalog's shape and each running
/// browser's listing outcome and latency (`chrome.tabs:ok:12:310ms`).
fn log_refresh(
    ctx: &Context,
    outcome: &str,
    summary: &RefreshSummary,
    listings: &str,
    started_at: Instant,
    changed: bool,
) {
    let elapsed = started_at.elapsed();
    let Some(level) =
        lock(&REFRESH_LOG_STATE).level(outcome, elapsed >= SLOW_REFRESH, changed, Instant::now())
    else {
        return;
    };
    ctx.log(
        level,
        &format!(
            "[browsers] refresh outcome={} count={} elapsed_ms={} sources=[{}] listings=[{}]",
            outcome,
            summary.count,
            elapsed.as_millis(),
            summary.sources,
            listings
        ),
    );
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        return PerformResponse::unhandled();
    };
    let Some((tab, browser)) = row
        .payload_as::<TabPayload>()
        .and_then(|tab| browser_for(&tab.bundle_id).map(|browser| (tab, browser)))
    else {
        ctx.activate(pid).await;
        return PerformResponse::ok().target_pid(pid);
    };
    let dialect = match browser.engine {
        Engine::Gecko => return firefox::resolve(ctx, pid, row, &tab).await,
        Engine::AppleScript(dialect) => dialect,
    };
    let Some((route, script)) = scripted_pick(dialect, browser.bundle_id, pid, &tab) else {
        return PerformResponse::fail("tab has neither a URL nor a title");
    };
    ctx.activate(pid).await;
    let result = ctx.applescript(&script, LIST_TIMEOUT).await;
    log_unconfirmed(ctx, "tab-select", pid, &result);
    scripted_outcome(route, &result)
}

/// The route a scripted pick lands on and the script selecting it: the tab
/// whose URL and title are both the listed ones (its title alone when it
/// exposes no URL), looked for at its listed slot first. `None` without
/// either.
fn scripted_pick(
    dialect: &Dialect,
    bundle_id: &str,
    pid: i64,
    tab: &TabPayload,
) -> Option<(TabRoute, flash_plugin::AppleScriptOperation)> {
    let route = TabRoute::new(pid, &tab.url, &tab.title)?;
    let identity = TabIdentity::listed(&tab.url, &tab.title);
    let script = dialect.select_operation(bundle_id, identity, tab.slot);
    Some((route, script))
}

/// Whether a select script printed `ok`.
fn confirmed(result: &Result<String, String>) -> bool {
    result
        .as_deref()
        .is_ok_and(|printed| printed.trim() == "ok")
}

/// A select script's reply: `performed` on the route only when the script
/// confirmed the tab (`ok`). Anything else (`missing`, a failed script) is
/// an error, so the host neither records a jump the user never made nor
/// falls back to another effect.
fn scripted_outcome(route: TabRoute, result: &Result<String, String>) -> PerformResponse {
    if confirmed(result) {
        performed(route.pid, Some(route))
    } else {
        PerformResponse::fail("tab not found")
    }
}

fn log_unconfirmed(ctx: &Context, what: &str, pid: i64, result: &Result<String, String>) {
    if !confirmed(result) {
        ctx.log(
            "warn",
            &format!(
                "[browsers] {what} did not confirm pid={pid} ok={} missing={}",
                result.is_ok(),
                result
                    .as_deref()
                    .is_ok_and(|printed| printed.trim() == "missing")
            ),
        );
    }
}

/// Restore a `flash-browser` route in the browser process it names.
async fn restore_navigation(ctx: &Context, request: &NavigateRequest) -> PerformResponse {
    let Some(route) = TabRoute::parse(&request.url) else {
        return PerformResponse::unhandled();
    };
    let Some(app) = running_browsers(&ctx.running_applications())
        .into_iter()
        .find(|app| app.pid == route.pid)
    else {
        return PerformResponse::fail("the route's browser is no longer running");
    };
    let dialect = match app.browser.engine {
        Engine::Gecko => return firefox::restore(ctx, &route).await,
        Engine::AppleScript(dialect) => dialect,
    };
    let script = dialect.select_operation(
        app.browser.bundle_id,
        TabIdentity::route(&route.target),
        None,
    );
    let result = ctx.applescript(&script, ACTION_TIMEOUT).await;
    log_unconfirmed(ctx, "restore", route.pid, &result);
    scripted_outcome(route, &result)
}

/// A core command the manifest declares, performed in the focused browser:
/// `tab select --index=N` and the tab moves. Anything else, and anything
/// asked outside a browser the engine table knows, is `unhandled`, so the
/// host sends the manifest's chord instead.
async fn perform_command(ctx: &Context, command: &CommandRequest) -> PerformResponse {
    let Some(context) = command.context.as_ref() else {
        return PerformResponse::unhandled();
    };
    let Some(pid) = context.pid else {
        return PerformResponse::unhandled();
    };
    let Some(browser) = context.bundle_id.as_deref().and_then(browser_for) else {
        return PerformResponse::unhandled();
    };
    let dialect = match browser.engine {
        Engine::Gecko => return firefox::perform_command(ctx, pid, command).await,
        Engine::AppleScript(dialect) => dialect,
    };
    let app = browser.bundle_id;
    let script = match (command.command.as_str(), command.subcommand.as_str()) {
        ("tab", "select") => match command.index().filter(|n| *n > 0) {
            Some(index) => dialect.tab_select_operation(app, index),
            None => return PerformResponse::unhandled(),
        },
        // Unhandled for Chromium: the host then sends the manifest's chord.
        ("tab", "move_next" | "move_previous") => {
            match dialect.tab_move_operation(app, command.subcommand == "move_next") {
                Some(script) => script,
                None => return PerformResponse::unhandled(),
            }
        }
        _ => return PerformResponse::unhandled(),
    };
    let result = ctx.applescript(&script, ACTION_TIMEOUT).await;
    // The engine table gates this claim either way: an OK script is
    // `performed`, a non-OK is `failed` so the host doesn't fall back to a
    // ⌘<digit> keystroke that switches the wrong tab.
    if confirmed(&result) {
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail(format!("{} did not confirm", command.name()))
    }
}

/// Site aliases are per-app content the plugin owns — the host ranker has
/// no per-site knowledge. Space-separated tokens land in the top-scoring
/// alias tier.
fn url_aliases(url: &str) -> Option<&'static str> {
    if url.starts_with("https://mail.google.com") {
        return Some("gmail gmail.com");
    }
    None
}

fn main() {
    run(Browsers);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::route::TabTarget;
    use flash_plugin::CommandContext;
    use flash_plugin::candidate_metadata::{CURRENT_LOCATION, NAVIGATION_URL};

    /// Events drive every refresh: startup registers no cadence. This is the
    /// tab refresh `on_start` runs; the history rebuild it continues with
    /// copies the user's real profile stores, so it stays out of a unit test
    /// (it arms no cadence either: `history::on_event` is its only trigger).
    #[tokio::test]
    async fn startup_registers_no_cadence() {
        let mut harness = flash_plugin::testing::Harness::new("browsers");
        refresh_locations(&harness.context()).await;
        let frames = harness.drain();
        assert!(
            !frames.iter().any(|frame| frame["method"] == "poll"),
            "{frames:?}"
        );
    }

    /// A browser's retitled or new windows (a tab switched, opened, closed
    /// or navigated retitles its window) refresh the catalog; its keystrokes
    /// and DOM churn do not, nor do other apps' changes.
    #[test]
    fn only_a_browsers_ax_changes_refresh_the_catalog() {
        let ax = |bundle_id: &str, notification: &str| Event {
            name: "core:ax.changed".into(),
            bundle_id: Some(bundle_id.into()),
            pid: Some(42),
            notification: Some(notification.into()),
            ..Event::default()
        };
        let ax_changed = |bundle_id: &str| ax(bundle_id, ax_notifications::TITLE_CHANGED);
        assert!(ax_change_touches_browser(&ax_changed("com.google.Chrome")));
        assert!(ax_change_touches_browser(&ax_changed(
            "org.mozilla.firefox"
        )));
        assert!(!ax_change_touches_browser(&ax_changed(
            "com.apple.Terminal"
        )));
        for notification in ax_notifications::ALL {
            assert_eq!(
                ax_change_touches_browser(&ax("com.google.Chrome", notification)),
                AX_REFRESH_NOTIFICATIONS.contains(&notification),
                "{notification}"
            );
        }
        assert!(!ax_change_touches_browser(&Event {
            name: "core:ax.changed".into(),
            ..Event::default()
        }));
        assert!(!ax_change_touches_browser(&Event {
            name: "core:focus.changed".into(),
            bundle_id: Some("com.google.Chrome".into()),
            ..Event::default()
        }));
    }

    #[test]
    fn engine_table_distinguishes_browser_editions() {
        let source = |bundle_id| browser_for(bundle_id).map(|browser| browser.source);
        assert_eq!(source("com.google.Chrome"), Some("chrome.tabs"));
        assert_eq!(source("com.brave.Browser"), Some("brave.tabs"));
        assert_eq!(source("com.microsoft.edgemac"), Some("edge.tabs"));
        assert_eq!(
            source("com.apple.SafariTechnologyPreview"),
            Some("safari.tabs")
        );
        for firefox in [
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
        ] {
            assert_eq!(source(firefox), Some("firefox.tabs"), "{firefox}");
            assert!(matches!(
                browser_for(firefox).unwrap().engine,
                Engine::Gecko
            ));
        }
        assert!(matches!(
            browser_for("com.apple.Safari").unwrap().engine,
            Engine::AppleScript(_)
        ));
        assert_eq!(source("org.mozilla.thunderbird"), None);
    }

    /// The history and bookmark stores read: the newest Firefox profile for
    /// every Gecko edition, and Chrome's `Default` profile for Chrome alone
    /// (Canary, Beta and Dev keep their own; the other browsers are not read).
    #[test]
    fn history_stores_belong_to_the_gecko_editions_and_chrome_alone() {
        let stores: Vec<(&str, HistoryStore)> = BROWSERS
            .iter()
            .filter_map(|browser| browser.history.map(|store| (browser.bundle_id, store)))
            .collect();
        assert_eq!(
            stores,
            [
                ("com.google.Chrome", HistoryStore::Chrome),
                ("org.mozilla.firefox", HistoryStore::Firefox),
                ("org.mozilla.firefoxdeveloperedition", HistoryStore::Firefox),
                ("org.mozilla.nightly", HistoryStore::Firefox),
            ]
        );
        for bundle_id in [
            "com.google.Chrome.canary",
            "com.google.Chrome.beta",
            "com.google.Chrome.dev",
            "org.chromium.Chromium",
            "com.brave.Browser",
            "com.apple.Safari",
        ] {
            assert_eq!(browser_for(bundle_id).unwrap().history, None, "{bundle_id}");
        }
    }

    #[test]
    fn running_editions_keep_host_order_and_skip_invalid_pids() {
        let app = |bundle_id: &str, pid, name: &str| RunningApplication {
            bundle_id: bundle_id.into(),
            pid,
            localized_name: name.into(),
        };
        let running = running_browsers(&[
            app("org.mozilla.firefoxdeveloperedition", 11, ""),
            app("com.apple.Finder", 12, "Finder"),
            app("com.google.Chrome", 13, "Chrome FR"),
            app("org.mozilla.firefox", 0, "Firefox"),
            // Another instance AppleScript would address by the same id.
            app("com.google.Chrome", 14, "Chrome FR"),
            // Firefox instances are read per pid.
            app("org.mozilla.firefoxdeveloperedition", 15, ""),
        ]);
        assert_eq!(
            running
                .iter()
                .map(|app| (app.browser.bundle_id, app.pid))
                .collect::<Vec<_>>(),
            [
                ("org.mozilla.firefoxdeveloperedition", 11),
                ("com.google.Chrome", 13),
                ("org.mozilla.firefoxdeveloperedition", 15),
            ]
        );
    }

    #[test]
    fn gmail_urls_gain_search_aliases_and_other_urls_do_not() {
        assert_eq!(
            url_aliases("https://mail.google.com/mail/u/0/"),
            Some("gmail gmail.com")
        );
        assert_eq!(url_aliases("https://example.com/"), None);
    }

    #[test]
    fn every_tab_row_carries_a_browser_route() {
        let chrome = browser_for("com.google.Chrome").unwrap();
        let payload = TabPayload {
            bundle_id: chrome.bundle_id.into(),
            url: "https://example.com/page".into(),
            title: "Page".into(),
            strip: None,
            slot: None,
        };
        let row = tab_candidate(
            chrome,
            42,
            "Page",
            "https://example.com/page",
            true,
            &payload,
        );
        let route = TabRoute::parse(row.meta(NAVIGATION_URL).unwrap()).unwrap();
        assert_eq!(route.pid, 42);
        assert_eq!(
            route.target,
            TabTarget::Url("https://example.com/page".into())
        );
        assert_eq!(row.payload_as::<TabPayload>().unwrap().strip, None);

        let firefox = browser_for("org.mozilla.firefox").unwrap();
        let untitled = tab_candidate(firefox, 7, "Docs", "", false, &TabPayload::default());
        assert_eq!(untitled.source, "firefox.tabs");
        assert_eq!(
            TabRoute::parse(untitled.meta(NAVIGATION_URL).unwrap())
                .unwrap()
                .target,
            TabTarget::Title("Docs".into())
        );
    }

    #[test]
    fn a_scripted_pick_preserves_identity_as_data() {
        let payload = TabPayload {
            bundle_id: "com.apple.Safari".into(),
            url: "https://docs.example/".into(),
            title: "Docs".into(),
            strip: None,
            slot: Some(TabSlot { window: 1, tab: 2 }),
        };
        let (route, operation) = scripted_pick(&SAFARI, "com.apple.Safari", 7, &payload).unwrap();
        assert_eq!(route.target, TabTarget::Url(payload.url.clone()));
        assert_eq!(
            serde_json::to_value(operation).unwrap(),
            serde_json::json!({"operation":"browser_select", "bundle_id":"com.apple.Safari", "url":payload.url, "title":"Docs", "window":1, "tab":2})
        );
        assert!(scripted_pick(&SAFARI, "com.apple.Safari", 7, &TabPayload::default()).is_none());
    }

    #[test]
    fn a_scripted_selection_performs_only_when_the_script_confirms_the_tab() {
        let route = TabRoute::new(7, "", "Docs").unwrap();
        let confirmed = scripted_outcome(route.clone(), &Ok("ok\n".to_string()));
        assert!(confirmed.is_ok());
        let wire = serde_json::to_value(&confirmed).unwrap();
        assert_eq!(wire["target_pid"], serde_json::json!(7));
        assert_eq!(
            wire["navigation_url"].as_str(),
            Some(route.to_url().as_str())
        );
        // `missing` or a failed script: an error, so the host neither
        // records the jump nor falls back.
        for result in [
            Ok("missing\n".to_string()),
            Err(String::new()),
            Err("ok\n".to_string()),
        ] {
            let response = scripted_outcome(route.clone(), &result);
            assert!(!response.is_ok(), "{result:?}");
            assert!(!response.is_unhandled(), "{result:?}");
        }
    }

    #[test]
    fn identical_scripted_tabs_stay_distinct_rows() {
        let chrome = browser_for("com.google.Chrome").unwrap();
        let listed = applescript::parse_tab_list(
            "1\t1\t0\thttps://mail.example/\tInbox\n\
             1\t2\t1\thttps://mail.example/\tInbox\n",
        );
        let rows: Vec<Candidate> = listed
            .iter()
            .map(|tab| scripted_row(chrome, 42, tab))
            .collect();
        assert_eq!(rows.len(), 2);
        assert_ne!(rows[0], rows[1]);
        assert_eq!(
            rows.iter()
                .map(|row| row.payload_as::<TabPayload>().unwrap().slot)
                .collect::<Vec<_>>(),
            [
                Some(TabSlot { window: 1, tab: 1 }),
                Some(TabSlot { window: 1, tab: 2 })
            ]
        );
        assert_eq!(
            rows.iter()
                .map(|row| row.meta(CURRENT_LOCATION))
                .collect::<Vec<_>>(),
            [None, Some("1")]
        );
        assert!(
            rows.iter()
                .all(|row| row.payload_as::<TabPayload>().unwrap().title == "Inbox")
        );
    }

    fn row(source: &str, pid: i64, title: &str) -> Candidate {
        Candidate::new(source, title).pid(pid)
    }

    fn titles(rows: &[Candidate]) -> Vec<&str> {
        rows.iter().map(|row| row.title.as_str()).collect()
    }

    /// The publishes as `(source, titles)`, in the order they go out.
    fn published(publishes: &[SourceRows]) -> Vec<(&str, Vec<&str>)> {
        publishes
            .iter()
            .map(|(source, rows)| (source.as_str(), titles(rows)))
            .collect()
    }

    /// Tabs and history are separate sources with their own caps (the
    /// module-level `const _` proves their sum fits the host's row quota),
    /// so the catalog the host merges stays inside it however many tabs
    /// are open: the rows past the tab cap are dropped, last browser first.
    #[test]
    fn tab_rows_are_capped_so_the_merged_catalog_stays_inside_the_host_quota() {
        let tabs: Vec<Candidate> = (0..TAB_ROWS_LIMIT + 5)
            .map(|index| row("chrome.tabs", 1, &format!("T{index}")))
            .collect();
        let mut catalog = TabCatalog::default();
        let publishes = catalog.record(&[1], vec![(1, Some(tabs.clone()))]);
        assert_eq!(publishes.len(), 1);
        assert_eq!(publishes[0].0, "chrome.tabs");
        assert_eq!(publishes[0].1, tabs[..TAB_ROWS_LIMIT]);
    }

    /// A tab change publishes the one source it touched — a few rows — and
    /// never another browser's tabs or the history rows.
    #[test]
    fn each_listing_publishes_its_own_source_alone() {
        let (chrome, firefox, canary) = (1, 2, 3);
        let running = [chrome, firefox, canary];
        let mut catalog = TabCatalog::default();
        // Firefox lands first: it publishes alone rather than waiting on
        // Chrome's read.
        let publishes = catalog.record(
            &running,
            vec![(firefox, Some(vec![row("firefox.tabs", firefox, "F1")]))],
        );
        assert_eq!(published(&publishes), [("firefox.tabs", vec!["F1"])]);
        // Chrome lands: its own source, Firefox's untouched.
        let publishes = catalog.record(
            &running,
            vec![(chrome, Some(vec![row("chrome.tabs", chrome, "C1")]))],
        );
        assert_eq!(published(&publishes), [("chrome.tabs", vec!["C1"])]);
        // Next cycle: a Firefox change republishes Firefox's source only,
        // while Chrome's read is still in flight.
        let publishes = catalog.record(
            &running,
            vec![(
                firefox,
                Some(vec![
                    row("firefox.tabs", firefox, "F1"),
                    row("firefox.tabs", firefox, "F2"),
                ]),
            )],
        );
        assert_eq!(published(&publishes), [("firefox.tabs", vec!["F1", "F2"])]);
        // Editions sharing a source merge in running order, not completion
        // order.
        let publishes = catalog.record(
            &running,
            vec![(canary, Some(vec![row("chrome.tabs", canary, "K1")]))],
        );
        assert_eq!(published(&publishes), [("chrome.tabs", vec!["C1", "K1"])]);
    }

    #[test]
    fn a_failed_listing_keeps_its_previous_rows_and_publishes_nothing() {
        let (chrome, firefox) = (1, 2);
        let running = [chrome, firefox];
        let mut catalog = TabCatalog::default();
        catalog.record(
            &running,
            vec![
                (chrome, Some(vec![row("chrome.tabs", chrome, "C1")])),
                (firefox, Some(vec![row("firefox.tabs", firefox, "F1")])),
            ],
        );
        // A failure alone publishes nothing: the host keeps last-good.
        assert!(catalog.record(&running, vec![(chrome, None)]).is_empty());
        assert_eq!(catalog.kept_rows(chrome), 1);
        // The next success publishes its source; the failed browser's rows
        // stay in the host store untouched.
        let publishes = catalog.record(
            &running,
            vec![(firefox, Some(vec![row("firefox.tabs", firefox, "F2")]))],
        );
        assert_eq!(published(&publishes), [("firefox.tabs", vec!["F2"])]);
        // An empty listing is authoritative, unlike a failure: the source
        // publishes empty.
        let publishes = catalog.record(&running, vec![(chrome, Some(Vec::new()))]);
        assert_eq!(published(&publishes), [("chrome.tabs", vec![])]);
        // A first cycle whose every read fails publishes nothing.
        let mut fresh = TabCatalog::default();
        assert!(
            fresh
                .record(&running, vec![(chrome, None), (firefox, None)])
                .is_empty()
        );
    }

    #[test]
    fn identical_row_sets_are_not_republished() {
        let (chrome, firefox) = (1, 2);
        let running = [chrome, firefox];
        let mut catalog = TabCatalog::default();
        let chrome_rows = vec![row("chrome.tabs", chrome, "C1")];
        assert!(
            !catalog
                .record(&running, vec![(chrome, Some(chrome_rows.clone()))])
                .is_empty()
        );
        assert!(
            catalog
                .record(&running, vec![(chrome, Some(chrome_rows))])
                .is_empty()
        );
        // A newly listed browser with no tabs has nothing to publish: its
        // source was never published, so there is nothing to empty.
        assert!(
            catalog
                .record(&running, vec![(firefox, Some(Vec::new()))])
                .is_empty()
        );
        assert_eq!(published(&catalog.clear()), [("chrome.tabs", vec![])]);
        assert!(
            catalog.clear().is_empty(),
            "an emptied source publishes once"
        );
    }

    /// A browser quitting empties its source once; the others' sources,
    /// unchanged, are not republished.
    #[test]
    fn browsers_that_quit_empty_their_source() {
        let (chrome, firefox) = (1, 2);
        let mut catalog = TabCatalog::default();
        catalog.record(
            &[chrome, firefox],
            vec![
                (chrome, Some(vec![row("chrome.tabs", chrome, "C1")])),
                (firefox, Some(vec![row("firefox.tabs", firefox, "F1")])),
            ],
        );
        // Chrome quit: the new cycle's snapshot no longer names it.
        catalog.retain_running(&[firefox]);
        assert_eq!(catalog.kept_rows(chrome), 0);
        let publishes = catalog.record(
            &[firefox],
            vec![(firefox, Some(vec![row("firefox.tabs", firefox, "F1")]))],
        );
        assert_eq!(published(&publishes), [("chrome.tabs", vec![])]);
    }

    #[test]
    fn a_failing_browser_warns_once_per_streak() {
        let mut streaks = ListingStreaks::default();
        assert_eq!(streaks.observe(1, true), ListingHealth::Healthy);
        assert_eq!(streaks.observe(1, false), ListingHealth::FailureStarted);
        assert_eq!(
            streaks.observe(1, false),
            ListingHealth::StillFailing { failures: 2 }
        );
        assert_eq!(streaks.observe(2, false), ListingHealth::FailureStarted);
        assert_eq!(
            streaks.observe(1, true),
            ListingHealth::Recovered { failures: 2 }
        );
        assert_eq!(streaks.observe(1, false), ListingHealth::FailureStarted);
        // A quit browser's streak does not outlive it.
        streaks.retain_running(&[1]);
        assert_eq!(streaks.observe(2, false), ListingHealth::FailureStarted);
    }

    #[test]
    fn refresh_cycles_warn_only_when_slow_and_then_once_per_interval() {
        let mut state = RefreshLogState::default();
        let start = Instant::now();
        assert_eq!(state.level("ok", false, true, start), Some("info"));
        assert_eq!(state.level("ok", false, false, start), None);
        assert_eq!(state.level("ok", false, true, start), Some("debug"));
        // A partial streak is an outcome change, not a per-cycle warning.
        assert_eq!(state.level("partial", false, true, start), Some("info"));
        assert_eq!(state.level("partial", false, true, start), Some("debug"));
        assert_eq!(state.level("partial", true, false, start), Some("warn"));
        let later = start + Duration::from_secs(10);
        assert_eq!(state.level("partial", true, true, later), Some("debug"));
        assert_eq!(state.level("partial", false, false, later), Some("info"));
        assert_eq!(
            state.level("partial", true, false, start + REPEAT_WARNING_INTERVAL),
            Some("warn")
        );
    }

    /// A core command asked in a browser, as the host sends it: the focused
    /// app rides along as `context`.
    fn core_command(bundle_id: &str, subcommand: &str) -> CommandRequest {
        CommandRequest {
            command: "tab".into(),
            subcommand: subcommand.into(),
            // No index: even `tab select` has nothing to claim.
            args: vec![],
            context: Some(CommandContext {
                bundle_id: Some(bundle_id.into()),
                pid: Some(4242),
                front_window_frame: None,
            }),
        }
    }

    #[tokio::test]
    async fn firefox_leaves_tab_creation_closing_and_moves_to_its_chords() {
        let harness = flash_plugin::testing::Harness::new("browsers");
        let ctx = harness.context();
        for subcommand in ["new", "close", "move_next", "move_previous", "select"] {
            let command = core_command("org.mozilla.firefox", subcommand);
            assert!(
                perform_command(&ctx, &command).await.is_unhandled(),
                "{subcommand}"
            );
        }
    }

    /// Every browser opens and closes tabs through its own Command-T and
    /// Command-W: a script would only add an Apple Event round trip and an
    /// Automation grant for the same result. A scripted browser steps its
    /// tabs by its own chords too; Firefox steps them itself, naming each
    /// stop ([`firefox::perform_command`]).
    #[tokio::test]
    async fn every_browser_leaves_tab_creation_and_closing_to_its_chords() {
        let harness = flash_plugin::testing::Harness::new("browsers");
        let ctx = harness.context();
        for bundle_id in ["com.google.Chrome", "com.apple.Safari"] {
            for subcommand in ["new", "close", "next", "previous", "first", "last"] {
                let command = core_command(bundle_id, subcommand);
                assert!(
                    perform_command(&ctx, &command).await.is_unhandled(),
                    "{bundle_id} {subcommand}"
                );
            }
        }
        // Without the focused app, or outside a browser, nothing is claimed.
        let mut bare = core_command("com.apple.Safari", "select");
        bare.context = None;
        assert!(perform_command(&ctx, &bare).await.is_unhandled());
        assert!(
            perform_command(&ctx, &core_command("com.apple.finder", "select"))
                .await
                .is_unhandled()
        );
    }

    #[test]
    fn manifest_scopes_exactly_the_engine_table() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let strings = |values: &serde_json::Value| -> Vec<String> {
            values
                .as_array()
                .unwrap()
                .iter()
                .map(|value| value.as_str().unwrap().to_string())
                .collect()
        };
        let table_bundle_ids: Vec<String> =
            BROWSERS.iter().map(|b| b.bundle_id.to_string()).collect();
        assert_eq!(strings(&manifest["only_bundle_ids"]), table_bundle_ids);
        let mut table_sources: Vec<String> =
            BROWSERS.iter().map(|b| b.source.to_string()).collect();
        table_sources.dedup();
        // The tab sources feed default results; the history and bookmark
        // sources follow them and are reached only through their source
        // filter or bang.
        let tab_sources = table_sources.len();
        table_sources.extend(history::SOURCES.iter().map(|source| source.to_string()));
        let sources = manifest["sources"].as_array().unwrap();
        assert_eq!(
            sources
                .iter()
                .map(|source| source["name"].as_str().unwrap().to_string())
                .collect::<Vec<_>>(),
            table_sources
        );
        // The history and bookmark sources are of the default kind, which
        // the manifest leaves implicit.
        for (index, source) in sources.iter().enumerate() {
            let kind = if index < tab_sources {
                serde_json::json!("locations")
            } else {
                serde_json::Value::Null
            };
            assert_eq!(source["kind"], kind, "{}", source["name"]);
        }
        // Every bang is `flash browsers <token>` (the host sends the plugin
        // id as the command) and scopes the flashlight to one declared
        // history or bookmark source.
        let bangs: Vec<(&str, &str)> = manifest["bangs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| {
                (
                    item["token"].as_str().unwrap(),
                    item["source"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            bangs,
            [
                ("fh", "firefox.history"),
                ("fb", "firefox.bookmarks"),
                ("ch", "chrome.history"),
                ("cb", "chrome.bookmarks"),
            ]
        );
        assert!(
            bangs
                .iter()
                .all(|(_, source)| history::SOURCES.contains(source))
        );
        // Firefox needs the AX broker and key posting; every row's route
        // scheme is declared so movement history dispatches it here.
        assert_eq!(
            strings(&manifest["capabilities"]),
            ["accessibility", "app_control", "apple_events"]
        );
        // Host-owned typed operations keep the browser process sandboxed.
        assert!(manifest.get("sandbox").is_none());
        let expected: std::collections::HashSet<_> = BROWSERS
            .iter()
            .filter(|browser| matches!(browser.engine, Engine::AppleScript(_)))
            .map(|browser| browser.bundle_id.to_string())
            .collect();
        assert_eq!(
            strings(&manifest["apple_events_targets"])
                .into_iter()
                .collect::<std::collections::HashSet<_>>(),
            expected
        );
        assert_eq!(strings(&manifest["navigation"]), ["flash-browser"]);
    }
}
