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

  /// The bundled plugins' own commands by `(command, subcommand)`, with the
  /// arguments each declares; `subcommand` is `*` for a wildcard. Config and
  /// the CLI accept `flash <command> <subcommand>` for these, the same shape
  /// as `:command subcommand`, and hold their arguments to the declaration.
  static let declaredCommands: [PluginCommandPair: PluginCommandRegistration] = {
    struct Commands: Decodable {
      var commands: [PluginCommandRegistration]?
    }
    var declared: [PluginCommandPair: PluginCommandRegistration] = [:]
    for root in manifestRoots(in: officialPluginRoots() + [sourceTreePluginsDirectory]) {
      let url = root.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: url),
        let manifest = try? JSONDecoder().decode(Commands.self, from: data)
      else { continue }
      for var command in manifest.commands ?? [] {
        command.command = command.command.trimmed.lowercased()
        command.subcommand = command.subcommand.trimmed.lowercased()
        // An entry under one of Flash's topics is a core command the plugin
        // performs, never a plugin command the CLI could name.
        guard !command.command.isEmpty, !command.isCoreCommand else { continue }
        let pair = PluginCommandPair(command: command.command, subcommand: command.subcommand)
        if declared[pair] == nil { declared[pair] = command }
      }
    }
    return declared
  }()

  /// The bundled registration `flash <command> <subcommand>` names: that
  /// pair, else the `*` wildcard of the same command.
  static func declaredCommand(_ command: String, subcommand: String)
    -> PluginCommandRegistration?
  {
    let command = command.lowercased()
    return declaredCommands[
      PluginCommandPair(command: command, subcommand: subcommand.lowercased())]
      ?? declaredCommands[PluginCommandPair(command: command, subcommand: "*")]
  }

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
    // The test runner gets a directory of its own: a test that boots the
    // resident's manager never writes into the user's plugin data.
    guard NSClassFromString("XCTestCase") == nil else { return testDataDir }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Flash/Plugins")
  }

  private static let testDataDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("flash-plugin-data-\(ProcessInfo.processInfo.processIdentifier)")
}
