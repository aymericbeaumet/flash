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
    case "--help", "-h":
      print(
        """
        flash-native-oracle [--fixture-app <path>] [--state-file <path>] [--timings <path>]
                            [--flash-cli <path>] [--flash-state-url <url>]
                            [--skip-resident-mode-tests]

        Launches the Flash native AppKit fixture, compares Flash's generic
        AX targets against expected native controls, verifies AXPress state,
        and drives the installed Flash resident through real pointer
        interactions to guard normal/insert mode handoff behavior.
        """)
      exit(0)
    default:
      fputs("Unknown argument: \(arg)\n", stderr)
      exit(2)
    }
  }
  return args
}

private enum OracleError: Error, CustomStringConvertible {
  case accessibilityMissing
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

private func runFlash(_ verb: String, args: Args) throws {
  guard FileManager.default.isExecutableFile(atPath: args.flashCLIPath) else {
    throw OracleError.flashCLIUnavailable(args.flashCLIPath)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: args.flashCLIPath)
  process.arguments = [verb]
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
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
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
  case .doubleClick:
    for click in 1...2 {
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

private func postEscapeKey() {
  let source = CGEventSource(stateID: .hidSystemState)
  CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?
    .post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.02)
  CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?
    .post(tap: .cghidEventTap)
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

private func activateTarget(
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
  guard target.activate?(.leftClick) == true else {
    recorder.fail("native target activation returned false label=\(label)")
    return
  }
  if let expectedState {
    do {
      try waitForState(
        path: statePath,
        key: expectedState.key,
        value: expectedState.value,
        timeout: 3)
      recorder.pass("native activation updated state label=\(label)")
    } catch {
      recorder.fail("native activation state check failed label=\(label): \(error)")
    }
  } else {
    recorder.pass("native target accepted AX activation label=\(label)")
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
  for systemUI in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SystemUIServer") {
    appendStatusItemRoots(from: AXUIElementCreateApplication(systemUI.processIdentifier), to: &roots)
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

    let primaryBefore = readState(args.statePath)["primary", default: 0]
    postMouseClick(at: try targetCenter(label: "Primary Action", targets: targets), action: .leftClick)
    try waitForState(path: args.statePath, key: "primary", value: primaryBefore + 1, timeout: 4)
    assertFlashMode("normal", args: args, recorder: recorder, label: "native button left click")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    postMouseClick(
      at: try targetCenter(label: "Native Search Field", targets: targets),
      action: .leftClick)
    assertFlashMode("insert", args: args, recorder: recorder, label: "native text field click")

    try runFlash("enter_normal_mode", args: args)
    try waitForFlashMode("normal", args: args, timeout: 4)
    let contextBefore = readState(args.statePath)["context_menu", default: 0]
    postMouseClick(at: try targetCenter(label: "Context Target", targets: targets), action: .rightClick)
    try waitForState(
      path: args.statePath,
      key: "context_menu",
      value: contextBefore + 1,
      timeout: 4)
    assertFlashMode("normal", args: args, recorder: recorder, label: "native context right click")
    postEscapeKey()

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
    postEscapeKey()
  } catch {
    recorder.fail("resident mode probe failed: \(error)")
  }
}

private let args = parseArgs()
private let recorder = ConsoleIntegrationRecorder()
private let timer = IntegrationTimer()
private let provider = AccessibilityProvider()

do {
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
    arguments: ["--state-file", args.statePath],
    timer: timer)
  defer { terminateRunningFixture(bundleID: args.fixtureBundleID) }

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

  activateTarget(
    label: "Primary Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "primary", value: 1),
    recorder: recorder)
  activateTarget(
    label: "Icon Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "icon", value: 1),
    recorder: recorder)
  activateTarget(
    label: "Duplicate Action",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "duplicate", value: 1),
    recorder: recorder)
  activateTarget(
    label: "Toggle Option",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "toggle", value: 1),
    recorder: recorder)
  activateTarget(
    label: "Radio Choice",
    targets: targets,
    statePath: args.statePath,
    expectedState: (key: "radio", value: 1),
    recorder: recorder)
  activateTarget(
    label: "Native Search Field",
    targets: targets,
    statePath: args.statePath,
    expectedState: nil,
    recorder: recorder)
  activateTarget(
    label: "Native Notes Area",
    targets: targets,
    statePath: args.statePath,
    expectedState: nil,
    recorder: recorder)

  runResidentModeProbe(args: args, app: app, targets: targets, recorder: recorder)

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
