import ApplicationServices
import Foundation

/// Keeps a Gecko app's lazily-built AX tree alive while the app is focused,
/// and its accessibility mode off whenever a window is moved.
///
/// Gecko enables accessibility when its application role is read. That mode
/// also turns programmatic window moves into a slow, often incomplete
/// animation, and switching it off discards the tree, so the next read finds
/// it empty while Gecko rebuilds it. The mode is process-wide: every Flash AX
/// client shares a per-process lock, and one ledger
/// (`GeckoAccessibilityLedger`) records which processes have it on because
/// Flash turned it on.
///
/// A mode Flash turned on stays on after tree work while the app is the
/// focused one (`focusChanged(to:)`), so the next walk or readiness probe
/// reads a built tree. It is switched off when the app loses focus, on a Space
/// change, when focus stops being reported (`releaseAll`), and immediately
/// before every window geometry write (`withWindowManagement`); the next tree
/// operation turns it on again. A mode Flash did not turn on (VoiceOver and
/// other assistive clients) is never switched off. Without focus reports
/// (the integration oracles) nothing lingers: every operation restores the
/// mode it found.
public enum GeckoAccessibility {
  public static func matches(bundleIdentifier: String?, pid: pid_t) -> Bool {
    AppTraits.of(bundleIdentifier: bundleIdentifier, pid: pid).engine == .gecko
  }

  /// Run synchronous AX tree work while Gecko accessibility is active.
  /// Apps outside the Gecko family pass through without locking or mutation.
  public static func withTree<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement? = nil,
    _ operation: (AXUIElement) throws -> T
  ) rethrows -> T {
    try shared.withTree(
      pid: pid, bundleIdentifier: bundleIdentifier, app: suppliedApp, operation)
  }

  /// Serialize a window operation against Gecko AX-tree work. Gecko's tree
  /// is woken long enough to resolve the target window and read its frame; the
  /// supplied callback then switches a Flash-owned mode off immediately before
  /// the caller writes position or size, even while it lingers for a focused
  /// app. A mode another client turned on is left on.
  public static func withWindowManagement<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement? = nil,
    _ operation: (AXUIElement, _ prepareGeometry: () -> Void) throws -> T
  ) rethrows -> T {
    try shared.withWindowManagement(
      pid: pid, bundleIdentifier: bundleIdentifier, app: suppliedApp, operation)
  }

  /// The focused app changed (nil: none). Every other process's Flash-owned
  /// mode is switched off off the calling thread; the caller never waits on
  /// a process lock.
  public static func focusChanged(to pid: pid_t?) {
    shared.focusChanged(to: pid)
  }

  /// The active Space changed, when window managers re-tile: every
  /// Flash-owned mode is switched off, off the calling thread. The next tree
  /// operation of the focused app turns its mode on again.
  public static func spaceChanged() {
    shared.spaceChanged()
  }

  /// The app quit and its mode went with it.
  public static func appTerminated(pid: pid_t) {
    shared.appTerminated(pid: pid)
  }

  /// Stop lingering: forget the focused app and switch every Flash-owned mode
  /// off, waiting at most `timeout` for operations in flight to finish. For
  /// shutdown, where nothing would run a deferred release.
  public static func releaseAll(waitingAtMost timeout: DispatchTimeInterval) {
    shared.releaseAll(waitingAtMost: timeout)
  }

  static let shared = GeckoAccessibilityCoordinator(driver: .live)
}

/// Which Gecko processes have accessibility on because Flash turned it on,
/// and which of those stay on once Flash's operation ends. Pure: the caller
/// reads the mode, performs the switch-offs it is told to, and holds the
/// process lock around every scope and release.
public struct GeckoAccessibilityLedger: Equatable, Sendable {
  public struct ProcessState: Equatable, Sendable {
    /// The mode is on because Flash turned it on, and Flash has not switched
    /// it off since.
    public var ownedByFlash = false
    /// Flash left its mode on after its last operation because the app was
    /// focused; cleared when the app loses focus or the Space changes.
    public var lingerUntilFocusLoss = false
    /// Operations in progress, nested on the thread holding the process lock.
    public var activeScopes = 0

    public init(
      ownedByFlash: Bool = false, lingerUntilFocusLoss: Bool = false, activeScopes: Int = 0
    ) {
      self.ownedByFlash = ownedByFlash
      self.lingerUntilFocusLoss = lingerUntilFocusLoss
      self.activeScopes = activeScopes
    }
  }

  /// The app focus reports name as frontmost; nil when none is reported.
  public private(set) var focusedPID: pid_t?
  /// Processes with any state; a process back to the defaults is dropped.
  public private(set) var processes: [pid_t: ProcessState] = [:]

  public init() {}

  /// An operation begins. `modeWasOn` is the mode read before Flash wakes the
  /// tree: off, Flash's wake turns it on and Flash owns it; on and not
  /// Flash's, another client owns it.
  public mutating func beginScope(pid: pid_t, modeWasOn: Bool) {
    var process = processes[pid] ?? ProcessState()
    process.activeScopes += 1
    if !modeWasOn { process.ownedByFlash = true }
    store(process, for: pid)
  }

  /// An operation ends. True when Flash must switch the mode off now: the
  /// outermost scope of a Flash-owned mode in an app that is not focused. A
  /// focused app's mode lingers.
  public mutating func endScope(pid: pid_t) -> Bool {
    guard var process = processes[pid], process.activeScopes > 0 else { return false }
    process.activeScopes -= 1
    var switchOff = false
    if process.activeScopes == 0 {
      if process.ownedByFlash, pid == focusedPID {
        process.lingerUntilFocusLoss = true
      } else {
        switchOff = process.ownedByFlash
        process.ownedByFlash = false
        process.lingerUntilFocusLoss = false
      }
    }
    store(process, for: pid)
    return switchOff
  }

  /// Immediately before a window geometry write. True when Flash must switch
  /// its mode off, lingering or not.
  public mutating func prepareGeometry(pid: pid_t) -> Bool {
    guard var process = processes[pid], process.ownedByFlash else { return false }
    process.ownedByFlash = false
    process.lingerUntilFocusLoss = false
    store(process, for: pid)
    return true
  }

  /// The focused app changed. Returns the processes whose Flash-owned mode is
  /// now due off. The newly focused app lingers again if its mode is still on.
  public mutating func focusChanged(to pid: pid_t?) -> [pid_t] {
    focusedPID = pid
    var due: [pid_t] = []
    for (other, var process) in processes where process.ownedByFlash {
      process.lingerUntilFocusLoss = other == pid
      if other != pid { due.append(other) }
      processes[other] = process
    }
    return due.sorted()
  }

  /// The active Space changed. Returns every process whose Flash-owned mode
  /// is now due off, the focused one included.
  public mutating func spaceChanged() -> [pid_t] {
    var due: [pid_t] = []
    for (pid, var process) in processes where process.ownedByFlash {
      process.lingerUntilFocusLoss = false
      processes[pid] = process
      due.append(pid)
    }
    return due.sorted()
  }

  /// Focus is no longer reported: nothing lingers from now on. Returns every
  /// process whose Flash-owned mode is due off.
  public mutating func stop() -> [pid_t] {
    focusedPID = nil
    return spaceChanged()
  }

  /// The app quit; its mode went with it.
  public mutating func terminated(pid: pid_t) {
    if focusedPID == pid { focusedPID = nil }
    guard var process = processes[pid] else { return }
    process.ownedByFlash = false
    process.lingerUntilFocusLoss = false
    store(process, for: pid)
  }

  /// A release made due by `focusChanged`, `spaceChanged` or `stop` runs,
  /// holding the process lock. True when Flash must switch the mode off now:
  /// it is still Flash's, no operation is using it, and the app did not
  /// regain focus (nor a newer operation of the focused app re-arm it) in
  /// the meantime.
  public mutating func takeRelease(pid: pid_t) -> Bool {
    guard var process = processes[pid], process.ownedByFlash,
      !process.lingerUntilFocusLoss, process.activeScopes == 0
    else { return false }
    process.ownedByFlash = false
    store(process, for: pid)
    return true
  }

  private mutating func store(_ process: ProcessState, for pid: pid_t) {
    processes[pid] = process == ProcessState() ? nil : process
  }
}

/// The AX reads and writes `GeckoAccessibilityCoordinator` performs, and
/// where it runs deferred releases; faked in tests.
struct GeckoAccessibilityDriver {
  var isGecko: (_ bundleIdentifier: String?, _ pid: pid_t) -> Bool
  var makeApp: (pid_t) -> AXUIElement
  /// The mode as the app reports it; nil when it does not answer.
  var readMode: (AXUIElement) -> Bool?
  /// Wake the tree: read the application role.
  var wake: (AXUIElement) -> Void
  /// Switch the mode off. Gecko reports `.cannotComplete` for this setter
  /// even though it applies the value, so the result is not inspected.
  var switchOff: (AXUIElement) -> Void
  /// Run a deferred release off the calling thread.
  var schedule: (@escaping () -> Void) -> Void

  static let live: GeckoAccessibilityDriver = {
    let releases = DispatchQueue(label: "flash.gecko_accessibility", qos: .userInitiated)
    return GeckoAccessibilityDriver(
      isGecko: GeckoAccessibility.matches(bundleIdentifier:pid:),
      makeApp: { AXApp.make(pid: $0) },
      readMode: { app in
        var value: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
      },
      wake: { app in
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
      },
      switchOff: { app in
        _ = AXUIElementSetAttributeValue(
          app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
      },
      schedule: { releases.async(execute: $0) })
  }()
}

/// Owns the ledger and the per-process locks. Every scope and release holds
/// its process lock around the AX calls; the ledger has its own short lock,
/// never held across IPC, so focus reports from the main thread never wait
/// on a walk.
final class GeckoAccessibilityCoordinator: @unchecked Sendable {
  private let driver: GeckoAccessibilityDriver
  private let ledgerLock = NSLock()
  private var ledger = GeckoAccessibilityLedger()
  private let locks = GeckoAccessibilityLockStore()

  init(driver: GeckoAccessibilityDriver) {
    self.driver = driver
  }

  var snapshot: GeckoAccessibilityLedger {
    update { $0 }
  }

  func withTree<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement?,
    _ operation: (AXUIElement) throws -> T
  ) rethrows -> T {
    let app = suppliedApp ?? driver.makeApp(pid)
    guard driver.isGecko(bundleIdentifier, pid) else {
      return try operation(app)
    }
    let lock = locks.lock(for: pid)
    lock.lock()
    defer { lock.unlock() }
    begin(pid: pid, app: app)
    defer { end(pid: pid, app: app) }
    return try operation(app)
  }

  func withWindowManagement<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement?,
    _ operation: (AXUIElement, _ prepareGeometry: () -> Void) throws -> T
  ) rethrows -> T {
    guard driver.isGecko(bundleIdentifier, pid) else {
      return try operation(suppliedApp ?? driver.makeApp(pid), {})
    }
    let lock = locks.lock(for: pid)
    lock.lock()
    defer { lock.unlock() }
    let app = suppliedApp ?? driver.makeApp(pid)
    begin(pid: pid, app: app)
    var prepared = false
    let prepareGeometry = {
      guard !prepared else { return }
      prepared = true
      if self.update({ $0.prepareGeometry(pid: pid) }) {
        self.driver.switchOff(app)
      }
    }
    defer {
      prepareGeometry()
      end(pid: pid, app: app)
    }
    return try operation(app, prepareGeometry)
  }

  func focusChanged(to pid: pid_t?) {
    scheduleReleases(update { $0.focusChanged(to: pid) }, group: nil)
  }

  func spaceChanged() {
    scheduleReleases(update { $0.spaceChanged() }, group: nil)
  }

  func appTerminated(pid: pid_t) {
    update { $0.terminated(pid: pid) }
  }

  func releaseAll(waitingAtMost timeout: DispatchTimeInterval) {
    let group = DispatchGroup()
    scheduleReleases(update { $0.stop() }, group: group)
    _ = group.wait(timeout: .now() + timeout)
  }

  private func begin(pid: pid_t, app: AXUIElement) {
    let modeWasOn = driver.readMode(app) == true
    update { $0.beginScope(pid: pid, modeWasOn: modeWasOn) }
    driver.wake(app)
  }

  private func end(pid: pid_t, app: AXUIElement) {
    if update({ $0.endScope(pid: pid) }) {
      driver.switchOff(app)
    }
  }

  private func scheduleReleases(_ pids: [pid_t], group: DispatchGroup?) {
    for pid in pids {
      group?.enter()
      driver.schedule { [self] in
        release(pid: pid)
        group?.leave()
      }
    }
  }

  /// Runs where `schedule` put it; waits for any operation in flight on the
  /// process, whose own end already honours the focus it sees.
  private func release(pid: pid_t) {
    let lock = locks.lock(for: pid)
    lock.lock()
    defer { lock.unlock() }
    guard update({ $0.takeRelease(pid: pid) }) else { return }
    driver.switchOff(driver.makeApp(pid))
  }

  @discardableResult
  private func update<R>(_ body: (inout GeckoAccessibilityLedger) -> R) -> R {
    ledgerLock.lock()
    defer { ledgerLock.unlock() }
    return body(&ledger)
  }
}

private final class GeckoAccessibilityLockStore: @unchecked Sendable {
  private let guardLock = NSLock()
  private var processLocks: [pid_t: NSRecursiveLock] = [:]

  func lock(for pid: pid_t) -> NSRecursiveLock {
    guardLock.lock()
    defer { guardLock.unlock() }
    if let existing = processLocks[pid] {
      return existing
    }
    let created = NSRecursiveLock()
    processLocks[pid] = created
    return created
  }
}
