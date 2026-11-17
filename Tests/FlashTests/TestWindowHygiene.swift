import AppKit
import XCTest

@testable import flash

/// Called by the `FlashTestsBootstrap` image constructor when XCTest loads
/// the bundle, before any test runs, filtered or not.
@_cdecl("flash_tests_bootstrap")
func flashTestsBootstrap() {
  TestWindowHygiene.install()
}

/// Keeps the suite's windows off the user's screen.
///
/// Tests drive real Flash windows — the overlay panel, the status bar and its
/// click band, widgets — and production code orders them front. Drawn on the
/// user's screen they covered the focused app, and the installed Flash then
/// walked a fully covered window and found no hints
/// (`[discover] frontmost_window_covered` naming the xctest pid).
///
/// - Every window this process orders in is made fully transparent first.
///   WindowServer neither draws nor hit-tests it and `WindowSnapshot` does not
///   count it as an occluder, while ordering, frames, levels and layers stay
///   exactly what the tests assert.
/// - After every test a guard fails the test when this process still has an
///   on-screen window with alpha above zero over a display, and orders it out.
/// - No window of this process becomes key. A non-activating panel that does
///   takes the keyboard from the user's frontmost app without activating
///   anything (WindowServer logs a "keythief"), so the keys the user types
///   into their app reach a hidden test window instead. `makeKey` is refused
///   and `makeKeyAndOrderFront` only orders the window in; tests drive key
///   handling by calling the panel's methods, never through the key window.
enum TestWindowHygiene {
  private static let observer = Observer()
  /// Refused key requests per window, for the hygiene's own test.
  @MainActor fileprivate static var refusals: [ObjectIdentifier: Int] = [:]

  @MainActor static func refusedKeyRequests(for window: NSWindow) -> Int {
    refusals[ObjectIdentifier(window)] ?? 0
  }

  static func install() {
    swap(
      #selector(NSWindow.order(_:relativeTo:)),
      #selector(NSWindow.flashTestsOrder(_:relativeTo:)))
    swap(
      #selector(NSWindow.orderFrontRegardless),
      #selector(NSWindow.flashTestsOrderFrontRegardless))
    swap(#selector(NSWindow.makeKey), #selector(NSWindow.flashTestsMakeKey))
    swap(
      #selector(NSWindow.makeKeyAndOrderFront(_:)),
      #selector(NSWindow.flashTestsMakeKeyAndOrderFront(_:)))
    XCTestObservationCenter.shared.addTestObserver(observer)
  }

  private static func swap(_ original: Selector, _ replacement: Selector) {
    guard let original = class_getInstanceMethod(NSWindow.self, original),
      let replacement = class_getInstanceMethod(NSWindow.self, replacement)
    else { preconditionFailure("NSWindow ordering selector not found") }
    method_exchangeImplementations(original, replacement)
  }

  struct OccludingWindow: Equatable, CustomStringConvertible {
    let number: Int
    let layer: Int
    let alpha: Double
    /// CoreGraphics coordinates, like the display bounds it is tested against.
    let bounds: CGRect

    var description: String { "window \(number) layer=\(layer) alpha=\(alpha) bounds=\(bounds)" }
  }

  /// `pid`'s on-screen windows that would cover part of a display: any alpha
  /// above zero counts, stricter than `WindowSnapshot.Entry.occludes`.
  static func occludingWindows(
    owner pid: pid_t, in windowList: [[String: Any]], displays: [CGRect]
  ) -> [OccludingWindow] {
    windowList.compactMap { info in
      guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
        let number = info[kCGWindowNumber as String] as? Int,
        let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
        bounds.width > 0, bounds.height > 0
      else { return nil }
      let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
      guard alpha > 0, displays.contains(where: { $0.intersects(bounds) }) else { return nil }
      return OccludingWindow(
        number: number, layer: (info[kCGWindowLayer as String] as? Int) ?? 0, alpha: alpha,
        bounds: bounds)
    }
  }

  static func activeDisplayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map(CGDisplayBounds)
  }

  private final class Observer: NSObject, XCTestObservation {
    /// Windows that became key during the running test, by class name.
    private var becameKey: [String] = []
    private var keyObserver: NSObjectProtocol?

    func testCaseWillStart(_ testCase: XCTestCase) {
      becameKey = []
      keyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
      ) { [weak self] note in
        guard let window = note.object as? NSWindow else { return }
        self?.becameKey.append(String(describing: type(of: window)))
        window.resignKey()
      }
      testCase.addTeardownBlock { [weak self] in
        if let observer = self?.keyObserver { NotificationCenter.default.removeObserver(observer) }
        if let names = self?.becameKey, !names.isEmpty {
          XCTFail(
            "\(testCase.name) made a window key, which takes the keyboard from the "
              + "user's frontmost app: \(names.joined(separator: ", "))")
        }
      }
      testCase.addTeardownBlock {
        let offenders = TestWindowHygiene.occludingWindows(
          owner: getpid(),
          in: WindowSnapshot.windowList([.optionOnScreenOnly, .excludeDesktopElements]) ?? [],
          displays: TestWindowHygiene.activeDisplayBounds())
        guard !offenders.isEmpty else { return }
        for offender in offenders {
          NSApp?.window(withWindowNumber: offender.number)?.orderOut(nil)
        }
        XCTFail(
          "\(testCase.name) left windows that cover the user's screen: "
            + offenders.map(\.description).joined(separator: ", "))
      }
    }
  }
}

extension NSWindow {
  /// Swapped with `order(_:relativeTo:)`: this calls the original.
  @objc fileprivate func flashTestsOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
    if place != .out { alphaValue = 0 }
    flashTestsOrder(place, relativeTo: other)
  }

  /// Swapped with `orderFrontRegardless()`: this calls the original.
  @objc fileprivate func flashTestsOrderFrontRegardless() {
    alphaValue = 0
    flashTestsOrderFrontRegardless()
  }

  /// Swapped with `makeKey()`: never calls the original (`TestWindowHygiene`).
  @MainActor @objc fileprivate func flashTestsMakeKey() {
    TestWindowHygiene.refusals[ObjectIdentifier(self), default: 0] += 1
  }

  /// Swapped with `makeKeyAndOrderFront(_:)`: orders in, transparent,
  /// without the key window (`TestWindowHygiene`).
  @MainActor @objc fileprivate func flashTestsMakeKeyAndOrderFront(_ sender: Any?) {
    TestWindowHygiene.refusals[ObjectIdentifier(self), default: 0] += 1
    orderFront(sender)
  }
}
