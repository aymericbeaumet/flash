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
    let url = fixturesDirectory.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(BrowserFixtureCatalog.self, from: data)
  }

  public func select(named names: [String]) throws -> [BrowserFixture] {
    guard !names.isEmpty else { return fixtures }
    var selected: [BrowserFixture] = []
    for name in names {
      guard
        let fixture = fixtures.first(where: { $0.name == name || $0.file == name })
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
}
