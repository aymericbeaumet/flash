import Foundation

/// One background thread whose run loop hosts every `AXObserver` source.
///
/// AX notifications arrive as run-loop source callbacks on whichever loop
/// holds the observer's source. With the source on the main loop, an app in
/// an event storm (Firefox emits >1000 `AXUIElementDestroyed`/s while
/// rendering) wakes the main thread once per notification, competing with the
/// keyboard tap for the input budget. Hosting the sources here keeps the
/// callbacks off main entirely; `AppMonitor` coalesces a burst into one
/// main-thread hop and processes the batch there, so the dirty-token /
/// storm-detection contract is unchanged.
final class AXObserverThread {
  static let shared = AXObserverThread()

  private(set) var runLoop: CFRunLoop!
  private let thread: Thread

  private init() {
    let ready = DispatchSemaphore(value: 0)
    var loop: CFRunLoop?
    thread = Thread {
      loop = CFRunLoopGetCurrent()
      // A live port keeps the loop from returning when no observer is
      // installed (e.g. before the first focus change).
      RunLoop.current.add(NSMachPort(), forMode: .default)
      ready.signal()
      while true { CFRunLoopRun() }
    }
    thread.name = "flash.ax.observer"
    thread.qualityOfService = .userInitiated
    thread.start()
    ready.wait()
    runLoop = loop
  }

  func add(_ source: CFRunLoopSource) {
    CFRunLoopAddSource(runLoop, source, .defaultMode)
    CFRunLoopWakeUp(runLoop)
  }

  func remove(_ source: CFRunLoopSource) {
    CFRunLoopRemoveSource(runLoop, source, .defaultMode)
  }
}
