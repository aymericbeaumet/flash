import AppKit
import FlashCore
import Foundation

/// What one relist did, for the refresh verbs.
enum AppleCatalogOutcome: Equatable {
  case listed(Int)
  /// The app is not running: the catalog is empty.
  case cleared
  /// Access is refused: the catalog is empty, and nothing is shown.
  case denied
  /// Nothing to do yet: access was never asked and this request may not ask.
  case kept
  /// The listing failed; the last good rows stay.
  case failed(String)
}

/// Owns the Notes, Reminders and Contacts catalogs: each one's last good
/// rows, its running-app gate, and when it relists (`AppleCatalogSchedule`).
/// Events arrive on main and only record state and queue work; every read of
/// an app runs on that catalog's own serial queue, so a slow Notes script
/// never holds up Reminders and nothing here blocks main or the keyboard
/// path. Requests queued while one runs merge into one more run.
final class AppleCatalogs {
  /// Called on main after a catalog's rows changed.
  var onChange: (AppleCatalog) -> Void = { _ in }

  private final class Engine {
    let catalog: AppleCatalog
    let reader: AppleCatalogReading
    let queue: DispatchQueue
    /// Guarded by `AppleCatalogs.lock`.
    var running = false
    var rows: [Candidate] = []
    /// Bumped when the app terminates: a listing begun before that is stale.
    var generation: UInt64 = 0
    var pending: AppleCatalogRequest?
    var waiters: [(AppleCatalogOutcome) -> Void] = []
    /// Requests that arrived while macOS's access prompt is open.
    var askWaiters: [(AppleCatalogOutcome) -> Void]?
    /// The last access macOS reported, so a query need not ask again.
    var knownAccess: AppleCatalogAccess?

    init(catalog: AppleCatalog, reader: AppleCatalogReading) {
      self.catalog = catalog
      self.reader = reader
      queue = DispatchQueue(label: "flash.apple-catalogs.\(catalog.rawValue)", qos: .utility)
    }
  }

  static let slowRefreshMs = 1_000

  private let lock = NSLock()
  private let engines: [AppleCatalog: Engine]
  /// Main only.
  private var schedule = AppleCatalogSchedule()
  private let nowMs: () -> Int

  init(
    readers: [AppleCatalog: AppleCatalogReading],
    nowMs: @escaping () -> Int = PollScheduler.continuousNowMs
  ) {
    var engines: [AppleCatalog: Engine] = [:]
    for (catalog, reader) in readers {
      engines[catalog] = Engine(catalog: catalog, reader: reader)
    }
    self.engines = engines
    self.nowMs = nowMs
  }

  // MARK: Reads (any thread)

  /// The last good rows, prepared for the flashlight.
  func rows(_ catalog: AppleCatalog) -> [Candidate] {
    guard let engine = engines[catalog] else { return [] }
    lock.lock()
    defer { lock.unlock() }
    return engine.rows
  }

  func isRunning(_ catalog: AppleCatalog) -> Bool {
    guard let engine = engines[catalog] else { return false }
    lock.lock()
    defer { lock.unlock() }
    return engine.running
  }

  // MARK: Events (main)

  /// The resident started with these apps running: list the catalogs Flash
  /// may already read. A failed first listing is retried once.
  func start(runningBundleIDs: Set<String>) {
    for catalog in AppleCatalog.allCases where runningBundleIDs.contains(catalog.bundleID) {
      setRunning(catalog, true)
      schedule.mark(catalog, nowMs: nowMs())
      request(catalog, .event) { [weak self] outcome in
        guard case .failed = outcome else { return }
        self?.request(catalog, .event)
      }
    }
  }

  func appLaunched(bundleID: String?) {
    guard let catalog = AppleCatalog.owning(bundleID: bundleID) else { return }
    setRunning(catalog, true)
    schedule.mark(catalog, nowMs: nowMs())
    request(catalog, .event)
  }

  /// Termination is authoritative: the rows go at once, and a listing begun
  /// before it is dropped when it lands.
  func appTerminated(bundleID: String?) {
    guard let catalog = AppleCatalog.owning(bundleID: bundleID), let engine = engines[catalog]
    else { return }
    lock.lock()
    engine.running = false
    engine.generation &+= 1
    let changed = !engine.rows.isEmpty
    engine.rows = []
    lock.unlock()
    if changed { onChange(catalog) }
  }

  /// Focus leaving a catalog's app relists it: the user may have just
  /// edited it.
  func focusChanged(bundleID: String?) {
    guard let left = schedule.focus(bundleID), isRunning(left) else { return }
    schedule.mark(left, nowMs: nowMs())
    request(left, .event)
  }

  /// A flashlight open relists the focused catalog and the stale ones.
  func sessionOpened() {
    let running = Set(AppleCatalog.allCases.filter(isRunning))
    for catalog in schedule.claimOnOpen(running: running, nowMs: nowMs()) {
      request(catalog, .event)
    }
  }

  /// A query named the catalog's source: the user is using it, so this is
  /// where Flash first asks macOS for access. Once macOS answered, a query
  /// costs nothing.
  func queried(_ catalog: AppleCatalog) {
    guard let engine = engines[catalog] else { return }
    lock.lock()
    let settled =
      !engine.running || engine.knownAccess == .granted
      || engine.knownAccess == .denied || engine.askWaiters != nil
    lock.unlock()
    guard !settled else { return }
    request(catalog, .query)
  }

  /// `<catalog>_refresh`: relist now, asking for access first if Flash never
  /// asked. `completion` runs on main.
  func refresh(_ catalog: AppleCatalog, completion: @escaping (AppleCatalogOutcome) -> Void) {
    schedule.mark(catalog, nowMs: nowMs())
    request(catalog, .command, completion)
  }

  /// Bring the row with `id` forward in its app. `completion` runs on main
  /// with whether it did.
  func show(_ catalog: AppleCatalog, id: String, completion: @escaping (Bool) -> Void) {
    guard let engine = engines[catalog] else {
      DispatchQueue.main.async { completion(false) }
      return
    }
    engine.reader.show(id: id) { failure in
      if let failure {
        FlashLog.warn("[apple] \(catalog.rawValue) selection failed: \(failure)")
      }
      DispatchQueue.main.async { completion(failure == nil) }
    }
  }

  /// Run `done` on main once the work queued for `catalog` so far has run,
  /// an open access prompt aside.
  func afterQueuedWork(_ catalog: AppleCatalog, _ done: @escaping () -> Void) {
    guard let engine = engines[catalog] else {
      DispatchQueue.main.async(execute: done)
      return
    }
    engine.queue.async { DispatchQueue.main.async(execute: done) }
  }

  // MARK: Work (each catalog's queue)

  private func setRunning(_ catalog: AppleCatalog, _ running: Bool) {
    guard let engine = engines[catalog] else { return }
    lock.lock()
    engine.running = running
    lock.unlock()
  }

  /// Queue `request`, or merge it into the one already queued.
  private func request(
    _ catalog: AppleCatalog, _ request: AppleCatalogRequest,
    _ completion: ((AppleCatalogOutcome) -> Void)? = nil
  ) {
    guard let engine = engines[catalog] else {
      if let completion { DispatchQueue.main.async { completion(.kept) } }
      return
    }
    lock.lock()
    if let completion { engine.waiters.append(completion) }
    if let pending = engine.pending {
      engine.pending = pending.merged(with: request)
      lock.unlock()
      return
    }
    engine.pending = request
    lock.unlock()
    engine.queue.async { [weak self] in self?.drain(engine) }
  }

  private func drain(_ engine: Engine) {
    lock.lock()
    guard let request = engine.pending else {
      lock.unlock()
      return
    }
    engine.pending = nil
    let waiters = engine.waiters
    engine.waiters = []
    let running = engine.running
    lock.unlock()
    let deliver: (AppleCatalogOutcome) -> Void = { outcome in
      guard !waiters.isEmpty else { return }
      DispatchQueue.main.async {
        for waiter in waiters { waiter(outcome) }
      }
    }
    let access = running ? engine.reader.access() : .undetermined
    lock.lock()
    if running { engine.knownAccess = access }
    lock.unlock()
    switch AppleCatalogStep.of(request, running: running, access: access) {
    case .keep:
      deliver(.kept)
    case .clear:
      deliver(clear(engine, outcome: running ? .denied : .cleared))
    case .list:
      deliver(list(engine))
    case .ask:
      ask(engine, deliver: deliver)
    }
  }

  /// macOS's prompt stays up until the user answers; the queue stays free
  /// meanwhile, and requests that need the answer wait for it.
  private func ask(_ engine: Engine, deliver: @escaping (AppleCatalogOutcome) -> Void) {
    lock.lock()
    if engine.askWaiters != nil {
      engine.askWaiters?.append(deliver)
      lock.unlock()
      return
    }
    engine.askWaiters = [deliver]
    lock.unlock()
    FlashLog.info("[apple] asking for \(engine.catalog.appName) access")
    engine.reader.requestAccess { [weak self] granted in
      engine.queue.async {
        guard let self else { return }
        self.lock.lock()
        let waiters = engine.askWaiters ?? []
        engine.askWaiters = nil
        engine.knownAccess = granted ? .granted : .denied
        self.lock.unlock()
        FlashLog.info(
          "[apple] \(engine.catalog.appName) access \(granted ? "granted" : "denied")")
        let outcome = granted ? self.list(engine) : self.clear(engine, outcome: .denied)
        for waiter in waiters { waiter(outcome) }
      }
    }
  }

  private func list(_ engine: Engine) -> AppleCatalogOutcome {
    lock.lock()
    let generation = engine.generation
    lock.unlock()
    let startedMs = nowMs()
    let listing = engine.reader.list()
    let elapsedMs = nowMs() - startedMs
    switch listing {
    case .denied:
      log(engine.catalog, outcome: "denied", rows: 0, elapsedMs: elapsedMs)
      return clear(engine, outcome: .denied)
    case .failed(let reason):
      FlashLog.warn("[apple] \(engine.catalog.rawValue) list failed: \(reason)")
      log(engine.catalog, outcome: "failed", rows: 0, elapsedMs: elapsedMs)
      return .failed(reason)
    case .rows(let rows):
      let candidates = CandidateFinder.prepare(
        AppleCatalogRows.candidates(rows, of: engine.catalog))
      lock.lock()
      // The app quit while it was listed: its termination already cleared it.
      let current = engine.generation == generation && engine.running
      if current { engine.rows = candidates }
      lock.unlock()
      guard current else { return .cleared }
      log(
        engine.catalog, outcome: candidates.isEmpty ? "empty" : "ok", rows: candidates.count,
        elapsedMs: elapsedMs)
      notify(engine.catalog)
      return .listed(candidates.count)
    }
  }

  private func clear(_ engine: Engine, outcome: AppleCatalogOutcome) -> AppleCatalogOutcome {
    lock.lock()
    let changed = !engine.rows.isEmpty
    engine.rows = []
    lock.unlock()
    if changed { notify(engine.catalog) }
    return outcome
  }

  private func notify(_ catalog: AppleCatalog) {
    DispatchQueue.main.async { [weak self] in self?.onChange(catalog) }
  }

  private func log(_ catalog: AppleCatalog, outcome: String, rows: Int, elapsedMs: Int) {
    let fields = [
      "catalog": catalog.rawValue, "outcome": outcome, "rows": String(rows),
      "elapsed_ms": String(elapsedMs),
    ]
    FlashLog.debug("[apple] refresh", fields: fields)
    if elapsedMs >= Self.slowRefreshMs {
      FlashLog.warn("[apple] refresh slow", fields: fields)
    }
  }
}

/// `@notes`, `@reminders` and `@contacts`: one catalog's
/// last good rows, served from memory only when a query names the source.
/// Naming it is what first asks macOS for access. Selecting a row brings it
/// forward in its app.
final class AppleCatalogSource: FlashSource {
  let catalog: AppleCatalog
  private let catalogs: AppleCatalogs

  init(catalog: AppleCatalog, catalogs: AppleCatalogs) {
    self.catalog = catalog
    self.catalogs = catalogs
  }

  var identifier: String { catalog.sourceID }
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: catalog.sourceLabel, type: catalog.rawValue)]
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    catalogs.queried(catalog)
    let rows = catalogs.rows(catalog)
    DispatchQueue.main.async { completion(rows) }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    guard let id = candidate.sourcePayload, !id.isEmpty else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }
    catalogs.show(catalog, id: id) { shown in
      completion(shown ? .resolved(pid: nil) : .unresolved)
    }
  }
}
