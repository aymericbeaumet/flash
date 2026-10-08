import XCTest

@testable import flash

final class SecureInputReleaseTests: XCTestCase {
  private func snapshot(
    enabled: Bool = true,
    holders: [SecureInputRelease.Holder] = [],
    frontmostPID: pid_t? = 10,
    frontmostBundleID: String? = "com.apple.Terminal",
    role: String? = nil,
    subrole: String? = nil,
    running: [String] = [],
    ownPID: pid_t = 1
  ) -> SecureInputRelease.Snapshot {
    SecureInputRelease.Snapshot(
      enabled: enabled,
      holders: holders,
      frontmostPID: frontmostPID,
      frontmostBundleID: frontmostBundleID,
      focused: SecureInputRelease.Focus(role: role, subrole: subrole),
      runningBundleIDs: running,
      ownPID: ownPID)
  }

  private func holder(_ pid: pid_t, _ bundleID: String?) -> SecureInputRelease.Holder {
    SecureInputRelease.Holder(pid: pid, bundleID: bundleID)
  }

  func testOffIsIdle() {
    XCTAssertEqual(SecureInputRelease.decide(snapshot(enabled: false)), .idle)
  }

  func testASecureFieldIsLeftAloneEvenWhenAnotherAppHoldsTheFlag() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(20, "com.google.Chrome")],
        role: "AXTextField", subrole: "AXSecureTextField"))
    XCTAssertEqual(decision, .legitimate)
    let byRole = SecureInputRelease.decide(
      snapshot(holders: [holder(10, "com.apple.Safari")], role: "AXSecureTextField"))
    XCTAssertEqual(byRole, .legitimate)
  }

  func testATextFieldInTheHoldingAppIsLeftAlone() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(10, "com.google.Chrome")],
        frontmostPID: 10, frontmostBundleID: "com.google.Chrome",
        role: "AXTextField"))
    XCTAssertEqual(decision, .legitimate)
    let area = SecureInputRelease.decide(
      snapshot(
        holders: [holder(10, "com.bitwarden.desktop")],
        frontmostPID: 10, frontmostBundleID: "com.bitwarden.desktop",
        role: "AXTextArea"))
    XCTAssertEqual(area, .legitimate)
  }

  func testABackgroundHolderIsReleasedWhileTheFrontAppHasATextField() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(20, "com.bitwarden.desktop")],
        role: "AXTextArea",
        running: ["com.bitwarden.desktop", "com.apple.Terminal"]))
    XCTAssertEqual(
      decision,
      .release([
        SecureInputRelease.Request(
          bundleID: "com.bitwarden.desktop", kind: .activate,
          returnTo: "com.apple.Terminal", frontmost: false)
      ]))
  }

  func testChromiumIsBlurredAndAnotherBrowserGoesToItsAddressBar() {
    let chrome = SecureInputRelease.decide(
      snapshot(
        holders: [holder(20, "com.google.Chrome")],
        role: "AXGroup"))
    XCTAssertEqual(
      chrome,
      .release([
        SecureInputRelease.Request(
          bundleID: "com.google.Chrome", kind: .chromium,
          returnTo: "com.apple.Terminal", frontmost: false)
      ]))
    let firefox = SecureInputRelease.decide(
      snapshot(holders: [holder(21, "org.mozilla.firefox")], role: "AXGroup"))
    XCTAssertEqual(
      firefox,
      .release([
        SecureInputRelease.Request(
          bundleID: "org.mozilla.firefox", kind: .addressBar,
          returnTo: "com.apple.Terminal", frontmost: false)
      ]))
  }

  func testAFrontmostLeakNamesNoAppToReturnTo() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(10, "com.google.Chrome")],
        frontmostPID: 10, frontmostBundleID: "com.google.Chrome",
        role: "AXWebArea"))
    XCTAssertEqual(
      decision,
      .release([
        SecureInputRelease.Request(
          bundleID: "com.google.Chrome", kind: .chromium,
          returnTo: nil, frontmost: true)
      ]))
  }

  func testBackgroundHoldersAreAskedBeforeTheFrontmostOne() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(10, "com.google.Chrome"), holder(20, "com.bitwarden.desktop")],
        frontmostPID: 10, frontmostBundleID: "com.google.Chrome",
        role: "AXWebArea"))
    guard case .release(let requests) = decision else {
      return XCTFail("\(decision)")
    }
    XCTAssertEqual(requests.map(\.bundleID), ["com.bitwarden.desktop", "com.google.Chrome"])
    XCTAssertEqual(requests.map(\.frontmost), [false, true])
  }

  func testAnUnknownHolderOnlyBlursRunningChromium() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(30, "com.apple.loginwindow")],
        role: "AXGroup",
        running: [
          "com.apple.Terminal", "org.mozilla.firefox", "com.brave.Browser",
          "com.bitwarden.desktop",
        ]))
    XCTAssertEqual(
      decision,
      .release([
        SecureInputRelease.Request(
          bundleID: "com.brave.Browser", kind: .chromium,
          returnTo: "com.apple.Terminal", frontmost: false)
      ]))
  }

  func testATextFieldWithNoActionableHolderIsLeftAlone() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [holder(30, "com.apple.loginwindow")],
        role: "AXTextArea",
        running: ["com.google.Chrome"]))
    XCTAssertEqual(decision, .legitimate)
  }

  func testRefusedAndSelfHoldsAreNotActivated() {
    let decision = SecureInputRelease.decide(
      snapshot(
        holders: [
          holder(1, "com.flash.app"),
          holder(40, "com.apple.SecurityAgent"),
          holder(41, "com.apple.finder"),
        ],
        role: "AXGroup",
        ownPID: 1))
    XCTAssertEqual(decision, .release([]))
  }

  func testANamedThirdPartyAppIsActivated() {
    let decision = SecureInputRelease.decide(
      snapshot(holders: [holder(22, "com.example.Vault")], role: nil))
    XCTAssertEqual(
      decision,
      .release([
        SecureInputRelease.Request(
          bundleID: "com.example.Vault", kind: .activate,
          returnTo: "com.apple.Terminal", frontmost: false)
      ]))
  }

  func testABundleIDThatCouldEscapeAppleScriptIsRejected() {
    XCTAssertNil(SecureInputRelease.chromiumBlurScript(bundleID: "com.google.Chrome\"; say"))
    XCTAssertNil(SecureInputRelease.chromiumBlurScript(bundleID: "not a bundle"))
    XCTAssertNil(SecureInputRelease.chromiumBlurScript(bundleID: "com.bitwarden.desktop"))
    XCTAssertFalse(SecureInputRelease.isBundleID(""))
    XCTAssertFalse(SecureInputRelease.isBundleID(".chrome"))
  }

  func testTheChromiumScriptBlursWithoutActivatingAndTheAddressBarIsAFixedShortcut() {
    let script = SecureInputRelease.chromiumBlurScript(bundleID: "com.google.Chrome")
    XCTAssertEqual(
      script?.contains("tell application id \"com.google.Chrome\""), true)
    XCTAssertEqual(script?.contains("document.activeElement.blur()"), true)
    XCTAssertEqual(script?.contains("activate"), false)
    XCTAssertEqual(script?.contains("if n > 8 then set n to 8"), true)
    XCTAssertEqual(
      SecureInputRelease.addressBarScript,
      "tell application \"System Events\" to keystroke \"l\" using command down")
  }

  func testAFrontmostLeakWaitsForASecondSample() {
    var machine = SecureInputFixMachine()
    let request = SecureInputRelease.Request(
      bundleID: "com.google.Chrome", kind: .chromium, returnTo: nil, frontmost: true)
    XCTAssertEqual(machine.consider(.release([request])), .wait)
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
    XCTAssertEqual(machine.consider(.release([request])), .wait)
  }

  func testALegitimateSampleResetsTheFrontmostWait() {
    var machine = SecureInputFixMachine()
    let request = SecureInputRelease.Request(
      bundleID: "com.google.Chrome", kind: .chromium, returnTo: nil, frontmost: true)
    XCTAssertEqual(machine.consider(.release([request])), .wait)
    XCTAssertEqual(machine.consider(.legitimate), .wait)
    XCTAssertEqual(machine.consider(.release([request])), .wait)
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
  }

  func testABackgroundReleaseRunsImmediatelyAndTheFrontmostOneCanFollow() {
    var machine = SecureInputFixMachine()
    let background = SecureInputRelease.Request(
      bundleID: "com.bitwarden.desktop", kind: .activate,
      returnTo: "com.google.Chrome", frontmost: false)
    let foreground = SecureInputRelease.Request(
      bundleID: "com.google.Chrome", kind: .chromium, returnTo: nil, frontmost: true)
    XCTAssertEqual(
      machine.consider(.release([background, foreground])), .perform([background]))
    XCTAssertEqual(machine.consider(.release([background, foreground])), .wait)
    XCTAssertEqual(
      machine.consider(.release([background, foreground])), .perform([foreground]))
  }

  func testTheFlagDroppingAllowsAnotherRelease() {
    var machine = SecureInputFixMachine()
    let request = SecureInputRelease.Request(
      bundleID: "com.bitwarden.desktop", kind: .activate,
      returnTo: "com.apple.Terminal", frontmost: false)
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
    XCTAssertEqual(machine.consider(.release([request])), .wait)
    XCTAssertEqual(machine.consider(.idle), .wait)
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
    _ = machine.consider(.release([request]))
    machine.noteCleared()
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
  }

  func testAnEmptyReleaseIsNotRetriedUntilTheFlagDrops() {
    var machine = SecureInputFixMachine()
    let request = SecureInputRelease.Request(
      bundleID: "com.example.Vault", kind: .activate,
      returnTo: "com.apple.Terminal", frontmost: false)
    XCTAssertEqual(machine.consider(.release([])), .wait)
    XCTAssertEqual(machine.consider(.release([request])), .wait)
    machine.noteCleared()
    XCTAssertEqual(machine.consider(.release([request])), .perform([request]))
  }
}
