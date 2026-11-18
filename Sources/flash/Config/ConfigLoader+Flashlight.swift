import FlashCore
import Foundation
import TOMLKit

/// `[flashlight]`: its sources, the app catalog and user bangs.
extension ConfigLoader {
  /// `[flashlight]`'s installed-app catalog: `ignored_apps` and
  /// `app_directories`, which also scope the `app open` command.
  private static func applyFlashlightAppCatalog(
    _ table: TOMLTable,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    applyStringArray(
      table["ignored_apps"], path: ["flashlight", "ignored_apps"],
      message: "flashlight.ignored_apps must be an array of strings", locations: locations,
      into: &config
    ) { value, config in
      config.flashlight.ignoredApps = value
    }
    applyStringArray(
      table["app_directories"], path: ["flashlight", "app_directories"],
      message: "flashlight.app_directories must be an array of directory paths",
      locations: locations, into: &config
    ) { value, config in
      let location = locations.location(for: ["flashlight", "app_directories"])
      // An empty list would silently kill the whole app catalog — keep the
      // defaults and say so.
      guard !value.isEmpty else {
        config.addDiagnostic(
          "flashlight.app_directories must not be empty (remove the key to use the defaults)",
          location: location)
        return
      }
      // Scanning from a filesystem root would walk the entire volume on
      // every reload; refuse those outright. Missing directories are only
      // warned about — an entry may legitimately appear later.
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let roots = value.filter {
        let expanded = ($0 as NSString).expandingTildeInPath
        return expanded == "/" || expanded == home
      }
      guard roots.isEmpty else {
        config.addDiagnostic(
          "flashlight.app_directories must not include a filesystem root or the bare home directory: "
            + roots.joined(separator: ", "),
          location: location)
        return
      }
      // Missing directories are fine — the watcher picks them up if they
      // appear later, so no existence check here.
      config.flashlight.appDirectories = value
    }
  }

  static func applyFlashlight(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyFlashlightAppCatalog(table, locations: locations, into: &config)
    applyInt(
      table["suggestion_count"], path: ["flashlight", "suggestion_count"],
      message: "flashlight.suggestion_count must be an integer between 1 and 100",
      locations: locations,
      into: &config, validate: { (1...100).contains($0) },
      assign: { value, config in
        config.flashlight.suggestionCount = value
      })
    applyInt(
      table["precedence_alive_bonus"], path: ["flashlight", "precedence_alive_bonus"],
      message: "flashlight.precedence_alive_bonus must be an integer between 0 and 10000",
      locations: locations, into: &config,
      validate: { (0...Self.precedenceBound).contains($0) },
      assign: { value, config in
        config.flashlight.precedenceAliveBonus = value
      })
    applyDouble(
      table["frecency_half_life_days"], path: ["flashlight", "frecency_half_life_days"],
      message: "flashlight.frecency_half_life_days must be a number between 0.5 and 365",
      locations: locations, into: &config, validate: { (0.5...365.0).contains($0) },
      assign: { value, config in
        config.flashlight.frecencyHalfLifeDays = value
      })
    applyInt(
      table["frecency_max_boost"], path: ["flashlight", "frecency_max_boost"],
      message: "flashlight.frecency_max_boost must be an integer between 0 and 10000 (0 = off)",
      locations: locations, into: &config, validate: { (0...10_000).contains($0) },
      assign: { value, config in
        config.flashlight.frecencyMaxBoost = value
      })
    applyInt(
      table["live_query_timeout_ms"], path: ["flashlight", "live_query_timeout_ms"],
      message: "flashlight.live_query_timeout_ms must be an integer between 50 and 5000 (ms)",
      locations: locations, into: &config, validate: { (50...5_000).contains($0) },
      assign: { value, config in
        config.flashlight.liveQueryTimeoutMs = value
      })

    if let aliases = sectionTable(
      table["aliases"], name: "flashlight.aliases", locations: locations, into: &config)
    {
      for (key, value) in aliases {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let locationPath = ["flashlight", "aliases", key]
        let location = locations.location(for: locationPath)
        if let parsed = value.string, !parsed.isEmpty, !trimmedKey.isEmpty {
          if let invalid = ResourceTypes.firstInvalidToken(in: parsed) {
            config.addDiagnostic(
              "flashlight.aliases.\(key): \(ResourceTypes.invalidTokenMessage(invalid))",
              location: location)
            continue
          }
          config.flashlight.aliases[trimmedKey] = parsed
          config.recordLocation(path: "flashlight.aliases.\(trimmedKey)", location: location)
        } else {
          config.addDiagnostic(
            "flashlight.aliases.\(key) must be a non-empty quoted string",
            location: location)
        }
      }
    }

    if let bangs = sectionTable(
      table["bangs"], name: "flashlight.bangs", locations: locations, into: &config)
    {
      for (name, value) in bangs {
        let location = locations.location(for: ["flashlight", "bangs", name])
        if let bang = parseUserBang(
          name: name, value, dotted: "flashlight.bangs.\(name)", location: location,
          into: &config)
        {
          config.flashlight.bangs[name] = bang
          config.recordLocation(path: "flashlight.bangs.\(name)", location: location)
        }
      }
    }

    if let precedence = sectionTable(
      table["precedence"], name: "flashlight.precedence", locations: locations, into: &config)
    {
      for (key, value) in precedence {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        let locationPath = ["flashlight", "precedence", key]
        let location = locations.location(for: locationPath)
        // Weights are per resource type, the word `@<type>` filters by.
        guard ResourceTypes.isValidName(trimmedKey) else {
          config.addDiagnostic(
            "flashlight.precedence.\(key): "
              + ResourceTypes.invalidTokenMessage(trimmedKey)
              .replacingOccurrences(of: "@\(trimmedKey) is", with: "\(trimmedKey) is"),
            location: location)
          continue
        }
        // Bounded so the ranking sum (base + alive bonus) can never
        // overflow Int and trap on the first flashlight query.
        if let parsed = value.int, !trimmedKey.isEmpty,
          (-Self.precedenceBound...Self.precedenceBound).contains(parsed)
        {
          config.flashlight.precedence[trimmedKey] = parsed
          config.recordLocation(path: "flashlight.precedence.\(trimmedKey)", location: location)
        } else {
          config.addDiagnostic(
            "flashlight.precedence.\(key) must be an integer between -10000 and 10000",
            location: location)
        }
      }
    }
  }

  /// One `[flashlight.bangs]` entry: `name = "<url>"` or
  /// `name = { url = "<url>", description = "…" }`. The name is one word of
  /// lowercase letters and digits nobody else owns, the URL http or https
  /// with `{query}` as its only braces. An inline table's keys share its
  /// line, so their diagnostics carry the entry's location.
  private static func parseUserBang(
    name: String, _ value: any TOMLValueConvertible, dotted: String,
    location: ConfigLocation?, into config: inout Config
  ) -> Config.Flashlight.Bang? {
    var bang: Config.Flashlight.Bang
    if let url = value.string {
      bang = Config.Flashlight.Bang(url: url)
    } else if let table = value.table {
      let keys = ["url", "description"]
      var valid = true
      for key in table.keys.sorted() where !keys.contains(key) {
        config.addDiagnostic(
          "\(dotted): unknown key '\(key)'; known keys: \(keys.joined(separator: ", "))",
          location: location)
        valid = false
      }
      guard let url = table["url"]?.string else {
        config.addDiagnostic(
          "\(dotted) needs url = \"https://…\", with {query} where the query goes",
          location: location)
        return nil
      }
      bang = Config.Flashlight.Bang(url: url)
      if let description = table["description"] {
        if let text = description.string {
          bang.description = text
        } else {
          config.addDiagnostic("\(dotted).description must be a string", location: location)
          valid = false
        }
      }
      guard valid else { return nil }
    } else {
      config.addDiagnostic(
        "\(dotted) must be a URL string or a table { url = \"https://…\", description = \"…\" }",
        location: location)
      return nil
    }
    guard UserBangs.isValidName(name) else {
      config.addDiagnostic(
        "\(dotted): a bang name is lowercase letters and digits (jira, gh2)", location: location)
      return nil
    }
    if let problem = UserBangs.templateProblem(bang.url) {
      config.addDiagnostic(
        "\(dotted) \(problem) (\"https://example.com/search?q={query}\")", location: location)
      return nil
    }
    if CoreBangs.bang(token: name) != nil {
      let own = CoreBangs.all.map { "!\($0.token)" }.joined(separator: ", ")
      config.addDiagnostic("\(dotted) is one of Flash's own bangs (\(own))", location: location)
      return nil
    }
    if let owner = PluginRepository.declaredBangOwners[name] {
      config.addDiagnostic("\(dotted) is the \(owner) plugin's bang", location: location)
      return nil
    }
    return bang
  }
}
