import FlashCore
import FlashSearch
import Foundation

/// One scope per flashlight keystroke. The coordinator builds it (it
/// owns the live pool selection + emoji/bang mode bookkeeping); the
/// service runs the scoring + DB merge.
struct CandidateFinderSearchScope {
  /// Live in-memory candidates the fuzzy scorer ranks. Already filtered
  /// for emoji mode, source flags, attribute filters.
  let pool: [Candidate]
  /// Text the fuzzy scorer matches against (the bang token in bang
  /// mode, the trimmed query otherwise).
  let scoringText: String
  /// Text fed to the FTS5 path. `nil` when the DB shouldn't be queried —
  /// in bang mode or emoji mode the DB has no relevant rows and the
  /// round-trip is pure waste.
  let indexQueryText: String?
  /// Attribute filters in pre-compiled form. Applied to the DB query
  /// via the bridge; the live pool already had them applied during
  /// scope construction.
  let attributeFilters: [CandidateFinder.CompiledAttributeFilter]
  /// Restrict the DB query to specific collections. `nil` means search
  /// every persisted collection.
  let indexCollections: [String]?
}

/// Single entry point the rest of the app uses to search for
/// candidates. Owns the persistent index, the frecency store, AND the
/// in-memory fuzzy ranker — exposing one API instead of forcing every
/// caller to coordinate two systems. The fuzzy scorer is an
/// implementation detail kept alive because FTS5 cannot do subsequence
/// matches ("sfr" → "Safari"); the DB still owns persistence + cross-
/// session frecency.
final class SearchService {
  let store: SearchStore
  let indexer: SearchIndexer
  let queryEngine: SearchQueryEngine
  let frecency: FrecencyStore
  let config: Config.Search

  private let lock = NSLock()
  private var livePoolSnapshot: [Candidate] = []
  /// Cached frecency snapshot — refreshed in the background and read
  /// on every keystroke. Plain dict means the live ranker pays an O(1)
  /// lookup, never a SQL round trip.
  private var frecencySnapshot: [String: Int] = [:]

  init?(config: Config.Search) {
    guard config.enabled else { return nil }
    let url = SearchService.resolveDatabaseURL(config.databasePath)
    let storeConfig = SearchStore.Configuration(
      mmapSize: Int64(max(0, config.mmapSize)),
      cacheSizeKB: max(1024, config.cacheSizeKB),
      busyTimeoutSeconds: 5.0,
      retrievalLimit: max(1, config.retrievalLimit))
    do {
      let store = try SearchStore(url: url, configuration: storeConfig, log: SearchServiceLog())
      self.store = store
      self.indexer = SearchIndexer(
        store: store, optimizeIntervalWrites: max(1024, config.optimizeIntervalWrites))
      self.queryEngine = SearchQueryEngine(store: store)
      self.frecency = FrecencyStore(
        store: store,
        configuration: FrecencyStore.Configuration(halfLifeDays: config.frecencyHalfLifeDays))
    } catch let error as SearchStoreError {
      FlashLog.warn(
        "[search] disabled: \(error.description)",
        fields: ["path": url.path])
      return nil
    } catch {
      FlashLog.warn(
        "[search] disabled: open failed \(error)",
        fields: ["path": url.path])
      return nil
    }
    self.config = config
    refreshFrecencySnapshotAsync()
    FlashLog.info("[search] opened", fields: ["path": url.path])
  }

  /// Resolve the DB path from config + `~/Library/Application
  /// Support/Flash/Search/index.db` fallback. The empty-string config
  /// value is the convention for "use the default" so a user editing
  /// `flash.toml` doesn't need to know the path themselves.
  private static func resolveDatabaseURL(_ raw: String) -> URL {
    if !raw.isEmpty {
      let expanded = (raw as NSString).expandingTildeInPath
      return URL(fileURLWithPath: expanded)
    }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return appSupport.appendingPathComponent("Flash/Search/index.db")
  }

  /// `wal_checkpoint(TRUNCATE)` so the WAL file doesn't survive across
  /// runs and bloat the index dir.
  func shutdown() {
    frecency.drain()
    store.checkpointTruncate()
  }

  // MARK: - Unified search

  /// Score the scope's live pool, query the persistent index, and
  /// deliver merged + sorted matches to `onResults`. The closure fires
  /// **twice**:
  ///
  /// 1. **Synchronously**, on the caller's thread, with the in-memory
  ///    fuzzy-scored result. This is what the keystroke renders right
  ///    away so the UI never blinks.
  /// 2. **Asynchronously**, on the main queue, when (and only if) the
  ///    DB walk found anything to merge. The whole set is re-sorted
  ///    and re-delivered.
  ///
  /// Callers compare `generation` against the value they captured
  /// before the call so a slow DB walk that finishes after the user
  /// has typed another keystroke is dropped silently.
  func search(
    scope: CandidateFinderSearchScope,
    generation: UInt64,
    onResults: @escaping (UInt64, [CandidateMatch]) -> Void
  ) {
    let fuzzyScore = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scope.scoringText)
    var memoryMatches = CandidateFinder.scoreMatches(
      pool: scope.pool, normalizedQuery: normalizedQuery, fuzzyScore: fuzzyScore)
    for index in memoryMatches.indices {
      memoryMatches[index].score += frecencyBoost(for: memoryMatches[index].candidate)
    }
    let memorySorted = CandidateFinder.sortedMatches(memoryMatches)
    onResults(generation, memorySorted)

    guard shouldQueryIndex(scope) else { return }
    let indexText = scope.indexQueryText ?? ""
    let filters = SearchAttributeFilterBridge.translate(scope.attributeFilters)
    let q = SearchQuery(
      text: indexText, filters: filters, collections: scope.indexCollections)
    let memoryKeys = itemKeySet(memoryMatches.map(\.candidate))
    queryEngine.query(q, completionQueue: .main) { [weak self] result in
      guard let self else { return }
      guard case .success(let hits) = result, !hits.isEmpty else { return }
      let preparedDB = self.prepareDatabaseMatches(
        hits: hits,
        normalizedQuery: normalizedQuery,
        fuzzyScore: fuzzyScore,
        deduplicateAgainst: memoryKeys)
      guard !preparedDB.isEmpty else { return }
      let merged = CandidateFinder.sortedMatches(memoryMatches + preparedDB)
      onResults(generation, merged)
    }
  }

  /// Whether the DB round-trip is worth the cost given the scope. We
  /// skip when the index isn't ready, the caller opted out (`nil`
  /// `indexQueryText`), or the text is shorter than
  /// `query_min_chars` and the user didn't explicitly opt into empty-
  /// query index browsing.
  private func shouldQueryIndex(_ scope: CandidateFinderSearchScope) -> Bool {
    guard let text = scope.indexQueryText else { return false }
    let minChars = max(0, config.queryMinChars)
    if text.count < minChars {
      return config.emptyQueryIndexResults
    }
    return true
  }

  /// Turn FTS hits into scored matches that drop into the same sort as
  /// the live pool. Dedup against `memoryKeys` so a candidate that's
  /// already in the live pool isn't double-counted (live wins — it has
  /// the latest pid + payload).
  private func prepareDatabaseMatches(
    hits: [SearchHit],
    normalizedQuery: String,
    fuzzyScore: @escaping (String, String) -> Int?,
    deduplicateAgainst memoryKeys: Set<String>
  ) -> [CandidateMatch] {
    var prepared: [Candidate] = []
    prepared.reserveCapacity(hits.count)
    for hit in hits {
      let candidate = SearchCandidateMapper.candidate(from: hit)
      if let key = SearchCandidateMapper.itemKey(for: candidate),
        memoryKeys.contains(key)
      {
        continue
      }
      prepared.append(CandidateFinder.prepare(candidate))
    }
    var matches = CandidateFinder.scoreMatches(
      pool: prepared, normalizedQuery: normalizedQuery, fuzzyScore: fuzzyScore)
    for index in matches.indices {
      matches[index].score += frecencyBoost(for: matches[index].candidate)
    }
    return matches
  }

  private func itemKeySet(_ candidates: [Candidate]) -> Set<String> {
    var out = Set<String>()
    out.reserveCapacity(candidates.count)
    for candidate in candidates {
      if let key = SearchCandidateMapper.itemKey(for: candidate) {
        out.insert(key)
      }
    }
    return out
  }

  // MARK: - Frecency

  /// O(1) snapshot lookup. Called from the live ranker — must not
  /// block on SQLite.
  func frecencyBoost(for candidate: Candidate) -> Int {
    guard config.frecencyEnabled,
      let key = SearchCandidateMapper.itemKey(for: candidate)
    else { return 0 }
    return frecencyBoost(forKey: key)
  }

  /// Same snapshot lookup, keyed by a raw frecency key. Used by call
  /// sites whose entries aren't candidates (e.g. command-line
  /// completions keyed by `FrecencyKey.command(label:)`).
  func frecencyBoost(forKey key: String) -> Int {
    guard config.frecencyEnabled else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    return frecencySnapshot[key] ?? 0
  }

  /// User confirmed this candidate — bump its frecency and refresh the
  /// snapshot in the background. The actual write is async; the
  /// snapshot refresh is debounced by the simple fact that it runs on
  /// the same queue.
  func recordOpen(_ candidate: Candidate) {
    guard let key = SearchCandidateMapper.itemKey(for: candidate) else { return }
    recordOpen(forKey: key)
  }

  /// Raw-key counterpart for non-candidate entries (commands, future
  /// surfaces that aren't backed by a `Candidate` but still want
  /// frecency).
  func recordOpen(forKey key: String) {
    frecency.recordOpen(itemKey: key)
    refreshFrecencySnapshotAsync()
  }

  // MARK: - Live pool mirror

  /// Snapshot the live-pool candidates so the plugin RPC's `include_memory`
  /// path can fuzzy-match it without hopping to the main thread.
  func updateLivePoolSnapshot(_ pool: [Candidate]) {
    lock.lock()
    livePoolSnapshot = pool
    lock.unlock()
  }

  func liveSnapshot() -> [Candidate] {
    lock.lock()
    defer { lock.unlock() }
    return livePoolSnapshot
  }

  /// Reload the frecency snapshot in the background. Cheap (one
  /// indexed `SELECT … LIMIT 4096`); called whenever recorded opens
  /// might have changed the ranking.
  func refreshFrecencySnapshotAsync() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let snapshot = (try? self.frecency.snapshotBoosts()) ?? [:]
      self.lock.lock()
      self.frecencySnapshot = snapshot
      self.lock.unlock()
    }
  }

  /// Hot-reload hook. The only knob safe to bump at runtime is the
  /// query-shaping config (min chars, empty-query browse) — the
  /// store-level pragmas and frecency half-life are bound at open.
  func applyConfig(_ config: Config.Search) {
    // Live mutation isn't supported for `config` (let-bound); a
    // restart picks up the new values. The few knobs that *could* be
    // bumped (query_min_chars, empty_query_index_results) are read
    // from the original snapshot here — accept the staleness for v1.
    _ = config
  }
}

/// Adapter that forwards FlashSearch's `SearchLogging` calls into the
/// app's structured `FlashLog`.
private final class SearchServiceLog: SearchLogging {
  func searchLog(_ level: SearchLogLevel, _ message: String, fields: [String: String]) {
    let l: FlashLog.Level
    switch level {
    case .trace: l = .trace
    case .debug: l = .debug
    case .info: l = .info
    case .warn: l = .warn
    case .error: l = .error
    }
    FlashLog.plugin(l, pluginID: "search", message: "[search] " + message, fields: fields)
  }
}

/// Translate the in-memory `CompiledAttributeFilter` shape into the
/// persistent `SearchFilter` shape so the same query syntax users type
/// for the live pool also pre-filters the DB.
enum SearchAttributeFilterBridge {
  static func translate(_ filters: [CandidateFinder.CompiledAttributeFilter]) -> [SearchFilter] {
    return filters.map { compiled in
      let field = translateField(compiled.field)
      let kind = translateKind(compiled.kind)
      return SearchFilter(field: field, kind: kind, needle: compiled.needle)
    }
  }

  private static func translateField(
    _ field: CandidateFinder.CompiledAttributeFilter.Field
  ) -> SearchFilter.Field {
    switch field {
    case .source: return .source
    case .kind: return .kind
    case .name: return .title
    case .url: return .url
    case .bundle: return .bundle
    case .subtitle: return .subtitle
    case .unknown: return .unknown
    }
  }

  private static func translateKind(
    _ kind: CandidateFinder.CompiledAttributeFilter.Kind
  ) -> SearchFilter.Kind {
    switch kind {
    case .any: return .any
    case .exact: return .exact
    case .prefix: return .prefix
    case .suffix: return .suffix
    case .contains: return .contains
    }
  }
}
