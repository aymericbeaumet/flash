import FlashCore
import XCTest

@testable import flash

/// `@menus` over a fake menu bar: which items become candidates, and that
/// every element costs one Accessibility round trip.
final class MenuBarWalkTests: XCTestCase {
  private typealias Read = MenuBarSource.MenuElementRead<String>

  /// Element id → its batched read.
  private var tree: [String: Read] = [:]
  private var reads: [String: Int] = [:]

  private func node(
    _ id: String, _ role: String, _ title: String? = nil, enabled: Bool = true,
    _ children: [String] = []
  ) {
    tree[id] = Read(role: role, title: title, enabled: enabled, children: children)
  }

  private func walk(_ bar: [String]) -> [String] {
    let (candidates, elements) = MenuBarSource.walk(pid: 7, barItems: bar) { id in
      self.reads[id, default: 0] += 1
      return self.tree[id] ?? Read(role: nil, title: nil, enabled: true, children: [])
    }
    XCTAssertEqual(elements.count, candidates.count)
    return candidates.map(\.title)
  }

  override func setUp() {
    super.setUp()
    node("apple", "AXMenuBarItem", "Apple", ["apple.menu"])
    node("apple.menu", "AXMenu", nil, ["apple.about"])
    node("apple.about", "AXMenuItem", "About This Mac")
    node("file", "AXMenuBarItem", "File", ["file.menu"])
    node("file.menu", "AXMenu", nil, ["file.new", "file.gone", "file.blank", "file.export", "sep"])
    node("file.new", "AXMenuItem", "New Tab")
    node("file.gone", "AXMenuItem", "Close All", enabled: false)
    node("file.blank", "AXMenuItem", "   ")
    node("file.export", "AXMenuItem", " Export ", ["export.menu"])
    node("export.menu", "AXMenu", nil, ["export.pdf", "export.png"])
    node("export.pdf", "AXMenuItem", "PDF…")
    node("export.png", "AXMenuItem", "PNG…")
    node("sep", "AXUnknown")
    node("view", "AXMenuBarItem", "View")
  }

  func testEnabledTitledLeavesBecomeCandidatesWithTheirPath() {
    XCTAssertEqual(
      walk(["apple", "file", "view"]),
      ["File › New Tab", "File › Export › PDF…", "File › Export › PNG…"],
      "the Apple menu is skipped, disabled and blank items are left out, and a bar item "
        + "without a menu is no candidate")
  }

  /// The regression: a role, a title, an enabled flag and a children list
  /// were four round trips per menu item, and a submenu cost two more.
  func testEveryElementIsReadOnce() {
    _ = walk(["apple", "file", "view"])
    XCTAssertEqual(reads.values.max(), 1, "\(reads)")
    XCTAssertNil(reads["apple"], "the Apple menu is never read")
    XCTAssertEqual(
      Set(reads.keys), Set(tree.keys).subtracting(["apple", "apple.menu", "apple.about"]))
  }

  func testDepthIsBounded() {
    var parent = "deep.menu"
    node("deep", "AXMenuBarItem", "Deep", [parent])
    for level in 0..<8 {
      let item = "deep.\(level)"
      let menu = "deep.\(level).menu"
      node(parent, "AXMenu", nil, [item, "deep.leaf.\(level)"])
      node("deep.leaf.\(level)", "AXMenuItem", "Leaf \(level)")
      node(item, "AXMenuItem", "Level \(level)", [menu])
      parent = menu
    }
    let titles = walk(["apple", "deep"])
    XCTAssertTrue(titles.contains("Deep › Leaf 0"))
    XCTAssertFalse(titles.contains { $0.hasSuffix("Leaf 7") }, "\(titles)")
  }
}
