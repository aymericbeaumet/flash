# Prepared hint models

`AppMonitor` prepares complete hint models for the focused app. Each model
carries the app's dirty token, configuration revision, and completion time.
Lookup and publication check those identities; invalid or stale models are
never served. Activation can run a complete walk on demand. Background work
never publishes a partial walk or changes provider ordering.

`PreparedModelScheduler` owns refresh and maintenance tickets on the main
thread. It takes uptime explicitly, so its timing policy is tested with a fake
clock. One refresh wake coalesces a burst; further events extend its deadline.
An earlier focus, configuration, or user-action request replaces a throttled
wake with a new ticket. Later noisy events cannot demote that request. Each
callback must consume its own ticket, so a cancelled or replaced callback
cannot clear or execute newly scheduled work for the same PID.

AX and queued refreshes debounce for 80 ms and observe a 2.5-second minimum
interval between automatic walks. Maintenance has a separate identity and
bypasses that minimum interval: it wakes 250 ms before the model's freshness
ceiling, then uses the same 80-ms debounce. Each model carries its own
ceiling: it starts at 1.5 s and doubles (up to 30 s) every time a maintenance
walk reproduces the previous model unchanged — same dirty token,
configuration revision, and target geometry/role digest — and resets to 1.5 s
on any other outcome. A maintenance wake is skipped outright after 60 s
without keyboard or pointer input; the model then expires and the next
activation walks on demand.

Maintenance is the one self-renewing wake — each stored model arms the next —
so it is a deadline registration on the shared `PollScheduler`
(`core:prepared_model_maintenance`) rather than a timer of its own: it
coalesces with the process's other wake-ups and is held while the displays
sleep or the session is locked. Only the frontmost app's model is stored, so
one registration serves, and a cancelled maintenance releases it. Its
`.normal` priority allows 100 ms of slack, inside the 250-ms lead, so a late
wake still starts before the ceiling. Debounce and readiness wakes stay
bounded one-shots on the main queue. The lead allows eligible
cheap walks to finish before the current model expires. A newer completed
model replaces the prior maintenance ticket even when its dirty token and
configuration revision are unchanged.

AX observer sources are hosted on a dedicated `AXObserverThread`; callbacks
enqueue and the main thread drains each burst in one hop, bumping every dirty
token in arrival order. AX storms and automatic walks taking at least 50 ms
suppress AX, queued, and maintenance warming. Focus and configuration requests can reassess those apps;
explicit activation remains available and complete. A degenerate walk (see
below) is fast because there was nothing to read, so it never lifts the
slow-walk suppression. Suppression, invalidation,
termination, and shutdown revoke the applicable tickets. No timer is a second
source of model validity: maintenance also rechecks focus, dirty token, and
configuration before requesting a refresh.

## Trees that are not built yet

Chromium and Flutter build their accessibility tree asynchronously after the
enhanced-UI wake, and Gecko once its tree is read
(`AppTraits.buildsAccessibilityTreeAsynchronously`). A walk that runs first finds an empty
or half-built tree in a few milliseconds and yields a *degenerate* result:
empty, or below a tenth of the app's last healthy count
(`discoveryLooksDegenerate`). The healthy count is recorded from activations
and from stored background walks that are not degenerate, and forgotten when
the app quits.

Readiness is decided by a bounded probe, `AccessibilityReadiness`: one
batched read (role and children) per element, breadth-first under the walked
window, at most 32 elements, descending only into containers. A web area with
children is ready and an empty one is not; without a web area in reach, a
window with more than five direct children, or a tree larger than the probe
reads, is ready. The probe runs on the AX queue (Gecko inside
`GeckoAccessibility.withTree`) and never decides the hints; it only decides
when the one walk that follows is worth doing. Waits between probes follow
`ReadinessLadder`: 50, 100, 200, 400 ms, then a final 750 ms after which the
walk runs regardless, 1.5 s at most. Every wait is an `asyncAfter` re-dispatch; nothing sleeps on
the main thread or the AX queue.

- **Focus.** A focus change wakes a Chromium or Flutter app at once, then,
  for any runtime above, replaces the focus walk with a readiness ladder whose
  last step requests it. While a ladder is pending or its probe is in flight,
  speculative walks (AX events, queued, maintenance) are held back: they would
  read the tree the ladder waits for.
- **Background.** A degenerate automatic walk of an app with a healthy count
  arms a ladder ending in a `readiness` refresh. That reason is owed, not
  speculative, so event storms and the slow-walk backoff do not suppress it,
  and it is bounded to two ladders per focus. An app whose tree is built on
  demand skips the probes and is simply walked again.
- **Activation.** Activation never waits on a background ladder: its walk
  cancels it. A degenerate activation walk is repaired by one extra walk,
  after the same ladder for these runtimes, after 150 ms for the rest, and
  the fuller result is served. A repair walk whose model comes back invalid
  (the tree changed while it was read) hands the activation a direct walk
  rather than the degenerate first result. The activation going away ends a
  climb.

Gecko discards its tree whenever its accessibility mode is switched off, so
switching it off after every operation makes walks and probes wake a tree that
may not be built yet — the Firefox background walks that come back empty in
1–5 ms. The mode Flash turns on therefore stays on while the app is focused
(`GeckoAccessibility`; see [runtime ownership](architecture.md)): one wake per
focus builds the tree, the ladder's probes watch that same tree fill, and
later walks read it built, the two Gecko scopes of one walk (the walked
window's frame, then the tree) included. Focus leaving the app, a Space change
and every window move switch it off, so the first walk after one of those can
still find the tree unbuilt, and is repaired as above.

A readiness step has its own ticket kind beside refresh and maintenance. A
probe holds the ticket while it runs, and its verdict applies only if the hold
survives: focus leaving the app, a walk starting, termination, a newer
ladder or `cancelRefreshWork` revoke it.

## Apps whose own tree has nothing

A volatile provider (tmux) owns a terminal's hints; the prepared model is its
Accessibility fallback. When the provider declines and the app's tree has
never produced targets, a degenerate activation walk is the answer: it is not
repeated, and the activation ends silently. After five consecutive empty
automatic walks of an app whose provider plan includes a volatile provider,
the app gets no automatic walks at all — focus, AX events, maintenance,
readiness — until an activation finds targets in its tree, the configuration
changes, or it quits (`EmptyBackgroundWalkGate`, logged once as
`[ax] model_refresh_gated`). The judgement is the walks, never the bundle
identifier: terminals that expose real Accessibility targets keep warming.
