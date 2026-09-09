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
bypasses that minimum interval: it wakes 250 ms before the model's 1.5-second
freshness ceiling, then uses the same 80-ms debounce. The lead allows eligible
cheap walks to finish before the current model expires. A newer completed
model replaces the prior maintenance ticket even when its dirty token and
configuration revision are unchanged.

AX storms and automatic walks taking at least 50 ms suppress AX, queued, and
maintenance warming. Focus and configuration requests can reassess those apps;
explicit activation remains available and complete. Suppression, invalidation,
termination, and shutdown revoke the applicable tickets. No timer is a second
source of model validity: maintenance also rechecks focus, dirty token, and
configuration before requesting a refresh.
