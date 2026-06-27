import AppKit

/// Watches the general pasteboard for changes and reports new text.
///
/// macOS exposes no pasteboard-change notification, so the only mechanism is
/// to compare `NSPasteboard.changeCount` (a monotonic integer the system bumps
/// on every write) against the last seen value. Reading that integer is a
/// single cheap call, so a low-frequency main-runloop timer is sufficient and
/// never spawns a subprocess.
///
/// This lives in the core on purpose: plugins must not poll. The clipboard
/// plugin instead subscribes to the `clipboard.changed` event the core emits
/// from this watcher's callback.
final class ClipboardMonitor {
  private let pasteboard: NSPasteboard
  private let onChange: (String) -> Void
  private var timer: Timer?
  private var lastChangeCount: Int

  /// Pasteboard types that mark a payload as a password (`ConcealedType`) or
  /// auto-generated/transient (`TransientType`). Both are excluded from
  /// history so secrets never land in the clipboard plugin's store.
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  init(pasteboard: NSPasteboard = .general, onChange: @escaping (String) -> Void) {
    self.pasteboard = pasteboard
    self.onChange = onChange
    self.lastChangeCount = pasteboard.changeCount
  }

  func start(interval: TimeInterval = 0.5) {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      self?.poll()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    let current = pasteboard.changeCount
    guard current != lastChangeCount else { return }
    lastChangeCount = current

    let types = pasteboard.types ?? []
    if types.contains(Self.concealedType) || types.contains(Self.transientType) { return }
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    onChange(text)
  }

  deinit { stop() }
}
