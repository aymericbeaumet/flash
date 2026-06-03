import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import Foundation

// MARK: - Why this exists
//
// `swift test` runs through `swiftpm-xctest-helper`, an Apple-signed
// binary that loads the test bundle as a dylib. Granting it
// Accessibility in System Settings should be enough, but in practice
// the permission frequently doesn't take (cdhash drift across Xcode
// updates, stale TCC state from previous grants, or a toggle that
// silently flips off after re-add).
//
// This standalone executable bypasses xctest entirely. After a single
// `swift build -c release` + ad-hoc codesign, the resulting binary
// lives at a stable path you can add to TCC once. Subsequent rebuilds
// keep working as long as the binary at that path is the one re-signed
// in place.
//
// Use Scripts/build-firefox-e2e.sh to build + sign + print the path
// you need to grant.

// MARK: - Fixture HTML
//
// Same shape as Tests/FlashTests/FirefoxIntegrationTests.swift —
// kept as a literal here because the CLI runner is a thin shell over
// the same logic and the file isn't imported by the test target.

private enum FixtureCounts {
  // Must-hint controls.
  static let links = 5
  static let imgLinks = 3
  static let buttons = 5
  static let submitInputs = 1
  static let textInputs = 2
  static let emailInputs = 2
  static let passwordInputs = 1
  static let numberInputs = 1
  static let telInputs = 1
  static let urlInputs = 1
  static let searchInputs = 1
  static let checkboxes = 2
  static let radios = 3
  static let selects = 1
  static let textareas = 1
  static let detailsBlocks = 1
  static let contentEditables = 1
  static let roleButtonDivs = 1
  static let roleLinkDivs = 1

  // Must-not-hint elements.
  static let headings = 5
  static let paragraphs = 5
  static let plainDivs = 5
  static let plainImages = 3

  // Hidden / disabled sentinels.
  static let disabledButtons = 5
  static let disabledInputs = 5
  static let ariaHiddenButtons = 5
  static let ariaHiddenInputs = 5
  static let displayNoneButtons = 5
}

private let fixtureHTML: String = {
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

private let forbiddenRoles: Set<String> = [
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

// MARK: - Output helpers

private enum Colour {
  static let red = "\u{1B}[31m"
  static let green = "\u{1B}[32m"
  static let yellow = "\u{1B}[33m"
  static let bold = "\u{1B}[1m"
  static let reset = "\u{1B}[0m"
}

private func log(_ s: String) {
  print(s)
  fflush(stdout)
}

private final class Failures {
  private(set) var messages: [String] = []
  func record(_ msg: String) {
    messages.append(msg)
    log("\(Colour.red)✗\(Colour.reset) \(msg)")
  }
  func pass(_ msg: String) {
    log("\(Colour.green)✓\(Colour.reset) \(msg)")
  }
}

// MARK: - Permission check

private func ensureAccessibilityOrExit() {
  if AXIsProcessTrusted() { return }
  let me = (CommandLine.arguments.first as NSString?)?.standardizingPath ?? "<self>"
  log("""
    \(Colour.red)Accessibility permission missing.\(Colour.reset)

    This binary needs to be granted Accessibility before it can walk
    Firefox's AX tree. The binary path:

      \(me)

    To grant:
      1. Open System Settings → Privacy & Security → Accessibility
      2. Click +, press ⌘⇧G, paste the path above.
      3. Toggle the new entry on.
      4. Re-run this binary.

    Notes:
      - Granting your terminal does NOT propagate to this binary.
      - The binary's ad-hoc signature is regenerated by `swift build`,
        which invalidates the TCC grant. Use Scripts/build-firefox-e2e.sh,
        which signs in place at a stable path so subsequent rebuilds at
        the same path keep the grant working.
    """)
  exit(2)
}

// MARK: - Firefox launch + AX walk

private let firefoxBundleID = "org.mozilla.firefox"
private let firefoxPath = "/Applications/Firefox.app"

private func launchFirefox() -> NSRunningApplication? {
  guard FileManager.default.fileExists(atPath: firefoxPath) else {
    log("\(Colour.red)Firefox not installed at \(firefoxPath)\(Colour.reset)")
    return nil
  }
  var allowed = CharacterSet.urlQueryAllowed
  allowed.remove(charactersIn: "#&=+")
  let encoded = fixtureHTML.addingPercentEncoding(withAllowedCharacters: allowed)!
  let url = URL(string: "data:text/html;charset=utf-8,\(encoded)")!

  let config = NSWorkspace.OpenConfiguration()
  config.activates = true
  config.addsToRecentItems = false

  var launched: NSRunningApplication?
  let sem = DispatchSemaphore(value: 0)
  NSWorkspace.shared.open(
    [url], withApplicationAt: URL(fileURLWithPath: firefoxPath),
    configuration: config
  ) { app, _ in
    launched = app
    sem.signal()
  }
  _ = sem.wait(timeout: .now() + 20)
  return launched
}

private func waitForAXWindow(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if app.processIdentifier > 0 {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
        let arr = raw as? [AXUIElement], !arr.isEmpty
      {
        return true
      }
    }
    Thread.sleep(forTimeInterval: 0.25)
  }
  return false
}

private func findWebAreaFrame(pid: pid_t) -> CGRect? {
  let app = AXUIElementCreateApplication(pid)
  var queue: [AXUIElement] = [app]
  var visited = 0
  let maxNodes = 2000
  let screenH =
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
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
  let screen =
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
    ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
  return AppContext(
    bundleIdentifier: firefoxBundleID,
    processID: app.processIdentifier,
    runningApp: app,
    frontWindowFrame: screen,
    allScreensFrame: screen
  )
}

// MARK: - Assertions

private func runAssertions(targets: [JumpTarget], webAreaFrame: CGRect?, firefox: NSRunningApplication) -> Failures {
  let f = Failures()

  if targets.isEmpty {
    f.record("AccessibilityProvider returned 0 targets — AX engine likely never woke")
    return f
  } else {
    f.pass("provider returned \(targets.count) total targets")
  }

  let pageTargets: [JumpTarget]
  if let web = webAreaFrame {
    pageTargets = targets.filter { web.intersects($0.frame) }
    f.pass("located AXWebArea frame \(web) — \(pageTargets.count) targets in page area")
  } else {
    pageTargets = targets
    f.record("could not locate AXWebArea frame; assertions degraded to total counts")
  }

  var roleCount: [String: Int] = [:]
  for t in pageTargets {
    roleCount[t.role ?? "<nil>", default: 0] += 1
  }

  // -- Undermatch --
  func assertAtLeast(_ role: String, _ floor: Int, _ context: String) {
    let got = roleCount[role, default: 0]
    if got >= floor {
      f.pass("\(role): \(got) ≥ \(floor)  (\(context))")
    } else {
      f.record("\(role) undermatch: expected ≥ \(floor), got \(got)  (\(context))")
    }
  }

  let expectedLinks = FixtureCounts.links + FixtureCounts.imgLinks
  assertAtLeast("AXLink", expectedLinks, "5 anchors + 3 image-wrapped")

  let expectedButtons = FixtureCounts.buttons + FixtureCounts.submitInputs
  assertAtLeast("AXButton", expectedButtons, "5 <button> + 1 submit")

  let expectedTextFields =
    FixtureCounts.textInputs + FixtureCounts.emailInputs
    + FixtureCounts.passwordInputs + FixtureCounts.numberInputs
    + FixtureCounts.telInputs + FixtureCounts.urlInputs
  assertAtLeast("AXTextField", expectedTextFields, "text/email/password/number/tel/url")

  assertAtLeast("AXSearchField", FixtureCounts.searchInputs, "<input type=search>")
  assertAtLeast("AXCheckBox", FixtureCounts.checkboxes, "<input type=checkbox>")
  assertAtLeast("AXRadioButton", FixtureCounts.radios, "<input type=radio>")
  assertAtLeast("AXPopUpButton", FixtureCounts.selects, "<select>")
  assertAtLeast("AXTextArea", FixtureCounts.textareas, "<textarea>")

  // -- Overmatch by role --
  for forbidden in forbiddenRoles {
    let n = roleCount[forbidden, default: 0]
    if n == 0 {
      f.pass("forbidden \(forbidden): 0")
    } else {
      f.record("Overmatch: role \(forbidden) must not produce hints, got \(n)")
    }
  }

  let imageCount = roleCount["AXImage", default: 0]
  if imageCount == 0 {
    f.pass("AXImage: 0 inside page area (img-as-decorative + actionless image filtering both work)")
  } else {
    f.record("Overmatch: AXImage \(imageCount) inside page area — expected 0")
  }

  // -- Hidden subtree ceilings --
  let realButtonCeiling = expectedButtons + FixtureCounts.roleButtonDivs
  let buttonsGot = roleCount["AXButton", default: 0]
  if buttonsGot <= realButtonCeiling + 2 {
    f.pass("AXButton ceiling: \(buttonsGot) ≤ \(realButtonCeiling + 2)")
  } else {
    f.record("Overmatch: AXButton \(buttonsGot) > \(realButtonCeiling + 2) — disabled / aria-hidden / display:none buttons leaking through")
  }

  let realTextFieldCeiling = expectedTextFields
  let textGot = roleCount["AXTextField", default: 0]
  if textGot <= realTextFieldCeiling + 2 {
    f.pass("AXTextField ceiling: \(textGot) ≤ \(realTextFieldCeiling + 2)")
  } else {
    f.record("Overmatch: AXTextField \(textGot) > \(realTextFieldCeiling + 2) — disabled / aria-hidden inputs leaking through")
  }

  // -- Invariants --
  let ids = targets.map { $0.id }
  if Set(ids).count == ids.count {
    f.pass("target ids are unique (\(ids.count))")
  } else {
    f.record("duplicate target ids — overlay layer pool would collide")
  }

  let wrongPid = pageTargets.filter { $0.pid != firefox.processIdentifier }
  if wrongPid.isEmpty {
    f.pass("all page targets carry Firefox's pid")
  } else {
    f.record("\(wrongPid.count) page targets carry wrong pid")
  }

  let screenFrame =
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
    ?? NSScreen.main!.frame
  let offscreen = pageTargets.filter { !screenFrame.intersects($0.frame) }
  if offscreen.isEmpty {
    f.pass("all page-target frames intersect the primary screen")
  } else {
    f.record("\(offscreen.count) page targets miss the primary screen — coordinate flip?")
  }

  // -- Histogram --
  log("\n\(Colour.bold)Role histogram (page area):\(Colour.reset)")
  for (role, count) in roleCount.sorted(by: { $0.key < $1.key }) {
    log("  \(role.padding(toLength: 24, withPad: " ", startingAt: 0))\(count)")
  }

  return f
}

// MARK: - Main

ensureAccessibilityOrExit()

log("\(Colour.bold)Flash Firefox E2E\(Colour.reset)")
log("Launching Firefox with fixture page…")

guard let firefox = launchFirefox() else {
  exit(2)
}
defer { firefox.terminate() }

if !waitForAXWindow(firefox, timeout: 20) {
  log("\(Colour.red)Firefox launched but no AX window appeared within 20s\(Colour.reset)")
  exit(2)
}
firefox.activate(options: [])

let provider = AccessibilityProvider()
let context = makeContext(for: firefox)
let expectedLinks = FixtureCounts.links + FixtureCounts.imgLinks

log("Waiting for AX tree to settle…")
var targets: [JumpTarget] = []
let settleDeadline = Date().addingTimeInterval(20)
while Date() < settleDeadline {
  targets =
    (try? provider.discover(in: context, deadline: Date().addingTimeInterval(2))) ?? []
  let links = targets.filter { $0.role == "AXLink" }.count
  if links >= expectedLinks { break }
  Thread.sleep(forTimeInterval: 0.25)
}
let webAreaFrame = findWebAreaFrame(pid: firefox.processIdentifier)

log("\n\(Colour.bold)Running assertions…\(Colour.reset)\n")
private let failures = runAssertions(targets: targets, webAreaFrame: webAreaFrame, firefox: firefox)

log("")
if failures.messages.isEmpty {
  log("\(Colour.green)\(Colour.bold)PASS\(Colour.reset) — every invariant held")
  exit(0)
} else {
  log("\(Colour.red)\(Colour.bold)FAIL\(Colour.reset) — \(failures.messages.count) assertion(s) failed:")
  for m in failures.messages {
    log("  • \(m)")
  }
  exit(1)
}
