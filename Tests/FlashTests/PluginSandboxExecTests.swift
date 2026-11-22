import FlashCore
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

  /// Spawn `executablePath` under the profile `manifest` resolves to, with
  /// the scrubbed plugin environment, answer its handshake and hand the
  /// running plugin to `body`; then close its stdin, which must end it.
  private func launch(
    manifest: PluginManifest, root: URL, executablePath: String, execTail: [String],
    body: (SandboxBootDriver) throws -> Void
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
    try body(driver)

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

  /// The rows a live source answers one `search` with, nil when the reply
  /// is no valid row list.
  private func searchRows(
    _ driver: SandboxBootDriver, manifest: PluginManifest, source: String, id: Int
  ) -> [Candidate]? {
    driver.send([
      "id": id, "method": "search", "params": ["source": source, "query": ""],
      "deadline_ms": PluginProtocol.searchDeadlineMs,
    ])
    return PluginWireCodec.searchRows(
      from: driver.waitForResponse(id: id, timeout: 10), source: source,
      sourceID: "plugin:\(manifest.id)")
  }

  private func boot(
    manifest: PluginManifest, root: URL, executablePath: String, execTail: [String]
  ) throws {
    try launch(
      manifest: manifest, root: root, executablePath: executablePath, execTail: execTail
    ) { driver in
      if !manifest.pushedSources.isEmpty {
        XCTAssertTrue(
          driver.waitForNotification(method: "publish", timeout: 10),
          """
          \(manifest.id): warm sources must publish under the profile — \
          logs: \(driver.logText()) stderr: \(driver.stderrText())
          """)
      }
      // A live source publishes nothing: it answers a search with its rows.
      for (offset, source) in manifest.sources.filter({ $0.live != nil }).enumerated() {
        XCTAssertNotNil(
          searchRows(driver, manifest: manifest, source: source.name, id: 100 + offset),
          """
          \(manifest.id): live source \(source.name) must answer a search under the profile — \
          logs: \(driver.logText()) stderr: \(driver.stderrText())
          """)
      }
      if manifest.id == "browsers" {
        XCTAssertTrue(
          driver.waitForPublishedRow(
            source: "chrome.bookmarks", url: Self.browserBookmarkURL, timeout: 10),
          "browsers: seeded bookmark must publish under the profile — \(driver.logText())")
      }
    }
  }

  /// The plugin that shows the process table reads none of it. Under its
  /// own profile, with a host that answers no RPC, its live source lists
  /// nothing, this test runner included: its rows are the host's answer
  /// (`host.process_table`) and it has no reader of its own to fall back on.
  func testThePluginThatShowsProcessesReadsNoneItself() throws {
    let declaring = try sandboxedManifests().filter {
      $0.manifest.capabilities.contains(.processTable)
    }
    let (root, manifest) = try XCTUnwrap(declaring.first, "a bundled plugin shows processes")
    XCTAssertEqual(declaring.count, 1, "one bundled plugin holds process_table")
    let executable = try XCTUnwrap(manifest.exec?.first)
    let executablePath = root.appendingPathComponent(executable).standardizedFileURL.path
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("\(manifest.id) must be built")
      }
      throw XCTSkip("\(manifest.id) is not built: run `mise run build:plugins`")
    }
    let source = try XCTUnwrap(manifest.sources.first { $0.live != nil }?.name)
    var rows: [Candidate]?
    try launch(manifest: manifest, root: root, executablePath: executablePath, execTail: []) {
      rows = searchRows($0, manifest: manifest, source: source, id: 100)
    }
    XCTAssertEqual(rows?.map(\.title), [], "no host, no process")
  }

  /// The built `flash-sandbox-probe`, beside the test bundle.
  private func sandboxProbe() throws -> URL {
    guard FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath) else {
      throw XCTSkip("sandbox-exec unavailable")
    }
    let probe = Self.canonicalURL(
      Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("flash-sandbox-probe"))
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: probe.path),
      "flash-sandbox-probe is not built beside the test bundle")
    return probe
  }

  /// One probe run, as `<what>: <outcome>`: under the profile a plugin with
  /// `capabilities` resolves to, or under none when `capabilities` is nil.
  private func runProbe(
    _ probe: URL, _ arguments: [String], capabilities: Set<PluginCapability>?
  ) throws -> [String: String] {
    try runProbe(
      probe, arguments,
      manifest: capabilities.map {
        PluginManifest(
          id: "probe", name: "Probe", version: "1", description: "",
          exec: ["./flash-sandbox-probe"], capabilities: $0)
      })
  }

  /// One probe run under the profile `manifest` resolves to, with the
  /// probe's directory standing for the plugin's root, or under none.
  /// `widening` is a rule appended to that profile: what a profile would
  /// let through if it ever carried it.
  private func runProbe(
    _ probe: URL, _ arguments: [String], manifest: PluginManifest?, widening: String = ""
  ) throws -> [String: String] {
    let process = Process()
    if let manifest {
      let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("flash-sandbox-probe/\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dataDir) }
      let profile = try XCTUnwrap(
        PluginSandbox.resolvedSandboxProfile(
          manifest: manifest, settings: [:], root: probe.deletingLastPathComponent(),
          dataDir: Self.canonicalURL(dataDir), executablePath: probe.path
        ).profile)
      process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
      process.arguments = ["-p", profile + widening, probe.path] + arguments
    } else {
      process.executableURL = probe
      process.arguments = arguments
    }
    process.environment = PluginProcess.sanitizedPluginEnvironment(
      base: ProcessInfo.processInfo.environment, overrides: [:])
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(
      process.terminationStatus, 0,
      "the probe ran — \(String(data: diagnostics, encoding: .utf8) ?? "")")
    var outcomes: [String: String] = [:]
    for line in (String(data: output, encoding: .utf8) ?? "").split(separator: "\n") {
      let words = line.split(separator: " ", maxSplits: 1)
      if words.count == 2 { outcomes[String(words[0])] = String(words[1]) }
    }
    return outcomes
  }

  /// Run `body` with the probe's arguments for a child this test spawns,
  /// which holds one marker in its arguments and one in its environment.
  private func withAHeldProcess<Result>(
    _ body: (_ probe: URL, _ arguments: [String]) throws -> Result
  ) throws -> Result {
    let probe = try sandboxProbe()
    let argument = "flash-probe-argument-\(UUID().uuidString)"
    let secret = "flash-probe-environment-\(UUID().uuidString)"
    let held = Process()
    held.executableURL = probe
    held.arguments = ["hold", argument]
    held.environment = ["FLASH_SANDBOX_PROBE_SECRET": secret]
    let hold = Pipe()
    held.standardInput = hold
    held.standardOutput = FileHandle.nullDevice
    try held.run()
    defer {
      hold.fileHandleForWriting.closeFile()
      held.waitUntilExit()
    }
    return try body(probe, ["process", "\(held.processIdentifier)", argument, secret])
  }

  /// The probe's reads of that child: without a sandbox, and under a
  /// plugin's profile.
  private func readsOfAHeldProcess() throws -> (
    unsandboxed: [String: String], plain: [String: String]
  ) {
    try withAHeldProcess { probe, arguments in
      (
        try runProbe(probe, arguments, capabilities: nil),
        try runProbe(probe, arguments, capabilities: [])
      )
    }
  }

  /// The reads every node and call of the probe makes of another process.
  private static let processReads = [
    "kern.procargs2", "kern.procargs", "kern.proc.pid", "kern.proc.all", "kern.proc.uid",
    "name:kern.procargs2", "name:kern.proc.pid", "proc_pidpath", "csops",
  ]

  /// Under the real profile of every sandboxed bundled plugin, the one
  /// that shows the process table included, a process reads nothing of a
  /// child this test spawned: not its arguments, not its environment, not
  /// its path, through sysctl or through libproc. No manifest opens them.
  func testNoBundledPluginReadsAnotherProcessUnderItsOwnProfile() throws {
    let manifests = try sandboxedManifests()
    XCTAssertTrue(manifests.contains { $0.manifest.id == "processes" }, "the process plugin")
    try withAHeldProcess { probe, arguments in
      let unsandboxed = try runProbe(probe, arguments, manifest: nil)
      XCTAssertEqual(unsandboxed["kern.procargs2"], "markers:2/2", "the probe finds both")
      for (_, manifest) in manifests {
        let reads = try runProbe(probe, arguments, manifest: manifest)
        for read in Self.processReads {
          XCTAssertEqual(reads[read], "errno:\(EPERM)", "\(manifest.id): \(read)")
        }
      }
    }
  }

  /// The kernel serves the process list, and a same-user process's
  /// arguments and environment, through `sysctl` as well as through libproc.
  /// With no sandbox the probe finds both markers; under a plugin's profile
  /// every one of those nodes is refused, by MIB and by name, like libproc.
  func testASandboxedPluginReadsNoOtherProcessThroughSysctl() throws {
    let reads = try readsOfAHeldProcess()
    XCTAssertEqual(reads.unsandboxed["kern.procargs2"], "markers:2/2", "the probe finds both")
    XCTAssertEqual(reads.unsandboxed["kern.procargs"], "markers:2/2")
    XCTAssertEqual(reads.unsandboxed["name:kern.procargs2"], "markers:2/2")
    XCTAssertEqual(reads.unsandboxed["proc_pidpath"], "read")
    for node in [
      "kern.procargs2", "kern.procargs", "kern.proc.pid", "kern.proc.all", "kern.proc.uid",
      "name:kern.procargs2", "name:kern.proc.pid", "proc_pidpath",
    ] {
      XCTAssertEqual(reads.plain[node], "errno:\(EPERM)", "\(node) under a plugin's profile")
    }
  }

  /// Why no profile opens `proc_pidinfo` for another process, and why the
  /// process table is the host's to read. macOS serves the `sysctl` nodes
  /// addressed by one pid (`kern.proc.pid`, `kern.procargs`,
  /// `kern.procargs2`) to whoever may `proc_pidinfo` that process, whatever
  /// the profile says of `sysctl-read`: no rule separates them (measured on
  /// macOS 26). A profile carrying that one allow reads a same-user
  /// process's arguments and environment. A failure of the first half means
  /// macOS separated them; the profiles stay as they are either way.
  func testOpeningPidinfoWouldAlsoServeArgumentsAndEnvironment() throws {
    let widened = try withAHeldProcess { probe, arguments in
      try runProbe(
        probe, arguments,
        manifest: PluginManifest(
          id: "probe", name: "Probe", version: "1", description: "",
          exec: ["./flash-sandbox-probe"]),
        widening: "\n(allow process-info-pidinfo (target others))")
    }
    XCTAssertEqual(widened["proc_pidpath"], "read", "the allow opens libproc")
    XCTAssertEqual(widened["kern.procargs2"], "markers:2/2")
    XCTAssertEqual(widened["kern.procargs"], "markers:2/2")
    XCTAssertEqual(widened["name:kern.procargs2"], "markers:2/2")
    XCTAssertEqual(widened["kern.proc.pid"], "read")
    XCTAssertEqual(widened["kern.proc.all"], "errno:\(EPERM)", "the list follows sysctl")
    XCTAssertEqual(widened["kern.proc.uid"], "errno:\(EPERM)")
  }

  /// `csops(2)` serves a process's code signature: its signing identifier,
  /// which names the app, its entitlements and its hash. No profile opens
  /// it for another process.
  func testNoSandboxedPluginReadsAnotherProcessCodeSignature() throws {
    let reads = try readsOfAHeldProcess()
    XCTAssertEqual(reads.unsandboxed["csops"], "read", "the probe reads it")
    XCTAssertEqual(reads.plain["csops"], "errno:\(EPERM)", "under a plugin's profile")
  }

  /// The allow-list serves what the bundled plugins and the system libraries
  /// read: each node answers under a plugin's profile exactly as it does
  /// without one. Trimming the list fails here before a plugin's values go
  /// empty. Numeric names are MIBs: the file-system table (`3.0.…`), then
  /// `getifaddrs`, the interface counters and the two routing tables
  /// (`4.17.…`).
  func testTheSysctlAllowListServesWhatBundledPluginsRead() throws {
    let probe = try sandboxProbe()
    let nodes = [
      "hw.memsize", "hw.ncpu", "hw.pagesize_compat", "kern.hostname", "kern.iossupportversion",
      "kern.memorystatus_level", "kern.osproductversion", "kern.osvariant_status",
      "security.mac.lockdown_mode_state", "vm.loadavg", "vm.swapusage",
      "3.0.1", "3.0.2.0", "3.0.2.1", "3.0.2.2", "3.0.2.30",
      "4.17.0.0.3.0", "4.17.0.0.6.0", "4.17.0.2.7.0", "4.17.0.30.7.0",
    ]
    let withheld = ["kern.bootargs", "kern.procname", "net.inet.tcp.pcblist_n"]
    let unsandboxed = try runProbe(probe, ["sysctl"] + nodes, capabilities: nil)
    XCTAssertEqual(unsandboxed["hw.memsize"], "read")
    XCTAssertEqual(unsandboxed["4.17.0.0.6.0"], "read")
    for capabilities: Set<PluginCapability> in [[], Set(PluginCapability.allCases)] {
      let sandboxed = try runProbe(
        probe, ["sysctl"] + nodes + withheld, capabilities: capabilities)
      for node in nodes {
        XCTAssertEqual(sandboxed[node], unsandboxed[node], "\(node) under a plugin's profile")
      }
      for node in withheld {
        XCTAssertEqual(sandboxed[node], "errno:\(EPERM)", "\(node) stays closed")
      }
    }
  }
}

/// Minimal host side of the NDJSON protocol for the boot test: collects the
/// plugin's frames, answers its host RPCs, lands the one-shot deadlines it
/// registers, and retains stderr for diagnostics.
private final class SandboxBootDriver {
  private let lock = NSLock()
  private let stdin: FileHandle
  private let allowShortcutListing: Bool
  private var buffer = Data()
  private var frames: [[String: Any]] = []
  private var landed: Set<String> = []
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
    var deadlines: [String] = []
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
      // The host's clock, for one-shot deadlines: each lands at once, once.
      if object["id"] == nil, object["method"] as? String == "poll",
        let registrations = (object["params"] as? [String: Any])?["registrations"]
          as? [String: [String: Any]]
      {
        for (name, registration) in registrations
        where registration["after"] != nil && landed.insert(name).inserted {
          deadlines.append(name)
        }
      }
    }
    lock.unlock()
    for request in requests { answer(request) }
    for name in deadlines {
      send(["method": "event", "params": ["name": "core:poll:\(name)", "payload": [:]]])
    }
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
