import AppKit
import CFlashTerminal
import CoreText
import QuartzCore

/// Draws a terminal frame with one Core Animation layer per row, so a frame
/// repaints exactly the rows whose contents changed; AppKit would merge
/// several `setNeedsDisplay(_:)` rects of a layer-backed view into their
/// bounding box. The cursor and blinking text are separate layers whose
/// opacity Core Animation blinks in the render server: no timer and no
/// redraw while they blink.
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
      guard font != oldValue else { return }
      renderer.font = font
      invalidateAllRows()
      updateCellGeometry()
    }
  }
  public var foreground: NSColor = .white { didSet { updateColors() } }
  public var background: NSColor = .black { didSet { updateColors() } }
  /// Whether the cursor cell is painted. A hover preview is a rendered
  /// document, not a surface the user types into, and its pager parks a
  /// cursor on the prompt row — which the inverted cursor fill turns into a
  /// stray light block. The popup controller enables this only once the
  /// surface actually takes keyboard focus.
  public var drawsCursor = true {
    didSet {
      guard drawsCursor != oldValue else { return }
      refresh()
    }
  }
  public var isRenderingEnabled = false {
    didSet {
      session?.setWantsFrames(isRenderingEnabled)
      if isRenderingEnabled != oldValue { invalidateAllRows() }
    }
  }
  public var cellSize: NSSize { renderer.cellSize }
  /// The cell a view drawing with `font` uses, without creating one: sizes a
  /// hidden session's grid before any view binds it.
  public static func cellSize(for font: NSFont) -> NSSize { TerminalRenderer.cellSize(for: font) }
  public private(set) var terminalFrame: TerminalFrame?
  /// Called after each frame the bound session publishes is shown.
  public var onFrameReceived: (() -> Void)?
  private weak var session: TerminalSession?
  private var selection: ClosedRange<Int>? {
    didSet {
      guard selection != oldValue else { return }
      for range in [oldValue, selection].compactMap({ $0 }) { invalidateRows(covering: range) }
      refresh()
    }
  }
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

  private let renderer = TerminalRenderer(
    font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  private lazy var painter = TerminalLayerPainter(view: self)
  private let gridLayer = CALayer()
  private var rowLayers: [TerminalRowLayer] = []
  private let cursorLayer = CALayer()
  private let markedLayer = CALayer()
  /// Bumped by changes every row depends on: font, colours, scale.
  private var renderEpoch = 0
  private var palette: TerminalRenderer.Palette?
  private var cursorState: CursorState?
  /// What the cursor layer last drew: its cell's row and the render epoch.
  private var cursorDrawn: (row: TerminalRow, column: Int, epoch: Int)?
  /// Blinking text shares one phase, anchored when the view was created.
  private let blinkEpoch = CACurrentMediaTime()

  private struct CursorState: Equatable {
    var column: Int
    var row: Int
    var style: Int
    var blinking: Bool
  }

  public override var acceptsFirstResponder: Bool { true }
  public override var isFlipped: Bool { true }
  public override var wantsUpdateLayer: Bool { true }
  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUp()
  }
  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    setUp()
  }
  private func setUp() {
    wantsLayer = true
    // Row layers extend to the frame's full height; a clipped prompt row stays hidden.
    clipsToBounds = true
    renderer.font = font
    for layer in [gridLayer, cursorLayer, markedLayer] { layer.delegate = painter }
    gridLayer.anchorPoint = .zero
    cursorLayer.isHidden = true
    markedLayer.isHidden = true
    attachLayers()
  }
  private func attachLayers() {
    guard let layer, gridLayer.superlayer !== layer else { return }
    layer.addSublayer(gridLayer)
    layer.addSublayer(cursorLayer)
    layer.addSublayer(markedLayer)
  }
  public override func updateLayer() {
    layer?.backgroundColor = background.cgColor
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachLayers()
    updateScale()
    updateCellGeometry()
  }
  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
    updateCellGeometry()
  }
  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    refresh()
    updateCellGeometry()
  }
  private func updateCellGeometry() {
    let scale = window?.backingScaleFactor ?? 1
    session?.setCellSize(
      width: Int(ceil(cellSize.width * scale)), height: Int(ceil(cellSize.height * scale)))
  }
  private func updateScale() {
    let scale = window?.backingScaleFactor ?? 2
    guard scale != cursorLayer.contentsScale else { return }
    for layer in [cursorLayer, markedLayer] { layer.contentsScale = scale }
    invalidateAllRows()
  }

  public func bind(session: TerminalSession?) {
    guard self.session !== session else { return }
    self.session?.setFocused(false)
    self.session?.onFrame = nil
    self.session?.setWantsFrames(false)
    self.session = session
    terminalFrame = session?.currentFrame()
    selection = nil
    mouseGesture = nil
    cursorState = nil
    session?.onFrame = { [weak self] in self?.receive($0) }
    session?.setWantsFrames(isRenderingEnabled)
    if window?.firstResponder === self { session?.setFocused(true) }
    updateCellGeometry()
    session?.setColors(foreground: foreground, background: background)
    refresh()
  }
  func receive(_ frame: TerminalFrame) {
    terminalFrame = frame
    refresh()
    onFrameReceived?()
  }
  private func updateColors() {
    session?.setColors(foreground: foreground, background: background)
    needsDisplay = true
    invalidateAllRows()
  }
  private func invalidateAllRows() {
    renderEpoch += 1
    palette = nil
    cursorState = nil
    refresh()
  }
  private func invalidateRows(covering range: ClosedRange<Int>) {
    guard let columns = terminalFrame?.columns, columns > 0 else { return }
    for row in (range.lowerBound / columns)...(range.upperBound / columns)
    where row < rowLayers.count {
      rowLayers[row].drawnEpoch = -1
    }
  }
  private func currentPalette() -> TerminalRenderer.Palette {
    if let palette { return palette }
    let value = TerminalRenderer.Palette(
      background: background.cgColor,
      selectedForeground: NSColor.selectedTextColor.cgColor,
      selectedBackground: NSColor.selectedTextBackgroundColor.cgColor)
    palette = value
    return value
  }

  /// Brings the layers in line with the current frame: rows whose contents,
  /// selection or configuration changed are marked for display, every other
  /// row keeps its rasterised contents.
  private func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard isRenderingEnabled, let frame = terminalFrame else {
      gridLayer.isHidden = true
      cursorLayer.isHidden = true
      markedLayer.isHidden = true
      return
    }
    gridLayer.isHidden = false
    let size = cellSize
    let scale = window?.backingScaleFactor ?? 2
    while rowLayers.count > frame.rows { rowLayers.removeLast().removeFromSuperlayer() }
    while rowLayers.count < frame.rows {
      let layer = TerminalRowLayer()
      layer.delegate = painter
      layer.index = rowLayers.count
      gridLayer.addSublayer(layer)
      rowLayers.append(layer)
    }
    gridLayer.frame = CGRect(
      x: 0, y: 0, width: bounds.width, height: size.height * CGFloat(frame.rows))
    for (index, layer) in rowLayers.enumerated() {
      let rect = CGRect(
        x: 0, y: CGFloat(index) * size.height, width: bounds.width, height: size.height)
      if layer.frame != rect { layer.frame = rect }
      if layer.contentsScale != scale {
        layer.contentsScale = scale
        layer.drawnEpoch = -1
      }
      let row = frame.grid[index]
      if layer.drawnEpoch != renderEpoch || layer.drawn != row {
        layer.drawn = row
        layer.drawnEpoch = renderEpoch
        layer.setNeedsDisplay()
        layer.updateBlinking(row.hasBlinkingCells, painter: painter, epoch: blinkEpoch)
      }
    }
    updateCursor(frame)
    updateMarkedText(frame)
  }

  private func updateCursor(_ frame: TerminalFrame) {
    guard drawsCursor, frame.cursorVisible, session != nil, frame.cursorY < frame.rows,
      frame.cursorX < frame.columns
    else {
      cursorLayer.isHidden = true
      cursorLayer.removeAnimation(forKey: "blink")
      cursorState = nil
      cursorDrawn = nil
      return
    }
    let size = cellSize
    let cell = frame.grid[frame.cursorY].cells[frame.cursorX]
    cursorLayer.frame = CGRect(
      x: CGFloat(frame.cursorX) * size.width, y: CGFloat(frame.cursorY) * size.height,
      width: size.width * CGFloat(max(1, cell.width)), height: size.height)
    cursorLayer.isHidden = false
    let row = frame.grid[frame.cursorY]
    if cursorDrawn.map({ $0.row != row || $0.column != frame.cursorX || $0.epoch != renderEpoch })
      ?? true
    {
      cursorDrawn = (row, frame.cursorX, renderEpoch)
      cursorLayer.setNeedsDisplay()
    }
    let state = CursorState(
      column: frame.cursorX, row: frame.cursorY, style: frame.cursorStyle,
      blinking: frame.cursorBlinking)
    guard state != cursorState else { return }
    cursorState = state
    cursorDrawn = (row, frame.cursorX, renderEpoch)
    cursorLayer.setNeedsDisplay()
    // Moving restarts the blink visible, so the cursor stays solid while typing.
    cursorLayer.removeAnimation(forKey: "blink")
    if frame.cursorBlinking {
      cursorLayer.add(
        Self.blinkAnimation(beginTime: CACurrentMediaTime()), forKey: "blink")
    }
  }

  static func blinkAnimation(beginTime: CFTimeInterval) -> CAAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = [1, 0]
    animation.keyTimes = [0, 0.5]
    animation.calculationMode = .discrete
    animation.duration = 1
    animation.repeatCount = .infinity
    animation.beginTime = beginTime
    animation.isRemovedOnCompletion = false
    return animation
  }

  private func updateMarkedText(_ frame: TerminalFrame) {
    guard marked.length > 0 else {
      markedLayer.isHidden = true
      return
    }
    let size = cellSize
    markedLayer.frame = CGRect(
      origin: CGPoint(
        x: CGFloat(frame.cursorX) * size.width, y: CGFloat(frame.cursorY) * size.height),
      size: marked.size())
    markedLayer.isHidden = false
    markedLayer.setNeedsDisplay()
  }

  fileprivate func paint(_ layer: CALayer, in context: CGContext) {
    guard let frame = terminalFrame else { return }
    let palette = currentPalette()
    if let row = layer as? TerminalRowLayer {
      guard row.index < frame.rows else { return }
      renderer.draw(
        frame.grid[row.index], frameBackground: frame.background,
        selection: selectedColumns(inRow: row.index, frame: frame), part: .base, palette: palette,
        width: layer.bounds.width, in: context)
    } else if let row = (layer.superlayer as? TerminalRowLayer), layer === row.blinkLayer {
      guard row.index < frame.rows else { return }
      renderer.draw(
        frame.grid[row.index], frameBackground: frame.background,
        selection: selectedColumns(inRow: row.index, frame: frame), part: .blinking,
        palette: palette, width: layer.bounds.width, in: context)
    } else if layer === cursorLayer {
      paintCursor(frame, in: context)
    } else if layer === markedLayer {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      marked.draw(at: .zero)
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  private func paintCursor(_ frame: TerminalFrame, in context: CGContext) {
    guard frame.cursorY < frame.rows, frame.cursorX < frame.columns else { return }
    let bounds = cursorLayer.bounds
    let row = frame.grid[frame.cursorY]
    let cell = row.cells[frame.cursorX]
    let inverse = cell.flags & 16 != 0
    let cellBackground = TerminalColor(inverse ? cell.foreground : cell.background)
    let under = cellBackground == frame.background ? background : cellBackground.nsColor
    let fill = (under.usingColorSpace(.sRGB) ?? under).blended(withFraction: 0.65, of: foreground)
    switch frame.cursorStyle {
    case 0:
      context.setFillColor(foreground.withAlphaComponent(0.65).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height))
    case 2:
      context.setFillColor(foreground.withAlphaComponent(0.65).cgColor)
      context.fill(CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2))
    case 3:
      context.setStrokeColor(foreground.cgColor)
      context.setLineWidth(1)
      context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    default:
      // A block inverts the cell: the text takes the colour under the cursor.
      context.setFillColor((fill ?? foreground).cgColor)
      context.fill(bounds)
      renderer.drawGlyph(of: row, column: frame.cursorX, color: under.cgColor, in: context)
    }
  }

  private func selectedColumns(inRow row: Int, frame: TerminalFrame) -> Range<Int>? {
    guard let selection else { return nil }
    let start = row * frame.columns
    let lower = max(selection.lowerBound, start)
    let upper = min(selection.upperBound + 1, start + frame.columns)
    return lower < upper ? (lower - start)..<(upper - start) : nil
  }

  /// Draws the rows intersecting `rect` of the current frame into a flipped
  /// context, blinking text visible — the same drawing the row layers record.
  func render(in context: CGContext, rect: NSRect) {
    guard let frame = terminalFrame else { return }
    let size = cellSize
    let palette = currentPalette()
    let first = max(0, Int((rect.minY / size.height).rounded(.down)))
    let last = min(frame.rows - 1, Int((rect.maxY / size.height).rounded(.up)) - 1)
    guard first <= last else { return }
    for index in first...last {
      context.saveGState()
      context.translateBy(x: 0, y: CGFloat(index) * size.height)
      let selection = selectedColumns(inRow: index, frame: frame)
      for part in [TerminalRenderer.Part.base, .blinking] {
        renderer.draw(
          frame.grid[index], frameBackground: frame.background, selection: selection, part: part,
          palette: palette, width: bounds.width, in: context)
      }
      context.restoreGState()
    }
  }

  /// Rows marked for display and not yet drawn, for tests and benchmarks.
  var rowsNeedingDisplay: [Int] {
    rowLayers.indices.filter { rowLayers[$0].needsDisplay() }
  }
  /// Draws every pending row layer now, as a Core Animation commit would.
  func displayPendingRows() {
    for layer in rowLayers { layer.displayIfNeeded() }
  }
  var cursorBlinkAnimation: CAAnimation? { cursorLayer.animation(forKey: "blink") }
  func blinkAnimation(inRow row: Int) -> CAAnimation? {
    row < rowLayers.count ? rowLayers[row].blinkLayer?.animation(forKey: "blink") : nil
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
    if let frame = terminalFrame, isRenderingEnabled { updateMarkedText(frame) }
  }
  public func unmarkText() {
    marked = NSAttributedString(string: "")
    if let frame = terminalFrame, isRenderingEnabled { updateMarkedText(frame) }
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

/// One terminal row. `drawn` and `drawnEpoch` record what the layer was last
/// asked to display, so an unchanged row is never redrawn.
final class TerminalRowLayer: CALayer {
  var index = 0
  var drawn: TerminalRow?
  var drawnEpoch = -1
  private(set) var blinkLayer: CALayer?

  override init() {
    super.init()
    isOpaque = true
    drawsAsynchronously = true
    needsDisplayOnBoundsChange = true
    anchorPoint = .zero
  }
  override init(layer: Any) {
    super.init(layer: layer)
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  override func layoutSublayers() {
    super.layoutSublayers()
    blinkLayer?.frame = bounds
  }

  /// Blinking cells draw in a transparent sublayer whose opacity blinks on a
  /// shared phase; the row itself never redraws for a blink.
  func updateBlinking(_ blinking: Bool, painter: TerminalLayerPainter, epoch: CFTimeInterval) {
    guard blinking else {
      blinkLayer?.removeFromSuperlayer()
      blinkLayer = nil
      return
    }
    let layer =
      blinkLayer
      ?? {
        let layer = CALayer()
        layer.delegate = painter
        layer.anchorPoint = .zero
        layer.drawsAsynchronously = true
        layer.needsDisplayOnBoundsChange = true
        layer.add(TerminalView.blinkAnimation(beginTime: epoch), forKey: "blink")
        addSublayer(layer)
        blinkLayer = layer
        return layer
      }()
    layer.frame = bounds
    layer.contentsScale = contentsScale
    layer.setNeedsDisplay()
  }
}

/// Layer delegate for the view's sublayers: draws through the view and
/// disables every implicit animation.
final class TerminalLayerPainter: NSObject, CALayerDelegate {
  weak var view: TerminalView?
  init(view: TerminalView) { self.view = view }
  func draw(_ layer: CALayer, in context: CGContext) { view?.paint(layer, in: context) }
  func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}
