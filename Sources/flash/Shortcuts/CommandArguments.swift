import Foundation

enum CommandArgumentError: Error, CustomStringConvertible {
  case malformed(String)
  case duplicate(String)

  var description: String {
    switch self {
    case .malformed(let value): return "invalid argument '\(value)'; use --name=value or --flag"
    case .duplicate(let name): return "duplicate argument '--\(name)'"
    }
  }
}

enum CommandArguments {
  static func parse<S: Sequence>(_ entries: S) throws -> [String: String]
  where S.Element == String {
    var result: [String: String] = [:]
    for entry in entries {
      guard entry.hasPrefix("--") else { throw CommandArgumentError.malformed(entry) }
      let parts = entry.dropFirst(2).split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = String(parts[0]).replacingOccurrences(of: "-", with: "_")
      guard let first = key.utf8.first, (97...122).contains(first),
        key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
      else { throw CommandArgumentError.malformed(entry) }
      guard result[key] == nil else { throw CommandArgumentError.duplicate(key) }
      result[key] = parts.count == 2 ? String(parts[1]) : "1"
    }
    return result
  }
}

struct VerbParameter {
  enum Kind {
    case flag
    case text(String)
    case integer
  }
  let name: String
  let kind: Kind
  let required: Bool

  static func flag(_ name: String) -> Self { Self(name: name, kind: .flag, required: false) }
  static func text(_ name: String, _ placeholder: String, required: Bool = false) -> Self {
    Self(name: name, kind: .text(placeholder), required: required)
  }
  static func integer(_ name: String, required: Bool = false) -> Self {
    Self(name: name, kind: .integer, required: required)
  }

  func accepts(_ value: String?) -> Bool {
    guard let value else { return !required }
    switch kind {
    case .flag: return ["0", "1", "false", "true"].contains(value)
    case .integer: return Int(value).map { $0 > 0 } ?? false
    case .text: return !required || !value.isEmpty
    }
  }

  var syntax: String {
    let flag = "--" + name.replacingOccurrences(of: "_", with: "-")
    let text: String
    switch kind {
    case .flag: text = flag
    case .integer: text = flag + "=<n>"
    case .text(let placeholder): text = flag + "=<\(placeholder)>"
    }
    return required ? text : "[\(text)]"
  }
}

struct VerbDefinition {
  let parameters: [VerbParameter]
  let parse: (VerbArgs) -> URLCommand?

  init(_ parameters: [VerbParameter] = [], parse: @escaping (VerbArgs) -> URLCommand?) {
    self.parameters = parameters
    self.parse = parse
  }

  func command(arguments: [String: String]) -> URLCommand? {
    guard Set(arguments.keys).isSubset(of: Set(parameters.map(\.name))),
      parameters.allSatisfy({ $0.accepts(arguments[$0.name]) })
    else { return nil }
    return parse(VerbArgs(args: arguments))
  }
}
