import FlashCore
import Foundation
import TOMLKit

/// `[plugins]` and each `[plugins.<id>]` settings table.
extension ConfigLoader {
  static func applyPlugins(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["watching_enabled"], path: ["plugins", "watching_enabled"],
      message: "plugins.watching_enabled must be true or false", locations: locations, into: &config
    ) { value, config in
      config.plugins.watchingEnabled = value
    }
    applyInt(
      table["install_timeout"], path: ["plugins", "install_timeout"],
      message: "plugins.install_timeout must be an integer between 10 and 1800 (seconds)",
      locations: locations, into: &config, validate: { (10...1_800).contains($0) },
      assign: { value, config in
        config.plugins.installTimeoutSeconds = value
      })
    applyInt(
      table["startup_timeout"], path: ["plugins", "startup_timeout"],
      message: "plugins.startup_timeout must be an integer between 1 and 120 (seconds)",
      locations: locations, into: &config, validate: { (1...120).contains($0) },
      assign: { value, config in
        config.plugins.startupTimeoutSeconds = value
      })

    let disabledPath = ["plugins", "disabled"]
    // A malformed `disabled` must not abort the rest of the section (it
    // used to `return`, silently dropping `third_party` with it).
    if let value = table["disabled"] {
      let location = locations.location(for: disabledPath)
      if let parsed = stringArrayValue(value) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        var disabled = Set<String>()
        var invalid: [String] = []
        for raw in parsed {
          let id = raw.trimmed.lowercased()
          if !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            disabled.insert(id)
          } else {
            invalid.append(raw)
          }
        }
        if invalid.isEmpty {
          config.plugins.disabled = disabled
          config.recordLocation(path: "plugins.disabled", location: location)
        } else {
          config.addDiagnostic(
            "plugins.disabled entries must be lowercase [a-z0-9._-]: \(invalid.joined(separator: ", "))",
            location: location)
        }
      } else {
        config.addDiagnostic(
          "plugins.disabled must be an array of plugin ids",
          location: location)
      }
    }

    let thirdPartyPath = ["plugins", "third_party"]
    if let value = table["third_party"] {
      let location = locations.location(for: thirdPartyPath)
      guard let parsed = stringArrayValue(value) else {
        config.addDiagnostic(
          "plugins.third_party must be an array of strings",
          location: location)
        return
      }
      var refs: [PluginReference] = []
      var invalid: [String] = []
      for raw in parsed {
        if let ref = PluginReference.parse(raw, sourceURL: sourceURL) {
          refs.append(ref)
        } else {
          invalid.append(raw)
        }
      }
      if invalid.isEmpty {
        config.plugins.thirdParty = refs
        config.recordLocation(path: "plugins.third_party", location: location)
      } else {
        config.addDiagnostic(
          "plugins.third_party entries must be github:user/project or file:<path>: \(invalid.joined(separator: ", "))",
          location: location)
      }
    }
  }

  /// `[plugins]`' own settings. Every other key of the table is a plugin id
  /// naming its `[plugins.<id>]` settings, so no plugin may take one of these
  /// as its id (`PluginManifest`).
  static let pluginsSettingKeys: Set<String> = [
    "watching_enabled", "disabled", "third_party", "install_timeout", "startup_timeout",
  ]

  /// `[plugins.<id>]` tables of bundled plugins that no longer exist, with
  /// where their settings went. A stale table is diagnosed and dropped, never
  /// applied under a name nothing reads.
  static let removedPluginSettingsTables: [String: String] = [
    "clipboard": "use [clipboard] history_size",
    "github": "the github plugin was removed",
    "kitty": "the kitty plugin was removed",
    "spotify": "the spotify plugin was removed",
    "windows": "the windows plugin was removed",
    "reference": "the plugin is now emojis and has no settings",
    "tmux": "use [plugins.terminals]",
    "history": "its browser history sources are now the browsers plugin",
    "cpu": "the plugin is now sysinfo and has no settings",
    "memory": "the plugin is now sysinfo and has no settings",
    "disks": "the plugin is now sysinfo and has no settings",
    "network": "the plugin is now sysinfo and has no settings",
    "power": "the plugin is now sysinfo and has no settings",
    "marks": "marks are core now and have no settings",
    "vscode": "its VS Code action bindings are now the defaults plugin",
  ]

  static func applyPluginSettings(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    let allowedIDChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    for (pluginID, value) in table where !pluginsSettingKeys.contains(pluginID) {
      // A non-table key is not a plugin's settings; the unknown-key check
      // reports it.
      guard let settings = value.table else { continue }
      if let replacement = Self.removedPluginSettingsTables[pluginID] {
        config.addDiagnostic(
          "[plugins.\(pluginID)] was removed; \(replacement)",
          location: locations.location(for: ["plugins", pluginID]))
        continue
      }
      guard
        !pluginID.isEmpty,
        pluginID.unicodeScalars.allSatisfy({ allowedIDChars.contains($0) })
      else {
        config.addDiagnostic(
          "[plugins.\(pluginID)] plugin ids must be lowercase [a-z0-9._-]",
          location: locations.location(for: ["plugins", pluginID]))
        continue
      }
      for (key, settingValue) in settings where !key.isEmpty {
        let locationPath = ["plugins", pluginID, key]
        let location = locations.location(for: locationPath)
        guard let parsed = pluginConfigValue(settingValue) else {
          config.addDiagnostic(
            "plugins.\(pluginID).\(key) must be a string, number, boolean, or array of strings",
            location: location)
          continue
        }
        config.plugins.settings[pluginID, default: [:]][key] = parsed
        config.recordLocation(path: "plugins.\(pluginID).\(key)", location: location)
      }
    }
  }
}
