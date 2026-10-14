import AppKit

extension FlashStatusTextColor {
  static func validated(_ raw: String) -> FlashStatusTextColor? {
    let word = raw.lowercased()
    if word == "default" || word == "terminal" { return .defaultForeground }
    if word == "label" { return .label }
    if let index = StatusFormatPalette.index(word) { return .palette(UInt8(index)) }
    if let rgb = StatusFormatPalette.rgb(word) { return .rgb(rgb) }
    return nil
  }

  static func parse(_ raw: String) -> FlashStatusTextColor {
    validated(raw) ?? .defaultForeground
  }

  /// Flash supplies terminal defaults; explicit colours use the native palette.
  /// Colours are immutable, so each distinct value is made once: the run
  /// renderer asks for every visible run's colours on every tick.
  static func nsColor(_ color: FlashStatusTextColor) -> NSColor {
    switch color {
    case .defaultForeground:
      return OverlayPanel.tmuxGrey245
    case .defaultBackground:
      return OverlayPanel.nordPolarNight0
    case .rgb, .label, .palette:
      colourCacheLock.lock()
      defer { colourCacheLock.unlock() }
      if let cached = colourCache[color] { return cached }
      let made = makeNSColor(color)
      colourCache[color] = made
      return made
    }
  }

  /// `nsColor(color).cgColor`, cached with it.
  static func cgColor(_ color: FlashStatusTextColor) -> CGColor {
    colourCacheLock.lock()
    defer { colourCacheLock.unlock() }
    if let cached = cgColourCache[color] { return cached }
    let nsColor: NSColor
    switch color {
    case .defaultForeground: nsColor = OverlayPanel.tmuxGrey245
    case .defaultBackground: nsColor = OverlayPanel.nordPolarNight0
    default:
      if let cached = colourCache[color] {
        nsColor = cached
      } else {
        nsColor = makeNSColor(color)
        colourCache[color] = nsColor
      }
    }
    let made = nsColor.cgColor
    cgColourCache[color] = made
    return made
  }

  private static let colourCacheLock = NSLock()
  private static var colourCache: [FlashStatusTextColor: NSColor] = [:]
  private static var cgColourCache: [FlashStatusTextColor: CGColor] = [:]

  private static func makeNSColor(_ color: FlashStatusTextColor) -> NSColor {
    switch color {
    case .defaultForeground:
      return OverlayPanel.tmuxGrey245
    case .defaultBackground:
      return OverlayPanel.nordPolarNight0
    case .rgb(let value):
      return NSColor(
        calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1)
    case .label:
      return makeNSColor(.rgb(0xEBCB8B))
    case .palette(let n):
      return Self.xterm(n)
    }
  }

  /// Plain xterm-256: 16 ANSI entries, a 6×6×6 colour cube, 24 greys.
  static func xterm(_ n: UInt8) -> NSColor {
    let rgb = StatusFormatPalette.rgb(index: Int(n)) ?? 0
    return NSColor(
      calibratedRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }
}
