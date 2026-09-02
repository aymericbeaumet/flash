import Foundation

/// Hidden local verb `flash _plugin-sandbox-profile --root <dir> --data-dir
/// <dir> [--settings <json>]`: prints the exact seatbelt profile the resident
/// would spawn the plugin under (stdout) and the resolution mode (stderr).
///
/// Handled in main.swift BEFORE the AppleEvent CLI dispatch, so it needs no
/// running resident. It exists for the conformance runner's --sandbox lane and
/// PluginSandboxExecTests: profiles resolve bare tool names via `mise which`
/// per machine, so they cannot be pregenerated at build time — reusing the
/// production `PluginSandbox.resolvedSandboxProfile` path here is the whole
/// point (a hand-rolled reimplementation would drift).
enum PluginSandboxProfileCLI {
  static func run(args: [String]) -> Int32 {
    var root: String?
    var dataDir: String?
    var settingsJSON: String?
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--root" where index + 1 < args.count:
        root = args[index + 1]
        index += 2
      case "--data-dir" where index + 1 < args.count:
        dataDir = args[index + 1]
        index += 2
      case "--settings" where index + 1 < args.count:
        settingsJSON = args[index + 1]
        index += 2
      default:
        FileHandle.standardError.write(Data("unknown argument: \(args[index])\n".utf8))
        return 2
      }
    }
    guard let root, let dataDir else {
      FileHandle.standardError.write(
        Data(
          "usage: flash _plugin-sandbox-profile --root <dir> --data-dir <dir> [--settings <json>]\n"
            .utf8))
      return 2
    }
    let rootURL = URL(fileURLWithPath: root)
    let manifest: PluginManifest
    do {
      manifest = try PluginManifest.load(from: rootURL)
    } catch {
      FileHandle.standardError.write(Data("cannot load manifest: \(error)\n".utf8))
      return 2
    }
    let settings = parseSettings(settingsJSON)
    // Mirror PluginProcess.launch's argv[0] resolution so the profile's
    // interpreter exec allowance matches what the host would spawn.
    var executablePath = ""
    if let executable = manifest.exec?.first {
      if executable.hasPrefix("/") {
        executablePath = executable
      } else if executable.contains("/") {
        executablePath = rootURL.appendingPathComponent(executable).standardizedFileURL.path
      } else if let resolved = PluginSandbox.resolveExecutable(named: executable, from: rootURL) {
        executablePath = resolved
      }
    }
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest, settings: settings, root: rootURL,
      dataDir: URL(fileURLWithPath: dataDir), executablePath: executablePath)
    FileHandle.standardError.write(Data("mode: \(resolved.mode)\n".utf8))
    guard let profile = resolved.profile else {
      return 3
    }
    print(profile)
    return 0
  }

  /// The two host-reserved settings keys that shape a profile: the
  /// `sandbox = false` kill switch and machine-specific `exec_paths`.
  private static func parseSettings(_ json: String?) -> [String: PluginConfigValue] {
    guard let json, let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var settings: [String: PluginConfigValue] = [:]
    if let sandbox = object["sandbox"] as? Bool {
      settings["sandbox"] = .bool(sandbox)
    }
    if let paths = object["exec_paths"] as? [String] {
      settings["exec_paths"] = .stringArray(paths)
    }
    return settings
  }
}
