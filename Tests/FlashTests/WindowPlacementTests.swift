import ApplicationServices
import CoreGraphics
import FlashCore
import XCTest

@testable import flash

/// An app window as Accessibility sees it. Frame writes land, are clamped to
/// the display, or land late, the way real apps answer them, and every call a
/// placement makes is recorded in order.
private final class FakeAppWindow {
  var frame: CGRect
  /// The displays a size write is clamped to when `clampsToDisplay`.
  var displays: [CGRect]
  /// A size write is clamped to the display holding the window's top-left
  /// corner, as macOS keeps a window from growing off its screen.
  var clampsToDisplay = false
  /// A position write lands only when the frame is next read, so a size write
  /// before then is clamped against the old corner: the async grow-clamp race.
  var positionLandsLate = false
  /// The app rounds every size down to this step (a terminal's cell grid).
  var sizeStep: CGFloat?
  var enhancedUserInterface: Bool?
  var enhancedUserInterfaceSettable = true
  /// Turning enhanced UI back on makes the app lay the window out here.
  var relayoutWhenEnhancedUserInterfaceReturns: CGRect?
  private var pendingTopLeft: CGPoint?
  private(set) var calls: [String] = []

  init(frame: CGRect, displays: [CGRect]) {
    self.frame = frame
    self.displays = displays
  }

  var writes: [WindowFrameWrite] {
    calls.compactMap { call in
      switch call {
      case "size": return .size
      case "position": return .position
      default: return nil
      }
    }
  }

  var driver: WindowGeometryDriver {
    WindowGeometryDriver(
      frame: { [self] in
        calls.append("frame")
        if let pendingTopLeft {
          frame.origin = CGPoint(x: pendingTopLeft.x, y: pendingTopLeft.y - frame.height)
          self.pendingTopLeft = nil
        }
        return frame
      },
      write: { [self] write, rect in
        switch write {
        case .position:
          calls.append("position")
          let topLeft = CGPoint(x: rect.minX, y: rect.maxY)
          if positionLandsLate {
            pendingTopLeft = topLeft
          } else {
            frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
          }
        case .size:
          calls.append("size")
          var size = rect.size
          if clampsToDisplay, let display = displayHoldingTopLeft() {
            size.width = min(size.width, display.maxX - frame.minX)
            size.height = min(size.height, frame.maxY - display.minY)
          }
          if let sizeStep {
            size.width = (size.width / sizeStep).rounded(.down) * sizeStep
            size.height = (size.height / sizeStep).rounded(.down) * sizeStep
          }
          frame = CGRect(
            x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
      },
      enhancedUserInterface: { [self] in
        calls.append("eui")
        return enhancedUserInterface
      },
      enhancedUserInterfaceIsSettable: { [self] in
        calls.append("eui_settable")
        return enhancedUserInterfaceSettable
      },
      setEnhancedUserInterface: { [self] enabled in
        calls.append("eui=\(enabled)")
        enhancedUserInterface = enabled
        if enabled, let relayout = relayoutWhenEnhancedUserInterfaceReturns {
          frame = relayout
          relayoutWhenEnhancedUserInterfaceReturns = nil
        }
      })
  }

  private func displayHoldingTopLeft() -> CGRect? {
    displays.first { display in
      display.minX <= frame.minX && frame.minX < display.maxX
        && display.minY < frame.maxY && frame.maxY <= display.maxY
    }
  }
}

final class WindowPlacementTests: XCTestCase {
  private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
  private let usable = CGRect(x: 0, y: 0, width: 1728, height: 1084)

  private func slot(_ position: WindowPosition, in usable: CGRect? = nil) -> CGRect {
    WindowMover.rectFor(position: position, in: usable ?? self.usable)
  }

  private func place(
    _ window: FakeAppWindow, at target: CGRect, within bounds: CGRect? = nil,
    engine: AppTraits.Engine? = nil
  ) -> WindowMover.Placement {
    WindowMover.apply(
      rect: target, from: window.frame, within: bounds ?? usable, engine: engine,
      driver: window.driver, bundleIdentifier: "com.example.App")
  }

  // MARK: - Which writes a placement makes

  func testFrameWritesSkipAWindowAlreadyInPlace() {
    let left = slot(.leftHalf)
    XCTAssertEqual(WindowMover.frameWrites(from: left, to: left, within: usable), [])
    XCTAssertEqual(
      WindowMover.frameWrites(from: left.offsetBy(dx: 0.4, dy: -0.4), to: left, within: usable),
      [], "an app rounding a fractional target is already in place")
  }

  func testFrameWritesMoveAWindowOfTheRightSizeWithOnePositionWrite() {
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.leftHalf), to: slot(.rightHalf), within: usable),
      [.position])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.topHalf), to: slot(.bottomHalf), within: usable),
      [.position])
  }

  func testFrameWritesResizeAWindowInPlaceWithOneSizeWrite() {
    // Maximized and the left half share their top-left corner.
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.maximized), to: slot(.leftHalf), within: usable),
      [.size])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.leftHalf), to: slot(.maximized), within: usable),
      [.size])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.topHalf), to: slot(.topLeft), within: usable),
      [.size])
  }

  func testFrameWritesShrinkBeforeMovingAndMoveBeforeGrowing() {
    // Either order's intermediate frame stays on the display: a shrink in
    // place, or a move at the smaller size.
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.maximized), to: slot(.rightHalf), within: usable),
      [.size, .position])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.rightHalf), to: slot(.maximized), within: usable),
      [.position, .size])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.maximized), to: slot(.centered), within: usable),
      [.size, .position])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.centered), to: slot(.maximized), within: usable),
      [.position, .size])
    XCTAssertEqual(
      WindowMover.frameWrites(from: slot(.bottomRight), to: slot(.topHalf), within: usable),
      [.position, .size])
  }

  func testFrameWritesKeepTheBurstForAWindowOutsideTheDestination() {
    let secondary = CGRect(x: 1728, y: 0, width: 2560, height: 1415)
    // On another display, the first size write can be clamped to the display
    // the window is leaving; the second applies it on arrival.
    XCTAssertEqual(
      WindowMover.frameWrites(
        from: slot(.leftHalf), to: slot(.maximized, in: secondary), within: secondary),
      [.size, .position, .size])
    // Hanging off the usable frame (under the status bar band).
    XCTAssertEqual(
      WindowMover.frameWrites(
        from: CGRect(x: 100, y: 200, width: 800, height: 900), to: slot(.rightHalf),
        within: usable),
      [.size, .position, .size])
    // Only the corner changes: the size already fits the destination.
    XCTAssertEqual(
      WindowMover.frameWrites(
        from: slot(.leftHalf),
        to: slot(.leftHalf).offsetBy(dx: secondary.minX, dy: 0), within: secondary),
      [.position])
  }

  // MARK: - Applying a placement

  func testPlacingAWindowAlreadyInPlaceTouchesNothing() {
    let window = FakeAppWindow(frame: slot(.maximized), displays: [display])
    window.enhancedUserInterface = true

    let placement = place(window, at: slot(.maximized))

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(window.calls, [], "no frame read, no enhanced-UI read, no write")
  }

  func testHalfToHalfWritesOnlyThePosition() {
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.clampsToDisplay = true

    let placement = place(window, at: slot(.rightHalf))

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(window.writes, [.position])
    XCTAssertEqual(window.frame, slot(.rightHalf))
  }

  func testGrowingToMaximizedMovesFirstSoTheDisplayNeverClampsIt() {
    let window = FakeAppWindow(frame: slot(.rightHalf), displays: [display])
    window.clampsToDisplay = true

    let placement = place(window, at: slot(.maximized))

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(placement.corrections, 0)
    XCTAssertEqual(window.writes, [.position, .size])
  }

  func testALatePositionCostsOneSizeCorrection() {
    let window = FakeAppWindow(frame: slot(.rightHalf), displays: [display])
    window.clampsToDisplay = true
    window.positionLandsLate = true

    let placement = place(window, at: slot(.maximized))

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(placement.corrections, 1)
    XCTAssertEqual(
      window.writes, [.position, .size, .size],
      "the correction writes only the size the late corner clamped")
  }

  func testCrossDisplayGrowLandsThroughTheBurst() {
    let secondary = CGRect(x: 1728, y: 0, width: 2560, height: 1415)
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display, secondary])
    window.clampsToDisplay = true

    let placement = place(window, at: slot(.maximized, in: secondary), within: secondary)

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(placement.corrections, 0)
    XCTAssertEqual(window.writes, [.size, .position, .size])
  }

  func testAWindowThatRefusesTheFrameStopsAfterBoundedCorrections() {
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.sizeStep = 7

    let placement = place(window, at: slot(.maximized))

    XCTAssertEqual(placement.outcome, .refused)
    XCTAssertEqual(placement.corrections, 2)
    XCTAssertEqual(window.writes, [.size, .size, .size])
  }

  // MARK: - Enhanced user interface

  func testEnhancedUserInterfaceSettabilityIsOnlyAskedWhenItIsOn() {
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.enhancedUserInterface = false

    _ = place(window, at: slot(.rightHalf))

    XCTAssertEqual(window.calls, ["eui", "position", "frame"])
  }

  func testEnhancedUserInterfaceIsSwitchedOffAroundTheWritesAndBackOn() {
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.enhancedUserInterface = true

    let placement = place(window, at: slot(.rightHalf), engine: .chromium)

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(
      window.calls,
      ["eui", "eui_settable", "eui=false", "position", "frame", "eui=true", "frame"])
  }

  func testGeckoNeverHasItsEnhancedUserInterfaceReadOrSwitched() {
    // `GeckoAccessibility.withWindowManagement` owns Gecko's mode.
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.enhancedUserInterface = true

    _ = place(window, at: slot(.rightHalf), engine: .gecko)

    XCTAssertEqual(window.calls, ["position", "frame"])
  }

  func testALayoutUndoneByEnhancedUserInterfaceIsPutBack() {
    let window = FakeAppWindow(frame: slot(.leftHalf), displays: [display])
    window.enhancedUserInterface = true
    window.relayoutWhenEnhancedUserInterfaceReturns = slot(.leftHalf)

    let placement = place(window, at: slot(.rightHalf))

    XCTAssertEqual(placement.outcome, .converged)
    XCTAssertEqual(window.frame, slot(.rightHalf))
    XCTAssertEqual(
      window.calls,
      [
        "eui", "eui_settable", "eui=false", "position", "frame", "eui=true", "frame",
        "eui=false", "position", "eui=true", "frame",
      ])
    XCTAssertEqual(window.enhancedUserInterface, true)
  }

  // MARK: - Resolving the window

  func testWindowLookupGivesUpOnAnAppThatTimedOut() {
    XCTAssertFalse(
      WindowMover.windowLookupFallbacksMayAnswer(
        afterBatch: .cannotComplete, elapsedMs: 1_508, timeoutMs: 1_500),
      "three more lookups would each wait out the same timeout on the layout queue")
    XCTAssertTrue(
      WindowMover.windowLookupFallbacksMayAnswer(
        afterBatch: .cannotComplete, elapsedMs: 4, timeoutMs: 1_500),
      "a quick refusal is not a hung app")
    XCTAssertTrue(
      WindowMover.windowLookupFallbacksMayAnswer(
        afterBatch: .failure, elapsedMs: 1_600, timeoutMs: 1_500))
  }

  // MARK: - Placement rules

  func testPlacementRuleReadsTheTitleOnlyWhenARuleForTheAppNeedsIt() {
    let editorAll = WindowPlacementRule(
      bundleID: "com.example.Editor", titleContains: nil,
      move: MoveWindowParams(layout: .position(.leftHalf), screen: 0))
    let notes = WindowPlacementRule(
      bundleID: "com.example.Notes", titleContains: "inbox",
      move: MoveWindowParams(layout: .position(.rightHalf), screen: 0))
    let notesAll = WindowPlacementRule(
      bundleID: "com.example.Notes", titleContains: nil,
      move: MoveWindowParams(layout: .position(.maximized), screen: 0))
    let rules = [editorAll, notes, notesAll]
    var titleReads = 0
    func title(_ value: String) -> () -> String? {
      {
        titleReads += 1
        return value
      }
    }

    XCTAssertNil(
      WindowPlacementRule.first(in: rules, bundleID: "com.example.Other", title: title("x")))
    XCTAssertEqual(
      WindowPlacementRule.first(in: rules, bundleID: "com.example.Editor", title: title("x")),
      editorAll)
    XCTAssertEqual(titleReads, 0, "no rule needed the title")

    XCTAssertEqual(
      WindowPlacementRule.first(in: rules, bundleID: "com.example.Notes", title: title("Inbox")),
      notes)
    XCTAssertEqual(
      WindowPlacementRule.first(in: rules, bundleID: "com.example.Notes", title: title("Draft")),
      notesAll, "the first matching rule wins in file order")
    XCTAssertEqual(titleReads, 2)
  }

  /// The regression: a window no rule matched was checked again on every
  /// title change, so a rule could move it long after the user placed it.
  /// Each window is checked once per rule set; a matched rule whose move did
  /// not land is retried until it does.
  func testAWindowIsCheckedAgainstTheRulesOncePerRuleSet() {
    let inbox = WindowPlacementRule(
      bundleID: "com.example.Notes", titleContains: "inbox",
      move: MoveWindowParams(layout: .position(.rightHalf), screen: 0))
    var checks = PlacementRuleChecks<String>()
    func rule(_ title: String) -> WindowPlacementRule? {
      checks.rule(for: "w1", in: [inbox], bundleID: "com.example.Notes", title: { title })
    }

    XCTAssertNil(rule("Loading…"), "first sight: no rule matches")
    XCTAssertNil(rule("Inbox"), "checked already: a later title moves nothing")

    checks.reset()
    XCTAssertEqual(rule("Inbox"), inbox, "a changed rule set checks it again")
    XCTAssertEqual(rule("Inbox"), inbox, "the move did not land: still due")
    checks.applied("w1")
    XCTAssertNil(rule("Inbox"), "applied once")

    checks.forget("w1")
    XCTAssertEqual(rule("Inbox"), inbox, "a closed window's identity starts over")
  }

  // MARK: - Choosing the target app

  func testAWindowVerbAimedAtTheFrontmostAppReadsNoWindowList() {
    var windowListReads = 0
    let topVisible: () -> pid_t? = {
      windowListReads += 1
      return 77
    }

    XCTAssertEqual(
      AppMonitor.windowVerbTargetPID(
        frontmost: (pid: 42, bundleIdentifier: "com.example.App"),
        excludingBundleIdentifier: "com.flash.app", topVisible: topVisible),
      42)
    XCTAssertEqual(windowListReads, 0)

    XCTAssertEqual(
      AppMonitor.windowVerbTargetPID(
        frontmost: (pid: 9, bundleIdentifier: "com.flash.app"),
        excludingBundleIdentifier: "com.flash.app", topVisible: topVisible),
      77, "Flash in front: the top visible window's app")
    XCTAssertEqual(
      AppMonitor.windowVerbTargetPID(
        frontmost: nil, excludingBundleIdentifier: "com.flash.app", topVisible: topVisible),
      77)
    XCTAssertEqual(windowListReads, 2)
  }
}
