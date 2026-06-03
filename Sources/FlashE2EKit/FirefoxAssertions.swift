import AppKit
import FlashCore
import Foundation

/// Backend-agnostic assertion runner for the Firefox E2E fixture.
///
/// Both the standalone CLI runner and the XCTest target funnel their
/// expectations through `Recorder`. The CLI records pass/fail lines
/// with red/green markers; the XCTest target forwards each failure to
/// `XCTFail`. Keeping the assertions themselves in one place stops the
/// two surfaces from drifting.
public protocol FirefoxE2ERecorder: AnyObject {
  /// Called once per passing assertion. CLI prints a green tick; tests
  /// log a debug message.
  func pass(_ message: String)
  /// Called once per failure. CLI buffers + prints in red; tests fail
  /// the XCTestCase.
  func fail(_ message: String)
}

public enum FirefoxAssertions {

  /// Run every fixture invariant against the provider's output.
  ///
  /// - Parameters:
  ///   - targets: full target list returned by AccessibilityProvider.
  ///   - webAreaFrame: AXWebArea bounds in NSScreen coords. When nil,
  ///     count assertions are run against `targets` directly and the
  ///     recorder gets a soft warning.
  ///   - firefoxPid: pid the targets must carry.
  ///   - recorder: backend that absorbs the pass/fail lines.
  public static func run(
    targets: [JumpTarget],
    webAreaFrame: CGRect?,
    firefoxPid: pid_t,
    recorder: FirefoxE2ERecorder
  ) {
    guard !targets.isEmpty else {
      recorder.fail(
        "AccessibilityProvider returned 0 targets — AX engine likely never woke. "
          + "Check AXEnhancedUserInterface / AXManualAccessibility wakeup.")
      return
    }
    recorder.pass("provider returned \(targets.count) total targets")

    let pageTargets: [JumpTarget]
    if let web = webAreaFrame {
      pageTargets = targets.filter { web.intersects($0.frame) }
      recorder.pass(
        "located AXWebArea frame \(web) — \(pageTargets.count) targets in page area")
    } else {
      pageTargets = targets
      recorder.fail("could not locate AXWebArea frame; assertions degraded to total counts")
    }

    guard !pageTargets.isEmpty else {
      recorder.fail(
        "No targets intersected the AXWebArea frame. Either the web area frame is wrong, "
          + "or the page-content walk dropped every candidate.")
      return
    }

    var roleCount: [String: Int] = [:]
    for t in pageTargets {
      roleCount[t.role ?? "<nil>", default: 0] += 1
    }

    // -- UNDERMATCH --

    func atLeast(_ role: String, _ floor: Int, _ context: String) {
      let got = roleCount[role, default: 0]
      if got >= floor {
        recorder.pass("\(role): \(got) ≥ \(floor)  (\(context))")
      } else {
        recorder.fail(
          "\(role) undermatch: expected ≥ \(floor), got \(got)  (\(context))")
      }
    }

    typealias C = FirefoxFixture.Counts
    atLeast("AXLink", C.expectedLinks, "5 anchors + 3 image-wrapped")
    atLeast("AXButton", C.expectedButtons, "5 <button> + 1 submit")
    atLeast(
      "AXTextField", C.expectedTextFields, "text/email/password/number/tel/url")
    atLeast("AXSearchField", C.searchInputs, "<input type=search>")
    atLeast("AXCheckBox", C.checkboxes, "<input type=checkbox>")
    atLeast("AXRadioButton", C.radios, "<input type=radio>")
    atLeast("AXPopUpButton", C.selects, "<select>")
    atLeast("AXTextArea", C.textareas, "<textarea>")

    // -- OVERMATCH by role --
    for forbidden in FirefoxFixture.forbiddenRoles {
      let n = roleCount[forbidden, default: 0]
      if n == 0 {
        recorder.pass("forbidden \(forbidden): 0")
      } else {
        recorder.fail(
          "Overmatch: role \(forbidden) must not produce hints, got \(n)")
      }
    }

    let imageCount = roleCount["AXImage", default: 0]
    if imageCount == 0 {
      recorder.pass(
        "AXImage: 0 inside page area "
          + "(img-as-decorative + actionless image filtering both work)")
    } else {
      recorder.fail(
        "Overmatch: AXImage \(imageCount) inside page area — expected 0. "
          + "Every fixture image is either wrapped in an <a> (decorative under "
          + "clickableContainerRoles) or has no click handler (filtered by "
          + "pending-action check). Possible regression: clickableContainerRoles "
          + "narrowed, or the pending-action verifier started letting through "
          + "actionless images.")
    }

    // -- HIDDEN-SUBTREE upper bounds --
    // The fixture seeds 25 elements into disabled / aria-hidden /
    // display:none subtrees. None of them must surface as hints. Express
    // that with role-specific ceilings.
    let realButtonCeiling = C.expectedButtons + C.roleButtonDivs
    let buttonsGot = roleCount["AXButton", default: 0]
    // +2 headroom: a chrome button can occasionally clip the AXWebArea
    // frame and slip into the page-area count.
    if buttonsGot <= realButtonCeiling + 2 {
      recorder.pass("AXButton ceiling: \(buttonsGot) ≤ \(realButtonCeiling + 2)")
    } else {
      recorder.fail(
        "Overmatch: AXButton \(buttonsGot) > \(realButtonCeiling + 2) — disabled / "
          + "aria-hidden / display:none buttons leaking through")
    }

    let realTextFieldCeiling = C.expectedTextFields
    let textGot = roleCount["AXTextField", default: 0]
    if textGot <= realTextFieldCeiling + 2 {
      recorder.pass("AXTextField ceiling: \(textGot) ≤ \(realTextFieldCeiling + 2)")
    } else {
      recorder.fail(
        "Overmatch: AXTextField \(textGot) > \(realTextFieldCeiling + 2) — disabled / "
          + "aria-hidden inputs leaking through")
    }

    // -- INVARIANTS --

    let ids = targets.map { $0.id }
    if Set(ids).count == ids.count {
      recorder.pass("target ids are unique (\(ids.count))")
    } else {
      recorder.fail(
        "duplicate target ids — overlay layer pool would collide")
    }

    let wrongPid = pageTargets.filter { $0.pid != firefoxPid }
    if wrongPid.isEmpty {
      recorder.pass("all page targets carry Firefox's pid")
    } else {
      recorder.fail("\(wrongPid.count) page targets carry wrong pid")
    }

    let screenFrame =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
      ?? NSScreen.main?.frame ?? .zero
    let offscreen = pageTargets.filter { !screenFrame.intersects($0.frame) }
    if offscreen.isEmpty {
      recorder.pass("all page-target frames intersect the primary screen")
    } else {
      recorder.fail(
        "\(offscreen.count) page targets miss the primary screen — coordinate flip?")
    }

    // Render a histogram into the recorder so a failure can be
    // diagnosed without re-running.
    let histo = roleCount.sorted { $0.key < $1.key }
      .map { "  \($0.key.padding(toLength: 24, withPad: " ", startingAt: 0))\($0.value)" }
      .joined(separator: "\n")
    recorder.pass("role histogram (page area):\n\(histo)")
  }
}
