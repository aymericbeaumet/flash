// Layout algorithms adapted from tmux 3.7b format-draw.c.
// Copyright (c) 2019, 2023 Nicholas Marriott <nicholas.marriott@gmail.com>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

import Foundation

/// Positions an already-expanded document using tmux's status-line cell rules.
/// Style width/pad are intentionally inert here: tmux uses them for scrollbars,
/// while format_draw consumes alignment, fill, list, and range metadata.
enum StatusFormatLayout {
  struct Cell: Equatable {
    var segment: FlashStatusTextSegment
    var columns = 1
    var isContinuation = false
  }

  struct PositionedRun: Equatable {
    var column: Int
    var columns: Int
    var segment: FlashStatusTextSegment
  }

  struct PositionedRange: Equatable {
    var columns: Range<Int>
    var range: StatusFormatRange
  }

  struct Result: Equatable {
    var cells: [Cell]
    var positionedRuns: [PositionedRun]
    var ranges: [PositionedRange]
    var fill: FlashStatusTextColor?
    var text: String { cells.filter { !$0.isContinuation }.map(\.segment.text).joined() }
  }

  static func layout(
    _ document: StatusFormatDocument, columns: Int,
    defaultStyle: FlashStatusTextSegment = .init(text: "", foreground: .defaultForeground)
  ) -> Result {
    var builder = Builder(columns: max(0, columns), defaultStyle: defaultStyle)
    for run in document.runs { builder.append(run) }
    return builder.finish()
  }

  private enum Section: Int, CaseIterable {
    case left, centre, right, absoluteCentre, list, leftMarker, rightMarker, after
  }

  private struct StoredRange {
    var section: Section
    var columns: Range<Int>
    var range: StatusFormatRange
  }

  private struct Builder {
    var columns: Int
    var defaultStyle: FlashStatusTextSegment
    var screens = Array(repeating: [Cell](), count: Section.allCases.count)
    var current = Section.left
    var alignmentMap: [StatusFormatAlignment: Section] = [
      .default: .left, .left: .left, .centre: .centre, .right: .right,
      .absoluteCentre: .absoluteCentre,
    ]
    enum ListState { case before, inside, after }
    var listState = ListState.before
    var listAlignment = StatusFormatAlignment.default
    var focusStart: Int?
    var focusEnd: Int?
    var fill: FlashStatusTextColor?
    var activeRange: StoredRange?
    var ranges: [StoredRange] = []
    var output: [Cell] = []
    var outputCursor = 0

    mutating func append(_ run: FlashStatusTextSegment) {
      if run.isStyleBoundary {
        applyBoundary(run)
        return
      }
      // Native format_draw treats newline/tab/control bytes as nonprinting.
      for scalar in run.text.unicodeScalars where scalar.value >= 32 && scalar.value != 127 {
        if scalar.value == 0x3164 { continue }
        let width = StatusFormatCells.scalarWidth(scalar)
        if combine(scalar, width: width) || width == 0 {
          continue
        }
        var segment = run
        segment.text = String(scalar)
        screens[current.rawValue].append(Cell(segment: segment, columns: width))
        for _ in 1..<width {
          segment.text = ""
          screens[current.rawValue].append(Cell(segment: segment, columns: 0, isContinuation: true))
        }
      }
    }

    mutating func combine(_ scalar: Unicode.Scalar, width: Int) -> Bool {
      guard let index = screens[current.rawValue].lastIndex(where: { !$0.isContinuation })
      else { return false }
      var previous = screens[current.rawValue][index]
      let joined = previous.segment.text + String(scalar)
      let scalars = previous.segment.text.unicodeScalars
      let first = scalars.first!.value
      let last = scalars.last!.value
      let value = scalar.value
      var forceWide = value == 0xfe0f
      var combines = width == 0 || forceWide
      if !combines, value >= 128 {
        switch Self.hangulClass(value) {
        case 1: return false
        case 2:
          if Self.hangulClass(last) != 1 { return true }
          combines = true
        case 3:
          if Self.hangulClass(last) != 2 { return true }
          combines = true
        default:
          let regional =
            (0x1f1e6...0x1f1ff).contains(value)
            && (0x1f1e6...0x1f1ff).contains(first)
            && scalars.filter { (0x1f1e6...0x1f1ff).contains($0.value) }.count == 1
          let modifier =
            ((0x1f3fb...0x1f3ff).contains(value) && Self.modifierBases.contains(first))
            || ((0x1f3fb...0x1f3ff).contains(first) && Self.modifierBases.contains(value))
          forceWide = regional || modifier
          combines = forceWide || last == 0x200d
        }
      }
      guard combines else { return false }
      // tmux's grid stores at most UTF8_SIZE bytes in a combined cell.
      guard joined.utf8.count <= 32 else { return false }
      previous.segment.text = joined
      if previous.columns == 1 && forceWide {
        previous.columns = 2
        var continuation = previous.segment
        continuation.text = ""
        screens[current.rawValue].append(
          Cell(segment: continuation, columns: 0, isContinuation: true))
      }
      screens[current.rawValue][index] = previous
      return true
    }

    static func hangulClass(_ value: UInt32) -> Int {
      switch value {
      case 0x1100...0x115f, 0xa960...0xa97c: return 1
      case 0x1160...0x11a7, 0xd7b0...0xd7c6: return 2
      case 0x11a8...0x11ff, 0xd7cb...0xd7fb: return 3
      default: return 0
      }
    }

    static let modifierBases: Set<UInt32> = [
      0x1f44b, 0x1f44c, 0x1f44d, 0x1f44e, 0x1f44f, 0x1f450, 0x1f466,
      0x1f467, 0x1f468, 0x1f469, 0x1f46e, 0x1f470, 0x1f471, 0x1f472,
      0x1f473, 0x1f474, 0x1f475, 0x1f476, 0x1f477, 0x1f478, 0x1f47c,
      0x1f481, 0x1f482, 0x1f483, 0x1f485, 0x1f486, 0x1f487, 0x1f4aa,
      0x1f575, 0x1f57a, 0x1f590, 0x1f595, 0x1f596, 0x1f645, 0x1f646,
      0x1f647, 0x1f64b, 0x1f64c, 0x1f64d, 0x1f64e, 0x1f64f, 0x1f6b4,
      0x1f6b5, 0x1f6b6, 0x1f926, 0x1f937, 0x1f938, 0x1f939, 0x1f93d,
      0x1f93e, 0x1f9b5, 0x1f9b6, 0x1f9b8, 0x1f9b9, 0x1f9cd, 0x1f9ce,
      0x1f9cf, 0x1f9d1, 0x1f9d2, 0x1f9d3, 0x1f9d4, 0x1f9d5, 0x1f9d6,
      0x1f9d7, 0x1f9d8, 0x1f9d9, 0x1f9da, 0x1f9db, 0x1f9dc, 0x1f9dd,
      0x1f9de, 0x1f9df,
    ]

    mutating func applyBoundary(_ run: FlashStatusTextSegment) {
      if let value = run.fill {
        fill = value
      }
      switch run.list {
      case .on:
        if listState != .inside {
          activeRange = nil
          listState = .inside
          listAlignment = run.alignment
        }
        endFocus()
        current = .list
      case .focus:
        if listState == .inside, focusStart == nil { focusStart = count(.list) }
      case .off:
        if listState == .inside {
          activeRange = nil
          endFocus()
          alignmentMap[listAlignment] = .after
          if listAlignment == .left { alignmentMap[.default] = .after }
          listState = .after
        }
        current = alignmentMap[run.alignment] ?? .left
      case .leftMarker, .rightMarker:
        let marker: Section = run.list == .leftMarker ? .leftMarker : .rightMarker
        if listState == .inside, count(marker) == 0 {
          activeRange = nil
          if focusStart != nil, focusEnd == nil {
            focusStart = nil
            focusEnd = nil
          }
          current = marker
        }
      }
      if let active = activeRange, active.range != run.nativeRange {
        if count(current) != active.columns.lowerBound {
          var closed = active
          closed.columns =
            active.columns.lowerBound..<max(active.columns.lowerBound, count(current) + 1)
          ranges.append(closed)
        }
        activeRange = nil
      }
      if activeRange == nil, let range = run.nativeRange {
        activeRange = StoredRange(
          section: current, columns: count(current)..<count(current), range: range)
      }
    }

    mutating func endFocus() {
      if focusStart != nil, focusEnd == nil { focusEnd = count(.list) }
    }

    func count(_ section: Section) -> Int { screens[section.rawValue].count }

    mutating func finish() -> Result {
      var blank = defaultStyle
      blank.text = " "
      blank.isStyleBoundary = false
      if let fill {
        blank = .init(text: " ", foreground: .defaultForeground, background: fill)
      }
      output = Array(repeating: Cell(segment: blank), count: columns)
      guard columns > 0 else {
        return Result(cells: [], positionedRuns: [], ranges: [], fill: fill)
      }
      switch listAlignment {
      case .default: drawWithoutList()
      case .left, .right: drawEdgeList()
      case .centre: drawCentreList()
      case .absoluteCentre: drawAbsoluteCentreList()
      }
      // Native row output advances over a wide glyph even if a later aligned
      // section overwrote its padding cell in the intermediate grid.
      var column = 0
      while column < output.count {
        let cell = output[column]
        if cell.isContinuation {
          output[column] = Cell(segment: blank)
        }
        if cell.columns > 1, column + 1 < output.count {
          var padding = cell.segment
          padding.text = ""
          output[column + 1] = Cell(segment: padding, columns: 0, isContinuation: true)
        }
        column += max(1, cell.columns)
      }
      return Result(
        cells: output, positionedRuns: Self.runs(output),
        ranges: ranges.map { .init(columns: $0.columns, range: $0.range) }, fill: fill)
    }

    /// Trim whole cell counts in upstream priority order without a per-cell loop.
    func trimmed(_ sections: [Section], available: Int) -> [Section: Int] {
      var widths = Dictionary(uniqueKeysWithValues: sections.map { ($0, count($0)) })
      var excess = max(0, widths.values.reduce(0, +) - available)
      for section in sections {
        let removed = min(widths[section, default: 0], excess)
        widths[section, default: 0] -= removed
        excess -= removed
      }
      return widths
    }

    mutating func drawWithoutList() {
      let w = trimmed([.centre, .right, .left], available: columns)
      let left = w[.left, default: 0]
      let centre = w[.centre, default: 0]
      let right = w[.right, default: 0]
      put(.left, offset: 0, width: left)
      put(.right, offset: columns - right, start: count(.right) - right, width: right)
      put(
        .centre, offset: left + (columns - right - left) / 2 - centre / 2,
        start: count(.centre) / 2 - centre / 2, width: centre)
      overlayAbsoluteCentre()
    }

    mutating func drawEdgeList() {
      let w = trimmed([.centre, .list, .right, .after, .left], available: columns)
      let left = w[.left, default: 0]
      let centre = w[.centre, default: 0]
      let right = w[.right, default: 0]
      let list = w[.list, default: 0]
      let after = w[.after, default: 0]
      guard list > 0 else {
        // The native fallback copies AFTER without advancing the source
        // cursor, so its cells do not extend the subsequently measured lane.
        drawWithoutList()
        return
      }
      put(.left, offset: 0, width: left)
      if listAlignment == .left {
        put(.right, offset: columns - right, start: count(.right) - right, width: right)
        put(.after, offset: left + list, width: after)
        let centreStart = left + list + after
        put(
          .centre, offset: centreStart + (columns - right - centreStart) / 2 - centre / 2,
          start: count(.centre) / 2 - centre / 2, width: centre)
        putList(offset: left, width: list, defaultFocus: 0)
      } else {
        put(.after, offset: columns - after, start: count(.after) - after, width: after)
        put(.right, offset: columns - right - list - after, width: right)
        put(
          .centre, offset: left + (columns - right - list - after - left) / 2 - centre / 2,
          start: count(.centre) / 2 - centre / 2, width: centre)
        putList(offset: columns - list - after, width: list, defaultFocus: 0)
      }
      overlayAbsoluteCentre()
    }

    mutating func drawCentreList() {
      let w = trimmed([.list, .after, .centre, .right, .left], available: columns)
      let left = w[.left, default: 0]
      let centre = w[.centre, default: 0]
      let right = w[.right, default: 0]
      let list = w[.list, default: 0]
      let after = w[.after, default: 0]
      guard list > 0 else {
        drawWithoutList()
        return
      }
      put(.left, offset: 0, width: left)
      put(.right, offset: columns - right, start: count(.right) - right, width: right)
      let middle = left + (columns - right - left) / 2
      put(.centre, offset: middle - list / 2 - centre, width: centre)
      put(.after, offset: middle - list / 2 + list, width: after)
      putList(offset: middle - list / 2, width: list, defaultFocus: count(.list) / 2)
      overlayAbsoluteCentre()
    }

    mutating func drawAbsoluteCentreList() {
      let outer = trimmed([.centre, .right, .left], available: columns)
      let inner = trimmed([.list, .after, .absoluteCentre], available: columns)
      let left = outer[.left, default: 0]
      let centre = outer[.centre, default: 0]
      let right = outer[.right, default: 0]
      let list = inner[.list, default: 0]
      let after = inner[.after, default: 0]
      let absolute = inner[.absoluteCentre, default: 0]
      put(.left, offset: 0, width: left)
      put(.right, offset: columns - right, start: count(.right) - right, width: right)
      let middle = left + (columns - right - left) / 2
      put(.centre, offset: middle - centre, width: centre)
      let offset = (columns - list - absolute) / 2
      put(.absoluteCentre, offset: offset, width: absolute)
      putList(offset: offset + absolute, width: list, defaultFocus: count(.list) / 2)
      put(.after, offset: offset + absolute + list, width: after)
    }

    mutating func overlayAbsoluteCentre() {
      let width = min(columns, count(.absoluteCentre))
      put(.absoluteCentre, offset: (columns - width) / 2, width: width)
    }

    mutating func putList(offset originalOffset: Int, width originalWidth: Int, defaultFocus: Int) {
      var offset = originalOffset
      var width = originalWidth
      guard width < count(.list) else {
        put(.list, offset: offset, width: width)
        return
      }
      let centre: Int
      if let start = focusStart, let end = focusEnd {
        centre = start + (end - start) / 2
      } else {
        centre = defaultFocus
      }
      var start = max(0, centre - width / 2)
      start = min(start, count(.list) - width)
      if start != 0, width > count(.leftMarker) {
        put(.leftMarker, offset: offset, width: count(.leftMarker), updateRanges: false)
        offset += count(.leftMarker)
        start += count(.leftMarker)
        width -= count(.leftMarker)
      }
      if start + width < count(.list), width > count(.rightMarker) {
        put(
          .rightMarker, offset: offset + width - count(.rightMarker),
          width: count(.rightMarker), updateRanges: false)
        width -= count(.rightMarker)
      }
      put(.list, offset: offset, start: start, width: width)
    }

    mutating func put(
      _ section: Section, offset: Int, start: Int = 0, width: Int,
      updateRanges: Bool = true
    ) {
      let source = screens[section.rawValue]
      // -1 is native cursormove's "unchanged" sentinel; other underflows
      // become an unsigned out-of-bounds position and clamp to the last cell.
      let destination =
        offset == -1 ? outputCursor : (offset < 0 ? columns - 1 : min(offset, columns - 1))
      outputCursor = destination
      for index in 0..<max(0, width) {
        guard start + index < source.count, destination + index < columns else { break }
        let cell = source[start + index]
        if index + cell.columns > width { break }
        if cell.isContinuation, index == 0 { continue }
        output[destination + index] = cell
      }
      guard updateRanges else { return }
      ranges = ranges.compactMap { stored in
        guard stored.section == section else { return stored }
        let lower = max(stored.columns.lowerBound, start)
        let upper = min(stored.columns.upperBound, start + width)
        guard lower < upper else { return nil }
        var updated = stored
        updated.columns = (lower - start + offset)..<(upper - start + offset)
        return updated
      }
    }

    static func runs(_ cells: [Cell]) -> [PositionedRun] {
      var result: [PositionedRun] = []
      for (index, cell) in cells.enumerated() where !cell.isContinuation {
        if var last = result.last {
          var appearance = last.segment
          appearance.text = cell.segment.text
          if appearance == cell.segment, last.column + last.columns == index {
            last.segment.text += cell.segment.text
            last.columns += cell.columns
            result[result.count - 1] = last
            continue
          }
        }
        result.append(.init(column: index, columns: cell.columns, segment: cell.segment))
      }
      return result
    }
  }
}
