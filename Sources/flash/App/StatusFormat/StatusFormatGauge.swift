import Foundation

/// Flash's numeric style extensions, drawn with Unicode block elements so the
/// same runs work in the bar, desktop widgets and PTY popups:
///
/// - `#[meter=W]` / `#[meter=W/MAX]` … `#[nometer]`: the first number of the
///   enclosed text becomes a bar exactly `W` cells wide (1–200), filled in
///   eighths of a cell over `0…MAX` (default 100); the empty track is spaces,
///   so `bg=` paints it.
/// - `#[spark]` / `#[spark=MIN/MAX]` … `#[nospark]`: every number of the
///   enclosed text becomes one of `▁▂▃▄▅▆▇█`, scaled over `MIN…MAX` or, by
///   default, from 0 to the largest value (the Rust SDK's `sparkline_scaled`).
///
/// The enclosed text is replaced once the document is parsed; text without a
/// number is kept unchanged. A gauge never spans a line break.
struct StatusFormatGauge: Equatable {
  enum Kind: Equatable {
    case meter(width: Int, maximum: Double)
    case spark(minimum: Double, maximum: Double)
    case sparkToLargest
  }

  var kind: Kind
  /// Each accepted marker opens its own region, so two meters written back
  /// to back draw two bars even when their shapes are identical.
  var region: Int

  var isMeter: Bool {
    if case .meter = kind { return true }
    return false
  }

  static let eighths: [Character] = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  static let levels: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

  /// The shape a `meter=…`, `spark` or `spark=…` token selects; nil when the
  /// token is malformed, which rejects the whole marker.
  static func kind(token: String) -> Kind? {
    if token == "spark" { return .sparkToLargest }
    if token.hasPrefix("spark=") {
      let parts = token.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, let minimum = number(parts[0]), let maximum = number(parts[1]),
        minimum < maximum
      else { return nil }
      return .spark(minimum: minimum, maximum: maximum)
    }
    guard token.hasPrefix("meter=") else { return nil }
    let parts = token.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let width = StatusFormatNumber.integer(String(parts[0])),
      (1...200).contains(width)
    else { return nil }
    guard parts.count == 2 else { return .meter(width: width, maximum: 100) }
    guard let maximum = number(parts[1]), maximum > 0 else { return nil }
    return .meter(width: width, maximum: maximum)
  }

  private static func number(_ raw: Substring) -> Double? {
    guard let value = Double(raw), value.isFinite else { return nil }
    return value
  }

  /// The gauge drawn for one line of enclosed text, or nil to keep the text.
  func render(_ text: String) -> String? {
    switch kind {
    case .meter(let width, let maximum):
      guard let value = Self.numbers(in: text, limit: 1).first else { return nil }
      let total = width * 8
      let filled = Int((min(1, max(0, value / maximum)) * Double(total)).rounded())
      let partial = filled % 8
      var bar = String(repeating: "█", count: filled / 8)
      if partial > 0 { bar.append(Self.eighths[partial - 1]) }
      return bar + String(repeating: " ", count: width - filled / 8 - (partial > 0 ? 1 : 0))
    case .spark(let minimum, let maximum):
      let values = Self.numbers(in: text)
      guard !values.isEmpty else { return nil }
      return Self.sparkline(values, minimum: minimum, maximum: maximum)
    case .sparkToLargest:
      let values = Self.numbers(in: text)
      guard !values.isEmpty else { return nil }
      return Self.sparkline(values, minimum: 0, maximum: values.reduce(0, max))
    }
  }

  private static func sparkline(_ values: [Double], minimum: Double, maximum: Double) -> String {
    let span = maximum - minimum
    return String(
      values.map { value in
        guard span > .ulpOfOne else { return levels[0] }
        let index = ((value - minimum) / span * Double(levels.count - 1)).rounded(.down)
        return levels[Int(min(Double(levels.count - 1), max(0, index)))]
      })
  }

  /// ASCII decimal numbers in reading order: `-` is a sign unless it follows
  /// a digit or a point, and a point needs a digit after it.
  static func numbers(in text: String, limit: Int = .max) -> [Double] {
    let bytes = Array(text.utf8)
    func digit(_ index: Int) -> Bool { index < bytes.count && (48...57).contains(bytes[index]) }
    var values: [Double] = []
    var index = 0
    while index < bytes.count, values.count < limit {
      guard digit(index) || (bytes[index] == 46 && digit(index + 1)) else {
        index += 1
        continue
      }
      var start = index
      if start > 0, bytes[start - 1] == 45,
        start < 2 || !(digit(start - 2) || bytes[start - 2] == 46)
      {
        start -= 1
      }
      while digit(index) { index += 1 }
      if index < bytes.count, bytes[index] == 46, digit(index + 1) {
        index += 1
        while digit(index) { index += 1 }
      }
      if let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)),
        value.isFinite
      {
        values.append(value)
      }
    }
    return values
  }

  /// Replace each gauge region of a parsed document with its drawing. The
  /// runs a region encloses are merged per line before reading numbers, so
  /// a value split across fragments or restyled mid-number still reads as
  /// one; the drawing takes the style of the line's first enclosed run.
  static func render(_ runs: [FlashStatusTextSegment]) -> [FlashStatusTextSegment] {
    guard runs.contains(where: { $0.gauge != nil }) else { return runs }
    var output: [FlashStatusTextSegment] = []
    var index = 0
    while index < runs.count {
      guard let gauge = runs[index].gauge else {
        output.append(runs[index])
        index += 1
        continue
      }
      var end = index + 1
      while end < runs.count, runs[end].gauge == gauge { end += 1 }
      output += gauge.render(region: runs[index..<end])
      index = end
    }
    return output
  }

  private func render(region: ArraySlice<FlashStatusTextSegment>) -> [FlashStatusTextSegment] {
    var output: [FlashStatusTextSegment] = []
    var line: [Int] = []
    func finishLine() {
      defer { line = [] }
      guard let first = line.first,
        let drawing = render(line.map { output[$0].text }.joined())
      else { return }
      output[first].text = drawing
      for index in line.dropFirst() { output[index].text = "" }
    }
    for var run in region {
      run.gauge = nil
      guard !run.isStyleBoundary, !run.isModeLabel else {
        output.append(run)
        continue
      }
      let parts = run.text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      for (offset, part) in parts.enumerated() {
        if offset > 0 {
          finishLine()
          var lineBreak = run
          lineBreak.text = "\n"
          output.append(lineBreak)
        }
        guard !part.isEmpty else { continue }
        var piece = run
        piece.text = String(Substring(part))
        line.append(output.count)
        output.append(piece)
      }
    }
    finishLine()
    return output.filter { $0.isStyleBoundary || $0.isModeLabel || !$0.text.isEmpty }
  }
}
