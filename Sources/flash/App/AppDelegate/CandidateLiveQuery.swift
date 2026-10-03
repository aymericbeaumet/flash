/// Live rows belong to one exact query, independently of the warm session
/// catalog. The token survives background preparation through publication.
struct CandidateLiveQuery<Row> {
  struct Query: Equatable {
    let filter: String
    let text: String
    let sourceIDs: [String]
  }

  struct Token: Equatable {
    fileprivate let generation: UInt64
  }

  private var generation: UInt64 = 0
  private(set) var revision: UInt64 = 0
  private var query: Query?
  private var snapshots: [String: [Row]] = [:]

  var rows: [Row] { snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] } }

  mutating func begin(_ next: Query) -> Token? {
    guard query != next else { return nil }
    generation &+= 1
    revision &+= 1
    snapshots.removeAll()
    query = next
    return Token(generation: generation)
  }

  mutating func cancel() {
    guard query != nil else { return }
    generation &+= 1
    revision &+= 1
    query = nil
    snapshots.removeAll()
  }

  func isCurrent(_ token: Token) -> Bool { query != nil && token.generation == generation }

  @discardableResult
  mutating func receive(_ rows: [Row], sourceID: String, token: Token) -> Bool {
    guard isCurrent(token), query?.sourceIDs.contains(sourceID) == true else { return false }
    snapshots[sourceID] = rows
    revision &+= 1
    return true
  }
}
