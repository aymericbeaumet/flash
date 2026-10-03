import AppKit
import CFlashTerminal
import CoreText

/// Draws terminal rows at fixed cell positions. Every glyph is placed at
/// `column × cellWidth` with `CTFontDrawGlyphs`, one call per run of a font
/// variant and colour, so text never drifts from the backgrounds, cursor,
/// selection and hit testing that share the grid. Characters come from a
/// per-variant scalar→glyph cache; a scalar the monospaced font lacks
/// resolves once to a fallback font's glyph. Grapheme clusters and scalars no
/// font covers are laid out by Core Text and clipped to their own cells.
final class TerminalRenderer {
  enum Part {
    /// Backgrounds, text and decorations of every cell except blinking ones.
    case base
    /// Only the text and decorations of blinking cells, on a clear background.
    case blinking
  }

  /// Colours shared by every row of one view configuration.
  struct Palette {
    var background: CGColor
    var selectedForeground: CGColor
    var selectedBackground: CGColor
  }

  /// A contiguous batch of glyphs sharing a font and colour; `clip` confines a
  /// fallback glyph that may be wider than its cells.
  struct GlyphRun {
    var font: CTFont
    var color: CGColor
    var range: Range<Int>
    var clip: CGRect?
  }

  /// Core Text layout for a cell no single glyph can draw.
  struct LineDraw {
    var line: CTLine
    var color: CGColor
    var rect: CGRect
  }

  private enum Glyph {
    case blank
    case glyph(CTFont, CGGlyph)
    case line
  }

  private final class FontVariant {
    let font: CTFont
    private var ascii: [Glyph] = []
    private var scalars = TerminalCache<UInt32, Glyph>(limit: 2048)

    init(_ font: CTFont) {
      self.font = font
      var characters = (0..<128).map { UniChar($0) }
      var glyphs = [CGGlyph](repeating: 0, count: 128)
      CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 128)
      ascii = (0..<128).map { index in
        if index <= 0x20 || index == 0x7F { return .blank }
        return glyphs[index] != 0 ? .glyph(font, glyphs[index]) : .line
      }
    }

    func glyph(for scalar: UInt32) -> Glyph {
      if scalar < 128 { return ascii[Int(scalar)] }
      if let cached = scalars[scalar] { return cached }
      let resolved = resolve(scalar)
      scalars[scalar] = resolved
      return resolved
    }

    private func resolve(_ value: UInt32) -> Glyph {
      guard let scalar = Unicode.Scalar(value) else { return .line }
      if scalar.properties.isWhitespace { return .blank }
      let text = String(scalar)
      var characters = Array(text.utf16)
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      if CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), glyphs[0] != 0
      {
        return .glyph(font, glyphs[0])
      }
      let fallback = CTFontCreateForString(
        font, text as CFString, CFRange(location: 0, length: characters.count))
      if CTFontGetGlyphsForCharacters(fallback, &characters, &glyphs, characters.count),
        glyphs[0] != 0
      {
        return .glyph(fallback, glyphs[0])
      }
      return .line
    }
  }

  private struct LineKey: Hashable {
    let text: String
    let variant: Int
  }

  /// Metrics and font variants are derived on first use after a change, so
  /// creating a view never measures a font it may not draw with.
  var font: NSFont {
    didSet {
      guard font != oldValue else { return }
      metrics = nil
      lines.removeAll()
    }
  }
  private struct Metrics {
    var cellSize: NSSize
    var baseline: CGFloat
    var variants: [FontVariant]
  }
  private var metrics: Metrics?
  private var current: Metrics {
    if let metrics { return metrics }
    let value = configure()
    metrics = value
    return value
  }
  var cellSize: NSSize { current.cellSize }
  var baseline: CGFloat { current.baseline }
  private var variants: [FontVariant] { current.variants }
  private var colors = TerminalCache<UInt32, CGColor>(limit: 512)
  private var lines = TerminalCache<LineKey, CTLine>(limit: 512)
  // Scratch storage reused by every row.
  private(set) var glyphs: [CGGlyph] = []
  private(set) var positions: [CGPoint] = []
  private(set) var runs: [GlyphRun] = []
  private(set) var lineDraws: [LineDraw] = []

  init(font: NSFont) {
    self.font = font
  }

  /// One integral cell of `font`: the advance of "M" by the line height.
  static func cellSize(for font: NSFont) -> NSSize {
    NSSize(
      width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
      height: ceil(font.ascender - font.descender + font.leading))
  }

  private func configure() -> Metrics {
    let manager = NSFontManager.shared
    return Metrics(
      cellSize: Self.cellSize(for: font),
      baseline: font.ascender,
      // Regular / bold / italic / bold-italic, indexed by the low two cell flags.
      variants: [
        font, manager.convert(font, toHaveTrait: .boldFontMask),
        manager.convert(font, toHaveTrait: .italicFontMask),
        manager.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask]),
      ].map { FontVariant($0 as CTFont) })
  }

  func color(_ color: TerminalColor, faint: Bool = false) -> CGColor {
    let key =
      UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue)
      | (faint ? 1 << 24 : 0)
    if let cached = colors[key] { return cached }
    let value = CGColor(
      srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
      blue: CGFloat(color.blue) / 255, alpha: faint ? 0.6 : 1)
    colors[key] = value
    return value
  }

  private func line(_ text: String, variant: Int) -> CTLine {
    let key = LineKey(text: text, variant: variant)
    if let cached = lines[key] { return cached }
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: variants[variant].font,
          kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ]))
    lines[key] = line
    return line
  }

  private static func draws(_ cell: FlashVTCell, part: Part) -> Bool {
    cell.width > 0 && cell.flags & 32 == 0
      && (cell.flags & TerminalRow.blinkFlag != 0) == (part == .blinking)
  }

  /// Lays out the text of one row in row-local coordinates into `glyphs`,
  /// `positions`, `runs` and `lineDraws`.
  func layout(_ row: TerminalRow, selection: Range<Int>?, part: Part, palette: Palette) {
    glyphs.removeAll(keepingCapacity: true)
    positions.removeAll(keepingCapacity: true)
    runs.removeAll(keepingCapacity: true)
    lineDraws.removeAll(keepingCapacity: true)
    let metrics = current
    let width = metrics.cellSize.width
    let height = metrics.cellSize.height
    let variants = metrics.variants
    var runKey: (variant: Int, color: UInt64)?
    for column in row.cells.indices {
      let cell = row.cells[column]
      guard Self.draws(cell, part: part), cell.content != 0 else { continue }
      let selected = selection?.contains(column) == true
      let faint = cell.flags & 4 != 0
      let foreground = TerminalColor(cell.flags & 16 != 0 ? cell.background : cell.foreground)
      let colorKey: UInt64 =
        selected
        ? 1 << 32
        : UInt64(foreground.red) << 16 | UInt64(foreground.green) << 8 | UInt64(foreground.blue)
          | (faint ? 1 << 24 : 0)
      let colorValue = {
        selected ? palette.selectedForeground : self.color(foreground, faint: faint)
      }
      let variant = Int(cell.flags & 3)
      let x = CGFloat(column) * width
      let rect = CGRect(x: x, y: 0, width: width * CGFloat(cell.width), height: height)
      let glyph: Glyph =
        cell.content & FLASH_VT_CLUSTER != 0 ? .line : variants[variant].glyph(for: cell.content)
      switch glyph {
      case .blank:
        continue
      case .glyph(let font, let value) where font === variants[variant].font:
        if runKey?.variant != variant || runKey?.color != colorKey || runs.last?.clip != nil {
          runs.append(
            GlyphRun(font: font, color: colorValue(), range: glyphs.count..<glyphs.count, clip: nil)
          )
          runKey = (variant, colorKey)
        }
        glyphs.append(value)
        positions.append(CGPoint(x: x, y: 0))
        runs[runs.count - 1].range = runs[runs.count - 1].range.lowerBound..<glyphs.count
      case .glyph(let font, let value):
        runs.append(
          GlyphRun(
            font: font, color: colorValue(), range: glyphs.count..<(glyphs.count + 1), clip: rect))
        runKey = nil
        glyphs.append(value)
        positions.append(CGPoint(x: x, y: 0))
      case .line:
        lineDraws.append(
          LineDraw(
            line: line(row.text(at: column), variant: variant), color: colorValue(), rect: rect))
      }
    }
  }

  /// Draws one row at the context origin: a row-high strip `width` wide in a
  /// flipped (top-left origin) context.
  func draw(
    _ row: TerminalRow, frameBackground: TerminalColor, selection: Range<Int>?, part: Part,
    palette: Palette, width: CGFloat, in context: CGContext
  ) {
    context.saveGState()
    defer { context.restoreGState() }
    let size = cellSize
    if part == .base {
      context.setFillColor(palette.background)
      context.fill(CGRect(x: 0, y: 0, width: width, height: size.height))
      // Backgrounds merged into runs of one colour. Cells on the terminal's
      // own background are already painted by the fill above.
      var pending: (rect: CGRect, key: UInt64, color: CGColor)?
      for column in row.cells.indices {
        let cell = row.cells[column]
        guard cell.width > 0 else { continue }
        let selected = selection?.contains(column) == true
        let background = cell.flags & 16 != 0 ? cell.foreground : cell.background
        guard selected || TerminalColor(background) != frameBackground else { continue }
        let key: UInt64 =
          selected
          ? 1 << 32 : UInt64(background.r) << 16 | UInt64(background.g) << 8 | UInt64(background.b)
        let rect = CGRect(
          x: CGFloat(column) * size.width, y: 0, width: size.width * CGFloat(cell.width),
          height: size.height)
        if var fill = pending, fill.key == key, fill.rect.maxX == rect.minX {
          fill.rect.size.width += rect.width
          pending = fill
        } else {
          if let fill = pending {
            context.setFillColor(fill.color)
            context.fill(fill.rect)
          }
          pending = (
            rect, key, selected ? palette.selectedBackground : color(TerminalColor(background))
          )
        }
      }
      if let fill = pending {
        context.setFillColor(fill.color)
        context.fill(fill.rect)
      }
    }
    layout(row, selection: selection, part: part, palette: palette)
    glyphs.withUnsafeBufferPointer { glyphs in
      positions.withUnsafeBufferPointer { positions in
        for run in runs {
          drawAtBaseline(context, clip: run.clip) {
            context.setFillColor(run.color)
            CTFontDrawGlyphs(
              run.font, glyphs.baseAddress! + run.range.lowerBound,
              positions.baseAddress! + run.range.lowerBound, run.range.count, context)
          }
        }
      }
    }
    for draw in lineDraws {
      drawAtBaseline(context, clip: draw.rect) {
        context.setFillColor(draw.color)
        context.textPosition = CGPoint(x: draw.rect.minX, y: 0)
        CTLineDraw(draw.line, context)
      }
    }
    drawDecorations(row, part: part, in: context)
  }

  /// Runs `body` in the row's text space: origin on the baseline, y up, and
  /// an identity text matrix, so glyph positions are plain `(x, 0)` points.
  private func drawAtBaseline(_ context: CGContext, clip: CGRect?, _ body: () -> Void) {
    context.saveGState()
    if let clip { context.clip(to: clip) }
    context.translateBy(x: 0, y: baseline)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    body()
    context.restoreGState()
  }

  private func drawDecorations(_ row: TerminalRow, part: Part, in context: CGContext) {
    let size = cellSize
    for column in row.cells.indices {
      let cell = row.cells[column]
      guard Self.draws(cell, part: part), cell.underline > 0 || cell.flags & (64 | 128) != 0 else {
        continue
      }
      let rect = CGRect(
        x: CGFloat(column) * size.width, y: 0, width: size.width * CGFloat(cell.width),
        height: size.height)
      context.setStrokeColor(color(TerminalColor(cell.underline_color)))
      context.setLineWidth(1)
      if cell.underline > 0 {
        context.saveGState()
        if cell.underline == 4 { context.setLineDash(phase: 0, lengths: [1, 2]) }
        if cell.underline == 5 { context.setLineDash(phase: 0, lengths: [4, 2]) }
        if cell.underline == 3 {
          context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 2))
          var x = rect.minX
          while x < rect.maxX {
            context.addLine(to: CGPoint(x: x + 1, y: rect.maxY - 3))
            context.addLine(to: CGPoint(x: x + 3, y: rect.maxY - 1))
            x += 4
          }
          context.strokePath()
        } else {
          stroke(y: rect.maxY - 2, rect: rect, context: context)
        }
        context.restoreGState()
      }
      if cell.underline == 2 { stroke(y: rect.maxY - 4, rect: rect, context: context) }
      if cell.flags & 64 != 0 { stroke(y: rect.midY, rect: rect, context: context) }
      if cell.flags & 128 != 0 { stroke(y: rect.minY + 1, rect: rect, context: context) }
    }
  }

  private func stroke(y: CGFloat, rect: CGRect, context: CGContext) {
    context.move(to: CGPoint(x: rect.minX, y: y))
    context.addLine(to: CGPoint(x: rect.maxX, y: y))
    context.strokePath()
  }

  /// Draws the glyph of one cell at the context origin in `color`, for the
  /// inverse block cursor.
  func drawGlyph(of row: TerminalRow, column: Int, color: CGColor, in context: CGContext) {
    let cell = row.cells[column]
    guard cell.content != 0, cell.flags & 32 == 0 else { return }
    let variant = Int(cell.flags & 3)
    let rect = CGRect(
      x: 0, y: 0, width: cellSize.width * CGFloat(max(1, cell.width)), height: cellSize.height)
    let glyph: Glyph =
      cell.content & FLASH_VT_CLUSTER != 0 ? .line : variants[variant].glyph(for: cell.content)
    drawAtBaseline(context, clip: rect) {
      context.setFillColor(color)
      switch glyph {
      case .blank:
        break
      case .glyph(let font, var value):
        var position = CGPoint.zero
        CTFontDrawGlyphs(font, &value, &position, 1, context)
      case .line:
        context.textPosition = .zero
        CTLineDraw(line(row.text(at: column), variant: variant), context)
      }
    }
  }
}

/// A bounded cache with approximate LRU eviction and no wipe-all cliff: hits
/// in the older generation are promoted, and filling the current generation
/// retires only the older one.
struct TerminalCache<Key: Hashable, Value> {
  private var current: [Key: Value] = [:]
  private var older: [Key: Value] = [:]
  let limit: Int

  init(limit: Int) { self.limit = limit }

  var count: Int { current.count + older.count }

  subscript(key: Key) -> Value? {
    mutating get {
      if let value = current[key] { return value }
      guard let value = older.removeValue(forKey: key) else { return nil }
      insert(value, for: key)
      return value
    }
    set {
      if let newValue { insert(newValue, for: key) } else { current[key] = nil }
    }
  }

  private mutating func insert(_ value: Value, for key: Key) {
    if current.count >= limit {
      older = current
      current = [:]
      current.reserveCapacity(limit)
    }
    current[key] = value
  }

  mutating func removeAll() {
    current.removeAll()
    older.removeAll()
  }
}
