import { createSubscriber } from "svelte/reactivity";

// The browser's wall clock, ticking once a second only while something on the
// page reads it. Durations such as uptime are derived here from the start
// times Flash pushes, so the resident needs no clock of its own.
const tick = createSubscriber((update) => {
  const id = setInterval(update, 1000);
  return () => clearInterval(id);
});

export function now(): number {
  tick();
  return Date.now();
}
