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
activation walks on demand. The lead allows eligible
cheap walks to finish before the current model expires. A newer completed
model replaces the prior maintenance ticket even when its dirty token and
configuration revision are unchanged.

AX observer sources are hosted on a dedicated `AXObserverThread`; callbacks
enqueue and the main thread drains each burst in one hop, bumping every dirty
token in arrival order. AX storms and automatic walks taking at least 50 ms
suppress AX, queued, and maintenance warming. Focus and configuration requests can reassess those apps;
explicit activation remains available and complete. Suppression, invalidation,
termination, and shutdown revoke the applicable tickets. No timer is a second
source of model validity: maintenance also rechecks focus, dirty token, and
configuration before requesting a refresh.
