import { copiedToast, copyFailedToast, ToastStack, type Toast } from "./toast";

/**
 * The page's one stack of toasts, drawn by `Toaster.svelte` in the app shell.
 * A caller shows a toast and closes it when what it says stops being true,
 * and when the caller itself goes away, so no action outlives its owner.
 */
let current = $state.raw<readonly Toast[]>([]);

function browserStorage(): Storage | undefined {
  try {
    // A server render has no browser storage (and Node warns on a look).
    return typeof window === "undefined" || typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

export const toasts = new ToastStack(
  {
    storage: browserStorage(),
    now: () => performance.now(),
    setTimer: (callback, delay) => setTimeout(callback, delay),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout> | undefined),
  },
  (next) => { current = next; },
);

/** The toasts up now, oldest first. */
export const toastList = {
  get current(): readonly Toast[] { return current; },
};

/**
 * Copies text to the clipboard and says so in a toast, `Copied <subject>.`;
 * a browser that refuses gets the failure and `hint`, how to copy by hand.
 */
export async function copyText(text: string, subject: string, hint?: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    toasts.show(copiedToast(subject));
    return true;
  } catch {
    toasts.show(copyFailedToast(subject, hint));
    return false;
  }
}
