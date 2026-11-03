import Foundation

/// The host's copy of the plugin wire-protocol constants. The single source
/// of truth is `Plugins/_flash_plugin_rust/protocol.json`;
/// `PluginProtocolParityTests` reads that file and asserts every value here
/// equals it, so a drift fails the build instead of shipping a skewed host.
enum PluginProtocol {
  /// The ONLY protocol version the host speaks, echoed exactly by every
  /// plugin at initialize. Features are manifest declarations — there is no
  /// per-feature wire negotiation.
  static let version = 1

  // MARK: - Deadlines (milliseconds)

  /// `initialize` reply budget. Config `[plugins] startup_timeout` tunes the
  /// live value (FlashTunables); this is the spec default it mirrors.
  static let startupDeadlineMs = 5_000
  /// Per-keystroke `evaluate`.
  static let queryDeadlineMs = 50
  /// Activation `hints` pull. Blocks the AX queue ahead of the prepared
  /// model, so it is a fixed latency ceiling rather than a config knob.
  static let hintsDeadlineMs = 500
  /// Letter-search `text_grid` pull. Asked asynchronously, but the search
  /// waits on it, so it shares the `hints` ceiling.
  static let textGridDeadlineMs = 500
  /// All three `perform` kinds.
  static let performDeadlineMs = 10_000
  /// Reply budget for the idle-liveness `ping`; ONE miss tears down.
  static let pingDeadlineMs = 10_000
  /// Inbound silence (with nothing in flight) before the host pings.
  static let idleBeforePingMs = 60_000
  /// stdin-close → SIGTERM; +500 ms → SIGKILL.
  static let shutdownGraceMs = 1_000

  // MARK: - Quotas (atomic rejection: any violation rejects the whole payload)

  static let maxFrameBytes = 10 * 1024 * 1024
  static let maxCatalogRows = 10_000
  static let maxCatalogBytes = 4 * 1024 * 1024
  static let maxTitleBytes = 4 * 1024
  static let maxURLBytes = 16 * 1024
  static let maxMetadataEntries = 64
  static let maxMetadataKeyBytes = 256
  static let maxMetadataValueBytes = 64 * 1024
  static let maxEffectTextBytes = 64 * 1024
  static let maxAnswers = 16
  static let maxAnswersBytes = 256 * 1024
  static let maxAnswerFieldBytes = 16 * 1024
  static let maxFetchResponseBytes = 1_048_576
  static let fetchTimeoutMs = 8_000
  /// Columns and rows of a `text_grid` reply are each at most this.
  static let maxTextGridDimension = 10_000

  // MARK: - host.applescript bounds (`applescript` in protocol.json)

  /// UTF-8 bytes of one script's source.
  static let maxAppleScriptScriptBytes = 64 * 1024
  /// UTF-8 bytes of a script's result text; a larger result fails whole.
  static let maxAppleScriptResultBytes = 1_048_576
  /// A call without `timeout_ms`.
  static let appleScriptDefaultTimeoutMs = 10_000
  /// The largest `timeout_ms` a plugin may ask for.
  static let appleScriptMaxTimeoutMs = 30_000
  /// Scripts of one plugin running at once; the next waits for a slot
  /// within its own timeout.
  static let appleScriptConcurrency = 4

  // MARK: - Poll registrations

  /// A priority a plugin may name in a `poll` registration, and the slack it
  /// maps to on the shared clock. The core-only `system` is not one of them.
  struct PollPriority: Equatable {
    let name: String
    let scheduler: PollScheduler.Priority
  }

  static let pollPriorities = [
    PollPriority(name: "high", scheduler: .high),
    PollPriority(name: "normal", scheduler: .normal),
    PollPriority(name: "low", scheduler: .low),
  ]
  /// Ceiling on `every` and `after`, in seconds; it also keeps the
  /// millisecond conversion far from overflow.
  static let pollMaxSeconds = 86_400
  static let pollMaxRegistrations = 64
  static let pollMaxNameBytes = 64

  // MARK: - Transport admission (per child)

  static let maxPendingRequests = 64
  static let maxHostRPCs = 64
  static let maxOutboundFrames = 256
  static let maxOutboundBytes = 20 * 1_024 * 1_024
  static let maxInboundFrames = 256
  static let maxInboundBytes = 20 * 1_024 * 1_024

  // MARK: - Host events

  /// Every `core:*` event the host delivers, in contract order.
  static let hostEvents = HostEvent.allCases.map(\.rawValue)

  /// State signals whose latest value supersedes every earlier one, in
  /// contract order (`host_events.replacement`).
  static let replacementEvents = HostEvent.allCases.filter(\.supersedesEarlier).map(\.rawValue)
  private static let replacementEventNames = Set(replacementEvents)

  /// Which earlier unsent event `name` supersedes; nil when it supersedes
  /// none. A replacement event's key is its name, except that
  /// `core:ax.changed` reports one fact per app and notification, so its key
  /// adds the payload `pid` and `notification`: a keystroke's value change
  /// never replaces a pending title change, and no app's event replaces
  /// another's.
  static func coalescingKey(eventName name: String, payload: [String: Any]) -> String? {
    guard replacementEventNames.contains(name) else { return nil }
    guard name == HostEvent.axChanged.rawValue else { return name }
    let pid = PluginJSON.pid(payload["pid"]).map(String.init) ?? ""
    let notification = payload["notification"] as? String ?? ""
    return "\(name)\u{0}\(pid)\u{0}\(notification)"
  }

  // MARK: - Perform

  /// The three `perform` kinds: a published row, a command (a core command
  /// the plugin performs, its own command or a bang) and a route.
  static let performKinds = ["resolve", "command", "navigate"]

  // MARK: - Canonical error strings (spec-pinned EXACT text)

  static func unknownMethodError(_ method: String) -> String {
    "unknown method: \(method)"
  }
  /// Emitted by the plugin, never the host; kept here for spec parity.
  static let protocolMismatchErrorTemplate =
    "protocol version mismatch: host v<H>, plugin v1"
  static let initializeRepeatedError = "initialize may only be called once"
  static let hostClosedError = "host closed stdin"
  static let hostCallTimeoutError = "host call timed out"
  static let frameOverflowError = "response exceeded outbound frame limit"
  static let requestCapacityError = "plugin request capacity exceeded"
  static let hostCallCapacityError = "host call capacity exceeded"
  /// A plugin's read-only handler ran out of the request's `deadline_ms`.
  static let deadlineExceededError = "deadline exceeded"
  static func capabilityDeniedError(_ capability: String) -> String {
    "missing \(capability) capability"
  }
}

/// A `core:*` event the host emits, named once: an emitting site builds a
/// `PluginEvent` from a case, never from a string, so it cannot send a name
/// no plugin or monitor can subscribe to. Raw values are the wire names, in
/// contract order (`protocol.json` `host_events`). Poll ticks
/// (`core:poll:<name>`) are per-registration and stay strings.
enum HostEvent: String, CaseIterable, Sendable {
  case appsChanged = "core:apps.changed"
  case appsLaunched = "core:apps.launched"
  case appsTerminated = "core:apps.terminated"
  case focusChanged = "core:focus.changed"
  case windowFocusChanged = "core:window.focus.changed"
  /// An AX notification of an observed app; payload `{pid, notification,
  /// bundle_id?}`.
  case axChanged = "core:ax.changed"
  case configChanged = "core:config.changed"
  case powerChanged = "core:power.changed"
  /// Network interfaces, addresses, routes or DNS changed; payload `{}`.
  case networkChanged = "core:network.changed"
  /// A volume mounted, unmounted or was renamed; payload `{}`.
  case volumesChanged = "core:volumes.changed"
  case statusObserved = "core:status.observed"
  case sessionOpened = "core:session.opened"
  case systemSlept = "core:system.slept"
  case systemWoke = "core:system.woke"
  case displaysSlept = "core:displays.slept"
  case displaysWoke = "core:displays.woke"
  case screenLocked = "core:screen.locked"
  case screenUnlocked = "core:screen.unlocked"
  case displaysChanged = "core:displays.changed"
  case spaceChanged = "core:space.changed"
  /// Nobody touched the keyboard, mouse or trackpad for `seconds`, one of
  /// the subscribers' idle thresholds; payload `{seconds}`.
  case userIdle = "core:user.idle"
  /// Input came back after an announced idle episode; payload
  /// `{idle_seconds}`.
  case userActive = "core:user.active"
  /// A USB device was connected; payload `{vendor_id?, product_id?, name?}`.
  case usbAttached = "core:usb.attached"
  /// A USB device was removed; the same payload.
  case usbDetached = "core:usb.detached"
  /// A minute of the wall clock began: every one for a plugin, an event
  /// monitor's `at` times for it; payload `{time, weekday, date,
  /// late_seconds}`.
  case clockMinute = "core:clock.minute"
  /// The focused tiling workspace changed; payload `{workspace, previous?,
  /// workspaces}`. Only while `[tiling]` is on.
  case workspaceChanged = "core:workspace.changed"
  /// Flash's mode changed; payload `{mode, previous, layer?}`, each mode
  /// named as `resident status` names it (`normal`, `insert`, `command`,
  /// `terminal`, `hyper`, `hold`, `layer`, `disabled`).
  case modeChanged = "core:mode.changed"
  /// A hint session drew its first labels; payload `{surface, targets}`.
  case hintsShown = "core:hints.shown"
  /// A hint session committed a target; payload `{surface}`. Never which
  /// target, its text or its label.
  case hintsCommitted = "core:hints.committed"
  /// A hint session ended without committing; payload `{surface}`.
  case hintsCancelled = "core:hints.cancelled"
  /// A value monitor rose into warning or error; payload `{monitor,
  /// level}`. Never the value.
  case monitorTriggered = "core:monitor.triggered"

  /// A state signal whose latest value supersedes every earlier one
  /// (`host_events.replacement`): a plugin's queue keeps only the newest.
  var supersedesEarlier: Bool {
    switch self {
    case .appsChanged, .focusChanged, .windowFocusChanged, .axChanged, .configChanged,
      .powerChanged, .networkChanged, .volumesChanged, .statusObserved, .spaceChanged,
      .workspaceChanged, .modeChanged:
      return true
    case .appsLaunched, .appsTerminated, .sessionOpened, .systemSlept, .systemWoke,
      .displaysSlept, .displaysWoke, .screenLocked, .screenUnlocked, .displaysChanged,
      .userIdle, .userActive, .usbAttached, .usbDetached, .clockMinute, .hintsShown,
      .hintsCommitted, .hintsCancelled, .monitorTriggered:
      return false
    }
  }

  /// Whether the IPC event stream carries it (`IPCProtocol.streamedEvents`):
  /// every event `AppDelegate.emitHostEvent` sends. The plugin plumbing a
  /// plugin alone hears never leaves the process: the running-apps
  /// snapshot a plugin's catalog keys on (`core:apps.launched` and
  /// `core:apps.terminated` report the changes), an observed app's AX
  /// notifications (every keystroke posts one), the flashlight opening, and
  /// which of a plugin's own segments a surface shows.
  var isStreamed: Bool {
    switch self {
    case .appsChanged, .axChanged, .sessionOpened, .statusObserved:
      return false
    case .appsLaunched, .appsTerminated, .focusChanged, .windowFocusChanged,
      .configChanged, .powerChanged, .networkChanged, .volumesChanged, .systemSlept,
      .systemWoke, .displaysSlept, .displaysWoke, .screenLocked, .screenUnlocked,
      .displaysChanged, .spaceChanged, .userIdle, .userActive, .usbAttached, .usbDetached,
      .clockMinute, .workspaceChanged, .modeChanged, .hintsShown, .hintsCommitted,
      .hintsCancelled, .monitorTriggered:
      return true
    }
  }
}
