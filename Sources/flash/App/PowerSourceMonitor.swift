import Foundation
import IOKit.ps

/// Emits when macOS reports a power-source change. This is the event-driven
/// replacement for plugin-side battery polling; plugins that care about
/// battery state can subscribe to `core:power.changed` and sample once.
final class PowerSourceMonitor {
  private var source: CFRunLoopSource?
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  func start() {
    guard source == nil else { return }
    let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    guard
      let unmanaged = IOPSNotificationCreateRunLoopSource(
        { raw in
          guard let raw else { return }
          let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(raw).takeUnretainedValue()
          monitor.onChange()
        },
        context)
    else { return }
    let source = unmanaged.takeRetainedValue()
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  }

  func stop() {
    guard let source else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    self.source = nil
  }

  deinit { stop() }
}
