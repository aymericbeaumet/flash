import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import type { ViteDevServer } from "vite";
import { freshNotice, hashBody, readingKey } from "./src/lib/reading.ts";
import { configToast, copiedToast, copyFailedToast, dismissedKey, dismissedLimit, doneToast, failedToast, passingTimeout, ToastStack, type ToastCloseReason, type ToastEnvironment } from "./src/lib/toast.ts";

/** A stack's clock and storage, driven by hand. */
function environment(stored = new Map<string, string>()) {
  let time = 0;
  let serial = 0;
  const timers = new Map<number, { at: number; callback: () => void }>();
  const env: ToastEnvironment = {
    storage: { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => { stored.set(key, value); } },
    now: () => time,
    setTimer: (callback, delay) => { timers.set(++serial, { at: time + delay, callback }); return serial; },
    clearTimer: (handle) => { timers.delete(handle as number); },
  };
  return {
    env,
    stored,
    pending: () => timers.size,
    advance(ms: number) {
      time += ms;
      for (const [handle, timer] of [...timers].sort((a, b) => a[1].at - b[1].at)) {
        if (timer.at > time || !timers.has(handle)) continue;
        timers.delete(handle);
        timer.callback();
      }
    },
  };
}

test("toasts stack oldest first, and showing an id that is up updates it in place", () => {
  const { env } = environment();
  const seen: string[][] = [];
  const stack = new ToastStack(env, (toasts) => seen.push(toasts.map((toast) => toast.message)));
  const first = stack.show({ message: "one" });
  const second = stack.show({ id: "two", message: "two" });
  stack.show({ message: "three" });
  assert.notEqual(first, second);
  assert.deepEqual(stack.toasts.map((toast) => toast.message), ["one", "two", "three"]);
  stack.show({ id: "two", message: "two, again" });
  assert.deepEqual(stack.toasts.map((toast) => toast.message), ["one", "two, again", "three"]);
  assert.deepEqual(seen.at(-1), ["one", "two, again", "three"]);
  const [toast] = stack.toasts;
  assert.equal(toast.tone, "info");
  assert.equal(toast.dismissLabel, "Dismiss");
  assert.deepEqual(toast.actions, []);
});

test("the reader's dismissal sticks under its key; the caller closing it does not", () => {
  const { env, stored } = environment();
  const reasons: ToastCloseReason[] = [];
  const stack = new ToastStack(env);
  stack.show({ id: "notice", message: "m", persist: "k", onclose: (reason) => reasons.push(reason) });
  stack.close("notice");
  assert.equal(stack.toasts.length, 0);
  stack.show({ id: "notice", message: "m", persist: "k", onclose: (reason) => reasons.push(reason) });
  assert.equal(stack.toasts.length, 1, "a caller's close records nothing");
  stack.dismiss("notice");
  assert.deepEqual(reasons, ["caller", "dismiss"]);
  assert.deepEqual(JSON.parse(stored.get(dismissedKey)!), ["k"]);
  stack.show({ id: "notice", message: "m", persist: "k" });
  assert.equal(stack.toasts.length, 0, "a dismissed key shows nothing");
  // Another page of the help reads the same storage.
  const later = new ToastStack(env);
  later.show({ message: "m", persist: "k" });
  later.show({ message: "m", persist: "other" });
  assert.deepEqual(later.toasts.map((toast) => toast.persist), ["other"]);
  // Closing what is not up does nothing.
  later.close("missing");
  later.dismiss("missing");
});

test("an action runs, then closes its toast as a dismissal unless it keeps it open", () => {
  const { env, stored } = environment();
  const ran: string[] = [];
  const reasons: ToastCloseReason[] = [];
  const stack = new ToastStack(env);
  const id = stack.show({
    message: "m",
    persist: "acted",
    actions: [{ label: "Stay", run: () => ran.push("stay"), keepOpen: true }, { label: "Go", run: () => ran.push("go") }],
    onclose: (reason) => reasons.push(reason),
  });
  stack.act(id, 0);
  assert.equal(stack.toasts.length, 1);
  stack.act(id, 5);
  stack.act(id, 1);
  assert.deepEqual(ran, ["stay", "go"]);
  assert.deepEqual(reasons, ["action"]);
  assert.equal(stack.toasts.length, 0);
  assert.deepEqual(JSON.parse(stored.get(dismissedKey)!), ["acted"]);
});

test("a timeout hides a toast, held while it is pointed at or focused; without one it stays", () => {
  const clock = environment();
  const reasons: ToastCloseReason[] = [];
  const stack = new ToastStack(clock.env);
  const timed = stack.show({ message: "timed", timeout: 1000, persist: "t", onclose: (reason) => reasons.push(reason) });
  stack.show({ message: "stays" });
  assert.equal(clock.pending(), 1, "only the timed toast arms a timer");
  clock.advance(600);
  stack.hold(timed, true);
  clock.advance(5000);
  assert.equal(stack.toasts.length, 2, "held, it does not time out");
  stack.hold(timed, false);
  clock.advance(399);
  assert.equal(stack.toasts.length, 2, "released, it keeps the 400 ms it had left");
  clock.advance(1);
  assert.deepEqual(stack.toasts.map((toast) => toast.message), ["stays"]);
  assert.deepEqual(reasons, ["timeout"]);
  assert.equal(clock.stored.get(dismissedKey), undefined, "a timeout is not the reader's dismissal");
  clock.advance(60_000);
  assert.equal(stack.toasts.length, 1);
  assert.equal(clock.pending(), 0);
});

test("updating a toast keeps its clock; closing one disarms it", () => {
  const clock = environment();
  const stack = new ToastStack(clock.env);
  const id = stack.show({ id: "saved", message: "Saved", timeout: 1000 });
  clock.advance(700);
  stack.show({ id, message: "Saved again", timeout: 1000 });
  clock.advance(300);
  assert.equal(stack.toasts.length, 0, "the same timeout keeps counting");
  stack.show({ id, message: "Saved", timeout: 1000 });
  stack.show({ id, message: "Saved", timeout: 2000 });
  clock.advance(1500);
  assert.equal(stack.toasts.length, 1, "a new timeout restarts the clock");
  stack.close(id);
  assert.equal(clock.pending(), 0);
  // A toast pointed at before it gains a timeout starts held.
  stack.show({ id, message: "Saved" });
  stack.hold(id, true);
  stack.show({ id, message: "Saved", timeout: 100 });
  clock.advance(500);
  assert.equal(stack.toasts.length, 1);
  stack.hold(id, false);
  clock.advance(100);
  assert.equal(stack.toasts.length, 0);
});

test("stored dismissals stay bounded, a malformed store is ignored, and a refusing one still holds them for the page", () => {
  const { env, stored } = environment(new Map([[dismissedKey, "{not json"]]));
  const stack = new ToastStack(env);
  stack.show({ message: "m", persist: "first" });
  assert.equal(stack.toasts.length, 1);
  for (let index = 0; index < dismissedLimit + 5; index += 1) stack.dismiss(stack.show({ message: "m", persist: `key-${index}` }));
  const keys = JSON.parse(stored.get(dismissedKey)!) as string[];
  assert.equal(keys.length, dismissedLimit);
  assert.equal(keys.at(-1), `key-${dismissedLimit + 4}`);
  stored.set(dismissedKey, JSON.stringify([1, "key-x", null]));
  stack.show({ message: "m", persist: "key-x" });
  assert.equal(stack.toasts.filter((toast) => toast.persist === "key-x").length, 0);

  const refusing = new ToastStack({ ...env, storage: { getItem: () => null, setItem: () => { throw new Error("quota"); } } });
  refusing.dismiss(refusing.show({ message: "m", persist: "private" }));
  refusing.show({ message: "m", persist: "private" });
  assert.equal(refusing.toasts.length, 0);
});

test("a toast of a group replaces the group's last one, as a new toast; clearing a group closes it", () => {
  const { env } = environment();
  const reasons: ToastCloseReason[] = [];
  const stack = new ToastStack(env);
  stack.show({ id: "docs-fresh", message: "notice" });
  const first = stack.show({ ...copiedToast("the code block"), onclose: (reason) => reasons.push(reason) });
  const second = stack.show(copyFailedToast("the code block"));
  assert.notEqual(first, second, "each report is a new toast, announced afresh");
  assert.deepEqual(reasons, ["replaced"]);
  stack.show(failedToast("refresh", "Refresh failed."));
  assert.deepEqual(stack.toasts.map((toast) => toast.group ?? toast.id), ["docs-fresh", "copy", "refresh"], "other groups stay");
  stack.clear("copy");
  assert.deepEqual(stack.toasts.map((toast) => toast.group ?? toast.id), ["docs-fresh", "refresh"]);
  stack.clear("missing");
});

test("confirmations share one wording and clock, and failures stay until dismissed", () => {
  const copied = copiedToast("the code block");
  assert.equal(copied.message, "Copied the code block.");
  assert.equal(copied.timeout, passingTimeout);
  assert.equal(copied.tone, "success");
  assert.equal(doneToast("refresh", "Refreshed.").timeout, passingTimeout);
  const failed = copyFailedToast("register a", "Expand it and select its text instead.");
  assert.equal(failed.message, "Could not copy register a. Expand it and select its text instead.");
  assert.equal(failed.group, copied.group, "the next copy replaces a failed one");
  assert.equal(failed.timeout, undefined);
  assert.equal(failed.tone, "error");
  assert.deepEqual(failed.icon, { name: "warning", label: "Error" }, "a failure says so to a screen reader too");
  assert.match(copyFailedToast("the record").message, /instead\.$/);
});

test("configuration diagnostics speak up when they appear, change or clear, not on the first snapshot", () => {
  let shown = 0;
  const show = () => { shown += 1; };
  const one = "[Flash]\nConfig error\n- flash.toml:3: unknown key `mod`";
  const two = "[Flash]\nConfig errors\n- flash.toml:3: unknown key `mod`\n- flash.toml:9: bad colour";
  assert.equal(configToast(undefined, one, show), undefined, "the first snapshot says nothing");
  assert.equal(configToast(undefined, null, show), undefined);
  assert.equal(configToast(one, one, show), undefined);
  assert.equal(configToast(null, null, show), undefined);
  const appeared = configToast(null, one, show)!;
  assert.equal(appeared.message, "The configuration has an error: flash.toml:3: unknown key `mod`");
  assert.equal(appeared.tone, "error");
  assert.equal(appeared.timeout, undefined);
  appeared.actions![0].run();
  assert.equal(shown, 1);
  assert.equal(configToast(one, two, show)!.message, "The configuration has errors: flash.toml:3: unknown key `mod` …");
  assert.equal(configToast(null, "garbled", show)!.message, "The configuration has errors.");
  const cleared = configToast(two, null, show)!;
  assert.equal(cleared.message, "The configuration loads without errors again.");
  assert.equal(cleared.group, appeared.group, "clearing replaces the failure");
  assert.equal(cleared.timeout, passingTimeout);
});

test("the new pages notice sticks dismissed until the documentation itself changes", () => {
  const doc = (name: string, body: string) => ({ name, hash: hashBody(body) });
  const docs = [doc("a", "x"), doc("b", "y")];
  const key = readingKey(docs);
  assert.equal(readingKey([...docs].reverse()), key, "order does not matter");
  assert.notEqual(readingKey([doc("a", "x"), doc("b", "y!")]), key, "an edit does");
  assert.notEqual(readingKey([...docs, doc("c", "")]), key, "a new page does");
  let read = 0;
  const notice = freshNotice(key, () => { read += 1; });
  assert.equal(notice.persist, `docs-fresh:${key}`);
  assert.equal(notice.timeout, undefined, "it stays until read or dismissed");
  assert.deepEqual(notice.icon, { name: "sparkle", label: "New or updated" });
  assert.equal(notice.message, "marks what is new or updated since your last visit.");
  assert.deepEqual(notice.actions?.map((action) => action.label), ["Mark all as read"]);
  const { env } = environment();
  const stack = new ToastStack(env);
  stack.act(stack.show(notice), 0);
  assert.equal(read, 1);
  assert.equal(stack.toasts.length, 0, "Mark all as read dismisses it");
});

// The components, rendered on the server as the published site renders them.

let server: ViteDevServer;
type Load = <T>(path: string) => Promise<T>;
let load: Load;

before(async () => {
  const { createServer } = await import("vite");
  const { svelte } = await import("@sveltejs/vite-plugin-svelte");
  server = await createServer({
    root: import.meta.dirname,
    configFile: false,
    logLevel: "silent",
    appType: "custom",
    plugins: [svelte()],
    server: { middlewareMode: true, hmr: false, ws: false },
  });
  load = <T>(path: string) => server.ssrLoadModule(path) as Promise<T>;
});
after(async () => { await server?.close(); });

type Render = (component: unknown, options?: { props?: Record<string, unknown> }) => { body: string };
type Stack = { toasts: ToastStack };

async function renderToaster(): Promise<string> {
  const { render } = await load<{ render: Render }>("svelte/server");
  const { default: Toaster } = await load<{ default: unknown }>("/src/lib/Toaster.svelte");
  return render(Toaster).body;
}

test("an empty toaster is a polite live region, and no landmark", async () => {
  const html = await renderToaster();
  assert.match(html, /<section class="toaster[^"]*">/);
  assert.doesNotMatch(html, /aria-label="Notifications"/);
  assert.match(html, /<div class="stack[^"]*" role="status" aria-live="polite" aria-atomic="false" aria-relevant="additions text">\s*(<!--[^>]*-->\s*)*<\/div>/);
  assert.doesNotMatch(html, /data-toast/);
});

test("toasts render in order with their icon, message, actions and dismiss control", async () => {
  const { toasts } = await load<Stack>("/src/lib/toasts.svelte.ts");
  const first = toasts.show({ message: "Copied <b>the</b> snippet", icon: { name: "check" }, tone: "success" });
  const second = toasts.show({ message: "marks what is new.", icon: { name: "sparkle", label: "New or updated" }, tone: "fresh", actions: [{ label: "Mark all as read", run: () => {} }], dismissLabel: "Dismiss the notice" });
  try {
    const html = await renderToaster();
    assert.match(html, /<section class="toaster[^"]*" aria-label="Notifications">/);
    const found = [...html.matchAll(/data-toast="([^"]+)"/g)].map((match) => match[1]);
    assert.deepEqual(found, [first, second], "oldest first, the newest nearest the corner");
    const [one, two] = html.split(/(?=<div class="toast )/).slice(1);
    assert.match(one, /class="toast tone-success[^"]*" role="group" aria-labelledby="([^"]+)-message"/);
    const labelled = one.match(/aria-labelledby="([^"]+)"/)![1];
    assert.match(one, new RegExp(`<p class="message[^"]*" id="${labelled}">`), "the message names the toast");
    assert.match(one, /Copied &lt;b>the&lt;\/b> snippet/, "a message is text, never markup");
    assert.match(one, /<span class="icon[^"]*" aria-hidden="true">/, "an unlabelled icon is decoration");
    assert.doesNotMatch(one, /<div class="actions/);
    assert.match(one, /<button type="button" class="dismiss[^"]*" aria-label="Dismiss" title="Dismiss">/);
    assert.match(two, /class="toast tone-fresh/);
    assert.match(two, /<span class="icon[^"]*" role="img" aria-label="New or updated" title="New or updated">/);
    assert.match(two, /<button type="button"[^>]*>Mark all as read<\/button>/);
    assert.match(two, /aria-label="Dismiss the notice"/);
    assert.notEqual(labelled, two.match(/aria-labelledby="([^"]+)"/)![1], "each toast has its own ids");
  } finally {
    toasts.close(first);
    toasts.close(second);
  }
});
