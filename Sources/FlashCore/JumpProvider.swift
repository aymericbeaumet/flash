import AppKit
import ApplicationServices

public enum FlashSourceReadinessPolicy: Sendable {
  /// Safe to keep prepared from AX/workspace invalidation while the app
  /// is focused.
  case continuous
  /// Run only when the user activates Flash.
  case activationOnly
  /// Results depend on external state Flash cannot observe reliably.
  case volatile
}

public enum FlashSourceActivationPolicy: Equatable, Sendable {
  /// Source is always available. Used by the generic AX and application
  /// sources.
  case always
  /// Source is enabled when at least one matching bundle id is running.
  case bundleIDs(Set<String>)
  /// Source is enabled when at least one known terminal app is running.
  case terminalBundles
}

public struct FlashSourceCapabilities: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let jumpTargets = FlashSourceCapabilities(rawValue: 1 << 0)
  public static let candidates = FlashSourceCapabilities(rawValue: 1 << 1)
  public static let documentURL = FlashSourceCapabilities(rawValue: 1 << 2)
  public static let appActivation = FlashSourceCapabilities(rawValue: 1 << 3)
  public static let tabSelection = FlashSourceCapabilities(rawValue: 1 << 4)
  public static let tabCreation = FlashSourceCapabilities(rawValue: 1 << 5)
  public static let tabNavigation = FlashSourceCapabilities(rawValue: 1 << 6)
  public static let tabClosing = FlashSourceCapabilities(rawValue: 1 << 7)
}

public enum SourceTabDirection: Sendable {
  case next
  case previous
}

public enum CandidateScope: Sendable {
  case running
  case all
}

public enum CandidateKind: Sendable {
  case app
  case tmuxWindow
  case browserTab
  case slackChannel
}

public struct Candidate: @unchecked Sendable {
  public var kind: CandidateKind
  /// Stable source id used for routing resolution back to the source.
  public var sourceID: String
  /// Short user-facing source name, such as "app", "tmux", or "firefox".
  public var source: String
  public var pid: pid_t?
  /// Primary searchable name. Candidate presentation and matching are built
  /// around the source/name/url contract.
  public var name: String
  public var subtitle: String
  public var bundleIdentifier: String
  /// Openable destination whenever one exists. App candidates must use an
  /// absolute file URL to the .app bundle; browser tabs and other external
  /// resources should use their canonical URL.
  public var url: URL?
  public var tmuxClientTTY: String?
  public var tmuxTarget: String?
  public var targetElement: AXUIElement?
  public var sourcePayload: String?
  public var displayTitle: String
  public var normalizedSearchText: String

  public init(
    kind: CandidateKind,
    sourceID: String,
    source: String,
    pid: pid_t?,
    name: String,
    subtitle: String,
    bundleIdentifier: String,
    url: URL?,
    tmuxClientTTY: String?,
    tmuxTarget: String?,
    targetElement: AXUIElement?,
    sourcePayload: String? = nil,
    displayTitle: String = "",
    normalizedSearchText: String = ""
  ) {
    self.kind = kind
    self.sourceID = sourceID
    self.source = source
    self.pid = pid
    self.name = name
    self.subtitle = subtitle
    self.bundleIdentifier = bundleIdentifier
    self.url = url
    self.tmuxClientTTY = tmuxClientTTY
    self.tmuxTarget = tmuxTarget
    self.targetElement = targetElement
    self.sourcePayload = sourcePayload
    self.displayTitle = displayTitle
    self.normalizedSearchText = normalizedSearchText
  }
}

public struct FlashSourceEnvironment {
  public let runningApplications: [NSRunningApplication]

  public init(runningApplications: [NSRunningApplication]) {
    self.runningApplications = runningApplications
  }
}

public struct CandidateResolution: Sendable {
  public let targetPID: pid_t?
  public let didResolve: Bool

  public init(targetPID: pid_t?, didResolve: Bool) {
    self.targetPID = targetPID
    self.didResolve = didResolve
  }

  public static let unresolved = CandidateResolution(targetPID: nil, didResolve: false)
  public static func resolved(pid: pid_t?) -> CandidateResolution {
    CandidateResolution(targetPID: pid, didResolve: true)
  }
}

public struct SourceActionResult: Sendable {
  public let targetPID: pid_t?
  public let didPerform: Bool

  public init(targetPID: pid_t?, didPerform: Bool) {
    self.targetPID = targetPID
    self.didPerform = didPerform
  }

  public static let unhandled = SourceActionResult(targetPID: nil, didPerform: false)
  public static func performed(pid: pid_t?) -> SourceActionResult {
    SourceActionResult(targetPID: pid, didPerform: true)
  }
}

public protocol FlashSource: AnyObject {
  var identifier: String { get }
  var displayName: String { get }
  var priority: Int { get }
  /// Capabilities this source contributes. A source can expose hints,
  /// `:open` items, document URL resolution, app activation, or any
  /// combination of those without separate registration paths.
  var capabilities: FlashSourceCapabilities { get }
  /// Cheap process-level activation gate. The registry instantiates and
  /// refreshes non-`always` sources only while this matches the current
  /// running application snapshot.
  var activationPolicy: FlashSourceActivationPolicy { get }
  /// How AppMonitor is allowed to prepare this source's jump targets.
  var readinessPolicy: FlashSourceReadinessPolicy { get }
  /// When true, this source's jump targets depend on state that isn't
  /// observable via `AXObserver` notifications, so caching them would
  /// silently serve stale hints. Activation skips prepared-model lookup
  /// and writes for any focused-app context where a volatile provider
  /// applies. Default: false.
  ///
  /// Set this on providers that read external state — e.g.,
  /// `TmuxSource` shells out to `tmux capture-pane`, whose content
  /// changes from terminal output and async tmux activity that the
  /// host terminal doesn't expose to AX at all.
  var resultsAreVolatile: Bool { get }
  func supports(_ context: AppContext) -> Bool
  /// Return a complete deterministic target set for the current UI state.
  /// Providers must not deadline-truncate results; a slow complete walk is
  /// preferable to serving a partial, activation-dependent hint set.
  func discover(in context: AppContext) throws -> [JumpTarget]
  /// Return complete, deterministic open/search items for this source's
  /// current enabled environment.
  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate]
  /// Resolve a previously returned candidate. The completion must be
  /// called on the main queue.
  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  )
  /// Resolve a user-provided target, such as `flash://app_open?name=`.
  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate?
  /// Resolve a document URL for the supplied focused context.
  func documentURL(in context: AppContext) -> String?
  /// Select the 1-based tab index for the focused app.
  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
  /// Select the adjacent tab for the focused app.
  func tabNext(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
  func tabPrev(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
  /// Create a tab in the focused app.
  func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
  /// Close the current tab in the focused app.
  func tabClose(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
}

extension FlashSource {
  public var displayName: String { identifier }
  public var capabilities: FlashSourceCapabilities { [.jumpTargets] }
  public var activationPolicy: FlashSourceActivationPolicy { .always }
  public var readinessPolicy: FlashSourceReadinessPolicy { .activationOnly }
  public var resultsAreVolatile: Bool { readinessPolicy == .volatile }
  public func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    []
  }
  public func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    DispatchQueue.main.async { completion(.unresolved) }
  }
  public func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    nil
  }
  public func documentURL(in context: AppContext) -> String? { nil }
  public func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
  public func tabNext(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
  public func tabPrev(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
  public func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
  public func tabClose(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
}

public typealias JumpProviderReadinessPolicy = FlashSourceReadinessPolicy
public typealias JumpProvider = FlashSource
