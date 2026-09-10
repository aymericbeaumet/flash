import AppKit
import CoreText

public final class TerminalView: NSView, NSTextInputClient {
  public var inputInterceptor: ((NSEvent) -> Bool)?
  public var onFocusRequested: (() -> Void)?
  public var openURL: (URL) -> Void = { url in
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(url, configuration: configuration)
  }
  public var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
    didSet {
      cachedCellSize = nil
      cachedFontVariants = nil
      needsDisplay = true
      updateCellGeometry()
    }
  }
  /// Regular / bold / italic / bold-italic, derived once per font change
  /// (`NSFontManager.convert` per frame was a measurable share of a redraw).
  private var cachedFontVariants: [NSFont]?
  private var cachedCellSize: NSSize?
  private func fontVariants() -> [NSFont] {
    if let cachedFontVariants { return cachedFontVariants }
    let variants = [
      font,
      NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
      NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
      NSFontManager.shared.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask]),
    ]
    cachedFontVariants = variants
    return variants
  }
  public var foreground: NSColor = .white { didSet { updateColors() } }
  public var background: NSColor = .black { didSet { updateColors() } }
  public var isRenderingEnabled = false {
    didSet {
      session?.setWantsFrames(isRenderingEnabled)
      if isRenderingEnabled { needsDisplay = true }
      updateBlinkTimer()
    }
  }
  public var cellSize: NSSize {
    if let cachedCellSize { return cachedCellSize }
    let size = NSSize(
      width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
      height: ceil(font.ascender - font.descender + font.leading))
    cachedCellSize = size
    return size
  }
  public private(set) var terminalFrame: TerminalFrame?
  private weak var session: TerminalSession?
  private weak var document: TerminalDocument?
  private var selection: ClosedRange<Int>?
  private enum MouseGesture {
    case reporting
    case selecting(start: Int, link: URL?, origin: NSPoint, dragged: Bool)
  }
  private var mouseGesture: MouseGesture?
  private var marked = NSAttributedString(string: "")
  private var markedSelection = NSRange(location: 0, length: 0)
  private var interpretingEvent: NSEvent?
  private var interpreted = false
  private var localCommandKeys: Set<UInt16> = []
  private var blinkTimer: Timer?
  private var blinkVisible = true

  deinit { blinkTimer?.invalidate() }

  public override var acceptsFirstResponder: Bool { true }
  public override var isFlipped: Bool { true }
  public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
  public required init?(coder: NSCoder) { super.init(coder: coder) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateCellGeometry()
  }
  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateCellGeometry()
  }
  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateCellGeometry()
  }
  private func updateCellGeometry() {
    let scale = window?.backingScaleFactor ?? 1
    session?.setCellSize(
      width: Int(ceil(cellSize.width * scale)), height: Int(ceil(cellSize.height * scale)))
  }

  public func bind(session: TerminalSession?) {
    guard self.session !== session || document != nil else { return }
    self.session?.setFocused(false)
    self.session?.onFrame = nil
    self.session?.setWantsFrames(false)
    document?.onFrame = nil
    document = nil
    self.session = session
    terminalFrame = session?.frame
    selection = nil
    mouseGesture = nil
    session?.onFrame = { [weak self] in self?.receive($0) }
    session?.setWantsFrames(isRenderingEnabled)
    if window?.firstResponder === self { session?.setFocused(true) }
    updateCellGeometry()
    updateColors()
  }
  public func bind(document: TerminalDocument) {
    guard self.document !== document || session != nil else { return }
    session?.onFrame = nil
    self.document?.onFrame = nil
    session = nil
    self.document = document
    terminalFrame = document.frame
    selection = nil
    mouseGesture = nil
    document.onFrame = { [weak self] in self?.receive($0) }
    updateColors()
  }
  private func receive(_ frame: TerminalFrame) {
    let previous = terminalFrame
    terminalFrame = frame
    updateBlinkTimer()
    guard isRenderingEnabled else { return }
    invalidateChangedRows(from: previous, to: frame)
  }

  /// Damage tracking: a frame that keeps its geometry invalidates only the
  /// rows whose cells changed plus the old and new cursor rows, so a cursor
  /// blink or one new line of output does not repaint the whole grid.
  private func invalidateChangedRows(from previous: TerminalFrame?, to frame: TerminalFrame) {
    guard let previous, previous.rows == frame.rows, previous.columns == frame.columns,
      previous.cells.count == frame.cells.count
    else {
      needsDisplay = true
      return
    }
    let size = cellSize
    var dirtyRows: [Int] = []
    for row in 0..<frame.rows {
      let range = (row * frame.columns)..<((row + 1) * frame.columns)
      if frame.cells[range] != previous.cells[range] { dirtyRows.append(row) }
    }
    if previous.cursorY != frame.cursorY || previous.cursorX != frame.cursorX
      || previous.cursorVisible != frame.cursorVisible
      || previous.cursorStyle != frame.cursorStyle
    {
      dirtyRows.append(previous.cursorY)
      dirtyRows.append(frame.cursorY)
    }
    guard !dirtyRows.isEmpty else { return }
    for row in Set(dirtyRows) where row >= 0 && row < frame.rows {
      setNeedsDisplay(rowRect(row, size: size))
    }
  }

  private func rowRect(_ row: Int, size: NSSize) -> NSRect {
    NSRect(x: 0, y: CGFloat(row) * size.height, width: bounds.width, height: size.height)
  }

  /// Blink toggles repaint only what blinks: the cursor cell, and every row
  /// only when the frame carries blinking cells.
  private func invalidateForBlink() {
    guard let frame = terminalFrame else { return }
    if frame.hasBlinkingCells {
      needsDisplay = true
      return
    }
    let size = cellSize
    setNeedsDisplay(rowRect(frame.cursorY, size: size))
  }
  private func updateBlinkTimer() {
    let blinking =
      terminalFrame.map {
        $0.cursorBlinking && $0.cursorVisible && session != nil || $0.hasBlinkingCells
      } ?? false
    guard isRenderingEnabled && blinking else {
      blinkTimer?.invalidate()
      blinkTimer = nil
      blinkVisible = true
      return
    }
    guard blinkTimer == nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.blinkVisible.toggle()
      self.invalidateForBlink()
    }
    blinkTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func updateColors() {
    session?.setColors(foreground: foreground, background: background)
    document?.setColors(foreground: foreground, background: background)
    if isRenderingEnabled { needsDisplay = true }
  }
  public override func becomeFirstResponder() -> Bool {
    session?.setFocused(true)
    return true
  }
  public override func resignFirstResponder() -> Bool {
    unmarkText()
    session?.setFocused(false)
    return true
  }
  public override func draw(_ dirtyRect: NSRect) {
    guard isRenderingEnabled, let frame = terminalFrame,
      let context = NSGraphicsContext.current?.cgContext
    else { return }
    background.setFill()
    dirtyRect.fill()
    let size = cellSize
    let fonts = fontVariants()
    // Text batching: consecutive single-width ASCII cells with the same font
    // and colour share one CTLine, positioned at the run's first cell. The
    // monospaced font advances ASCII by exactly one cell, so the grid holds;
    // any other cell (wide, non-ASCII, styled differently) still draws alone
    // in its own clipped cell so shaping can never shift its neighbours.
    var pendingRun: (start: Int, text: String, font: NSFont, color: NSColor, rect: NSRect)?
    func flushRun() {
      guard let run = pendingRun else { return }
      pendingRun = nil
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: run.text, attributes: [.font: run.font, .foregroundColor: run.color]))
      context.saveGState()
      context.clip(to: run.rect)
      context.translateBy(x: run.rect.minX, y: run.rect.minY + font.ascender)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = .zero
      CTLineDraw(line, context)
      context.restoreGState()
    }
    for row in 0..<frame.rows {
      let rowRect = NSRect(
        x: 0, y: CGFloat(row) * size.height, width: bounds.width, height: size.height)
      guard rowRect.intersects(dirtyRect) else { continue }
      for column in 0..<frame.columns {
        let index = row * frame.columns + column
        let cell = frame.cells[index]
        guard cell.width > 0 else { continue }
        let rect = NSRect(
          x: CGFloat(column) * size.width, y: CGFloat(row) * size.height,
          width: size.width * CGFloat(cell.width), height: size.height)
        guard rect.intersects(dirtyRect) else {
          flushRun()
          continue
        }
        let inverse = cell.flags & 16 != 0
        let selected = selection?.contains(index) == true
        let fg =
          selected
          ? NSColor.selectedTextColor
          : (inverse ? cell.background : cell.foreground).nsColor
        let bg =
          selected
          ? NSColor.selectedTextBackgroundColor
          : (inverse ? cell.foreground : cell.background).nsColor
        bg.setFill()
        rect.fill()
        guard cell.flags & 32 == 0, blinkVisible || cell.flags & 8 == 0 else {
          flushRun()
          continue
        }
        let cellFont = fonts[Int(cell.flags & 3)]
        let color = fg.withAlphaComponent(cell.flags & 4 != 0 ? 0.6 : 1)
        let isBlank = cell.text.allSatisfy(\.isWhitespace)
        let batchable =
          cell.width == 1 && cell.text.utf8.count == 1 && cell.text.utf8.first.map { $0 < 128 }
            == true
        if batchable {
          if var run = pendingRun, run.font == cellFont, run.color == color,
            run.start + run.text.utf8.count == column
          {
            run.text.append(cell.text)
            run.rect.size.width += rect.width
            pendingRun = run
          } else {
            flushRun()
            if !isBlank {
              pendingRun = (column, cell.text, cellFont, color, rect)
            }
          }
        } else {
          flushRun()
          if !isBlank {
            let line = CTLineCreateWithAttributedString(
              NSAttributedString(
                string: cell.text, attributes: [.font: cellFont, .foregroundColor: color]))
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY + font.ascender)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
          }
        }
        cell.underlineColor.nsColor.setStroke()
        if cell.underline > 0 {
          context.saveGState()
          if cell.underline == 4 { context.setLineDash(phase: 0, lengths: [1, 2]) }
          if cell.underline == 5 { context.setLineDash(phase: 0, lengths: [4, 2]) }
          if cell.underline == 3 {
            context.move(to: NSPoint(x: rect.minX, y: rect.maxY - 2))
            var x = rect.minX
            while x < rect.maxX {
              context.addLine(to: NSPoint(x: x + 1, y: rect.maxY - 3))
              context.addLine(to: NSPoint(x: x + 3, y: rect.maxY - 1))
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
      flushRun()
    }
    if frame.cursorVisible && session != nil && (blinkVisible || !frame.cursorBlinking) {
      var cursor = NSRect(
        x: CGFloat(frame.cursorX) * size.width, y: CGFloat(frame.cursorY) * size.height,
        width: size.width, height: size.height)
      foreground.withAlphaComponent(0.65).setFill()
      if frame.cursorStyle == 0 {
        cursor.size.width = 2
      } else if frame.cursorStyle == 2 {
        cursor.origin.y = cursor.maxY - 2
        cursor.size.height = 2
      }
      if frame.cursorStyle == 3 {
        foreground.setStroke()
        NSBezierPath(rect: cursor.insetBy(dx: 0.5, dy: 0.5)).stroke()
      } else {
        cursor.fill(using: .difference)
      }
    }
    if marked.length > 0 {
      marked.draw(
        at: NSPoint(x: CGFloat(frame.cursorX) * size.width, y: CGFloat(frame.cursorY) * size.height)
      )
    }
  }
  private func stroke(y: CGFloat, rect: NSRect, context: CGContext) {
    context.setLineWidth(1)
    context.move(to: NSPoint(x: rect.minX, y: y))
    context.addLine(to: NSPoint(x: rect.maxX, y: y))
    context.strokePath()
  }
  public override func keyDown(with event: NSEvent) {
    guard inputInterceptor?(event) != true else { return }
    replay(event: event)
  }
  /// Replays an event already considered by the configured mapping matcher.
  public func replay(event: NSEvent, to target: TerminalSession?) {
    if Self.isKeyRelease(event), localCommandKeys.remove(event.keyCode) != nil { return }
    if target === session {
      replay(event: event)
    } else if let target {
      encode(event, action: Self.isKeyRelease(event) ? 0 : nil, to: target)
    }
  }

  public static func isKeyRelease(_ event: NSEvent) -> Bool {
    guard event.type == .flagsChanged else { return event.type == .keyUp }
    // Device-dependent NSEvent bits distinguish left/right modifiers even
    // while the other side remains held.
    let mask: UInt
    switch event.keyCode {
    case 54: mask = 0x10
    case 55: mask = 0x08
    case 56: mask = 0x02
    case 57: mask = NSEvent.ModifierFlags.capsLock.rawValue
    case 58: mask = 0x20
    case 59: mask = 0x01
    case 60: mask = 0x04
    case 61: mask = 0x40
    case 62: mask = 0x2000
    default: return false
    }
    return event.modifierFlags.rawValue & mask == 0
  }

  public func replay(event: NSEvent) {
    if Self.isKeyRelease(event) {
      guard localCommandKeys.remove(event.keyCode) == nil else { return }
      encode(event, action: 0)
      return
    }
    if event.type == .flagsChanged {
      encode(event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
      localCommandKeys.insert(event.keyCode)
      copy(nil)
      return
    }
    if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
      localCommandKeys.insert(event.keyCode)
      paste(nil)
      return
    }
    guard session != nil else { return }
    if modifiers.contains(.control) || modifiers.contains(.command) {
      encode(event)
      return
    }
    interpretingEvent = event
    interpreted = false
    interpretKeyEvents([event])
    interpretingEvent = nil
    if !interpreted && !hasMarkedText() { encode(event) }
  }
  public override func keyUp(with event: NSEvent) {
    guard inputInterceptor?(event) != true else { return }
    replay(event: event)
  }
  public override func flagsChanged(with event: NSEvent) {
    guard inputInterceptor?(event) != true else { return }
    replay(event: event)
  }
  private func encode(_ event: NSEvent, action: Int32? = nil, to target: TerminalSession? = nil) {
    let raw = event.type == .flagsChanged ? "" : event.charactersIgnoringModifiers ?? ""
    let text =
      raw.unicodeScalars.contains {
        $0.value < 32 || (127...159).contains($0.value) || (0xF700...0xF8FF).contains($0.value)
      } ? "" : raw
    (target ?? session)?.key(
      code: event.keyCode, modifiers: Self.modifiers(event),
      action: action ?? (event.type == .keyDown && event.isARepeat ? 2 : 1), text: text,
      unshifted: raw.lowercased().unicodeScalars.first?.value ?? 0)
  }
  private static func modifiers(_ event: NSEvent) -> UInt16 {
    var result: UInt16 = 0
    if event.modifierFlags.contains(.shift) { result |= 1 }
    if event.modifierFlags.contains(.control) { result |= 2 }
    if event.modifierFlags.contains(.option) { result |= 4 }
    if event.modifierFlags.contains(.command) { result |= 8 }
    if event.modifierFlags.contains(.capsLock) { result |= 16 }
    return result
  }
  @objc public func copy(_ sender: Any?) {
    guard let frame = terminalFrame, let selection else { return }
    var result = ""
    for index in selection where index < frame.cells.count {
      if index > selection.lowerBound && index % frame.columns == 0 { result += "\n" }
      result += frame.cells[index].text
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(result, forType: .string)
  }
  @objc public func paste(_ sender: Any?) {
    if let text = NSPasteboard.general.string(forType: .string) { session?.paste(text) }
  }
  private func cell(at event: NSEvent) -> (column: Int, row: Int) {
    let point = convert(event.locationInWindow, from: nil)
    let size = cellSize
    return (
      max(0, min((terminalFrame?.columns ?? 1) - 1, Int(point.x / size.width))),
      max(0, min((terminalFrame?.rows ?? 1) - 1, Int(point.y / size.height)))
    )
  }
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
  }
  public override func mouseMoved(with event: NSEvent) {
    guard window?.isKeyWindow == true, terminalFrame?.mouseTracking == true,
      !event.modifierFlags.contains(.shift)
    else { return }
    forwardTerminalMouse(event, action: 2, button: 0)
  }
  private func link(at event: NSEvent) -> URL? {
    let point = convert(event.locationInWindow, from: nil)
    guard let frame = terminalFrame,
      point.x >= 0, point.y >= 0,
      point.x < CGFloat(frame.columns) * cellSize.width,
      point.y < CGFloat(frame.rows) * cellSize.height
    else { return nil }
    return frame.link(atColumn: Int(point.x / cellSize.width), row: Int(point.y / cellSize.height))
  }

  public override func mouseDown(with event: NSEvent) {
    onFocusRequested?()
    window?.makeFirstResponder(self)
    let cell = cell(at: event)
    if terminalFrame?.mouseTracking == true && !event.modifierFlags.contains(.shift) {
      mouseGesture = .reporting
      forwardTerminalMouse(event, action: 0, button: 1)
    } else {
      let start = cell.row * (terminalFrame?.columns ?? 1) + cell.column
      mouseGesture = .selecting(
        start: start, link: event.modifierFlags.contains(.shift) ? link(at: event) : nil,
        origin: event.locationInWindow, dragged: false)
      selection = start...start
      needsDisplay = true
    }
  }
  public override func mouseDragged(with event: NSEvent) {
    switch mouseGesture {
    case .selecting(let start, let link, let origin, let dragged):
      let cell = cell(at: event)
      let index = cell.row * (terminalFrame?.columns ?? 1) + cell.column
      mouseGesture = .selecting(
        start: start, link: link, origin: origin,
        dragged: dragged
          || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4)
      selection = min(start, index)...max(start, index)
      needsDisplay = true
    case .reporting:
      forwardTerminalMouse(event, action: 2, button: 1)
    case nil:
      break
    }
  }
  public override func mouseUp(with event: NSEvent) {
    defer { mouseGesture = nil }
    switch mouseGesture {
    case .reporting:
      forwardTerminalMouse(event, action: 1, button: 1)
    case .selecting(_, let destination?, let origin, false):
      guard hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) <= 4,
        link(at: event) == destination
      else { return }
      selection = nil
      needsDisplay = true
      openURL(destination)
    default:
      break
    }
  }
  public override func rightMouseDown(with event: NSEvent) {
    forwardMouse(event, action: 0, button: 2)
  }
  public override func rightMouseUp(with event: NSEvent) {
    forwardMouse(event, action: 1, button: 2)
  }
  public override func rightMouseDragged(with event: NSEvent) {
    forwardMouse(event, action: 2, button: 2)
  }
  public override func otherMouseDown(with event: NSEvent) {
    forwardMouse(event, action: 0, button: 3)
  }
  public override func otherMouseUp(with event: NSEvent) {
    forwardMouse(event, action: 1, button: 3)
  }
  public override func otherMouseDragged(with event: NSEvent) {
    forwardMouse(event, action: 2, button: 3)
  }
  private func forwardMouse(_ event: NSEvent, action: Int32, button: Int32) {
    guard terminalFrame?.mouseTracking == true else { return }
    if action == 0 {
      onFocusRequested?()
      window?.makeFirstResponder(self)
    }
    forwardTerminalMouse(event, action: action, button: button)
  }
  private func forwardTerminalMouse(_ event: NSEvent, action: Int32, button: Int32) {
    let point = convert(event.locationInWindow, from: nil)
    session?.mousePosition(
      action: action, button: button, modifiers: Self.modifiers(event),
      x: Double(max(0, point.x) / cellSize.width), y: Double(max(0, point.y) / cellSize.height))
  }
  public func scroll(lines: Int) {
    session?.scroll(lines: lines)
    document?.scroll(lines: lines)
  }
  public override func scrollWheel(with event: NSEvent) {
    let lines = Int(-event.scrollingDeltaY.rounded(.awayFromZero))
    if terminalFrame?.mouseTracking == true && !event.modifierFlags.contains(.shift) {
      for _ in 0..<min(64, abs(lines)) {
        forwardTerminalMouse(event, action: 0, button: lines < 0 ? 4 : 5)
      }
    } else {
      scroll(lines: lines)
    }
  }
  public func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
    interpreted = true
    if marked.length == 0, let event = interpretingEvent, text == event.characters {
      encode(event)
    } else {
      session?.send(Data(text.utf8))
    }
    unmarkText()
  }
  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked =
      (string as? NSAttributedString)
      ?? NSAttributedString(
        string: string as? String ?? "",
        attributes: [.font: font, .foregroundColor: foreground, .backgroundColor: background])
    markedSelection = selectedRange
    interpreted = true
    needsDisplay = true
  }
  public func unmarkText() {
    marked = NSAttributedString(string: "")
    needsDisplay = true
  }
  public func selectedRange() -> NSRange { markedSelection }
  public func markedRange() -> NSRange {
    marked.length > 0
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  public func hasMarkedText() -> Bool { marked.length > 0 }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.font, .foregroundColor, .backgroundColor, .underlineStyle]
  }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
    actualRange?.pointee = range
    return marked.attributedSubstring(from: range)
  }
  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = range
    let rect = NSRect(
      x: CGFloat(terminalFrame?.cursorX ?? 0) * cellSize.width,
      y: CGFloat(terminalFrame?.cursorY ?? 0) * cellSize.height, width: cellSize.width,
      height: cellSize.height)
    return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
  }
  public override func doCommand(by selector: Selector) {
    if let event = interpretingEvent {
      interpreted = true
      encode(event)
    }
  }
}
