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
enum TestWindowHygiene {
  private static let observer = Observer()

  static func install() {
    swap(
      #selector(NSWindow.order(_:relativeTo:)),
      #selector(NSWindow.flashTestsOrder(_:relativeTo:)))
    swap(
      #selector(NSWindow.orderFrontRegardless),
      #selector(NSWindow.flashTestsOrderFrontRegardless))
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
    func testCaseWillStart(_ testCase: XCTestCase) {
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
}
