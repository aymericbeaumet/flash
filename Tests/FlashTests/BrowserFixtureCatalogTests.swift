import FlashBrowserTestSupport
import XCTest

final class BrowserFixtureCatalogTests: XCTestCase {
  func testCatalogCoversEverySyntheticTemplateAndAllCollectedSnapshots() throws {
    let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/BrowserSnapshots", isDirectory: true)
    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    XCTAssertEqual(Set(catalog.fixtures.map(\.name)).count, catalog.fixtures.count)

    let byCategory = Dictionary(grouping: catalog.fixtures, by: \.category)
    // Each synthetic template now has exactly one canonical fixture; the
    // numbered duplicates that previously padded each category were just
    // re-labelled clones of the same DOM and added no signal coverage.
    XCTAssertEqual(byCategory["synthetic-controls"]?.count, 1)
    XCTAssertEqual(byCategory["synthetic-layout"]?.count, 1)
    XCTAssertEqual(byCategory["docs-reference"]?.count, 1)
    XCTAssertEqual(byCategory["article-news"]?.count, 1)
    XCTAssertEqual(byCategory["forum-thread"]?.count, 1)
    XCTAssertEqual(byCategory["developer-code"]?.count, 1)
    XCTAssertEqual(byCategory["commerce-listing"]?.count, 1)
    // Collected fixtures are real-world page captures and are kept
    // 1:1 with the snapshots/ files.
    let collected = byCategory["collected-regression"] ?? []
    XCTAssertGreaterThanOrEqual(collected.count, 20)

    for fixture in catalog.fixtures {
      let path =
        fixturesDir
        .appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent(fixture.file)
      XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), fixture.file)
    }
  }

  /// Reverse of the file-existence check above: guards against an orphaned
  /// `snapshots/*.html` that no manifest entry references. Such a file would
  /// never be exercised by the browser oracle yet would silently ship and rot.
  func testEverySnapshotFileIsReferencedByManifest() throws {
    let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/BrowserSnapshots", isDirectory: true)
    let snapshotsDir = fixturesDir.appendingPathComponent("snapshots", isDirectory: true)
    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    let referenced = Set(catalog.fixtures.map(\.file))
    let onDisk = try FileManager.default
      .contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "html" }
      .map { $0.lastPathComponent }

    for file in onDisk {
      XCTAssertTrue(
        referenced.contains(file),
        "snapshots/\(file) exists on disk but is not listed in manifest.json")
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

  func testAllowListMatchesShiftedEquivalentTargetsByKind() {
    let allowList = OracleAllowList(entries: [
      AllowListEntry(
        side: .flashOnly,
        rect: [1366.5, 871, 284, 46.5],
        reason: "fixture chrome drift",
        axRole: "AXLink")
    ])

    XCTAssertTrue(
      allowList.contains(
        rect: CGRect(x: 1510, y: 841, width: 284, height: 46),
        side: .flashOnly,
        axRole: "AXLink"))
    XCTAssertFalse(
      allowList.contains(
        rect: CGRect(x: 1510, y: 841, width: 284, height: 46),
        side: .flashOnly,
        axRole: "AXButton"))
    XCTAssertFalse(
      allowList.contains(
        rect: CGRect(x: 1510, y: 841, width: 200, height: 46),
        side: .flashOnly,
        axRole: "AXLink"))
  }
}
