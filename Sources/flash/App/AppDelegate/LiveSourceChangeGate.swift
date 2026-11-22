import FlashCore

/// One live source a plugin said changed (`changed`): the plugin's flashlight
/// source and the manifest source name it gave.
struct LiveSourceChange: Hashable {
  /// The plugin's `FlashSource` identifier (`plugin:<id>`).
  let sourceID: String
  /// The manifest `sources[].name`.
  let source: String

  /// Whether `query` is scoped to this source, so its rows are on screen or
  /// on their way: the plugin is one the query pulls, and the query's scope
  /// is the source's type (`@<type>`) or the source itself (a bound bang).
  /// A plugin's other live sources are pulled with it and filtered out, so
  /// a change of one of those shows nothing new.
  func isShown<Row>(
    by query: CandidateLiveQuery<Row>.Query?, descriptors: [CandidateSourceDescriptor]
  ) -> Bool {
    guard let query, query.sourceIDs.contains(sourceID),
      let descriptor = descriptors.first(where: { $0.name == source })
    else { return false }
    return query.filter == SourceScope.type(descriptor.type).signature
      || query.filter == SourceScope.source(descriptor.name).signature
  }
}

/// Bounds how often `changed` notifications pull a flashlight query's live
/// sources again (`protocol.json` `changed.min_interval_ms`): the first is
/// honoured at once, and those that arrive inside the interval cost one more
/// pull at its end, whatever their number. A plugin that announces a change
/// with every reply therefore costs two searches a second, not a loop.
///
/// The gate only decides; its owner asks it solely about changes a query
/// shows, runs the pull, and arms the one deadline `wait` asks for.
struct LiveSourceChangeGate {
  enum Decision: Equatable {
    /// Pull now.
    case pull
    /// Inside the interval: pull once, this many milliseconds from now.
    case wait(ms: Int)
    /// A pull is already waiting, and this change rides with it.
    case coalesced
  }

  let minIntervalMs: Int
  private var lastPullMs: Int?
  private(set) var waiting: Set<LiveSourceChange> = []

  init(minIntervalMs: Int = PluginProtocol.changedMinIntervalMs) {
    self.minIntervalMs = minIntervalMs
  }

  /// A change the current query shows, at `nowMs` on a monotonic clock.
  mutating func admit(_ change: LiveSourceChange, nowMs: Int) -> Decision {
    guard waiting.isEmpty else {
      waiting.insert(change)
      return .coalesced
    }
    let elapsed = lastPullMs.map { nowMs - $0 } ?? minIntervalMs
    guard elapsed < minIntervalMs else {
      lastPullMs = nowMs
      return .pull
    }
    waiting.insert(change)
    return .wait(ms: minIntervalMs - max(0, elapsed))
  }

  /// The waiting deadline fired: the changes that waited on it. The owner
  /// pulls if a query still shows one of them, and says so with `pulled`.
  mutating func takeWaiting() -> Set<LiveSourceChange> {
    defer { waiting.removeAll() }
    return waiting
  }

  mutating func pulled(nowMs: Int) { lastPullMs = nowMs }

  /// The flashlight session ended: nothing waits for it any more. The time
  /// of the last pull stays, so the bound holds across sessions.
  mutating func cancelWaiting() { waiting.removeAll() }
}
