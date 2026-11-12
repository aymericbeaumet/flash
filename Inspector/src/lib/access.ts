// The help server answers its data only with your access token (`HelpAccess`
// in Flash): the loopback address is shared by every account and process on
// the Mac. Flash opens the page with `?token=`; the page keeps it in
// localStorage, which is per origin and so per port (a cookie would reach
// every port of the host), drops it from the address, and sends it with every
// data request.

const storageKey = "flash.help.token";
const queryName = "token";
const wellFormed = /^[0-9a-f]{64}$/;

export interface AccessStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function defaultStore(): AccessStore | null {
  try { return globalThis.localStorage ?? null; } catch { return null; }
}

/** Keeps the token the address arrived with and returns the address without
 * it; an address without one is returned as it is. */
export function adopt(href: string, store: AccessStore | null = defaultStore()): string {
  const url = new URL(href);
  if (!url.searchParams.has(queryName)) return href;
  const token = url.searchParams.get(queryName) ?? "";
  if (wellFormed.test(token)) store?.setItem(storageKey, token);
  url.searchParams.delete(queryName);
  return url.toString();
}

export function token(store: AccessStore | null = defaultStore()): string | null {
  const value = store?.getItem(storageKey) ?? null;
  return value && wellFormed.test(value) ? value : null;
}

/** Only Flash's own data endpoints get the token: never the published
 * manual, never another origin. */
export function isDataEndpoint(url: string): boolean {
  return url === "/api" || url.startsWith("/api/") || url.startsWith("/api?");
}

/** `url` carrying the token, for what cannot send a header: an event
 * stream, an image. */
export function withToken(url: string, value: string | null = token()): string {
  if (!value || !isDataEndpoint(url)) return url;
  return `${url}${url.includes("?") ? "&" : "?"}${queryName}=${value}`;
}

/** `headers` with the token, for a request to a data endpoint. */
export function authorize(url: string, headers?: HeadersInit, value: string | null = token()): Headers {
  const result = new Headers(headers);
  if (value && isDataEndpoint(url)) result.set("Authorization", `Bearer ${value}`);
  return result;
}
