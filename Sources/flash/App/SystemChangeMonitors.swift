import AppKit
import SystemConfiguration

/// An OS change source behind one host event. It costs nothing until
/// started, and `HostEventSources` starts it only while a plugin listens.
protocol HostEventSource: AnyObject {
  func start()
  func stop()
}

/// The host event monitors, each run exactly while some plugin's `listen`
/// matches its event: a system nobody subscribes to is never observed.
/// Main thread only.
final class HostEventSources {
  private let factories: [String: () -> any HostEventSource]
  private var running: [String: any HostEventSource] = [:]

  init(_ factories: [String: () -> any HostEventSource]) {
    self.factories = factories
  }

  /// Event names whose monitor runs, sorted.
  var runningEvents: [String] { running.keys.sorted() }

  /// Start the monitor of each event that gained a listener, stop the one of
  /// each event that lost its last.
  func reconcile(listening: (String) -> Bool) {
    for event in factories.keys.sorted() {
      let wanted = listening(event)
      guard wanted != (running[event] != nil) else { continue }
      if wanted, let source = factories[event]?() {
        FlashLog.debug("[events] monitor started event=\(event)")
        running[event] = source
        source.start()
      } else {
        FlashLog.debug("[events] monitor stopped event=\(event): no listener")
        running.removeValue(forKey: event)?.stop()
      }
    }
  }

  func stopAll() {
    for source in running.values { source.stop() }
    running.removeAll()
  }
}

/// Collapses a burst of OS notifications into one signal: the first starts
/// a window of `delayMs`, and the signal fires once when it closes, however
/// many notifications arrived inside it. A bounded one-shot per burst.
final class CoalescedSignal {
  private let queue: DispatchQueue
  private let delayMs: Int
  private let action: () -> Void
  /// Queue-confined: the window open now, nil when none is.
  private var pending: DispatchWorkItem?

  init(queue: DispatchQueue, delayMs: Int, action: @escaping () -> Void) {
    self.queue = queue
    self.delayMs = delayMs
    self.action = action
  }

  func signal() {
    queue.async { [self] in
      guard pending == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.pending = nil
        self.action()
      }
      pending = work
      queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }
  }

  func cancel() {
    queue.sync {
      pending?.cancel()
      pending = nil
    }
  }
}

/// `core:network.changed`: the System Configuration dynamic store reports a
/// change to an interface's link or addresses, or to the global primary
/// interface, route or DNS. The signal carries nothing — no interface, no
/// address, no network name — so plugins re-read what they show.
final class NetworkChangeMonitor: HostEventSource {
  /// Global primary interface/router and resolver state.
  static let watchedKeys = [
    "State:/Network/Global/IPv4",
    "State:/Network/Global/IPv6",
    "State:/Network/Global/DNS",
  ]
  /// Every interface's link state and addresses.
  static let watchedPatterns = ["State:/Network/Interface/[^/]+/(Link|IPv4|IPv6)"]
  static let coalesceMs = 500

  /// Handed to the store as its unretained `info`; the monitor owns it and
  /// outlives every callback (see `stop`).
  private final class Relay {
    weak var monitor: NetworkChangeMonitor?
  }

  private let queue = DispatchQueue(label: "flash.events.network", qos: .utility)
  private let relay = Relay()
  private let signal: CoalescedSignal
  private var store: SCDynamicStore?

  init(onChange: @escaping () -> Void) {
    signal = CoalescedSignal(queue: queue, delayMs: Self.coalesceMs, action: onChange)
    relay.monitor = self
  }

  func start() {
    guard store == nil else { return }
    var context = SCDynamicStoreContext(
      version: 0, info: Unmanaged.passUnretained(relay).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    guard
      let store = SCDynamicStoreCreate(
        nil, "com.flash.app.network-events" as CFString,
        { _, _, info in
          guard let info else { return }
          Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().monitor?.changed()
        }, &context),
      SCDynamicStoreSetNotificationKeys(
        store, Self.watchedKeys as CFArray, Self.watchedPatterns as CFArray),
      SCDynamicStoreSetDispatchQueue(store, queue)
    else {
      FlashLog.warn(
        "[events] network change monitor unavailable: \(String(cString: SCErrorString(SCError())))")
      return
    }
    self.store = store
  }

  /// Detaching the queue stops new callbacks; draining it waits out one
  /// already running, so the relay never outlives a callback that uses it.
  func stop() {
    guard let store else { return }
    SCDynamicStoreSetDispatchQueue(store, nil)
    queue.sync {}
    self.store = nil
    signal.cancel()
  }

  /// Runs on `queue`.
  func changed() { signal.signal() }

  /// Owners call `stop`; this only detaches, since the last release could
  /// come from anywhere.
  deinit {
    if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
  }
}

/// `core:volumes.changed`: a volume mounted, unmounted or was renamed. The
/// signal carries no volume name or path.
final class VolumeChangeMonitor: HostEventSource {
  static let notifications: [Notification.Name] = [
    NSWorkspace.didMountNotification,
    NSWorkspace.didUnmountNotification,
    NSWorkspace.didRenameVolumeNotification,
  ]
  static let coalesceMs = 500

  private let center: NotificationCenter
  private let signal: CoalescedSignal
  private var tokens: [NSObjectProtocol] = []

  init(
    center: NotificationCenter = NSWorkspace.shared.notificationCenter,
    coalesceMs: Int = VolumeChangeMonitor.coalesceMs,
    onChange: @escaping () -> Void
  ) {
    self.center = center
    signal = CoalescedSignal(
      queue: DispatchQueue(label: "flash.events.volumes", qos: .utility), delayMs: coalesceMs,
      action: onChange)
  }

  func start() {
    guard tokens.isEmpty else { return }
    tokens = Self.notifications.map { name in
      center.addObserver(forName: name, object: nil, queue: nil) { [signal] _ in signal.signal() }
    }
  }

  func stop() {
    for token in tokens { center.removeObserver(token) }
    tokens.removeAll()
    signal.cancel()
  }

  deinit {
    for token in tokens { center.removeObserver(token) }
  }
}
