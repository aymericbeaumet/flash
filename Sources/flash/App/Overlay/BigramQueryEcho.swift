import AppKit
import QuartzCore

/// The two characters typed after `mouse_bigram`, drawn as a small chip by the
/// pointer. Empty slots are middle dots, so the chip is not a "no targets"
/// banner: zero matches leave it up and stay silent.
enum BigramQueryEcho {
  static func text(for query: String) -> String {
    switch query.count {
    case 0: return "\u{00B7}\u{00B7}"
    case 1: return query + "\u{00B7}"
    default: return String(query.prefix(2))
    }
  }
}

extension OverlayPanel {
  func setBigramQueryEcho(_ query: String?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if let query {
      bigramQueryEcho = makeBigramQueryEcho(BigramQueryEcho.text(for: query))
      transientContentVisible = true
    } else {
      bigramQueryEcho = nil
    }
    renderPersistentContent()
    if query != nil { captureKeyboardInput() }
  }

  /// Drops the chip without redrawing. `display` and `hide` rebuild the layer
  /// tree themselves; a later `renderPersistentContent` must not put it back.
  func clearBigramQueryEcho() {
    bigramQueryEcho = nil
  }

  private func makeBigramQueryEcho(_ text: String) -> CALayer {
    let panel = ensurePanelFrame()
    let pointer = NSEvent.mouseLocation
    let size = CGSize(width: 36, height: 22)
    var origin = CGPoint(
      x: pointer.x - panel.minX + 12, y: pointer.y - panel.minY + 12)
    origin.x = min(max(0, origin.x), max(0, panel.width - size.width))
    origin.y = min(max(0, origin.y), max(0, panel.height - size.height))
    let screen =
      NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2

    let chip = CALayer()
    chip.frame = CGRect(origin: origin, size: size)
    chip.backgroundColor = Self.nordPolarNight0.cgColor
    chip.cornerRadius = 4
    chip.borderWidth = 1
    chip.borderColor = Self.nordFrost2CG
    chip.contentsScale = scale
    chip.actions = Self.noActions

    let label = CATextLayer()
    label.string = text
    label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    label.fontSize = 13
    label.foregroundColor = Self.nordSnowStorm2CG
    label.alignmentMode = .center
    label.contentsScale = scale
    label.frame = CGRect(x: 0, y: 3, width: size.width, height: 16)
    label.actions = Self.noActions
    chip.addSublayer(label)
    return chip
  }
}
