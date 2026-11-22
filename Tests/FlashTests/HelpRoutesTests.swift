import Foundation
import XCTest

@testable import flash

/// The browser help's page table (`DebugServer.Page.Name`), which the
/// frontend reads from Inspector/src/lib/help-routes.json.
/// `FLASH_WRITE_SCHEMA=1 swift test --filter HelpRoutesTests` (or
/// `mise run build:schema`) rewrites the committed copy.
final class HelpRoutesTests: XCTestCase {
  private typealias Name = DebugServer.Page.Name

  private static let published = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Inspector/src/lib/help-routes.json")

  private static var generated: String {
    func list(_ names: [Name]) -> String {
      names.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }
    return """
      {
        "pages": [\(list(Name.allCases))],
        "detailPages": [\(list(Name.detailed))]
      }

      """
  }

  func testTheFrontendsPageTableIsCurrent() throws {
    if ProcessInfo.processInfo.environment["FLASH_WRITE_SCHEMA"] == "1" {
      try Self.generated.write(to: Self.published, atomically: true, encoding: .utf8)
    }
    let committed = try String(contentsOf: Self.published, encoding: .utf8)
    XCTAssertEqual(
      committed, Self.generated,
      "Inspector/src/lib/help-routes.json is stale: run mise run build:schema")
  }

  func testEveryNamedPageIsServedAtItsName() {
    for name in Name.allCases {
      let path = "/\(name.rawValue)"
      XCTAssertEqual(DebugServer.Page(path: path)?.path, path)
      XCTAssertEqual(DebugServer.route(path: path), .app(found: true), path)
      // Only the manual and the detailed pages take a further segment.
      XCTAssertEqual(
        DebugServer.Page(path: "\(path)/tmux")?.path,
        name == .docs || Name.detailed.contains(name) ? "\(path)/tmux" : nil, path)
      XCTAssertEqual(
        DebugServer.Page(path: "\(path)/tmux/panes")?.path,
        name == .docs ? "\(path)/tmux/panes" : nil, path)
    }
    XCTAssertNil(DebugServer.Page(path: "/guides"))
  }
}
