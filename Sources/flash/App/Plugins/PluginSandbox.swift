import FlashCore
import Foundation

/// Seatbelt profile generation and executable resolution for plugin
/// processes. Everything here is pure and static — profiles are built from
/// the manifest + config settings before spawn; `PluginProcess` only wraps
/// the result in `sandbox-exec -p`.
enum PluginSandbox {

  static let sandboxExecPath = "/usr/bin/sandbox-exec"

  /// Seatbelt string literals: expand ~, strip quotes (paths come from the
  /// strict manifest validator, so this is belt-and-suspenders).
  private static func q(_ path: String) -> String {
    "\"" + NSString(string: path).expandingTildeInPath.replacingOccurrences(of: "\"", with: "")
      + "\""
  }

  /// Reads are broad, minus secrets a keyboard-productivity plugin has no
  /// business touching and the other plugins' data.
  private static func secretsReadDeny(baseDataDir: URL) -> String {
    "(deny file-read* (subpath \(q("~/.ssh"))) (subpath \(q("~/.aws")))"
      + " (subpath \(q("~/.config/gh"))) (subpath \(q("~/Library/Keychains")))"
      + " (subpath \(q(baseDataDir.path))))"
  }

  /// Seatbelt profile for the plugin's runtime process: allow everything but
  /// deny outbound network. Returns nil (spawn unsandboxed) for plugins that
  /// declare `network` (they legitimately reach the network) or `subprocess`
  /// (they exec privileged helpers like setgid `/bin/ps` that seatbelt forbids —
  /// no profile can run those without also letting children escape the network
  /// deny). Third-party install steps run under `installSandboxProfile`.
  static func networkSandboxProfile(for manifest: PluginManifest) -> String? {
    if manifest.capabilities.contains(.network) || manifest.capabilities.contains(.subprocess) {
      return nil
    }
    return "(version 1)\n(allow default)\n(deny network*)"
  }

  /// Deny-default profile generated from the manifest's `sandbox` spec plus
  /// capability composition: everything is denied except loading the binary
  /// (plugin root + system libraries), the plugin's own data dir, declared
  /// exec/read/write allowances, and network-outbound when the `network`
  /// capability is declared.
  static func denyDefaultSandboxProfile(
    for manifest: PluginManifest, spec: PluginSandboxSpec, root: URL, dataDir: URL,
    executablePath: String = ""
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
      // contained by the write/network/exec denials, and a per-plugin
      // spec.read can re-open a denied subtree (rule order: later wins).
      "(allow file-read*)",
      secretsReadDeny(baseDataDir: baseDataDir),
      // The plugin's own writable data root, re-opened after the
      // base-data-dir deny above.
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
      lines.append("(allow system-socket)")
      lines.append("(allow mach-lookup (global-name \"com.apple.dnssd.service\"))")
      lines.append(
        "(allow file-read* (literal \"/etc/hosts\") (literal \"/etc/resolv.conf\")"
          + " (subpath \"/private/etc\"))")
    }
    if !spec.exec.isEmpty {
      lines.append("(allow process-fork)")
      let literals = spec.exec.map { "(literal \(q($0)))" }.joined(separator: " ")
      lines.append("(allow process-exec \(literals))")
      // The exec'd child's dyld must also map the tool executable, and
      // tools like /usr/bin/open and osascript resolve apps through
      // LaunchServices.
      lines.append("(allow file-map-executable \(literals))")
      lines.append(
        "(allow mach-lookup (global-name \"com.apple.coreservices.launchservicesd\")"
          + " (global-name \"com.apple.lsd.mapdb\"))")
    }
    if spec.signal {
      lines.append("(allow signal)")
    }
    if spec.processInfo {
      lines.append("(allow process-info*)")
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
    if spec.hid {
      // Synthetic HID/CGEvent posting: the WindowServer session and IOHID
      // event system.
      lines.append(
        "(allow mach-lookup (global-name \"com.apple.windowserver.active\")"
          + " (global-name \"com.apple.iohideventsystem\")"
          + " (global-name \"com.apple.CARenderServer\"))")
      lines.append("(allow iokit-open)")
    }
    if spec.appleEvents {
      // osascript-driven plugins: AppleEvents routing and the TCC daemon
      // that mediates Automation consent.
      lines.append(
        "(allow mach-lookup (global-name \"com.apple.coreservices.appleevents\")"
          + " (global-name \"com.apple.tccd\")"
          + " (global-name \"com.apple.tccd.system\"))")
      lines.append("(allow appleevent-send)")
    }
    if !spec.read.isEmpty {
      let subpaths = spec.read.map { "(subpath \(q($0)))" }.joined(separator: " ")
      lines.append("(allow file-read* \(subpaths))")
    }
    if !spec.write.isEmpty {
      let subpaths = spec.write.map { "(subpath \(q($0)))" }.joined(separator: " ")
      lines.append("(allow file* \(subpaths))")
    }
    return lines.joined(separator: "\n")
  }

  /// Expand a manifest sandbox spec for this machine. Bare tool names in
  /// spec.exec resolve through the login-shell PATH (the user's package
  /// manager decides where spotify_player lives); both the PATH hit and its
  /// symlink-resolved target land in the profile because seatbelt matches
  /// canonical vnode paths (Homebrew bins are Cellar symlinks). Config
  /// `[plugin.<id>] exec_paths` appends machine-specific absolute paths.
  /// Unresolvable names are dropped with a loud log — the later exec then
  /// fails as a clear seatbelt denial instead of silently widening the
  /// profile.
  static func expandedSandboxSpec(
    _ spec: PluginSandboxSpec, settings: [String: PluginConfigValue], pluginID: String,
    root: URL? = nil
  ) -> PluginSandboxSpec {
    var expanded = spec
    expanded.exec = spec.exec.flatMap { entry -> [String] in
      let candidates: [String]
      if entry.hasPrefix("/") {
        candidates = [entry]
      } else if let resolved = resolveExecutable(named: entry, from: root) {
        candidates = [resolved]
      } else {
        FlashLog.warn(
          "[plugin] \(pluginID) sandbox exec tool not found on PATH: \(entry)",
          fields: ["plugin": pluginID, "tool": entry])
        return []
      }
      return candidates.flatMap { path -> [String] in
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == path ? [path] : [path, resolved]
      }
    }
    if case .stringArray(let extra) = settings["exec_paths"] {
      expanded.exec.append(contentsOf: extra.filter { $0.hasPrefix("/") })
    }
    return expanded
  }

  /// Resolve a bare tool name to an absolute path. mise is the toolchain
  /// authority (the repo mise.toml pins interpreter versions) and its
  /// activation is interactive-shell-only — the login-shell PATH never
  /// carries it — so ask `mise which` first (cwd-aware, so plugin roots
  /// under the checkout pick up the repo pins) and only then fall back to
  /// a login-PATH walk for non-mise tools.
  static func resolveExecutable(named name: String, from directory: URL? = nil) -> String? {
    if let resolved = miseWhich(name, from: directory) {
      return resolved
    }
    let path =
      FlashProcessEnvironment.shared.environment["PATH"] ?? FlashProcessEnvironment.fallbackPath
    for entry in path.split(separator: ":") {
      let candidate = "\(entry)/\(name)"
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private static func miseWhich(_ name: String, from directory: URL?) -> String? {
    let candidates = [
      "\(NSHomeDirectory())/.local/bin/mise",
      "/opt/homebrew/bin/mise",
      "/usr/local/bin/mise",
    ]
    guard let mise = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: mise)
    process.arguments = ["which", name]
    if let directory { process.currentDirectoryURL = directory }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    // Bound a wedged mise the same way installIfNeeded bounds installers —
    // this runs on the plugin's serial queue.
    let killWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + .seconds(10), execute: killWork)
    process.waitUntilExit()
    killWork.cancel()
    guard process.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let path = String(data: data, encoding: .utf8)?.trimmed, !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    else { return nil }
    return path
  }

  /// Which profile a plugin launches under, in order: the per-plugin
  /// `[plugin.<id>] sandbox = false` kill switch (fail-open, logged loudly by
  /// the caller), a manifest `sandbox` spec (deny-default), else the legacy
  /// network-deny transitional profile.
  static func resolvedSandboxProfile(
    manifest: PluginManifest, settings: [String: PluginConfigValue], root: URL, dataDir: URL,
    executablePath: String = ""
  ) -> (profile: String?, mode: String) {
    if case .bool(false) = settings["sandbox"] {
      return (nil, "disabled_by_config")
    }
    if let spec = manifest.sandbox {
      let expanded = expandedSandboxSpec(
        spec, settings: settings, pluginID: manifest.id, root: root)
      return (
        denyDefaultSandboxProfile(
          for: manifest, spec: expanded, root: root, dataDir: dataDir,
          executablePath: executablePath),
        "deny_default"
      )
    }
    if let legacy = networkSandboxProfile(for: manifest) {
      return (legacy, "network_denied")
    }
    return (nil, "unsandboxed")
  }

  /// Seatbelt for third-party `install` scripts: network and exec stay open
  /// (fetching and building dependencies is the point, and name-scoping an
  /// arbitrary build toolchain is hopeless), so the containment is the
  /// filesystem scope — writes confined to the plugin's own root, data dir,
  /// and temp; secrets read-denied.
  static func installSandboxProfile(root: URL, dataDir: URL) -> String {
    let baseDataDir = dataDir.deletingLastPathComponent()
    return [
      "(version 1)",
      "(deny default)",
      "(allow process-exec)",
      "(allow process-fork)",
      "(allow file-map-executable)",
      "(allow file-read*)",
      secretsReadDeny(baseDataDir: baseDataDir),
      "(allow file* (subpath \(q(root.path))) (subpath \(q(dataDir.path)))"
        + " (subpath \"/private/tmp\") (subpath \"/private/var/folders\"))",
      "(allow file-write-data (literal \"/dev/null\"))",
      "(allow file-read-metadata)",
      "(allow process-info*)",
      "(allow sysctl-read)",
      "(allow mach-lookup)",
      "(allow network-outbound)",
      "(allow system-socket)",
    ].joined(separator: "\n")
  }
}
