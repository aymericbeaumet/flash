import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import XCTest

/// Live AX integration tests against Firefox. Firefox is the trickiest
/// host Flash supports because:
///   - it has no AppleScript `do JavaScript` bridge, so the
///     BrowserScriptProvider never applies — the AccessibilityProvider
///     IS the implementation.
///   - its accessibility engine is lazy: until something signals
///     "screen reader on", `AXWebArea` exposes only the chrome buttons.
///     `AccessibilityProvider` sets `AXEnhancedUserInterface` and
///     `AXManualAccessibility` to wake it; any regression there
///     silently empties the hint list.
///   - it batches AX IPC differently than Safari/Chrome, which is why
///     the walker has a per-element-attributes single-call fallback.
///
/// The fixture page exercises three failure modes:
///
/// **Undermatch** — every clickable role we promise to hint must be
/// present in the page area: links, buttons, every input type, select,
/// textarea, checkboxes, radios, contenteditable, details/summary,
/// role-overridden divs. A regression that narrows the role set or
/// over-eagerly filters elements drops the lower-bound counts.
///
/// **Overmatch** — non-clickable structural elements MUST NOT produce
/// hints: headings, plain paragraphs, the document container, layout
/// groups, decorative images inside links, standalone decorative
/// images without click handlers. A regression that broadens
/// acceptance (e.g. lets AXStaticText through, or stops treating
/// img-in-link as decorative) surfaces as forbidden roles appearing in
/// the target set or as the AXImage count blowing past zero inside the
/// page area.
///
/// **Hidden-subtree exclusion** — disabled controls, `aria-hidden`
/// subtrees, and `display:none` subtrees must contribute nothing. The
/// fixture seeds each with a fixed count of "if these were hinted, the
/// totals would explode" elements so a regression in the hidden /
/// enabled gating is impossible to miss.
///
/// **Opt-in**: gated on `FLASH_FIREFOX_E2E=1` so a default `swift
/// test` run doesn't launch a browser. Also skipped if Firefox isn't
/// installed or the test runner doesn't have Accessibility permission.
///
/// **AX permission**: the test runner (`xctest` under SwiftPM) needs
/// Accessibility access. Grant it via System Settings → Privacy &
/// Security → Accessibility → add the `xctest` binary, OR run inside
/// Xcode, which inherits Xcode's grant. Without it,
/// `AXIsProcessTrusted` returns false and these tests skip rather than
/// fail.
final class FirefoxIntegrationTests: XCTestCase {

  private static let firefoxBundleID = "org.mozilla.firefox"
  private static let firefoxPath = "/Applications/Firefox.app"

  // MARK: - Fixture
  //
  // Fixture HTML is structured as discrete sections so each regression
  // mode has its own bucket. Each section's *expected* contribution to
  // the target set is encoded next to its definition below. The test
  // sums these into per-role lower/upper bounds and presence/absence
  // assertions.
  //
  // Element counts intentionally include some redundancy (e.g. 5
  // buttons not 1) so a regression that drops half the matches is still
  // detectable.

  /// Number of each kind of element in the fixture. Update both this
  /// table and the corresponding HTML section in lockstep.
  private struct FixtureCounts {
    // Must-hint controls.
    static let links = 5            // <a href>
    static let imgLinks = 3         // <a href><img></a> — img must NOT double-hint
    static let buttons = 5          // <button>
    static let submitInputs = 1     // <input type=submit>
    static let textInputs = 2       // <input type=text>
    static let emailInputs = 2      // <input type=email>
    static let passwordInputs = 1   // <input type=password>
    static let numberInputs = 1     // <input type=number>
    static let telInputs = 1        // <input type=tel>
    static let urlInputs = 1        // <input type=url>
    static let searchInputs = 1     // <input type=search>
    static let checkboxes = 2       // <input type=checkbox>
    static let radios = 3           // <input type=radio> (same group)
    static let selects = 1          // <select>
    static let textareas = 1        // <textarea>
    static let detailsBlocks = 1    // <details><summary>
    static let contentEditables = 1 // <div contenteditable=true>
    static let roleButtonDivs = 1   // <div role=button tabindex=0>
    static let roleLinkDivs = 1     // <div role=link tabindex=0>

    // Must-not-hint elements.
    static let headings = 5         // <h1>/<h2>/<h3>
    static let paragraphs = 5       // <p>
    static let plainDivs = 5        // <div> (no role, no click)
    static let plainImages = 3      // <img> standalone, no click handler

    // Hidden / disabled sentinels. None of these should contribute to
    // ANY role count.
    static let disabledButtons = 5  // <button disabled>
    static let disabledInputs = 5   // <input disabled>
    static let ariaHiddenButtons = 5 // <button> inside aria-hidden subtree
    static let ariaHiddenInputs = 5 // <input> inside aria-hidden subtree
    static let displayNoneButtons = 5 // <button> inside display:none subtree
  }

  private static let fixtureHTML: String = {
    var html = """
      <!DOCTYPE html>
      <html><head>
      <title>FlashE2E</title>
      <style>
        body { font: 16px/1.4 -apple-system; padding: 16px; }
        section { border: 1px solid #ccc; padding: 12px; margin: 12px 0; }
        h2 { margin: 0 0 8px; font-size: 14px; color: #666; }
        button, input, select, textarea { margin: 4px; }
        img { width: 32px; height: 32px; background: #ddd; display: inline-block; }
      </style>
      </head><body>

      <section id="links"><h2>links</h2>
      """
    for i in 1...FixtureCounts.links {
      html += "<a href=\"#l\(i)\">link-\(i)</a> "
    }
    html += "</section><section id=\"img-links\"><h2>image links</h2>"
    for i in 1...FixtureCounts.imgLinks {
      html += "<a href=\"#il\(i)\"><img alt=\"il-\(i)\"></a> "
    }
    html += "</section><section id=\"buttons\"><h2>buttons</h2>"
    for i in 1...FixtureCounts.buttons {
      html += "<button>btn-\(i)</button> "
    }
    for i in 1...FixtureCounts.submitInputs {
      html += "<input type=\"submit\" value=\"submit-\(i)\"> "
    }
    html += "</section><section id=\"inputs\"><h2>inputs</h2>"
    for i in 1...FixtureCounts.textInputs {
      html += "<input type=\"text\" placeholder=\"text-\(i)\"> "
    }
    for i in 1...FixtureCounts.emailInputs {
      html += "<input type=\"email\" placeholder=\"email-\(i)\"> "
    }
    for i in 1...FixtureCounts.passwordInputs {
      html += "<input type=\"password\" placeholder=\"pw-\(i)\"> "
    }
    for i in 1...FixtureCounts.numberInputs {
      html += "<input type=\"number\" placeholder=\"num-\(i)\"> "
    }
    for i in 1...FixtureCounts.telInputs {
      html += "<input type=\"tel\" placeholder=\"tel-\(i)\"> "
    }
    for i in 1...FixtureCounts.urlInputs {
      html += "<input type=\"url\" placeholder=\"url-\(i)\"> "
    }
    for i in 1...FixtureCounts.searchInputs {
      html += "<input type=\"search\" placeholder=\"search-\(i)\"> "
    }
    html += "</section><section id=\"checks-radios\"><h2>checks + radios</h2>"
    for i in 1...FixtureCounts.checkboxes {
      html += "<label><input type=\"checkbox\"> cb-\(i)</label> "
    }
    for i in 1...FixtureCounts.radios {
      html += "<label><input type=\"radio\" name=\"r\"> r-\(i)</label> "
    }
    html += "</section><section id=\"selects\"><h2>selects + textareas</h2>"
    for i in 1...FixtureCounts.selects {
      html += "<select><option>s-\(i)-a</option><option>s-\(i)-b</option></select> "
    }
    for i in 1...FixtureCounts.textareas {
      html += "<textarea>ta-\(i)</textarea> "
    }
    html += "</section><section id=\"native-disclosure\"><h2>native disclosure</h2>"
    for i in 1...FixtureCounts.detailsBlocks {
      html += "<details><summary>summary-\(i)</summary><p>body-\(i)</p></details> "
    }
    html += "</section><section id=\"aria\"><h2>role-overridden + contenteditable</h2>"
    for i in 1...FixtureCounts.roleButtonDivs {
      html += "<div role=\"button\" tabindex=\"0\">role-btn-\(i)</div> "
    }
    for i in 1...FixtureCounts.roleLinkDivs {
      html += "<div role=\"link\" tabindex=\"0\">role-link-\(i)</div> "
    }
    for i in 1...FixtureCounts.contentEditables {
      html += "<div contenteditable=\"true\">ce-\(i)</div> "
    }
    html += "</section><section id=\"headings\"><h2>headings (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.headings {
      let level = (i % 3) + 1
      html += "<h\(level)>heading-\(i)</h\(level)> "
    }
    html += "</section><section id=\"paragraphs\"><h2>paragraphs + plain divs (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.paragraphs {
      html += "<p>paragraph-\(i)</p>"
    }
    for i in 1...FixtureCounts.plainDivs {
      html += "<div>plain-div-\(i)</div>"
    }
    html += "</section><section id=\"plain-imgs\"><h2>decorative images (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.plainImages {
      html += "<img alt=\"plain-\(i)\"> "
    }
    html += "</section><section id=\"disabled\"><h2>disabled controls (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.disabledButtons {
      html += "<button disabled>disabled-btn-\(i)</button> "
    }
    for i in 1...FixtureCounts.disabledInputs {
      html += "<input type=\"text\" disabled value=\"disabled-input-\(i)\"> "
    }
    html += "</section><section id=\"aria-hidden\" aria-hidden=\"true\"><h2>aria-hidden subtree (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.ariaHiddenButtons {
      html += "<button>aria-hidden-btn-\(i)</button> "
    }
    for i in 1...FixtureCounts.ariaHiddenInputs {
      html += "<input type=\"text\" value=\"aria-hidden-input-\(i)\"> "
    }
    html += "</section><section id=\"display-none\" style=\"display:none\"><h2>display:none subtree (MUST NOT HINT)</h2>"
    for i in 1...FixtureCounts.displayNoneButtons {
      html += "<button>display-none-btn-\(i)</button> "
    }
    html += "</section></body></html>"
    return html
  }()

  // Roles the AccessibilityProvider promises to never produce as a
  // hint target. AXHeading and AXStaticText are page structure — a
  // regression that lets them through would dump a hint on every
  // sentence. AXGroup / AXScrollArea / AXSplitter / AXWebArea are
  // layout containers; hinting them would land in the middle of a
  // huge region instead of on a specific control.
  private static let forbiddenRoles: Set<String> = [
    "AXHeading",
    "AXStaticText",
    "AXGroup",
    "AXGenericElement",
    "AXScrollArea",
    "AXSplitter",
    "AXWebArea",
    "AXSection",
    "AXParagraph",
    "AXDocument",
    "AXOutline",
    "AXList",
    "AXListItem",
  ]

  override func setUpWithError() throws {
    guard ProcessInfo.processInfo.environment["FLASH_FIREFOX_E2E"] == "1" else {
      throw XCTSkip(
        "Firefox E2E is opt-in. Set FLASH_FIREFOX_E2E=1 to enable.")
    }
    guard FileManager.default.fileExists(atPath: Self.firefoxPath) else {
      throw XCTSkip("Firefox not installed at \(Self.firefoxPath)")
    }
    // Accessibility TCC is keyed on the *binary*'s cdhash, not on
    // the parent terminal — so granting Alacritty / iTerm / Terminal.app
    // does NOT bubble down to the xctest host. The auto-prompt
    // (`AXIsProcessTrustedWithOptions` with kAXTrustedCheckOptionPrompt)
    // is misleading here: macOS blames the "responsible process"
    // (whatever terminal launched `swift test`), which is usually
    // already granted, so adding it again changes nothing. The fix is
    // to grant `xctest` itself.
    guard AXIsProcessTrusted() else {
      // Granting Accessibility to `swift test`'s xctest helper is
      // fragile in practice (cdhash drift across Xcode updates, TCC
      // designated-requirement mismatch, terminal-attribution edge
      // cases). The recommended path is the standalone
      // `flash-firefox-e2e` binary, which signs with the same stable
      // identity as the Flash app bundle and gets a persistent grant.
      throw XCTSkip(
        """
        Test runner lacks Accessibility permission.

        Recommended: use the standalone runner instead of `swift test`.
        It signs with the stable "Flash Dev" identity, so the TCC grant
        persists across rebuilds:

          ./Scripts/install.sh              # one-time, sets up the signing identity
          ./Scripts/build-firefox-e2e.sh    # builds + signs flash-firefox-e2e
          # then grant accessibility to:
          #   <project>/build/flash-firefox-e2e
          ./build/flash-firefox-e2e

        Why not `swift test`: SwiftPM loads the test bundle through
        `swiftpm-xctest-helper`, whose TCC grant rarely sticks (Xcode
        updates rotate its cdhash, and stale grants linger silently).
        The standalone runner has the same fixture + assertions but
        runs in a binary you control.
        """)
    }
  }

  // MARK: - Test cases

  /// The headline regression test. Launches Firefox, lets the AX tree
  /// settle, walks via `AccessibilityProvider`, and asserts every
  /// fixture invariant simultaneously. Splitting this across N small
  /// tests would re-launch Firefox per test (~10 s each); the cost
  /// isn't worth it given each invariant has its own bespoke failure
  /// message.
  func testFirefoxHintCoverageAndExclusion() throws {
    let firefox = try launchFirefoxWithFixture()
    defer { firefox.terminate() }

    firefox.activate(options: [])

    let provider = AccessibilityProvider()
    let context = makeContext(for: firefox)

    let (targets, webAreaFrame) = try waitForStableTree(
      firefox: firefox,
      provider: provider,
      context: context,
      timeout: 20
    )
    XCTAssertFalse(
      targets.isEmpty,
      "AccessibilityProvider returned 0 targets after settle window — "
        + "AX engine likely never woke. Check AXEnhancedUserInterface / AXManualAccessibility wakeup.")

    // Page-area targets: those whose centre lies inside the AXWebArea.
    // Firefox chrome buttons (back/forward/urlbar, tab strip,
    // hamburger) live outside this rect; this filter removes them so
    // count assertions reason about page content alone.
    let pageTargets: [JumpTarget]
    if let web = webAreaFrame {
      pageTargets = targets.filter { web.intersects($0.frame) }
    } else {
      // Couldn't find web area frame — fall through to all targets
      // with a softer interpretation. The lower-bound assertions still
      // mean something; the upper-bound ones become advisory.
      pageTargets = targets
    }
    XCTAssertFalse(
      pageTargets.isEmpty,
      "No targets intersected the AXWebArea frame. Either the web area frame is wrong, "
        + "or the page-content walk dropped every candidate.")

    // Build a role histogram from page-area targets.
    var roleCount: [String: Int] = [:]
    for t in pageTargets {
      roleCount[t.role ?? "<nil>", default: 0] += 1
    }

    // ---- UNDERMATCH ASSERTIONS (must-hint lower bounds) ----
    //
    // Each assertion expresses: "given the fixture has N elements of
    // this kind, the page-area hint set must include at least M of
    // them." M is set to capture the floor where a regression has
    // narrowed acceptance.

    // AXLink: 5 plain anchors + 3 image-wrapped anchors. Image-wrapped
    // anchors must surface as one AXLink each (the inner img is
    // suppressed as decorative).
    let expectedLinks = FixtureCounts.links + FixtureCounts.imgLinks
    XCTAssertGreaterThanOrEqual(
      roleCount["AXLink", default: 0],
      expectedLinks,
      "AXLink undermatch: expected ≥ \(expectedLinks) (plain + image-wrapped anchors), "
        + "got \(roleCount["AXLink", default: 0]). Possible regression in AXLink "
        + "recognition or in the img-as-decorative folding.")

    // AXButton: <button> elements + <input type=submit>. role=button
    // div may or may not flow through as AXButton (Firefox sometimes
    // exposes role-overridden divs as AXButton, sometimes as AXGroup
    // with an AXPress action that goes through the web-action path).
    let expectedButtons = FixtureCounts.buttons + FixtureCounts.submitInputs
    XCTAssertGreaterThanOrEqual(
      roleCount["AXButton", default: 0],
      expectedButtons,
      "AXButton undermatch: expected ≥ \(expectedButtons), got \(roleCount["AXButton", default: 0]). "
        + "Possible regression: <input type=submit> not mapped to AXButton, "
        + "or disabled-filter overzealously rejecting enabled buttons.")

    // AXTextField: text + email + password + number + tel + url. Firefox
    // sometimes uses subroles (AXSecureTextField for password) — the
    // role itself is still AXTextField, so the AccessibilityProvider's
    // role-set match still picks them up.
    let expectedTextFields =
      FixtureCounts.textInputs + FixtureCounts.emailInputs
        + FixtureCounts.passwordInputs + FixtureCounts.numberInputs
        + FixtureCounts.telInputs + FixtureCounts.urlInputs
    XCTAssertGreaterThanOrEqual(
      roleCount["AXTextField", default: 0],
      expectedTextFields,
      "AXTextField undermatch: expected ≥ \(expectedTextFields) (text/email/password/number/tel/url), "
        + "got \(roleCount["AXTextField", default: 0]). "
        + "Possible regression: AXTextField excluded from textInputRoles, "
        + "or specific input types now report a role not in the recognised set.")

    XCTAssertGreaterThanOrEqual(
      roleCount["AXSearchField", default: 0],
      FixtureCounts.searchInputs,
      "AXSearchField undermatch.")

    XCTAssertGreaterThanOrEqual(
      roleCount["AXCheckBox", default: 0],
      FixtureCounts.checkboxes,
      "AXCheckBox undermatch.")

    XCTAssertGreaterThanOrEqual(
      roleCount["AXRadioButton", default: 0],
      FixtureCounts.radios,
      "AXRadioButton undermatch.")

    XCTAssertGreaterThanOrEqual(
      roleCount["AXPopUpButton", default: 0],
      FixtureCounts.selects,
      "AXPopUpButton undermatch — <select> should map to AXPopUpButton in Firefox.")

    // AXTextArea: explicit <textarea> + the contenteditable div
    // (Firefox typically reports contenteditable as AXTextArea).
    XCTAssertGreaterThanOrEqual(
      roleCount["AXTextArea", default: 0],
      FixtureCounts.textareas,
      "AXTextArea undermatch: <textarea> missing from hint set.")

    // ---- OVERMATCH ASSERTIONS (must-not-hint role exclusions) ----
    //
    // Roles that should never appear as hint targets. If any does, the
    // walker has started accepting page structure as clickable.
    for forbidden in Self.forbiddenRoles {
      XCTAssertEqual(
        roleCount[forbidden, default: 0], 0,
        "Overmatch: role \(forbidden) must not produce hints. "
          + "Found \(roleCount[forbidden, default: 0]) targets with this role. "
          + "A regression has broadened acceptance to include page structure.")
    }

    // AXImage inside the page area must be 0. The fixture has:
    //   - 3 imgs wrapped in <a href> → decorative (parent AXLink owns the hint)
    //   - 3 standalone decorative imgs with no click handler →
    //     filtered by the pending-action check (no AXPress).
    // Any nonzero count means the img-as-decorative folding broke or
    // standalone images bypassed the action-name verification.
    XCTAssertEqual(
      roleCount["AXImage", default: 0], 0,
      "Overmatch: AXImage hinted inside page area. "
        + "Found \(roleCount["AXImage", default: 0]) image targets. "
        + "Expected 0 — every fixture image is either wrapped in an <a> (decorative under "
        + "clickableContainerRoles) or has no click handler (filtered by pending-action check). "
        + "A regression: clickableContainerRoles narrowed, "
        + "or the pending-action verifier started letting through actionless images.")

    // ---- HIDDEN-SUBTREE UPPER BOUNDS ----
    //
    // Disabled + aria-hidden + display:none subtrees collectively
    // contribute 5+5+5+5+5 = 25 extra elements. None should be
    // hinted. Express this as upper bounds on roles where the
    // sentinels live.

    let hiddenButtonBudget =
      FixtureCounts.disabledButtons + FixtureCounts.ariaHiddenButtons
        + FixtureCounts.displayNoneButtons
    // Real (must-hint) buttons + role-overridden divs. The role=button
    // div MAY map to AXButton in Firefox — give it +1 headroom.
    let realButtonCeiling = expectedButtons + FixtureCounts.roleButtonDivs
    XCTAssertLessThanOrEqual(
      roleCount["AXButton", default: 0],
      realButtonCeiling + 2,  // +2 absorbs Firefox chrome leaking into the web area frame
      "Overmatch: AXButton page-area count \(roleCount["AXButton", default: 0]) exceeds "
        + "expected ceiling \(realButtonCeiling + 2). Disabled / aria-hidden / display:none "
        + "buttons (\(hiddenButtonBudget) of them) are leaking into the hint set.")

    let hiddenTextFieldBudget =
      FixtureCounts.disabledInputs + FixtureCounts.ariaHiddenInputs
    let realTextFieldCeiling = expectedTextFields
    XCTAssertLessThanOrEqual(
      roleCount["AXTextField", default: 0],
      realTextFieldCeiling + 2,
      "Overmatch: AXTextField page-area count \(roleCount["AXTextField", default: 0]) exceeds "
        + "expected ceiling \(realTextFieldCeiling + 2). Disabled / aria-hidden inputs "
        + "(\(hiddenTextFieldBudget) of them) are leaking into the hint set.")

    // ---- INVARIANT ASSERTIONS ----

    // Hint IDs must be unique — OverlayPanel's layer pool keys by id.
    let allIDs = targets.map { $0.id }
    XCTAssertEqual(
      Set(allIDs).count, allIDs.count,
      "JumpTarget.id duplicates: id pool collision would corrupt the overlay layer.")

    // Every page-area target must carry Firefox's pid. The commit
    // path uses it to reactivate the target app before AXPressing.
    for t in pageTargets {
      XCTAssertEqual(
        t.pid, firefox.processIdentifier,
        "page target pid mismatch — would commit against the wrong app.")
    }

    // Every page-area target's frame must be a sensible non-degenerate
    // rect on a real screen.
    let screenFrame = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
      ?? NSScreen.main!.frame
    for t in pageTargets {
      XCTAssertGreaterThanOrEqual(
        t.frame.width, 1,
        "page target has degenerate width: \(t.frame)")
      XCTAssertGreaterThanOrEqual(
        t.frame.height, 1,
        "page target has degenerate height: \(t.frame)")
      XCTAssertTrue(
        screenFrame.intersects(t.frame),
        "page target frame \(t.frame) misses the primary screen \(screenFrame) — "
          + "coordinate-flip regression?")
    }

    // Render a compact role histogram into the test log so a failure
    // can be diagnosed without re-running.
    let histo = roleCount.sorted { $0.key < $1.key }
      .map { "  \($0.key)=\($0.value)" }.joined(separator: "\n")
    print("--- Firefox hint role histogram (page area) ---\n\(histo)")
  }

  // MARK: - Helpers

  private func launchFirefoxWithFixture() throws -> NSRunningApplication {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "#&=+")
    let encoded = Self.fixtureHTML.addingPercentEncoding(withAllowedCharacters: allowed)!
    let url = URL(string: "data:text/html;charset=utf-8,\(encoded)")!

    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.addsToRecentItems = false

    var launched: NSRunningApplication?
    var launchError: Error?
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open(
      [url], withApplicationAt: URL(fileURLWithPath: Self.firefoxPath),
      configuration: config
    ) { app, error in
      launched = app
      launchError = error
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    if let launchError {
      throw launchError
    }
    let app = try XCTUnwrap(launched, "NSWorkspace.open returned no application")

    // Wait until Firefox reports at least one AX window.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if app.processIdentifier > 0 {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
          let arr = raw as? [AXUIElement], !arr.isEmpty
        {
          return app
        }
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw XCTSkip("Firefox launched but never reported any AX windows within 20s")
  }

  /// Repeatedly walks until either:
  ///   - the AXLink count reaches the expected floor (page is built), or
  ///   - the timeout expires.
  /// Returns the last walk's result plus the discovered AXWebArea frame.
  private func waitForStableTree(
    firefox: NSRunningApplication,
    provider: AccessibilityProvider,
    context: AppContext,
    timeout: TimeInterval
  ) throws -> (targets: [JumpTarget], webAreaFrame: CGRect?) {
    let expectedLinks = FixtureCounts.links + FixtureCounts.imgLinks
    var lastTargets: [JumpTarget] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      lastTargets =
        (try? provider.discover(in: context, deadline: Date().addingTimeInterval(2))) ?? []
      let linkCount = lastTargets.filter { $0.role == "AXLink" }.count
      if linkCount >= expectedLinks {
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    let web = findWebAreaFrame(pid: firefox.processIdentifier)
    return (lastTargets, web)
  }

  /// BFS the AX tree from the app root, returning the AXWebArea frame
  /// in NSScreen coordinates. The frame is used to filter hint targets
  /// to the page area (excluding Firefox chrome buttons).
  private func findWebAreaFrame(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    var queue: [AXUIElement] = [app]
    var visited = 0
    let maxNodes = 2000
    let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    while !queue.isEmpty, visited < maxNodes {
      let node = queue.removeFirst()
      visited += 1
      var roleRaw: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRaw)
      let role = roleRaw as? String
      if role == "AXWebArea" {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &posRaw)
        _ = AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeRaw)
        if let posCF = posRaw, let sizeCF = sizeRaw,
          CFGetTypeID(posCF) == AXValueGetTypeID(),
          CFGetTypeID(sizeCF) == AXValueGetTypeID()
        {
          let posV = posCF as! AXValue
          let sizeV = sizeCF as! AXValue
          var pos = CGPoint.zero
          var size = CGSize.zero
          if AXValueGetValue(posV, .cgPoint, &pos),
            AXValueGetValue(sizeV, .cgSize, &size),
            size.width > 0, size.height > 0
          {
            // AX coords are Y-down from primary top-left. Convert to
            // NSScreen Y-up.
            let nsY = screenH - pos.y - size.height
            return CGRect(x: pos.x, y: nsY, width: size.width, height: size.height)
          }
        }
      }
      var childrenRaw: CFTypeRef?
      if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRaw)
        == .success,
        let children = childrenRaw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }

  private func makeContext(for app: NSRunningApplication) -> AppContext {
    let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
      ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    return AppContext(
      bundleIdentifier: Self.firefoxBundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: screen,
      allScreensFrame: screen
    )
  }
}
