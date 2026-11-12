import XCTest

@testable import flash

/// Every sandboxed bundled manifest's RESOLVED seatbelt profile (each plugin
/// that runs a process and does not declare `"sandbox": false`), against the
/// real `sandbox-exec`. The compile test catches a profile with a syntax error
/// (which used to ship green — the old tests asserted substrings of the string,
/// never compilability — and fail only at user runtime as an unlaunchable
/// plugin). The boot test then spawns each BUILT plugin binary under its
/// profile with the scrubbed plugin environment and drives the protocol the
/// way the host does: initialize must answer immediately and warm-sources
/// plugins must publish.
///
/// sandbox-exec exit codes, pinned empirically: 65 = profile failed to
/// compile, 71 = compiled but exec of the target denied, 0 = ran.
final class PluginSandboxExecTests: XCTestCase {
  private static let browserBookmarkURL = "https://example.invalid/sandbox-bookmark"

  /// We append a narrow allowance for `/usr/bin/true` to the profile under
  /// test (append-only rules can only widen, so the original text still has
  /// to compile) and require a clean 0.
  private static let trueAllowance = """

    (allow process-exec (literal "/usr/bin/true"))
    (allow file-map-executable (literal "/usr/bin/true"))
    (allow file-read* (literal "/usr/bin/true"))
    """

  private func sandboxedManifests() throws -> [(root: URL, manifest: PluginManifest)] {
    guard FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath) else {
      throw XCTSkip("sandbox-exec unavailable")
    }
    let roots = PluginRepository.officialPluginRoots()
    XCTAssertFalse(roots.isEmpty, "no bundled plugins found — run from the repo root")
    var manifests: [(root: URL, manifest: PluginManifest)] = []
    for root in roots {
      do {
        let manifest = try PluginManifest.load(from: root)
        if manifest.exec != nil, manifest.sandboxSpec != nil {
          manifests.append((root, manifest))
        }
      } catch {
        XCTFail("unloadable manifest at \(root.path): \(error)")
      }
    }
    return manifests
  }

  func testEveryBundledSandboxSpecCompilesAndRuns() throws {
    var checked = 0
    for (root, manifest) in try sandboxedManifests() {
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
    XCTAssertGreaterThanOrEqual(checked, 8, "only \(checked) sandboxed manifests checked")
  }

  /// Boots every built sandboxed plugin under its resolved profile. Host RPCs
  /// are answered like a host that grants nothing. Skips when no binary is
  /// built (`mise run build:plugins`).
  func testEveryBuiltSandboxedPluginBootsUnderItsProfile() throws {
    var booted = 0
    var unbuilt: [String] = []
    for (root, manifest) in try sandboxedManifests() {
      guard let exec = manifest.exec, let executable = exec.first else { continue }
      let executablePath = root.appendingPathComponent(executable).standardizedFileURL.path
      guard FileManager.default.isExecutableFile(atPath: executablePath) else {
        unbuilt.append(manifest.id)
        continue
      }
      try boot(
        manifest: manifest, root: root, executablePath: executablePath,
        execTail: Array(exec.dropFirst()))
      booted += 1
    }
    if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
      XCTAssertEqual(unbuilt, [], "every sandboxed plugin must be built and booted")
    }
    if booted == 0 {
      throw XCTSkip(
        "no built sandboxed plugin binaries (\(unbuilt.count) unbuilt) — run `mise run build:plugins`"
      )
    }
  }

  /// `realpath(3)`: the kernel's own canonical path, `/private` prefix and all.
  private static func canonicalURL(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url.resolvingSymlinksInPath() }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }

  private func boot(
    manifest: PluginManifest, root: URL, executablePath: String, execTail: [String]
  ) throws {
    let dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-sandbox-boot/\(manifest.id)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDir) }
    // Seatbelt matches canonical vnode paths: the profile and the env must
    // name the same resolved directory. `resolvingSymlinksInPath()` is not
    // that canonicalizer — it strips a leading `/private`, so a temp data dir
    // would be written into the profile as `/var/folders/…` while the kernel
    // matches `/private/var/folders/…` and every data-dir write is denied.
    let canonicalDataDir = Self.canonicalURL(dataDir)
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest, settings: [:], root: root, dataDir: canonicalDataDir,
      executablePath: executablePath)
    let profile = try XCTUnwrap(resolved.profile, "\(manifest.id): no profile resolved")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
    process.arguments = ["-p", profile, executablePath] + execTail
    process.currentDirectoryURL = root
    var environment = [
      "FLASH_PLUGIN_ID": manifest.id,
      "FLASH_PLUGIN_VERSION": manifest.version,
      "FLASH_PLUGIN_DATA_DIR": canonicalDataDir.path,
      "FLASH_PLUGIN_CONFIG": "{}",
    ]
    if manifest.id == "browsers" {
      // Empty profiles correctly publish nothing. Seed one known row so this
      // proves sandboxed discovery without depending on the user's history.
      let home = canonicalDataDir.appendingPathComponent("fixture-home")
      let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
      try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
      let bookmarks = """
        {"roots":{"bookmark_bar":{"children":[
          {"type":"url","name":"Sandbox bookmark","url":"\(Self.browserBookmarkURL)"}
        ]}}}
        """
      try Data(bookmarks.utf8).write(to: profile.appendingPathComponent("Bookmarks"))
      environment["HOME"] = home.path
    }
    process.environment = PluginProcess.sanitizedPluginEnvironment(
      base: ProcessInfo.processInfo.environment, overrides: environment)
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    let driver = SandboxBootDriver(
      stdin: stdin.fileHandleForWriting,
      allowShortcutListing: manifest.capabilities.contains(.appleEvents)
        && manifest.appleEventsTargets.contains("com.apple.shortcuts.events"))
    stdout.fileHandleForReading.readabilityHandler = { handle in
      driver.ingestStdout(handle.availableData)
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      driver.ingestStderr(handle.availableData)
    }
    defer {
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      if process.isRunning { process.terminate() }
    }

    driver.send([
      "id": 1, "method": "initialize", "params": ["protocol_version": PluginProtocol.version],
    ])
    let reply = driver.waitForResponse(id: 1, timeout: 10)
    XCTAssertEqual(
      reply?["ok"] as? Bool, true,
      "\(manifest.id): initialize under the profile — \(driver.stderrText())")
    XCTAssertEqual(
      reply?["protocol_version"] as? Int, PluginProtocol.version,
      "\(manifest.id): \(driver.stderrText())")
    if !manifest.sources.isEmpty {
      XCTAssertTrue(
        driver.waitForNotification(method: "publish", timeout: 10),
        """
        \(manifest.id): warm sources must publish under the profile — \
        logs: \(driver.logText()) stderr: \(driver.stderrText())
        """)
    }
    if manifest.id == "browsers" {
      XCTAssertTrue(
        driver.waitForPublishedRow(
          source: "chrome.bookmarks", url: Self.browserBookmarkURL, timeout: 10),
        "browsers: seeded bookmark must publish under the profile — \(driver.logText())")
    }

    // Shutdown is stdin EOF, nothing else.
    stdin.fileHandleForWriting.closeFile()
    XCTAssertEqual(
      finished.wait(timeout: .now() + 5), .success,
      "\(manifest.id): did not exit on stdin EOF — \(driver.stderrText())")
    if !process.isRunning {
      XCTAssertEqual(
        process.terminationStatus, 0, "\(manifest.id): exit status — \(driver.stderrText())")
    }
  }
}

/// Minimal host side of the NDJSON protocol for the boot test: collects the
/// plugin's frames, answers its host RPCs, and retains stderr for diagnostics.
private final class SandboxBootDriver {
  private let lock = NSLock()
  private let stdin: FileHandle
  private let allowShortcutListing: Bool
  private var buffer = Data()
  private var frames: [[String: Any]] = []
  private var stderr = Data()

  init(stdin: FileHandle, allowShortcutListing: Bool) {
    self.stdin = stdin
    self.allowShortcutListing = allowShortcutListing
  }

  func send(_ object: [String: Any]) {
    guard var frame = try? JSONSerialization.data(withJSONObject: object) else { return }
    frame.append(0x0A)
    lock.lock()
    defer { lock.unlock() }
    stdin.write(frame)
  }

  func ingestStdout(_ data: Data) {
    guard !data.isEmpty else { return }
    var requests: [[String: Any]] = []
    lock.lock()
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer.subdata(in: buffer.startIndex..<newline)
      buffer.removeSubrange(buffer.startIndex...newline)
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      frames.append(object)
      if object["id"] != nil, object["method"] is String { requests.append(object) }
    }
    lock.unlock()
    for request in requests { answer(request) }
  }

  func ingestStderr(_ data: Data) {
    lock.lock()
    stderr.append(data)
    lock.unlock()
  }

  func stderrText() -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: stderr, encoding: .utf8) ?? "<non-utf8 stderr>"
  }

  /// The plugin's own `log` notifications. A refresh that declines to publish
  /// says why here, never on stderr, so the publish assertion quotes both.
  func logText() -> String {
    lock.lock()
    defer { lock.unlock() }
    return
      frames
      .filter { $0["id"] == nil && $0["method"] as? String == "log" }
      .compactMap { ($0["params"] as? [String: Any])?["message"] as? String }
      .joined(separator: " | ")
  }

  /// A declared shortcut listing uses an empty host fixture, so the test
  /// verifies RPC and publication under seatbelt without Automation prompts.
  /// Every other host request is denied.
  private func answer(_ request: [String: Any]) {
    if allowShortcutListing, request["method"] as? String == "host.applescript",
      let params = request["params"] as? [String: Any],
      params["operation"] as? String == "shortcuts_list"
    {
      send(["id": request["id"]!, "result": ["ok": true, "result": ""]])
      return
    }
    send([
      "id": request["id"]!,
      "result": ["ok": false, "error": "not available in the sandbox boot test"],
    ])
  }

  func waitForResponse(id: Int, timeout: TimeInterval) -> [String: Any]? {
    wait(timeout: timeout) { frames in
      frames.first { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }?["result"]
        as? [String: Any]
    }
  }

  func waitForNotification(method: String, timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { frames in
      frames.contains { $0["id"] == nil && $0["method"] as? String == method } ? true : nil
    } ?? false
  }

  func waitForPublishedRow(source: String, url: String, timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { frames in
      let published = frames.contains { frame in
        guard frame["id"] == nil, frame["method"] as? String == "publish",
          let params = frame["params"] as? [String: Any], params["source"] as? String == source,
          let rows = params["rows"] as? [[String: Any]]
        else { return false }
        return rows.contains { $0["url"] as? String == url }
      }
      return published ? true : nil
    } ?? false
  }

  private func wait<T>(timeout: TimeInterval, _ find: ([[String: Any]]) -> T?) -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      lock.lock()
      let found = find(frames)
      lock.unlock()
      if let found { return found }
      Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return nil
  }
}
