import AppKit
import XCTest

@testable import flash

/// `#[link=…]` is text a plugin, a source or a program wrote, so what it may
/// hand to macOS is an allowlist of schemes: web and mail links, plus
/// `[statusbar] link_schemes`. Every surface that follows a status link —
/// a click on the bar, an `f` hint, a hyperlink in a popup — goes through
/// the overlay's one `StatusLinkOpener`.
final class StatusLinkGateTests: XCTestCase {
  private func url(_ string: String) -> URL { URL(string: string)! }

  func testWebAndMailLinksOpenAndEveryOtherSchemeIsRefused() {
    XCTAssertTrue(StatusLinkPolicy.permits(url("http://example.com/a"), schemes: []))
    XCTAssertTrue(StatusLinkPolicy.permits(url("https://example.com/a?b=1#c"), schemes: []))
    XCTAssertTrue(StatusLinkPolicy.permits(url("mailto:me@example.com"), schemes: []))
    XCTAssertFalse(StatusLinkPolicy.permits(url("file:///etc/hosts"), schemes: []))
    XCTAssertFalse(StatusLinkPolicy.permits(url("slack://channel?id=1"), schemes: []))
    XCTAssertFalse(
      StatusLinkPolicy.permits(
        url("x-apple.systempreferences:com.apple.preference.battery"), schemes: []))
    XCTAssertFalse(StatusLinkPolicy.permits(url("javascript:alert(1)"), schemes: []))
    XCTAssertFalse(StatusLinkPolicy.permits(url("example.com/no/scheme"), schemes: []))
  }

  func testAnAllowlistedSchemeOpensAndOnlyThatOne() {
    XCTAssertTrue(StatusLinkPolicy.permits(url("slack://channel?id=1"), schemes: ["slack"]))
    XCTAssertFalse(StatusLinkPolicy.permits(url("file:///etc/hosts"), schemes: ["slack"]))
    XCTAssertTrue(StatusLinkPolicy.permits(url("file:///etc/hosts"), schemes: ["file", "slack"]))
    XCTAssertTrue(StatusLinkPolicy.permits(url("https://example.com"), schemes: ["slack"]))
  }

  /// A URL's scheme is case-insensitive (RFC 3986), so `HTTPS://` and
  /// `Slack://` read as `https` and `slack`. The allowlist is the exact
  /// lowercase name: the loader rejects any other spelling and the policy
  /// does not fold one.
  func testTheURLSchemeFoldsToLowercaseAndTheAllowlistIsExact() {
    XCTAssertTrue(StatusLinkPolicy.permits(url("HTTPS://EXAMPLE.COM"), schemes: []))
    XCTAssertTrue(StatusLinkPolicy.permits(url("MailTo:me@example.com"), schemes: []))
    XCTAssertTrue(StatusLinkPolicy.permits(url("Slack://x"), schemes: ["slack"]))
    XCTAssertFalse(StatusLinkPolicy.permits(url("slack://x"), schemes: ["Slack"]))
    XCTAssertEqual(StatusLinkPolicy.scheme(of: url("HTTPS://EXAMPLE.COM")), "https")
    XCTAssertNil(StatusLinkPolicy.scheme(of: url("example.com/no/scheme")))

    for name in ["slack", "x-apple.systempreferences", "git+ssh", "a1", "http"] {
      XCTAssertTrue(StatusLinkPolicy.isSchemeName(name), name)
    }
    for name in ["Slack", "", "1slack", "slack:", "sl ack", "slack://", "-slack", "é"] {
      XCTAssertFalse(StatusLinkPolicy.isSchemeName(name), name)
    }
  }

  func testTheOpenerFollowsPermittedLinksAndNotesEachRefusedSchemeOnce() {
    let opener = StatusLinkOpener()
    var opened: [URL] = []
    opener.open = { opened.append($0) }
    XCTAssertTrue(opener.follow(url("https://example.com")))
    XCTAssertFalse(opener.follow(url("file:///a")))
    XCTAssertFalse(opener.follow(url("file:///b")))
    XCTAssertFalse(opener.follow(url("slack://c")))
    XCTAssertFalse(opener.follow(url("example.com/no/scheme")))
    XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
    XCTAssertEqual(opener.refusedSchemes, ["file", "slack", "(none)"])

    opener.schemes = ["slack"]
    XCTAssertEqual(opener.refusedSchemes, ["file", "(none)"], "an allowed scheme leaves the note")
    XCTAssertTrue(opener.follow(url("slack://c")))
    XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com", "slack://c"])
  }

  func testTheNoteHoldsABoundedNumberOfSchemes() {
    let opener = StatusLinkOpener()
    opener.open = { _ in }
    for index in 0..<(StatusLinkOpener.refusedSchemesLimit + 8) {
      opener.follow(url("scheme\(index)://x"))
    }
    XCTAssertEqual(opener.refusedSchemes.count, StatusLinkOpener.refusedSchemesLimit)
    XCTAssertEqual(opener.refusedSchemes.first, "scheme0")
  }

  func testARefusedHintLinkNeverLogsItsPathOrQuery() throws {
    let panel = OverlayPanel()
    let sentinel = "private-status-link-sentinel"
    let lock = NSLock()
    var logs: [String] = []
    let sink = FlashLog.addSink { record in
      lock.withLock { logs.append(record.message + String(describing: record.fields)) }
    }
    defer { FlashLog.removeSink(sink) }
    let refused = url("file:///\(sentinel)?token=\(sentinel)")
    panel.activateStatusBarLink(refused)
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
    view.links = [(rect: view.bounds, url: refused)]
    panel.wireStatusBarClickView(view, band: view.bounds)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: event)
    view.mouseUp(with: event)
    XCTAssertEqual(panel.statusLinkOpener.refusedSchemes, ["file"])
    XCTAssertFalse(lock.withLock { logs.contains { $0.contains(sentinel) } })
  }

  /// A hinted link, a physical click on the bar and a hyperlink in a popup's
  /// pager or program all leave through the overlay's opener, so one
  /// allowlist governs them.
  func testEveryStatusLinkSurfaceFollowsThroughTheOverlaysOpener() {
    let panel = OverlayPanel()
    var opened: [URL] = []
    panel.statusLinkOpener.open = { opened.append($0) }
    panel.statusLinkOpener.schemes = ["slack"]

    panel.activateStatusBarLink(url("file:///etc/hosts"))
    panel.activateStatusBarLink(url("https://example.com/hint"))

    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    view.activate(url: url("https://example.com/unwired"))
    XCTAssertEqual(opened.count, 1, "a click view with no opener opens nothing")
    panel.wireStatusBarClickView(view, band: view.frame)
    view.activate(url: url("x-apple.systempreferences:com.apple.preference.battery"))
    view.activate(url: url("slack://channel"))
    view.activate(url: url("mailto:me@example.com"))

    panel.statusPopupController.terminalView.openURL(url("file:///tmp/x"))
    panel.statusPopupController.terminalView.openURL(url("https://example.com/popup"))

    XCTAssertEqual(
      opened.map(\.absoluteString),
      [
        "https://example.com/hint", "slack://channel", "mailto:me@example.com",
        "https://example.com/popup",
      ])
    XCTAssertEqual(
      panel.statusLinkOpener.refusedSchemes, ["file", "x-apple.systempreferences"])
  }

  /// A `#[range=user|…]` span is an action for `[statusbar.click]`, never a
  /// URL for macOS: it reaches the handler whatever the allowlist says.
  func testARangeActionIsNotALinkAndNeverReachesTheOpener() throws {
    let panel = OverlayPanel()
    var opened: [URL] = []
    var actions: [String] = []
    panel.statusLinkOpener.open = { opened.append($0) }
    panel.statusBarActionHandler = { actions.append($0) }
    let action = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "bat-prefs"))
    panel.activateStatusBarLink(action)
    XCTAssertEqual(actions, ["bat-prefs"])
    XCTAssertTrue(opened.isEmpty)
    XCTAssertTrue(panel.statusLinkOpener.refusedSchemes.isEmpty)
  }
}
