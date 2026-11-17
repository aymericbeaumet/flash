import Foundation
import TOMLKit

/// The JSON Schema (draft-07) of `flash.toml`: what an editor with a TOML
/// language server (Taplo, Tombi, Even Better TOML) completes, documents and
/// validates as you type.
///
/// One source for each part, so the schema cannot drift from the loader:
/// - the keys are the loader's own tables (`ConfigLoader.sectionKeys` and the
///   per-table sets it checks unknown keys against);
/// - the value types come from the bundled defaults (`config.default.toml`),
///   with `declaredTypes` for enumerations and keys that default to nothing;
/// - the descriptions are the comments above each key in the defaults.
///
/// `flash config schema` prints it for the running version; the published
/// copy is `docs/schema/flash.schema.json`, kept equal by a test.
enum ConfigSchema {
  /// Where the published copy lives, for a `#:schema` directive.
  static let publishedURL =
    "https://raw.githubusercontent.com/aymericbeaumet/flash/main/docs/schema/flash.schema.json"

  /// The schema as pretty JSON with sorted keys: stable, so the published
  /// copy diffs cleanly.
  static func json(defaults text: String) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: document(defaults: text),
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n"
  }

  static func document(defaults text: String) -> [String: Any] {
    let defaults = (try? TOMLTable(string: text)).map(plain) as? [String: Any] ?? [:]
    let builder = Builder(defaults: defaults, comments: comments(in: text))
    var root = builder.object(
      properties: Dictionary(
        uniqueKeysWithValues: ConfigLoader.topLevelSections.map { ($0, builder.section($0)) }))
    root["$schema"] = "http://json-schema.org/draft-07/schema#"
    root["$id"] = publishedURL
    root["title"] = "flash.toml"
    root["description"] =
      "Flash's configuration. Every key is optional: config.default.toml holds the defaults "
      + "and documents each one (flash help show --topic=configuration)."
    return root
  }

  // MARK: Types the defaults cannot show

  static let colorPattern = "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"
  static let optionalColorPattern = "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?)?$"

  /// Enumerations, unions and keys absent from the defaults, by dotted path.
  /// `*` stands for any user-chosen table name (a popup, widget, monitor,
  /// status source, layer or app).
  static var declaredTypes: [String: [String: Any]] {
    func strings(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    let argv: [String: Any] = [
      "type": "array", "items": ["type": "string"], "minItems": 1,
      "description": "An argv array: [\"flash\", \"<topic>\", \"<action>\", …] runs a Flash "
        + "command; any other head is an executable run without a shell.",
    ]
    let color: [String: Any] = ["type": "string", "pattern": colorPattern]
    let number: [String: Any] = ["type": "number"]
    let integer: [String: Any] = ["type": "integer"]
    let threshold: [String: Any] = [
      "anyOf": [number, ["const": false]],
      "description": "A threshold; false removes an inherited one.",
    ]
    let boolean: [String: Any] = ["type": "boolean"]
    let string: [String: Any] = ["type": "string"]
    let stringList: [String: Any] = ["type": "array", "items": string]
    let percent: [String: Any] = ["type": "number", "minimum": 0, "maximum": 100]
    return [
      "clipboard.history_size": integer,
      "calendar.calendars": stringList,
      "hints.mouse_grid_keys": stringList,
      "widgets.*.enabled": boolean, "widgets.*.hide_from_capture": boolean,
      "widgets.*.template": string, "widgets.*.font": string,
      "widgets.*.columns": integer, "widgets.*.max_columns": integer,
      "widgets.*.interval": integer,
      "widgets.*.gap_x": number, "widgets.*.gap_y": number, "widgets.*.font_size": number,
      "widgets.*.line_spacing": number, "widgets.*.border_size": number,
      "widgets.*.corner_radius": number, "widgets.*.padding": number,
      "window_rules.*.x": percent, "window_rules.*.y": percent,
      "window_rules.*.width": percent, "window_rules.*.height": percent,
      "monitors.*.detail": string, "monitors.*.alert": boolean,
      "monitors.*.notify": boolean,
      "tiling.workspaces": stringList,
      "tiling.workspaces.*": string,
      "tiling.gaps": [
        "type": "object", "additionalProperties": false,
        "properties": Dictionary(
          uniqueKeysWithValues: [
            "inner", "inner_horizontal", "inner_vertical", "outer", "outer_left", "outer_right",
            "outer_top", "outer_bottom",
          ].map { ($0, integer) }),
      ],
      "tiling.monitors": [
        "type": "object",
        "additionalProperties": [
          "anyOf": [strings(["main", "secondary"]), ["type": "integer", "minimum": 1]]
        ],
      ],
      "tiling.rules": [
        "type": "array",
        "items": [
          "type": "object", "additionalProperties": false, "required": ["bundle_id"],
          "properties": [
            "bundle_id": string, "title_contains": string, "float": boolean, "workspace": string,
          ],
        ],
      ],
      "monitors.*.idle": integer,
      "monitors.*.at": [
        "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]
      ],
      "monitors.*.days": [
        "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]
      ],
      "telemetry.receiver.token": string,
      "statusbar.sources.*.interval": integer, "statusbar.sources.*.cycle_interval": integer,
      "statusbar.sources.*.history": integer, "statusbar.sources.*.working_directory": string,
      "app.updates": strings(UpdateMode.allCases.map(\.rawValue)),
      "keyboard.layout": strings(Alphabet.layoutNames),
      "debug.log_level": strings(["trace", "debug", "info", "warn", "error", "fatal"]),
      "statusbar.monitor": strings(["all", "primary"]),
      "statusbar.link_schemes": [
        "type": "array", "uniqueItems": true,
        "items": ["type": "string", "pattern": "^[a-z][a-z0-9+.-]*$"],
      ],
      "statusbar.sources": ["type": "object"],
      "hints.label_order": strings(Config.LabelOrder.allCases.map(\.rawValue)),
      "hints.adjust_digits": strings(Config.AdjustDigits.allCases.map(\.rawValue)),
      "hints.position_history_scope": strings(
        Config.PositionScope.allCases.map(\.rawValue)),
      "overlay.hint_placement": strings(HintPlacement.allCases.map(\.rawValue)),
      "flashlight.aliases": ["type": "object", "additionalProperties": ["type": "string"]],
      "flashlight.bangs": [
        "type": "object",
        "additionalProperties": [
          "anyOf": [
            ["type": "string", "pattern": "^https?://"],
            [
              "type": "object", "additionalProperties": false, "required": ["url"],
              "properties": [
                "url": ["type": "string", "pattern": "^https?://"], "description": string,
              ],
            ],
          ],
          "description": "A bang of your own: an http or https URL, {query} where the query "
            + "goes (none: a quicklink), as a string or { url, description }.",
        ],
      ],
      "flashlight.precedence": ["type": "object", "additionalProperties": integer],
      "flashlight.ignored_apps": ["type": "array", "items": ["type": "string"]],
      "flashlight.app_directories": ["type": "array", "items": ["type": "string"]],
      "plugins.disabled": ["type": "array", "items": ["type": "string"]],
      "plugins.third_party": ["type": "array", "items": ["type": "object"]],
      "mode.normal.leader": ["anyOf": [["type": "string"], ["const": false]]],
      "mode.move_page_lines": ["type": "integer", "minimum": 1, "maximum": 200],
      "mode.normal.hyper": ["anyOf": [["type": "string"], ["const": false]]],
      "mode.text.enabled": boolean,
      "mode.apps.*.text.enabled": boolean,
      "popup.fg": color, "popup.bg": color, "popup.border": color,
      "popup.*.text": ["type": "string", "description": "A status format shown in the pager."],
      "popup.*.command": argv,
      "popup.*.cwd": ["type": "string"],
      "popup.*.env": ["type": "object", "additionalProperties": ["type": "string"]],
      "popup.*.size": [
        "type": "string", "pattern": "^[0-9.]+%?x[0-9.]+%?$",
        "description": "Columns x rows in cells, or a percentage of the screen: \"100x28\", "
          + "\"90%x85%\".",
      ],
      "popup.*.persistent": ["type": "boolean"],
      "popup.*.pause_hidden": [
        "type": "boolean",
        "description": "Stop a persistent popup's process while hidden and continue it when "
          + "shown (needs persistent = true).",
      ],
      "widgets.*.anchor": strings(Config.Widget.Anchor.allCases.map(\.rawValue)),
      "widgets.*.fg": color, "widgets.*.bg": color, "widgets.*.border": color,
      "widgets.*.screen": ["anyOf": [strings(["primary", "all"]), integer]],
      "monitors.*.warning": threshold, "monitors.*.error": threshold,
      "monitors.*.direction": strings(MonitorDirection.allCases.map(\.rawValue)),
      "monitors.*.run": [
        "anyOf": [argv, ["type": "array", "items": argv, "minItems": 1]],
        "description": "One argv array, or a list of them run in order.",
      ],
      "monitors.*.event": ["type": "string"], "monitors.*.app": ["type": "string"],
      "monitors.*.usb": [
        "type": "object", "additionalProperties": false,
        "properties": [
          "vendor_id": ["type": "integer", "minimum": 0, "maximum": 65535],
          "product_id": ["type": "integer", "minimum": 0, "maximum": 65535],
          "name": string,
        ],
        "description": "The USB device core:usb.attached and core:usb.detached must name: "
          + "vendor_id and product_id exactly, name as a part of the product name; any "
          + "subset, never empty.",
      ],
      "monitors.*.timeout": integer, "monitors.*.cooldown": integer,
      "statusbar.sources.*.command": argv,
      "statusbar.sources.*.output": strings(FlashStatusBarSourceOutput.allCases.map(\.rawValue)),
      "statusbar.sources.*.env": ["type": "object", "additionalProperties": ["type": "string"]],
      "window_rules.*.bundle_id": ["type": "string"],
      "window_rules.*.title_contains": ["type": "string"],
      "window_rules.*.position": ["type": "string"],
      "window_rules.*.screen": integer,
      "telemetry.exporter.protocol": strings(OTLPEncoding.allCases.map(\.rawValue)),
      "telemetry.exporter.compression": strings(["none", "gzip"]),
      "telemetry.exporter.signals": [
        "type": "array", "items": strings(TelemetrySignal.allCases.map(\.rawValue)),
      ],
      "telemetry.exporter.headers": [
        "type": "object", "additionalProperties": ["type": "string"],
      ],
      "startup.run": [
        "anyOf": [argv, ["type": "array", "items": argv]],
        "description": "Commands run in order, once at each launch and on startup run: a list "
          + "of argv arrays (one argv array is one command, [] none).",
      ],
    ]
  }

  /// Keys whose value takes any TOML type, left untyped on purpose.
  static let untypedKeys: Set<String> = [
    // Each `[plugins.<id>]` table is the plugin's own settings.
    "plugins.*",
    // Plain string, integer, or float, as the monitored value parses.
    "monitors.*.value",
  ]

  // MARK: Building

  private struct Builder {
    let defaults: [String: Any]
    let comments: [String: String]

    func object(
      properties: [String: Any], additional: Any = false, description: String? = nil
    ) -> [String: Any] {
      var node: [String: Any] = [
        "type": "object", "properties": properties, "additionalProperties": additional,
      ]
      if let description { node["description"] = description }
      return node
    }

    func value(at path: [String]) -> Any? {
      var current: Any? = defaults
      for key in path {
        current = (current as? [String: Any])?[key]
      }
      return current
    }

    /// The schema of one key: declared, else inferred from its default,
    /// with the comment above it as its description.
    func key(_ path: [String], pattern: [String]? = nil) -> [String: Any] {
      let dotted = path.joined(separator: ".")
      let lookup = (pattern ?? path).joined(separator: ".")
      var node =
        ConfigSchema.declaredTypes[lookup]
        ?? value(at: path).map(ConfigSchema.inferred)
        ?? [:]
      if node["description"] == nil, let comment = comments[dotted] ?? comments[lookup] {
        node["description"] = comment
      }
      return node
    }

    func keys(_ names: Set<String>, under path: [String], pattern: [String]? = nil)
      -> [String: Any]
    {
      Dictionary(
        uniqueKeysWithValues: names.map { name in
          (name, key(path + [name], pattern: pattern.map { $0 + [name] }))
        })
    }

    func section(_ name: String) -> [String: Any] {
      let description = comments[name]
      switch name {
      case "popup":
        return object(
          properties: keys(ConfigLoader.popupStyleKeys, under: ["popup"]),
          additional: [
            "description": "A named popup ([popup.<name>]): text or command, not both.",
            "anyOf": [
              object(
                properties: keys(
                  ConfigLoader.textPopupKeys, under: ["popup", "*"], pattern: ["popup", "*"])
              )
              .merging(["required": ["text"]]) { $1 },
              object(
                properties: keys(
                  ConfigLoader.terminalPopupKeys, under: ["popup", "*"], pattern: ["popup", "*"])
              )
              .merging(["required": ["command"]]) { $1 },
            ],
          ],
          description: description)
      case "widgets":
        return map(of: named("widgets", ConfigLoader.widgetKeys), description: description)
      case "monitors":
        return map(of: named("monitors", ConfigLoader.monitorKeys), description: description)
      case "window_rules":
        return [
          "type": "array",
          "description": description ?? "Placement rules ([[window_rules]]); see docs/windows.md.",
          "items": named("window_rules", ConfigLoader.windowRuleKeys),
        ]
      case "telemetry":
        return object(
          properties: [
            "receiver": object(
              properties: keys(
                ConfigLoader.telemetryReceiverKeys, under: ["telemetry", "receiver"]),
              description: comments["telemetry.receiver"]),
            "exporter": object(
              properties: keys(
                ConfigLoader.telemetryExporterKeys, under: ["telemetry", "exporter"]),
              description: comments["telemetry.exporter"]),
          ], description: description)
      default:
        return fixed(name, description: description)
      }
    }

    /// A user-named table's fields: `[<section>.<name>]`, typed by `*` paths.
    func named(_ section: String, _ names: Set<String>) -> [String: Any] {
      // A built-in default (`[monitors.battery]`) shows each field's type.
      let sample = (value(at: [section]) as? [String: Any])?.keys.sorted().first
      return object(
        properties: Dictionary(
          uniqueKeysWithValues: names.map { name in
            let declared = ConfigSchema.declaredTypes["\(section).*.\(name)"]
            var node =
              declared
              ?? sample.flatMap { value(at: [section, $0, name]) }.map(ConfigSchema.inferred)
              ?? [:]
            if node["description"] == nil,
              let comment = sample.flatMap({ comments["\(section).\($0).\(name)"] })
            {
              node["description"] = comment
            }
            return (name, node)
          }))
    }

    func map(of item: [String: Any], description: String?) -> [String: Any] {
      var node: [String: Any] = ["type": "object", "additionalProperties": item]
      if let description { node["description"] = description }
      return node
    }

    /// A section whose keys are fixed, with its known subtables.
    func fixed(_ name: String, description: String?) -> [String: Any] {
      var properties = keys(ConfigLoader.sectionKeys[name] ?? [], under: [name])
      var additional: Any = false
      switch name {
      case "plugins":
        additional = [
          "type": "object", "description": "A plugin's settings ([plugins.<id>]).",
        ]
      case "overlay":
        let dark = (value(at: ["overlay", "dark"]) as? [String: Any])?.keys.sorted() ?? []
        properties["dark"] = object(
          properties: Dictionary(
            uniqueKeysWithValues: dark.map { key in
              var node: [String: Any] = [
                "type": "string", "pattern": ConfigSchema.optionalColorPattern,
              ]
              node["description"] = comments["overlay.dark.\(key)"]
              return (key, node)
            }), description: comments["overlay.dark"])
      case "statusbar":
        properties["sources"] = map(
          of: named("statusbar.sources", ConfigLoader.statusSourceKeys)
            .merging(["description": "A named status source ([statusbar.sources.<name>])."]) {
              $1
            },
          description: comments["statusbar.sources"])
        properties["click"] = map(
          of: [
            "anyOf": [
              ["type": "string", "format": "uri"],
              ConfigSchema.declaredTypes["statusbar.sources.*.command"] ?? [:],
            ]
          ], description: comments["statusbar.click"])
      case "mode":
        properties = mode(properties)
      default:
        break
      }
      return object(properties: properties, additional: additional, description: description)
    }

    func mode(_ base: [String: Any]) -> [String: Any] {
      var properties = base
      let argv = ConfigSchema.declaredTypes["popup.*.command"] ?? [:]
      let mappingValue: [String: Any] = [
        "anyOf": [
          argv, ["const": false],
          [
            "type": "object", "additionalProperties": false, "required": ["command"],
            "properties": ["command": argv, "repeat": ["type": "boolean"]],
          ],
        ],
        "description": "A command (argv array) for the key, false to remove an inherited one, "
          + "or { command = [...], repeat = true } to repeat it on its final key.",
      ]
      let mappings: [String: Any] = [
        "type": "object", "additionalProperties": mappingValue,
        "description": "Key → command. Keys use Flash's key syntax (docs/mappings.md).",
      ]
      let scoped = object(properties: ["mappings": mappings])
      properties["labels"] = object(
        properties: Dictionary(
          uniqueKeysWithValues: ConfigLoader.modeLabelKeys.map {
            ($0, ["type": "string", "minLength": 1, "maxLength": 32] as [String: Any])
          }), description: comments["mode.labels"])
      properties["normal"] = object(
        properties: Dictionary(
          uniqueKeysWithValues: ConfigLoader.modeNormalKeys.map { key in
            (key, key == "mappings" ? mappings : self.key(["mode", "normal", key]))
          }), description: comments["mode.normal"])
      for scope in ["all", "insert", "command", "terminal", "hyper", "hold", "visual"] {
        properties[scope] = scoped.merging(
          comments["mode.\(scope).mappings"].map { ["description": $0] } ?? [:]
        ) { $1 }
      }
      // `[mode.text]` carries the engagement switch beside its table.
      properties["text"] = object(
        properties: [
          "enabled": key(["mode", "text", "enabled"]),
          "mappings": mappings.merging(
            comments["mode.text.mappings"].map { ["description": $0] } ?? [:]
          ) { $1 },
        ], description: comments["mode.text"])
      let appText = object(
        properties: [
          "enabled": key(["mode", "apps", "*", "text", "enabled"]),
          "mappings": mappings,
        ],
        description: "enabled = true engages this app's fields although a plugin declared it "
          + "an editor with its own text editing; false never engages them. Its text mappings "
          + "share this table.")
      properties["apps"] = map(
        of: object(
          properties: Dictionary(
            uniqueKeysWithValues: [
              "all", "normal", "insert", "command", "terminal", "hyper", "hold", "visual",
            ]
            .map { ($0, scoped) } + [("text", appText)]),
          description: "Mappings for one exact bundle ID, by mode scope, and its text switch."),
        description: comments["mode.apps"])
      properties["layers"] = map(
        of: object(
          properties: [
            "label": ["type": "string", "minLength": 1, "maxLength": 32],
            "sticky": ["type": "boolean"],
            "mappings": mappings,
          ]), description: comments["mode.layers"])
      return properties
    }
  }

  /// A key's schema from its default value.
  static func inferred(_ value: Any) -> [String: Any] {
    switch value {
    case is Bool: return ["type": "boolean"]
    case is Int: return ["type": "integer"]
    case is Double: return ["type": "number"]
    case let string as String:
      return string.range(of: colorPattern, options: .regularExpression) != nil
        ? ["type": "string", "pattern": colorPattern] : ["type": "string"]
    case let array as [Any]:
      return ["type": "array", "items": array.first.map(inferred) ?? [:]]
    case is [String: Any]: return ["type": "object"]
    default: return [:]
    }
  }

  /// A TOML value as plain Swift values (Bool, Int, Double, String, arrays
  /// and dictionaries), the shape JSONSerialization and the tests read.
  static func plain(_ value: any TOMLValueConvertible) -> Any {
    switch value.type {
    case .table:
      var result: [String: Any] = [:]
      for (key, child) in value.table ?? [:] { result[key] = plain(child) }
      return result
    case .array: return (value.array ?? []).map(plain)
    case .string: return value.string ?? ""
    case .int: return value.int ?? 0
    case .double: return value.double ?? 0
    case .bool: return value.bool ?? false
    case .date, .time, .dateTime: return "\(value)"
    }
  }

  /// The comment block right above each key (and table header) of the
  /// defaults, by dotted path: what an editor shows on hover. Commented-out
  /// TOML (`# key = value`, `# [table]`) is an example, not a description.
  static func comments(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var table: [String] = []
    var block: [String] = []
    let keyLine = try? NSRegularExpression(pattern: #"^("[^"]+"|[A-Za-z0-9_-]+)\s*="#)
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#:") { continue }  // a tool directive such as #:schema
      if line.hasPrefix("#") {
        let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
        // A commented-out example, its multi-line array's closing bracket
        // included, describes nothing.
        let isExample =
          comment.hasPrefix("[") || comment.hasPrefix("]")
          || keyLine?.firstMatch(
            in: comment, range: NSRange(comment.startIndex..., in: comment)) != nil
        if isExample { block = [] } else if !comment.isEmpty { block.append(comment) }
        continue
      }
      defer { block = [] }
      if line.hasPrefix("[") {
        let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        table = name.split(separator: ".").map {
          String($0).trimmingCharacters(in: .init(charactersIn: "\""))
        }
        if !block.isEmpty { result[table.joined(separator: ".")] = block.joined(separator: " ") }
        continue
      }
      guard let match = keyLine?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let range = Range(match.range(at: 1), in: line), !block.isEmpty
      else { continue }
      let key = line[range].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      result[(table + [key]).joined(separator: ".")] = block.joined(separator: " ")
    }
    return result
  }
}
