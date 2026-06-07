import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

enum FlashMode: Equatable {
  case insert
  case normal
}

struct NormalModeTransition: Equatable {
  var pending: String
  var action: MappingAction?
  var repeatCount: Int
  var passThrough: Bool

  var command: URLCommand? { action?.command }

  static func command(_ command: URLCommand, repeatCount: Int = 1) -> NormalModeTransition {
    action(.flashCommand(command), repeatCount: repeatCount)
  }

  static func action(_ action: MappingAction, repeatCount: Int = 1) -> NormalModeTransition {
    NormalModeTransition(
      pending: "", action: action, repeatCount: max(1, repeatCount), passThrough: false)
  }

  static func pending(_ pending: String) -> NormalModeTransition {
    NormalModeTransition(pending: pending, action: nil, repeatCount: 1, passThrough: false)
  }

  static let consume = NormalModeTransition(
    pending: "", action: nil, repeatCount: 1, passThrough: false)
  static let passThrough = NormalModeTransition(
    pending: "", action: nil, repeatCount: 1, passThrough: true)
}

struct PendingNormalModeCommand: Equatable {
  var action: MappingAction
  var repeatCount: Int

  var command: URLCommand? { action.command }
}

enum NormalModeInterpreter {
  private static let maxRepeatCount = 999
  static let sequenceTimeoutMs = 1_000

  private struct PendingState {
    var count: Int?
    var prefix: String

    var repeatCount: Int { count ?? 1 }

    var encoded: String {
      "\(count.map(String.init) ?? "")\(prefix)"
    }

    func appendingPrefix(_ next: String) -> String {
      PendingState(count: count, prefix: next).encoded
    }
  }

  static func interpret(
    pending: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  ) -> NormalModeTransition {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    if keyCode == 53 { return .consume }

    if independent.contains(.command) || independent.contains(.option) {
      return .consume
    }

    if let mapping = modifiedMapping(
      keyCode: keyCode,
      modifierFlags: independent,
      mappings: mappings)
    {
      return .action(mapping.action)
    }

    let hasControl = independent.contains(.control)
    let ignoredChar = firstCharacter(charactersIgnoringModifiers)?.lowercased().first
    let actualChar = firstCharacter(characters)
    let state = pendingState(pending)

    if state.prefix.isEmpty, let digit = digitValue(ignoredChar) {
      if state.count == nil, digit == 0 {
        return .consume
      }
      let next = min(((state.count ?? 0) * 10) + digit, maxRepeatCount)
      return .pending(PendingState(count: next, prefix: "").encoded)
    }

    let keys = mappingKeys(
      keyCode: keyCode,
      hasControl: hasControl,
      hasShift: independent.contains(.shift),
      ignoredChar: ignoredChar,
      actualChar: actualChar)
    guard !keys.isEmpty else {
      return .consume
    }
    for key in keys {
      let sequence = state.prefix + key
      let exact = mappings.first(where: { $0.key == sequence })
      let hasLonger = mappings.contains { $0.key != sequence && $0.key.hasPrefix(sequence) }
      if let mapping = exact, !hasLonger {
        return .action(mapping.action, repeatCount: state.repeatCount)
      }
      if exact != nil || hasLonger {
        return .pending(state.appendingPrefix(sequence))
      }
    }
    return .consume
  }

  static func firstCharacter(_ value: String?) -> Character? {
    guard let value, let first = value.first else { return nil }
    return first
  }

  static func pendingCommand(
    pending: String,
    mappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  ) -> PendingNormalModeCommand? {
    let state = pendingState(pending)
    guard !state.prefix.isEmpty,
      let mapping = mappings.first(where: { $0.key == state.prefix })
    else { return nil }
    return PendingNormalModeCommand(action: mapping.action, repeatCount: state.repeatCount)
  }

  static func pendingSequenceTimedOut(
    pending: String,
    lastInputAt: Date?,
    now: Date = Date(),
    timeoutMs: Int = sequenceTimeoutMs
  ) -> Bool {
    guard !pending.isEmpty, let lastInputAt else { return false }
    return now.timeIntervalSince(lastInputAt) * 1_000 > Double(timeoutMs)
  }

  private static func pendingState(_ pending: String) -> PendingState {
    let digitPrefix = pending.prefix { ch in
      guard let value = ch.wholeNumberValue else { return false }
      return value >= 0 && value <= 9
    }
    let prefix = String(pending.dropFirst(digitPrefix.count))
    let count = digitPrefix.isEmpty ? nil : Int(digitPrefix).map { min($0, maxRepeatCount) }
    return PendingState(count: count, prefix: prefix)
  }

  private static func digitValue(_ char: Character?) -> Int? {
    guard let char, let value = char.wholeNumberValue, value >= 0, value <= 9 else {
      return nil
    }
    return value
  }

  private static func modifiedMapping(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    mappings: [ModeMapping]
  ) -> ModeMapping? {
    let carbonModifiers = Self.carbonModifiers(from: modifierFlags)
    guard carbonModifiers != 0 else { return nil }
    return mappings.first { mapping in
      guard mapping.key.contains("+"),
        let parsed = HotkeySyntax.parse(hotkey: mapping.key)
      else { return false }
      return parsed.modifiers == carbonModifiers
        && parsed.virtualKey == UInt32(keyCode)
    }
  }

  private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    let independent = flags.intersection(.deviceIndependentFlagsMask)
    var out: UInt32 = 0
    if independent.contains(.command) { out |= UInt32(cmdKey) }
    if independent.contains(.shift) { out |= UInt32(shiftKey) }
    if independent.contains(.control) { out |= UInt32(controlKey) }
    if independent.contains(.option) { out |= UInt32(optionKey) }
    return out
  }

  private static func mappingKeys(
    keyCode: UInt16,
    hasControl: Bool,
    hasShift: Bool,
    ignoredChar: Character?,
    actualChar: Character?
  ) -> [String] {
    if hasControl {
      guard let ignoredChar else { return [] }
      return ["ctrl-\(ignoredChar)"]
    }
    var keys: [String] = []
    if let actualChar {
      keys.append(String(actualChar))
    }
    if hasShift, ignoredChar == "/", !keys.contains("?") {
      keys.append("?")
    }
    if keys.isEmpty, let ignoredChar {
      keys.append(String(ignoredChar))
    }
    switch Int(keyCode) {
    case kVK_Space:
      if !keys.contains("space") { keys.append("space") }
    case kVK_Tab:
      if !keys.contains("tab") { keys.append("tab") }
    case kVK_ForwardDelete:
      for alias in ["delete_forward", "forward_delete"] where !keys.contains(alias) {
        keys.append(alias)
      }
    default:
      break
    }
    return keys
  }
}

enum NormalModeDispatcher {
  static let scrollStepPixels: Int32 = 60

  private struct MappingRow {
    var scope: String
    var key: String
    var action: String
  }

  enum ScrollKind: Hashable {
    case left
    case right
    case up
    case down
    case halfPageUp
    case halfPageDown
    case top
    case bottom
  }

  static func helpTopic(config: Config, showModes: Bool) -> HelpTopic {
    HelpTopic(
      name: "normal-mode",
      title: "Normal Mode",
      summary: "Normal-mode mappings, counts, command line, and mouse targeting.",
      body: """
        # Normal Mode

        Normal mode captures keyboard input through the Flash overlay panel. It
        does not install arbitrary global key capture; only configured modified
        mappings use Carbon hotkeys.

        ## Core Motion

        - `h` / `j` / `k` / `l` scroll left, down, up, and right.
        - `ctrl-d` / `ctrl-u` scroll by half a page.
        - `gg` scrolls to the top.
        - `G` scrolls to the bottom.
        - Counts prefix actions: `10u`, `2gT`, and similar forms repeat the action.

        ## Tabs And Windows

        - `gt` / `gT` moves to the next or previous tab.
        - `g1` ... `g9` select a numbered tab when the focused source supports it.
        - In browsers this maps to tab selection.
        - `n` opens a new window with Cmd-N.
        - `t` opens a new tab and then enters insert mode.

        ## Mouse Targets

        - `f` targets clickable elements discovered from the focused app.
        - `rf` right-clicks a discovered target.
        - `df` double-clicks a discovered target.
        - `mf` moves the cursor to a discovered target.
        - `F` starts mouse grid mode for a precise screen position.
        - `rF` / `dF` / `mF` right-click, double-click, or move with mouse grid mode.

        ## Command Line

        `:` opens command-line mode. Use `:help` for the topic index,
        `:help plugins` for plugin docs, and `:mappings` for the resolved
        mapping table. `:open <query>` and `:flashlight <query>` search source
        candidates.

        ## Active Mappings

        ```text
        \(helpText(config: config, showModes: showModes))
        ```
        """)
  }

  static func helpText(config: Config, showModes: Bool) -> String {
    let normal = groupedKeys(config.mode.mappings(for: .normal))
    let insert = groupedKeys(config.mode.mappings(for: .insert))
    let commands = Array(Set(normal.keys).union(insert.keys))
      .sorted { lhs, rhs in
        lhs.diagnosticDescription.localizedCaseInsensitiveCompare(rhs.diagnosticDescription)
          == .orderedAscending
      }
    let rows = commands.map { command -> (String, String, String) in
      (
        command.diagnosticDescription,
        joined(normal[command] ?? []),
        joined(insert[command] ?? [])
      )
    }

    let actionWidth = max("ACTION".count, rows.map(\.0.count).max() ?? 0)
    let normalWidth = max("NORMAL".count, rows.map(\.1.count).max() ?? 0)
    let commandLineVisible =
      !(normal[.flashCommand(.commandMode)] ?? []).isEmpty
      || !(insert[.flashCommand(.commandMode)] ?? []).isEmpty
    var lines: [String] = []
    if !showModes {
      let mappingWidth = max("MAPPING".count, rows.map(\.1.count).max() ?? 0)
      lines.append(
        padded("ACTION", width: actionWidth)
          + "  " + padded("MAPPING", width: mappingWidth))
      for row in rows where !row.1.isEmpty {
        lines.append(
          padded(row.0, width: actionWidth)
            + "  " + padded(row.1, width: mappingWidth))
      }
      lines.append("")
      lines.append("Counts: N{mapping}, e.g. 10u or 3gt")
      appendCommandLineHelp(to: &lines, visible: commandLineVisible)
      return lines.joined(separator: "\n")
    }

    if showModes {
      lines.append("MAPPINGS")
      lines.append("")
    }
    lines.append(
      padded("ACTION", width: actionWidth)
        + "  " + padded("NORMAL", width: normalWidth)
        + "  INSERT")
    for row in rows where !row.1.isEmpty || !row.2.isEmpty || showModes {
      lines.append(
        padded(row.0, width: actionWidth)
          + "  " + padded(row.1, width: normalWidth)
          + "  " + row.2)
    }
    lines.append("")
    lines.append("Counts: N{mapping}, e.g. 10u or 3gt")
    appendCommandLineHelp(to: &lines, visible: commandLineVisible)
    return lines.joined(separator: "\n")
  }

  static func mappingsText(config: Config) -> String {
    let rows =
      mappingRows(scope: "all", mappings: config.mode.all)
      + mappingRows(scope: "normal", mappings: config.mode.normal)
      + mappingRows(scope: "insert", mappings: config.mode.insert)
    let scopeWidth = max("SCOPE".count, rows.map(\.scope.count).max() ?? 0)
    let keyWidth = max("KEY".count, rows.map(\.key.count).max() ?? 0)
    var lines = [
      "# Mappings",
      "",
      "Normal leader: `\(config.mode.normalLeader ?? "<unset>")`",
      "",
    ]
    guard !rows.isEmpty else {
      lines.append("No mappings are configured.")
      return lines.joined(separator: "\n")
    }
    lines.append("```text")
    lines.append(
      padded("SCOPE", width: scopeWidth)
        + "  " + padded("KEY", width: keyWidth)
        + "  ACTION")
    for row in rows {
      lines.append(
        padded(row.scope, width: scopeWidth)
          + "  " + padded(row.key, width: keyWidth)
          + "  " + row.action)
    }
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  private static func mappingRows(scope: String, mappings: [ModeMapping]) -> [MappingRow] {
    mappings.map { mapping in
      MappingRow(
        scope: scope,
        key: mapping.key,
        action: mapping.action.diagnosticDescription
      )
    }
  }

  private static func appendCommandLineHelp(to lines: inout [String], visible: Bool) {
    guard visible else { return }
    lines.append("")
    lines.append("COMMANDS")
    for line in commandLineHelpLines {
      lines.append(line)
    }
    lines.append("Command mode exits with Esc, ctrl-c, or empty backspace.")
  }

  private static var commandLineHelpLines: [String] {
    var lines = commandLineSpecs.map { $0.helpLine }
    lines.append(":help [topic]")
    lines.append(":open <query>")
    lines.append(":flashlight <query>")
    return lines
  }

  private static func groupedKeys(_ mappings: [ModeMapping]) -> [MappingAction: [String]] {
    var grouped: [MappingAction: [String]] = [:]
    for mapping in mappings {
      grouped[mapping.action, default: []].append(mapping.key)
    }
    return grouped
  }

  private static func joined(_ keys: [String]) -> String {
    keys.joined(separator: ", ")
  }

  private static func padded(_ value: String, width: Int) -> String {
    value + String(repeating: " ", count: max(0, width - value.count))
  }

  enum CommandLineCommand: Equatable {
    case quit(force: Bool)
    case save
    case saveAndQuit(force: Bool)
    case print
    case open
    case newWindow
    case newTab
    case close
    case find
    case undo
    case redo
    case copy
    case cut
    case paste
    case copyAll
    case plugins
    case mappings
    case help(topic: String?)
  }

  static func commandLineCommand(_ raw: String) -> CommandLineCommand? {
    guard let parsed = parseCommandLine(raw) else { return nil }
    let matches = commandLineSpecs.compactMap { spec in
      spec.command(for: parsed.body, bang: parsed.bang)
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  static func commandLineOpenAppQuery(_ raw: String) -> String? {
    commandLineQuery(raw, name: "open", acceptsBareCommand: false)
  }

  static func commandLineCandidateQuery(_ raw: String) -> String? {
    if let query = commandLineOpenAppQuery(raw) {
      return query
    }
    return commandLineQuery(raw, name: "flashlight", acceptsBareCommand: true)
  }

  static func commandLineHelpTopic(_ raw: String) -> String?? {
    var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    body.removeLeadingWhitespace()
    guard !body.isEmpty else { return nil }
    let lower = body.lowercased()
    guard lower == "h" || lower == "help" || lower.hasPrefix("h ") || lower.hasPrefix("help ")
    else { return nil }
    let nameLength = lower.hasPrefix("help") ? 4 : 1
    let nameEnd = body.index(body.startIndex, offsetBy: nameLength)
    if body.count == nameLength {
      return .some(nil)
    }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    let topic = String(body[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return .some(topic.isEmpty ? nil : topic)
  }

  private static func commandLineQuery(
    _ raw: String,
    name: String,
    acceptsBareCommand: Bool
  ) -> String? {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
      body.removeLeadingWhitespace()
    }

    if acceptsBareCommand, body.lowercased() == name {
      return ""
    }
    guard body.count > name.count else { return nil }
    let nameEnd = body.index(body.startIndex, offsetBy: name.count)
    guard body[..<nameEnd].lowercased() == name else { return nil }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    let query = String(body[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return query
  }

  private enum BangPolicy {
    case rejected
    case accepted
  }

  private struct CommandLineName: ExpressibleByStringLiteral {
    var documented: String
    var full: String
    var minimumLength: Int

    init(stringLiteral value: String) {
      self.init(value)
    }

    init(_ documented: String) {
      self.documented = documented
      var full = ""
      var required = 0
      var optional = false
      for ch in documented {
        switch ch {
        case "[":
          optional = true
        case "]":
          optional = false
        default:
          full.append(ch)
          if !optional { required += 1 }
        }
      }
      self.full = full
      self.minimumLength = required
    }

    func matches(_ body: String) -> Bool {
      body.count >= minimumLength && body.count <= full.count && full.hasPrefix(body)
    }
  }

  private struct CommandLineSpec {
    var names: [CommandLineName]
    var bangPolicy: BangPolicy
    var build: (Bool) -> CommandLineCommand

    var helpLine: String {
      let base = names.map { ":\($0.documented)" }.joined(separator: " / ")
      guard bangPolicy == .accepted else { return base }
      return "\(base) / \(names.map { ":\($0.documented)!" }.joined(separator: " / "))"
    }

    func command(for body: String, bang: Bool) -> CommandLineCommand? {
      if bang, bangPolicy == .rejected { return nil }
      guard names.contains(where: { $0.matches(body) }) else { return nil }
      return build(bang)
    }
  }

  private static let commandLineSpecs: [CommandLineSpec] = [
    CommandLineSpec(names: ["q[uit]"], bangPolicy: .accepted) { .quit(force: $0) },
    CommandLineSpec(names: ["w[rite]"], bangPolicy: .accepted) { _ in .save },
    CommandLineSpec(names: ["wq", "x[it]"], bangPolicy: .accepted) {
      .saveAndQuit(force: $0)
    },
    CommandLineSpec(names: ["p[rint]"], bangPolicy: .rejected) { _ in .print },
    CommandLineSpec(names: ["e[dit]", "open"], bangPolicy: .rejected) { _ in .open },
    CommandLineSpec(names: ["new"], bangPolicy: .rejected) { _ in .newWindow },
    CommandLineSpec(names: ["tabnew", "tabedit", "tabe"], bangPolicy: .rejected) {
      _ in .newTab
    },
    CommandLineSpec(names: ["bd[elete]", "cl[ose]"], bangPolicy: .rejected) {
      _ in .close
    },
    CommandLineSpec(names: ["find", "grep", "vimgrep"], bangPolicy: .rejected) { _ in .find },
    CommandLineSpec(names: ["u[ndo]"], bangPolicy: .rejected) { _ in .undo },
    CommandLineSpec(names: ["red[o]"], bangPolicy: .rejected) { _ in .redo },
    CommandLineSpec(names: ["y[ank]", "copy"], bangPolicy: .rejected) { _ in .copy },
    CommandLineSpec(names: ["d[elete]", "cut"], bangPolicy: .rejected) { _ in .cut },
    CommandLineSpec(names: ["pu[t]", "paste"], bangPolicy: .rejected) { _ in .paste },
    CommandLineSpec(names: ["%y[ank]"], bangPolicy: .rejected) { _ in .copyAll },
    CommandLineSpec(names: ["plugins"], bangPolicy: .rejected) { _ in .plugins },
    CommandLineSpec(names: ["map[pings]"], bangPolicy: .rejected) { _ in .mappings },
  ]

  static func pluginCommandLineInvocation(_ raw: String) -> (
    command: String, name: String, args: [String], raw: String
  )? {
    var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    let parts = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard parts.count >= 2 else { return nil }
    return (
      command: parts[0],
      name: parts[1],
      args: Array(parts.dropFirst(2)),
      raw: raw
    )
  }

  private static func parseCommandLine(_ raw: String) -> (body: String, bang: Bool)? {
    var command = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if command.hasPrefix(":") {
      command.removeFirst()
    }
    guard !command.isEmpty else { return nil }

    let bangCount = command.reduce(0) { $0 + ($1 == "!" ? 1 : 0) }
    guard bangCount <= 1 else { return nil }
    let bang = command.last == "!"
    if bang {
      command.removeLast()
      guard !command.isEmpty else { return nil }
    } else if bangCount > 0 {
      return nil
    }
    return (body: command, bang: bang)
  }

  static func fuzzyScore(query rawQuery: String, candidate rawCandidate: String) -> Int? {
    let query = normalizedSearchText(rawQuery)
    let candidate = normalizedSearchText(rawCandidate)
    return fuzzyScore(normalizedQuery: query, normalizedCandidate: candidate)
  }

  static func fuzzyScore(normalizedQuery query: String, normalizedCandidate candidate: String)
    -> Int?
  {
    if query.isEmpty { return 0 }
    guard !candidate.isEmpty else { return nil }

    var best: Int?
    if let exact = exactContainmentScore(query: query, candidate: candidate) {
      best = max(best ?? exact, exact)
    }
    if let ordered = orderedMatchScore(query: query, candidate: candidate) {
      best = max(best ?? ordered, ordered)
    }

    let queryCompact = query.filter { !$0.isWhitespace }
    let compactCandidate = candidate.filter { !$0.isWhitespace }
    for segment in searchSegments(candidate: candidate) + [compactCandidate] {
      guard let score = typoScore(query: queryCompact, segment: segment) else { continue }
      best = max(best ?? score, score)
    }
    return best
  }

  static func fuzzyHighlightRanges(query rawQuery: String, candidate rawCandidate: String)
    -> [Range<Int>]
  {
    let query = normalizedSearchText(rawQuery).filter { !$0.isWhitespace }
    guard !query.isEmpty, !rawCandidate.isEmpty else { return [] }

    let indexedChars = rawCandidate.enumerated().compactMap { offset, ch -> (Int, Character)? in
      guard let scalar = String(ch).lowercased().unicodeScalars.first,
        isSearchableScalar(scalar)
      else { return nil }
      return (offset, Character(String(scalar)))
    }
    guard !indexedChars.isEmpty else { return [] }

    let compactCandidate = String(indexedChars.map(\.1))
    if let range = compactCandidate.range(of: query) {
      let start = compactCandidate.distance(from: compactCandidate.startIndex, to: range.lowerBound)
      let end = compactCandidate.distance(from: compactCandidate.startIndex, to: range.upperBound)
      return mergeCharacterOffsets(indexedChars[start..<end].map(\.0))
    }

    if let ordered = orderedHighlightOffsets(query: query, indexedChars: indexedChars) {
      return mergeCharacterOffsets(ordered)
    }

    return mergeCharacterOffsets(lcsHighlightOffsets(query: query, indexedChars: indexedChars))
  }

  static func normalizedSearchText(_ value: String) -> String {
    var out = ""
    var previousWasSpace = false
    for scalar in value.lowercased().unicodeScalars {
      if isSearchableScalar(scalar) {
        out.unicodeScalars.append(scalar)
        previousWasSpace = false
      } else if !previousWasSpace {
        out.append(" ")
        previousWasSpace = true
      }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func orderedHighlightOffsets(
    query: String,
    indexedChars: [(Int, Character)]
  ) -> [Int]? {
    var offsets: [Int] = []
    var queryIndex = query.startIndex
    for (offset, ch) in indexedChars where queryIndex < query.endIndex {
      if ch == query[queryIndex] {
        offsets.append(offset)
        queryIndex = query.index(after: queryIndex)
      }
    }
    return queryIndex == query.endIndex ? offsets : nil
  }

  private static func lcsHighlightOffsets(
    query: String,
    indexedChars: [(Int, Character)]
  ) -> [Int] {
    let q = Array(query)
    let c = indexedChars.map(\.1)
    guard !q.isEmpty, !c.isEmpty else { return [] }

    var table = Array(
      repeating: Array(repeating: 0, count: c.count + 1),
      count: q.count + 1)
    for qi in stride(from: q.count - 1, through: 0, by: -1) {
      for ci in stride(from: c.count - 1, through: 0, by: -1) {
        if q[qi] == c[ci] {
          table[qi][ci] = table[qi + 1][ci + 1] + 1
        } else {
          table[qi][ci] = max(table[qi + 1][ci], table[qi][ci + 1])
        }
      }
    }

    var offsets: [Int] = []
    var qi = 0
    var ci = 0
    while qi < q.count, ci < c.count {
      if q[qi] == c[ci] {
        offsets.append(indexedChars[ci].0)
        qi += 1
        ci += 1
      } else if table[qi + 1][ci] >= table[qi][ci + 1] {
        qi += 1
      } else {
        ci += 1
      }
    }
    return offsets
  }

  private static func mergeCharacterOffsets(_ offsets: [Int]) -> [Range<Int>] {
    let sorted = offsets.sorted()
    guard var start = sorted.first else { return [] }
    var previous = start
    var ranges: [Range<Int>] = []
    for offset in sorted.dropFirst() {
      if offset == previous + 1 {
        previous = offset
      } else {
        ranges.append(start..<previous + 1)
        start = offset
        previous = offset
      }
    }
    ranges.append(start..<previous + 1)
    return ranges
  }

  private static func exactContainmentScore(query: String, candidate: String) -> Int? {
    guard let range = candidate.range(of: query) else { return nil }
    let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    return 220 - min(80, offset * 3) - max(0, candidate.count - query.count) / 6
  }

  private static func orderedMatchScore(query: String, candidate: String) -> Int? {
    let query = Array(query.filter { !$0.isWhitespace })
    let candidate = Array(candidate)
    guard !query.isEmpty else { return 0 }
    var queryIndex = 0
    var score = 0
    var previousMatchIndex: Int?
    for (candidateIndex, ch) in candidate.enumerated() {
      guard queryIndex < query.count else { break }
      guard ch == query[queryIndex] else { continue }
      score += 10
      if candidateIndex == 0 {
        score += 8
      } else {
        let previous = candidate[candidateIndex - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "#" {
          score += 6
        }
      }
      if let previousMatchIndex {
        score += candidateIndex == previousMatchIndex + 1 ? 8 : -min(6, candidateIndex - previousMatchIndex - 1)
      }
      previousMatchIndex = candidateIndex
      queryIndex += 1
    }
    guard queryIndex == query.count else { return nil }
    return 140 + score - max(0, candidate.count - query.count) / 4
  }

  private static func isSearchableScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar.value == 35
  }

  private static func searchSegments(candidate: String) -> [String] {
    candidate
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  private static func typoScore(query: String, segment: String) -> Int? {
    guard !query.isEmpty, !segment.isEmpty else { return nil }
    let maxEdits = allowedTypoCount(query.count)
    guard query.count <= segment.count + maxEdits else { return nil }
    let prefixLength = min(segment.count, query.count + maxEdits)
    let prefix = String(segment.prefix(prefixLength))
    guard let distance = boundedEditDistance(query, prefix, maxDistance: maxEdits) else {
      return nil
    }
    return 105 - distance * 24 - abs(prefix.count - query.count) * 3
      - max(0, segment.count - query.count) / 4
  }

  private static func allowedTypoCount(_ length: Int) -> Int {
    if length <= 2 { return 0 }
    if length <= 5 { return 1 }
    return 2
  }

  private static func boundedEditDistance(
    _ lhs: String,
    _ rhs: String,
    maxDistance: Int
  ) -> Int? {
    let a = Array(lhs)
    let b = Array(rhs)
    if abs(a.count - b.count) > maxDistance { return nil }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      var rowMin = current[0]
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        let insertion = current[j - 1] + 1
        let deletion = previous[j] + 1
        current[j] = min(substitution, insertion, deletion)
        rowMin = min(rowMin, current[j])
      }
      if rowMin > maxDistance { return nil }
      swap(&previous, &current)
    }
    return previous[b.count] <= maxDistance ? previous[b.count] : nil
  }

  @discardableResult
  static func scroll(_ kind: ScrollKind, pid: pid_t, windowFrame: CGRect? = nil) -> Bool {
    let pageTarget = windowFrame.flatMap { pageScrollTarget(pid: pid, visibleIn: $0) }
    if let pageTarget {
      if scrollPageInstantly(kind, element: pageTarget.element) {
        FlashLog.debug("[normal_mode] scroll method=page_ax_edge kind=\(kind)")
        return true
      }
      if synthesizeScrollWheel(kind, windowFrame: windowFrame, pageFrame: pageTarget.frame) {
        FlashLog.debug("[normal_mode] scroll method=page_wheel kind=\(kind)")
        return true
      }
    }

    switch kind {
    case .top, .bottom:
      if scrollInstantly(kind, pid: pid) {
        FlashLog.debug("[normal_mode] scroll method=ax_value kind=\(kind)")
        return true
      }
    default:
      if synthesizeScrollWheel(kind, windowFrame: windowFrame, pageFrame: nil) {
        FlashLog.debug("[normal_mode] scroll method=wheel kind=\(kind)")
        return true
      }
      if scrollInstantly(kind, pid: pid) {
        FlashLog.debug("[normal_mode] scroll method=ax_value kind=\(kind)")
        return true
      }
    }

    if sendScrollKey(kind, pid: pid) { return true }
    if performScrollAction(kind, pid: pid) { return true }
    FlashLog.debug("[normal_mode] no instant AX scroller for \(kind)")
    return false
  }

  static func adjustedScrollValue(
    current: Double,
    lower: Double,
    upper: Double,
    deltaFraction: Double
  ) -> Double {
    guard upper > lower else { return current }
    let adjusted = current + (upper - lower) * deltaFraction
    return min(max(adjusted, lower), upper)
  }

  static func edgeScrollValue(lower: Double, upper: Double, edge: ScrollEdge) -> Double {
    switch edge {
    case .minimum: return lower
    case .maximum: return upper
    }
  }

  private enum Axis: Equatable {
    case horizontal
    case vertical
  }

  enum ScrollEdge {
    case minimum
    case maximum
  }

  private struct ScrollIntent {
    var axis: Axis
    var deltaFraction: Double?
    var edge: ScrollEdge?
  }

  private struct PageScrollTarget {
    var element: AXUIElement
    var frame: CGRect
  }

  private static func scrollInstantly(_ kind: ScrollKind, pid: pid_t) -> Bool {
    guard let intent = intent(for: kind),
      let bar = scrollBar(axis: intent.axis, pid: pid),
      let current = numberAttribute(bar, kAXValueAttribute as String),
      let lower = numberAttribute(bar, kAXMinValueAttribute as String),
      let upper = numberAttribute(bar, kAXMaxValueAttribute as String)
    else { return false }

    let next: Double
    if let edge = intent.edge {
      next = edgeScrollValue(lower: lower, upper: upper, edge: edge)
    } else if let deltaFraction = intent.deltaFraction {
      next = adjustedScrollValue(
        current: current,
        lower: lower,
        upper: upper,
        deltaFraction: deltaFraction)
    } else {
      return false
    }

    guard abs(next - current) > .ulpOfOne else { return true }
    return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
      == .success
  }

  private static func scrollPageInstantly(_ kind: ScrollKind, element: AXUIElement) -> Bool {
    guard let intent = intent(for: kind),
      intent.axis == .vertical,
      let edge = intent.edge,
      let bar = directScrollBar(on: element, axis: .vertical)
        ?? scrollBarNear(element: element, axis: .vertical),
      let current = numberAttribute(bar, kAXValueAttribute as String),
      let lower = numberAttribute(bar, kAXMinValueAttribute as String),
      let upper = numberAttribute(bar, kAXMaxValueAttribute as String)
    else { return false }

    let next = edgeScrollValue(lower: lower, upper: upper, edge: edge)
    guard abs(next - current) > .ulpOfOne else { return true }
    return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
      == .success
  }

  private static func performScrollAction(_ kind: ScrollKind, pid: pid_t) -> Bool {
    let actions = scrollActionNames(for: kind)
    guard !actions.isEmpty else { return false }

    let app = AXUIElementCreateApplication(pid)
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      performActionNear(element: focused, actions: actions)
    {
      return true
    }
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return false
    }
    if performActionNear(element: window, actions: actions) {
      return true
    }
    return performFirstActionInTree(in: window, actions: actions, maxNodes: 2_000)
  }

  private static func scrollActionNames(for kind: ScrollKind) -> [String] {
    switch kind {
    case .left:
      return ["AXScrollLeftByPage", "AXScrollLeft"]
    case .right:
      return ["AXScrollRightByPage", "AXScrollRight"]
    case .up, .halfPageUp:
      return ["AXScrollUpByPage", "AXScrollUp"]
    case .down, .halfPageDown:
      return ["AXScrollDownByPage", "AXScrollDown"]
    case .top, .bottom:
      return []
    }
  }

  private static func performActionNear(element: AXUIElement, actions: [String]) -> Bool {
    var current = element
    for _ in 0..<10 {
      if performFirstSupportedAction(current, actions: actions) {
        return true
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return false
      }
      current = parent
    }
    return false
  }

  private static func performFirstActionInTree(
    in root: AXUIElement,
    actions: [String],
    maxNodes: Int
  ) -> Bool {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if performFirstSupportedAction(element, actions: actions) {
        return true
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return false
  }

  private static func performFirstSupportedAction(
    _ element: AXUIElement,
    actions: [String]
  ) -> Bool {
    for action in actions {
      if AXUIElementPerformAction(element, action as CFString) == .success {
        return true
      }
    }
    return false
  }

  private static func intent(for kind: ScrollKind) -> ScrollIntent? {
    switch kind {
    case .left:
      return ScrollIntent(axis: .horizontal, deltaFraction: -0.08, edge: nil)
    case .right:
      return ScrollIntent(axis: .horizontal, deltaFraction: 0.08, edge: nil)
    case .up:
      return ScrollIntent(axis: .vertical, deltaFraction: -0.08, edge: nil)
    case .down:
      return ScrollIntent(axis: .vertical, deltaFraction: 0.08, edge: nil)
    case .halfPageUp:
      return ScrollIntent(axis: .vertical, deltaFraction: -0.5, edge: nil)
    case .halfPageDown:
      return ScrollIntent(axis: .vertical, deltaFraction: 0.5, edge: nil)
    case .top:
      return ScrollIntent(axis: .vertical, deltaFraction: nil, edge: .minimum)
    case .bottom:
      return ScrollIntent(axis: .vertical, deltaFraction: nil, edge: .maximum)
    }
  }

  private static func sendScrollKey(_ kind: ScrollKind, pid: pid_t) -> Bool {
    var sent = false
    for event in scrollKeyEvents(for: kind) {
      sent = sendKey(virtualKey: event.virtualKey, flags: event.flags, to: pid) || sent
    }
    return sent
  }

  static func scrollKeyEvents(for kind: ScrollKind) -> [(virtualKey: CGKeyCode, flags: CGEventFlags)] {
    switch kind {
    case .left:
      return [(CGKeyCode(kVK_LeftArrow), [])]
    case .right:
      return [(CGKeyCode(kVK_RightArrow), [])]
    case .up:
      return [(CGKeyCode(kVK_UpArrow), [])]
    case .down:
      return [(CGKeyCode(kVK_DownArrow), [])]
    case .halfPageUp:
      return [(CGKeyCode(kVK_PageUp), [])]
    case .halfPageDown:
      return [(CGKeyCode(kVK_PageDown), [])]
    case .top:
      return [(CGKeyCode(kVK_UpArrow), .maskCommand)]
    case .bottom:
      return [(CGKeyCode(kVK_DownArrow), .maskCommand)]
    }
  }

  private static func synthesizeScrollWheel(
    _ kind: ScrollKind,
    windowFrame: CGRect?,
    pageFrame: CGRect?
  ) -> Bool {
    guard let windowFrame, !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0,
      let delta = scrollWheelDelta(
        for: kind,
        viewportSize: (pageFrame ?? windowFrame).size)
    else {
      return false
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 2,
        wheel1: delta.vertical,
        wheel2: delta.horizontal,
        wheel3: 0)
    else {
      return false
    }
    let screenH = primaryScreenHeight()
    let point = scrollWheelPoint(windowFrame: windowFrame, pageFrame: pageFrame)
    event.location = CGPoint(x: point.x, y: screenH - point.y)
    event.post(tap: .cghidEventTap)
    return true
  }

  private static func scrollWheelPoint(windowFrame: CGRect, pageFrame: CGRect?) -> CGPoint {
    let frame = pageFrame ?? windowFrame
    let insetX = max(4, min(10, frame.width * 0.01))
    let x = min(max(frame.maxX - insetX, windowFrame.minX + 4), windowFrame.maxX - 4)
    let y = min(max(frame.midY, windowFrame.minY + 4), windowFrame.maxY - 4)
    return CGPoint(x: x, y: y)
  }

  static func scrollWheelDelta(
    for kind: ScrollKind,
    viewportSize: CGSize
  ) -> (vertical: Int32, horizontal: Int32)? {
    let verticalPage = Int32(max(1, (viewportSize.height / 2).rounded()))
    switch kind {
    case .left:
      return (vertical: 0, horizontal: scrollStepPixels)
    case .right:
      return (vertical: 0, horizontal: -scrollStepPixels)
    case .up:
      return (vertical: scrollStepPixels, horizontal: 0)
    case .down:
      return (vertical: -scrollStepPixels, horizontal: 0)
    case .halfPageUp:
      return (vertical: verticalPage, horizontal: 0)
    case .halfPageDown:
      return (vertical: -verticalPage, horizontal: 0)
    case .top, .bottom:
      return nil
    }
  }

  private static func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  @discardableResult
  static func sendKey(
    virtualKey: CGKeyCode,
    flags: CGEventFlags = [],
    to pid: pid_t
  ) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
    else { return false }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }

  static func cgFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var flags = CGEventFlags()
    if independent.contains(.command) { flags.insert(.maskCommand) }
    if independent.contains(.shift) { flags.insert(.maskShift) }
    if independent.contains(.control) { flags.insert(.maskControl) }
    if independent.contains(.option) { flags.insert(.maskAlternate) }
    return flags
  }

  static func copy(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
  }

  static func documentURL(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var focusedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
      == .success,
      let element = focusedRaw,
      CFGetTypeID(element) == AXUIElementGetTypeID(),
      let url = documentURLNear(element as! AXUIElement)
    {
      return url
    }

    var windowRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRaw)
        == .success,
      let window = windowRaw,
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    let focusedWindow = window as! AXUIElement
    if let url = urlAttribute(focusedWindow, kAXDocumentAttribute as String)
      ?? urlAttribute(focusedWindow, kAXURLAttribute as String)
    {
      return url
    }
    return firstDocumentURL(in: focusedWindow, maxNodes: 2_000)
  }

  static func isEditableFocusedElement(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let element = elementAttribute(app, kAXFocusedUIElementAttribute as String) else {
      return false
    }
    return isEditable(element)
  }

  static func focusedElementFrame(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    let screenH = primaryScreenHeight()
    if let element = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      let frame = frame(of: element, primaryScreenHeight: screenH)
    {
      return frame
    }
    if let window = elementAttribute(app, kAXFocusedWindowAttribute as String),
      let frame = frame(of: window, primaryScreenHeight: screenH)
    {
      return frame
    }
    return nil
  }

  static func defocusFocusedEditableElement(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      isEditable(focused)
    else { return true }

    if setFocused(focused, false) { return true }
    if let target = nearestNonEditableAncestor(of: focused),
      setFocused(target, true)
    {
      return true
    }
    if let window = elementAttribute(app, kAXFocusedWindowAttribute as String),
      setFocused(window, true)
    {
      return true
    }
    if let window = elementAttribute(app, kAXFocusedWindowAttribute as String),
      AXUIElementSetAttributeValue(app, kAXFocusedUIElementAttribute as CFString, window)
        == .success
    {
      return true
    }
    return false
  }

  private static func scrollBar(axis: Axis, pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
      let bar = scrollBarNear(element: focused, axis: axis)
    {
      return bar
    }
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return nil
    }
    return firstScrollBar(in: window, axis: axis, maxNodes: 2_000)
  }

  private static func scrollBarNear(element: AXUIElement, axis: Axis) -> AXUIElement? {
    var current = element
    for _ in 0..<10 {
      if let bar = directScrollBar(on: current, axis: axis) {
        return bar
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      current = parent
    }
    return nil
  }

  private static func firstScrollBar(
    in root: AXUIElement,
    axis: Axis,
    maxNodes: Int
  ) -> AXUIElement? {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if let bar = directScrollBar(on: element, axis: axis) {
        return bar
      }
      if isScrollBar(element, axis: axis), canAdjustScrollBar(element) {
        return element
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }

  private static func directScrollBar(on element: AXUIElement, axis: Axis) -> AXUIElement? {
    let name =
      axis == .vertical
      ? (kAXVerticalScrollBarAttribute as String)
      : (kAXHorizontalScrollBarAttribute as String)
    guard let bar = elementAttribute(element, name), canAdjustScrollBar(bar) else {
      return nil
    }
    return bar
  }

  private static func isScrollBar(_ element: AXUIElement, axis: Axis) -> Bool {
    guard role(of: element) == "AXScrollBar" else { return false }
    guard let orientation = stringAttribute(element, kAXOrientationAttribute as String) else {
      return true
    }
    switch axis {
    case .vertical:
      return orientation == (kAXVerticalOrientationValue as String)
    case .horizontal:
      return orientation == (kAXHorizontalOrientationValue as String)
    }
  }

  private static func canAdjustScrollBar(_ element: AXUIElement) -> Bool {
    numberAttribute(element, kAXValueAttribute as String) != nil
      && numberAttribute(element, kAXMinValueAttribute as String) != nil
      && numberAttribute(element, kAXMaxValueAttribute as String) != nil
  }

  private static let editableRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]
  private static let documentRoles: Set<String> = ["AXWebArea", "AXDocument"]

  private static func pageScrollTarget(pid: pid_t, visibleIn windowFrame: CGRect) -> PageScrollTarget?
  {
    guard !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0 else {
      return nil
    }
    let app = AXUIElementCreateApplication(pid)
    guard let window = elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      return nil
    }

    let screenH = primaryScreenHeight()
    var best: PageScrollTarget?
    var bestArea: CGFloat = 0
    var queue = [window]
    var index = 0
    while index < queue.count, index < 600 {
      let element = queue[index]
      index += 1
      if role(of: element).map({ documentRoles.contains($0) }) == true,
        let frame = frame(of: element, primaryScreenHeight: screenH)
      {
        let clipped = frame.intersection(windowFrame)
        if !clipped.isNull, clipped.width > 40, clipped.height > 40 {
          let area = clipped.width * clipped.height
          if area > bestArea {
            bestArea = area
            best = PageScrollTarget(element: element, frame: clipped)
          }
        }
      }
      queue.append(contentsOf: children(of: element))
    }
    return best
  }

  private static func isEditable(_ element: AXUIElement) -> Bool {
    var current = element
    for _ in 0..<8 {
      if role(of: current).map({ editableRoles.contains($0) }) == true {
        return true
      }
      if boolAttribute(current, "AXIsEditable") == true {
        return true
      }
      if elementAttribute(current, "AXEditableAncestor") != nil
        || elementAttribute(current, "AXHighestEditableAncestor") != nil
      {
        return true
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return false
      }
      current = parent
    }
    return false
  }

  private static func nearestNonEditableAncestor(of element: AXUIElement) -> AXUIElement? {
    var current = element
    for _ in 0..<8 {
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      if !isEditable(parent) { return parent }
      current = parent
    }
    return nil
  }

  private static func setFocused(_ element: AXUIElement, _ focused: Bool) -> Bool {
    AXUIElementSetAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      focused ? kCFBooleanTrue : kCFBooleanFalse
    ) == .success
  }

  private static func documentURLNear(_ element: AXUIElement) -> String? {
    var current = element
    for _ in 0..<10 {
      if role(of: current).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(current, kAXURLAttribute as String)
          ?? urlAttribute(current, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      current = parent
    }
    return nil
  }

  private static func firstDocumentURL(in root: AXUIElement, maxNodes: Int) -> String? {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if role(of: element).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(element, kAXURLAttribute as String)
          ?? urlAttribute(element, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let children = raw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }

  private static func role(of element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success
    else { return nil }
    return raw as? String
  }

  private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
      return nil
    }
    return raw as? String
  }

  private static func numberAttribute(_ element: AXUIElement, _ name: String) -> Double? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
      return (value as! NSNumber).doubleValue
    }
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    return nil
  }

  private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
      return nil
    }
    return raw as? Bool
  }

  private static func urlAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if CFGetTypeID(value) == CFURLGetTypeID() {
      return (value as! URL).absoluteString
    }
    if let url = value as? URL {
      return url.absoluteString
    }
    if let string = value as? String,
      !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return string
    }
    return nil
  }

  private static func frame(
    of element: AXUIElement,
    primaryScreenHeight screenH: CGFloat
  ) -> CGRect? {
    guard
      let origin = pointAttribute(element, kAXPositionAttribute as String),
      let size = sizeAttribute(element, kAXSizeAttribute as String),
      size.width > 0,
      size.height > 0
    else { return nil }
    return CGRect(
      x: origin.x,
      y: screenH - origin.y - size.height,
      width: size.width,
      height: size.height)
  }

  private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
  }

  private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
  }

  private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
      == .success,
      let children = raw as? [AXUIElement]
    else { return [] }
    return children
  }

}

private extension String {
  mutating func removeLeadingWhitespace() {
    while let firstChar = first, firstChar.isWhitespace {
      removeFirst()
    }
  }
}
