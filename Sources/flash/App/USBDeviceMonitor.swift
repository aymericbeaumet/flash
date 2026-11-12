import Foundation
import IOKit
import IOKit.usb

/// `core:usb.attached` and `core:usb.detached`: IOKit's matching
/// notifications for USB devices, observed only while a plugin or an event
/// monitor listens (`HostEventSources`). Devices already connected when it
/// starts are not announced. The payload names the device by its vendor and
/// product ids and product name, never its serial number. Main thread only.
final class USBDeviceMonitor: HostEventSource {
  /// Handed to IOKit as the unretained refcon; the monitor owns it and
  /// tears the notifications down before it goes.
  private final class Relay {
    weak var monitor: USBDeviceMonitor?
  }

  private let relay = Relay()
  private let emit: (HostEvent, [String: Any]) -> Void
  private var port: IONotificationPortRef?
  private var attached: io_iterator_t = 0
  private var detached: io_iterator_t = 0

  init(emit: @escaping (HostEvent, [String: Any]) -> Void) {
    self.emit = emit
    relay.monitor = self
  }

  func start() {
    guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    IONotificationPortSetDispatchQueue(port, .main)
    self.port = port
    let refcon = Unmanaged.passUnretained(relay).toOpaque()
    let callback: IOServiceMatchingCallback = { refcon, iterator in
      guard let refcon else { return }
      Unmanaged<Relay>.fromOpaque(refcon).takeUnretainedValue().monitor?.drain(iterator)
    }
    let attachStatus = IOServiceAddMatchingNotification(
      port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), callback, refcon,
      &attached)
    let detachStatus = IOServiceAddMatchingNotification(
      port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), callback, refcon,
      &detached)
    guard attachStatus == KERN_SUCCESS, detachStatus == KERN_SUCCESS else {
      FlashLog.warn(
        "[events] usb_monitor_unavailable",
        fields: ["attach": String(attachStatus), "detach": String(detachStatus)])
      stop()
      return
    }
    // Arm both notifications; what is connected now is not news.
    drain(attached, announce: false)
    drain(detached, announce: false)
  }

  func stop() {
    if attached != 0 { IOObjectRelease(attached) }
    if detached != 0 { IOObjectRelease(detached) }
    attached = 0
    detached = 0
    if let port { IONotificationPortDestroy(port) }
    port = nil
  }

  private func drain(_ iterator: io_iterator_t, announce: Bool = true) {
    let event: HostEvent = iterator == detached ? .usbDetached : .usbAttached
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard announce else { continue }
      let payload = Self.payload(
        vendorID: Self.property(service, kUSBVendorID) as? Int,
        productID: Self.property(service, kUSBProductID) as? Int,
        name: Self.property(service, kUSBProductString) as? String)
      emit(event, payload)
    }
  }

  private static func property(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  /// What `core:usb.*` carries: the ids as numbers and the product name,
  /// each only when the device reports it.
  static func payload(vendorID: Int?, productID: Int?, name: String?) -> [String: Any] {
    var payload: [String: Any] = [:]
    if let vendorID { payload["vendor_id"] = vendorID }
    if let productID { payload["product_id"] = productID }
    if let name, !name.isEmpty { payload["name"] = name }
    return payload
  }
}
