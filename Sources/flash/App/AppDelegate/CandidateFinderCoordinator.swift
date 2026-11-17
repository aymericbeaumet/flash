import AppKit
import FlashCore

/// Owns command/finder work from session opening through query publication and close.
extension AppDelegate {
  static var candidateFinderFirstPaintBudgetMs: Int { 150 }
  static var candidateFinderSlowReplyWarningMs: Int { 100 }

  /// Open a flashlight session behind a short, session-local fan-in barrier.
  /// The command prompt paints immediately with no rows. Built-in applications
  /// and every eligible plugin's in-memory location catalog are then frozen into
  /// one deterministic snapshot and revealed exactly once. Nothing is retained
  /// in the host after the session closes.
  /// The session's frozen selector context, resolved now for a session that
  /// opened cold (typed `:` without a flashlight entry).
  private func sessionSelectorContext() -> PluginSelectorContext {
    if let context = finder.selectorContext { return context }
    let context = pluginSelectorContext()
    finder.selectorContext = context
    return context
  }

  func openCandidateFinderSession(scope: CandidateScope) {
    let startedNs = DispatchTime.now().uptimeNanoseconds
    // Advisory: the flashlight opened. Eager plugins may refresh their
    // catalogs; nothing is required and first paint never waits for them.
    if pluginManager.hasListener(for: .sessionOpened) {
      pluginManager.emit(PluginEvent(.sessionOpened))
    }
    appleCatalogs.sessionOpened()
    finder.precedenceTable = buildCandidateFinderPrecedenceTable()
    finder.selectorContext = pluginSelectorContext()
    finder.scope = scope
    finder.sessionGeneration &+= 1
    finder.liveQuery.cancel()
    invalidateCandidateQueryEvaluation()
    let generation = finder.sessionGeneration
    finder.fetchedNonLocationSourceIDs.removeAll()
    finder.deferredNonLocationSnapshots.removeAll()
    finder.snapshotOrdering = CandidateSnapshotOrdering()
    finder.resetInitialSnapshot()
    finder.submissionDeferral.cancel()
    finder.candidates = []
    finder.matches = []
    finder.selectedIndex = 0

    // Built-in candidate sources join the barrier too: core.apps may still be
    // waiting on its asynchronous resident-startup index, so it is gathered as
    // a regular expected source instead of being frozen as a partial seed.
    var sourcesByID: [String: FlashSource] = [:]
    for source in registry.initialCandidateSnapshotSources() {
      sourcesByID[source.identifier] = source
    }
    let sources = sourcesByID.values.sorted { $0.identifier < $1.identifier }
    finder.beginInitialSnapshot(
      CandidateSnapshotBarrier(
        generation: generation,
        startedNs: startedNs,
        expectedSourceIDs: sources.map(\.identifier)))

    let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
    FlashLog.trace(
      "[flashlight] snapshot_begin generation=\(generation) scope=\(scope) "
        + "sources=\(sources.count) seed_ms=\(elapsedMs)")

    // Let `enterCommandLineMode` render/focus the native text field first.
    // Snapshots start on the next main turn, so even a future synchronous source
    // cannot publish rows before the prompt has appeared.
    DispatchQueue.main.async { [weak self] in
      self?.startInitialCandidateSnapshots(
        sources,
        scope: scope,
        generation: generation)
    }
  }

  private func startInitialCandidateSnapshots(
    _ sources: [FlashSource],
    scope: CandidateScope,
    generation: UInt64
  ) {
    guard generation == finder.sessionGeneration,
      let barrier = finder.initialBarrier,
      barrier.generation == generation
    else { return }

    let elapsedMs = Int(
      (DispatchTime.now().uptimeNanoseconds &- barrier.startedNs) / 1_000_000)
    let remainingMs = max(0, Self.candidateFinderFirstPaintBudgetMs - elapsedMs)
    if remainingMs == 0 {
      finalizeInitialCandidateSnapshot(
        generation: generation, reason: .firstPaintBudget)
      return
    }

    let deadline = DispatchWorkItem { [weak self] in
      self?.finalizeInitialCandidateSnapshot(
        generation: generation, reason: .firstPaintBudget)
    }
    finder.armInitialDeadline(deadline)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(remainingMs),
      execute: deadline)

    guard !sources.isEmpty else {
      finalizeInitialCandidateSnapshot(
        generation: generation, reason: .allSourcesSettled)
      return
    }

    let env = registry.snapshotEnvironment
    for source in sources {
      let snapshotStartedNs = DispatchTime.now().uptimeNanoseconds
      source.snapshotCandidates(in: env, scope: scope) { [weak self] candidates in
        self?.recordInitialCandidateReply(
          candidates,
          sourceID: source.identifier,
          generation: generation,
          snapshotStartedNs: snapshotStartedNs)
      }
    }
  }

  private func recordInitialCandidateReply(
    _ candidates: [Candidate],
    sourceID: String,
    generation: UInt64,
    snapshotStartedNs: UInt64
  ) {
    let nowNs = DispatchTime.now().uptimeNanoseconds
    let latencyMs = Int((nowNs &- snapshotStartedNs) / 1_000_000)
    guard generation == finder.sessionGeneration else {
      FlashLog.trace(
        "[flashlight] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=stale_session ms=\(latencyMs)")
      return
    }
    guard var barrier = finder.initialBarrier,
      barrier.generation == generation
    else {
      if finder.initialSnapshotReady {
        FlashLog.warn(
          "[flashlight] snapshot_reply_late source=\(sourceID) "
            + "generation=\(generation) ms=\(latencyMs) count=\(candidates.count) ignored=true")
      }
      return
    }

    let result = barrier.record(
      sourceID: sourceID,
      candidates: candidates,
      latencyMs: latencyMs)
    finder.updateInitialBarrier(barrier)
    switch result {
    case .accepted:
      FlashLog.trace(
        "[flashlight] snapshot_reply source=\(sourceID) generation=\(generation) "
          + "ms=\(latencyMs) count=\(candidates.count) "
          + "settled=\(barrier.settledSourceCount)/\(barrier.expectedSourceCount)")
      if latencyMs >= Self.candidateFinderSlowReplyWarningMs {
        FlashLog.warn(
          "[flashlight] snapshot_reply_slow source=\(sourceID) "
            + "generation=\(generation) ms=\(latencyMs) "
            + "budget_ms=\(Self.candidateFinderFirstPaintBudgetMs)")
      }
      if barrier.isSettled {
        finalizeInitialCandidateSnapshot(
          generation: generation, reason: .allSourcesSettled)
      }
    case .duplicate:
      FlashLog.warn(
        "[flashlight] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=duplicate")
    case .unknownSource:
      FlashLog.warn(
        "[flashlight] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=unknown_source")
    case .finalized:
      FlashLog.warn(
        "[flashlight] snapshot_reply_late source=\(sourceID) "
          + "generation=\(generation) ms=\(latencyMs) count=\(candidates.count) ignored=true")
    }
  }

  private func finalizeInitialCandidateSnapshot(
    generation: UInt64,
    reason: CandidateSnapshotBarrier.FinalizationReason
  ) {
    guard generation == finder.sessionGeneration,
      var barrier = finder.initialBarrier,
      barrier.generation == generation,
      let snapshot = barrier.finalize(reason: reason)
    else { return }

    // Keep the finalized barrier installed while the raw snapshot is prepared
    // off-main. `refreshCommandLine` continues to show a live empty prompt and
    // late opt-in replies are buffered rather than overwriting this first
    // deterministic publication.
    finder.cancelInitialDeadline()
    finder.updateInitialBarrier(barrier)
    if !snapshot.missingSourceIDs.isEmpty {
      FlashLog.warn(
        "[flashlight] snapshot_budget_missed generation=\(generation) "
          + "budget_ms=\(Self.candidateFinderFirstPaintBudgetMs) "
          + "missing=\(snapshot.missingSourceIDs.joined(separator: ","))")
    }

    let startedNs = barrier.startedNs
    let expectedSourceCount = barrier.expectedSourceCount
    let settledSourceCount = snapshot.replies.count
    let latencies = snapshot.sourceLatencies.isEmpty ? "none" : snapshot.sourceLatencies
    finder.preparationQueue.async { [weak self] in
      var frozen: [Candidate] = []
      for reply in snapshot.replies {
        frozen.append(contentsOf: CandidateFinder.prepare(reply.candidates))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self,
          generation == self.finder.sessionGeneration,
          self.finder.initialBarrier?.generation == generation
        else { return }

        self.finder.candidates = frozen
        self.finder.selectedIndex = 0
        self.finder.publishInitialSnapshot()
        self.publishDeferredNonLocationSnapshots(generation: generation)

        let elapsedMs = Int(
          (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        FlashLog.debug(
          "[flashlight] snapshot_ready generation=\(generation) reason=\(reason.rawValue) "
            + "count=\(self.finder.candidates.count) "
            + "settled=\(settledSourceCount)/\(expectedSourceCount) "
            + "ms=\(elapsedMs) source_ms=\(latencies)")
        self.rerenderActiveCandidateFinderSurface()
      }
    }
  }

  /// Lazily pull non-location candidate stores when the user opts into them.
  /// A confirmed `@type` fetches only providers that declare a source of
  /// that type; bang completion fetches only the plugins that answer
  /// every bang (`!*`), whose catalogs hold the bang rows. Providers are
  /// tracked individually so switching explicit sources later in the same
  /// session still works without repeating prior snapshots.
  func fetchNonLocationSourcesIfNeeded(
    matching scope: SourceScope? = nil, bangCatalogsOnly: Bool = false
  ) {
    let sources = registry.nonLocationCandidateSources(matching: scope).filter {
      !bangCatalogsOnly || ($0 as? PluginFlashSource)?.answersEveryBang == true
    }
    let pending = sources.filter { source in
      finder.fetchedNonLocationSourceIDs.insert(source.identifier).inserted
    }
    guard !pending.isEmpty else { return }
    fanOutCandidateSnapshots(
      pending,
      generation: finder.sessionGeneration)
  }

  /// Start only the warm non-location snapshots implied by the current query.
  /// This can run while the initial location barrier is still preparing, which
  /// overlaps plugin decoding with first-paint work. Partial `@type`
  /// completion remains manifest-only and performs no catalog request.
  func prefetchNonLocationSources(forCandidateQuery query: String) {
    let sourceCompletion = CandidateFinder.sourceCompletionState(query: query)
    let bangCompletion = CandidateFinder.bangCompletionState(query: query)
    let parsed =
      sourceCompletion == nil
      ? NormalModeDispatcher.candidateFinderQuery(query)
      : NormalModeDispatcher.CandidateFinderQuery(scope: nil, text: query)
    let parsedBang = CandidateFinder.parseBang(parsed.text)
    if let scope = parsed.scope {
      fetchNonLocationSourcesIfNeeded(matching: scope)
    } else if bangCompletion != nil || parsedBang != nil {
      fetchNonLocationSourcesIfNeeded(bangCatalogsOnly: true)
    }
  }

  /// The catalog store's coalesced (≤1/s) change tick. With no flashlight
  /// session open this is a no-op — the next open reads the store anyway.
  /// With one open, re-read every plugin catalog this session already
  /// surfaced (an initial location source, or a non-location one the user
  /// opted into) and merge through the per-source pool swap — lossless,
  /// since the store is already current when the tick lands.
  func handlePluginCatalogsChanged() {
    switch overlay.inputMode {
    case .commandLine: break
    default: return
    }
    var surfaced: [String: FlashSource] = [:]
    for source in registry.initialCandidateSnapshotSources()
    where source.identifier.hasPrefix("plugin:") {
      surfaced[source.identifier] = source
    }
    for source in pluginManager.sources
    where finder.fetchedNonLocationSourceIDs.contains(source.identifier) {
      surfaced[source.identifier] = source
    }
    guard !surfaced.isEmpty else { return }
    FlashLog.trace(
      "[flashlight] catalogs_changed_repull sources=\(surfaced.count)")
    fanOutCandidateSnapshots(
      Array(surfaced.values), generation: finder.sessionGeneration)
  }

  /// Live results never enter the warm catalog. Every query change invalidates
  /// both replies and rows still being prepared, including leaving a source.
  private func beginLiveSourceQueriesIfNeeded(forCandidateQuery query: String) {
    guard CandidateFinder.sourceCompletionState(query: query) == nil else {
      finder.liveQuery.cancel()
      return
    }
    let parsed = NormalModeDispatcher.candidateFinderQuery(query)
    let scope: SourceScope
    let text: String
    if let bound = boundBangScope(query) {
      scope = bound.scope
      text = bound.remainder
    } else if let typed = parsed.scope {
      scope = typed
      text = parsed.text.trimmed
    } else {
      finder.liveQuery.cancel()
      return
    }
    let sources = registry.liveCandidateSources(matching: scope)
    guard !sources.isEmpty else {
      finder.liveQuery.cancel()
      return
    }
    guard
      let token = finder.liveQuery.begin(
        .init(
          filter: scope.signature, text: Self.liveQueryText(text, sources: sources),
          sourceIDs: sources.map(\.identifier).sorted()))
    else { return }
    pullLiveSources(sources, text: text, token: token)
  }

  /// The text a live query is keyed by: empty when none of its sources reads
  /// it, so typing re-pulls nothing and their rows stay on screen.
  static func liveQueryText(_ text: String, sources: [FlashSource]) -> String {
    sources.contains(where: \.liveCandidatesDependOnText) ? text : ""
  }

  private func boundBangScope(_ query: String) -> (scope: SourceScope, remainder: String)? {
    CandidateFinder.boundBangScope(query) { bangCandidateScope(token: $0) }
  }

  /// A live source's rows changed while a query shows them (a catalog relist
  /// landed): pull the query's sources again under a renewed token, keeping
  /// the rows on screen until the new ones replace them.
  func refreshLiveCandidates(sourceID: String) {
    switch overlay.inputMode {
    case .commandLine: break
    default: return
    }
    guard let current = finder.liveQuery.query, current.sourceIDs.contains(sourceID) else {
      return
    }
    let sources = current.sourceIDs.compactMap { registry.source(identifier: $0) }
    guard let token = finder.liveQuery.renew() else { return }
    pullLiveSources(sources, text: current.text, token: token)
  }

  private func pullLiveSources(
    _ sources: [FlashSource], text: String, token: CandidateLiveQuery<Candidate>.Token
  ) {
    let env = registry.snapshotEnvironment
    for source in sources {
      let sourceID = source.identifier
      source.liveCandidates(matching: text, in: env, scope: finder.scope) {
        [weak self] candidates in
        DispatchQueue.main.async { [weak self] in
          guard let self, self.finder.liveQuery.isCurrent(token) else { return }
          self.finder.preparationQueue.async { [weak self] in
            let prepared = CandidateFinder.prepare(candidates)
            DispatchQueue.main.async { [weak self] in
              guard let self,
                self.finder.liveQuery.receive(prepared, sourceID: sourceID, token: token)
              else { return }
              self.scheduleCoalescedCandidateFinderRerender()
            }
          }
        }
      }
    }
  }

  /// Fan user-requested non-location snapshots out in parallel. Initial location
  /// sources use the one-publish barrier above; this merge path is only reached
  /// after an explicit `@type` / `!` opt-in.
  private func fanOutCandidateSnapshots(
    _ sources: [FlashSource],
    generation: UInt64
  ) {
    let env = registry.snapshotEnvironment
    for source in sources {
      source.snapshotCandidates(in: env, scope: finder.scope) {
        [weak self] candidates in
        self?.mergeCandidateSnapshotResults(candidates, from: source, generation: generation)
      }
    }
  }

  /// Merge one explicitly requested non-location source into the frozen initial
  /// pool, then re-render at the current query. Late replies from a closed or
  /// superseded session are dropped via the generation and surface guards.
  private func mergeCandidateSnapshotResults(
    _ candidates: [Candidate],
    from source: FlashSource,
    generation: UInt64
  ) {
    let sourceID = source.identifier
    // Stamped before the preparation that may reorder replies for one source.
    let stamp = finder.snapshotOrdering.stamp(sourceID)
    finder.preparationQueue.async { [weak self] in
      let prepared = CandidateFinder.prepare(candidates)
      DispatchQueue.main.async { [weak self] in
        self?.receivePreparedCandidateSnapshot(
          prepared,
          sourceID: sourceID,
          generation: generation,
          stamp: stamp)
      }
    }
  }

  private func receivePreparedCandidateSnapshot(
    _ candidates: [Candidate],
    sourceID: String,
    generation: UInt64,
    stamp: UInt64
  ) {
    guard generation == finder.sessionGeneration else { return }
    guard finder.snapshotOrdering.accept(sourceID, stamp: stamp) else {
      FlashLog.trace("[flashlight] merge_superseded source=\(sourceID) stamp=\(stamp)")
      return
    }
    switch overlay.inputMode {
    case .commandLine: break
    default: return
    }
    if finder.initialBarrier != nil {
      finder.deferredNonLocationSnapshots[sourceID] = candidates
      FlashLog.trace(
        "[flashlight] merge_deferred source=\(sourceID) count=\(candidates.count)")
      return
    }
    publishPreparedCandidateSnapshot(candidates, sourceID: sourceID)
    scheduleCoalescedCandidateFinderRerender()
  }

  private func publishPreparedCandidateSnapshot(_ candidates: [Candidate], sourceID: String) {
    let ownedPrefix = sourceID + "."
    var pool = finder.candidates.filter { candidate in
      candidate.sourceID != sourceID && !candidate.sourceID.hasPrefix(ownedPrefix)
    }
    pool.append(contentsOf: candidates)
    finder.candidates = pool
    FlashLog.trace(
      "[flashlight] merge source=\(sourceID) count=\(candidates.count) "
        + "pool=\(finder.candidates.count)")
  }

  private func publishDeferredNonLocationSnapshots(generation: UInt64) {
    guard generation == finder.sessionGeneration else { return }
    let deferred = finder.deferredNonLocationSnapshots
    finder.deferredNonLocationSnapshots.removeAll()
    for sourceID in deferred.keys.sorted() {
      guard let candidates = deferred[sourceID] else { continue }
      publishPreparedCandidateSnapshot(candidates, sourceID: sourceID)
    }
  }

  /// Re-render once per runloop turn no matter how many opt-in sources merged.
  private func scheduleCoalescedCandidateFinderRerender() {
    guard !finder.mergeRerenderScheduled else { return }
    finder.mergeRerenderScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.finder.mergeRerenderScheduled = false
      self.rerenderActiveCandidateFinderSurface()
    }
  }

  /// Re-score and repaint whichever flashlight surface is open after the pool
  /// changed mid-session. Both refresh paths fully replace the rendered rows, so
  /// inserting late candidates is safe; the user's typed query and selection are
  /// preserved by the existing scoring path.
  private func rerenderActiveCandidateFinderSurface() {
    switch overlay.inputMode {
    case .commandLine:
      // This is a passive re-render (late candidates merged in), not a caret
      // move — pick up the field editor's live caret so it isn't snapped back to
      // a stale stored index the user has since moved past with an arrow/click.
      overlay.syncCommandLineCursorFromField()
      refreshCommandLine(
        text: overlay.commandLineText, cursorIndex: overlay.commandLineCursorIndex)
    default:
      break
    }
    if finder.queryEvaluationSettledGeneration
      == finder.queryEvaluationInFlightGeneration
    {
      finder.queryEvaluationSettledGeneration = nil
      finder.queryEvaluationInFlightGeneration = nil
    }
    replayDeferredCandidateSubmissionIfReady()
  }

  /// Translate the `!<token>` range from the candidate-finder query into
  /// the full command buffer (`":flashlight !g foo"`). Returns an
  /// `NSRange` so the panel can drive `attributedStringValue` without
  /// re-parsing.
  private func bangRangeInCommand(
    command: String,
    query: String,
    bangRange: Range<String.Index>
  ) -> NSRange {
    let bangOffset = query.distance(from: query.startIndex, to: bangRange.lowerBound)
    let bangLen = query.distance(from: bangRange.lowerBound, to: bangRange.upperBound)
    let prefixLen = command.count - query.count
    let location = max(0, prefixLen + bangOffset)
    let utf16Prefix = command.index(
      command.startIndex,
      offsetBy: min(location, command.count))
    let utf16End = command.index(
      utf16Prefix,
      offsetBy: min(bangLen, command.distance(from: utf16Prefix, to: command.endIndex)))
    let nsLocation = utf16Prefix.utf16Offset(in: command)
    let nsLength = utf16End.utf16Offset(in: command) - nsLocation
    return NSRange(location: nsLocation, length: max(0, nsLength))
  }

  func refreshCommandLine(text: String, cursorIndex: Int? = nil) {
    let command = Self.commandLineBuffer(from: text)
    overlay.commandLineText = command
    overlay.commandLineCursorIndex = cursorIndex ?? command.count
    if let query = NormalModeDispatcher.commandLineCandidateQuery(command) {
      clearCommandLineCompletionState()
      // A pick lists its own rows only: `@`, `!` and `=` are filter text.
      if finder.menu != nil {
        applyMenuMatches(query: query)
        overlay.displayCommandLine(
          command, suggestions: candidateFinderDisplayItems(),
          emptyText: "no line matches; Return answers with what you typed",
          cursorIndex: overlay.commandLineCursorIndex, prompt: finder.menu?.prompt)
        return
      }
      if finder.candidates.isEmpty,
        finder.initialBarrier == nil,
        !finder.initialSnapshotReady
      {
        // Cold command line (typed without a mapped flashlight entry): begin
        // the same one-publish initial gather as an explicit open.
        openCandidateFinderSession(scope: finder.scope)
      }
      beginLiveSourceQueriesIfNeeded(forCandidateQuery: query)
      if finder.initialBarrier != nil {
        prefetchNonLocationSources(forCandidateQuery: query)
        // Keep the native text field live while the initial catalogs fan in,
        // but do not paint an apps-only list or a false "no matching app"
        // result. Finalization re-scores the latest text and reveals rows once.
        finder.currentQuery = query
        finder.matches = []
        finder.selectedIndex = 0
        overlay.displayCommandLine(
          command,
          suggestions: nil,
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex)
        return
      }
      // Bang lock: once the user has typed a space after `!<token>`, the
      // remainder of the query semantically belongs to that bang's
      // dispatch (e.g. `!g rust language` → "search Google for 'rust
      // language'"). Showing candidate rows in that state was confusing
      // — the user was matching against bang names instead of typing
      // the query — so we drop the suggestions and pass the confirmed
      // bang range to the panel so it can underline `!g` and visually
      // acknowledge the lock-in. Backspacing past the space (no
      // confirmed bang anymore) unlocks and the bang list returns.
      // A bang bound to a candidate source (`!f report`) instead lists
      // that source's rows for the remainder, still underlined.
      let bang = CandidateFinder.parseBangState(query)
      if let bang, bang.confirmed, bangCandidateScope(token: bang.token) != nil {
        updateCandidateMatches(query: query)
        overlay.displayCommandLine(
          command,
          suggestions: candidateFinderDisplayItems(),
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex,
          underlineRange: bangRangeInCommand(
            command: command, query: query, bangRange: bang.bangRange))
        return
      }
      if let bang, bang.confirmed {
        // The locked-in query now belongs to the bang's dispatch, so keep
        // `finder.currentQuery` current — submit re-parses it for the
        // remainder. This branch returns before `updateCandidateMatches` (which
        // normally sets it), so without this it stays stuck at the value from
        // before the confirming space: `!g weather paris` then searched nothing
        // and `weather !g paris` searched only "weather".
        invalidateCandidateQueryEvaluation()
        finder.currentQuery = query
        finder.matches = []
        finder.selectedIndex = 0
        let queryRange = bangRangeInCommand(
          command: command, query: query, bangRange: bang.bangRange)
        overlay.displayCommandLine(
          command,
          suggestions: nil,
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex,
          underlineRange: queryRange,
          underlineInvalid: !confirmedBangIsKnown(bang.token))
        return
      }
      updateCandidateMatches(query: query)
      overlay.displayCommandLine(
        command,
        suggestions: candidateFinderDisplayItems(),
        cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    if let context = commandLineCompletionContext(for: command) {
      clearCandidateFinderState()
      updateCommandLineCompletions(context: context)
      overlay.displayCommandLine(
        command,
        suggestions: commandLineCompletionDisplayItems(),
        emptyText: "no matching command",
        cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    clearCandidateFinderState()
    clearCommandLineCompletionState()
    overlay.displayCommandLine(command, cursorIndex: overlay.commandLineCursorIndex)
  }

  private func commandLineCompletionContext(for command: String)
    -> NormalModeDispatcher.CommandLineCompletionContext?
  {
    NormalModeDispatcher.commandLineCompletions(command, inventory: commandLineInventory())
  }

  /// The words this command session resolves against, built once: plugin
  /// registrations and help topics do not change while one command field
  /// is open, so rebuilding them on every character only adds input latency.
  func commandLineInventory() -> NormalModeDispatcher.CommandLineInventory {
    if let cached = commandLineCompletionInventory { return cached }
    let inventory = makeCommandLineInventory()
    commandLineCompletionInventory = inventory
    return inventory
  }

  private func updateCommandLineCompletions(
    context: NormalModeDispatcher.CommandLineCompletionContext
  ) {
    commandLineCompletionPrefix = context.prefix
    commandLineCompletionQuery = context.query
    let trimmedQuery = context.query.trimmed
    let scored: [CommandLineCompletionMatch] = context.items.compactMap { item in
      // Frecency boost surfaces the user's most-typed commands at the
      // top of the empty `:` prompt without distorting the order once
      // they start typing — fuzzy score dominates from the first
      // character because it's an order of magnitude larger than the
      // capped boost.
      let boost = commandFrecencyBoost(label: item.label)
      if trimmedQuery.isEmpty {
        return CommandLineCompletionMatch(completion: item, score: boost)
      }
      guard
        let score = NormalModeDispatcher.fuzzyScore(
          query: trimmedQuery, candidate: item.label)
      else { return nil }
      return CommandLineCompletionMatch(completion: item, score: score + boost)
    }
    let sorted = scored.sorted { lhs, rhs in
      // The word the typed query selects — an ex command at its minimum
      // (`:q` is `quit`, not `qall`), an exact word or a unique prefix —
      // ranks first whatever its fuzzy score or frecency: it is what Enter
      // runs, so it is the highlighted row.
      if let selected = context.selectedLabel {
        let lhsSelected = lhs.completion.label == selected
        let rhsSelected = rhs.completion.label == selected
        if lhsSelected != rhsSelected { return lhsSelected }
      }
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.completion.label.localizedCaseInsensitiveCompare(rhs.completion.label)
        == .orderedAscending
    }
    commandLineCompletionMatches = sorted
    // A keystroke recomputes the highlight from the text; only the
    // resolver's pick is highlighted, so an ambiguous or unknown word, and
    // the empty prompt, show the candidates with no row selected.
    commandLineCompletionSelection =
      context.selectedLabel.flatMap { selected in
        sorted.firstIndex { $0.completion.label == selected }
      }.map(CommandLineCompletionSelection.implied) ?? .none
  }

  /// Frecency boost for a command-line completion label. Falls back to
  /// 0 when the store is unavailable (couldn't open the JSON file) or
  /// the label has never been opened.
  private func commandFrecencyBoost(label: String) -> Int {
    guard let frecencyStore else { return 0 }
    return frecencyStore.boost(forKey: FrecencyKey.command(label: label))
  }

  /// Record a frecency open against a command-line verb (`:flashlight`,
  /// `:help`, …). Called from every `submitCommandLine` so the empty-
  /// `:` prompt surfaces the user's actual habits.
  private func recordCommandLineFrecency(rawInput: String) {
    guard let frecencyStore else { return }
    var trimmed = rawInput.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(":") { trimmed.removeFirst() }
    guard let verb = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { return }
    let label = verb.lowercased()
    guard !label.isEmpty else { return }
    frecencyStore.recordOpen(itemKey: FrecencyKey.command(label: label))
  }

  private var commandBarSuggestionCount: Int {
    max(1, config.flashlight.suggestionCount)
  }

  func commandLineCompletionDisplayItems() -> [CandidateDisplayItem] {
    guard !commandLineCompletionMatches.isEmpty else { return [] }
    // Same windowed slice as the flashlight finder. This list used to show
    // every match at once ("reveal the whole catalogue"), but the plugin
    // command set has outgrown the band between the centered prompt and the
    // screen bottom — an unwindowed list drew up across the prompt itself.
    // Arrow keys scroll the window over the full match set.
    let window = CandidateFinder.displayWindow(
      count: commandLineCompletionMatches.count,
      selectedIndex: commandLineCompletionSelection.index ?? 0,
      windowSize: commandBarSuggestionCount)
    return commandLineCompletionMatches[window].enumerated().map { offset, match in
      CandidateDisplayItem(
        title: match.completion.label,
        detail: match.completion.detail,
        highlightedRanges: commandLineCompletionQuery.isEmpty
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: commandLineCompletionQuery, candidate: match.completion.label),
        isSelected: window.lowerBound + offset == commandLineCompletionSelection.index)
    }
  }

  private func clearCommandLineCompletionState() {
    commandLineCompletionPrefix = ""
    commandLineCompletionMatches = []
    commandLineCompletionSelection = .none
    commandLineCompletionQuery = ""
  }

  static func commandLineBuffer(from raw: String) -> String {
    raw.hasPrefix(":") ? raw : ":\(raw)"
  }

  private func updateCandidateMatches(query: String) {
    if finder.menu != nil { return applyMenuMatches(query: query) }
    let t0 = CFAbsoluteTimeGetCurrent()
    // `@<type>` narrows the pool to one resource type; the residual text after
    // the `@type ` token is the actual fuzzy query.
    let sourceCompletion = CandidateFinder.sourceCompletionState(query: query)
    let bangCompletion = CandidateFinder.bangCompletionState(query: query)
    let parsed =
      sourceCompletion == nil
      ? NormalModeDispatcher.candidateFinderQuery(query)
      : NormalModeDispatcher.CandidateFinderQuery(scope: nil, text: query)
    // A confirmed bang that lists candidates (`!clip `, `!f report`) scopes
    // the rest of the query exactly as `@<type>` does: one cached pool,
    // ranked by the incremental scorer.
    let boundBang = sourceCompletion == nil ? boundBangScope(query) : nil
    let scope = boundBang?.scope ?? parsed.scope
    let trimmed = parsed.text
    finder.currentQuery = sourceCompletion?.token ?? trimmed
    beginLiveSourceQueriesIfNeeded(forCandidateQuery: query)
    let calculatorOnly = boundBang == nil && trimmed.first == "="
    if calculatorOnly {
      finder.incrementalCache = nil
      beginCandidateQueryEvaluationIfNeeded(text: trimmed)
      // A leading `=` is an exclusive evaluator marker. Do not score or show
      // the ordinary catalog while its owning calculator answers settle.
      applyCandidateMatches([])
      return
    }
    let parsedBang = boundBang == nil ? CandidateFinder.parseBang(trimmed) : nil
    let usesTransientCompletionPool =
      sourceCompletion != nil
      || bangCompletion != nil
      || parsedBang != nil

    // Non-location sources (emojis, bangs, notes, …) aren't pulled on open; the
    // moment the user confirms a `@type` or types a `!`bang, fetch the warm
    // stores needed for that intent. Source-completion rows come from manifest
    // declarations, so partial `@em...` input performs no catalog snapshots.
    prefetchNonLocationSources(forCandidateQuery: query)

    if boundBang == nil, let token = bangListToken(trimmed: trimmed, rawQuery: query) {
      invalidateCandidateQueryEvaluation()
      finder.incrementalCache = nil
      finder.indexGenerationCounter &+= 1
      showBangList(token: token, startedAt: t0)
      return
    }

    let (pool, scoringText) =
      boundBang.map { (filteredCandidatePool(scope: $0.scope), $0.remainder) }
      ?? buildCandidateFinderPool(trimmed: trimmed, rawQuery: query, scope: scope)
    let tFiltered = CFAbsoluteTimeGetCurrent()

    // Bump the generation so any scoring job that completes AFTER
    // this keystroke is dropped silently when its callback fires.
    finder.indexGenerationCounter &+= 1
    let generation = finder.indexGenerationCounter

    if usesTransientCompletionPool {
      invalidateCandidateQueryEvaluation()
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scoringText)
      let fuzzy = NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalizedQuery)
      let scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalizedQuery,
        fuzzyScore: fuzzy,
        allowParallel: false)
      let sorted = CandidateFinder.sortedMatches(scored, precedence: precedenceTable())
      // Bang / source-completion pools are disjoint from the main flashlight
      // pool, so a saved incremental cache from a previous keystroke must
      // not survive into the next plain-query keystroke.
      finder.incrementalCache = nil
      applyCandidateMatches(sorted)
      return
    }

    if scoringText.trimmed.isEmpty {
      invalidateCandidateQueryEvaluation()
      let fuzzy = NormalModeDispatcher.fuzzyScorer(normalizedQuery: "")
      let scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: "",
        fuzzyScore: fuzzy,
        allowParallel: false)
      let sorted = CandidateFinder.sortedMatches(scored, precedence: precedenceTable())
      // Empty query returns the whole filtered pool — a useful starting
      // point but not a fuzzy-narrowed set, so leave the incremental
      // cache empty and let the first real keystroke seed it from the
      // full pool.
      finder.incrementalCache = nil
      applyCandidateMatches(sorted)
      return
    }

    // Bare input is additive: every registered evaluator gets the same exact
    // text. A confirmed `@type` remains catalog-only, but still uses the
    // large-pool ranker below (parallel scoring, incremental narrowing, and a
    // bounded display sort). Evaluator rows live in a fixed answer lane and
    // never enter this fuzzy scorer or its incremental cache.
    if scope == nil {
      beginCandidateQueryEvaluationIfNeeded(text: scoringText.trimmed)
    } else {
      invalidateCandidateQueryEvaluation()
    }

    // Score on the main thread so the keystroke and its fresh result
    // land in the same frame. The fuzzy ranker uses the precomputed
    // scoring masks + normalized fields stashed by `CandidateFinder
    // .prepare`, so a 3000-candidate pool typically scores + sorts in
    // ~1–2ms — well under the 16ms frame budget. The earlier
    // background-queue + async-callback design was visibly choppy: the
    // keystroke painted with the previous match snapshot, then the
    // sorted result replaced it a frame later, which felt like a
    // perceptible delay even when the work itself was sub-millisecond.
    // The heaviest pools (full installed-app + plugin candidate
    // counts) stay below ~5k so the synchronous path stays cheap.
    let tScoringStart = CFAbsoluteTimeGetCurrent()
    // Rewrite standalone emoticons (`:)`, `:-(`, `;)`, …) to the emoji
    // shortcodes the `emojis` plugin indexes before normalization strips
    // their punctuation — otherwise `@emojis :)` collapses to an empty query
    // and lists every glyph unranked.
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(
      NormalModeDispatcher.expandEmoticons(scoringText))
    let fuzzy = NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalizedQuery)
    let signature = scope?.signature ?? ""
    // Incremental narrowing: if the new query extends the previous one
    // and neither the pool nor the attribute filters have changed since
    // the previous keystroke, no candidate that failed the shorter
    // query can possibly pass the longer one. Re-score only the
    // previous match set; the candidate space contracts on every
    // keystroke and scoring gets monotonically cheaper.
    let scoringPool: [Candidate]
    let isIncremental: Bool
    if let cache = finder.incrementalCache,
      cache.epoch == finder.candidatesEpoch,
      cache.signature == signature,
      !cache.normalizedQuery.isEmpty,
      normalizedQuery.count > cache.normalizedQuery.count,
      normalizedQuery.hasPrefix(cache.normalizedQuery)
    {
      scoringPool = cache.matches.map(\.candidate)
      isIncremental = true
    } else {
      scoringPool = pool
      isIncremental = false
    }
    var scored = CandidateFinder.scoreMatches(
      pool: scoringPool,
      normalizedQuery: normalizedQuery,
      fuzzyScore: fuzzy,
      allowParallel: true)
    let tScored = CFAbsoluteTimeGetCurrent()
    // Apply frecency boost before the sort so the comparator sees the
    // final score. Skip the loop entirely when the store has no
    // entries — the boost is always 0 in that case and
    // `FrecencyMapper.itemKey` does a non-trivial amount of per-candidate
    // work that's pure waste here.
    let store = self.frecencyStore
    if let store, !store.isEmpty {
      // One copy of the table per keystroke; the key was derived at prepare.
      let boosts = store.boosts()
      for index in scored.indices {
        let candidate = scored[index].candidate
        let key =
          candidate.sortKey.isEmpty
          ? FrecencyMapper.itemKey(for: candidate)
          : (candidate.frecencyKey.isEmpty ? nil : candidate.frecencyKey)
        if let key, let boost = boosts[key] {
          scored[index].score += boost
        }
      }
    }
    // Top-K bounded sort. The display window is `commandBarSuggestionCount`
    // (default 10), with arrow-key scrolling allowed inside the bounded
    // set, so a 3x buffer keeps the result list scroll-friendly without
    // paying for a full O(N log N) sort of every match. Keep the
    // incremental cache unbounded, though: a row that misses the display
    // top-K for "t" can become the best match for "tmux".
    let sortLimit = max(commandBarSuggestionCount * 3, 30)
    let ranked = CandidateFinder.displayAndIncrementalMatches(
      scored, precedence: precedenceTable(), limit: sortLimit)
    let sorted = ranked.display
    let tSorted = CFAbsoluteTimeGetCurrent()
    // Re-check the generation — a re-entrant call (e.g. caches landing
    // mid-update) could have already superseded us.
    guard generation == self.finder.indexGenerationCounter else { return }
    finder.incrementalCache = (
      normalizedQuery: normalizedQuery,
      matches: ranked.incremental,
      epoch: finder.candidatesEpoch,
      signature: signature
    )
    applyCandidateMatches(sorted)
    if !trimmed.isEmpty {
      let tRendered = CFAbsoluteTimeGetCurrent()
      let dFilter = Int((tFiltered - t0) * 1000)
      let dScore = Int((tScored - tScoringStart) * 1000)
      let dSort = Int((tSorted - tScored) * 1000)
      let dRender = Int((tRendered - tSorted) * 1000)
      let dTotal = Int((tRendered - t0) * 1000)
      FlashLog.trace(
        "[flashlight] pool=\(pool.count) scored=\(scoringPool.count) inc=\(isIncremental) "
          + "matches=\(sorted.count) "
          + "total_ms=\(dTotal) filter_ms=\(dFilter) score_ms=\(dScore) "
          + "sort_ms=\(dSort) render_ms=\(dRender)")
    }
  }

  /// Build a `PrecedenceTable` from the live source descriptors and config
  /// overrides. Frozen once with the candidate snapshot so query-time sorting
  /// uses a prepared table.
  func buildCandidateFinderPrecedenceTable() -> CandidateFinder.PrecedenceTable {
    let sources = registry.registeredCandidateSourceDescriptors()
    return CandidateFinder.PrecedenceTable(
      sources: sources,
      overrides: Self.sourceWeights(typeWeights: config.flashlight.precedence, sources: sources),
      aliveBonus: config.flashlight.precedenceAliveBonus)
  }

  /// `[flashlight.precedence]` weighs resource types; the table weighs
  /// sources: each type's weight goes to every source of it.
  static func sourceWeights(
    typeWeights: [String: Int], sources: [CandidateSourceDescriptor]
  ) -> [String: Int] {
    var weights: [String: Int] = [:]
    for source in sources {
      if let weight = typeWeights[source.type] { weights[source.name] = weight }
    }
    return weights
  }

  private func precedenceTable() -> CandidateFinder.PrecedenceTable {
    finder.precedenceTable
  }

  /// Set `finder.matches` and clamp the selected index.
  /// Centralised so the SearchService completion and the disabled-
  /// mode fallback can't drift on the selection-bounds rules.
  private func applyCandidateMatches(_ matches: [CandidateMatch]) {
    let catalogMatches: [CandidateMatch]
    if finder.queryAnswers.isEmpty {
      catalogMatches = matches
    } else {
      let answerKeys = Set(
        finder.queryAnswers.map {
          "\($0.sourceID)\u{0}\($0.title)"
        })
      catalogMatches = matches.filter {
        !answerKeys.contains("\($0.candidate.sourceID)\u{0}\($0.candidate.title)")
      }
    }
    let answers = finder.queryAnswers.enumerated().map { index, candidate in
      CandidateMatch(candidate: candidate, score: Int.max - index)
    }
    finder.matches = answers + catalogMatches
    if let followed = finder.followedRow,
      let index = finder.matches.firstIndex(where: {
        $0.candidate.sourcePayload == followed.payload && $0.candidate.source == followed.source
      })
    {
      finder.followedRow = nil
      finder.selectedIndex = index
    }
    if finder.matches.isEmpty {
      finder.selectedIndex = 0
    } else {
      finder.selectedIndex = min(
        max(finder.selectedIndex, 0), finder.matches.count - 1)
    }
  }

  /// Launch one evaluator fan-out per canonical bare query. The session and
  /// per-query generations jointly reject results from closed surfaces and
  /// superseded keystrokes. `SourceRegistry` itself completes only once, so a
  /// multi-plugin response produces a single repaint.
  private func beginCandidateQueryEvaluationIfNeeded(text: String) {
    let exactText = text.trimmed
    guard !exactText.isEmpty, exactText != finder.queryEvaluationText else {
      return
    }
    finder.queryEvaluationGeneration &+= 1
    let evaluationGeneration = finder.queryEvaluationGeneration
    let sessionGeneration = finder.sessionGeneration
    finder.queryEvaluationText = exactText
    finder.queryAnswers = []
    finder.queryEvaluationInFlightGeneration = evaluationGeneration
    finder.queryEvaluationSettledGeneration = nil

    registry.evaluateQuery(
      QueryEvaluationRequest(
        surface: .flashlight,
        text: exactText,
        exclusivePrefix: exactText.first == "=" ? "=" : nil)
    ) { [weak self] candidates in
      guard let self,
        sessionGeneration == self.finder.sessionGeneration,
        evaluationGeneration == self.finder.queryEvaluationGeneration,
        exactText == self.finder.queryEvaluationText
      else { return }
      switch self.overlay.inputMode {
      case .commandLine: break
      default: return
      }
      self.finder.queryAnswers = candidates
      if !candidates.isEmpty {
        self.finder.selectedIndex = 0
      }
      if !candidates.isEmpty || self.finder.submissionDeferral.hasPendingAction {
        // Do not open the submission gate until the coalesced render has put
        // these answers into `finder.matches`.
        self.finder.queryEvaluationSettledGeneration = evaluationGeneration
        self.scheduleCoalescedCandidateFinderRerender()
      } else {
        // No answer lane changed and nobody is waiting to submit, so the fuzzy
        // rows already on screen are final for this exact query.
        self.finder.queryEvaluationInFlightGeneration = nil
      }
    }
  }

  private func invalidateCandidateQueryEvaluation() {
    finder.queryEvaluationGeneration &+= 1
    finder.queryEvaluationInFlightGeneration = nil
    finder.queryEvaluationSettledGeneration = nil
    finder.queryEvaluationText = ""
    finder.queryAnswers = []
  }

  /// The bang-list pool: static manifest-declared bangs plus the dynamic
  /// bang-kind rows from published catalogs (e.g. the searchproviders bangs),
  /// which land in the session pool once the non-location sources are read on
  /// the first `@type`/`!` keystroke.
  private func bangListCandidates() -> [Candidate] {
    CoreBangs.candidates
      + pluginManager.shebangCandidates(in: sessionSelectorContext())
      + UserBangs.candidates(config.flashlight.bangs)
      + finder.candidates.filter { $0.kind == CandidateFinder.bangKind }
  }

  /// The scope a confirmed `!token` swaps the pool to: a core bang's first
  /// (`!f` → `@files`), else the one source a plugin bang registration binds
  /// (`!fh` → `firefox.history`).
  private func bangCandidateScope(token: String) -> SourceScope? {
    CoreBangs.bang(token: token)?.scope
      ?? pluginManager.shebangCandidateSource(token: token, in: sessionSelectorContext())
      .map(SourceScope.source)
  }

  /// Dispatch a named `#[range=user|<name>]` status-bar click through the
  /// `[statusbar.click]` action map — tmux's status-line mouse model: the
  /// span names the action, the binding lives in config. URLs open
  /// activating; action arrays run through the mapping-command dispatcher
  /// (same power as a keybinding, e.g. ["flash", "volume", "down"]).
  func performStatusBarClickAction(named name: String) {
    guard let action = config.statusBar.clickActions[name] else {
      FlashLog.warn(
        "[statusbar] click range \"\(name)\" has no [statusbar.click] action configured")
      overlay.displayBanner("no [statusbar.click] action for \"\(name)\"")
      return
    }
    FlashLog.debug("[statusbar] click_action name=\(name)")
    switch action {
    case .url(let raw):
      guard let url = URLParsing.url(raw) else { return }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    case .command(let command):
      performMappingCommand(command)
    }
  }

  /// True when a confirmed `!token` is actually routable: an exact shebang
  /// registration, or a bang its wildcard owner has published to the pool
  /// (the searchproviders bang rows: its best-ranked 10,000, so a rarer trigger
  /// it still resolves underlines as unknown). A wildcard registration alone
  /// doesn't count — the owner would just reject the token at dispatch.
  /// Drives the lock-in underline color: purple for routable, red for a
  /// token nothing will answer.
  private func confirmedBangIsKnown(_ token: String) -> Bool {
    let lc = token.lowercased()
    if let index = finder.bangIndex, index.epoch == finder.candidatesEpoch,
      index.session == finder.sessionGeneration
    {
      return index.index.tokens.contains(lc)
    }
    return bangListCandidates().contains {
      $0.sourcePayload?.lowercased() == lc
    }
  }

  /// The token a `!` query lists bangs for: `!<token>` being typed, or a
  /// confirmed one no candidate source owns (`!g rust` keeps listing `g`).
  /// Nil when the query is no bang, or a confirmed bang that swaps the pool
  /// to its source (`!f report`).
  private func bangListToken(trimmed: String, rawQuery: String) -> String? {
    if let bang = CandidateFinder.parseBangState(trimmed), bang.confirmed,
      bangCandidateScope(token: bang.token) != nil
    {
      return nil
    }
    if let bang = CandidateFinder.parseBang(trimmed) { return bang.token }
    // The raw query: a trailing space after a bare sigil dismisses the list
    // (`!` shows the bangs, `! ` does not).
    return CandidateFinder.bangCompletionState(query: rawQuery)?.token
  }

  /// The bang list for `token` without scoring every bang on the main
  /// thread: the index's prefix tier at once, completed by the full scorer
  /// off the main thread when that tier does not fill the display.
  private func showBangList(token: String, startedAt t0: CFAbsoluteTime) {
    let epoch = finder.candidatesEpoch
    guard let index = bangCompletionIndex(epoch: epoch) else {
      applyCandidateMatches([])
      return
    }
    let normalized = NormalModeDispatcher.normalizedSearchText(token)
    let limit = max(commandBarSuggestionCount * 3, 30)
    if let complete = finder.bangCompletion, complete.epoch == epoch,
      complete.token == normalized
    {
      applyCandidateMatches(complete.matches)
      return
    }
    let listed = index.matches(
      normalizedToken: normalized, precedence: precedenceTable(), limit: limit)
    applyCandidateMatches(listed.matches)
    FlashLog.trace(
      "[flashlight] bangs=\(index.rows.count) matches=\(listed.matches.count) "
        + "final=\(listed.final) total_ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))")
    guard !listed.final else { return }
    let generation = finder.indexGenerationCounter
    let precedence = precedenceTable()
    let ticket = finder.bangScoringTicket
    ticket.issue(generation)
    finder.bangScoringQueue.async { [weak self] in
      guard ticket.isLatest(generation) else { return }
      let scored = CandidateFinder.scoreMatches(
        pool: index.rows, normalizedQuery: normalized,
        fuzzyScore: NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalized),
        allowParallel: true)
      let sorted = CandidateFinder.sortedMatches(scored, precedence: precedence, limit: limit)
      DispatchQueue.main.async {
        guard let self, ticket.isLatest(generation), self.finder.candidatesEpoch == epoch else {
          return
        }
        self.finder.bangCompletion = (epoch, normalized, sorted)
        self.scheduleCoalescedCandidateFinderRerender()
      }
    }
  }

  /// The bang index for the current candidates, or nil while it builds: the
  /// build reads the whole pool, so it runs off the main thread once per
  /// epoch and re-renders when it lands.
  private func bangCompletionIndex(epoch: UInt64) -> BangCompletionIndex? {
    if let built = finder.bangIndex, built.epoch == epoch,
      built.session == finder.sessionGeneration
    {
      return built.index
    }
    guard finder.bangIndexBuilding != epoch else { return finder.bangIndex?.index }
    finder.bangIndexBuilding = epoch
    let candidates = finder.candidates
    let declared =
      CoreBangs.candidates
      + pluginManager.shebangCandidates(in: sessionSelectorContext())
      + UserBangs.candidates(config.flashlight.bangs)
    let precedence = precedenceTable()
    let limit = max(commandBarSuggestionCount * 3, 30)
    let generation = finder.sessionGeneration
    finder.preparationQueue.async { [weak self] in
      let index = BangCompletionIndex(
        candidates: declared + candidates.filter { $0.kind == CandidateFinder.bangKind },
        precedence: precedence, limit: limit)
      DispatchQueue.main.async {
        guard let self, self.finder.bangIndexBuilding == epoch else { return }
        self.finder.bangIndexBuilding = nil
        // The declared bangs follow the session's focused app.
        guard self.finder.sessionGeneration == generation else { return }
        self.finder.bangIndex = (epoch, generation, index)
        self.scheduleCoalescedCandidateFinderRerender()
      }
    }
    // A previous epoch's index lists the bangs it knew while this one builds.
    return finder.bangIndex?.index
  }

  /// Pick the candidate pool and the text we score against. Three cases:
  ///
  ///   * Bang mode (query starts with `!`) — the pool is the bang registry. A
  ///     confirmed bang that lists a candidate source (`!fh `, `!clip `)
  ///     never comes here: the caller scopes the rest of the query to that
  ///     source with `filteredCandidatePool`, as `@<type>` does.
  ///   * `@<type>` mode — the pool is narrowed to that one resource type. With an
  ///     empty residual the user sees every candidate from that source (e.g.
  ///     `@emojis ` lists every emoji).
  ///   * Default — the regular pool scored on the full query, restricted to
  ///     location entities. Synthetic
  ///     bang / source-completion rows are always excluded; all other sources
  ///     are excluded unless the user opts in via `@<type>`.
  private func buildCandidateFinderPool(
    trimmed: String,
    rawQuery: String,
    scope: SourceScope?
  ) -> (pool: [Candidate], scoringText: String) {
    if let bang = CandidateFinder.parseBang(trimmed) {
      let bangs = CandidateFinder.prepare(bangListCandidates())
      return (bangs, bang.token)
    }
    // Use the *raw* (untrimmed) query so a trailing space after a bare sigil
    // dismisses the suggestions: `!` shows bang candidates, `! ` does not.
    if let bang = CandidateFinder.bangCompletionState(query: rawQuery) {
      let bangs = CandidateFinder.prepare(bangListCandidates())
      return (bangs, bang.token)
    }
    // `@<partial>` completion: when the user is in the middle of
    // typing a source token (no trailing whitespace yet), swap the
    // pool for source-completion rows derived from the candidates
    // actually present. This mirrors the bang-completion surface so
    // `<tab>`/`<cr>` semantics stay identical across both modes.
    if let completion = CandidateFinder.sourceCompletionState(query: rawQuery) {
      let pool = CandidateFinder.prepare(
        knownSourceCompletionCandidates())
      // A dotted source name from before resource types completes to the
      // type it most likely meant (`@emojis` offers `@emojis`).
      return (pool, ResourceTypes.suggestion(for: completion.token) ?? completion.token)
    }
    return (filteredCandidatePool(scope: scope), trimmed)
  }

  /// The session pool narrowed to `scope`'s rows, or to the default
  /// (location) rows without one.
  private func filteredCandidatePool(scope: SourceScope?) -> [Candidate] {
    // Joined only on a cache miss: the cache hit below, the common
    // keystroke, copies nothing.
    func availableCandidates() -> [Candidate] { finder.candidates + finder.liveQuery.rows }
    // Cache the kind+source-narrow pass — while the user types into
    // flashlight the signature is stable, so the same ~2k-entry filter
    // ran ~2k times on every keystroke. Keyed by the base-pool epoch +
    // filter signature; one-slot cache because consecutive keystrokes
    // always share the same key.
    let signature = scope?.signature ?? ""
    let basePool: [Candidate]
    if let cached = finder.filteredPoolCache,
      cached.epoch == finder.candidatesEpoch,
      cached.signature == signature
    {
      basePool = cached.pool
    } else {
      // `@<type>` opts in to whatever type the user names. Without one, keep
      // the default flashlight focused on locations.
      let userOptedIntoSource = scope != nil
      let precedence = precedenceTable()
      let types = scope == nil ? [:] : registry.resourceTypesBySource()
      let pool = availableCandidates().filter { candidate in
        guard candidate.kind != CandidateFinder.bangKind,
          candidate.kind != CandidateFinder.sourceKind
        else { return false }
        guard Self.candidateCanRenderInCommandBar(candidate) else { return false }
        if !userOptedIntoSource,
          !CandidateFinder.isDefaultFlashlightCandidate(candidate, precedence: precedence)
        {
          return false
        }
        if let scope, !scope.matches(candidate, types: types) {
          return false
        }
        return true
      }
      finder.filteredPoolCache = (
        epoch: finder.candidatesEpoch,
        signature: signature,
        pool: pool
      )
      basePool = pool
    }
    return basePool
  }

  static func candidateCanRenderInCommandBar(_ candidate: Candidate) -> Bool {
    CandidateEmojiSupport.candidateCanRenderInCommandBar(candidate)
  }

  /// One `@<type>` completion row per registered resource type. It reads the
  /// source declarations, not the visible pool, so `@tabs` is offered before
  /// the browsers plugin produced a tab snapshot this session.
  private func knownSourceCompletionCandidates() -> [Candidate] {
    registry.registeredResourceTypeProviders().map {
      CandidateFinder.sourceCompletionCandidate(type: $0.type, providers: $0.providers)
    }
  }

  func candidateFinderDisplayItems(windowSize: Int? = nil) -> [CandidateDisplayItem] {
    guard !finder.matches.isEmpty else { return [] }
    let window = CandidateFinder.displayWindow(
      count: finder.matches.count,
      selectedIndex: finder.selectedIndex,
      windowSize: windowSize ?? commandBarSuggestionCount)
    let labels = ResourceTypeLabels(types: registry?.resourceTypesBySource() ?? [:])
    return finder.matches[window].enumerated().map { offset, match in
      let (title, detail) = labels.label(
        match.candidate,
        displayTitle: match.candidate.displayTitle.isEmpty
          ? candidateFinderDisplayTitle(match.candidate) : match.candidate.displayTitle)
      return CandidateDisplayItem(
        title: title,
        detail: detail,
        highlightedRanges: finder.currentQuery.isEmpty || match.candidate.effect != nil
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: finder.currentQuery,
            candidate: title),
        isSelected: window.lowerBound + offset == finder.selectedIndex)
    }
  }

  /// The pick's rows for `query`, as the list shows them.
  private func applyMenuMatches(query: String) {
    guard let menu = finder.menu else { return }
    finder.currentQuery = query.trimmingCharacters(in: .whitespaces)
    finder.matches = MenuChoice.matches(menu.candidates, query: query)
    finder.selectedIndex = 0
  }

  private func candidateFinderDisplayTitle(_ candidate: Candidate) -> String {
    CandidateFinder.displayTitle(candidate)
  }

  static func candidateFinderDisplayTitle(source: String, title: String) -> String {
    CandidateFinder.displayTitle(source: source, name: title)
  }

  /// Append a submitted command to the recall history (most-recent last),
  /// dropping a consecutive duplicate and bounding the size. Records every
  /// submission, success or not. Resets the recall cursor so the next up/down
  /// starts from the newest entry.
  func recordCommandLineHistory(_ rawInput: String) {
    // Persist so recall survives the next restart/reinstall.
    if commandLineHistory.record(rawInput) {
      commandHistoryStore?.save(commandLineHistory.entries)
    }
  }

  /// `variant` is a modified Return (Shift- or Option-Return); only the
  /// flashlight's clipboard rows read it.
  func submitCommandLine(_ rawInput: String, variant: CommandLineSubmitVariant? = nil) {
    // `#` output-capture modifier (`:#aws whoami`): strip it up front so all
    // downstream parsing sees a clean command line, and remember to route the
    // command's output onto the clipboard rather than just a toast.
    let (raw, captureOutput) =
      NormalModeDispatcher.commandLineClipboardModifier(rawInput)
    // Record the verb against the frecency store so the empty-`:`
    // completion list surfaces what the user actually runs. We record
    // before dispatch so even an unknown command (typo or
    // half-finished plugin install) still gets a frequency mark — the
    // user's intent is what matters; the cost of a bad mark is bounded
    // by the same decay all other frecency entries pay.
    recordCommandLineFrecency(rawInput: raw)
    recordCommandLineHistory(rawInput)
    if NormalModeDispatcher.commandLineCandidateQuery(raw) != nil {
      actOnSelectedCandidateFinderCandidate(submit: false, allowFinisher: true, variant: variant)
      return
    }
    // A row the user moved to is what Enter runs, whatever the text
    // resolves to. `applySelected…` clears the completion state before
    // recursing, so the recursive call resolves the inserted words.
    if commandLineCompletionSelection.isChosen, applySelectedCommandLineCompletion() {
      return
    }
    // Otherwise the words resolve as the completion list showed them, and as
    // `flash` resolves the same words in a terminal: an exact command, an ex
    // command, or each word by its unique prefix. The list's highlighted
    // row, when there is one, is that same resolution.
    let words = NormalModeDispatcher.commandLineWords(raw)
    var invocation = CommandInvocation(
      words: words, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    invocation.capturesOutput = captureOutput
    let inventory = commandLineInventory()
    let resolution = NormalModeDispatcher.resolveCommandWords(words, inventory: inventory)
    switch resolution {
    case .empty:
      finishCommandLineInteraction(reason: "command_empty")
    case .incomplete, .ambiguous, .unknown:
      // Nothing runs. A highlighted row — the unique word an incomplete
      // line names (`:ta` inserts `tab `) — is applied; otherwise the list,
      // when there is one, stays up as the feedback: the candidates of an
      // ambiguous word, or the words the typed text resembles.
      let topLevelEmpty =
        commandLineCompletionPrefix == ":" && commandLineCompletionQuery.isEmpty
      if !topLevelEmpty, applySelectedCommandLineCompletion() {
        return
      }
      if !commandLineCompletionMatches.isEmpty, !topLevelEmpty {
        FlashLog.debug("[command] nothing to run for \(raw); the list shows the candidates")
        return
      }
      finishCommandLineInteraction(reason: "command_unknown")
      if !NormalModeDispatcher.commandLineBodyIsEmpty(raw) { warnUnsupportedCommand(raw) }
    case .commands, .plugin, .query, .open, .flashlight, .shell, .normalKeys:
      finishCommandLineInteraction(reason: "command_submit")
      // What `@:` runs again, and what a recording keeps for the `:`.
      macros.noteCommandLine(rawInput)
      performResolution(
        resolution, invocation: invocation, inventory: inventory, surface: .commandLine
      ) { [weak self] result in
        self?.presentCommandLineResult(result, invocation: invocation)
      }
    }
  }

  private func applySelectedCommandLineCompletion() -> Bool {
    guard let index = commandLineCompletionSelection.index,
      commandLineCompletionMatches.indices.contains(index)
    else { return false }
    let match = commandLineCompletionMatches[index]
    let completion = match.completion
    let prefix = commandLineCompletionPrefix
    let newBuffer = prefix + completion.insertion
    switch completion.kind {
    case .acceptsArgs:
      refreshCommandLine(text: newBuffer, cursorIndex: newBuffer.count)
      return true
    case .terminal, .pluginSubcommand:
      clearCommandLineCompletionState()
      submitCommandLine(newBuffer)
      return true
    }
  }

  /// Insert the selected completion's **value** (`insertion`) into the
  /// command line without submitting — the `<tab>` half of the
  /// candidate contract. The visible `label` is purely cosmetic; what
  /// lands in the buffer is always the value. With no row highlighted (an
  /// ambiguous word), Tab takes the first, as vim's completion cycles from
  /// the top. Returns false when no completion list is active so the caller
  /// can fall back to selection movement (the candidate finder keeps its
  /// documented tab-to-cycle).
  func applySelectedCommandLineCompletionInPlace() -> Bool {
    guard !commandLineCompletionMatches.isEmpty else { return false }
    commandLineCompletionSelection = commandLineCompletionSelection.tabbed(
      count: commandLineCompletionMatches.count)
    guard let index = commandLineCompletionSelection.index else { return false }
    let completion = commandLineCompletionMatches[index].completion
    let newBuffer = commandLineCompletionPrefix + completion.insertion
    refreshCommandLine(text: newBuffer, cursorIndex: newBuffer.count)
    return true
  }

  /// Single act-on-selection entry point for the flashlight surface.
  /// `<cr>` and `<tab>` call with `submit=false` (insert-first).
  /// Return passes `allowFinisher=true`, so source-owned finishers and
  /// exact primary-title matches can open. Tab passes `allowFinisher=false`
  /// but `submitFinalDestinations=true`, so location rows behave like an
  /// explicit Command-Return while partial/source rows still rewrite the
  /// buffer. `<cmd+cr>` calls with `submit=true`, the explicit force-submit
  /// path for real candidates.
  /// Synthetic source-filter rows are always insert-only. `variant` rides
  /// along to a clipboard row (Shift-Return: plain text, Option-Return: copy).
  func actOnSelectedCandidateFinderCandidate(
    submit: Bool,
    allowFinisher: Bool = true,
    submitFinalDestinations: Bool = false,
    variant: CommandLineSubmitVariant? = nil
  ) {
    let initialSnapshotPending = finder.initialBarrier != nil
    let evaluationInFlight = finder.queryEvaluationInFlightGeneration
    if initialSnapshotPending || evaluationInFlight != nil {
      finder.submissionDeferral.deferAction(
        CandidateSubmissionDeferral.Action(
          submit: submit,
          allowFinisher: allowFinisher,
          submitFinalDestinations: submitFinalDestinations,
          variant: variant),
        sessionGeneration: finder.sessionGeneration,
        query: activeCandidateFinderInputText(),
        evaluationGeneration: initialSnapshotPending ? nil : evaluationInFlight)
      FlashLog.trace(
        "[flashlight] action_deferred session=\(finder.sessionGeneration) "
          + "query_generation=\(evaluationInFlight.map(String.init) ?? "initial")")
      return
    }
    if let menu = finder.menu {
      // Answer first: the close that follows then finds no pick to cancel.
      guard
        let picked = MenuChoice.pick(
          matches: finder.matches, selectedIndex: finder.selectedIndex,
          query: finder.currentQuery)
      else { return }
      finder.menu = nil
      finishCommandLineInteraction(reason: "menu_pick")
      menu.complete(.success(picked))
      return
    }
    let typedBang = CandidateFinder.parseBang(finder.currentQuery)
    let isEmpty = finder.matches.isEmpty

    if isEmpty {
      if let typed = typedBang {
        submitTypedBang(typed: typed)
      } else {
        finishCommandLineInteraction(reason: "command_open_empty")
      }
      return
    }

    let candidate = finder.matches[
      min(finder.selectedIndex, finder.matches.count - 1)
    ]
    .candidate
    if candidate.kind == CandidateFinder.bangKind,
      let token = candidate.sourcePayload
    {
      let remainder = typedBang?.remainder ?? ""
      // Dispatch the search when force-submitted (`<cmd+cr>`) OR on plain `<cr>`
      // (allowFinisher) once a query is already typed — `!g paris weather`, or a
      // bang anywhere like `paris weather !g`, searches immediately. Only fall
      // back to canonicalizing `:flashlight !<token> ` when there's no query yet
      // (so "type `!g`, then the query" keeps working) or on `<tab>`.
      if submit || (allowFinisher && !remainder.isEmpty) {
        submitTypedBang(typed: (token: token, remainder: remainder))
        return
      }
      let buffer = ":flashlight !\(token) "
      refreshCommandLine(text: buffer, cursorIndex: buffer.count)
      return
    }
    if candidate.kind == CandidateFinder.sourceKind,
      let source = candidate.sourcePayload
    {
      // Source-completion row. Rewrite the in-progress `@<partial>`
      // token in the buffer with the canonical `@<type> ` so the
      // existing source-filter parser applies it to the next refresh,
      // and the cursor sits ready for the query. Source rows are
      // synthetic completions, not resolvable candidates, so Return,
      // Tab, and Command-Return all stop at insertion.
      replaceInProgressAtSourceToken(with: source)
      return
    }
    if CandidateFinder.selectionSubmits(
      candidate,
      query: finder.currentQuery,
      submit: submit,
      allowFinisher: allowFinisher,
      submitFinalDestinations: submitFinalDestinations)
    {
      let insertionTargetPID = finder.invocationTargetPID
      finishCommandLineInteraction(reason: "command_open")
      openSourceItem(candidate, insertionTargetPID: insertionTargetPID, variant: variant)
      return
    }
    replaceCommandLineCandidateQuery(with: CandidateFinder.commandInsertionText(candidate))
  }

  /// Replay a held selection only when both asynchronous first-row boundaries
  /// have settled for the same session, exact query, and evaluator generation.
  /// A user edit, cancel, or superseding evaluation discards the action.
  private func replayDeferredCandidateSubmissionIfReady() {
    let resolution = finder.submissionDeferral.resolve(
      sessionGeneration: finder.sessionGeneration,
      query: activeCandidateFinderInputText(),
      currentEvaluationGeneration: finder.queryEvaluationGeneration,
      initialSnapshotPending: finder.initialBarrier != nil,
      evaluationInFlightGeneration: finder.queryEvaluationInFlightGeneration)
    switch resolution {
    case .none, .waiting:
      return
    case .discarded:
      FlashLog.trace(
        "[flashlight] deferred_action_discarded session=\(finder.sessionGeneration)")
    case .replay(let action):
      FlashLog.trace(
        "[flashlight] deferred_action_replay session=\(finder.sessionGeneration)")
      actOnSelectedCandidateFinderCandidate(
        submit: action.submit,
        allowFinisher: action.allowFinisher,
        submitFinalDestinations: action.submitFinalDestinations,
        variant: action.variant)
    }
  }

  /// Exact user-visible candidate query, before `@type`/bang parsing rewrites
  /// `finder.currentQuery` for scoring. Using this for deferral identity
  /// preserves initial-barrier submission for explicit selectors and makes any
  /// intervening edit invalidate the held action.
  private func activeCandidateFinderInputText() -> String {
    switch overlay.inputMode {
    case .commandLine:
      return NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText)
        ?? finder.currentQuery
    default:
      return finder.currentQuery
    }
  }

  /// Rewrite the trailing `@<partial>` token inside the live command
  /// line with `@<type> ` and re-render. Called by Tab/CR/Cmd+CR on
  /// a source-completion row so the user sees the canonical filter
  /// appear without leaving the surface.
  private func replaceInProgressAtSourceToken(with source: String) {
    let command = overlay.commandLineText
    guard let query = NormalModeDispatcher.commandLineCandidateQuery(command),
      let completion = CandidateFinder.parseAtSourceCompletion(query)
    else { return }
    // Map the `query`-relative @ range into the absolute command buffer
    // (the prompt + verb prefix the user can't see in `query`).
    let prefixLen = command.count - query.count
    let queryStart = command.index(command.startIndex, offsetBy: prefixLen)
    let atOffset = query.distance(from: query.startIndex, to: completion.atRange.lowerBound)
    let endOffset = query.distance(from: query.startIndex, to: completion.atRange.upperBound)
    let absoluteStart = command.index(queryStart, offsetBy: atOffset)
    let absoluteEnd = command.index(queryStart, offsetBy: endOffset)
    let replacement = "@\(source) "
    let buffer = command.replacingCharacters(in: absoluteStart..<absoluteEnd, with: replacement)
    let newCursor =
      command.distance(from: command.startIndex, to: absoluteStart) + replacement.count
    refreshCommandLine(text: buffer, cursorIndex: newCursor)
  }

  /// Replace the live `:flashlight` query with the selected candidate's
  /// canonical insertion text while keeping the
  /// command verb intact. Return reaches this path for non-finishers;
  /// Tab reaches it for non-final destinations. Command-Return is the
  /// explicit submit.
  private func replaceCommandLineCandidateQuery(with insertion: String) {
    let command = overlay.commandLineText
    guard let query = NormalModeDispatcher.commandLineCandidateQuery(command) else { return }
    let prefixLen = command.count - query.count
    let queryStart = command.index(command.startIndex, offsetBy: prefixLen)
    let buffer = String(command[..<queryStart]) + insertion
    refreshCommandLine(text: buffer, cursorIndex: buffer.count)
  }

  /// `<cmd+cr>` in bang mode. Dispatches whatever the user typed via
  /// `PluginManager.invokeShebang`, which checks explicit-token
  /// registrations first then falls back to the catch-all (so
  /// `!google rust` reaches searchproviders even though `google` isn't
  /// declared in any plugin's manifest). If a candidate row is
  /// selected AND its token equals the typed token, we still go
  /// through `invokeShebang` — its lookup is the same — so this path
  /// is unified.
  private func submitTypedBang(typed: (token: String, remainder: String)) {
    if let bang = CoreBangs.bang(token: typed.token) {
      // A core bang only scopes the flashlight to its source: lock it in and
      // keep the bar open for that source's rows (they may still be arriving).
      let buffer = ":flashlight !\(bang.token) \(typed.remainder)"
      refreshCommandLine(text: buffer, cursorIndex: buffer.count)
      return
    }
    // The user's own bang, unless a plugin declares the token by name: it
    // then keeps its owner, as the loader told a bundled plugin's would.
    let context = pluginSelectorContext()
    if !pluginManager.declaresShebang(token: typed.token, in: context),
      let bang = UserBangs.bang(token: typed.token, in: config.flashlight.bangs)
    {
      if let url = UserBangs.url(template: bang.url, query: typed.remainder) {
        FlashLog.debug("[normal] bang_user", fields: ["bang": typed.token.lowercased()])
        UserBangs.opener(url)
      } else {
        FlashLog.info("[normal] bang_user_unopenable", fields: ["bang": typed.token])
      }
      finishCommandLineInteraction(reason: "command_bang_submit")
      return
    }
    let dispatched = pluginManager.invokeShebang(
      token: typed.token,
      query: typed.remainder,
      in: context
    ) { [weak self] ok, pid, stdout, navigationURL in
      guard ok, let self else { return }
      self.activateCommandTarget(pid, navigationURL: navigationURL)
      guard let stdout, !stdout.isEmpty else { return }
      self.overlay.displayBanner(stdout)
    }
    if !dispatched {
      FlashLog.info("[normal] bang_unclaimed", fields: ["bang": typed.token])
    }
    finishCommandLineInteraction(reason: "command_bang_submit")
  }

  func finishCommandLineInteraction(reason: String) {
    // Drop the field editor explicitly so a cancel (Escape) closes the bar the
    // same way a submit does — a submit's app activation resigns our key window,
    // which the OS uses to tear the editor down; a cancel has no such trigger, so
    // without this the reused editor stayed associated and the next open showed
    // no caret.
    overlay.resignCommandTextFieldFocus()
    // The reducer pops the surface's recorded `restoreTo`; the resulting
    // base-mode entry effects tear down the command-line overlay.
    dispatchMode(.closeCommand(reason: reason))
  }

  func resetCommandLineState() {
    // Closed, or replaced by another open, without a pick.
    if let menu = finder.menu {
      finder.menu = nil
      menu.complete(.failure(.cancelled))
    }
    finder.invocationTargetPID = nil
    finder.selectorContext = nil
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    finder.scope = .all
    clearCandidateFinderState()
    clearCommandLineCompletionState()
    commandLineCompletionInventory = nil
  }

  func clearCandidateFinderState() {
    cancelCandidateFinderSessionWork()
    finder.candidates = []
    finder.matches = []
    finder.selectedIndex = 0
    finder.followedRow = nil
    finder.currentQuery = ""
    finder.precedenceTable = .default
    finder.incrementalCache = nil
  }

  func cancelCandidateFinderSessionWork() {
    // Bump the generation and cancel the UI deadline so in-flight plugin
    // replies cannot publish into a closed or superseded session.
    finder.sessionGeneration &+= 1
    finder.liveQuery.cancel()
    invalidateCandidateQueryEvaluation()
    finder.resetInitialSnapshot()
    finder.submissionDeferral.cancel()
    finder.fetchedNonLocationSourceIDs.removeAll()
    finder.deferredNonLocationSnapshots.removeAll()
  }

}
