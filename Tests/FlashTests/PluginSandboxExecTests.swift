import XCTest

@testable import flash

/// Compiles every sandboxed bundled manifest's RESOLVED seatbelt profile with
/// the real `sandbox-exec` — a profile with a syntax error used to ship green
/// (the old tests asserted substrings of the string, never compilability) and
/// fail only at user runtime as an unlaunchable plugin.
///
/// sandbox-exec exit codes, pinned empirically: 65 = profile failed to
/// compile, 71 = compiled but exec of the target denied, 0 = ran. We append a
/// narrow allowance for `/usr/bin/true` to the profile under test (append-only
/// rules can only widen, so the original text still has to compile) and
/// require a clean 0. Full protocol boots under the profile are the
/// conformance runner's `--sandbox` lane, driven through the same
/// `flash _plugin-sandbox-profile` production code path.
final class PluginSandboxExecTests: XCTestCase {
  private static let trueAllowance = """

    (allow process-exec (literal "/usr/bin/true"))
    (allow file-map-executable (literal "/usr/bin/true"))
    (allow file-read* (literal "/usr/bin/true"))
    """

  func testEveryBundledSandboxSpecCompilesAndRuns() throws {
    guard FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath) else {
      throw XCTSkip("sandbox-exec unavailable")
    }
    let roots = PluginRepository.officialPluginRoots()
    XCTAssertFalse(roots.isEmpty, "no bundled plugins found — run from the repo root")
    var checked = 0
    for root in roots {
      let manifest: PluginManifest
      do {
        manifest = try PluginManifest.load(from: root)
      } catch {
        XCTFail("unloadable manifest at \(root.path): \(error)")
        continue
      }
      guard manifest.sandbox != nil else { continue }
      let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("flash-sandbox-test/\(manifest.id)")
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      let resolved = PluginSandbox.resolvedSandboxProfile(
        manifest: manifest, settings: [:], root: root, dataDir: dataDir)
      let profile = try XCTUnwrap(resolved.profile, "\(manifest.id): no profile resolved")
      XCTAssertEqual(resolved.mode, "deny_default", manifest.id)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
      process.arguments = ["-p", profile + Self.trueAllowance, "/usr/bin/true"]
      let stderr = Pipe()
      process.standardError = stderr
      try process.run()
      process.waitUntilExit()
      let diagnostics =
        String(
          data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      XCTAssertEqual(
        process.terminationStatus, 0,
        "\(manifest.id): sandbox-exec exit \(process.terminationStatus) — \(diagnostics)")
      XCTAssertFalse(
        diagnostics.contains("syntax error"),
        "\(manifest.id): profile failed to compile — \(diagnostics)")
      checked += 1
    }
    // Regression floor: the bundled tree carries a large sandboxed majority;
    // a collapse of this number means manifest loading or spec resolution
    // broke, not that plugins legitimately dropped their sandboxes.
    XCTAssertGreaterThanOrEqual(checked, 20, "only \(checked) sandboxed manifests checked")
  }
}
