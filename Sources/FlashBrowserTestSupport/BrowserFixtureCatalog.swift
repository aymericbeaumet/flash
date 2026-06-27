import Foundation

public struct BrowserFixture: Decodable, Sendable {
  public let name: String
  public let file: String
  public let category: String
  public let kind: String

  public var displayName: String { name }

  public init(name: String, file: String, category: String, kind: String) {
    self.name = name
    self.file = file
    self.category = category
    self.kind = kind
  }

  public func html(fixturesDirectory: URL) throws -> String {
    let url =
      fixturesDirectory
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(file)
    return try String(contentsOf: url, encoding: .utf8)
  }

  public func allowListURL(fixturesDirectory: URL) -> URL {
    let base = (file as NSString).deletingPathExtension
    return
      fixturesDirectory
      .appendingPathComponent("allowlists", isDirectory: true)
      .appendingPathComponent("\(base).allowed.json")
  }

  public func loadAllowList(fixturesDirectory: URL) -> OracleAllowList {
    let url = allowListURL(fixturesDirectory: fixturesDirectory)
    guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
    return (try? OracleAllowList.load(from: url)) ?? .empty
  }
}

public struct BrowserFixtureCatalog: Decodable {
  public let fixtures: [BrowserFixture]

  public init(fixtures: [BrowserFixture]) {
    self.fixtures = fixtures
  }

  public static func load(from fixturesDirectory: URL) throws -> BrowserFixtureCatalog {
    let snapshotsDir = fixturesDirectory.appendingPathComponent("snapshots", isDirectory: true)
    let snapshotFiles = try snapshotHTMLFiles(in: snapshotsDir)
    guard !snapshotFiles.isEmpty else {
      throw CatalogError.noSnapshots(snapshotsDir.path)
    }

    let filesOnDisk = Set(snapshotFiles)
    let manifestFixtures = try loadManifestFixtures(from: fixturesDirectory)

    var fixtures: [BrowserFixture] = []
    var seenFiles = Set<String>()
    var seenNames = Set<String>()

    func append(_ fixture: BrowserFixture) throws {
      guard seenFiles.insert(fixture.file).inserted else { return }
      guard seenNames.insert(fixture.name).inserted else {
        throw CatalogError.duplicateFixtureName(fixture.name)
      }
      fixtures.append(fixture)
    }

    for fixture in manifestFixtures where filesOnDisk.contains(fixture.file) {
      try append(fixture)
    }

    for file in snapshotFiles where !seenFiles.contains(file) {
      try append(inferredFixture(for: file))
    }

    return BrowserFixtureCatalog(fixtures: fixtures)
  }

  public func select(named names: [String]) throws -> [BrowserFixture] {
    guard !names.isEmpty else { return fixtures }
    var selected: [BrowserFixture] = []
    for name in names {
      guard
        let fixture = fixtures.first(where: { fixture in
          fixture.name == name
            || fixture.file == name
            || (fixture.file as NSString).deletingPathExtension == name
        })
      else {
        let known = fixtures.map(\.name).joined(separator: ", ")
        throw SelectionError.unknownFixture(name: name, known: known)
      }
      selected.append(fixture)
    }
    return selected
  }

  public enum SelectionError: Error, CustomStringConvertible {
    case unknownFixture(name: String, known: String)

    public var description: String {
      switch self {
      case .unknownFixture(let name, let known):
        return "Unknown fixture: \(name). Known: \(known)"
      }
    }
  }

  public enum CatalogError: Error, CustomStringConvertible {
    case noSnapshots(String)
    case duplicateFixtureName(String)

    public var description: String {
      switch self {
      case .noSnapshots(let path):
        return "No browser fixture snapshots found in \(path)"
      case .duplicateFixtureName(let name):
        return "Duplicate browser fixture name: \(name)"
      }
    }
  }

  private static func loadManifestFixtures(from fixturesDirectory: URL) throws -> [BrowserFixture] {
    let url = fixturesDirectory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(BrowserFixtureCatalog.self, from: data).fixtures
  }

  private static func snapshotHTMLFiles(in snapshotsDir: URL) throws -> [String] {
    try FileManager.default
      .contentsOfDirectory(
        at: snapshotsDir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
      .filter { url in
        guard url.pathExtension.lowercased() == "html" else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? true
      }
      .map(\.lastPathComponent)
      .sorted()
  }

  private static func inferredFixture(for file: String) -> BrowserFixture {
    let name = (file as NSString).deletingPathExtension
    let metadata = inferredMetadata(for: name)
    return BrowserFixture(
      name: name,
      file: file,
      category: metadata.category,
      kind: metadata.kind)
  }

  private static func inferredMetadata(for name: String) -> (category: String, kind: String) {
    if name.hasPrefix("baseline-synthetic") {
      return ("synthetic-controls", "synthetic")
    }
    if name.hasPrefix("layout-synthetic") {
      return ("synthetic-layout", "synthetic")
    }
    if name.hasPrefix("docs-reference") {
      return ("docs-reference", "realistic")
    }
    if name.hasPrefix("article-news") {
      return ("article-news", "realistic")
    }
    if name.hasPrefix("forum-thread") {
      return ("forum-thread", "realistic")
    }
    if name.hasPrefix("developer-code") {
      return ("developer-code", "realistic")
    }
    if name.hasPrefix("commerce-listing") {
      return ("commerce-listing", "realistic")
    }
    return ("collected-regression", "collected")
  }
}
