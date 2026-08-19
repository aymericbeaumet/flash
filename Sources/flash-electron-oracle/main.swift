import AppKit
import ApplicationServices
import Darwin
import FlashCore
import FlashIntegrationTestSupport
import FlashProviders
import Foundation

private struct Args {
  var fixtureDirectory: String = "Tests/ElectronFixture"
  var electronAppPath: String?
  var electronBundleID: String = "com.github.Electron"
  var expectedPath: String = "/tmp/flash-electron-expected.json"
  var statePath: String = "/tmp/flash-electron-state.json"
  var timingsPath: String?
}

private struct ElectronExpectedPayload: Decodable {
  let targets: [ExpectedIntegrationTarget]
}

private enum OracleError: Error, CustomStringConvertible {
  case accessibilityMissing
  case electronMissing(String)
  case launchFailed(String)
  case appNotFound
  case axWindowTimedOut
  case expectedTimedOut(String)
  case stateTimedOut(String)

  var description: String {
    switch self {
    case .accessibilityMissing:
      return "Accessibility permission is missing for the Electron oracle app"
    case .electronMissing(let path):
      return "Electron app not found at \(path). Run npm ci in Tests/ElectronFixture first."
    case .launchFailed(let message):
      return "Electron launch failed: \(message)"
    case .appNotFound:
      return "Could not resolve Electron as an NSRunningApplication"
    case .axWindowTimedOut:
      return "Electron fixture did not expose an AX window before timeout"
    case .expectedTimedOut(let path):
      return "Timed out waiting for expected target JSON at \(path)"
    case .stateTimedOut(let expected):
      return "Timed out waiting for fixture state \(expected)"
    }
  }
}

private func parseArgs() -> Args {
  var args = Args()
  var iter = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = iter.next() {
    switch arg {
    case "--fixture-dir":
      args.fixtureDirectory = iter.next() ?? args.fixtureDirectory
    case "--electron-app":
      args.electronAppPath = iter.next()
    case "--electron-bundle-id":
      args.electronBundleID = iter.next() ?? args.electronBundleID
    case "--expected-file":
      args.expectedPath = iter.next() ?? args.expectedPath
    case "--state-file":
      args.statePath = iter.next() ?? args.statePath
    case "--timings":
      args.timingsPath = iter.next()
    case "--help", "-h":
      print(
        """
        flash-electron-oracle [--fixture-dir <path>] [--electron-app <path>]
                              [--expected-file <path>] [--state-file <path>]

        Launches the pinned Electron fixture, compares its expected DOM targets
        against Flash's AX provider output, and verifies a host click updates
        fixture state.
        """)
      exit(0)
    default:
      fputs("Unknown argument: \(arg)\n", stderr)
      exit(2)
    }
  }
  return args
}

private func ensureAccessibility() throws {
  if AXIsProcessTrusted() { return }
  let opts: NSDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
  ]
  _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
  throw OracleError.accessibilityMissing
}

private func defaultElectronAppPath(fixtureDirectory: String) -> String {
  URL(fileURLWithPath: fixtureDirectory)
    .appendingPathComponent("node_modules/electron/dist/Electron.app")
    .standardizedFileURL.path
}

private func launchElectronFixture(args: Args, timer: IntegrationTimer) throws
  -> (Process, NSRunningApplication)
{
  let appPath =
    args.electronAppPath ?? defaultElectronAppPath(fixtureDirectory: args.fixtureDirectory)
  guard FileManager.default.fileExists(atPath: appPath) else {
    throw OracleError.electronMissing(appPath)
  }
  let executable = URL(fileURLWithPath: appPath)
    .appendingPathComponent("Contents/MacOS/Electron")
    .path
  guard FileManager.default.isExecutableFile(atPath: executable) else {
    throw OracleError.electronMissing(executable)
  }
  let before = Set(
    NSRunningApplication.runningApplications(withBundleIdentifier: args.electronBundleID)
      .map { $0.processIdentifier })
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = [
    URL(fileURLWithPath: args.fixtureDirectory).standardizedFileURL.path,
    "--expected-file", args.expectedPath,
    "--state-file", args.statePath,
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.standardError
  timer.mark("electron_launch_start", detail: "app=\(appPath)")
  do {
    try process.run()
  } catch {
    throw OracleError.launchFailed(String(describing: error))
  }

  let app =
    AXIntegrationHarness.waitForRunningApplication(
      bundleIdentifier: args.electronBundleID,
      excluding: before,
      timeout: 12)
    ?? NSRunningApplication(processIdentifier: process.processIdentifier)
  guard let app else { throw OracleError.appNotFound }
  app.activate()
  guard AXIntegrationHarness.waitForAXWindow(app, timeout: 20) else {
    throw OracleError.axWindowTimedOut
  }
  timer.mark("electron_launch_ready", detail: "pid=\(app.processIdentifier)")
  return (process, app)
}

private func waitForExpectedTargets(path: String, timeout: TimeInterval) throws
  -> [ExpectedIntegrationTarget]
{
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let data = FileManager.default.contents(atPath: path),
      let payload = try? JSONDecoder().decode(ElectronExpectedPayload.self, from: data),
      !payload.targets.isEmpty
    {
      return payload.targets
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  throw OracleError.expectedTimedOut(path)
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
    app.activate()
    last = timer.measure("electron_discover") {
      AXIntegrationHarness.discoverFinalizedTargets(app: app, provider: provider)
    }
    let diff = IntegrationTargetMatcher.classify(
      expected: expected,
      actual: last,
      ignoreUnlabeledUnexpected: true)
    if diff.missing.isEmpty { return last }
    Thread.sleep(forTimeInterval: 0.3)
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

private func performHostClick(_ target: JumpTarget) -> Bool {
  let nsPoint = CGPoint(x: target.frame.midX, y: target.frame.midY)
  let point = CGPoint(
    x: nsPoint.x,
    y: AXIntegrationHarness.primaryScreenHeight() - nsPoint.y)
  let source = CGEventSource(stateID: .hidSystemState)
  guard
    let down = CGEvent(
      mouseEventSource: source,
      mouseType: .leftMouseDown,
      mouseCursorPosition: point,
      mouseButton: .left),
    let up = CGEvent(
      mouseEventSource: source,
      mouseType: .leftMouseUp,
      mouseCursorPosition: point,
      mouseButton: .left)
  else { return false }
  CGWarpMouseCursorPosition(point)
  Thread.sleep(forTimeInterval: 0.03)
  down.post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.05)
  up.post(tap: .cghidEventTap)
  return true
}

private func terminateElectronFixture(process: Process, app: NSRunningApplication) {
  app.terminate()
  process.terminate()
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if app.isTerminated, !process.isRunning { return }
    Thread.sleep(forTimeInterval: 0.1)
  }
  if !app.isTerminated {
    app.forceTerminate()
  }
  if process.isRunning {
    kill(process.processIdentifier, SIGKILL)
  }
}

private func reportDiff(_ diff: IntegrationTargetDiff, recorder: ConsoleIntegrationRecorder) {
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

private let args = parseArgs()
private let recorder = ConsoleIntegrationRecorder()
private let timer = IntegrationTimer()
private let provider = AccessibilityProvider()

do {
  try ensureAccessibility()
  try? FileManager.default.removeItem(atPath: args.expectedPath)
  try? FileManager.default.removeItem(atPath: args.statePath)

  let (process, app) = try launchElectronFixture(args: args, timer: timer)
  defer {
    terminateElectronFixture(process: process, app: app)
  }

  let expected = try timer.measure("electron_expected_wait") {
    try waitForExpectedTargets(path: args.expectedPath, timeout: 12)
  }
  let targets = waitForTargets(
    app: app,
    provider: provider,
    expected: expected,
    timeout: 10,
    timer: timer)
  let diff = IntegrationTargetMatcher.classify(
    expected: expected,
    actual: targets,
    ignoreUnlabeledUnexpected: true)
  reportDiff(diff, recorder: recorder)

  if targets.contains(where: { $0.accessibilityLabel == "Electron Disabled" }) {
    recorder.fail("disabled Electron button was hinted")
  } else {
    recorder.pass("disabled Electron button is not hinted")
  }

  if let primary = targets.first(where: { $0.accessibilityLabel == "Electron Primary" }),
    performHostClick(primary)
  {
    try waitForState(path: args.statePath, key: "primary", value: 1, timeout: 4)
    recorder.pass("host click on Electron button updated fixture state")
  } else {
    recorder.fail("could not click Electron Primary target")
  }

  if let timingsPath = args.timingsPath {
    try timer.writeJSON(to: URL(fileURLWithPath: timingsPath))
    recorder.pass("wrote timings to \(timingsPath)")
  }

  if recorder.failures.count > 0 {
    exit(1)
  }
  recorder.info("PASS electron integration oracle")
  exit(0)
} catch {
  recorder.fail(String(describing: error))
  if let timingsPath = args.timingsPath {
    try? timer.writeJSON(to: URL(fileURLWithPath: timingsPath))
  }
  exit(2)
}
