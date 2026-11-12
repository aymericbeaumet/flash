import XCTest

@testable import flash

/// `core:usb.attached` and `core:usb.detached`: what they carry, and that
/// observing starts quiet.
final class USBDeviceEventTests: XCTestCase {
  func testThePayloadNamesTheDeviceWithoutASerial() {
    let payload = USBDeviceMonitor.payload(vendorID: 0x05ac, productID: 0x024f, name: "Keyboard")
    XCTAssertEqual(payload["vendor_id"] as? Int, 0x05ac)
    XCTAssertEqual(payload["product_id"] as? Int, 0x024f)
    XCTAssertEqual(payload["name"] as? String, "Keyboard")
    XCTAssertEqual(Set(payload.keys), ["vendor_id", "product_id", "name"])
    XCTAssertTrue(USBDeviceMonitor.payload(vendorID: nil, productID: nil, name: "").isEmpty)
  }

  /// Devices connected before observing are not news.
  func testStartingAnnouncesNothingAlreadyConnected() {
    var events: [HostEvent] = []
    let monitor = USBDeviceMonitor { event, _ in events.append(event) }
    monitor.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    monitor.stop()
    XCTAssertEqual(events, [])
  }

  func testAMonitorCanWatchUSBEvents() {
    let config = ConfigLoader.parse(
      """
      [monitors.keyboard]
      event = ["core:usb.attached", "core:usb.detached"]
      run = ["/bin/echo", "usb"]
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertTrue(
      config.eventMonitorSpecs["keyboard"]?.matches(
        PluginEvent(.usbAttached, payload: ["name": "Keyboard"])) == true)
    XCTAssertNil(config.monitors["keyboard"]?.usb)
  }

  /// `usb` names the device: every field it sets must match the payload,
  /// ids exactly and the name as a case-insensitive substring; a payload
  /// missing a field the filter names does not match.
  func testAUSBFilterMatchesOnlyTheDeviceItNames() {
    let keyboard = USBDeviceMonitor.payload(
      vendorID: 0x05ac, productID: 0x024f, name: "Apple Keyboard")
    let nameless = USBDeviceMonitor.payload(vendorID: 0x05ac, productID: 0x024f, name: nil)

    XCTAssertTrue(USBDeviceFilter(vendorID: 0x05ac).matches(keyboard))
    XCTAssertTrue(USBDeviceFilter(vendorID: 0x05ac, productID: 0x024f).matches(keyboard))
    XCTAssertTrue(USBDeviceFilter(name: "keyboard").matches(keyboard))
    XCTAssertTrue(
      USBDeviceFilter(vendorID: 0x05ac, productID: 0x024f, name: "Apple Keyboard")
        .matches(keyboard))
    XCTAssertFalse(USBDeviceFilter(vendorID: 0x046d).matches(keyboard))
    XCTAssertFalse(USBDeviceFilter(vendorID: 0x05ac, productID: 0x0250).matches(keyboard))
    XCTAssertFalse(USBDeviceFilter(name: "mouse").matches(keyboard))
    XCTAssertFalse(USBDeviceFilter(name: "keyboard").matches(nameless))
    XCTAssertFalse(USBDeviceFilter(vendorID: 0x05ac).matches([:]))
    XCTAssertTrue(USBDeviceFilter().isEmpty)
    XCTAssertFalse(USBDeviceFilter(name: "k").isEmpty)
  }

  func testAMonitorCanNarrowUSBEventsToADevice() throws {
    let config = ConfigLoader.parse(
      """
      [monitors.keyboard]
      event = ["core:usb.attached", "core:usb.detached"]
      usb = { vendor_id = 0x05ac, product_id = 0x024f }
      run = ["flash", "caffeinate", "on"]

      [monitors.dock]
      event = "core:usb.attached"
      message = "Dock connected"
      [monitors.dock.usb]
      name = "caldigit"
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      config.monitors["keyboard"]?.usb, USBDeviceFilter(vendorID: 0x05ac, productID: 0x024f))
    XCTAssertEqual(config.monitors["dock"]?.usb, USBDeviceFilter(name: "caldigit"))
    XCTAssertEqual(
      config.valueLocations["monitors.keyboard.usb"], ConfigLocation(line: 3, column: 7))

    let keyboard = try XCTUnwrap(config.eventMonitorSpecs["keyboard"])
    XCTAssertTrue(
      keyboard.matches(
        PluginEvent(
          .usbAttached,
          payload: USBDeviceMonitor.payload(
            vendorID: 0x05ac, productID: 0x024f, name: "Apple Keyboard"))))
    XCTAssertTrue(
      keyboard.matches(
        PluginEvent(
          .usbDetached,
          payload: USBDeviceMonitor.payload(vendorID: 0x05ac, productID: 0x024f, name: nil))))
    XCTAssertFalse(
      keyboard.matches(
        PluginEvent(
          .usbAttached,
          payload: USBDeviceMonitor.payload(vendorID: 0x046d, productID: 0xc52b, name: "Mouse"))))
    XCTAssertFalse(keyboard.matches(PluginEvent(.usbAttached, payload: [:])))

    let dock = try XCTUnwrap(config.eventMonitorSpecs["dock"])
    XCTAssertTrue(
      dock.matches(
        PluginEvent(
          .usbAttached,
          payload: USBDeviceMonitor.payload(vendorID: 0x2188, productID: 1, name: "CalDigit TS4"))))
    XCTAssertFalse(
      dock.matches(
        PluginEvent(
          .usbAttached,
          payload: USBDeviceMonitor.payload(vendorID: 0x2188, productID: 1, name: "Display"))))
    XCTAssertFalse(dock.matches(PluginEvent(.usbDetached, payload: ["name": "CalDigit TS4"])))
  }

  func testAUSBFilterIsValidatedWithItsLocation() {
    let config = ConfigLoader.parse(
      """
      [monitors.empty]
      event = "core:usb.attached"
      usb = {}
      run = ["/bin/echo"]

      [monitors.range]
      event = "core:usb.attached"
      usb = { vendor_id = 70000 }
      run = ["/bin/echo"]

      [monitors.serial]
      event = "core:usb.attached"
      usb = { vendor_id = 0x05ac, serial = "C02XYZ" }
      run = ["/bin/echo"]

      [monitors.text]
      event = "core:usb.attached"
      usb = "keyboard"
      run = ["/bin/echo"]

      [monitors.blank]
      event = "core:usb.attached"
      usb = { name = "" }
      run = ["/bin/echo"]

      [monitors.wake]
      event = "core:system.woke"
      usb = { vendor_id = 0x05ac }
      run = ["/bin/echo"]
      """)
    let found = config.loadingDiagnostics
    func diagnostic(_ prefix: String) -> ConfigDiagnostic? {
      found.first { $0.message.hasPrefix(prefix) }
    }
    XCTAssertEqual(
      diagnostic("monitors.empty.usb must name the device")?.location,
      ConfigLocation(line: 3, column: 7), found.map(\.logMessage).joined(separator: "\n"))
    XCTAssertEqual(
      diagnostic("monitors.range.usb.vendor_id must be an integer between 0 and 65535")?.location,
      ConfigLocation(line: 8, column: 7))
    XCTAssertEqual(
      diagnostic("monitors.serial.usb: unknown key 'serial'")?.location,
      ConfigLocation(line: 13, column: 7))
    XCTAssertEqual(
      diagnostic("monitors.text.usb must be a table")?.location, ConfigLocation(line: 18, column: 7)
    )
    XCTAssertEqual(
      diagnostic("monitors.blank.usb.name must be a non-empty string")?.location,
      ConfigLocation(line: 23, column: 7))
    // A cross-key problem is located at the monitor's first located key,
    // its event, as the idle and clock ones are.
    XCTAssertEqual(
      diagnostic("monitors.wake.usb narrows core:usb.attached and core:usb.detached")?.location,
      ConfigLocation(line: 27, column: 9))
    for name in ["empty", "range", "serial", "text", "blank"] {
      XCTAssertNil(config.monitors[name]?.usb, name)
    }
    XCTAssertNil(config.eventMonitorSpecs["wake"], "a monitor with a problem does not run")
    XCTAssertEqual(
      Set(config.eventMonitorSpecs.keys), ["empty", "range", "serial", "text", "blank"])
  }
}
