import XCTest

@testable import flash

/// Every sandboxed bundled manifest's RESOLVED seatbelt profile, against the
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
        if manifest.sandbox != nil { manifests.append((root, manifest)) }
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
    XCTAssertGreaterThanOrEqual(checked, 20, "only \(checked) sandboxed manifests checked")
  }

  /// Boots every built sandboxed plugin under its resolved profile. Host RPCs
  /// are answered like a host that grants nothing, except `host.process_table`,
  /// which gets one scripted row so `processes` can build its catalog without
  /// a host. Skips when no binary is built (`Scripts/build-plugins.sh dev`).
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
    if booted == 0 {
      throw XCTSkip(
        "no built sandboxed plugin binaries (\(unbuilt.count) unbuilt) — run Scripts/build-plugins.sh dev"
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
    process.environment = PluginProcess.sanitizedPluginEnvironment(
      base: ProcessInfo.processInfo.environment,
      overrides: [
        "FLASH_PLUGIN_ID": manifest.id,
        "FLASH_PLUGIN_VERSION": manifest.version,
        "FLASH_PLUGIN_DATA_DIR": canonicalDataDir.path,
        "FLASH_PLUGIN_CONFIG": "{}",
        "FLASH_PLUGIN_PARENT_PID": String(getpid()),
      ])
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    let driver = SandboxBootDriver(stdin: stdin.fileHandleForWriting)
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
    if manifest.sources.contains(where: { !$0.live }) {
      XCTAssertTrue(
        driver.waitForNotification(method: "publish", timeout: 10),
        """
        \(manifest.id): warm sources must publish under the profile — \
        logs: \(driver.logText()) stderr: \(driver.stderrText())
        """)
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
  private var buffer = Data()
  private var frames: [[String: Any]] = []
  private var stderr = Data()

  init(stdin: FileHandle) {
    self.stdin = stdin
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

  /// The scripted host: one process-table row, every other capability denied.
  private func answer(_ request: [String: Any]) {
    let result: [String: Any]
    if request["method"] as? String == "host.process_table" {
      result = [
        "ok": true,
        "processes": [["pid": 1, "comm": "launchd", "cpu_percent": 0.4, "mem_percent": 0.1]],
      ]
    } else {
      result = ["ok": false, "error": "not available in the sandbox boot test"]
    }
    send(["id": request["id"]!, "result": result])
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
