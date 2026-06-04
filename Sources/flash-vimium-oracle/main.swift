import AppKit
import ApplicationServices
import FlashBrowserTestSupport
import FlashCore
import FlashProviders
import Foundation

// MARK: - Output

private enum Colour {
  static let red = "\u{1B}[31m"
  static let green = "\u{1B}[32m"
  static let yellow = "\u{1B}[33m"
  static let bold = "\u{1B}[1m"
  static let reset = "\u{1B}[0m"
}

private let outputLock = NSLock()

private func log(_ s: String) {
  outputLock.lock()
  print(s)
  fflush(stdout)
  outputLock.unlock()
}

private func logErr(_ s: String) {
  outputLock.lock()
  if let data = (s + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
  outputLock.unlock()
}

final class CLIRecorder: FirefoxE2ERecorder {
  private let lock = NSLock()
  private var storedFailures: [String] = []

  var failures: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedFailures
  }

  func pass(_ msg: String) { log("\(Colour.green)✓\(Colour.reset) \(msg)") }

  func fail(_ msg: String) {
    lock.lock()
    storedFailures.append(msg)
    lock.unlock()
    log("\(Colour.red)✗\(Colour.reset) \(msg)")
  }
}

// MARK: - Args

struct Args {
  var fixturesDirectory: URL
  var fixtureNames: [String]
  var updateAllowList: Bool
  var jobs: Int
  var browserAppPath: String
}

private func defaultFixturesDirectory() -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/BrowserSnapshots", isDirectory: true)
}

private func defaultJobs() -> Int {
  let cores = ProcessInfo.processInfo.activeProcessorCount
  return min(8, max(2, cores / 2))
}

private func parseJobs(_ raw: String) -> Int? {
  if raw == "auto" { return defaultJobs() }
  guard let value = Int(raw), value > 0 else { return nil }
  return value
}

private func parseArgs() -> Args {
  var fixturesDirectory = defaultFixturesDirectory()
  var fixtureNames: [String] = []
  var updateAllowList = false
  var jobs = defaultJobs()
  var browserAppPath = BrowserTestProfile.defaultAppPath()
  var iter = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = iter.next() {
    switch arg {
    case "--fixture":
      guard let name = iter.next() else {
        logErr("--fixture requires a value")
        exit(2)
      }
      fixtureNames.append(name)
    case "--fixtures-dir":
      guard let path = iter.next() else {
        logErr("--fixtures-dir requires a value")
        exit(2)
      }
      fixturesDirectory = URL(fileURLWithPath: path)
    case "--jobs":
      guard let raw = iter.next(), let parsed = parseJobs(raw) else {
        logErr("--jobs requires a positive integer or 'auto'")
        exit(2)
      }
      jobs = parsed
    case "--browser-app":
      guard let path = iter.next() else {
        logErr("--browser-app requires a value")
        exit(2)
      }
      browserAppPath = path
    case "--update-allow-list":
      updateAllowList = true
    case "--help", "-h":
      log(
        """
        flash-vimium-oracle [--fixture <name>] [--fixtures-dir <path>] [--jobs <n|auto>]

        Compare Flash's AX-derived hint set against what Vimium-FF hints
        on each browser fixture. Strict ISO: any divergence not covered
        by a fixture allow-list JSON sidecar fails the runner.

          --fixture <name>      Run one fixture. May be repeated.
          --fixtures-dir <path> Directory containing manifest.json,
                                snapshots/, and allowlists/.
          --jobs <n|auto>      Parallel Firefox workers. Default: auto.
          --browser-app <path> Firefox-family .app path. Default: Firefox.app,
                                then Firefox Developer Edition.app.
          --update-allow-list  Print suggested allow-list JSON entries to
                                stderr and exit 0 even when divergences exist.
        """)
      exit(0)
    default:
      logErr("Unknown argument: \(arg)")
      exit(2)
    }
  }
  return Args(
    fixturesDirectory: fixturesDirectory,
    fixtureNames: fixtureNames,
    updateAllowList: updateAllowList,
    jobs: jobs,
    browserAppPath: browserAppPath)
}

// MARK: - Preflight

private func ensureAccessibilityOrExit() {
  if AXIsProcessTrusted() { return }
  let opts: NSDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
  ]
  if AXIsProcessTrustedWithOptions(opts as CFDictionary) { return }

  let me = (CommandLine.arguments.first as NSString?)?.standardizingPath ?? "<self>"
  let grantPath: String = {
    if let range = me.range(of: ".app/Contents/MacOS/") {
      return String(me[..<range.lowerBound]) + ".app"
    }
    return me
  }()
  logErr(
    """
    \(Colour.red)Accessibility permission missing.\(Colour.reset)

    macOS should have just shown a prompt. Click "Open System Settings"
    on the dialog, toggle the new entry on, and re-run this command.

    If no prompt appeared, grant manually:

      \(grantPath)

    Open System Settings → Privacy & Security → Accessibility → + →
    ⌘⇧G → paste the path above → Open → toggle the new entry on.
    """)
  exit(2)
}

private func ensureBrowserProfileReadyOrExit(appPath: String) {
  do {
    try BrowserTestProfile.verifyReady(appPath: appPath)
  } catch let e as BrowserTestProfile.SetupError {
    logErr("\(Colour.red)\(e)\(Colour.reset)")
    exit(2)
  } catch {
    logErr("\(Colour.red)\(error)\(Colour.reset)")
    exit(2)
  }
}

// MARK: - Session + worker state

final class OracleSession {
  let workerID: Int
  let firefox: NSRunningApplication
  let marionette: MarionetteClient
  let context: AppContext
  let profilePath: String

  init(
    workerID: Int,
    firefox: NSRunningApplication,
    marionette: MarionetteClient,
    context: AppContext,
    profilePath: String
  ) {
    self.workerID = workerID
    self.firefox = firefox
    self.marionette = marionette
    self.context = context
    self.profilePath = profilePath
  }

  static func start(workerID: Int, appPath: String) throws -> OracleSession {
    let profile = try BrowserTestProfile.prepareWorkerProfile(workerID: workerID)
    let profilePath = profile.path
    let firefox = try FirefoxHarness.launchWithProfile(
      appPath: appPath,
      profilePath: profilePath,
      url: URL(string: "about:blank")!,
      extraArgs: [],
      offscreen: false,
      marionettePort: 0)
    guard let port = FirefoxHarness.readMarionettePort(profilePath: profilePath)
    else {
      firefox.terminate()
      throw SessionError.marionettePortMissing
    }
    let marionette = try MarionetteClient(port: port)
    try marionette.newSession()
    let context = FirefoxHarness.makeContext(for: firefox)
    return OracleSession(
      workerID: workerID,
      firefox: firefox,
      marionette: marionette,
      context: context,
      profilePath: profilePath)
  }

  func stop() {
    try? marionette.quit()
    marionette.close()
    firefox.terminate()
    let deadline = Date().addingTimeInterval(2)
    while !firefox.isTerminated, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if !firefox.isTerminated {
      firefox.forceTerminate()
    }
  }

  enum SessionError: Error, CustomStringConvertible {
    case marionettePortMissing
    var description: String {
      switch self {
      case .marionettePortMissing:
        return "Firefox didn't write MarionetteActivePort to the profile"
      }
    }
  }
}

private final class FixtureQueue {
  private let lock = NSLock()
  private let fixtures: [(Int, BrowserFixture)]
  private var nextIndex = 0

  init(fixtures: [BrowserFixture]) {
    self.fixtures = fixtures.enumerated().map { ($0.offset, $0.element) }
  }

  func next() -> (Int, BrowserFixture)? {
    lock.lock()
    defer { lock.unlock() }
    guard nextIndex < fixtures.count else { return nil }
    let item = fixtures[nextIndex]
    nextIndex += 1
    return item
  }
}

private struct FixtureSummary {
  let index: Int
  let name: String
  let workerID: Int
  let duration: TimeInterval
  let hardFailures: Int
}

private final class SummaryStore {
  private let lock = NSLock()
  private var summaries: [FixtureSummary] = []
  private var sessionFailures: [String] = []

  func append(_ summary: FixtureSummary) {
    lock.lock()
    summaries.append(summary)
    lock.unlock()
  }

  func failSession(_ message: String) {
    lock.lock()
    sessionFailures.append(message)
    lock.unlock()
  }

  var all: [FixtureSummary] {
    lock.lock()
    defer { lock.unlock() }
    return summaries
  }

  var failures: [String] {
    lock.lock()
    defer { lock.unlock() }
    return sessionFailures
  }
}

// MARK: - Per-fixture run

private func runFixture(
  index: Int,
  fixture: BrowserFixture,
  fixturesDirectory: URL,
  session: OracleSession,
  provider: AccessibilityProvider,
  recorder: CLIRecorder,
  updateAllowList: Bool
) -> FixtureSummary {
  let start = Date()
  log(
    "\n\(Colour.bold)[w\(session.workerID)] Running fixture \(index + 1): "
      + "\(fixture.displayName)\(Colour.reset)")

  let html: String
  do {
    html = try fixture.html(fixturesDirectory: fixturesDirectory)
  } catch {
    recorder.fail("[w\(session.workerID)] \(fixture.displayName): fixture read failed: \(error)")
    return FixtureSummary(
      index: index,
      name: fixture.displayName,
      workerID: session.workerID,
      duration: Date().timeIntervalSince(start),
      hardFailures: 1)
  }

  let server: FixtureServer
  do {
    server = try FixtureServer(html: html)
  } catch {
    recorder.fail("[w\(session.workerID)] \(fixture.displayName): fixture server failed: \(error)")
    return FixtureSummary(
      index: index,
      name: fixture.displayName,
      workerID: session.workerID,
      duration: Date().timeIntervalSince(start),
      hardFailures: 1)
  }
  defer { server.stop() }

  do {
    try session.marionette.navigate(url: server.url)
  } catch {
    recorder.fail("[w\(session.workerID)] \(fixture.displayName): navigate failed: \(error)")
    return FixtureSummary(
      index: index,
      name: fixture.displayName,
      workerID: session.workerID,
      duration: Date().timeIntervalSince(start),
      hardFailures: 1)
  }

  let snapshot: OracleSnapshot
  do {
    snapshot = try VimiumOracle.capture(
      firefox: session.firefox,
      context: session.context,
      provider: provider,
      marionette: session.marionette)
  } catch {
    recorder.fail("[w\(session.workerID)] \(fixture.displayName): capture failed: \(error)")
    return FixtureSummary(
      index: index,
      name: fixture.displayName,
      workerID: session.workerID,
      duration: Date().timeIntervalSince(start),
      hardFailures: 1)
  }

  let residual = String(format: "%.2f", snapshot.fiducialResidual)
  recorder.pass("[w\(session.workerID)] \(fixture.displayName): fiducial residual \(residual)pt")
  if snapshot.fiducialResidual > 2 {
    recorder.fail(
      "[w\(session.workerID)] \(fixture.displayName): fiducial residual "
        + "\(residual)pt > 2pt")
  }
  recorder.pass(
    "[w\(session.workerID)] \(fixture.displayName): vimium="
      + "\(snapshot.vimiumAnchors.count) anchors, flash="
      + "\(snapshot.flashTargets.count) AX targets")

  let pageRect = snapshot.pageScreenRect
  let pageFlash = snapshot.flashTargets.filter {
    pageRect.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
  }
  recorder.pass(
    "[w\(session.workerID)] \(fixture.displayName): page targets "
      + "\(pageFlash.count)/\(snapshot.flashTargets.count)")
  assertHintWidths(fixture: fixture, snapshot: snapshot, recorder: recorder)

  let allowList = fixture.loadAllowList(fixturesDirectory: fixturesDirectory)
  let result = OracleDiff.classify(
    vimium: snapshot.vimiumAnchors,
    flash: pageFlash,
    allowList: allowList)
  OracleDiff.report(result, fixtureName: fixture.displayName, recorder: recorder)

  if updateAllowList {
    let json = OracleDiff.suggestedAllowListJSON(result)
    logErr("\n--- suggested allow-list for \(fixture.displayName) ---")
    logErr(json)
    logErr("--- end ---\n")
  }
  return FixtureSummary(
    index: index,
    name: fixture.displayName,
    workerID: session.workerID,
    duration: Date().timeIntervalSince(start),
    hardFailures: result.hardFailures.count)
}

private func assertHintWidths(
  fixture: BrowserFixture,
  snapshot: OracleSnapshot,
  recorder: CLIRecorder
) {
  guard fixture.name.hasPrefix("baseline-synthetic") else { return }
  for sample in snapshot.hintWidthSamples {
    let line =
      "\(fixture.displayName): hint width viewport #\(sample.scrollIndex): "
      + "vimium targets=\(sample.vimiumTargetCount) max=\(sample.vimiumMaxLabelLength), "
      + "flash raw=\(sample.flashRawTargetCount) "
      + "visible=\(sample.flashTargetCount) max=\(sample.flashMaxLabelLength)"
    if sample.flashMaxLabelLength > sample.vimiumMaxLabelLength {
      recorder.fail(line)
    } else {
      recorder.pass(line)
    }
  }
}

// MARK: - Main

let args = parseArgs()
ensureAccessibilityOrExit()
ensureBrowserProfileReadyOrExit(appPath: args.browserAppPath)

let catalog: BrowserFixtureCatalog
do {
  catalog = try BrowserFixtureCatalog.load(from: args.fixturesDirectory)
} catch {
  logErr("\(Colour.red)Could not load browser fixture catalog: \(error)\(Colour.reset)")
  exit(2)
}

let fixtures: [BrowserFixture]
do {
  fixtures = try catalog.select(named: args.fixtureNames)
} catch {
  logErr("\(Colour.red)\(error)\(Colour.reset)")
  exit(2)
}

let jobs = min(max(1, args.jobs), max(1, fixtures.count))
log("\(Colour.bold)Flash Vimium Oracle\(Colour.reset)")
log("Fixtures: \(fixtures.count)")
log("Workers: \(jobs)")
log("Fixtures dir: \(args.fixturesDirectory.path)")
log("Firefox app: \(args.browserAppPath)")

private var sessions: [OracleSession] = []
private let summaries = SummaryStore()
private let recorder = CLIRecorder()
private let runStart = Date()

for workerID in 0..<jobs {
  do {
    let session = try OracleSession.start(workerID: workerID, appPath: args.browserAppPath)
    sessions.append(session)
  } catch {
    let msg = "[w\(workerID)] failed to start Firefox session: \(error)"
    summaries.failSession(msg)
    logErr("\(Colour.red)\(msg)\(Colour.reset)")
  }
}

if sessions.isEmpty {
  logErr("\(Colour.red)No Firefox worker sessions could be started\(Colour.reset)")
  exit(2)
}

private let queue = FixtureQueue(fixtures: fixtures)
DispatchQueue.concurrentPerform(iterations: sessions.count) { workerIndex in
  let session = sessions[workerIndex]
  defer { session.stop() }

  let provider = AccessibilityProvider()
  while let (index, fixture) = queue.next() {
    let summary = runFixture(
      index: index,
      fixture: fixture,
      fixturesDirectory: args.fixturesDirectory,
      session: session,
      provider: provider,
      recorder: recorder,
      updateAllowList: args.updateAllowList)
    summaries.append(summary)
  }
}

private let elapsed = Date().timeIntervalSince(runStart)
private let ordered = summaries.all.sorted { $0.index < $1.index }
private let hardFailures =
  ordered.reduce(0) { $0 + $1.hardFailures } + summaries.failures.count

log("")
log("\(Colour.bold)Summary\(Colour.reset)")
for summary in ordered {
  let status = summary.hardFailures == 0 ? "PASS" : "FAIL"
  let seconds = String(format: "%.2f", summary.duration)
  log(
    "\(status) [w\(summary.workerID)] \(summary.name) "
      + "\(seconds)s failures=\(summary.hardFailures)")
}
let elapsedString = String(format: "%.2f", elapsed)
log("Total: \(fixtures.count) fixture(s), \(jobs) worker(s), \(elapsedString)s")

if args.updateAllowList && hardFailures > 0 {
  log(
    "\(Colour.yellow)\(Colour.bold)REVIEW\(Colour.reset) — divergences "
      + "printed above; commit allow-list sidecars after review")
  exit(0)
}
if hardFailures > 0 {
  log(
    "\(Colour.red)\(Colour.bold)FAIL\(Colour.reset) — "
      + "\(recorder.failures.count + summaries.failures.count) assertion(s) failed")
  exit(1)
}
log("\(Colour.green)\(Colour.bold)PASS\(Colour.reset) — strict ISO held on all fixtures")
exit(0)
