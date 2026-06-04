import FlashBrowserTestSupport
import XCTest

final class BrowserFixtureCatalogTests: XCTestCase {
  func testCatalogContainsOneHundredDiverseFixtures() throws {
    let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/BrowserSnapshots", isDirectory: true)
    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    XCTAssertEqual(catalog.fixtures.count, 100)
    XCTAssertEqual(Set(catalog.fixtures.map(\.name)).count, 100)

    let byCategory = Dictionary(grouping: catalog.fixtures, by: \.category)
    XCTAssertGreaterThanOrEqual(byCategory.count, 7)
    XCTAssertEqual(byCategory["synthetic-controls"]?.count, 20)
    XCTAssertEqual(byCategory["synthetic-layout"]?.count, 20)
    XCTAssertEqual(byCategory["docs-reference"]?.count, 12)
    XCTAssertEqual(byCategory["article-news"]?.count, 12)
    XCTAssertEqual(byCategory["forum-thread"]?.count, 12)
    XCTAssertEqual(byCategory["developer-code"]?.count, 12)
    XCTAssertEqual(byCategory["commerce-listing"]?.count, 12)

    for fixture in catalog.fixtures {
      let path =
        fixturesDir
        .appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent(fixture.file)
      XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), fixture.file)
    }
  }

  func testFixtureSelectionRejectsUnknownNames() throws {
    let catalog = BrowserFixtureCatalog(fixtures: [
      BrowserFixture(
        name: "baseline-synthetic-001",
        file: "baseline-synthetic-001.html",
        category: "synthetic-controls",
        kind: "synthetic")
    ])

    XCTAssertEqual(try catalog.select(named: ["baseline-synthetic-001"]).count, 1)
    XCTAssertThrowsError(try catalog.select(named: ["missing"]))
  }
}
