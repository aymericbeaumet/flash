import Darwin
import Foundation

struct StatusFormatOrigin: Equatable, Hashable {
  var name: String
  init(_ name: String = "statusbar.format") { self.name = name }
}

struct StatusFormatSpan: Equatable, Hashable {
  var origin: StatusFormatOrigin
  var bytes: Range<Int>
  var invocation: [String] = []
  var identity: String {
    "\(origin.name):\(bytes.lowerBound)" + invocation.map { "@\($0)" }.joined()
  }
}

struct StatusFormatDiagnostic: Equatable {
  var span: StatusFormatSpan
  var message: String
}

struct StatusFormatDependencies: Equatable {
  var values: Set<String> = []
  var options: Set<String> = []
  var containsJobs = false
  var containsTime = false

  mutating func formUnion(_ other: Self) {
    values.formUnion(other.values)
    options.formUnion(other.options)
    containsJobs = containsJobs || other.containsJobs
    containsTime = containsTime || other.containsTime
  }
}

struct StatusFormatFragment: Equatable {
  var text: String
  var span: StatusFormatSpan
}

struct StatusFormatJobRequest: Equatable, Hashable {
  var rawCommand: String
  var command: String
  var span: StatusFormatSpan
}

struct StatusFormatEvaluation: Equatable {
  var fragments: [StatusFormatFragment] = []
  var jobs: [StatusFormatJobRequest] = []
  var dependencies = StatusFormatDependencies()
  var text: String { fragments.map(\.text).joined() }
}

/// Loop records supply language context without importing a tmux server's state.
struct StatusFormatScope: Equatable {
  var values: [String: String]
  var options: [String: String] = [:]
  var active = false
  var index = 0
  var name = ""
  var activity: TimeInterval = 0
}

struct StatusFormatContext {
  var values: [String: String] = [:]
  var options: [String: String] = [:]
  var jobs: [String: String] = [:]
  var scopes: [String: [StatusFormatScope]] = [:]
  var paneLines: [String] = []
  var environment: [String: String] = [:]
  var now = Date()
  var timeZone = TimeZone.current
  var allowJobs = true
  var timeExpansion = false
  var invocation: [String] = []
}

/// The decoded format, including every nested operand, is compiled once. Rendering,
/// configuration diagnostics and dependency discovery all consume this program.
struct StatusFormatProgram: Equatable {
  indirect enum Node: Equatable {
    case text(String, StatusFormatSpan)
    case expression(Expression, StatusFormatSpan)
    case job(StatusFormatProgram, StatusFormatSpan)
  }

  struct Modifier: Equatable {
    var name: String
    var arguments: [StatusFormatProgram]
  }

  struct Expression: Equatable {
    var modifiers: [Modifier]
    var operand: StatusFormatProgram
    var arguments: [StatusFormatProgram]
    var raw: String
  }

  var source: String
  var origin: StatusFormatOrigin
  var nodes: [Node]
  var diagnostics: [StatusFormatDiagnostic]
  var dependencies: StatusFormatDependencies

  static func compile(
    source: String, origin: StatusFormatOrigin = StatusFormatOrigin()
  ) -> Self {
    StatusFormatProgramCache.shared.program(source: source, origin: origin) {
      compile(source: source, origin: origin, offset: 0, depth: 0)
    }
  }

  private static func compile(
    source: String, origin: StatusFormatOrigin, offset: Int, depth: Int
  ) -> Self {
    let bytes = Array(source.utf8)
    var result = Self(
      source: source, origin: origin, nodes: [], diagnostics: [],
      dependencies: StatusFormatDependencies(containsTime: source.contains("%")))
    guard depth < 100 else { return result }
    var index = 0
    var buffer = ""
    var bufferStart = 0
    var styleEnd = -1
    func span(_ range: Range<Int>) -> StatusFormatSpan {
      StatusFormatSpan(
        origin: origin, bytes: (range.lowerBound + offset)..<(range.upperBound + offset))
    }
    func flush() {
      guard !buffer.isEmpty else { return }
      result.nodes.append(.text(buffer, span(bufferStart..<index)))
      buffer = ""
    }
    while index < bytes.count {
      guard bytes[index] == 35 else {
        let next = bytes[(index + 1)...].firstIndex(of: 35) ?? bytes.count
        if buffer.isEmpty { bufferStart = index }
        buffer += String(decoding: bytes[index..<next], as: UTF8.self)
        index = next
        continue
      }
      let start = index
      guard index + 1 < bytes.count else {
        flush()
        break
      }
      let next = bytes[index + 1]
      if next == 123 {
        flush()
        guard let end = StatusFormatSyntax.find(bytes, from: index, delimiters: [125]) else {
          result.diagnostics.append(
            .init(span: span(start..<bytes.count), message: "Unclosed format expression"))
          break
        }
        let expression = expression(
          bytes: Array(bytes[(index + 2)..<end]), origin: origin,
          offset: offset + index + 2, depth: depth + 1)
        result.nodes.append(.expression(expression, span(start..<(end + 1))))
        for program in [expression.operand] + expression.arguments
          + expression.modifiers.flatMap(\.arguments)
        {
          result.dependencies.formUnion(program.dependencies)
          result.diagnostics += program.diagnostics
        }
        let name = expression.raw
        if !name.hasPrefix("?"), !name.contains("#{"),
          expression.modifiers.isEmpty
            || expression.modifiers.allSatisfy({
              ![
                "?", "l", "a", "c", "R", "!", "!!", "&&", "||", "e", "m", "C", "S", "W", "P", "L",
                "N", "==", "!=", "<", ">", "<=", ">=",
              ].contains($0.name)
            })
        {
          if name.hasPrefix("@") {
            result.dependencies.options.insert(name)
          } else if !name.isEmpty {
            result.dependencies.values.insert(name)
          }
        }
        if name.hasPrefix("?") {
          for index in stride(from: 0, to: max(0, expression.arguments.count - 1), by: 2) {
            let condition = expression.arguments[index].source
            if !condition.contains("#{") {
              if condition.hasPrefix("@") {
                result.dependencies.options.insert(condition)
              } else {
                result.dependencies.values.insert(condition)
              }
            }
          }
        }
        if expression.modifiers.contains(where: { ["t", "T"].contains($0.name) }) {
          result.dependencies.containsTime = true
        }
        index = end + 1
      } else if next == 40 {
        flush()
        var nesting = 1
        var end = index + 2
        while end < bytes.count {
          if bytes[end] == 40 { nesting += 1 }
          if bytes[end] == 41 {
            nesting -= 1
            if nesting == 0 { break }
          }
          end += 1
        }
        guard end < bytes.count else {
          result.diagnostics.append(
            .init(span: span(start..<bytes.count), message: "Unclosed shell command"))
          break
        }
        let command = compile(
          source: String(decoding: bytes[(index + 2)..<end], as: UTF8.self),
          origin: origin, offset: offset + index + 2, depth: depth + 1)
        result.nodes.append(.job(command, span(start..<(end + 1))))
        result.dependencies.formUnion(command.dependencies)
        result.dependencies.containsJobs = true
        result.diagnostics += command.diagnostics
        index = end + 1
      } else if next == 35 || next == 91 {
        var end = index
        while end < bytes.count, bytes[end] == 35 { end += 1 }
        if end < bytes.count, bytes[end] == 91 {
          styleEnd = StatusFormatSyntax.find(bytes, from: end + 1, delimiters: [93]) ?? bytes.count
          if buffer.isEmpty { bufferStart = index }
          buffer += String(decoding: bytes[index...end], as: UTF8.self)
          index = end + 1
        } else {
          if buffer.isEmpty { bufferStart = index }
          buffer += next == 35 ? "#" : "["
          index += 2
        }
      } else if next == 125 || next == 44 {
        if buffer.isEmpty { bufferStart = index }
        buffer += String(UnicodeScalar(next))
        index += 2
      } else if index > styleEnd, let alias = StatusFormatSyntax.aliases[next] {
        flush()
        let operand = compile(
          source: alias, origin: origin, offset: offset + start, depth: depth + 1)
        result.nodes.append(
          .expression(
            Expression(modifiers: [], operand: operand, arguments: [operand], raw: alias),
            span(start..<(start + 2))))
        result.dependencies.values.insert(alias)
        index += 2
      } else {
        if buffer.isEmpty { bufferStart = index }
        let length = next < 128 ? 1 : next < 224 ? 2 : next < 240 ? 3 : 4
        let end = min(bytes.count, index + 1 + length)
        buffer += String(decoding: bytes[index..<end], as: UTF8.self)
        index = end
      }
    }
    flush()
    return result
  }

  private static func expression(
    bytes: [UInt8], origin: StatusFormatOrigin, offset: Int, depth: Int
  ) -> Expression {
    let parsed = StatusFormatSyntax.modifiers(bytes)
    let operandBytes = Array(bytes[parsed.end...])
    let raw = String(decoding: operandBytes, as: UTF8.self)
    let modifiers = parsed.modifiers.map { modifier in
      Modifier(
        name: modifier.name,
        arguments: modifier.arguments.map { range in
          compile(
            source: String(decoding: bytes[range], as: UTF8.self), origin: origin,
            offset: offset + range.lowerBound, depth: depth)
        })
    }
    let names = Set(modifiers.map(\.name))
    let conditional = raw.hasPrefix("?")
    let allArguments = conditional || names.contains("&&") || names.contains("||")
    let splitArguments =
      allArguments
      || !names.isDisjoint(with: ["==", "!=", "<", ">", "<=", ">=", "m", "e", "R", "W", "P"])
    let argumentStart = conditional ? parsed.end + 1 : parsed.end
    var ranges =
      splitArguments ? StatusFormatSyntax.split(bytes, from: argumentStart, delimiter: 44) : []
    if !allArguments, ranges.count > 2 { ranges = [ranges[0], ranges[1].lowerBound..<bytes.count] }
    let operand =
      splitArguments || names.contains("l")
      ? Self(source: raw, origin: origin, nodes: [], diagnostics: [], dependencies: .init())
      : compile(source: raw, origin: origin, offset: offset + parsed.end, depth: depth)
    return Expression(
      modifiers: modifiers,
      operand: operand,
      arguments: ranges.map {
        compile(
          source: String(decoding: bytes[$0], as: UTF8.self), origin: origin,
          offset: offset + $0.lowerBound, depth: depth)
      }, raw: raw)
  }

  func evaluate(_ context: StatusFormatContext = StatusFormatContext(), expandTime: Bool = false)
    -> StatusFormatEvaluation
  {
    var context = context
    context.timeExpansion = expandTime
    var evaluator = StatusFormatEvaluator(context: context)
    let fragments = evaluator.expand(self, context: context, depth: 0)
    return StatusFormatEvaluation(
      fragments: fragments, jobs: evaluator.jobs, dependencies: evaluator.dependencies)
  }
}

/// Shared byte lexer for compilation, modifier separators and expanded styles.
enum StatusFormatSyntax {
  static let aliases: [UInt8: String] = [
    68: "pane_id", 70: "window_flags", 72: "host", 73: "window_index",
    80: "pane_index", 83: "session_name", 84: "pane_title", 87: "window_name", 104: "host_short",
  ]

  static func find(_ bytes: [UInt8], from start: Int, delimiters: Set<UInt8>) -> Int? {
    var depth = 0
    var index = start
    while index < bytes.count {
      if bytes[index] == 35, index + 1 < bytes.count {
        if bytes[index + 1] == 123 { depth += 1 }
        if [44, 35, 123, 125, 58].contains(bytes[index + 1]) {
          index += 2
          continue
        }
      }
      if bytes[index] == 125 { depth -= 1 }
      if depth == 0, delimiters.contains(bytes[index]) { return index }
      index += 1
    }
    return nil
  }

  static func split(_ bytes: [UInt8], from start: Int = 0, delimiter: UInt8) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var index = start
    while let end = find(bytes, from: index, delimiters: [delimiter]) {
      ranges.append(index..<end)
      index = end + 1
    }
    ranges.append(index..<bytes.count)
    return ranges
  }

  struct RawModifier {
    var name: String
    var arguments: [Range<Int>]
  }

  static func modifiers(_ bytes: [UInt8]) -> (modifiers: [RawModifier], end: Int) {
    var result: [RawModifier] = []
    var index = 0
    func separator(_ value: UInt8) -> Bool { value == 58 || value == 59 }
    while index < bytes.count {
      let start = index
      var name = ""
      var arguments: [Range<Int>] = []
      if index + 2 < bytes.count,
        ["||", "&&", "!!", "!=", "==", "<=", ">="].contains(
          String(decoding: bytes[index..<(index + 2)], as: UTF8.self)),
        separator(bytes[index + 2])
      {
        name = String(decoding: bytes[index..<(index + 2)], as: UTF8.self)
        index += 2
      } else if index + 1 < bytes.count,
        Array("labcdnwETSWPL!<>".utf8).contains(bytes[index]), separator(bytes[index + 1])
      {
        name = String(UnicodeScalar(bytes[index]))
        index += 1
      } else if Array("mCLNPSst=pReqW".utf8).contains(bytes[index]), index + 1 < bytes.count {
        name = String(UnicodeScalar(bytes[index]))
        index += 1
        if !separator(bytes[index]) {
          let delimiter = bytes[index]
          let punctuation =
            (33...47).contains(delimiter) || (58...64).contains(delimiter)
            || (91...96).contains(delimiter) || (123...126).contains(delimiter)
          if !punctuation || delimiter == 45 {
            guard let end = find(bytes, from: index, delimiters: [58, 59]) else { return ([], 0) }
            arguments.append(index..<end)
            index = end
          } else {
            index += 1
            while index <= bytes.count {
              guard let end = find(bytes, from: index, delimiters: [delimiter, 58, 59]) else {
                return ([], 0)
              }
              arguments.append(index..<end)
              index = end
              if bytes[index] != delimiter { break }
              index += 1
              if index < bytes.count, separator(bytes[index]) { break }
            }
          }
        }
      } else {
        return ([], 0)
      }
      guard index > start, index < bytes.count, separator(bytes[index]) else { return ([], 0) }
      result.append(RawModifier(name: name, arguments: arguments))
      let end = bytes[index] == 58
      index += 1
      if end { return (result, index) }
    }
    return ([], 0)
  }

  static func unescape(_ raw: String) -> String {
    let bytes = Array(raw.utf8)
    var output: [UInt8] = []
    var depth = 0
    var index = 0
    while index < bytes.count {
      if bytes[index] == 35, index + 1 < bytes.count {
        if bytes[index + 1] == 123 { depth += 1 }
        if depth == 0, [44, 35, 123, 125, 58].contains(bytes[index + 1]) {
          output.append(bytes[index + 1])
          index += 2
          continue
        }
      }
      if bytes[index] == 125 { depth -= 1 }
      output.append(bytes[index])
      index += 1
    }
    return String(decoding: output, as: UTF8.self)
  }
}

private struct StatusFormatEvaluator {
  var context: StatusFormatContext
  var jobs: [StatusFormatJobRequest] = []
  var dependencies = StatusFormatDependencies()
  let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000

  mutating func expand(
    _ program: StatusFormatProgram, context: StatusFormatContext, depth: Int, time: Bool = false
  ) -> [StatusFormatFragment] {
    guard depth < 100, DispatchTime.now().uptimeNanoseconds < deadline else { return [] }
    var program = program
    var context = context
    context.timeExpansion = time || context.timeExpansion
    if context.timeExpansion, program.source.contains("%") {
      dependencies.containsTime = true
      let expanded = Self.strftime(program.source, date: context.now, timeZone: context.timeZone)
      program = StatusFormatProgram.compile(source: expanded, origin: program.origin)
    }
    var output: [StatusFormatFragment] = []
    for node in program.nodes {
      switch node {
      case .text(let text, var span):
        span.invocation = context.invocation
        output.append(.init(text: text, span: span))
      case .expression(let expression, let span):
        var span = span
        span.invocation = context.invocation
        if let value = evaluate(expression, span: span, context: context, depth: depth + 1) {
          output += value
        } else {
          return output
        }
      case .job(let commandProgram, var span):
        guard context.allowJobs else { continue }
        span.invocation = context.invocation
        var commandContext = context
        commandContext.allowJobs = false
        commandContext.timeExpansion = false
        let command = expand(commandProgram, context: commandContext, depth: depth + 1).map(\.text)
          .joined()
        jobs.append(.init(rawCommand: commandProgram.source, command: command, span: span))
        dependencies.containsJobs = true
        let cached = StatusFormatProgram.compile(
          source: context.jobs[commandProgram.source] ?? "", origin: span.origin)
        output += expand(cached, context: commandContext, depth: depth + 1)
      }
    }
    return output
  }

  mutating func evaluate(
    _ expression: StatusFormatProgram.Expression, span: StatusFormatSpan,
    context: StatusFormatContext, depth: Int
  ) -> [StatusFormatFragment]? {
    guard depth < 100 else { return [] }
    var modifiers: [(name: String, arguments: [String])] = []
    for modifier in expression.modifiers {
      modifiers.append(
        (
          modifier.name,
          modifier.arguments.map {
            expand($0, context: context, depth: depth).map(\.text).joined()
          }
        ))
    }
    let names = Set(modifiers.map(\.name))
    func argument(_ name: String) -> [String] {
      modifiers.last(where: { $0.name == name })?.arguments ?? []
    }
    let nameQueries = modifiers.filter { $0.name == "N" }
    let windowQuery = nameQueries.contains { $0.arguments.isEmpty || $0.arguments[0].contains("w") }
    let sessionQuery = nameQueries.contains { $0.arguments.first?.contains("s") == true }
    func bool(_ value: Bool) -> String { value ? "1" : "0" }
    func wrap(_ text: String) -> [StatusFormatFragment] { [.init(text: text, span: span)] }
    var fragments: [StatusFormatFragment]
    if names.contains("l") {
      fragments = wrap(StatusFormatSyntax.unescape(expression.raw))
    } else if names.contains("a") {
      let number =
        StatusFormatNumber.integer(text(expression.operand, context: context, depth: depth)) ?? 0
      fragments = wrap((32...126).contains(number) ? String(UnicodeScalar(number)!) : "")
    } else if names.contains("c") {
      let colour = text(expression.operand, context: context, depth: depth)
      fragments = wrap(StatusFormatPalette.rgb(colour).map { String(format: "%06x", $0) } ?? "")
    } else if let loop = ["S", "W", "P", "L"].first(where: names.contains) {
      let sorting = modifiers.last(where: { ["S", "W", "P", "L"].contains($0.name) })
      let flags =
        sorting?.name == "P"
        ? (sorting?.arguments.first?.contains("r") == true ? "r" : "")
        : sorting?.arguments.first ?? ""
      fragments = loopRecords(
        loop, flags: flags, expression: expression,
        context: context, depth: depth)
    } else if windowQuery || sessionQuery {
      let name = text(expression.operand, context: context, depth: depth)
      let scope = windowQuery ? "W" : "S"
      fragments = wrap(bool((context.scopes[scope] ?? []).contains { $0.name == name }))
    } else if names.contains("C") {
      let pattern = text(expression.operand, context: context, depth: depth)
      let flags = argument("C").first ?? ""
      let search = flags.contains("r") ? pattern : "*\(pattern)*"
      let index = context.paneLines.firstIndex {
        var line = $0
        while line.last?.isWhitespace == true { line.removeLast() }
        return StatusFormatPOSIX.matches(pattern: search, text: line, flags: flags)
      }
      fragments = wrap(index.map { String($0 + 1) } ?? "0")
    } else if names.contains("R") {
      guard let pair = pair(expression, context: context, depth: depth) else { return nil }
      let count = StatusFormatNumber.integer(pair.1) ?? 0
      guard !(1...10_000).contains(count) || pair.0.utf8.count <= 16_777_216 / count else {
        return nil
      }
      fragments = wrap((1...10_000).contains(count) ? String(repeating: pair.0, count: count) : "")
    } else if names.contains("!") || names.contains("!!") {
      let value = Self.truth(text(expression.operand, context: context, depth: depth))
      fragments = wrap(bool(names.contains("!") ? !value : value))
    } else if let operation = modifiers.last(where: { ["||", "&&"].contains($0.name) }) {
      let conjunction = operation.name == "&&"
      var value = conjunction
      for argument in expression.arguments {
        if value != conjunction { break }
        value = Self.truth(text(argument, context: context, depth: depth))
      }
      fragments = wrap(bool(value))
    } else if let operation = modifiers.last(where: {
      ["==", "!=", "<", ">", "<=", ">=", "m"].contains($0.name)
    }) {
      guard let pair = pair(expression, context: context, depth: depth) else { return nil }
      if operation.name == "m" {
        fragments = wrap(
          bool(
            StatusFormatPOSIX.matches(
              pattern: pair.0, text: pair.1, flags: operation.arguments.first ?? "")))
      } else {
        let comparison = pair.0.withCString { left in pair.1.withCString { strcmp(left, $0) } }
        let value: Bool
        switch operation.name {
        case "==": value = comparison == 0
        case "!=": value = comparison != 0
        case "<": value = comparison < 0
        case ">": value = comparison > 0
        case "<=": value = comparison <= 0
        default: value = comparison >= 0
        }
        fragments = wrap(bool(value))
      }
    } else if expression.raw.hasPrefix("?") {
      fragments = []
      var index = 0
      while index < expression.arguments.count {
        let condition = expression.arguments[index]
        if index + 1 == expression.arguments.count {
          fragments = expand(condition, context: context, depth: depth)
          break
        }
        let found: String
        if let value = lookup(condition.source, modifiers: modifiers, context: context) {
          found = value
        } else {
          let expanded = text(condition, context: context, depth: depth)
          found = expanded == condition.source ? "" : expanded
        }
        if Self.truth(found) {
          fragments = expand(expression.arguments[index + 1], context: context, depth: depth)
          break
        }
        index += 2
      }
    } else if names.contains("e") {
      guard let pair = pair(expression, context: context, depth: depth) else { return nil }
      fragments = wrap(Self.arithmetic(arguments: argument("e"), lhs: pair.0, rhs: pair.1))
    } else if expression.raw.contains("#{") {
      fragments = expand(expression.operand, context: context, depth: depth)
    } else {
      fragments = wrap(lookup(expression.raw, modifiers: modifiers, context: context) ?? "")
    }
    var value = fragments.map(\.text).joined()
    if names.contains("E") || names.contains("T") {
      let origin =
        expression.raw.hasPrefix("@") ? StatusFormatOrigin("option.\(expression.raw)") : span.origin
      var nested = context
      nested.invocation.append(span.identity)
      fragments = expand(
        StatusFormatProgram.compile(source: value, origin: origin), context: nested,
        depth: depth, time: !names.contains("E") && names.contains("T"))
      value = fragments.map(\.text).joined()
    }
    var changed = false
    for modifier in modifiers where modifier.name == "s" && modifier.arguments.count >= 2 {
      let pattern = text(
        StatusFormatProgram.compile(source: modifier.arguments[0]), context: context, depth: depth)
      let replacement = text(
        StatusFormatProgram.compile(source: modifier.arguments[1]), context: context, depth: depth)
      value = StatusFormatPOSIX.substitute(
        pattern: pattern, replacement: replacement, text: value,
        ignoreCase: modifier.arguments.count > 2 && modifier.arguments[2].contains("i"))
      changed = true
    }
    if let limit = argument("=").first.flatMap(StatusFormatNumber.integer), limit != 0,
      (-10_000...10_000).contains(limit)
    {
      let trimmed = StatusFormatCells.trim(value, width: abs(limit), tail: limit < 0)
      if trimmed != value, argument("=").count > 1 {
        let marker = argument("=")[1]
        value = limit < 0 ? marker + trimmed : trimmed + marker
      } else {
        value = trimmed
      }
      changed = true
    }
    if let width = argument("p").first.flatMap(StatusFormatNumber.integer), width != 0,
      (-10_000...10_000).contains(width)
    {
      let pad = String(
        repeating: " ", count: max(0, abs(width) - StatusFormatCells.width(value, styles: false)))
      value = width > 0 ? value + pad : pad + value
      changed = true
    }
    if names.contains("n") {
      value = String(value.utf8.count)
      changed = true
    }
    if names.contains("w") {
      value = String(StatusFormatCells.width(value))
      changed = true
    }
    return changed ? wrap(value) : fragments
  }

  mutating func text(_ program: StatusFormatProgram, context: StatusFormatContext, depth: Int)
    -> String
  {
    expand(program, context: context, depth: depth).map(\.text).joined()
  }

  mutating func pair(
    _ expression: StatusFormatProgram.Expression, context: StatusFormatContext, depth: Int
  ) -> (String, String)? {
    guard expression.arguments.count >= 2 else { return nil }
    let lhs = text(expression.arguments[0], context: context, depth: depth)
    let rhs = text(expression.arguments[1], context: context, depth: depth)
    return (lhs, rhs)
  }

  mutating func lookup(
    _ key: String, modifiers: [(name: String, arguments: [String])], context: StatusFormatContext
  ) -> String? {
    if key.hasPrefix("@") {
      dependencies.options.insert(key)
    } else {
      dependencies.values.insert(key)
    }
    let names = Set(modifiers.map(\.name))
    var value = context.options[key] ?? context.values[key]
    if value == nil, !names.contains("t") { value = context.environment[key] }
    guard var value else { return nil }
    if names.contains("t") {
      dependencies.containsTime = true
      guard let timestamp = StatusFormatNumber.integer(value), timestamp > 0 else { return nil }
      let date = Date(timeIntervalSince1970: Double(timestamp))
      let times = modifiers.filter { $0.name == "t" }
      if times.contains(where: { $0.arguments.first?.contains("p") == true }) {
        return Self.prettyTime(date, now: context.now, timeZone: context.timeZone)
      }
      if let args = times.last(where: { $0.arguments.count > 1 && $0.arguments[0].contains("f") })?
        .arguments
      {
        return Self.strftime(
          StatusFormatSyntax.unescape(args[1]), date: date, timeZone: context.timeZone)
      }
      return Self.strftime("%a %b %e %H:%M:%S %Y", date: date, timeZone: context.timeZone)
    }
    if names.contains("b") { value = Self.pathPart(value, basename: true) }
    if names.contains("d") { value = Self.pathPart(value, basename: false) }
    let quotes = modifiers.filter { $0.name == "q" }
    if quotes.contains(where: { $0.arguments.isEmpty }) {
      value = value.map { "|&;<>()$`\\\"'*?[# =%".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
    let quoteFlags = quotes.compactMap { $0.arguments.first }
    if quoteFlags.contains(where: { $0.contains("e") || $0.contains("h") }) {
      value = value.replacingOccurrences(of: "#", with: "##")
    }
    if quoteFlags.contains(where: { !$0.contains("e") && !$0.contains("h") && $0.contains("a") }) {
      value = Self.quoteArguments(value)
    }
    return value
  }

  mutating func loopRecords(
    _ loop: String, flags: String, expression: StatusFormatProgram.Expression,
    context: StatusFormatContext, depth: Int
  ) -> [StatusFormatFragment] {
    var records = context.scopes[loop] ?? []
    if !flags.contains("i"), flags.contains("n") {
      records.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    } else if !flags.contains("i"), flags.contains("t") {
      records.sort { $0.activity > $1.activity }
    } else {
      records.sort { $0.index < $1.index }
    }
    if flags.contains("r") { records.reverse() }
    var output: [StatusFormatFragment] = []
    for (index, record) in records.enumerated() {
      var child = context
      child.invocation.append("\(loop):\(record.index)")
      child.values.merge(record.values) { _, new in new }
      child.options.merge(record.options) { _, new in new }
      child.values["loop_last"] = index == records.count - 1 ? "1" : "0"
      if loop == "W" {
        child.values["window_after_active"] = index > 0 && records[index - 1].active ? "1" : "0"
        child.values["window_before_active"] =
          index + 1 < records.count && records[index + 1].active ? "1" : "0"
        for (prefix, neighbor) in [("prev", index - 1), ("next", index + 1)]
        where records.indices.contains(neighbor) {
          child.values["\(prefix)_window_index"] = String(records[neighbor].index)
          child.values["\(prefix)_window_active"] = records[neighbor].active ? "1" : "0"
          for (key, value) in records[neighbor].options where key.hasPrefix("@") {
            child.values["\(prefix)_\(key)"] = value
          }
        }
      }
      let useActive = record.active && expression.arguments.count >= 2 && ["W", "P"].contains(loop)
      let program =
        useActive ? expression.arguments[1] : (expression.arguments.first ?? expression.operand)
      output += expand(program, context: child, depth: depth)
    }
    return output
  }

  static func truth(_ value: String) -> Bool { !value.isEmpty && value != "0" }

  static func strftime(_ format: String, date: Date, timeZone: TimeZone) -> String {
    guard let seconds = time_t(exactly: date.timeIntervalSince1970.rounded(.towardZero)) else {
      return ""
    }
    let zoneOffset = timeZone.secondsFromGMT(for: date)
    let adjusted = seconds.addingReportingOverflow(zoneOffset)
    guard !adjusted.overflow else { return "" }
    var timestamp = adjusted.partialValue
    var local = tm()
    guard gmtime_r(&timestamp, &local) != nil else { return "" }
    local.tm_gmtoff = zoneOffset
    var buffer = [CChar](repeating: 0, count: 8192)
    let count = (timeZone.abbreviation(for: date) ?? "").withCString { zone in
      local.tm_zone = UnsafeMutablePointer(mutating: zone)
      return format.withCString { Darwin.strftime(&buffer, buffer.count, $0, &local) }
    }
    guard count > 0 else { return "" }
    return String(cString: buffer)
  }

  static func prettyTime(_ date: Date, now: Date, timeZone: TimeZone) -> String {
    let age = max(0, now.timeIntervalSince(date))
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    let a = calendar.dateComponents([.year, .month], from: date)
    let b = calendar.dateComponents([.year, .month], from: now)
    guard let ay = a.year, let am = a.month, let by = b.year, let bm = b.month else { return "" }
    let pattern: String
    if age < 86400 {
      pattern = "%H:%M"
    } else if age < 28 * 86400 || (a.year == b.year && a.month == b.month) {
      pattern = "%a%d"
    } else if (ay == by && am < bm) || (ay == by - 1 && am > bm) {
      pattern = "%d%b"
    } else {
      pattern = "%h%y"
    }
    return strftime(pattern, date: date, timeZone: timeZone)
  }

  static func pathPart(_ value: String, basename: Bool) -> String {
    var bytes = Array(value.utf8CString)
    return bytes.withUnsafeMutableBufferPointer { buffer in
      String(
        cString: basename ? Darwin.basename(buffer.baseAddress) : Darwin.dirname(buffer.baseAddress)
      )
    }
  }

  static func quoteArguments(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let quote: String =
      value.contains(where: { " #';${}%".contains($0) })
      ? "\""
      : value.contains(where: { " \"".contains($0) }) ? "'" : ""
    if value.count == 1, value != " ", !quote.isEmpty || value == "~" { return "\\" + value }
    var escaped = ""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 9: escaped += "\\t"
      case 10: escaped += "\\n"
      case 13: escaped += "\\r"
      case 92: escaped += "\\\\"
      case 34 where quote == "\"": escaped += "\\\""
      case 0...31, 127: escaped += String(format: "\\%03o", scalar.value)
      default: escaped += String(scalar)
      }
    }
    if value.hasPrefix("~"), quote != "'" { escaped = "\\" + escaped }
    return quote + escaped + quote
  }

  static func arithmetic(arguments: [String], lhs: String, rhs: String) -> String {
    func number(_ raw: String) -> Double? {
      if raw.isEmpty { return 0 }
      var end: UnsafeMutablePointer<CChar>?
      return raw.withCString { start in
        let value = strtod(start, &end)
        return end?.pointee == 0 ? value : nil
      }
    }
    guard !arguments.isEmpty, arguments.count <= 3, var left = number(lhs), var right = number(rhs)
    else { return "" }
    let floating = arguments.count > 1 && arguments[1].contains("f")
    guard
      let precision = arguments.count > 2
        ? StatusFormatNumber.integer(arguments[2]) : (floating ? 2 : 0),
      (-100...100).contains(precision)
    else { return "" }
    func integer(_ number: Double) -> Double {
      if number.isNaN { return 0 }
      return min(Double(Int64.max), max(Double(Int64.min), number.rounded(.towardZero)))
    }
    if !floating {
      left = integer(left)
      right = integer(right)
    }
    let result: Double
    switch arguments[0] {
    case "+": result = left + right
    case "-": result = left - right
    case "*": result = left * right
    case "/": result = left / right
    case "m", "%": result = fmod(left, right)
    case "==": result = abs(left - right) < 1e-9 ? 1 : 0
    case "!=": result = abs(left - right) > 1e-9 ? 1 : 0
    case "<": result = left < right ? 1 : 0
    case ">": result = left > right ? 1 : 0
    case "<=": result = left <= right ? 1 : 0
    case ">=": result = left >= right ? 1 : 0
    default: return ""
    }
    return String(
      format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), precision,
      floating ? result : integer(result))
  }
}

enum StatusFormatPOSIX {
  static func matches(pattern: String, text: String, flags: String) -> Bool {
    let previous = uselocale(StatusFormatCells.unicodeLocale)
    defer { uselocale(previous) }
    if flags.contains("r") {
      guard
        let regex = StatusFormatRegexCache.shared.regex(
          pattern: pattern, flags: REG_EXTENDED | (flags.contains("i") ? REG_ICASE : 0))
      else { return false }
      return regexec(regex.pointer, text, 0, nil, 0) == 0
    }
    return fnmatch(pattern, text, flags.contains("i") ? FNM_CASEFOLD : 0) == 0
  }

  static func substitute(pattern: String, replacement: String, text: String, ignoreCase: Bool)
    -> String
  {
    guard !pattern.isEmpty, !text.isEmpty else { return text }
    let previous = uselocale(StatusFormatCells.unicodeLocale)
    defer { uselocale(previous) }
    guard
      let regex = StatusFormatRegexCache.shared.regex(
        pattern: pattern, flags: REG_EXTENDED | (ignoreCase ? REG_ICASE : 0))
    else { return text }
    let bytes = Array(text.utf8CString)
    let replacementBytes = Array(replacement.utf8)
    var offset = 0
    var last = 0
    var previousEmpty = false
    var output: [UInt8] = []
    while offset < bytes.count {
      var matches = [regmatch_t](repeating: regmatch_t(), count: 10)
      let found = bytes.withUnsafeBufferPointer { buffer in
        regexec(regex.pointer, buffer.baseAddress! + offset, matches.count, &matches, 0)
      }
      guard found == 0, matches[0].rm_so >= 0 else {
        output += bytes[offset..<(bytes.count - 1)].map { UInt8(bitPattern: $0) }
        break
      }
      let start = offset + Int(matches[0].rm_so)
      let end = offset + Int(matches[0].rm_eo)
      output += bytes[last..<start].map { UInt8(bitPattern: $0) }
      if !previousEmpty, start == last, start == end {
        last = end
        offset = end + 1
        previousEmpty = true
        if pattern.hasPrefix("^") {
          output += bytes[offset..<(bytes.count - 1)].map { UInt8(bitPattern: $0) }
          break
        }
        continue
      }
      var index = 0
      while index < replacementBytes.count {
        if replacementBytes[index] == 92, index + 1 < replacementBytes.count {
          index += 1
          let next = replacementBytes[index]
          if (48...57).contains(next) {
            let match = matches[Int(next - 48)]
            if match.rm_so >= 0, match.rm_so != match.rm_eo {
              output += bytes[(offset + Int(match.rm_so))..<(offset + Int(match.rm_eo))].map {
                UInt8(bitPattern: $0)
              }
            } else {
              output.append(next)
            }
          } else {
            output.append(next)
          }
        } else {
          output.append(replacementBytes[index])
        }
        index += 1
      }
      last = end
      offset = end
      previousEmpty = false
      if pattern.hasPrefix("^") {
        output += bytes[offset..<(bytes.count - 1)].map { UInt8(bitPattern: $0) }
        break
      }
    }
    return String(decoding: output, as: UTF8.self)
  }
}

enum StatusFormatPalette {
  static let ansi: [UInt32] = [
    0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
    0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
  ]
  static func rgb(index: Int) -> UInt32? {
    guard (0...255).contains(index) else { return nil }
    if index < 16 { return ansi[index] }
    if index >= 232 {
      let grey = UInt32(8 + (index - 232) * 10)
      return grey * 0x010101
    }
    let cube = index - 16
    let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
    return (steps[cube / 36] << 16) | (steps[(cube / 6) % 6] << 8) | steps[cube % 6]
  }
  static func index(_ raw: String) -> Int? {
    let word = raw.lowercased()
    for prefix in ["colour", "color"] where word.hasPrefix(prefix) {
      guard let value = StatusFormatNumber.integer(String(word.dropFirst(prefix.count))),
        (0...255).contains(value)
      else {
        return nil
      }
      return value
    }
    let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    if let number = Int(word), String(number) == word {
      if (0...7).contains(number) { return number }
      if (90...97).contains(number) { return number - 90 + 8 }
    }
    if let value = names.firstIndex(of: word) { return value }
    if word.hasPrefix("bright"), let value = names.firstIndex(of: String(word.dropFirst(6))) {
      return value + 8
    }
    return nil
  }
  static func rgb(_ raw: String) -> UInt32? {
    if raw.first == "#", raw.utf8.count == 7 { return UInt32(raw.dropFirst(), radix: 16) }
    if let index = index(raw) { return rgb(index: index) }
    let word = raw.lowercased()
    if word.hasPrefix("grey") || word.hasPrefix("gray") {
      if word.count == 4 { return 0xbebebe }
      guard let level = StatusFormatNumber.integer(String(word.dropFirst(4))),
        (0...100).contains(level)
      else { return nil }
      return UInt32((Double(level) * 2.55).rounded()) * 0x010101
    }
    return StatusFormatNamedColours.values[word]
  }
}

enum StatusFormatCells {
  struct Piece {
    var raw: String
    var text: String
    var width: Int
    var style: Bool
    var bytes: Range<Int>
  }
  static let unicodeLocale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)

  static func scalarWidth(_ scalar: UnicodeScalar) -> Int {
    guard scalar.value > 31, scalar.value != 127 else { return 0 }
    if let width = StatusFormatUnicodeWidths.overrides[scalar.value] { return width }
    return StatusFormatUnicodeData.width(scalar.value)
  }

  static func pieces(_ raw: String, styles: Bool = true) -> [Piece] {
    let bytes = Array(raw.utf8)
    var result: [Piece] = []
    var index = 0
    while index < bytes.count {
      if styles, bytes[index] == 35 {
        let start = index
        while index < bytes.count, bytes[index] == 35 { index += 1 }
        let count = index - start
        let marker = index < bytes.count && bytes[index] == 91
        let hashes = marker ? count / 2 : (count + 1) / 2
        if hashes > 0 {
          let rawHashes = marker && count % 2 == 1 ? count - 1 : count
          result.append(
            Piece(
              raw: String(repeating: "#", count: rawHashes),
              text: String(repeating: "#", count: hashes), width: hashes, style: false,
              bytes: start..<(start + rawHashes)))
        }
        if marker, count % 2 == 1 {
          guard let end = StatusFormatSyntax.find(bytes, from: index + 1, delimiters: [93]) else {
            break
          }
          result.append(
            Piece(
              raw: String(decoding: bytes[(index - 1)...end], as: UTF8.self), text: "", width: 0,
              style: true, bytes: (index - 1)..<(end + 1)))
          index = end + 1
        }
        continue
      }
      let start = index
      let first = bytes[index]
      let length = first < 128 ? 1 : first < 224 ? 2 : first < 240 ? 3 : 4
      index = min(bytes.count, index + length)
      let text = String(decoding: bytes[start..<index], as: UTF8.self)
      let width = text.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
      result.append(Piece(raw: text, text: text, width: width, style: false, bytes: start..<index))
    }
    return result
  }

  static func width(_ raw: String, styles: Bool = true) -> Int {
    let values = pieces(raw, styles: styles)
    if styles, (values.last?.bytes.upperBound ?? 0) < raw.utf8.count { return 0 }
    return values.reduce(0) { $0 + $1.width }
  }

  static func trim(_ raw: String, width limit: Int, tail: Bool) -> String {
    let pieces = pieces(raw)
    let total = pieces.reduce(0) { $0 + $1.width }
    if tail, total <= limit { return raw }
    let skip = max(0, total - limit)
    var width = 0
    var output = ""
    for piece in pieces {
      if !tail, width >= limit { break }
      if piece.style {
        output += piece.raw
        continue
      }
      if piece.text.unicodeScalars.allSatisfy({ $0.value < 32 || $0.value == 127 }) { continue }
      if !piece.text.isEmpty, piece.text.allSatisfy({ $0 == "#" }) {
        let count =
          tail
          ? min(piece.width, max(0, width + piece.width - skip)) : min(piece.width, limit - width)
        if count > 0 {
          output += String(repeating: "#", count: piece.raw.count == 1 ? 1 : count * 2)
        }
        width += piece.width
        continue
      }
      if tail ? width >= skip : width + piece.width <= limit { output += piece.raw }
      width += piece.width
    }
    return output
  }
}
