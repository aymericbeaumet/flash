import Foundation
import os

/// One entry of a manifest's `settings`: a `[plugins.<id>]` key the plugin
/// reads, with the type the host checks it against before the plugin starts.
struct PluginSettingDeclaration: Decodable, Equatable {
  enum Kind: String, Decodable, CaseIterable {
    case string, integer, number, boolean
    case stringArray = "string_array"
  }

  var type: Kind
  /// What the key is for: the schema's description, shown by an editor.
  var description: String
  /// What the plugin receives when no file sets the key.
  var defaultValue: PluginConfigValue?
  /// The values a `string` may take.
  var allowed: [String]?
  /// Inclusive bounds of an `integer` or a `number`.
  var min: Double?
  var max: Double?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case type, description, min, max
    case defaultValue = "default"
    case allowed = "enum"
  }

  init(
    type: Kind, description: String, defaultValue: PluginConfigValue? = nil,
    allowed: [String]? = nil, min: Double? = nil, max: Double? = nil
  ) {
    self.type = type
    self.description = description
    self.defaultValue = defaultValue
    self.allowed = allowed
    self.min = min
    self.max = max
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.type = try c.decode(Kind.self, forKey: .type)
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.allowed = try c.decodeIfPresent([String].self, forKey: .allowed)
    self.min = try c.decodeIfPresent(Double.self, forKey: .min)
    self.max = try c.decodeIfPresent(Double.self, forKey: .max)
    guard c.contains(.defaultValue) else {
      self.defaultValue = nil
      return
    }
    switch type {
    case .string: self.defaultValue = .string(try c.decode(String.self, forKey: .defaultValue))
    case .integer: self.defaultValue = .int(try c.decode(Int.self, forKey: .defaultValue))
    case .number:
      let value = try c.decode(Double.self, forKey: .defaultValue)
      self.defaultValue = Int(exactly: value).map { .int($0) } ?? .double(value)
    case .boolean: self.defaultValue = .bool(try c.decode(Bool.self, forKey: .defaultValue))
    case .stringArray:
      self.defaultValue = .stringArray(try c.decode([String].self, forKey: .defaultValue))
    }
  }

  /// What a value must be, as the rest of `plugins.<id>.<key> …`.
  var requirement: String {
    switch type {
    case .string:
      guard let allowed else { return "must be a string" }
      return "must be one of \(allowed.joined(separator: ", "))"
    case .boolean: return "must be true or false"
    case .stringArray: return "must be an array of strings"
    case .integer, .number:
      let noun = type == .integer ? "an integer" : "a number"
      switch (min, max) {
      case (let min?, let max?):
        return "must be \(noun) between \(Self.bound(min)) and \(Self.bound(max))"
      case (let min?, nil): return "must be \(noun) of at least \(Self.bound(min))"
      case (nil, let max?): return "must be \(noun) of at most \(Self.bound(max))"
      case (nil, nil): return "must be \(noun)"
      }
    }
  }

  private static func bound(_ value: Double) -> String {
    Int(exactly: value).map(String.init) ?? String(value)
  }

  /// Whether `value` is one this setting takes.
  func accepts(_ value: PluginConfigValue) -> Bool {
    func inBounds(_ number: Double) -> Bool {
      (min.map { number >= $0 } ?? true) && (max.map { number <= $0 } ?? true)
    }
    switch (type, value) {
    case (.string, .string(let string)): return allowed?.contains(string) ?? true
    case (.integer, .int(let int)), (.number, .int(let int)): return inBounds(Double(int))
    case (.number, .double(let double)): return inBounds(double)
    case (.boolean, .bool), (.stringArray, .stringArray): return true
    default: return false
    }
  }

  /// Why a manifest cannot declare this under `name`; nil when it can.
  func validationError(name: String) -> String? {
    let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
    guard !name.isEmpty, name.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else {
      return "names must be lowercase [a-z0-9_]"
    }
    if PluginSettings.host[name] != nil { return "is the host's own setting" }
    if description.trimmed.isEmpty { return "needs a description" }
    if let allowed {
      guard type == .string else { return "enum belongs to a string" }
      guard !allowed.isEmpty, Set(allowed).count == allowed.count else {
        return "enum must list distinct values"
      }
    }
    if min != nil || max != nil {
      guard type == .integer || type == .number else {
        return "min and max belong to an integer or a number"
      }
      if type == .integer,
        [min, max].compactMap({ $0 }).contains(where: { Int(exactly: $0) == nil })
      {
        return "min and max of an integer must be integers"
      }
      if let min, let max, min > max { return "min must not exceed max" }
    }
    if let defaultValue, !accepts(defaultValue) { return "default \(requirement)" }
    return nil
  }
}

/// `[plugins.<id>]` checked against what the plugin's manifest declares: one
/// rule for the config loader, the plugin manager and the config schema.
enum PluginSettings {
  /// The keys the host itself reads in every `[plugins.<id>]` table. No
  /// manifest declares them.
  static let host: [String: PluginSettingDeclaration] = [
    "sandbox": PluginSettingDeclaration(
      type: .boolean,
      description: "false launches the plugin without its sandbox profile; a kill switch for "
        + "a profile that blocks the plugin's work.")
  ]

  /// Why a `[plugins.<id>]` key is not delivered to its plugin.
  enum Problem: Equatable {
    /// The manifest declares no such setting; the nearest declared name.
    case undeclared(suggestion: String?)
    /// The declared setting does not take this value.
    case invalid(requirement: String)

    /// The diagnostic for the key at `path` (`plugins.<id>.<key>`).
    func message(path: String) -> String {
      switch self {
      case .undeclared(let suggestion):
        return "unknown config key '\(path)'"
          + (suggestion.map { " — did you mean '\($0)'?" } ?? "")
      case .invalid(let requirement): return "\(path) \(requirement)"
      }
    }
  }

  static func problem(
    key: String, value: PluginConfigValue, declared: [String: PluginSettingDeclaration]
  ) -> Problem? {
    guard let declaration = declared[key] ?? host[key] else {
      return .undeclared(
        suggestion: ConfigLoader.closestKnownKey(
          to: key, in: Set(declared.keys).union(host.keys)))
    }
    return declaration.accepts(value) ? nil : .invalid(requirement: declaration.requirement)
  }

  /// What a plugin receives as `FLASH_PLUGIN_CONFIG`: the authored values its
  /// manifest accepts over the declared defaults, and the keys left out.
  static func resolve(
    declared: [String: PluginSettingDeclaration], authored: [String: PluginConfigValue]
  ) -> (values: [String: PluginConfigValue], problems: [(key: String, problem: Problem)]) {
    var values = declared.compactMapValues(\.defaultValue)
    var problems: [(key: String, problem: Problem)] = []
    for key in authored.keys.sorted() {
      guard let value = authored[key] else { continue }
      if let problem = problem(key: key, value: value, declared: declared) {
        problems.append((key, problem))
      } else {
        values[key] = value
      }
    }
    return (values, problems)
  }
}

/// The settings each bundled plugin declares, by plugin id: what the config
/// loader checks `[plugins.<id>]` tables against and the config schema types.
/// A third-party plugin is not in it; the plugin manager checks its settings
/// against its manifest when it loads.
struct PluginSettingsCatalog: Equatable {
  var declared: [String: [String: PluginSettingDeclaration]]

  private struct Declared: Decodable {
    var id: String
    var settings: [String: PluginSettingDeclaration]?
  }

  private struct Cached {
    var modified: Date?
    var size: Int?
    var entry: Declared?
  }

  private static let cache = OSAllocatedUnfairLock<[URL: Cached]>(initialState: [:])

  /// The bundled manifests' declarations. A manifest is read again only when
  /// its file changed, so a config reload costs one `stat` per plugin. One
  /// that does not decode is left out: the plugin manager reports it.
  static func bundled(roots: [URL] = PluginRepository.officialPluginRoots())
    -> PluginSettingsCatalog
  {
    var declared: [String: [String: PluginSettingDeclaration]] = [:]
    for root in roots {
      let url = root.appendingPathComponent("manifest.json")
      let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ])
      var cached = cache.withLock { $0[url] }
      if cached == nil || cached?.modified != values?.contentModificationDate
        || cached?.size != values?.fileSize
      {
        let entry = (try? Data(contentsOf: url)).flatMap {
          try? JSONDecoder().decode(Declared.self, from: $0)
        }
        let read = Cached(
          modified: values?.contentModificationDate, size: values?.fileSize, entry: entry)
        cache.withLock { $0[url] = read }
        cached = read
      }
      guard let entry = cached?.entry, declared[entry.id] == nil else { continue }
      declared[entry.id] = entry.settings ?? [:]
    }
    return PluginSettingsCatalog(declared: declared)
  }
}
