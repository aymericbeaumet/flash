import AppKit

/// Watches the general pasteboard for changes and reports new text.
///
/// macOS exposes no pasteboard-change notification, so the only mechanism is
/// to compare `NSPasteboard.changeCount` (a monotonic integer the system bumps
/// on every write) against the last seen value. That makes this one of the few
/// places a poll is the only option — so it runs on the shared
/// `PollScheduler` rather than its own timer, and only while a plugin
/// subscribes to `clipboard.changed`.
///
/// This lives in the core on purpose: plugins must not poll. The clipboard
/// plugin instead subscribes to the `clipboard.changed` event the core emits
/// from this watcher's callback.
final class ClipboardMonitor {
  private let pasteboard: NSPasteboard
  private let onChange: (String) -> Void
  /// The 2 Hz poll runs on a utility queue: `changeCount` is a cheap read
  /// that never needs the main run loop (which hosts the keyboard tap), and
  /// only an actual change hops to main to read the payload.
  private let queue = DispatchQueue(label: "flash.clipboard", qos: .utility)
  private let scheduler: PollScheduler
  private var registered = false
  private var lastChangeCount: Int

  /// Pasteboard types that mark a payload as a password (`ConcealedType`) or
  /// auto-generated/transient (`TransientType`). Both are excluded from
  /// history so secrets never land in the clipboard plugin's store.
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  static let clientID = "core:clipboard"

  init(
    pasteboard: NSPasteboard = .general,
    scheduler: PollScheduler = .shared,
    onChange: @escaping (String) -> Void
  ) {
    self.pasteboard = pasteboard
    self.scheduler = scheduler
    self.onChange = onChange
    self.lastChangeCount = pasteboard.changeCount
  }

  func start(interval: TimeInterval = 0.5) {
    guard !registered else { return }
    registered = true
    scheduler.register(
      Self.clientID, everyMs: Int(interval * 1000), on: queue
    ) { [weak self] in self?.poll() }
  }

  func stop() {
    guard registered else { return }
    registered = false
    scheduler.unregister(Self.clientID)
  }

  private func poll() {
    let current = pasteboard.changeCount
    guard current != lastChangeCount else { return }
    lastChangeCount = current
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let types = self.pasteboard.types ?? []
      if types.contains(Self.concealedType) || types.contains(Self.transientType) { return }
      guard let text = self.pasteboard.string(forType: .string), !text.isEmpty else { return }
      self.onChange(text)
    }
  }

  deinit { stop() }
}
