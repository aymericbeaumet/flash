import FlashCore
import Foundation

struct PluginCommandPair: Hashable {
  var command: String
  var subcommand: String
}

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
  /// `git fetch` — without it a stuck child would hang the whole reload; the
  /// timeout ends git's helpers too (`BoundedCommand`).
  private func runGit(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 60
  ) -> Bool {
    BoundedCommand.run(
      ["/usr/bin/env", "git"] + arguments, environment: FlashProcessEnvironment.shared.environment,
      directory: root.path, timeout: timeoutSeconds, capture: .none
    ).succeeded
  }

  /// Run a `git` subcommand and return its stdout on success. Used to read
  /// `git rev-parse HEAD` for commit-pin verification.
  private func runGitCapture(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 30
  ) -> String? {
    let result = BoundedCommand.run(
      ["/usr/bin/env", "git"] + arguments, environment: FlashProcessEnvironment.shared.environment,
      directory: root.path, timeout: timeoutSeconds, capture: .stdout)
    return result.succeeded ? result.text : nil
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
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
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

  /// `(command, subcommand)` pairs from bundled manifests. `subcommand` is
  /// `*` for a wildcard. Config and the CLI accept `flash <command> <subcommand>`
  /// for these, the same shape as `:command subcommand`.
  static let declaredCommandPairs: Set<PluginCommandPair> = {
    var pairs = Set<PluginCommandPair>()
    for root in manifestRoots(in: officialPluginRoots() + [sourceTreePluginsDirectory]) {
      let url = root.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let commands = json["commands"] as? [[String: Any]]
      else { continue }
      for command in commands {
        guard let name = command["command"] as? String else { continue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An entry under one of Flash's topics is a core command the plugin
        // performs, never a plugin command the CLI could name.
        guard !trimmed.isEmpty, !URLEventHandler.isTopic(trimmed) else { continue }
        let sub =
          (command["subcommand"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        pairs.insert(PluginCommandPair(command: trimmed, subcommand: sub))
      }
    }
    return pairs
  }()

  /// Lowercased bang token → the bundled plugin whose manifest declares it,
  /// the `*` catch-all left out. `[flashlight.bangs]` may not take one.
  static let declaredBangOwners: [String: String] = {
    var owners: [String: String] = [:]
    for root in manifestRoots(in: officialPluginRoots() + [sourceTreePluginsDirectory]) {
      let url = root.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = json["id"] as? String, let bangs = json["bangs"] as? [[String: Any]]
      else { continue }
      for bang in bangs {
        guard let token = bang["token"] as? String else { continue }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "*", owners[trimmed] == nil else { continue }
        owners[trimmed] = id
      }
    }
    return owners
  }()

  /// `Plugins/` of the checkout this binary was built from, where a
  /// development run finds the bundled manifests.
  private static let sourceTreePluginsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Plugins")

  /// True when some manifest registers `command`. With a subcommand, true
  /// only for that pair or a `*` wildcard on the same command.
  static func declaresCommand(_ command: String, subcommand: String? = nil) -> Bool {
    let command = command.lowercased()
    guard declaredCommandPairs.contains(where: { $0.command == command }) else { return false }
    guard let subcommand else { return true }
    let normalized = subcommand.lowercased()
    return declaredCommandPairs.contains(
      PluginCommandPair(command: command, subcommand: normalized))
      || declaredCommandPairs.contains(PluginCommandPair(command: command, subcommand: "*"))
  }

  static func officialPluginRoots(
    bundleURL: URL = Bundle.main.bundleURL,
    resourceURL: URL? = Bundle.main.resourceURL,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) -> [URL] {
    // An installed resident trusts its signed bundle only. Its launch
    // directory may be a downloaded repository containing arbitrary Plugins.
    if bundleURL.pathExtension.lowercased() == "app" {
      return manifestRoots(in: resourceURL.map { [$0.appendingPathComponent("Plugins")] } ?? [])
    }
    let candidates = [
      resourceURL?.appendingPathComponent("Plugins"),
      workingDirectory.appendingPathComponent("Plugins"),
    ].compactMap { $0 }
    return manifestRoots(in: candidates)
  }

  static func defaultDataDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Flash/Plugins")
  }
}
