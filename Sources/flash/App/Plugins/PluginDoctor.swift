import Foundation

/// `:plugins doctor` — the checkhealth surface: turns "a plugin doesn't
/// work" into a self-service diagnosis instead of a support thread. Pure
/// over the runtime statuses plus on-disk state; every check reports a
/// line, problems are prefixed `!!` and counted. Runs off-main (profile
/// compilation execs sandbox-exec per sandboxed plugin).
enum PluginDoctor {

  struct Report {
    var lines: [String]
    var issues: Int
  }

  /// Appended to a generated profile so sandbox-exec can run /usr/bin/true
  /// as the compile oracle — append-only rules can only widen, so the real
  /// profile text is still what must compile. Exit codes, pinned
  /// empirically: 65 = compile error, 71 = exec denied, 0 = ran.
  private static let trueAllowance = """

    (allow process-exec (literal "/usr/bin/true"))
    (allow file-map-executable (literal "/usr/bin/true"))
    (allow file-read* (literal "/usr/bin/true"))
    """

  static func run(statuses: [PluginStatus]) -> Report {
    var lines: [String] = []
    var issues = 0
    lines.append("protocol v\(PluginProtocol.version); \(statuses.count) plugin(s)")
    for status in statuses.sorted(by: { $0.id < $1.id }) {
      var problems: [String] = []
      var notes: [String] = ["state=\(status.state)", "activation=\(status.activation)"]
      if status.state == "failed" {
        problems.append("parked failed\(status.lastError.map { ": \($0)" } ?? "")")
      } else if let error = status.lastError {
        notes.append("last_error=\(error)")
      }
      if status.restartCount > 0 {
        notes.append("restarts=\(status.restartCount)")
      }

      let root = URL(fileURLWithPath: status.root)
      let manifest: PluginManifest?
      do {
        manifest = try PluginManifest.load(from: root)
      } catch {
        manifest = nil
        problems.append("manifest: \(error)")
      }

      if let manifest {
        if let issue = execIssue(manifest: manifest, root: root) {
          problems.append(issue)
        }
        let dataDir = PluginRepository.defaultDataDir().appendingPathComponent(manifest.id)
        let resolved = PluginSandbox.resolvedSandboxProfile(
          manifest: manifest, settings: [:], root: root, dataDir: dataDir)
        notes.append("sandbox=\(resolved.mode)")
        if let profile = resolved.profile, let issue = profileIssue(profile) {
          problems.append(issue)
        }
      }

      let marker = problems.isEmpty ? "ok" : "!!"
      issues += problems.isEmpty ? 0 : 1
      let detail = (problems + notes).joined(separator: "; ")
      lines.append("\(marker) \(status.id): \(detail)")
    }
    return Report(lines: lines, issues: issues)
  }

  /// Mirrors PluginProcess.launch's argv[0] resolution so the diagnosis
  /// matches what the spawn would actually do.
  private static func execIssue(manifest: PluginManifest, root: URL) -> String? {
    guard let executable = manifest.exec?.first else { return nil }
    if executable.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: executable)
        ? nil : "exec: \(executable) is not executable"
    }
    if executable.contains("/") {
      let path = root.appendingPathComponent(executable).standardizedFileURL.path
      return FileManager.default.isExecutableFile(atPath: path)
        ? nil : "exec: \(executable) missing — run Scripts/build-plugins.sh"
    }
    return PluginSandbox.resolveExecutable(named: executable, from: root) == nil
      ? "exec: runtime \(executable) not found via mise or the login PATH" : nil
  }

  private static func profileIssue(_ profile: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
    process.arguments = ["-p", profile + trueAllowance, "/usr/bin/true"]
    process.standardOutput = FileHandle.nullDevice
    let stderr = Pipe()
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      return "sandbox: cannot run sandbox-exec (\(error))"
    }
    process.waitUntilExit()
    if process.terminationStatus == 0 { return nil }
    let diagnostics =
      String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return "sandbox: profile check failed (exit \(process.terminationStatus)) "
      + diagnostics.trimmed.prefix(160)
  }
}
