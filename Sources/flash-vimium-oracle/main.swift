import AppKit
import ApplicationServices
import FlashCore
import FlashE2EKit
import FlashProviders
import Foundation

// MARK: - Why this exists
//
// Iterating on `AccessibilityProvider`'s hint-filtering logic without
// an oracle is risky — it's easy to drop a class of legitimate hints
// (regression) or let through decorative noise (over-match). This
// runner pins both ends down:
//   - Vimium-FF (real, signed) is the source of truth for "what should
//     be hinted" on a given page
//   - Flash's AX walker runs in parallel against the same Firefox
//     window
//   - A per-fixture diff is reported against strict ISO: any unmatched
//     element on either side is a failure unless covered by an
//     allow-list JSON sidecar
//
// See Scripts/vimium-oracle.sh for the all-in-one provision/build/run
// driver — it preserves the TCC Accessibility grant across rebuilds.

private enum Colour {
  static let red = "\u{1B}[31m"
  static let green = "\u{1B}[32m"
  static let yellow = "\u{1B}[33m"
  static let bold = "\u{1B}[1m"
  static let reset = "\u{1B}[0m"
}

private func log(_ s: String) {
  print(s)
  fflush(stdout)
}
private func logErr(_ s: String) {
  if let data = (s + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

final class CLIRecorder: FirefoxE2ERecorder {
  private(set) var failures: [String] = []
  func pass(_ msg: String) { log("\(Colour.green)✓\(Colour.reset) \(msg)") }
  func fail(_ msg: String) {
    failures.append(msg)
    log("\(Colour.red)✗\(Colour.reset) \(msg)")
  }
}

// MARK: - Args

struct Args {
  var fixtures: [OracleFixture]
  var updateAllowList: Bool
}

private func parseArgs() -> Args {
  var fixtures: [OracleFixture] = OracleFixture.allCases
  var updateAllowList = false
  var iter = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = iter.next() {
    switch arg {
    case "--fixture":
      guard let name = iter.next() else {
        logErr("--fixture requires a value")
        exit(2)
      }
      guard
        let f = OracleFixture.allCases.first(where: {
          $0.rawValue == name || $0.displayName == name
        })
      else {
        let known = OracleFixture.allCases.map { $0.displayName }.joined(separator: ", ")
        logErr("Unknown fixture: \(name). Known: \(known)")
        exit(2)
      }
      fixtures = [f]
    case "--update-allow-list":
      updateAllowList = true
    case "--help", "-h":
      log(
        """
        flash-vimium-oracle [--fixture <name>] [--update-allow-list]

        Compare Flash's AX-derived hint set against what Vimium-FF would
        hint on each fixture page. Strict ISO: any divergence not in the
        fixture's allow-list JSON sidecar fails the runner.

          --fixture <name>      Run a single fixture (default: all).
          --update-allow-list   Print suggested allow-list JSON entries to
                                stderr and exit 0 even when divergences exist
                                (use to seed a new fixture's sidecar).

        Firefox launches once at the start of the run (in background via
        `open -g`) and stays open. Each fixture re-uses the same window —
        the runner navigates between URLs via Marionette, so neither focus
        nor a new Firefox process is needed per fixture.
        """)
      exit(0)
    default:
      logErr("Unknown argument: \(arg)")
      exit(2)
    }
  }
  return Args(fixtures: fixtures, updateAllowList: updateAllowList)
}

// MARK: - Preflight

private func ensureAccessibilityOrExit() {
  if AXIsProcessTrusted() { return }
  // Not trusted yet. Re-check via the prompting variant — macOS will
  // pop its canonical "Allow X to control your computer using
  // Accessibility features?" dialog with a button that takes the user
  // straight to the right entry in System Settings. The call returns
  // immediately; it doesn't block on the user. On a fresh install this
  // is the most reliable path through the TCC dance: the system itself
  // adds the entry (it doesn't rely on the user finding the bundle in
  // the file picker).
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

    The bundle is codesigned with the stable "Flash Dev" identity so
    the grant persists across rebuilds.
    """)
  exit(2)
}

private func ensureOracleReadyOrExit() {
  do {
    try OracleProfile.verifyReady()
  } catch let e as OracleProfile.SetupError {
    logErr("\(Colour.red)\(e)\(Colour.reset)")
    exit(2)
  } catch {
    logErr("\(Colour.red)\(error)\(Colour.reset)")
    exit(2)
  }
}

// MARK: - Session + per-fixture run

/// Long-lived Firefox session. One Firefox process for the whole
/// corpus run; each fixture navigates the same window via Marionette
/// rather than spawning its own browser. Big win: ~5s of launch cost
/// paid once instead of per fixture, no per-fixture process churn,
/// and the user sees at most one Firefox icon in the dock.
final class OracleSession {
  let firefox: NSRunningApplication
  let marionette: MarionetteClient
  let context: AppContext

  init(firefox: NSRunningApplication, marionette: MarionetteClient, context: AppContext) {
    self.firefox = firefox
    self.marionette = marionette
    self.context = context
  }

  static func start() throws -> OracleSession {
    let profilePath = OracleProfile.profileDirectory.path
    // Wipe stale MarionetteActivePort from any prior run so we don't
    // race-read the previous port.
    let portFile = (profilePath as NSString)
      .appendingPathComponent("MarionetteActivePort")
    try? FileManager.default.removeItem(atPath: portFile)
    let firefox = try FirefoxHarness.launchWithProfile(
      appPath: OracleProfile.appPath,
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
      firefox: firefox, marionette: marionette, context: context)
  }

  func stop() {
    try? marionette.quit()
    marionette.close()
    firefox.terminate()
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

private func runFixture(
  _ fixture: OracleFixture,
  session: OracleSession,
  provider: AccessibilityProvider,
  recorder: CLIRecorder,
  updateAllowList: Bool,
  isFirst: Bool
) -> OracleDiff.Result? {
  log("\n\(Colour.bold)Running fixture: \(fixture.displayName)\(Colour.reset)")

  // Spin up a per-fixture localhost server with this fixture's HTML.
  // Firefox MV2 content scripts don't run on data: URLs, so we need a
  // real origin — fresh port per fixture so we don't reuse a stale
  // connection from the previous load.
  let server: FixtureServer
  do {
    server = try FixtureServer(html: fixture.html())
  } catch {
    recorder.fail("fixture server failed: \(error)")
    return nil
  }
  defer { server.stop() }

  // Pick a target tab. The first fixture re-uses Firefox's initial
  // tab; every subsequent fixture opens a fresh tab. All tabs stay
  // open across the run so the user can inspect any fixture's live
  // page state in Firefox after the oracle finishes.
  do {
    if !isFirst {
      let handle = try session.marionette.newWindow(type: "tab")
      try session.marionette.switchToWindow(handle: handle)
    }
    try session.marionette.navigate(url: server.url)
  } catch {
    recorder.fail("tab navigate failed: \(error)")
    return nil
  }

  let snapshot: OracleSnapshot
  do {
    snapshot = try VimiumOracle.capture(
      firefox: session.firefox, context: session.context, provider: provider,
      marionette: session.marionette)
  } catch {
    recorder.fail("capture failed: \(error)")
    return nil
  }

  let residual = String(format: "%.2f", snapshot.fiducialResidual)
  recorder.pass("fiducial residual: \(residual)pt (threshold 2pt)")
  if snapshot.fiducialResidual > 2 {
    recorder.fail(
      "fiducial residual \(residual)pt > 2pt — coordinate transform is "
        + "unreliable; divergences below are likely spurious")
  }
  recorder.pass(
    "vimium=\(snapshot.vimiumAnchors.count) anchors, "
      + "flash=\(snapshot.flashTargets.count) AX targets")

  // Vimium only ever hints page DOM, never Firefox chrome. Keep
  // Flash hits whose CENTER lies inside the projected viewport —
  // `intersects` was too lax and let in elements partially scrolled
  // off the top of the viewport (rects with negative y but height
  // crossing y=0) that Vimium correctly skips.
  let pageRect = snapshot.pageScreenRect
  let pageFlash = snapshot.flashTargets.filter {
    pageRect.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
  }
  recorder.pass(
    "page rect \(snapshot.pageScreenRect) — \(pageFlash.count)/"
      + "\(snapshot.flashTargets.count) flash targets in page area")

  let allowList = fixture.loadAllowList()
  let result = OracleDiff.classify(
    vimium: snapshot.vimiumAnchors, flash: pageFlash,
    allowList: allowList)
  OracleDiff.report(result, fixtureName: fixture.displayName, recorder: recorder)

  if updateAllowList {
    let json = OracleDiff.suggestedAllowListJSON(result)
    logErr("\n--- suggested allow-list for \(fixture.displayName) ---")
    logErr(json)
    logErr("--- end ---\n")
  }
  return result
}

// MARK: - Main

let args = parseArgs()
ensureAccessibilityOrExit()
ensureOracleReadyOrExit()

log("\(Colour.bold)Flash Vimium Oracle\(Colour.reset)")
log("Fixtures: \(args.fixtures.map { $0.displayName }.joined(separator: ", "))")

let provider = AccessibilityProvider()
let recorder = CLIRecorder()

// One Firefox launch for the whole corpus run.
let session: OracleSession
do {
  session = try OracleSession.start()
} catch {
  logErr("\(Colour.red)Failed to start Firefox session: \(error)\(Colour.reset)")
  exit(2)
}
defer { session.stop() }

var anyHardFailure = false
for (idx, fixture) in args.fixtures.enumerated() {
  guard
    let result = runFixture(
      fixture, session: session, provider: provider, recorder: recorder,
      updateAllowList: args.updateAllowList, isFirst: idx == 0)
  else {
    anyHardFailure = true
    continue
  }
  if !result.hardFailures.isEmpty {
    anyHardFailure = true
  }
}

log("")
if args.updateAllowList && anyHardFailure {
  log(
    "\(Colour.yellow)\(Colour.bold)REVIEW\(Colour.reset) — divergences "
      + "printed above; commit allow-list sidecars after review")
  exit(0)
}
if anyHardFailure {
  log(
    "\(Colour.red)\(Colour.bold)FAIL\(Colour.reset) — "
      + "\(recorder.failures.count) assertion(s) failed")
  exit(1)
}
log("\(Colour.green)\(Colour.bold)PASS\(Colour.reset) — strict ISO held on all fixtures")
exit(0)
