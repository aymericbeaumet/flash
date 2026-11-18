#!/usr/bin/env node
// Measure the browser help (docs/performance.md, "Browser help"): the help
// server's replies, then the page in headless Chrome — first load and
// reload, page-to-page navigation, typing in the searches, and what the live
// event stream costs a tab left open. Read-only: it sends GET requests and
// holds an event stream, as a help tab does. Node's standard library only;
// Chrome is driven over the DevTools protocol, never shown.
//
// Usage: benchmark-help.mjs [--url http://127.0.0.1:4242] [--runs 5]
//                           [--chrome <path>] [--server-only]
//        benchmark-help.mjs --site [<directory>] [--runs 5] [--chrome <path>]
//
// `--site` measures a build of the published site instead (`mise run
// build:site`, default build/site), with no resident: what the build weighs,
// then the pages in headless Chrome, served from this process over loopback
// under the site's path, compressed as a static host sends them — first
// visits, a link followed cold and after pointing at it, and a search from
// its outline to its text.

import { spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import http from "node:http";
import { homedir, tmpdir } from "node:os";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const options = { url: "http://127.0.0.1:4242", runs: 5, chrome: "", serverOnly: false, site: "" };
const repository = fileURLToPath(new URL("..", import.meta.url));
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--url") options.url = args[++index];
  else if (arg === "--runs") options.runs = Number(args[++index]);
  else if (arg === "--chrome") options.chrome = args[++index];
  else if (arg === "--server-only") options.serverOnly = true;
  else if (arg === "--site") options.site = args[index + 1] && !args[index + 1].startsWith("--") ? resolve(args[++index]) : join(repository, "build/site");
  else {
    console.error("usage: benchmark-help.mjs [--url URL] [--runs N] [--chrome PATH] [--server-only]\n       benchmark-help.mjs --site [DIRECTORY] [--runs N] [--chrome PATH]");
    process.exit(2);
  }
}
const tokenFile = join(homedir(), "Library/Application Support/Flash/help-token");
if (!options.site && !existsSync(tokenFile)) {
  console.error(`no ${tokenFile}: open the help once (flash help show) so Flash writes its token`);
  process.exit(1);
}
const token = options.site ? "" : readFileSync(tokenFile, "utf8").trim();
const base = new URL(options.url);

const percentile = (values, p) => {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)] : NaN;
};
const median = (values) => percentile(values, 50);
const fixed = (value, digits = 1) => (Number.isFinite(value) ? value.toFixed(digits) : "-");

function get(path, headers = {}) {
  return new Promise((resolve, reject) => {
    const started = process.hrtime.bigint();
    let first;
    const request = http.request(
      { host: base.hostname, port: base.port, path, agent: false, headers: { Authorization: `Bearer ${token}`, ...headers } },
      (response) => {
        let bytes = 0;
        response.on("data", (chunk) => { first ??= process.hrtime.bigint(); bytes += chunk.length; });
        response.on("end", () => {
          const ended = process.hrtime.bigint();
          resolve({ status: response.statusCode, headers: response.headers, bytes, ttfb: Number((first ?? ended) - started) / 1e6, total: Number(ended - started) / 1e6 });
        });
      },
    );
    request.on("error", reject);
    request.end();
  });
}

async function measureServer() {
  console.log(`\nServer: ${options.url}, 20 sequential requests each (ms)`);
  console.log(`${"path".padEnd(26)}${"status".padStart(7)}${"bytes".padStart(10)}${"p50".padStart(8)}${"p95".padStart(8)}${"max".padStart(8)}  revalidated`);
  for (const path of ["/docs/normal-mode", "/api/docs", "/api/docs/search", "/api/state", "/api/logs", "/api/traces"]) {
    const replies = [];
    for (let index = 0; index < 20; index += 1) replies.push(await get(path));
    const totals = replies.map((reply) => reply.total);
    let revalidated = "no validator";
    const etag = replies[0].headers.etag;
    if (etag) {
      const again = [];
      for (let index = 0; index < 20; index += 1) again.push(await get(path, { "If-None-Match": etag }));
      revalidated = `${again[0].status} in ${fixed(median(again.map((reply) => reply.total)), 2)} ms`;
    }
    console.log(`${path.padEnd(26)}${String(replies[0].status).padStart(7)}${String(replies[0].bytes).padStart(10)}${fixed(median(totals)).padStart(8)}${fixed(percentile(totals, 95)).padStart(8)}${fixed(Math.max(...totals)).padStart(8)}  ${revalidated}`);
  }
}

// What each page records about itself, installed before the help's script runs.
function instrument() {
  const perf = (window.__flashBench = { longtasks: [], marks: {}, stream: {} });
  try {
    new PerformanceObserver((list) => { for (const entry of list.getEntries()) perf.longtasks.push(entry.duration); }).observe({ type: "longtask", buffered: true });
  } catch { /* Not every engine reports long tasks. */ }
  const Source = window.EventSource;
  window.EventSource = class extends Source {
    addEventListener(type, listener, more) {
      super.addEventListener(type, (event) => {
        const seen = (perf.stream[type] ??= { count: 0, bytes: 0 });
        seen.count += 1;
        seen.bytes += event.data?.length ?? 0;
        listener(event);
      }, more);
    }
  };
  const watch = () => {
    if (!perf.marks.docs && document.querySelector(".article-body h2, .article-body p")) perf.marks.docs = performance.now();
    if (!perf.marks.live && document.querySelector(".sidebar .version")) perf.marks.live = performance.now();
    if (!(perf.marks.docs && perf.marks.live)) requestAnimationFrame(watch);
  };
  requestAnimationFrame(watch);
}

// Follows a link the way a click does and times the app's render and layout,
// then the next frame.
async function hop(href) {
  const heading = () => document.querySelector("main h1")?.textContent ?? "";
  const before = heading();
  const link = document.createElement("a");
  link.href = href;
  document.body.append(link);
  const macrotask = () => new Promise((resolve) => { const channel = new MessageChannel(); channel.port1.onmessage = resolve; channel.port2.postMessage(0); });
  const started = performance.now();
  link.click();
  link.remove();
  await macrotask();
  void document.body.offsetHeight;
  const laidOut = performance.now();
  await new Promise((resolve) => requestAnimationFrame(() => macrotask().then(resolve)));
  const framed = performance.now();
  await new Promise((resolve) => setTimeout(resolve, 300));
  return { render: laidOut - started, frame: framed - started, changed: heading() !== before };
}

// Types `text` into the field one character at a time and times each
// keystroke's work: the app's update and the layout it causes. The field is
// emptied afterwards unless `keep` is set.
async function type(selector, text, keep = false) {
  const field = document.querySelector(selector);
  if (!field) return null;
  field.focus();
  const macrotask = () => new Promise((resolve) => { const channel = new MessageChannel(); channel.port1.onmessage = resolve; channel.port2.postMessage(0); });
  const keys = [];
  for (const character of text) {
    const started = performance.now();
    field.value += character;
    field.dispatchEvent(new Event("input", { bubbles: true }));
    await macrotask();
    void document.body.offsetHeight;
    keys.push(performance.now() - started);
    await new Promise((resolve) => setTimeout(resolve, 60));
  }
  if (keep) return keys;
  field.value = "";
  field.dispatchEvent(new Event("input", { bubbles: true }));
  return keys;
}

class DevTools {
  constructor(socket) {
    this.socket = socket;
    this.next = 0;
    this.pending = new Map();
    this.waiters = [];
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) pending?.reject(new Error(`${message.error.message} (${pending.method})`));
        else pending?.resolve(message.result);
        return;
      }
      this.waiters = this.waiters.filter((waiter) => !(waiter.method === message.method && waiter.session === message.sessionId && (waiter.resolve(message.params), true)));
    });
  }

  send(method, params = {}, sessionId) {
    const id = ++this.next;
    this.socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject, method }));
  }

  event(method, session) {
    return new Promise((resolve) => this.waiters.push({ method, session, resolve }));
  }
}

async function launch(path) {
  const profile = await mkdtemp(join(tmpdir(), "flash-bench-help-"));
  const chrome = spawn(path, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-extensions", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  const endpoint = await new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => reject(new Error("Chrome did not start its DevTools endpoint")), 20_000);
    chrome.stderr.on("data", (chunk) => {
      output += chunk;
      const match = /DevTools listening on (ws:\/\/\S+)/.exec(output);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.on("exit", () => { clearTimeout(timer); reject(new Error("Chrome exited before it listened")); });
  });
  const socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const close = async () => { socket.close(); chrome.kill(); await new Promise((resolve) => chrome.once("exit", resolve)); await rm(profile, { recursive: true, force: true }); };
  return { devtools: new DevTools(socket), close };
}

/** A tab in a fresh browser context: a cold cache and empty storage. */
async function openTab(devtools) {
  const { browserContextId } = await devtools.send("Target.createBrowserContext");
  const { targetId } = await devtools.send("Target.createTarget", { url: "about:blank", browserContextId });
  const { sessionId } = await devtools.send("Target.attachToTarget", { targetId, flatten: true });
  const send = (method, params) => devtools.send(method, params, sessionId);
  const evaluate = async (source, ...values) => {
    const reply = await send("Runtime.evaluate", { expression: `(${source})(...${JSON.stringify(values)})`, awaitPromise: true, returnByValue: true });
    if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text);
    return reply.result.value;
  };
  const metrics = async () => Object.fromEntries((await send("Performance.getMetrics")).metrics.map((metric) => [metric.name, metric.value]));
  for (const domain of ["Page", "Runtime", "Performance"]) await send(`${domain}.enable`);
  await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false });
  await send("Page.addScriptToEvaluateOnNewDocument", { source: `(${instrument})()` });
  const load = async (url) => {
    const loaded = devtools.event("Page.loadEventFired", sessionId);
    if (url) await send("Page.navigate", { url });
    else await send("Page.reload", {});
    await loaded;
    await evaluate(() => new Promise((resolve, reject) => {
      const deadline = performance.now() + 15_000;
      const check = () => {
        const marks = window.__flashBench?.marks ?? {};
        if (marks.docs && marks.live) resolve();
        else if (performance.now() > deadline) reject(new Error("the page did not render its documentation and live data"));
        else setTimeout(check, 20);
      };
      check();
    }));
    await new Promise((resolve) => setTimeout(resolve, 1000));
    return evaluate(() => {
      const navigation = performance.getEntriesByType("navigation")[0];
      const bench = window.__flashBench;
      const fetched = performance.getEntriesByType("resource").reduce((sum, entry) => sum + entry.transferSize, navigation.transferSize);
      return {
        ttfb: navigation.responseStart, fcp: performance.getEntriesByName("first-contentful-paint")[0]?.startTime,
        docs: bench.marks.docs, live: bench.marks.live, kib: fetched / 1024,
        longtasks: bench.longtasks.reduce((sum, duration) => sum + duration, 0),
      };
    });
  };
  return { send, evaluate, metrics, load, close: () => devtools.send("Target.disposeBrowserContext", { browserContextId }) };
}

const hops = ["/docs/configuration", "/docs/plugin-protocol", "/mappings", "/commands", "/clipboard", "/logs", "/docs/commands", "/docs/normal-mode"];
const searches = [
  ["/docs/normal-mode", ".searchbox input", "window move"],
  ["/mappings", 'main input[aria-label="Search mappings"]', "window left"],
  ["/commands", 'main input[aria-label="Search commands"]', "clipboard"],
  ["/logs", 'main input[aria-label="Search logs"]', "statusbar"],
];

async function measureBrowser(chromePath) {
  const { devtools, close } = await launch(chromePath);
  const runs = [];
  try {
    for (let run = 0; run < options.runs; run += 1) {
      const tab = await openTab(devtools);
      const entry = new URL(`/docs/normal-mode?token=${token}`, base).href;
      const cold = await tab.load(entry);
      const warm = await tab.load(null);
      await tab.evaluate(() => { window.__flashBench.stream = {}; });
      const before = await tab.metrics();
      await new Promise((resolve) => setTimeout(resolve, 10_000));
      const after = await tab.metrics();
      const stream = await tab.evaluate(() => window.__flashBench.stream);
      const idle = {
        taskPerSecond: ((after.TaskDuration - before.TaskDuration) * 1000) / 10,
        kib: Object.values(stream).reduce((sum, seen) => sum + seen.bytes, 0) / 1024,
        pushes: (stream.state?.count ?? 0) + (stream.patch?.count ?? 0),
      };
      const navigation = [];
      for (const pass of [0, 1]) for (const href of hops) navigation.push({ pass, href, ...(await tab.evaluate(hop, href)) });
      const typing = [];
      for (const [page, selector, text] of searches) {
        await tab.evaluate(hop, page);
        typing.push({ page, keys: await tab.evaluate(type, selector, text) ?? [] });
      }
      runs.push({ cold, warm, idle, navigation, typing });
      await tab.close();
    }
  } finally {
    await close();
  }
  const row = (label, values, unit = "ms") => console.log(`${label.padEnd(44)}${fixed(median(values)).padStart(9)} ${unit}`);
  console.log(`\nBrowser: headless Chrome, 1440x900, median of ${runs.length} runs`);
  for (const kind of ["cold", "warm"]) {
    row(`${kind} load: bytes fetched`, runs.map((run) => run[kind].kib), "KiB");
    row(`${kind} load: first contentful paint`, runs.map((run) => run[kind].fcp));
    row(`${kind} load: documentation rendered`, runs.map((run) => run[kind].docs));
    row(`${kind} load: live data rendered`, runs.map((run) => run[kind].live));
    row(`${kind} load: long tasks`, runs.map((run) => run[kind].longtasks));
  }
  row("open tab, idle: main-thread time per second", runs.map((run) => run.idle.taskPerSecond));
  row("open tab, idle: stream received in 10 s", runs.map((run) => run.idle.kib), "KiB");
  row("open tab, idle: state pushes in 10 s", runs.map((run) => run.idle.pushes), "");
  for (const pass of [0, 1]) {
    for (const href of hops) row(`${pass ? "again" : "first"} -> ${href}: render + layout`, runs.map((run) => run.navigation.find((step) => step.pass === pass && step.href === href)?.render));
  }
  for (const [page, , text] of searches) {
    const keys = runs.flatMap((run) => run.typing.find((step) => step.page === page)?.keys ?? []);
    row(`typing "${text}" on ${page}: per key p50`, keys);
    row(`typing "${text}" on ${page}: per key p95`, [percentile(keys, 95)]);
  }
}

// --- The published site -----------------------------------------------------

const contentTypes = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".xml": "application/xml", ".txt": "text/plain; charset=utf-8", ".toml": "text/plain; charset=utf-8", ".png": "image/png", ".jpg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" };

/**
 * The build served over loopback under the site's path, as a static host
 * does: compressed text, a directory's index.html, the 404 page for anything
 * else. `hold(pattern)` keeps matching replies back until its release is
 * called, so the search can be read between its two files.
 */
async function serveSite(directory, root) {
  const compressed = new Map();
  let held = null;
  const server = http.createServer(async (request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    let file;
    if (path.startsWith(`${root}/`)) {
      let relative = path.slice(root.length + 1);
      if (relative === "" || relative.endsWith("/")) relative += "index.html";
      const candidate = resolve(directory, relative);
      if (candidate.startsWith(directory + sep) && existsSync(candidate) && statSync(candidate).isFile()) file = candidate;
    }
    const status = file ? 200 : 404;
    file ??= join(directory, "404.html");
    if (held?.pattern.test(path)) await held.released;
    const type = contentTypes[extname(file)] ?? "application/octet-stream";
    const headers = { "content-type": type, "cache-control": "max-age=600" };
    let body = readFileSync(file);
    if (/^(text|application)\//.test(type) && /\bgzip\b/.test(request.headers["accept-encoding"] ?? "")) {
      if (!compressed.has(file)) compressed.set(file, gzipSync(body, { level: 6 }));
      body = compressed.get(file);
      headers["content-encoding"] = "gzip";
    }
    response.writeHead(status, { ...headers, "content-length": body.length });
    response.end(body);
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    hold(pattern) {
      let release;
      held = { pattern, released: new Promise((done) => { release = done; }) };
      return () => { held = null; release(); };
    },
    close: () => new Promise((done) => { server.closeAllConnections(); server.close(done); }),
  };
}

/**
 * A tab on the published site, in a fresh browser context. A link is a
 * document of its own, and one the browser rendered ahead replaces the tab's
 * page target, so the tab finds its page again after every navigation.
 */
async function openSiteTab(devtools) {
  const { browserContextId } = await devtools.send("Target.createBrowserContext");
  const { targetId } = await devtools.send("Target.createTarget", { url: "about:blank", browserContextId });
  let session;
  const attach = async (target) => {
    session = (await devtools.send("Target.attachToTarget", { targetId: target, flatten: true })).sessionId;
    for (const domain of ["Page", "Runtime"]) await devtools.send(`${domain}.enable`, {}, session);
    await devtools.send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false }, session);
  };
  await attach(targetId);
  const send = (method, params) => devtools.send(method, params, session);
  const evaluate = async (source, ...values) => {
    const reply = await send("Runtime.evaluate", { expression: `(${source})(...${JSON.stringify(values)})`, awaitPromise: true, returnByValue: true });
    if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text);
    return reply.result.value;
  };
  /** What the page at `path` says about its own load, once it is hydrated and painted. */
  const arrive = async (path) => {
    const read = () => {
      const navigation = performance.getEntriesByType("navigation")[0];
      const hydrated = performance.getEntriesByName("flash:hydrated")[0]?.startTime;
      const paint = performance.getEntriesByName("first-contentful-paint")[0]?.startTime;
      if (document.prerendering || hydrated === undefined || paint === undefined) return null;
      // A page rendered ahead counts its times from when it was shown.
      const shown = navigation.activationStart ?? 0;
      const resources = performance.getEntriesByType("resource");
      return {
        path: location.pathname,
        prepared: shown > 0 ? "rendered ahead" : navigation.deliveryType === "navigational-prefetch" ? "fetched ahead" : "no",
        paint: Math.max(0, paint - shown), hydrated: Math.max(0, hydrated - shown),
        kib: resources.reduce((sum, entry) => sum + entry.transferSize, navigation.transferSize) / 1024,
        requests: resources.length + 1,
        longtasks: (window.__flashBench?.longtasks ?? []).reduce((sum, duration) => sum + duration, 0),
      };
    };
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      try {
        const page = await Promise.race([evaluate(read), new Promise((_, reject) => setTimeout(() => reject(new Error("no reply")), 2000))]);
        if (page?.path === path) return page;
      } catch { /* The document is changing, or this target was replaced. */ }
      const { targetInfos } = await devtools.send("Target.getTargets");
      const page = targetInfos.find((info) => info.type === "page" && info.browserContextId === browserContextId && info.subtype !== "prerender" && new URL(info.url).pathname === path);
      if (page && !page.attached) await attach(page.targetId);
      await new Promise((done) => setTimeout(done, 20));
    }
    throw new Error(`${path} did not load and hydrate`);
  };
  const instrumented = `(${() => {
    const perf = (window.__flashBench = { longtasks: [] });
    try {
      new PerformanceObserver((list) => { for (const entry of list.getEntries()) perf.longtasks.push(entry.duration); }).observe({ type: "longtask", buffered: true });
    } catch { /* Not every engine reports long tasks. */ }
  }})()`;
  return {
    evaluate,
    async load(url) {
      await send("Page.addScriptToEvaluateOnNewDocument", { source: instrumented });
      await send("Page.navigate", { url });
      return arrive(new URL(url).pathname);
    },
    /** Follows the page's own link to `path` without pointing at it first. */
    async click(path) {
      await evaluate((href) => document.querySelector(`a[href="${href}"]`).click(), path);
      return arrive(path);
    },
    /** Points at the page's own link to `path`, rests, then presses it, as a hand does. */
    async pointAndClick(path) {
      const at = await evaluate((href) => {
        const link = document.querySelector(`a[href="${href}"]`);
        link.scrollIntoView({ block: "center" });
        const box = link.getBoundingClientRect();
        return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
      }, path);
      const mouse = (type, more = {}) => send("Input.dispatchMouseEvent", { type, x: at.x, y: at.y, ...more });
      await mouse("mouseMoved", { x: at.x - 4 });
      await mouse("mouseMoved");
      await new Promise((done) => setTimeout(done, 400));
      await mouse("mousePressed", { button: "left", clickCount: 1 });
      await new Promise((done) => setTimeout(done, 80));
      await mouse("mouseReleased", { button: "left", clickCount: 1 });
      return arrive(path);
    },
    close: () => devtools.send("Target.disposeBrowserContext", { browserContextId }),
  };
}

const sitePages = ["", "getting-started/", "commands/"];
const siteQuery = "window move";

async function measureSiteBrowser(chromePath, served, root) {
  const { devtools, close } = await launch(chromePath);
  const address = (page) => `${served.origin}${root}/${page}`;
  const runs = [];
  try {
    for (let run = 0; run < options.runs; run += 1) {
      const first = {};
      for (const page of sitePages) {
        const tab = await openSiteTab(devtools);
        first[page] = await tab.load(address(page));
        await tab.close();
      }
      // Two links from the home page, each in a browser that has only seen it.
      let tab = await openSiteTab(devtools);
      await tab.load(address(""));
      const cold = await tab.click(`${root}/commands/`);
      await tab.close();
      tab = await openSiteTab(devtools);
      await tab.load(address(""));
      const pointed = await tab.pointAndClick(`${root}/commands/`);
      await tab.close();
      // A search: the outline alone while the text is held back, then all of it.
      tab = await openSiteTab(devtools);
      await tab.load(address("getting-started/"));
      const release = served.hold(/\/_app\/search-text-/);
      const search = { keys: [] };
      try {
        const focused = await tab.evaluate(() => { document.querySelector(".searchbox input").focus(); return performance.now(); });
        const file = (name) => tab.evaluate((pattern) => new Promise((done) => {
          const check = () => {
            const entry = performance.getEntriesByType("resource").find((candidate) => candidate.name.includes(pattern) && candidate.responseEnd > 0);
            if (entry) done({ end: entry.responseEnd, kib: entry.transferSize / 1024 });
            else setTimeout(check, 5);
          };
          check();
        }), name);
        const state = () => tab.evaluate(() => ({ line: document.querySelector("main .purpose")?.textContent ?? "", results: document.querySelectorAll(".search-results a").length, note: document.querySelector(".search-results p.empty")?.textContent.trim() ?? "", now: performance.now() }));
        const outline = await file("/_app/search-outline-");
        search.outline = { ms: outline.end - focused, kib: outline.kib };
        search.keys = await tab.evaluate(type, ".searchbox input", siteQuery, true);
        await new Promise((done) => setTimeout(done, 100));
        search.partial = await state();
        const released = search.partial.now;
        release();
        const text = await file("/_app/search-text-");
        let complete = await state();
        for (const deadline = Date.now() + 10_000; /search/i.test(complete.line) && Date.now() < deadline; ) {
          await new Promise((done) => setTimeout(done, 5));
          complete = await state();
        }
        search.text = { ms: complete.now - released, kib: text.kib };
        search.complete = complete;
      } finally {
        release();
      }
      await tab.close();
      runs.push({ first, cold, pointed, search });
    }
  } finally {
    await close();
  }
  const row = (label, values, unit = "ms") => console.log(`${label.padEnd(62)}${fixed(median(values)).padStart(9)} ${unit}`);
  const said = (values) => [...new Set(values)].join(" | ");
  console.log(`\nBrowser: headless Chrome, 1440x900, loopback, median of ${runs.length} runs`);
  for (const page of sitePages) {
    const name = `first visit of ${root}/${page}`;
    row(`${name}: transferred`, runs.map((entry) => entry.first[page].kib), "KiB");
    row(`${name}: requests`, runs.map((entry) => entry.first[page].requests), "");
    row(`${name}: first contentful paint`, runs.map((entry) => entry.first[page].paint));
    row(`${name}: hydrated`, runs.map((entry) => entry.first[page].hydrated));
    row(`${name}: long tasks`, runs.map((entry) => entry.first[page].longtasks));
  }
  for (const [label, kind] of [["link followed cold", "cold"], ["link pointed at, then pressed", "pointed"]]) {
    console.log(`${`${label}: had the page ahead`.padEnd(62)}${said(runs.map((entry) => entry[kind].prepared)).padStart(9)}`);
    row(`${label}: transferred`, runs.map((entry) => entry[kind].kib), "KiB");
    row(`${label}: first contentful paint`, runs.map((entry) => entry[kind].paint));
    row(`${label}: hydrated`, runs.map((entry) => entry[kind].hydrated));
  }
  row("search: outline after the field takes focus", runs.map((entry) => entry.search.outline.ms));
  row("search: outline transferred", runs.map((entry) => entry.search.outline.kib), "KiB");
  row(`search: results for "${siteQuery}" from the outline`, runs.map((entry) => entry.search.partial.results), "");
  row("search: text read and results complete", runs.map((entry) => entry.search.text.ms));
  row("search: text transferred", runs.map((entry) => entry.search.text.kib), "KiB");
  row(`search: results for "${siteQuery}" once complete`, runs.map((entry) => entry.search.complete.results), "");
  const keys = runs.flatMap((entry) => entry.search.keys);
  row(`typing "${siteQuery}": per key p50`, keys);
  row(`typing "${siteQuery}": per key p95`, [percentile(keys, 95)]);
  console.log(`search, outline only: ${said(runs.map((entry) => `${entry.search.partial.line} / ${entry.search.partial.note}`))}`);
  console.log(`search, complete:     ${said(runs.map((entry) => entry.search.complete.line))}`);
}

async function measureSite() {
  if (!existsSync(join(options.site, "index.html"))) {
    console.error(`no site in ${options.site}: build it first (mise run build:site)`);
    process.exit(1);
  }
  const { measureSite: weigh } = await import(new URL("../Inspector/scripts/site-sizes.ts", import.meta.url).href);
  const sizes = weigh(options.site);
  const kib = (bytes) => (bytes / 1024).toFixed(1);
  const line = (label, weight) => console.log(`${label.padEnd(62)}${kib(weight.raw).padStart(10)}${kib(weight.gzip).padStart(10)}`);
  console.log(`\nSite: ${options.site}, ${sizes.pages} pages and ${sizes.stubs} alias stubs (KiB)`);
  console.log(`${"".padEnd(62)}${"raw".padStart(10)}${"gzip".padStart(10)}`);
  line("total HTML", sizes.html);
  line(`median page (${sizes.medianPage.file})`, sizes.medianPage);
  line(`largest page (${sizes.largestPage.file})`, sizes.largestPage);
  line("site JS", sizes.js);
  line("CSS", sizes.css);
  line("navigation", sizes.navigation);
  line("search outline", sizes.searchOutline);
  line("search text", sizes.searchText);
  const chrome = findChrome();
  if (!chrome) return console.log("\nNo Chrome found (--chrome <path>): browser measurements skipped.");
  const { site } = JSON.parse(readFileSync(join(repository, "docs/nav.json"), "utf8"));
  const root = new URL(site.url).pathname.replace(/\/$/, "");
  const served = await serveSite(options.site, root);
  try {
    await measureSiteBrowser(chrome, served, root);
  } finally {
    await served.close();
  }
}

function findChrome() {
  return options.chrome || ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"].find((path) => existsSync(path));
}

if (options.site) {
  await measureSite();
  process.exit(0);
}
try {
  await get("/api/traces");
} catch {
  console.error(`nothing answers at ${options.url}: open the help (flash help show), or set [debug] http_inspector_enabled = true`);
  process.exit(1);
}
await measureServer();
if (!options.serverOnly) {
  const chrome = findChrome();
  if (!chrome) console.log("\nNo Chrome found (--chrome <path>): browser measurements skipped.");
  else await measureBrowser(chrome);
}
