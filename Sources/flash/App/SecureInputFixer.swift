import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

/// Releases secure input an app left on, without a menu, a dialog, or a
/// lock-screen prompt.
///
/// The session tap receives no keys while the flag is on, so it cannot see
/// the rising edge or a hold that outlives the password field. This poll is
/// that observer. It stays registered for the life of the resident: there is
/// no earlier event to scope it to. A real password field is left alone
/// (`SecureInputRelease`). One episode asks each chosen app once.
final class SecureInputFixer {
  static let pollID = "core:secure-input"
  static let stepID = "core:secure-input-fix"
  static let pollEveryMs = 2_000

  var onFlag: (Bool) -> Void = { _ in }

  private let queue = DispatchQueue(label: "com.flash.secure-input")
  private var machine = SecureInputFixMachine()
  private var inFlight = false
  private var generation: UInt64 = 0
  private var lastPublished: Bool?

  func start() {
    PollScheduler.shared.register(
      Self.pollID, everyMs: Self.pollEveryMs, priority: .low, on: queue
    ) { [weak self] in
      self?.tick()
    }
    queue.async { [weak self] in self?.tick() }
  }

  func stop() {
    PollScheduler.shared.unregister(Self.pollID)
    PollScheduler.shared.unregister(Self.stepID)
    queue.async { [weak self] in
      guard let self else { return }
      self.generation &+= 1
      self.inFlight = false
    }
  }

  private struct Plan {
    var requests: [SecureInputRelease.Request]
    var index: Int
    var stage: Stage
    var generation: UInt64

    enum Stage {
      case start
      case afterChromiumBlur
      case afterActivate
      case afterKeystroke
      case afterRestore
    }

    func replacing(stage: Stage) -> Plan {
      Plan(requests: requests, index: index, stage: stage, generation: generation)
    }

    func nextRequest() -> Plan {
      Plan(requests: requests, index: index + 1, stage: .start, generation: generation)
    }
  }

  private func tick() {
    let snapshot = Self.observe()
    publish(snapshot.enabled)
    guard !inFlight else { return }
    guard case .perform(let requests) = machine.consider(SecureInputRelease.decide(snapshot)),
      !requests.isEmpty
    else { return }
    inFlight = true
    let described = requests.map { "\($0.bundleID):\($0.kind)" }.joined(separator: ",")
    FlashLog.info("[input] secure_input release start \(described)")
    advance(
      Plan(requests: requests, index: 0, stage: .start, generation: generation))
  }

  private func advance(_ plan: Plan) {
    guard plan.generation == generation, inFlight else { return }
    let enabled = IsSecureEventInputEnabled()
    publish(enabled)
    guard enabled else {
      // A blur or an activation can itself clear the flag, and telling a
      // browser to run the script can bring it forward. Put the user back
      // before stopping. The start stage has not touched focus yet.
      if plan.stage != .start { restore(plan) }
      finish(generation: plan.generation, cleared: true)
      return
    }
    guard plan.requests.indices.contains(plan.index) else {
      finish(generation: plan.generation, cleared: false)
      return
    }
    let request = plan.requests[plan.index]
    switch plan.stage {
    case .start:
      switch request.kind {
      case .chromium:
        if let script = SecureInputRelease.chromiumBlurScript(bundleID: request.bundleID) {
          _ = Self.runAppleScript(script)
        }
        schedule(plan.replacing(stage: .afterChromiumBlur), afterMs: 500)
      case .addressBar:
        activate(request.bundleID)
        schedule(plan.replacing(stage: .afterActivate), afterMs: 400)
      case .activate:
        activate(request.frontmost ? SecureInputRelease.finderBundleID : request.bundleID)
        schedule(plan.replacing(stage: .afterActivate), afterMs: 700)
      }
    case .afterChromiumBlur:
      activate(request.bundleID)
      schedule(plan.replacing(stage: .afterActivate), afterMs: 400)
    case .afterActivate:
      switch request.kind {
      case .chromium, .addressBar:
        if Self.frontmostBundleID() == request.bundleID {
          _ = Self.runAppleScript(SecureInputRelease.addressBarScript)
        } else {
          FlashLog.warn(
            "[input] secure_input release skipped keystroke bundle=\(request.bundleID)")
        }
        schedule(plan.replacing(stage: .afterKeystroke), afterMs: 400)
      case .activate:
        restore(plan)
        schedule(plan.replacing(stage: .afterRestore), afterMs: 400)
      }
    case .afterKeystroke:
      restore(plan)
      schedule(plan.replacing(stage: .afterRestore), afterMs: 400)
    case .afterRestore:
      schedule(plan.nextRequest(), afterMs: 200)
    }
  }

  /// After a frontmost holder was resigned, bring it back. Otherwise return
  /// to the app the user was in.
  private func restore(_ plan: Plan) {
    guard plan.requests.indices.contains(plan.index) else { return }
    let request = plan.requests[plan.index]
    if request.frontmost {
      activate(request.bundleID)
    } else if let returnTo = request.returnTo, returnTo != request.bundleID {
      activate(returnTo)
    }
  }

  private func finish(generation: UInt64, cleared: Bool) {
    guard generation == self.generation else { return }
    inFlight = false
    if cleared { machine.noteCleared() }
    FlashLog.info("[input] secure_input release result=\(cleared ? "cleared" : "still_on")")
  }

  /// The step handler is already on `queue`. Scheduling the next deadline has
  /// to wait until this handler returns: the scheduler forbids a synchronous
  /// re-entry.
  private func schedule(_ plan: Plan, afterMs: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      PollScheduler.shared.scheduleOnce(
        Self.stepID, afterMs: afterMs, priority: .normal, on: self.queue
      ) { [weak self] in
        self?.advance(plan)
      }
    }
  }

  private func publish(_ enabled: Bool) {
    guard lastPublished != enabled else { return }
    lastPublished = enabled
    onFlag(enabled)
  }

  private func activate(_ bundleID: String) {
    DispatchQueue.main.async {
      guard
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
        !app.isTerminated
      else { return }
      if NSApp.isActive { NSApp.yieldActivation(to: app) }
      _ = app.activate(from: .current, options: [])
    }
  }

  /// Role and subrole of the focused element only. The value is never read.
  private static func observe() -> SecureInputRelease.Snapshot {
    let processes = DoctorProbe.secureInputHolders()
    let apps = appSnapshot(pids: processes.map(\.pid))
    return SecureInputRelease.Snapshot(
      enabled: IsSecureEventInputEnabled(),
      holders: processes.map { process in
        SecureInputRelease.Holder(pid: process.pid, bundleID: apps.bundles[process.pid])
      },
      frontmostPID: apps.frontmostPID,
      frontmostBundleID: apps.frontmostBundleID,
      focused: focusedElement(),
      runningBundleIDs: apps.runningBundleIDs,
      ownPID: ProcessInfo.processInfo.processIdentifier)
  }

  /// AppKit's workspace reads stay on the main thread. The registry and the
  /// focused-element read stay off it.
  private static func appSnapshot(pids: [pid_t]) -> (
    frontmostPID: pid_t?, frontmostBundleID: String?, runningBundleIDs: [String],
    bundles: [pid_t: String]
  ) {
    let read = {
      var bundles: [pid_t: String] = [:]
      for pid in pids {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
          bundles[pid] = bundleID
        }
      }
      let front = NSWorkspace.shared.frontmostApplication
      return (
        frontmostPID: front?.processIdentifier,
        frontmostBundleID: front?.bundleIdentifier,
        runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
        bundles: bundles
      )
    }
    if Thread.isMainThread { return read() }
    return DispatchQueue.main.sync(execute: read)
  }

  private static func frontmostBundleID() -> String? {
    let read = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    if Thread.isMainThread { return read() }
    return DispatchQueue.main.sync(execute: read)
  }

  private static func focusedElement() -> SecureInputRelease.Focus {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, AXApp.defaultMessagingTimeout)
    guard let focused = AXAttribute.element(system, kAXFocusedUIElementAttribute as String) else {
      return SecureInputRelease.Focus(role: nil, subrole: nil)
    }
    AXUIElementSetMessagingTimeout(focused, AXApp.defaultMessagingTimeout)
    return SecureInputRelease.Focus(
      role: AXAttribute.role(focused),
      subrole: AXAttribute.string(focused, kAXSubroleAttribute as String))
  }

  private static func runAppleScript(_ source: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    process.qualityOfService = .utility
    do {
      try process.run()
    } catch {
      FlashLog.warn("[input] secure_input applescript launch failed: \(error.localizedDescription)")
      return false
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let errorText =
        String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let clipped = errorText.count > 180 ? String(errorText.prefix(180)) : errorText
      FlashLog.warn(
        "[input] secure_input applescript status=\(process.terminationStatus) \(clipped)")
      return false
    }
    return true
  }
}
