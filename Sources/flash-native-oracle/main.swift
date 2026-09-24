import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashIntegrationTestSupport
import FlashProviders
import Foundation

private struct Args {
  var fixtureAppPath: String = "/Applications/Flash Native Fixture.app"
  var fixtureBundleID: String = "com.flash.native-fixture"
  var flashCLIPath: String = "\(NSHomeDirectory())/.local/bin/flash"
  var flashStateURL: String = "http://127.0.0.1:4242/state"
  var skipResidentModeTests = false
  var statePath: String = "/tmp/flash-native-fixture-state.json"
  var timingsPath: String?
  /// `--bench=N [--bench-trigger=key|cli]`: time hint activations on the
  /// fixture instead of running the oracle (`Scripts/benchmark-hints.sh`).
  var bench: ResidentHintBenchmark?
  /// `--fixture-large-table <rows>` (bench only): the fixture opens its
  /// long-table window in front, so the benchmark times a walk over it.
  var fixtureLargeTableRows: Int?
}

private func parseArgs() -> Args {
  var args = Args()
  var iter = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = iter.next() {
    switch arg {
    case "--fixture-app":
      args.fixtureAppPath = iter.next() ?? args.fixtureAppPath
    case "--fixture-bundle-id":
      args.fixtureBundleID = iter.next() ?? args.fixtureBundleID
    case "--flash-cli":
      args.flashCLIPath = iter.next() ?? args.flashCLIPath
    case "--flash-state-url":
      args.flashStateURL = iter.next() ?? args.flashStateURL
    case "--skip-resident-mode-tests":
      args.skipResidentModeTests = true
    case "--state-file":
      args.statePath = iter.next() ?? args.statePath
    case "--timings":
      args.timingsPath = iter.next()
    case "--fixture-large-table":
      guard let rows = iter.next().flatMap(Int.init), rows > 0 else {
        fputs("--fixture-large-table needs a positive row count\n", stderr)
        exit(2)
      }
      args.fixtureLargeTableRows = rows
    case let arg where ResidentHintBenchmark.owns(arg):
      continue
    case "--help", "-h":
      print(
        """
        flash-native-oracle [--fixture-app <path>] [--state-file <path>] [--timings <path>]
                            [--flash-cli <path>] [--flash-state-url <url>]
                            [--skip-resident-mode-tests]
                            [--bench=<runs> [--bench-trigger=key|cli]
                             [--fixture-large-table <rows>]]

        Launches the Flash native AppKit fixture, compares Flash's generic
        AX targets against expected native controls, verifies host clicks,
        and drives the installed Flash resident through captured-target and
        normal/insert mode handoff regressions.
        """)
      exit(0)
    default:
      fputs("Unknown argument: \(arg)\n", stderr)
      exit(2)
    }
  }
  do {
    args.bench = try ResidentHintBenchmark.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    fputs("\(error)\n", stderr)
    exit(2)
  }
  if args.fixtureLargeTableRows != nil, args.bench == nil {
    fputs("--fixture-large-table only applies with --bench\n", stderr)
    exit(2)
  }
  return args
}

private enum OracleError: Error, CustomStringConvertible {
  case accessibilityMissing
  case consoleLocked
  case fixtureNotFound(String)
  case launchFailed(String)
  case axWindowTimedOut
  case flashCLIUnavailable(String)
  case flashCommandFailed(String)
  case flashStateUnavailable(String)
  case flashModeTimedOut(String)
  case stateTimedOut(String)
  case targetMissing(String)

  var description: String {
    switch self {
    case .accessibilityMissing:
      return "Accessibility permission is missing for the native oracle app"
    case .consoleLocked:
      return "Native GUI probes require an unlocked console session"
    case .fixtureNotFound(let path):
      return "Native fixture app not found at \(path)"
    case .launchFailed(let message):
      return "Native fixture launch failed: \(message)"
    case .axWindowTimedOut:
      return "Native fixture did not expose an AX window before timeout"
    case .flashCLIUnavailable(let path):
      return "Flash CLI not found or not executable at \(path)"
    case .flashCommandFailed(let message):
      return "Flash command failed: \(message)"
    case .flashStateUnavailable(let message):
      return "Flash debug state unavailable: \(message)"
    case .flashModeTimedOut(let expected):
      return "Timed out waiting for Flash mode \(expected)"
    case .stateTimedOut(let expected):
      return "Timed out waiting for fixture state \(expected)"
    case .targetMissing(let label):
      return "Could not find native target \(label)"
    }
  }
}

private func ensureUnlockedConsole() throws {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
    session["CGSSessionScreenIsLocked"] as? Bool != true
  else { throw OracleError.consoleLocked }
}

private func ensureAccessibility() throws {
  if AXIsProcessTrusted() { return }
  let opts: NSDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
  ]
  _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
  throw OracleError.accessibilityMissing
}

private func terminateRunningFixture(bundleID: String) {
  for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
    app.terminate()
  }
  Thread.sleep(forTimeInterval: 0.4)
  for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
  where !app.isTerminated {
    app.forceTerminate()
  }
}

private func launchFixture(
  appPath: String,
  bundleID: String,
  arguments: [String],
  timer: IntegrationTimer
) throws -> NSRunningApplication {
  guard FileManager.default.fileExists(atPath: appPath) else {
    throw OracleError.fixtureNotFound(appPath)
  }
  let before = Set(
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .map { $0.processIdentifier })
  let config = NSWorkspace.OpenConfiguration()
  config.activates = true
  config.addsToRecentItems = false
  config.arguments = arguments

  var launched: NSRunningApplication?
  var launchError: Error?
  let sem = DispatchSemaphore(value: 0)
  timer.mark("launch_fixture_start", detail: "args=\(arguments.joined(separator: " "))")
  NSWorkspace.shared.openApplication(
    at: URL(fileURLWithPath: appPath),
    configuration: config
  ) { app, error in
    launched = app
    launchError = error
    sem.signal()
  }
  if sem.wait(timeout: .now() + 20) == .timedOut {
    throw OracleError.launchFailed("NSWorkspace.openApplication timed out")
  }
  if let launchError {
    throw OracleError.launchFailed(String(describing: launchError))
  }
  let app =
    launched
    ?? AXIntegrationHarness.waitForRunningApplication(
      bundleIdentifier: bundleID,
      excluding: before,
      timeout: 10)
  guard let app else {
    throw OracleError.launchFailed("no NSRunningApplication returned")
  }
  guard AXIntegrationHarness.waitForAXWindow(app, timeout: 20) else {
    terminateRunningFixture(bundleID: bundleID)
    throw OracleError.axWindowTimedOut
  }
  timer.mark("launch_fixture_ready", detail: "pid=\(app.processIdentifier)")
  return app
}

private func waitForTargets(
  app: NSRunningApplication,
  provider: AccessibilityProvider,
  expected: [ExpectedIntegrationTarget],
  timeout: TimeInterval,
  timer: IntegrationTimer
) -> [JumpTarget] {
  let deadline = Date().addingTimeInterval(timeout)
  var last: [JumpTarget] = []
  while Date() < deadline {
    last = timer.measure("native_discover") {
      AXIntegrationHarness.discoverFinalizedTargets(app: app, provider: provider)
    }
    let diff = IntegrationTargetMatcher.classify(expected: expected, actual: last)
    if diff.missing.isEmpty { return last }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return last
}

private func readState(_ path: String) -> [String: Int] {
  guard let data = FileManager.default.contents(atPath: path),
    let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
  else { return [:] }
  return decoded
}

private func waitForState(path: String, key: String, value: Int, timeout: TimeInterval) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if readState(path)[key] == value { return }
    Thread.sleep(forTimeInterval: 0.1)
  }
  throw OracleError.stateTimedOut("\(key)=\(value)")
}

private func targetCenter(label: String, targets: [JumpTarget]) throws -> CGPoint {
  guard let target = targets.first(where: { $0.accessibilityLabel == label }) else {
    throw OracleError.targetMissing(label)
  }
  return CGPoint(x: target.frame.midX, y: target.frame.midY)
}

private func runFlash(_ verb: String, arguments: [String] = [], args: Args) throws {
  guard FileManager.default.isExecutableFile(atPath: args.flashCLIPath) else {
    throw OracleError.flashCLIUnavailable(args.flashCLIPath)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: args.flashCLIPath)
  process.arguments = [verb] + arguments
  let pipe = Pipe()
  process.standardError = pipe
  process.standardOutput = pipe
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    throw OracleError.flashCommandFailed("\(verb) exited \(process.terminationStatus): \(output)")
  }
}

private func fetchFlashState(args: Args, timeout: TimeInterval = 4) throws -> [String: Any] {
  guard let url = URL(string: args.flashStateURL) else {
    throw OracleError.flashStateUnavailable("invalid URL \(args.flashStateURL)")
  }
  let deadline = Date().addingTimeInterval(timeout)
  var lastError: Error?
  while Date() < deadline {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<[String: Any], Error>?
    URLSession.shared.dataTask(with: url) { data, _, error in
      if let error {
        result = .failure(error)
      } else if let data,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        result = .success(object)
      } else {
        result = .failure(OracleError.flashStateUnavailable("invalid JSON from \(url)"))
      }
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 0.5)
    if let result {
      switch result {
      case .success(let object):
        return object
      case .failure(let error):
        lastError = error
      }
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  throw OracleError.flashStateUnavailable(lastError.map(String.init(describing:)) ?? "timeout")
}

private func waitForFlashMode(_ expected: String, args: Args, timeout: TimeInterval) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if try flashMode(args: args) == expected { return }
    Thread.sleep(forTimeInterval: 0.1)
  }
  throw OracleError.flashModeTimedOut(expected)
}

private struct ResidentHint: Equatable {
  let label: String
  let accessibilityLabel: String?
  let role: String?
  let frame: CGRect

  init(_ value: [String: Any]) throws {
    guard let label = value["label"] as? String, !label.isEmpty,
      let frame = value["frame"] as? [String: NSNumber],
      let x = frame["x"], let y = frame["y"],
      let width = frame["width"], let height = frame["height"]
    else { throw OracleError.flashStateUnavailable("invalid hint label or frame") }
    self.label = label
    accessibilityLabel = value["accessibility_label"] as? String
    role = value["role"] as? String
    self.frame = CGRect(
      x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
  }
}

private func waitForResidentHints(
  behavior: String, after previous: [ResidentHint] = [], allowInsert: Bool = false, args: Args
) throws -> [ResidentHint] {
  let deadline = Date().addingTimeInterval(4)
  while Date() < deadline {
    let state = try fetchFlashState(args: args, timeout: 1)
    if allowInsert, state["mode"] as? String == "insert" { return [] }
    if state["hint_behavior"] as? String == behavior,
      state["activation_in_flight"] as? Bool == false,
      let values = state["hints"] as? [[String: Any]]
    {
      let hints = try values.map(ResidentHint.init)
      if !hints.isEmpty, hints != previous { return hints }
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw OracleError.flashStateUnavailable("timed out waiting for \(behavior) hint layout")
}

private func captureResidentHint(label: String, args: Args) throws -> ResidentHint {
  try ensureUnlockedConsole()
  try runFlash("mouse_target", args: args)
  let hints = try waitForResidentHints(behavior: "click", args: args)
  guard let hint = hints.first(where: { $0.accessibilityLabel == label }) else {
    throw OracleError.targetMissing("resident hint for \(label)")
  }
  return hint
}

private func commitResidentHint(label: String, args: Args) throws {
  let hint = try captureResidentHint(label: label, args: args)
  try ensureUnlockedConsole()
  try postHintLabel(hint.label)
}

private func assertResidentHintIsStillCaptured(_ hint: ResidentHint, args: Args) throws {
  let state = try fetchFlashState(args: args, timeout: 1)
  guard state["hint_behavior"] as? String == "click",
    state["activation_in_flight"] as? Bool == false,
    let values = state["hints"] as? [[String: Any]],
    try values.map(ResidentHint.init).contains(hint)
  else { throw OracleError.flashStateUnavailable("captured hint changed before commit") }
}

private func waitForResidentHintsDismissed(args: Args) throws {
  let deadline = Date().addingTimeInterval(4)
  while Date() < deadline {
    try ensureUnlockedConsole()
    let state = try fetchFlashState(args: args, timeout: 1)
    if state["activation_in_flight"] as? Bool == false,
      let hints = state["hints"] as? [[String: Any]], hints.isEmpty
    {
      return
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw OracleError.flashStateUnavailable("captured hint was not dismissed")
}

@discardableResult
private func waitForAXFrame(_ element: AXUIElement, near expected: CGRect) throws -> CGRect {
  let deadline = Date().addingTimeInterval(4)
  while Date() < deadline {
    try ensureUnlockedConsole()
    if let frame = AXIntegrationHarness.frame(of: element),
      abs(frame.minX - expected.minX) < 1, abs(frame.minY - expected.minY) < 1,
      abs(frame.width - expected.width) < 1, abs(frame.height - expected.height) < 1
    {
      return frame
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw OracleError.stateTimedOut("owned fixture AX frame \(NSStringFromRect(expected))")
}

private func setFixtureWindowFrame(_ window: AXUIElement, to frame: CGRect) throws {
  try ensureUnlockedConsole()
  var point = CGPoint(
    x: frame.minX, y: AXIntegrationHarness.primaryScreenHeight() - frame.maxY)
  guard let value = AXValueCreate(.cgPoint, &point) else { throw OracleError.axWindowTimedOut }
  let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
  guard result == .success else {
    throw OracleError.stateTimedOut("moving owned fixture window failed AX=\(result.rawValue)")
  }
  try waitForAXFrame(window, near: frame)
}

private func verifyMovedResidentHint(
  args: Args, app: NSRunningApplication, recorder: ConsoleIntegrationRecorder
) throws {
  guard let window = AXIntegrationHarness.focusedWindow(pid: app.processIdentifier),
    let originalFrame = AXIntegrationHarness.frame(of: window),
    let primary = findAXNode(
      root: AXUIElementCreateApplication(app.processIdentifier),
      labels: ["Primary Action"], maxNodes: 4_000),
    let originalButton = primary.frame,
    let screen = NSScreen.screens.first(where: { $0.frame.contains(originalButton.origin) })
  else { throw OracleError.targetMissing("owned movable fixture window and primary button") }
  let moves = [
    CGVector(dx: 0, dy: 80), CGVector(dx: 0, dy: -80),
    CGVector(dx: 200, dy: 0), CGVector(dx: -200, dy: 0),
  ]
  guard
    let move = moves.first(where: {
      screen.visibleFrame.contains(originalFrame.offsetBy(dx: $0.dx, dy: $0.dy))
        && !originalButton.intersects(originalButton.offsetBy(dx: $0.dx, dy: $0.dy))
    })
  else { throw OracleError.stateTimedOut("space for an owned fixture-window move") }
  defer {
    try? runFlash("hints_dismiss", args: args)
    do {
      try setFixtureWindowFrame(window, to: originalFrame)
    } catch {
      recorder.fail("restoring moved fixture window failed: \(error)")
    }
  }
  let hint = try captureResidentHint(label: "Primary Action", args: args)
  let before = readState(args.statePath)["primary", default: 0]
  try setFixtureWindowFrame(window, to: originalFrame.offsetBy(dx: move.dx, dy: move.dy))
  let movedButton = try waitForAXFrame(
    primary.element, near: originalButton.offsetBy(dx: move.dx, dy: move.dy))
  try assertResidentHintIsStillCaptured(hint, args: args)
  try ensureUnlockedConsole()
  try postHintLabel(hint.label)
  try waitForState(path: args.statePath, key: "primary", value: before + 1, timeout: 4)
  try waitForResidentHintsDismissed(args: args)
  try waitForFlashModeStable("normal", args: args, timeout: 4, stableFor: 0.35)
  guard movedButton.contains(NSEvent.mouseLocation) else {
    throw OracleError.stateTimedOut("cursor at the moved captured button")
  }
  recorder.pass("resident captured button followed its moved AX window and received the host click")
}

private func verifyChangedResidentHint(
  args: Args, app: NSRunningApplication, recorder: ConsoleIntegrationRecorder
) throws {
  guard
    let input = findAXNode(
      root: AXUIElementCreateApplication(app.processIdentifier),
      labels: ["Native Search Field"], maxNodes: 4_000)
  else { throw OracleError.targetMissing("Native Search Field") }
  var rawValue: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(input.element, kAXValueAttribute as CFString, &rawValue)
      == .success, let originalValue = rawValue as? String
  else { throw OracleError.stateTimedOut("capturing owned search-field value") }
  defer {
    try? runFlash("hints_dismiss", args: args)
    let result = AXUIElementSetAttributeValue(
      input.element, kAXValueAttribute as CFString, originalValue as CFString)
    if result != .success {
      recorder.fail("restoring fixture search value failed AX=\(result.rawValue)")
    }
  }
  let hint = try captureResidentHint(label: "Native Search Field", args: args)
  let changedValue = originalValue + " changed after hint capture"
  try ensureUnlockedConsole()
  let result = AXUIElementSetAttributeValue(
    input.element, kAXValueAttribute as CFString, changedValue as CFString)
  guard result == .success else {
    throw OracleError.stateTimedOut(
      "changing owned search-field value failed AX=\(result.rawValue)")
  }
  try waitForAXValue(input.element, value: changedValue)
  try assertResidentHintIsStillCaptured(hint, args: args)
  let pointerBefore = NSEvent.mouseLocation
  try ensureUnlockedConsole()
  try postHintLabel(hint.label)
  try waitForResidentHintsDismissed(args: args)
  try waitForFlashModeStable("normal", args: args, timeout: 4, stableFor: 0.35)
  guard
    hypot(NSEvent.mouseLocation.x - pointerBefore.x, NSEvent.mouseLocation.y - pointerBefore.y) < 1
  else { throw OracleError.stateTimedOut("changed input target cancelled without a pointer move") }
  recorder.pass("resident cancelled a captured input after its AX value changed")
}

private func runResidentCapturedTargetProbes(
  args: Args, app: NSRunningApplication, recorder: ConsoleIntegrationRecorder
) {
  guard !args.skipResidentModeTests else { return }
  do {
    try ensureUnlockedConsole()
    let originalMode = try flashMode(args: args)
    defer {
      try? runFlash("hints_dismiss", args: args)
      try? runFlash(
        originalMode == "insert" ? "enter_insert_mode" : "enter_normal_mode", args: args)
    }
    app.activate(options: [])
    try waitForFocusedAXElement(pid: app.processIdentifier)
    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    do {
      try verifyMovedResidentHint(args: args, app: app, recorder: recorder)
    } catch {
      recorder.fail("resident moved-target capture probe failed: \(error)")
    }
    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    do {
      try verifyChangedResidentHint(args: args, app: app, recorder: recorder)
    } catch {
      recorder.fail("resident changed-target capture probe failed: \(error)")
    }
  } catch {
    recorder.fail("resident captured-target setup failed: \(error)")
  }
}

private func commitResidentGrid(
  app: NSRunningApplication, targets: [JumpTarget], args: Args
) throws {
  let window = AXIntegrationHarness.makeContext(for: app).frontWindowFrame.insetBy(dx: 32, dy: 48)
  guard !window.isEmpty, !window.isNull else { throw OracleError.axWindowTimedOut }
  let point = CGPoint(x: window.midX, y: window.midY)
  let excluded = targets.filter {
    $0.entersInsertMode || $0.role == "AXPopUpButton" || $0.role == "AXMenuButton"
      || $0.accessibilityLabel == "Open Fixture Menu"
  }.map(\.frame)
  func safeClick(_ hint: ResidentHint) -> Bool {
    let center = CGPoint(x: hint.frame.midX, y: hint.frame.midY)
    return window.contains(center) && !excluded.contains { $0.contains(center) }
  }
  func distance(_ hint: ResidentHint) -> CGFloat {
    hypot(hint.frame.midX - point.x, hint.frame.midY - point.y)
  }
  try runFlash("mouse_grid", args: args)
  var hints = try waitForResidentHints(behavior: "mouseGridClick", args: args)
  // Configuration allows at most six steps. Read each new layout before the
  // next key, and only let the final click land inside this fixture's window.
  // The grid marks the cells whose selection clicks by role.
  for _ in 0..<6 {
    let candidates = hints.filter { hint in
      let commits =
        hint.role == "FlashMouseGridFinalChip" || hint.role == "FlashMouseGridFinalCell"
      return !commits || safeClick(hint)
    }
    guard let selected = candidates.min(by: { distance($0) < distance($1) }) else {
      throw OracleError.targetMissing("safe non-input fixture grid cell")
    }
    try postHintLabel(selected.label)
    hints = try waitForResidentHints(
      behavior: "mouseGridClick", after: hints, allowInsert: true, args: args)
    if hints.isEmpty { return }
  }
  throw OracleError.flashModeTimedOut("insert after final mouse_grid cell")
}

private func flashMode(args: Args) throws -> String {
  let state = try fetchFlashState(args: args, timeout: 1)
  guard let mode = state["mode"] as? String else {
    throw OracleError.flashStateUnavailable("debug state did not include mode")
  }
  return mode
}

private func waitForFlashModeStable(
  _ expected: String,
  args: Args,
  timeout: TimeInterval,
  stableFor duration: TimeInterval
) throws {
  try waitForFlashMode(expected, args: args, timeout: timeout)
  let deadline = Date().addingTimeInterval(duration)
  while Date() < deadline {
    let current = try flashMode(args: args)
    guard current == expected else {
      throw OracleError.flashModeTimedOut("\(expected) stable; saw \(current)")
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
}

private func assertFlashMode(
  _ expected: String,
  args: Args,
  recorder: ConsoleIntegrationRecorder,
  label: String
) {
  do {
    try waitForFlashModeStable(expected, args: args, timeout: 4, stableFor: 0.35)
    recorder.pass("resident mode \(expected) after \(label)")
  } catch {
    recorder.fail("resident mode check failed after \(label): \(error)")
  }
}

private func cgScreenPoint(from nsScreenPoint: CGPoint) -> CGPoint {
  CGPoint(
    x: nsScreenPoint.x,
    y: AXIntegrationHarness.primaryScreenHeight() - nsScreenPoint.y)
}

private func postMouseClick(at nsScreenPoint: CGPoint, action: JumpAction) {
  let point = cgScreenPoint(from: nsScreenPoint)
  let source = CGEventSource(stateID: .hidSystemState)
  CGWarpMouseCursorPosition(point)
  Thread.sleep(forTimeInterval: 0.03)
  func post(_ type: CGEventType, button: CGMouseButton) {
    CGEvent(
      mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
      .post(tap: .cghidEventTap)
  }
  switch action {
  case .leftClick:
    post(.leftMouseDown, button: .left)
    Thread.sleep(forTimeInterval: 0.05)
    post(.leftMouseUp, button: .left)
  case .rightClick:
    post(.rightMouseDown, button: .right)
    Thread.sleep(forTimeInterval: 0.05)
    post(.rightMouseUp, button: .right)
  case .middleClick:
    post(.otherMouseDown, button: .center)
    Thread.sleep(forTimeInterval: 0.05)
    post(.otherMouseUp, button: .center)
  case .doubleClick, .tripleClick:
    let clickCount = action == .tripleClick ? 3 : 2
    for click in 1...clickCount {
      let down = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left)
      down?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      down?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.04)
      let up = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left)
      up?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
      up?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.06)
    }
  }
}

private func postKey(_ key: CGKeyCode) {
  let source = CGEventSource(stateID: .hidSystemState)
  CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?
    .post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.02)
  CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?
    .post(tap: .cghidEventTap)
}

private func postHintLabel(_ label: String) throws {
  try postText(label.lowercased())
}

private func postText(_ text: String) throws {
  let source = CGEventSource(stateID: .hidSystemState)
  for character in text {
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { throw OracleError.flashCommandFailed("could not create text key events") }
    let units = Array(String(character).utf16)
    units.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
      up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
    }
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    up.post(tap: .cghidEventTap)
  }
}

@discardableResult
private func waitForFocusedAXElement(
  pid: pid_t, value: String? = nil, timeout: TimeInterval = 4
) throws -> AXUIElement {
  let system = AXUIElementCreateSystemWide()
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    try ensureUnlockedConsole()
    if let focused = axElementAttribute(system, kAXFocusedUIElementAttribute as CFString) {
      var focusedPID: pid_t = 0
      if AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == pid,
        value == nil
          || AXIntegrationHarness.stringAttribute(focused, kAXValueAttribute as CFString) == value
      {
        return focused
      }
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw OracleError.stateTimedOut("focused input in pid=\(pid)")
}

private func waitForAXValue(
  _ element: AXUIElement, value: String, timeout: TimeInterval = 4
) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    try ensureUnlockedConsole()
    if AXIntegrationHarness.stringAttribute(element, kAXValueAttribute as CFString) == value {
      return
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  throw OracleError.stateTimedOut("expected value in original fixture input")
}

private func runResidentEmojiInsertionProbe(
  args: Args, app: NSRunningApplication, recorder: ConsoleIntegrationRecorder
) {
  guard !args.skipResidentModeTests else { return }
  do {
    let originalMode = try flashMode(args: args)
    defer {
      try? runFlash(
        originalMode == "insert" ? "enter_insert_mode" : "enter_normal_mode", args: args)
    }
    let residents = NSRunningApplication.runningApplications(withBundleIdentifier: "com.flash.app")
      .filter { !$0.isTerminated }
    guard residents.count == 1, let resident = residents.first else {
      throw OracleError.flashStateUnavailable("emoji probe requires one running Flash resident")
    }
    let queryPrefix = ":flashlight @emojis.glyphs "
    for label in ["Native Search Field", "Native Notes Area"] {
      for entryMode in ["normal", "insert"] {
        try ensureUnlockedConsole()
        try runFlash("enter_insert_mode", args: args)
        app.activate(options: [])
        try waitForFocusedAXElement(pid: app.processIdentifier)
        guard
          let node = findAXNode(
            root: AXUIElementCreateApplication(app.processIdentifier), labels: [label],
            maxNodes: 4_000),
          let frame = node.frame
        else { throw OracleError.targetMissing(label) }
        let cleared = AXUIElementSetAttributeValue(
          node.element, kAXValueAttribute as CFString, "" as CFString)
        guard cleared == .success else {
          throw OracleError.stateTimedOut("clearing \(label) failed AX=\(cleared.rawValue)")
        }
        try ensureUnlockedConsole()
        postMouseClick(at: CGPoint(x: frame.midX, y: frame.midY), action: .leftClick)
        try waitForFocusedAXElement(pid: app.processIdentifier)
        try runFlash(entryMode == "normal" ? "enter_normal_mode" : "enter_insert_mode", args: args)
        try waitForFlashMode(entryMode, args: args, timeout: 4)
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let restore = entryMode == "insert" ? ["--restore-mode"] : []
        try runFlash(
          "enter_command_mode", arguments: ["--input=\(queryPrefix)"] + restore, args: args)
        // Observe real field-editor ownership, then send the query through the
        // command panel so this covers the focus handoff that native inputs need.
        try waitForFocusedAXElement(pid: resident.processIdentifier, value: queryPrefix)
        try ensureUnlockedConsole()
        try postText("rocket")
        try waitForFocusedAXElement(pid: resident.processIdentifier, value: queryPrefix + "rocket")
        try ensureUnlockedConsole()
        postKey(CGKeyCode(kVK_Return))
        try waitForAXValue(node.element, value: "🚀")
        try waitForFocusedAXElement(pid: app.processIdentifier, value: "🚀")
        try waitForFlashModeStable(entryMode, args: args, timeout: 4, stableFor: 0.35)
        guard NSPasteboard.general.changeCount == clipboardChangeCount else {
          throw OracleError.stateTimedOut("emoji insertion changed the clipboard")
        }
        recorder.pass("emoji returned to \(label), preserved clipboard and \(entryMode) mode")
      }
    }
  } catch {
    recorder.fail("resident emoji insertion probe failed: \(error)")
  }
}

private func reportDiff(
  _ diff: IntegrationTargetDiff,
  recorder: ConsoleIntegrationRecorder
) {
  for match in diff.matches {
    recorder.pass(
      "matched \(match.expected.id) label=\(match.expected.label) role=\(match.actual.role ?? "-")")
  }
  for missing in diff.missing {
    recorder.fail("missing expected target \(missing.id) label=\(missing.label)")
  }
  for unexpected in diff.unexpected {
    recorder.fail(
      "unexpected target label=\(unexpected.accessibilityLabel ?? "-") role=\(unexpected.role ?? "-")"
    )
  }
}

private func assertAbsentLabels(
  _ labels: [String],
  targets: [JumpTarget],
  recorder: ConsoleIntegrationRecorder
) {
  for label in labels {
    if targets.contains(where: { $0.accessibilityLabel == label }) {
      recorder.fail("forbidden native target was hinted label=\(label)")
    } else {
      recorder.pass("forbidden native target absent label=\(label)")
    }
  }
}

private func clickTarget(
  label: String,
  targets: [JumpTarget],
  statePath: String,
  expectedState: (key: String, value: Int)?,
  recorder: ConsoleIntegrationRecorder
) {
  guard let target = targets.first(where: { $0.accessibilityLabel == label }) else {
    recorder.fail("could not find native target label=\(label)")
    return
  }
  postMouseClick(
    at: CGPoint(x: target.frame.midX, y: target.frame.midY),
    action: .leftClick)
  if let expectedState {
    do {
      try waitForState(
        path: statePath,
        key: expectedState.key,
        value: expectedState.value,
        timeout: 3)
      recorder.pass("native host click updated state label=\(label)")
    } catch {
      recorder.fail("native host-click state check failed label=\(label): \(error)")
    }
  } else {
    recorder.pass("native target accepted host click label=\(label)")
  }
}

private func runOpenMenuProbe(
  args: Args,
  provider: AccessibilityProvider,
  recorder: ConsoleIntegrationRecorder,
  timer: IntegrationTimer
) {
  terminateRunningFixture(bundleID: args.fixtureBundleID)
  do {
    let app = try launchFixture(
      appPath: args.fixtureAppPath,
      bundleID: args.fixtureBundleID,
      arguments: ["--open-menu-on-launch"],
      timer: timer)
    defer { terminateRunningFixture(bundleID: args.fixtureBundleID) }
    Thread.sleep(forTimeInterval: 1.0)
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let rawMenuItems = AXIntegrationHarness.walk(root: root, maxNodes: 4_000)
      .filter { $0.role == "AXMenuItem" }
    let targets = timer.measure("native_open_menu_discover") {
      AXIntegrationHarness.discoverFinalizedTargets(app: app, provider: provider)
    }
    let hintedMenuItems = targets.filter { $0.role == "AXMenuItem" }
    recorder.pass("open menu raw AXMenuItem count=\(rawMenuItems.count)")
    if hintedMenuItems.isEmpty {
      recorder.pass(
        "open NSMenu remains unsupported under the current no-key-capture production path")
    } else {
      recorder.fail(
        "open NSMenu produced \(hintedMenuItems.count) menu-item hints without a compliant input path"
      )
    }
  } catch {
    recorder.fail("open menu probe failed: \(error)")
  }
}

private struct AXMatchedNode {
  var element: AXUIElement
  var frame: CGRect?
}

private func waitForAXNode(
  app: NSRunningApplication,
  labels: Set<String>,
  timeout: TimeInterval
) -> AXMatchedNode? {
  let roots = axStatusItemSearchRoots(app: app)
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    for root in roots {
      if let match = findAXNode(root: root, labels: labels, maxNodes: 8_000) {
        return match
      }
    }
    Thread.sleep(forTimeInterval: 0.2)
  }
  return nil
}

private func findAXNode(
  root: AXUIElement,
  labels: Set<String>,
  maxNodes: Int
) -> AXMatchedNode? {
  var queue: [(AXUIElement, Int)] = [(root, 0)]
  var visited = 0
  while !queue.isEmpty, visited < maxNodes {
    let (element, _) = queue.removeFirst()
    visited += 1
    let label = AXIntegrationHarness.label(of: element)
    let frame = AXIntegrationHarness.frame(of: element)
    if let label, frame != nil, labels.contains(label) {
      return AXMatchedNode(
        element: element,
        frame: frame)
    }
    queue.append(contentsOf: AXIntegrationHarness.children(of: element).map { ($0, 0) })
  }
  return nil
}

private func axStatusItemSearchRoots(app: NSRunningApplication) -> [AXUIElement] {
  var roots: [AXUIElement] = []
  appendStatusItemRoots(from: AXUIElementCreateApplication(app.processIdentifier), to: &roots)
  for systemUI in NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.SystemUIServer")
  {
    appendStatusItemRoots(
      from: AXUIElementCreateApplication(systemUI.processIdentifier), to: &roots)
  }
  appendStatusItemRoots(from: AXUIElementCreateSystemWide(), to: &roots)
  return roots
}

private func appendStatusItemRoots(from root: AXUIElement, to roots: inout [AXUIElement]) {
  roots.append(root)
  for attribute in [kAXExtrasMenuBarAttribute as CFString, kAXMenuBarAttribute as CFString] {
    if let element = axElementAttribute(root, attribute) {
      roots.append(element)
    }
  }
}

private func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
  var raw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return (value as! AXUIElement)
}

private func runResidentModeProbe(
  args: Args,
  app: NSRunningApplication,
  targets: [JumpTarget],
  recorder: ConsoleIntegrationRecorder
) {
  guard !args.skipResidentModeTests else {
    recorder.pass("resident mode probe skipped")
    return
  }
  do {
    _ = try fetchFlashState(args: args, timeout: 4)
    guard
      let statusNode = waitForAXNode(
        app: app,
        labels: ["FlashNativeStatus"],
        timeout: 4),
      let statusFrame = statusNode.frame
    else {
      recorder.fail("resident status item AX frame not found")
      return
    }

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)

    let hintButtonBefore = readState(args.statePath)["primary", default: 0]
    try commitResidentHint(label: "Primary Action", args: args)
    try waitForState(
      path: args.statePath, key: "primary", value: hintButtonBefore + 1, timeout: 4)
    assertFlashMode("normal", args: args, recorder: recorder, label: "non-input hint commit")

    try commitResidentHint(label: "Native Search Field", args: args)
    assertFlashMode("insert", args: args, recorder: recorder, label: "input hint commit")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    try commitResidentGrid(app: app, targets: targets, args: args)
    assertFlashMode("insert", args: args, recorder: recorder, label: "non-input mouse_grid commit")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    let pointerCommandBefore = readState(args.statePath)["primary", default: 0]
    let primaryPoint = try targetCenter(label: "Primary Action", targets: targets)
    CGWarpMouseCursorPosition(cgScreenPoint(from: primaryPoint))
    try runFlash("mouse_pointer", args: args)
    postKey(CGKeyCode(kVK_Return))
    try waitForState(
      path: args.statePath, key: "primary", value: pointerCommandBefore + 1, timeout: 4)
    assertFlashMode("normal", args: args, recorder: recorder, label: "pointer command button click")

    let primaryBefore = readState(args.statePath)["primary", default: 0]
    postMouseClick(
      at: try targetCenter(label: "Primary Action", targets: targets), action: .leftClick)
    try waitForState(path: args.statePath, key: "primary", value: primaryBefore + 1, timeout: 4)
    assertFlashMode("insert", args: args, recorder: recorder, label: "native button left click")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    postMouseClick(
      at: try targetCenter(label: "Native Search Field", targets: targets),
      action: .leftClick)
    assertFlashMode("insert", args: args, recorder: recorder, label: "native text field click")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    let contextBefore = readState(args.statePath)["context_menu", default: 0]
    postMouseClick(
      at: try targetCenter(label: "Context Target", targets: targets), action: .rightClick)
    try waitForState(
      path: args.statePath,
      key: "context_menu",
      value: contextBefore + 1,
      timeout: 4)
    assertFlashMode("normal", args: args, recorder: recorder, label: "native context right click")
    postKey(CGKeyCode(kVK_Escape))

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    let statusBefore = readState(args.statePath)["status_popover", default: 0]
    let statusCloseBefore = readState(args.statePath)["status_popover_closed", default: 0]
    postMouseClick(at: CGPoint(x: statusFrame.midX, y: statusFrame.midY), action: .leftClick)
    assertFlashMode("normal", args: args, recorder: recorder, label: "native status item CG click")
    if (try? waitForState(
      path: args.statePath,
      key: "status_popover",
      value: statusBefore + 1,
      timeout: 0.7)) != nil
    {
      recorder.pass("resident status item opened from CG click")
    } else {
      let error = AXUIElementPerformAction(statusNode.element, kAXPressAction as CFString)
      guard error == .success else {
        recorder.fail("resident status item AXPress fallback failed error=\(error.rawValue)")
        return
      }
      try waitForState(
        path: args.statePath,
        key: "status_popover",
        value: statusBefore + 1,
        timeout: 4)
      recorder.pass("resident status item opened from AXPress after menu-bar pointer handoff")
    }
    assertFlashMode("normal", args: args, recorder: recorder, label: "native status item popover")
    Thread.sleep(forTimeInterval: 0.35)
    let statusCloseAfter = readState(args.statePath)["status_popover_closed", default: 0]
    if statusCloseAfter == statusCloseBefore {
      recorder.pass("resident status item popover stayed open")
    } else {
      recorder.fail("resident status item popover closed during normal-mode handoff")
    }
    postKey(CGKeyCode(kVK_Escape))
  } catch {
    recorder.fail("resident mode probe failed: \(error)")
  }
}

private let args = parseArgs()
private let recorder = ConsoleIntegrationRecorder()
private let timer = IntegrationTimer()
private let provider = AccessibilityProvider()

do {
  try ensureUnlockedConsole()
  try ensureAccessibility()
  try? FileManager.default.removeItem(atPath: args.statePath)
  terminateRunningFixture(bundleID: args.fixtureBundleID)

  let expected = [
    ExpectedIntegrationTarget(id: "primary", label: "Primary Action", role: "AXButton"),
    ExpectedIntegrationTarget(id: "icon", label: "Icon Action", role: "AXButton"),
    ExpectedIntegrationTarget(id: "duplicate-a", label: "Duplicate Action", role: "AXButton"),
    ExpectedIntegrationTarget(id: "duplicate-b", label: "Duplicate Action", role: "AXButton"),
    ExpectedIntegrationTarget(id: "toggle", label: "Toggle Option", role: "AXCheckBox"),
    ExpectedIntegrationTarget(id: "radio", label: "Radio Choice", role: "AXRadioButton"),
    ExpectedIntegrationTarget(id: "popup", label: "Menu Choice", role: "AXPopUpButton"),
    ExpectedIntegrationTarget(id: "search", label: "Native Search Field", role: "AXTextField"),
    ExpectedIntegrationTarget(id: "notes", label: "Native Notes Area", role: "AXTextArea"),
    ExpectedIntegrationTarget(id: "tab-general", label: "General Tab"),
    ExpectedIntegrationTarget(id: "tab-advanced", label: "Advanced Tab"),
    ExpectedIntegrationTarget(id: "slider", label: "Native Slider", role: "AXSlider"),
    ExpectedIntegrationTarget(id: "open-menu", label: "Open Fixture Menu", role: "AXButton"),
    ExpectedIntegrationTarget(id: "context-target", label: "Context Target", role: "AXButton"),
  ]

  let app = try launchFixture(
    appPath: args.fixtureAppPath,
    bundleID: args.fixtureBundleID,
    arguments: ["--state-file", args.statePath]
      + (args.fixtureLargeTableRows.map { ["--large-table", "\($0)"] } ?? []),
    timer: timer)
  defer { terminateRunningFixture(bundleID: args.fixtureBundleID) }

  if var bench = args.bench {
    bench.flashCLIPath = args.flashCLIPath
    if let url = URL(string: args.flashStateURL) { bench.stateURL = url }
    try bench.run(activate: { app.activate() }, log: recorder.info)
    recorder.info("PASS native hint benchmark")
    exit(0)
  }

  let targets = waitForTargets(
    app: app,
    provider: provider,
    expected: expected,
    timeout: 8,
    timer: timer)
  let diff = IntegrationTargetMatcher.classify(
    expected: expected,
    actual: targets,
    allowedUnexpectedLabels: ["Rows", "Row Alpha", "Row Beta", "Row Gamma", "Search"],
    ignoreUnlabeledUnexpected: true)
  reportDiff(diff, recorder: recorder)

  assertAbsentLabels(
    [
      "Decorative Image",
      "Disabled Action",
      "Disabled Text Field",
      "Flash Native Fixture",
      "Hidden Action",
    ],
    targets: targets,
    recorder: recorder)

  clickTarget(
    label: "Primary Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "primary", value: 1),
    recorder: recorder)
  clickTarget(
    label: "Icon Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "icon", value: 1),
    recorder: recorder)
  clickTarget(
    label: "Duplicate Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "duplicate", value: 1),
    recorder: recorder)
  clickTarget(
    label: "Toggle Option",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "toggle", value: 1),
    recorder: recorder)
  clickTarget(
    label: "Radio Choice",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "radio", value: 1),
    recorder: recorder)
  clickTarget(
    label: "Native Search Field",
    targets: targets,
    statePath: args.statePath,
    expectedState: nil,
    recorder: recorder)
  clickTarget(
    label: "Native Notes Area",
    targets: targets,
    statePath: args.statePath,
    expectedState: nil,
    recorder: recorder)

  runResidentCapturedTargetProbes(args: args, app: app, recorder: recorder)
  runResidentModeProbe(args: args, app: app, targets: targets, recorder: recorder)
  runResidentEmojiInsertionProbe(args: args, app: app, recorder: recorder)

  runOpenMenuProbe(args: args, provider: provider, recorder: recorder, timer: timer)

  if let timingsPath = args.timingsPath {
    try timer.writeJSON(to: URL(fileURLWithPath: timingsPath))
    recorder.pass("wrote timings to \(timingsPath)")
  }

  if recorder.failures.count > 0 {
    exit(1)
  }
  recorder.info("PASS native integration oracle")
  exit(0)
} catch {
  recorder.fail(String(describing: error))
  if let timingsPath = args.timingsPath {
    try? timer.writeJSON(to: URL(fileURLWithPath: timingsPath))
  }
  exit(2)
}
