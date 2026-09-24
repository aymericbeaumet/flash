import Foundation

struct CommandLaunchConfiguration: Equatable {
  let command: [String]
  let workingDirectory: String?
  let environment: [String: String]

  init(
    command: [String], workingDirectory: String? = nil,
    overrides: [String: String] = [:], environment base: [String: String]
  ) {
    var environment = base
    for (name, value) in overrides {
      environment[name] = Self.expand(value, environment: base)
    }
    self.command = command.map { Self.expand($0, environment: environment) }
    self.workingDirectory = workingDirectory.map { Self.expand($0, environment: environment) }
    self.environment = environment
  }

  static func expandLeadingTilde(_ value: String) -> String {
    guard value == "~" || value.hasPrefix("~/") else { return value }
    return (value as NSString).expandingTildeInPath
  }

  static func expand(_ value: String, environment: [String: String]) -> String {
    let value = expandLeadingTilde(value)
    var result = ""
    var cursor = value.startIndex
    while cursor < value.endIndex {
      guard value[cursor] == "$" else {
        result.append(value[cursor])
        cursor = value.index(after: cursor)
        continue
      }
      let start = cursor
      cursor = value.index(after: cursor)
      let braced = cursor < value.endIndex && value[cursor] == "{"
      if braced { cursor = value.index(after: cursor) }
      let nameStart = cursor
      while cursor < value.endIndex,
        value[cursor].isASCII,
        value[cursor].isLetter || value[cursor].isNumber || value[cursor] == "_"
      {
        cursor = value.index(after: cursor)
      }
      let name = String(value[nameStart..<cursor])
      if !name.isEmpty, !braced || (cursor < value.endIndex && value[cursor] == "}") {
        if braced { cursor = value.index(after: cursor) }
        result += environment[name] ?? String(value[start..<cursor])
      } else {
        result += String(value[start..<cursor])
      }
    }
    return result
  }
}
