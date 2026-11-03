import CoreServices
import Foundation

/// In-process Spotlight file-name search behind `@files` and `!f`.
///
/// Queries run one at a time on a dedicated thread, never on main or the
/// keyboard path: an asynchronous `MDQuery` delivers its results through the
/// run loop of the thread that executed it, so that thread runs its loop
/// until the query ends. Every request starts a new generation and supersedes
/// the older ones, which complete at once with no paths. A query ends when
/// Spotlight finishes gathering, when `limit` results arrived, or at its
/// deadline with whatever it gathered so far: a slow index yields fewer rows,
/// never an error. Results keep Spotlight's server order, the order `mdfind`
/// prints.
final class SpotlightNameSearch: @unchecked Sendable {
  enum Outcome: String, Sendable {
    case finished
    case limited
    case deadline
    case superseded
    case failed
  }

  struct Result: Sendable {
    let paths: [String]
    let outcome: Outcome
  }

  /// The Spotlight query `mdfind -name <text>` runs for a literal name:
  /// `mdfind` builds it with a private helper over `kMDItemDisplayName`, so
  /// this rebuilds the same string. The text is canonically decomposed, its
  /// words (split on Unicode white space and U+200B) are joined by one space,
  /// and `"`, `'`, `*` and `\` are escaped so the whole phrase is literal:
  /// only the trailing `*` is a wildcard. `cdw` ignores case and diacritics
  /// and matches at word starts; `t` tokenizes a multi-word phrase; `s` turns
  /// on the segmenter for CJK and Hangul text. `mdfind`'s own query syntax
  /// (`-word`, parentheses, `AND`, `kind:`) stays literal here. Returns nil
  /// for blank input, which runs no query.
  static func query(forName text: String) -> String? {
    var words: [String.UnicodeScalarView] = []
    var word = String.UnicodeScalarView()
    for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
      if scalar.properties.isWhitespace || scalar.value == 0x200B {
        if !word.isEmpty { words.append(word) }
        word = String.UnicodeScalarView()
      } else {
        word.append(scalar)
      }
    }
    if !word.isEmpty { words.append(word) }
    guard !words.isEmpty else { return nil }
    let phrase = words.map(String.init).joined(separator: " ")
    var escaped = String.UnicodeScalarView()
    for scalar in phrase.unicodeScalars {
      if scalar == "\"" || scalar == "'" || scalar == "*" || scalar == "\\" {
        escaped.append("\\")
      }
      escaped.append(scalar)
    }
    var modifiers = "cdw"
    if words.count > 1 { modifiers += "t" }
    if needsSegmenter(phrase) { modifiers += "s" }
    return "(kMDItemDisplayName = \"\(String(escaped))*\"\(modifiers))"
  }

  /// Ideographic, kana, Hangul and full-width text has no spaces between
  /// words, so Spotlight segments it (`s`) once the phrase has two units.
  private static func needsSegmenter(_ phrase: String) -> Bool {
    let units = phrase.utf16
    guard units.count >= 2 else { return false }
    return units.contains { unit in
      (0x1100...0x11FF).contains(unit) || (0x2E80...0xF8FF).contains(unit)
        || (0xFF60...0xFFAF).contains(unit)
    }
  }

  private let mailbox = Mailbox()

  deinit {
    mailbox.close()
  }

  /// Run one Spotlight query (`query(forName:)` builds it). The request
  /// supersedes every earlier one. `completion` runs exactly once, on the
  /// search thread.
  func search(
    query: String,
    limit: Int,
    deadline: DispatchTimeInterval,
    completion: @escaping @Sendable (Result) -> Void
  ) {
    mailbox.submit(
      Request(
        query: query, limit: limit, deadline: .now() + deadline, completion: completion))
  }

  fileprivate struct Request {
    let query: String
    let limit: Int
    let deadline: DispatchTime
    let completion: @Sendable (Result) -> Void
    var generation: UInt64 = 0
  }

  /// The requests waiting for the search thread and the generation that is
  /// still wanted. The thread holds this mailbox, not the search, so the
  /// search's `deinit` closes it and the thread exits.
  private final class Mailbox: @unchecked Sendable {
    private let condition = NSCondition()
    /// Guarded by `condition`.
    private var pending: [Request] = []
    private var generation: UInt64 = 0
    private var closed = false
    private var started = false
    /// The search thread's run loop and the source that interrupts it.
    private var wake: (loop: CFRunLoop, source: CFRunLoopSource)?

    func submit(_ request: Request) {
      var request = request
      condition.lock()
      guard !closed else {
        condition.unlock()
        request.completion(Result(paths: [], outcome: .superseded))
        return
      }
      generation &+= 1
      request.generation = generation
      pending.append(request)
      if !started {
        started = true
        let thread = Thread { [self] in serve() }
        thread.name = "flash.files.spotlight"
        thread.qualityOfService = .userInitiated
        thread.start()
      }
      let wake = self.wake
      condition.signal()
      condition.unlock()
      interrupt(wake)
    }

    func close() {
      condition.lock()
      closed = true
      let wake = self.wake
      condition.signal()
      condition.unlock()
      interrupt(wake)
    }

    /// Whether `generation` is still the one wanted.
    private func isCurrent(_ generation: UInt64) -> Bool {
      condition.lock()
      defer { condition.unlock() }
      return !closed && generation == self.generation
    }

    /// Wake the query in flight so it notices a newer generation.
    private func interrupt(_ wake: (loop: CFRunLoop, source: CFRunLoopSource)?) {
      guard let wake else { return }
      CFRunLoopSourceSignal(wake.source)
      CFRunLoopWakeUp(wake.loop)
    }

    /// The search thread: take what arrived, answer the superseded requests,
    /// run the current one, and wait for the next. The interrupt source also
    /// keeps the run loop from returning at once for want of a source.
    private func serve() {
      let loop = CFRunLoopGetCurrent()!
      var context = CFRunLoopSourceContext()
      context.perform = { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
      let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
      CFRunLoopAddSource(loop, source, .defaultMode)
      condition.lock()
      wake = (loop, source)
      condition.unlock()
      while let batch = next() {
        for request in batch {
          if isCurrent(request.generation) {
            run(request)
          } else {
            request.completion(Result(paths: [], outcome: .superseded))
          }
        }
      }
      CFRunLoopRemoveSource(loop, source, .defaultMode)
    }

    /// Block until requests arrive. Nil once closed, after superseding what
    /// was still waiting.
    private func next() -> [Request]? {
      condition.lock()
      while pending.isEmpty && !closed { condition.wait() }
      let batch = pending
      pending = []
      let open = !closed
      condition.unlock()
      guard open else {
        for request in batch { request.completion(Result(paths: [], outcome: .superseded)) }
        return nil
      }
      return batch
    }

    private func run(_ request: Request) {
      guard request.limit > 0,
        let query = MDQueryCreate(kCFAllocatorDefault, request.query as CFString, nil, nil)
      else {
        request.completion(Result(paths: [], outcome: .failed))
        return
      }
      // Report every `limit` results or every 50 ms: the defaults hold the
      // first rows back for no benefit here.
      var batching = MDQueryGetBatchingParameters(query)
      batching.first_max_num = request.limit
      batching.first_max_ms = 50
      batching.progress_max_num = request.limit
      batching.progress_max_ms = 50
      MDQuerySetBatchingParameters(query, batching)

      let progress = QueryProgress()
      let center = CFNotificationCenterGetLocalCenter()
      let observer = UnsafeRawPointer(Unmanaged.passUnretained(progress).toOpaque())
      let object = UnsafeRawPointer(Unmanaged.passUnretained(query).toOpaque())
      for name in [kMDQueryProgressNotification, kMDQueryDidFinishNotification] {
        CFNotificationCenterAddObserver(
          center, observer, QueryProgress.notified, name, object, .deliverImmediately)
      }
      // A static asynchronous query: no live updates. Never
      // `MDQuerySetMaxCount`, which answers with a wrong subset; the cap is
      // enforced by stopping once `limit` results arrived.
      var outcome = Outcome.failed
      if MDQueryExecute(query, 0) {
        while true {
          if progress.finished {
            outcome = .finished
            break
          }
          if MDQueryGetResultCount(query) >= request.limit {
            outcome = .limited
            break
          }
          if !isCurrent(request.generation) {
            outcome = .superseded
            break
          }
          let now = DispatchTime.now().uptimeNanoseconds
          let end = request.deadline.uptimeNanoseconds
          guard end > now else {
            outcome = .deadline
            break
          }
          _ = CFRunLoopRunInMode(.defaultMode, Double(end - now) / 1e9, false)
        }
      }
      CFNotificationCenterRemoveEveryObserver(center, observer)
      // Stopping folds in results received but not yet batched.
      MDQueryStop(query)
      let paths: [String]
      switch outcome {
      case .finished, .limited, .deadline: paths = Self.paths(of: query, limit: request.limit)
      case .superseded, .failed: paths = []
      }
      request.completion(Result(paths: paths, outcome: outcome))
    }

    private static func paths(of query: MDQuery, limit: Int) -> [String] {
      let count = min(MDQueryGetResultCount(query), limit)
      var paths: [String] = []
      paths.reserveCapacity(count)
      for index in 0..<count {
        guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
        let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
        if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
          paths.append(path)
        }
      }
      return paths
    }
  }

  /// One query's notifications, delivered on the search thread while it runs
  /// its loop. Each stops the loop so the thread re-checks the end
  /// conditions.
  private final class QueryProgress {
    var finished = false

    static let notified: CFNotificationCallback = { _, observer, name, _, _ in
      guard let observer else { return }
      let progress = Unmanaged<QueryProgress>.fromOpaque(observer).takeUnretainedValue()
      if let name, CFEqual(name.rawValue, kMDQueryDidFinishNotification) {
        progress.finished = true
      }
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
  }
}
