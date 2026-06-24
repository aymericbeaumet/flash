import FlashBrowserTestSupport
import XCTest

final class BrowserFixtureCatalogTests: XCTestCase {
  func testCatalogCoversEverySyntheticTemplateAndAllSnapshotFiles() throws {
    let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/BrowserSnapshots", isDirectory: true)
    let snapshotFiles = try htmlSnapshotFiles(in: fixturesDir)
    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    XCTAssertEqual(Set(catalog.fixtures.map(\.name)).count, catalog.fixtures.count)
    XCTAssertEqual(Set(catalog.fixtures.map(\.file)), Set(snapshotFiles))

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

  func testCatalogAutodiscoversSnapshotFilesMissingFromManifest() throws {
    let fixturesDir = try temporaryFixturesDirectory()
    let snapshotsDir = fixturesDir.appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(
      at: snapshotsDir,
      withIntermediateDirectories: true)
    try """
    <html><body><a href="/">Known</a></body></html>
    """.write(
      to: snapshotsDir.appendingPathComponent("known.html"),
      atomically: true,
      encoding: .utf8)
    try """
    <html><body><a href="/">Collected</a></body></html>
    """.write(
      to: snapshotsDir.appendingPathComponent("collected-new-page-001.html"),
      atomically: true,
      encoding: .utf8)
    try """
    {
      "fixtures": [
        {
          "name": "known-name",
          "file": "known.html",
          "kind": "synthetic",
          "category": "synthetic-controls"
        }
      ]
    }
    """.write(
      to: fixturesDir.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)

    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    XCTAssertEqual(catalog.fixtures.map(\.name), ["known-name", "collected-new-page-001"])
    XCTAssertEqual(catalog.fixtures.map(\.file), ["known.html", "collected-new-page-001.html"])
    XCTAssertEqual(catalog.fixtures[1].category, "collected-regression")
    XCTAssertEqual(catalog.fixtures[1].kind, "collected")
  }

  func testCatalogLoadsWithoutManifest() throws {
    let fixturesDir = try temporaryFixturesDirectory()
    let snapshotsDir = fixturesDir.appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(
      at: snapshotsDir,
      withIntermediateDirectories: true)
    try """
    <html><body><button>Run</button></body></html>
    """.write(
      to: snapshotsDir.appendingPathComponent("baseline-synthetic-extra.html"),
      atomically: true,
      encoding: .utf8)

    let catalog = try BrowserFixtureCatalog.load(from: fixturesDir)

    XCTAssertEqual(catalog.fixtures.count, 1)
    XCTAssertEqual(catalog.fixtures[0].name, "baseline-synthetic-extra")
    XCTAssertEqual(catalog.fixtures[0].category, "synthetic-controls")
    XCTAssertEqual(catalog.fixtures[0].kind, "synthetic")
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

  private func htmlSnapshotFiles(in fixturesDir: URL) throws -> [String] {
    let snapshotsDir = fixturesDir.appendingPathComponent("snapshots", isDirectory: true)
    return try FileManager.default
      .contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "html" }
      .map(\.lastPathComponent)
      .sorted()
  }

  private func temporaryFixturesDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-browser-fixtures-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
