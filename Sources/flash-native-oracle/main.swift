import AppKit
import ApplicationServices
import FlashCore
import FlashIntegrationTestSupport
import FlashProviders
import Foundation

private struct Args {
  var fixtureAppPath: String = "/Applications/Flash Native Fixture.app"
  var fixtureBundleID: String = "com.flash.native-fixture"
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
    case "--state-file":
      args.statePath = iter.next() ?? args.statePath
    case "--timings":
      args.timingsPath = iter.next()
    case "--help", "-h":
      print(
        """
        flash-native-oracle [--fixture-app <path>] [--state-file <path>] [--timings <path>]

        Launches the Flash native AppKit fixture, compares Flash's generic
        AX targets against expected native controls, verifies AXPress state,
        and records the current open-NSMenu limitation under the production
        no-key-capture rule.
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
  case stateTimedOut(String)

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
    case .stateTimedOut(let expected):
      return "Timed out waiting for fixture state \(expected)"
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
    ExpectedIntegrationTarget(id: "search", label: "Native Search Field", role: "AXSearchField"),
    ExpectedIntegrationTarget(id: "notes", label: "Native Notes Area", role: "AXTextArea"),
    ExpectedIntegrationTarget(id: "tab-general", label: "General Tab"),
    ExpectedIntegrationTarget(id: "tab-advanced", label: "Advanced Tab"),
    ExpectedIntegrationTarget(id: "open-menu", label: "Open Fixture Menu", role: "AXButton"),
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
    allowedUnexpectedLabels: ["Rows", "Row Alpha", "Row Beta", "Row Gamma"],
    ignoreUnlabeledUnexpected: true)
  reportDiff(diff, recorder: recorder)

  assertAbsentLabels(
    [
      "Decorative Image",
      "Disabled Action",
      "Disabled Text Field",
      "Flash Native Fixture",
      "Hidden Action",
      "Native Slider",
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
