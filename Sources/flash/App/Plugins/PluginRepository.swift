import FlashCore
import Foundation

/// Third-party plugin materialization (commit-pinned GitHub checkouts) and
/// on-disk plugin-root discovery. Owns nothing but `baseDataDir`; every git
/// child is argv-exec'd (no shell) with a kill-timer bound.
struct PluginRepository {
  let baseDataDir: URL

  /// Builds the git remote URL for a `github:` ref. Testability seam — the
  /// production value IS github.com; the manager reload tests point it at a
  /// local bare-repo fixture so the commit-pin fetch/checkout/verify pipeline
  /// runs without the network. `var` + internal on purpose (mirrors the
  /// PluginProcess lifecycle seams); tests must restore it.
  static var remoteURLBuilder: (_ owner: String, _ repository: String) -> String = {
    owner, repository in
    "https://github.com/\(owner)/\(repository).git"
  }

  func materialize(_ ref: PluginReference) -> (root: URL, origin: PluginOrigin)? {
    switch ref.kind {
    case .file(let path):
      return (URL(fileURLWithPath: path), .file(ref.raw))
    case .github(let owner, let repository, let commit):
      let root = baseDataDir.appendingPathComponent("github/\(owner)-\(repository)-\(commit)")
      let url = Self.remoteURLBuilder(owner, repository)
      do {
        try FileManager.default.createDirectory(
          at: root.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        // The directory name embeds the commit, so a populated root means we
        // already checked that exact SHA out — skip any network round trip.
        // This also means a previously vetted plugin keeps working offline.
        let head = root.appendingPathComponent(".git/HEAD")
        if FileManager.default.fileExists(atPath: head.path),
          verifyGitCommit(root: root, commit: commit)
        {
          return (root, .github(ref.raw))
        }
        // Fresh fetch: init an empty repo, fetch *exactly* the requested
        // commit, then check it out and verify HEAD matches. We never run
        // `git pull` on an existing tree — that would let a moving upstream
        // ref silently slide the worktree forward.
        if FileManager.default.fileExists(atPath: root.path) {
          try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard runGit(["init", "--quiet"], in: root),
          runGit(["remote", "add", "origin", url], in: root),
          runGit(["fetch", "--depth", "1", "origin", commit], in: root),
          runGit(["checkout", "--quiet", commit], in: root),
          verifyGitCommit(root: root, commit: commit)
        else {
          FlashLog.warn(
            "[plugins] github checkout did not match pinned commit \(commit)",
            fields: ["ref": ref.raw, "root": root.path, "commit": commit])
          return nil
        }
        return (root, .github(ref.raw))
      } catch {
        FlashLog.warn(
          "[plugins] failed to materialize \(ref.raw): \(error)",
          fields: ["ref": ref.raw, "root": root.path, "error": String(describing: error)])
        return nil
      }
    }
  }

  /// True iff `git rev-parse HEAD` inside `root` returns exactly `commit`. The
  /// equality is the defense — a checkout of the wrong object (or an opaque
  /// object database race) gets rejected loudly instead of being trusted.
  private func verifyGitCommit(root: URL, commit: String) -> Bool {
    guard let head = runGitCapture(["rev-parse", "HEAD"], in: root) else { return false }
    return head.trimmed.lowercased() == commit
  }

  /// Run a `git` subcommand using an explicit argv (no shell). Returns true on
  /// exit status 0. 60s timeout protects config reload from a network-stalled
  /// `git fetch` — without it a stuck child would hang the whole reload.
  private func runGit(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 60
  ) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    FlashProcessEnvironment.shared.apply(to: process)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    let timeout = DispatchTime.now() + .nanoseconds(Int(timeoutSeconds * 1_000_000_000))
    let killer = DispatchQueue.global(qos: .utility)
    let workItem = DispatchWorkItem {
      if process.isRunning {
        process.terminate()
      }
    }
    killer.asyncAfter(deadline: timeout, execute: workItem)
    process.waitUntilExit()
    workItem.cancel()
    return process.terminationStatus == 0
  }

  /// Run a `git` subcommand and return its stdout on success. Used to read
  /// `git rev-parse HEAD` for commit-pin verification.
  private func runGitCapture(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 30
  ) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    FlashProcessEnvironment.shared.apply(to: process)
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let timeout = DispatchTime.now() + .nanoseconds(Int(timeoutSeconds * 1_000_000_000))
    let killer = DispatchQueue.global(qos: .utility)
    let workItem = DispatchWorkItem {
      if process.isRunning {
        process.terminate()
      }
    }
    killer.asyncAfter(deadline: timeout, execute: workItem)
    process.waitUntilExit()
    workItem.cancel()
    guard process.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  static func manifestRoots(in candidates: [URL], fileManager fm: FileManager = .default) -> [URL] {
    var roots: [URL] = []
    var seenBases = Set<String>()
    var seenRoots = Set<String>()
    for candidate in candidates {
      let bases = [candidate, candidate.resolvingSymlinksInPath()]
      for base in bases where seenBases.insert(base.path).inserted {
        guard
          let children = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { continue }
        for child in children {
          let root = child.resolvingSymlinksInPath()
          guard fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            continue
          }
          guard seenRoots.insert(root.path).inserted else { continue }
          roots.append(root)
        }
      }
    }
    return roots
  }

  static func officialPluginRoots() -> [URL] {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Plugins"),
    ].compactMap { $0 }
    return manifestRoots(in: candidates)
  }

  /// Env the host injects at plugin spawn so interpreted plugins import their
  /// shared SDK by bare module name (`import flashplugin`) from anywhere —
  /// repo checkout, release bundle, or a third-party root. Set for every
  /// plugin (harmless for compiled ones). Same candidate order as
  /// `officialPluginRoots()`: the staged bundle wins over a cwd checkout.
  static func interpreterSDKEnvironment() -> [String: String] {
    let bases = [
      Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Plugins"),
    ].compactMap { $0 }
    let sdkDirs = [
      ("PYTHONPATH", "_flash_plugin_python"),
      ("RUBYLIB", "_flash_plugin_ruby"),
      ("NODE_PATH", "_flash_plugin_typescript"),
    ]
    var env: [String: String] = [:]
    for (variable, directory) in sdkDirs {
      for base in bases {
        let dir = base.appendingPathComponent(directory)
        if FileManager.default.fileExists(atPath: dir.path) {
          env[variable] = dir.resolvingSymlinksInPath().path
          break
        }
      }
    }
    return env
  }

  static func defaultDataDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Flash/Plugins")
  }
}
