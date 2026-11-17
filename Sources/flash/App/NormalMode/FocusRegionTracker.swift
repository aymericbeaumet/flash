import CoreGraphics
import Foundation

/// The cached `FocusRegion` of the focused app. Every focus change the AX
/// observers report (`AppMonitor.focusedElementMayHaveChanged`: an app
/// activation, `AXFocusedUIElementChanged`, a window change or the focused
/// element's destruction) drops the cached reading and reads the focused
/// element again off the main loop; a reading from before the latest change
/// is never kept. A keypress reads the cache: a command that arrives while a
/// read is pending waits for it, in order, instead of guessing from a stale
/// region. Main thread only.
final class FocusRegionTracker {
  /// One read of the focused element: its region, and the frame of the
  /// scroll area around it (NSScreen coordinates), where a scroll lands when
  /// the pointer is outside the focused window.
  struct Reading: Equatable {
    var region: FocusRegion
    var scrollFrame: CGRect?
    /// The focused element's identity (`CFHash`), which `TextScope` and
    /// VISUAL compare to the one they act on: another element means the
    /// focus moved.
    var element: Int?

    init(region: FocusRegion, scrollFrame: CGRect? = nil, element: Int? = nil) {
      self.region = region
      self.scrollFrame = scrollFrame
      self.element = element
    }

    /// Unknown focus: a page, where Flash scrolls and types nothing.
    static let unknown = Reading(region: .document)
  }

  /// Reads `pid`'s focused element off the main loop and delivers on main.
  typealias Read = (pid_t, @escaping (Reading) -> Void) -> Void

  private let read: Read
  /// The app the cache describes.
  private(set) var pid: pid_t?
  /// Nil until the read after the latest focus change lands.
  private(set) var reading: Reading?
  private var generation: UInt64 = 0
  private var readInFlight = false
  /// A reading landed for the latest focus.
  var onSettled: (() -> Void)?
  private var waiters: [(pid: pid_t, body: (Reading) -> Void)] = []

  init(read: @escaping Read) {
    self.read = read
  }

  /// Focus may have moved in `pid`: forget the region and read it again.
  func focusMayHaveChanged(pid: pid_t) {
    self.pid = pid
    reading = nil
    generation &+= 1
    startRead()
  }

  /// The reading for `pid`, at once when the cache holds one, else once the
  /// pending read lands. A reading for another app than the one asked about
  /// (the focus moved on meanwhile) is `Reading.unknown`.
  func withReading(for pid: pid_t, _ body: @escaping (Reading) -> Void) {
    if self.pid == pid, let reading { return body(reading) }
    if self.pid != pid { focusMayHaveChanged(pid: pid) }
    waiters.append((pid, body))
  }

  /// Whether a read for the latest focus change is still pending.
  var isReading: Bool { pid != nil && reading == nil }

  /// The reading the cache holds for `pid` now, without waiting.
  func cachedReading(for pid: pid_t) -> Reading? {
    self.pid == pid ? reading : nil
  }

  private func startRead() {
    guard !readInFlight, let pid else { return }
    readInFlight = true
    let generation = self.generation
    read(pid) { [weak self] reading in
      guard let self else { return }
      self.readInFlight = false
      // The focus moved while this read ran: it describes what was focused
      // before, so read again.
      guard generation == self.generation, pid == self.pid else { return self.startRead() }
      self.reading = reading
      self.onSettled?()
      let ready = self.waiters
      self.waiters.removeAll()
      for waiter in ready {
        waiter.body(waiter.pid == pid ? reading : .unknown)
      }
    }
  }
}
