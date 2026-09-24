import Foundation

/// One user interaction — a routed key, a hotkey, a pointer click, a CLI
/// verb — named by a short id that every log line it causes carries: the
/// host's own lines, the plugin requests it sends (`trace` on the envelope),
/// and the lines those plugins log while serving them. `rg` for the id in
/// `flash.log`, or the inspector's `/logs?trace=` and `/traces`, reassembles
/// the interaction end to end.
///
/// The current id lives on the main thread, where interactions start and
/// dispatch. Work that hops threads or turns captures it (`Trace.current`)
/// and re-enters it (`Trace.run(in:)`) explicitly; nothing else inherits it.
enum Trace {
  /// Base-36, at most 13 characters: `^[0-9a-z]{1,16}$` on the wire.
  struct ID: Hashable {
    let value: UInt64
    var text: String { String(value, radix: 36) }
  }

  enum Origin: String {
    case key, hotkey, pointer, cli
    case commandLine = "command_line"
  }

  /// Where and when an interaction started: the input's own timestamp in
  /// `ProcessInfo.systemUptime` seconds — a tap event's, a Carbon hotkey
  /// event's, an AppleEvent's arrival — so a probe can measure from it.
  struct Trigger: Equatable {
    let id: ID
    let origin: Origin
    let uptime: TimeInterval
  }

  private static var counter: UInt64 = {
    // Unique across relaunches within a log file's lifetime.
    UInt64(Date().timeIntervalSince1970 * 1000) << 12
  }()
  private static var mainCurrent: ID?
  private static var mainTrigger: Trigger?
  /// Set by `triggered(at:)` for the interaction its body begins.
  private static var pendingTriggerUptime: TimeInterval?

  /// The interaction the main thread is serving; nil on other threads.
  static var current: ID? {
    Thread.isMainThread ? mainCurrent : nil
  }

  /// The trigger of the interaction being served synchronously from its
  /// input; nil once the work has hopped a turn (re-entered with `run(in:)`)
  /// or off the main thread, where "since the trigger" means nothing.
  static var currentTrigger: Trigger? {
    guard Thread.isMainThread, let trigger = mainTrigger, trigger.id == mainCurrent else {
      return nil
    }
    return trigger
  }

  /// Run `body` as a new interaction from `origin`. Main thread only.
  /// `triggeredAt` is the input's own timestamp (systemUptime seconds);
  /// without it the interaction dates from `triggered(at:)`, or now.
  @discardableResult
  static func begin<T>(
    _ origin: Origin, triggeredAt: TimeInterval? = nil, _ body: () throws -> T
  ) rethrows -> T {
    counter &+= 1
    let id = ID(value: counter)
    let enclosingTrigger = mainTrigger
    mainTrigger = Trigger(
      id: id, origin: origin,
      uptime: triggeredAt ?? pendingTriggerUptime ?? ProcessInfo.processInfo.systemUptime)
    defer { mainTrigger = enclosingTrigger }
    return try run(in: id) {
      FlashLog.debug("[trace] begin", fields: ["origin": origin.rawValue])
      return try body()
    }
  }

  /// Run `body` knowing when its input arrived: an interaction it begins
  /// dates from `uptime` rather than from `begin`. For inputs whose
  /// timestamp is read before the code that begins the interaction (a
  /// Carbon hotkey event, an AppleEvent). Main thread only.
  @discardableResult
  static func triggered<T>(at uptime: TimeInterval, _ body: () throws -> T) rethrows -> T {
    guard Thread.isMainThread else { return try body() }
    let enclosing = pendingTriggerUptime
    pendingTriggerUptime = uptime
    defer { pendingTriggerUptime = enclosing }
    return try body()
  }

  /// Run `body` as a new interaction unless one is already running (a
  /// hotkey fired from a routed key belongs to that key's interaction).
  @discardableResult
  static func ensure<T>(_ origin: Origin, _ body: () throws -> T) rethrows -> T {
    guard current == nil else { return try body() }
    return try begin(origin, body)
  }

  /// Run `body` inside `id` (a captured `current`), restoring the enclosing
  /// interaction after. A nil id runs `body` outside any interaction. Main
  /// thread only; elsewhere it just runs `body`.
  @discardableResult
  static func run<T>(in id: ID?, _ body: () throws -> T) rethrows -> T {
    guard Thread.isMainThread else { return try body() }
    let enclosing = mainCurrent
    mainCurrent = id
    defer { mainCurrent = enclosing }
    return try body()
  }

  /// Whether `text` is a well-formed id, as a plugin echoes it back.
  static func isValid(_ text: String) -> Bool {
    (1...16).contains(text.utf8.count)
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
  }
}
