import FlashCore
import FlashTerminal
import Foundation
import os

/// Seatbelt profile generation and executable resolution for plugin
/// processes. Profiles are pure — built from the manifest + config settings
/// before spawn; `PluginProcess` only wraps the result in `sandbox-exec -p`.
/// Executable resolution is remembered in `executableResolutions`.
enum PluginSandbox {

  static let sandboxExecPath = "/usr/bin/sandbox-exec"

  /// Seatbelt string literals: expand ~, strip quotes (paths come from the
  /// strict manifest validator, so this is belt-and-suspenders).
  private static func q(_ path: String) -> String {
    "\"" + NSString(string: path).expandingTildeInPath.replacingOccurrences(of: "\"", with: "")
      + "\""
  }

  /// Reads are broad, minus secrets a keyboard-productivity plugin has no
  /// business touching and the OTHER plugins' data. The base-data-dir clause
  /// carves the plugin's own data dir out with require-not INSIDE the deny:
  /// "a later (allow file* (subpath dataDir)) re-opens the denied subtree"
  /// is empirically false on modern seatbelt — the earlier subpath deny kept
  /// winning for reads, which silently broke every plugin reading its own
  /// data dir (history's sqlite copies were the visible casualty). Rule
  /// order must never carry that exception; the filter does.
  private static func secretsReadDeny(baseDataDir: URL, dataDir: URL? = nil) -> String {
    let baseClause: String
    if let dataDir {
      baseClause =
        "(require-all (subpath \(q(baseDataDir.path)))"
        + " (require-not (subpath \(q(dataDir.path)))))"
    } else {
      baseClause = "(subpath \(q(baseDataDir.path)))"
    }
    return "(deny file-read* (subpath \(q("~/.ssh"))) (subpath \(q("~/.aws")))"
      + " (subpath \(q("~/.config/gh"))) (subpath \(q("~/Library/Keychains")))"
      + " \(baseClause))"
  }

  /// The resident's socket directory, which no sandboxed process may
  /// connect into: the socket runs any command, `:!` shell lines included,
  /// outside the sandbox. A rule after every allow, so no allow reopens it.
  static func residentSocketDeny(_ directories: [String]) -> String {
    directories.map { "(deny network-outbound (remote unix-socket (subpath \(q($0)))))" }
      .joined(separator: "\n")
  }

  /// Deny-default profile generated from the manifest's `sandbox` spec plus
  /// capability composition: everything is denied except loading the binary
  /// (plugin root + system libraries, plus an interpreter outside the root),
  /// the plugin's own data dir, declared mach allowances, and
  /// network-outbound when the `network` capability is declared — never to
  /// the resident's own socket.
  static func denyDefaultSandboxProfile(
    for manifest: PluginManifest, spec: PluginSandboxSpec, root: URL, dataDir: URL,
    executablePath: String = "",
    residentSocketDirectories: [String] = IPCEndpoint.standard.sandboxPaths
  ) -> String {
    let baseDataDir = dataDir.deletingLastPathComponent()
    var lines = [
      "(version 1)",
      "(deny default)",
      // sandbox-exec applies the profile and THEN execvp()s the plugin
      // binary, so exec of the plugin's own root must stay allowed; dyld
      // must map the binary, system libraries, and the shared-cache cryptex
      // (seatbelt matches the real /private/preboot mount, not the
      // /System/Volumes alias).
      "(allow process-exec (subpath \(q(root.path))))",
      "(allow file-map-executable (subpath \(q(root.path))) (subpath \"/usr/lib\")"
        + " (subpath \"/System\") (subpath \"/Library/Frameworks\")"
        + " (subpath \"/private/preboot/Cryptexes/OS\")"
        + " (subpath \"/System/Cryptexes/OS\"))",
      // Reads are broad — dyld's startup reads defeat a strict allowlist
      // (it aborts, without a message, on cache paths that vary per OS
      // release) — minus the secrets deny below. Exfiltration is
      // contained by the write/network/exec denials.
      "(allow file-read*)",
      secretsReadDeny(baseDataDir: baseDataDir, dataDir: dataDir),
      // The plugin's own writable data root (reads stay open via the
      // require-not carve-out in the deny above).
      "(allow file* (subpath \(q(dataDir.path))))",
      "(allow file-write-data (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))",
      "(allow file-read-metadata)",
      "(allow process-info* (target self))",
      "(allow sysctl-read)",
      // Baseline mach services every process ends up touching (unified
      // logging, notifications). Name-scoped on purpose — no wildcard.
      "(allow mach-lookup (global-name \"com.apple.logd\")"
        + " (global-name \"com.apple.diagnosticd\")"
        + " (global-name \"com.apple.system.notification_center\")"
        + " (global-name \"com.apple.system.logger\"))",
    ]
    if manifest.capabilities.contains(.network) {
      lines.append("(allow network-outbound)")
      lines.append(residentSocketDeny(residentSocketDirectories))
      lines.append("(allow system-socket)")
      lines.append("(allow mach-lookup (global-name \"com.apple.dnssd.service\"))")
      lines.append(
        "(allow file-read* (literal \"/etc/hosts\") (literal \"/etc/resolv.conf\")"
          + " (subpath \"/private/etc\"))")
    }
    // Interpreted plugins exec a runtime outside the plugin root (python3,
    // bun): allow exec + dyld mapping of the resolved interpreter itself.
    if !executablePath.isEmpty && !executablePath.hasPrefix(root.path) {
      let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
      let paths = resolved == executablePath ? [executablePath] : [executablePath, resolved]
      let literals = paths.map { "(literal \(q($0)))" }.joined(separator: " ")
      lines.append("(allow process-exec \(literals))")
      lines.append("(allow file-map-executable \(literals))")
    }
    if !spec.mach.isEmpty {
      let names = spec.mach.map { "(global-name \(q($0)))" }.joined(separator: " ")
      lines.append("(allow mach-lookup \(names))")
    }
    return lines.joined(separator: "\n")
  }

  /// Every bare-name resolution for the life of the resident. A `mise which`
  /// spawn can stall for seconds while `syspolicyd` is busy, and plugin
  /// launches and the tmux bigram capture used to pay one on every call. Callers stay off the main thread: a miss still
  /// spawns `mise`.
  static let executableResolutions = ExecutableResolutionCache()

  /// Resolve a bare tool name to an absolute path. mise is the toolchain
  /// authority (the repo mise.toml pins interpreter versions) and its
  /// activation is interactive-shell-only — the login-shell PATH never
  /// carries it — so ask `mise which` first (cwd-aware, so plugin roots
  /// under the checkout pick up the repo pins) and only then fall back to
  /// a login-PATH walk for non-mise tools. A remembered answer is served
  /// while it is still an executable file.
  static func resolveExecutable(named name: String, from directory: URL? = nil) -> String? {
    let path =
      FlashProcessEnvironment.shared.environment["PATH"] ?? FlashProcessEnvironment.fallbackPath
    let key = ExecutableResolutionCache.Key(name: name, directory: directory, searchPath: path)
    return executableResolutions.resolve(key) {
      resolveExecutableUncached(named: name, from: directory, searchPath: path)
    }
  }

  private static func resolveExecutableUncached(
    named name: String, from directory: URL?, searchPath path: String
  ) -> String? {
    if let resolved = miseWhich(name, from: directory) {
      return resolved
    }
    // The same search a terminal popup's command gets.
    return name.contains("/") ? nil : TerminalExecutable.resolve(name, path: path)
  }

  private static func miseWhich(_ name: String, from directory: URL?) -> String? {
    let candidates = [
      "\(NSHomeDirectory())/.local/bin/mise",
      "/opt/homebrew/bin/mise",
      "/usr/local/bin/mise",
    ]
    guard let mise = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    // Bound a wedged mise the same way installIfNeeded bounds installers —
    // this runs on the plugin's serial queue.
    let result = BoundedCommand.run(
      [mise, "which", name], environment: ProcessInfo.processInfo.environment,
      directory: directory?.path, timeout: 10)
    let path = result.text.trimmed
    guard result.succeeded, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
    else { return nil }
    return path
  }

  /// Which profile a plugin launches under, in order: the per-plugin
  /// `[plugins.<id>] sandbox = false` kill switch (fail-open, logged loudly by
  /// the caller), a manifest's `"sandbox": false`, else the deny-default
  /// profile built from the manifest's spec (absent: the empty spec).
  /// Third-party install steps run under `installSandboxProfile` either way.
  static func resolvedSandboxProfile(
    manifest: PluginManifest, settings: [String: PluginConfigValue], root: URL, dataDir: URL,
    executablePath: String = ""
  ) -> (profile: String?, mode: String) {
    if case .bool(false) = settings["sandbox"] {
      return (nil, "disabled_by_config")
    }
    guard let spec = manifest.sandboxSpec else {
      return (nil, "disabled_by_manifest")
    }
    return (
      denyDefaultSandboxProfile(
        for: manifest, spec: spec, root: root, dataDir: dataDir,
        executablePath: executablePath),
      "deny_default"
    )
  }

  /// Seatbelt for third-party `install` scripts: network and exec stay open
  /// (fetching and building dependencies is the point, and name-scoping an
  /// arbitrary build toolchain is hopeless), so the containment is the
  /// filesystem scope — writes confined to the plugin's own root, data dir,
  /// and temp; secrets read-denied.
  static func installSandboxProfile(
    root: URL, dataDir: URL,
    residentSocketDirectories: [String] = IPCEndpoint.standard.sandboxPaths
  ) -> String {
    let baseDataDir = dataDir.deletingLastPathComponent()
    return [
      "(version 1)",
      "(deny default)",
      "(allow process-exec)",
      "(allow process-fork)",
      "(allow file-map-executable)",
      "(allow file-read*)",
      secretsReadDeny(baseDataDir: baseDataDir, dataDir: dataDir),
      "(allow file* (subpath \(q(root.path))) (subpath \(q(dataDir.path)))"
        + " (subpath \"/private/tmp\") (subpath \"/private/var/folders\"))",
      "(allow file-write-data (literal \"/dev/null\"))",
      "(allow file-read-metadata)",
      "(allow process-info*)",
      "(allow sysctl-read)",
      "(allow mach-lookup)",
      "(allow network-outbound)",
      residentSocketDeny(residentSocketDirectories),
      "(allow system-socket)",
    ].joined(separator: "\n")
  }
}

/// Remembered bare-name executable resolutions, keyed by everything one
/// reads: the name, the directory `mise which` runs in (its pins are
/// cwd-aware) and the login `PATH` the fallback walk searches. A hit is
/// served only while it is still an executable file; otherwise it is
/// dropped and resolved afresh. A failed resolution is never remembered, so
/// a miss — a tool installed later included — behaves as an uncached lookup.
final class ExecutableResolutionCache: @unchecked Sendable {
  struct Key: Hashable {
    let name: String
    let directory: String?
    let searchPath: String

    init(name: String, directory: URL?, searchPath: String) {
      self.name = name
      self.directory = directory?.standardizedFileURL.path
      self.searchPath = searchPath
    }
  }

  private let entries = OSAllocatedUnfairLock(initialState: [Key: String]())
  private let isExecutable: (String) -> Bool

  init(
    isExecutable: @escaping (String) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  ) {
    self.isExecutable = isExecutable
  }

  /// The remembered path for `key` while it is still executable, else
  /// `resolve()`'s answer, remembered when there is one. `resolve` runs
  /// outside the lock: concurrent misses for one key each resolve, and the
  /// last answer is kept.
  func resolve(_ key: Key, _ resolve: () -> String?) -> String? {
    if let hit = entries.withLock({ $0[key] }) {
      if isExecutable(hit) { return hit }
      entries.withLock { entries in
        if entries[key] == hit { entries[key] = nil }
      }
    }
    guard let resolved = resolve() else { return nil }
    entries.withLock { $0[key] = resolved }
    return resolved
  }
}
