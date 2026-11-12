import XCTest

@testable import flash

/// `[tiling]` parsing: off by default, every key validated with a located
/// diagnostic.
final class TilingConfigTests: XCTestCase {
  func testTilingIsOffByDefault() {
    XCTAssertEqual(ConfigLoader.parse("").tiling, TilingSettings())
    XCTAssertFalse(Config.default.tiling.enabled)
  }

  func testEveryKeyParses() {
    let config = ConfigLoader.parse(
      """
      [tiling]
      enabled = true
      layout = "accordion"
      orientation = "vertical"
      accordion_padding = 12
      workspaces = ["1", "2", "web"]

      [tiling.gaps]
      inner = 8
      outer = 6
      outer_top = 0

      [tiling.monitors]
      "web" = "secondary"
      "2" = 2

      [[tiling.rules]]
      bundle_id = "com.apple.finder"
      float = true

      [[tiling.rules]]
      bundle_id = "com.example.Chat"
      title_contains = "Inbox"
      workspace = 3
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let tiling = config.tiling
    XCTAssertTrue(tiling.enabled)
    XCTAssertEqual(tiling.layout, .accordion)
    XCTAssertEqual(tiling.orientation, .vertical)
    XCTAssertEqual(tiling.accordionPadding, 12)
    XCTAssertEqual(tiling.workspaces, ["1", "2", "web"])
    XCTAssertEqual(
      tiling.gaps,
      TilingGaps(
        innerHorizontal: 8, innerVertical: 8, outerLeft: 6, outerRight: 6, outerTop: 0,
        outerBottom: 6))
    XCTAssertEqual(tiling.pinned, ["web": .secondary, "2": .index(2)])
    XCTAssertEqual(
      tiling.rules,
      [
        TilingRule(bundleID: "com.apple.finder", floats: true),
        TilingRule(bundleID: "com.example.Chat", titleContains: "Inbox", workspace: "3"),
      ])
  }

  func testInvalidValuesAreReportedWhereTheyAre() {
    let config = ConfigLoader.parse(
      """
      [tiling]
      layout = "bsp"
      orientation = "diagonal"
      accordion_padding = 500
      workspaces = ["one", "two words"]

      [tiling.gaps]
      inner = -1
      middle = 2

      [tiling.monitors]
      "9" = "left"

      [[tiling.rules]]
      bundle_id = "com.example.App"

      [[tiling.rules]]
      bundle_id = "com.example.App"
      float = "yes"
      """)
    let messages = config.loadingDiagnostics.map(\.message)
    for expected in [
      "tiling.layout must be \"tiles\" or \"accordion\"",
      "tiling.orientation must be \"auto\", \"horizontal\" or \"vertical\"",
      "tiling.accordion_padding must be an integer between 0 and 200 (points)",
      "tiling.workspaces names must be unique words without spaces, at most 32 characters",
      "tiling.gaps.inner must be an integer between 0 and 200 (points)",
      "tiling.gaps: unknown key 'middle'",
      "tiling.monitors.9 must be \"main\", \"secondary\" or a display number from 1",
      "tiling.rules[0] needs float or workspace",
      "tiling.rules[1].float must be true or false",
    ] {
      XCTAssertTrue(
        messages.contains { $0.hasPrefix(expected) }, "missing: \(expected)\n\(messages)")
    }
    XCTAssertTrue(config.loadingDiagnostics.allSatisfy { $0.location != nil }, "located")
  }
}

/// What the bar and plugins read of the workspaces.
final class TilingStatusTests: XCTestCase {
  func testTheBarReadsTheFocusedAndListedWorkspaces() {
    var context = FlashStatusBarContext()
    context.workspace = "2"
    context.workspaces = "1 2 web"
    let values = FlashStatusBarTemplateEngine.formatContext(context).values
    XCTAssertEqual(values["flash.workspace"], "2")
    XCTAssertEqual(values["flash.workspaces"], "1 2 web")
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.formatContext(.init()).values["flash.workspace"], "")
    XCTAssertEqual(FlashStatusBarTemplateEngine.sdkValue(for: "flash.workspace"), .workspace)
    XCTAssertEqual(FlashStatusBarTemplateEngine.sdkValue(for: "flash.workspaces"), .workspaces)
  }

  /// `core:workspace.changed` fires when the focused workspace changes, not
  /// when only the list does.
  func testTheWorkspaceEventFollowsTheFocusedWorkspace() throws {
    let first = TilingStatus(focused: "1", listed: ["1", "2"], previous: nil)
    let initial = try XCTUnwrap(first.workspaceChange(since: nil))
    XCTAssertEqual(initial["workspace"] as? String, "1")
    XCTAssertEqual(initial["workspaces"] as? [String], ["1", "2"])
    XCTAssertNil(initial["previous"])

    let switched = TilingStatus(focused: "2", listed: ["1", "2"], previous: "1")
    XCTAssertEqual(switched.workspaceChange(since: first)?["previous"] as? String, "1")
    let renamed = TilingStatus(focused: "2", listed: ["1", "2", "web"], previous: "1")
    XCTAssertNil(renamed.workspaceChange(since: switched))
    XCTAssertNil(TilingStatus(focused: nil, listed: [], previous: nil).workspaceChange(since: nil))
  }
}
