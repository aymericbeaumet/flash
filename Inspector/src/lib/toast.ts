/**
 * Toasts: short notices in the bottom-right corner that need no answer and
 * never take focus. Several stack, oldest first. Every toast has a dismiss
 * control (Escape inside it too), may offer actions, may stick dismissed
 * under a key, and may hide itself after a while. `toasts.svelte.ts` holds
 * the page's one stack and `Toaster.svelte` draws it; this module is the
 * stack itself, with its clock and storage handed in so tests drive both,
 * and the help's shared wording for what its pages report.
 */

/** Tints the icon and the leading edge: brass, the ✨ amber, verdigris or oxide red. */
export type ToastTone = "info" | "fresh" | "success" | "error";

export interface ToastIcon {
  /** An `Icon.svelte` name. */
  name: string;
  /** Read as part of the message when set; otherwise the icon is decoration. */
  label?: string;
}

export interface ToastAction {
  label: string;
  run: () => void;
  /** Leave the toast up after the action runs; by default it closes. */
  keepOpen?: boolean;
}

/**
 * Why a toast left: the reader dismissed it, took an action, it timed out,
 * the next toast of its group replaced it, or its caller closed it.
 */
export type ToastCloseReason = "dismiss" | "action" | "timeout" | "replaced" | "caller";

export interface ToastOptions {
  /** Showing an id that is already up updates that toast in place; otherwise each show adds one. */
  id?: string;
  /**
   * Showing a toast of a group closes the group's other toasts first, so
   * repeated events (each copy, each failed refresh) never pile up and each
   * is announced afresh.
   */
  group?: string;
  message: string;
  icon?: ToastIcon;
  tone?: ToastTone;
  actions?: ToastAction[];
  /** The dismiss control's accessible name. */
  dismissLabel?: string;
  /**
   * A dismissal by the reader (the dismiss control, Escape or an action)
   * sticks under this key in the browser's storage: showing the key again
   * does nothing. A timeout or the caller closing it records nothing.
   */
  persist?: string;
  /** Hide after this many milliseconds on screen, paused while pointed at or focused. Off when unset. */
  timeout?: number;
  onclose?: (reason: ToastCloseReason) => void;
}

export interface Toast {
  id: string;
  group?: string;
  message: string;
  icon?: ToastIcon;
  tone: ToastTone;
  actions: ToastAction[];
  dismissLabel: string;
  persist?: string;
  timeout?: number;
  onclose?: (reason: ToastCloseReason) => void;
}

export interface ToastEnvironment {
  storage?: Pick<Storage, "getItem" | "setItem">;
  now: () => number;
  setTimer: (callback: () => void, delay: number) => unknown;
  clearTimer: (handle: unknown) => void;
}

/** Where dismissals stick, newest last. */
export const dismissedKey = "flash.help.dismissed-toasts";
/** Dismissals kept: enough for every notice the help shows, bounded so the list never grows. */
export const dismissedLimit = 32;

interface Clock {
  /** Time left on screen; it counts down only while the toast is not held. */
  remaining: number;
  started: number;
  handle?: unknown;
}

export class ToastStack {
  private list: Toast[] = [];
  private clocks = new Map<string, Clock>();
  /** Toasts the reader is pointing at or has focused. */
  private held = new Set<string>();
  /** Dismissals of this page, for when the browser's storage refuses them. */
  private session = new Set<string>();
  private serial = 0;
  private readonly env: ToastEnvironment;
  private readonly changed: (toasts: readonly Toast[]) => void;

  constructor(env: ToastEnvironment, changed: (toasts: readonly Toast[]) => void = () => {}) {
    this.env = env;
    this.changed = changed;
  }

  get toasts(): readonly Toast[] {
    return this.list;
  }

  /**
   * Shows a toast and returns its id. An id already up is updated in place,
   * keeping its position and, unless the timeout changed, its clock. A
   * dismissed `persist` key shows nothing (and closes the id if it is up).
   */
  show(options: ToastOptions): string {
    const id = options.id ?? `toast-${++this.serial}`;
    if (options.persist !== undefined && this.isDismissed(options.persist)) {
      this.close(id);
      return id;
    }
    if (options.group !== undefined) {
      for (const other of this.list.filter((toast) => toast.group === options.group && toast.id !== id)) this.close(other.id, "replaced");
    }
    const toast: Toast = {
      id,
      group: options.group,
      message: options.message,
      icon: options.icon,
      tone: options.tone ?? "info",
      actions: options.actions ?? [],
      dismissLabel: options.dismissLabel ?? "Dismiss",
      persist: options.persist,
      timeout: options.timeout !== undefined && options.timeout > 0 ? options.timeout : undefined,
      onclose: options.onclose,
    };
    const index = this.list.findIndex((candidate) => candidate.id === id);
    const previous = index >= 0 ? this.list[index] : undefined;
    this.list = index >= 0 ? this.list.map((candidate) => (candidate === previous ? toast : candidate)) : [...this.list, toast];
    if (previous?.timeout !== toast.timeout) this.arm(id, toast.timeout);
    this.changed(this.list);
    return id;
  }

  /** The reader dismissed it: closes it and records its `persist` key. */
  dismiss(id: string) {
    this.close(id, "dismiss");
  }

  /** Runs the toast's action at `index`; the toast then closes as a dismissal unless the action keeps it open. */
  act(id: string, index: number) {
    const action = this.list.find((toast) => toast.id === id)?.actions[index];
    if (!action) return;
    action.run();
    if (!action.keepOpen) this.close(id, "action");
  }

  /** Closes a toast; nothing if it is not up. Only the reader's own closes stick. */
  close(id: string, reason: ToastCloseReason = "caller") {
    const toast = this.remove(id);
    if (!toast) return;
    if (toast.persist !== undefined && (reason === "dismiss" || reason === "action")) this.remember(toast.persist);
    toast.onclose?.(reason);
  }

  /** Closes every toast of a group, as its caller: a new try makes the last one's report stale. */
  clear(group: string) {
    for (const toast of this.list.filter((candidate) => candidate.group === group)) this.close(toast.id);
  }

  /** Holds a toast's timeout while the reader points at or focuses it; releasing resumes the time it had left. */
  hold(id: string, held: boolean) {
    if (!this.list.some((toast) => toast.id === id) || this.held.has(id) === held) return;
    if (held) this.held.add(id);
    else this.held.delete(id);
    const clock = this.clocks.get(id);
    if (!clock) return;
    if (held) {
      this.env.clearTimer(clock.handle);
      clock.handle = undefined;
      clock.remaining = Math.max(0, clock.remaining - (this.env.now() - clock.started));
    } else {
      this.start(id, clock);
    }
  }

  private arm(id: string, timeout: number | undefined) {
    const old = this.clocks.get(id);
    if (old) this.env.clearTimer(old.handle);
    this.clocks.delete(id);
    if (timeout === undefined) return;
    const clock: Clock = { remaining: timeout, started: 0 };
    this.clocks.set(id, clock);
    if (!this.held.has(id)) this.start(id, clock);
  }

  private start(id: string, clock: Clock) {
    clock.started = this.env.now();
    clock.handle = this.env.setTimer(() => {
      // A timer outlived by a replacement clock must not close the replacement.
      if (this.clocks.get(id) === clock) this.close(id, "timeout");
    }, clock.remaining);
  }

  private remove(id: string): Toast | undefined {
    const toast = this.list.find((candidate) => candidate.id === id);
    if (!toast) return undefined;
    const clock = this.clocks.get(id);
    if (clock) this.env.clearTimer(clock.handle);
    this.clocks.delete(id);
    this.held.delete(id);
    this.list = this.list.filter((candidate) => candidate !== toast);
    this.changed(this.list);
    return toast;
  }

  private isDismissed(key: string): boolean {
    return this.session.has(key) || this.dismissed().includes(key);
  }

  private dismissed(): string[] {
    try {
      const parsed = JSON.parse(this.env.storage?.getItem(dismissedKey) ?? "[]") as unknown;
      return Array.isArray(parsed) ? parsed.filter((key): key is string => typeof key === "string") : [];
    } catch {
      return [];
    }
  }

  private remember(key: string) {
    this.session.add(key);
    const keys = [...this.dismissed().filter((known) => known !== key), key].slice(-dismissedLimit);
    try {
      this.env.storage?.setItem(dismissedKey, JSON.stringify(keys));
    } catch {
      // Private browsing or a full quota keeps the dismissal for this page only.
    }
  }
}

// The help's shared wording: one group per kind of report, confirmations on
// one clock, failures until dismissed.

/** How long a confirmation stays on screen: long enough to read twice. */
export const passingTimeout = 5000;

/** Something the reader asked for worked. */
export function doneToast(group: string, message: string): ToastOptions {
  return { group, message, icon: { name: "check" }, tone: "success", timeout: passingTimeout };
}

/** Something the reader asked for failed: it stays until dismissed, or until the next try of its group. */
export function failedToast(group: string, message: string): ToastOptions {
  return { group, message, icon: { name: "warning", label: "Error" }, tone: "error" };
}

/** A copy to the clipboard worked: `Copied the code block.` */
export function copiedToast(subject: string): ToastOptions {
  return doneToast("copy", `Copied ${subject}.`);
}

/** A copy the browser refused, with how to copy by hand. */
export function copyFailedToast(subject: string, hint = "Select the text and copy it instead."): ToastOptions {
  return failedToast("copy", `Could not copy ${subject}. ${hint}`);
}

/**
 * What a change of the configuration's diagnostics says while the help is
 * open, from Flash's alert text (`[Flash]`, `Config error`, then `- ` lines).
 * The first snapshot says nothing: the resident alerts on its own and the
 * runtime page lists them. New or changed diagnostics are a failure that
 * offers `show`; diagnostics that clear are a confirmation.
 */
export function configToast(previous: string | null | undefined, next: string | null, show: () => void): ToastOptions | undefined {
  if (previous === undefined || previous === next) return undefined;
  if (next === null) return doneToast("config", "The configuration loads without errors again.");
  const lines = next.split("\n");
  const first = lines.find((line) => line.startsWith("- "))?.slice(2).trim();
  const several = lines.filter((line) => line.startsWith("- ")).length > 1;
  const message = first ? `The configuration has ${several ? "errors" : "an error"}: ${first}${several ? " …" : ""}` : "The configuration has errors.";
  return { ...failedToast("config", message), actions: [{ label: "Show", run: show }] };
}
