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
  let me = (CommandLine.arguments.first as NSString?)?.standardizingPath ?? "<self>"
  logErr(
    """
    \(Colour.red)Accessibility permission missing.\(Colour.reset)

    This binary must be granted Accessibility before it can walk Firefox's
    AX tree or post keystrokes to it.

      \(me)

    Grant: System Settings → Privacy & Security → Accessibility → + →
    ⌘⇧G → paste the path above → toggle on.

    Scripts/vimium-oracle.sh signs with the same "Flash Dev" identity
    as flash-firefox-e2e, so the grant persists across rebuilds.
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
  updateAllowList: Bool
) -> OracleDiff.Result? {
  log("\n\(Colour.bold)Running fixture: \(fixture.displayName)\(Colour.reset)")
  let firefox: NSRunningApplication
  do {
    firefox = try FirefoxHarness.launchWithProfile(
      appPath: OracleProfile.appPath,
      profilePath: OracleProfile.profileDirectory.path,
      url: fixture.htmlURL())
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

  let allowList = fixture.loadAllowList()
  let result = OracleDiff.classify(
    vimium: snapshot.vimiumAnchors, flash: snapshot.flashTargets,
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
      updateAllowList: args.updateAllowList)
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
