import AppKit
import ApplicationServices
import FlashCore
import FlashE2EKit
import FlashProviders
import Foundation

// MARK: - Why this exists
//
// `swift test` runs through `swiftpm-xctest-helper`, an Apple-signed
// binary that loads the test bundle as a dylib. Granting it
// Accessibility in System Settings should be enough, but in practice
// the permission frequently doesn't take (cdhash drift across Xcode
// updates, stale TCC state from previous grants, or a toggle that
// silently flips off after re-add).
//
// This standalone executable bypasses xctest entirely. After a single
// `swift build -c release` + ad-hoc codesign, the resulting binary
// lives at a stable path you can add to TCC once. Subsequent rebuilds
// keep working as long as the binary at that path is the one re-signed
// in place.
//
// Use Scripts/test-firefox-e2e.sh to build + sign + print the path
// you need to grant.

// MARK: - Output helpers

private enum Colour {
  static let red = "\u{1B}[31m"
  static let green = "\u{1B}[32m"
  static let bold = "\u{1B}[1m"
  static let reset = "\u{1B}[0m"
}

private func log(_ s: String) {
  print(s)
  fflush(stdout)
}

final class CLIRecorder: FirefoxE2ERecorder {
  private(set) var failures: [String] = []
  func pass(_ msg: String) { log("\(Colour.green)✓\(Colour.reset) \(msg)") }
  func fail(_ msg: String) {
    failures.append(msg)
    log("\(Colour.red)✗\(Colour.reset) \(msg)")
  }
}

// MARK: - Permission check

private func ensureAccessibilityOrExit() {
  if AXIsProcessTrusted() { return }
  let me = (CommandLine.arguments.first as NSString?)?.standardizingPath ?? "<self>"
  log(
    """
    \(Colour.red)Accessibility permission missing.\(Colour.reset)

    This binary needs to be granted Accessibility before it can walk
    Firefox's AX tree. The binary path:

      \(me)

    To grant:
      1. Open System Settings → Privacy & Security → Accessibility
      2. Click +, press ⌘⇧G, paste the path above.
      3. Toggle the new entry on.
      4. Re-run this binary.

    Notes:
      - Granting your terminal does NOT propagate to this binary.
      - Scripts/test-firefox-e2e.sh signs the binary with the stable
        "Flash Dev" identity, so TCC's stored designated requirement
        (the cert, not the cdhash) keeps matching across rebuilds.
        You only need to grant once.
    """)
  exit(2)
}

// MARK: - Main

ensureAccessibilityOrExit()

log("\(Colour.bold)Flash Firefox E2E\(Colour.reset)")
log("Launching Firefox with fixture page…")

let firefox: NSRunningApplication
do {
  firefox = try FirefoxHarness.launchWithFixture()
} catch {
  log("\(Colour.red)\(error)\(Colour.reset)")
  exit(2)
}
defer { firefox.terminate() }

firefox.activate(options: [])

let provider = AccessibilityProvider()
let context = FirefoxHarness.makeContext(for: firefox)

log("Waiting for AX tree to settle…")
let (targets, webAreaFrame) =
  FirefoxHarness.waitForStableTree(provider: provider, context: context, timeout: 20)

log("\n\(Colour.bold)Running assertions…\(Colour.reset)\n")
let recorder = CLIRecorder()
FirefoxAssertions.run(
  targets: targets,
  webAreaFrame: webAreaFrame,
  firefoxPid: firefox.processIdentifier,
  recorder: recorder
)

log("")
if recorder.failures.isEmpty {
  log("\(Colour.green)\(Colour.bold)PASS\(Colour.reset) — every invariant held")
  exit(0)
} else {
  log(
    "\(Colour.red)\(Colour.bold)FAIL\(Colour.reset) — "
      + "\(recorder.failures.count) assertion(s) failed:")
  for m in recorder.failures {
    log("  • \(m)")
  }
  exit(1)
}
