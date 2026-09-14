"use strict";

// Flash Tab Bridge — a ONE-WAY, read-only tab mirror.
//
// Flash never talks to this extension. The extension pushes a tab snapshot by
// calling `runtime.sendNativeMessage`, which makes Firefox spawn the Flash
// native-messaging host (`flash-plugin-firefox-bridge`) for that single
// message, hand it one length-prefixed JSON frame, read one reply and reap the
// process. The host writes the snapshot as a state file under the Flash
// firefox plugin's data directory and exits; the Flash plugin reads that file
// off disk exactly as it already reads the session store.
//
// There is deliberately no resident port, no command channel and no way for
// Flash to ask this extension to do anything. Tab switching stays with Flash
// (host-posted key chords and the Accessibility broker); the bridge only makes
// those mechanisms accurate by supplying exact per-window indices and counts.
//
// The extension never requests host permissions, never injects a content
// script and never reads page DOM. `tabs` alone already yields title and URL.

const HOST = "com.flash.firefox_bridge";
const STATE_VERSION = 1;

// Event bursts (session restore, a window close, a drag that re-indexes a
// whole strip) coalesce into one native message.
const DEBOUNCE_MS = 300;
// Hard cap mirroring the host side. A strip this long is already far past the
// point where a flashlight row per tab is useful, and the cap bounds both the
// native frame and the state file.
const MAX_TABS = 2000;
const MAX_WINDOWS = 200;
// Titles and URLs are bounded so one pathological data: URL cannot blow the
// native frame budget.
const MAX_TITLE_CHARS = 512;
const MAX_URL_CHARS = 2048;
// Re-publish even when nothing changed. The Flash plugin only trusts a state
// file inside a bounded freshness window (5 minutes), and that window is the
// only way it can tell "an idle browser" from "the add-on was disabled or
// crashed". Without this tick an idle Firefox would silently lose its mirror.
const HEARTBEAT_MS = 60000;

let sequence = 0;
let timer = null;
let inFlight = false;
let dirty = false;

function clamp(value, max) {
  if (typeof value !== "string" || value.length === 0) {
    return "";
  }
  if (value.length <= max) {
    return value;
  }
  // Slice by code point, never by UTF-16 unit: a split surrogate pair makes
  // the JSON frame undecodable on the Rust side, which would drop the whole
  // snapshot. This also keeps the cap identical to the host's char count.
  return Array.from(value).slice(0, max).join("");
}

async function snapshot() {
  const windows = await browser.windows.getAll({ populate: false });
  const tabs = await browser.tabs.query({});
  // `focused` goes false on every window while another app is frontmost —
  // which is exactly when Flash reads this file. The last-focused window is
  // the one Firefox's own ⌘1..⌘8 will address, so it is what the reader needs.
  const lastFocused = await browser.windows.getLastFocused().catch(() => null);
  let focusedWindowId = null;
  const windowRows = [];
  for (const window of windows) {
    if (windowRows.length >= MAX_WINDOWS) {
      break;
    }
    if (window.focused) {
      focusedWindowId = window.id;
    }
    windowRows.push({ id: window.id, focused: Boolean(window.focused) });
  }
  const known = new Set(windowRows.map((window) => window.id));
  if (focusedWindowId === null && lastFocused && known.has(lastFocused.id)) {
    focusedWindowId = lastFocused.id;
  }
  const tabRows = [];
  for (const tab of tabs) {
    if (tabRows.length >= MAX_TABS) {
      break;
    }
    if (tab.id == null || tab.windowId == null || !known.has(tab.windowId)) {
      continue;
    }
    tabRows.push({
      id: tab.id,
      window_id: tab.windowId,
      index: typeof tab.index === "number" ? tab.index : 0,
      title: clamp(tab.title || "", MAX_TITLE_CHARS),
      url: clamp(tab.url || "", MAX_URL_CHARS),
      active: Boolean(tab.active),
      pinned: Boolean(tab.pinned)
    });
  }
  sequence += 1;
  return {
    version: STATE_VERSION,
    sequence,
    timestamp_ms: Date.now(),
    focused_window_id: focusedWindowId,
    windows: windowRows,
    tabs: tabRows
  };
}

async function publish() {
  if (inFlight) {
    dirty = true;
    return;
  }
  inFlight = true;
  try {
    const state = await snapshot();
    await browser.runtime.sendNativeMessage(HOST, state);
  } catch (error) {
    // The usual cause is "the native host manifest is not installed yet".
    // Nothing to retry against, and the Flash plugin falls back to its
    // Accessibility walk on its own, so this stays a console breadcrumb.
    console.error("[flash-tab-bridge]", (error && error.message) || String(error));
  } finally {
    inFlight = false;
    if (dirty) {
      dirty = false;
      schedule();
    }
  }
}

function schedule() {
  if (timer !== null) {
    clearTimeout(timer);
  }
  timer = setTimeout(() => {
    timer = null;
    void publish();
  }, DEBOUNCE_MS);
}

// Only the events that can change a tab's identity, position or window
// membership. `onUpdated` is filtered to title/url/status so a favicon or
// audible flip does not re-publish the whole strip.
browser.tabs.onCreated.addListener(schedule);
browser.tabs.onRemoved.addListener(schedule);
browser.tabs.onMoved.addListener(schedule);
browser.tabs.onActivated.addListener(schedule);
browser.tabs.onAttached.addListener(schedule);
browser.tabs.onDetached.addListener(schedule);
browser.tabs.onReplaced.addListener(schedule);
browser.tabs.onUpdated.addListener(schedule, {
  properties: ["title", "url", "status", "pinned"]
});
browser.windows.onCreated.addListener(schedule);
browser.windows.onRemoved.addListener(schedule);
browser.windows.onFocusChanged.addListener(schedule);

// Publish once at load so a browser that is already open is mirrored before
// the first tab event, then keep the mirror inside the reader's freshness
// window while nothing happens.
schedule();
setInterval(() => {
  void publish();
}, HEARTBEAT_MS);
