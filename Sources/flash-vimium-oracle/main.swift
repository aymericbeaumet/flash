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
  var visible: Bool
}

private func parseArgs() -> Args {
  var fixtures: [OracleFixture] = OracleFixture.allCases
  var updateAllowList = false
  var visible = false
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
    case "--visible":
      visible = true
    case "--help", "-h":
      log(
        """
        flash-vimium-oracle [--fixture <name>] [--update-allow-list] [--visible]

        Compare Flash's AX-derived hint set against what Vimium-FF would
        hint on each fixture page. Strict ISO: any divergence not in the
        fixture's allow-list JSON sidecar fails the runner.

          --fixture <name>      Run a single fixture (default: all).
          --update-allow-list   Print suggested allow-list JSON entries to
                                stderr and exit 0 even when divergences exist
                                (use to seed a new fixture's sidecar).
          --visible             Run Firefox on-screen (default: off-screen
                                window). True --headless was tested and
                                broken — Firefox doesn't expose an AX
                                tree without a real window. Off-screen
                                is the closest functional equivalent:
                                AX-walkable, invisible to the user.
        """)
      exit(0)
    default:
      logErr("Unknown argument: \(arg)")
      exit(2)
    }
  }
  return Args(fixtures: fixtures, updateAllowList: updateAllowList, visible: visible)
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

// MARK: - Per-fixture run

private func runFixture(
  _ fixture: OracleFixture,
  provider: AccessibilityProvider,
  recorder: CLIRecorder,
  updateAllowList: Bool,
  visible: Bool
) -> OracleDiff.Result? {
  log("\n\(Colour.bold)Running fixture: \(fixture.displayName)\(Colour.reset)")

  // Spin up a localhost server with the fixture HTML. Required because
  // Firefox MV2 content scripts don't run on data: URLs — without a
  // real origin, the companion never mounts.
  let server: FixtureServer
  do {
    server = try FixtureServer(html: fixture.html())
  } catch {
    recorder.fail("fixture server failed: \(error)")
    return nil
  }
  defer { server.stop() }

  let firefox: NSRunningApplication
  do {
    firefox = try FirefoxHarness.launchWithProfile(
      appPath: OracleProfile.appPath,
      profilePath: OracleProfile.profileDirectory.path,
      url: server.url,
      extraArgs: [],
      offscreen: !visible)
  } catch {
    recorder.fail("launch failed: \(error)")
    return nil
  }
  defer { firefox.terminate() }

  let context = FirefoxHarness.makeContext(for: firefox)
  let snapshot: OracleSnapshot
  do {
    snapshot = try VimiumOracle.capture(
      firefox: firefox, context: context, provider: provider)
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

  // Vimium only ever hints page DOM, never Firefox chrome. Filter
  // Flash's hits to the AXWebArea bounds before diffing — otherwise
  // every toolbar button, tab strip, address bar, etc. would appear
  // as a flashOnly noise entry. Same pattern as
  // FirefoxAssertions.run() (line 47).
  let webArea = FirefoxHarness.findWebAreaFrame(pid: firefox.processIdentifier)
  let pageFlash: [JumpTarget]
  if let web = webArea {
    pageFlash = snapshot.flashTargets.filter { web.intersects($0.frame) }
    recorder.pass(
      "AXWebArea frame \(web) — \(pageFlash.count)/\(snapshot.flashTargets.count) "
        + "flash targets fall inside page area")
  } else {
    pageFlash = snapshot.flashTargets
    recorder.fail(
      "could not locate AXWebArea; diff includes Firefox chrome hits")
  }

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

var anyHardFailure = false
for fixture in args.fixtures {
  guard
    let result = runFixture(
      fixture, provider: provider, recorder: recorder,
      updateAllowList: args.updateAllowList, visible: args.visible)
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
