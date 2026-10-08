import FlashCore
import FlashProviders
import Foundation

/// Owns one bigram walk. The corpus stays on `axQueue`; main only sees a
/// generation and, once the query is one character, the matches.
///
/// `invalidate` bumps the generation and queues the wipe. It does not wait on
/// the queue: the keyboard loop must not block behind the walk. `start` is
/// queued after that wipe, so a replaced session cannot present the previous
/// window's text.
final class BigramSearch {
  struct Result {
    let generation: UInt64
    let query: String
    let targets: [JumpTarget]
    let runCount: Int
    let bundleIdentifier: String
    /// The focused window when the walk started. The status bar on its screen
    /// joins the matches, the same screen `f` uses.
    let windowFrame: CGRect
  }

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var corpus: BigramTextCollector.Corpus?
  private var focusedPID: pid_t = 0
  private var windowFrame: CGRect = .null
  private var tmuxGrid: TmuxBigramGrid.Grid?
  private var query = ""
  private var resolvedQuery: String?
  private var deliver: ((Result) -> Void)?

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  var currentGeneration: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  @discardableResult
  func invalidate() -> UInt64 {
    lock.lock()
    generation &+= 1
    let generation = generation
    lock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      self.corpus = nil
      self.windowFrame = .null
      self.tmuxGrid = nil
      self.query = ""
      self.resolvedQuery = nil
      self.deliver = nil
    }
    return generation
  }

  /// `discovered` is the frame `f` measures. An empty discovery keeps the
  /// activation-time window.
  static func hintWindow(_ discovered: CGRect, fallback: CGRect) -> CGRect {
    if discovered.isNull || discovered.isEmpty || discovered.isInfinite { return fallback }
    return discovered
  }

  func start(
    context: AppContext, screenH: CGFloat,
    discoverFrame: @escaping (AppContext) -> CGRect,
    deliver: @escaping (Result) -> Void
  ) {
    let generation = currentGeneration
    queue.async { [weak self] in
      guard let self, self.currentGeneration == generation else { return }
      self.deliver = deliver
      let corpus = BigramTextCollector.collect(in: context, screenH: screenH)
      guard self.currentGeneration == generation else { return }
      self.corpus = corpus
      self.focusedPID = context.processID
      let window = Self.hintWindow(discoverFrame(context), fallback: context.frontWindowFrame)
      self.windowFrame = window
      // A terminal such as Alacritty draws its own glyphs and publishes no
      // text to Accessibility. The tmux client attached to that window does,
      // on the same window rectangle `f` uses.
      self.tmuxGrid =
        corpus.runCount == 0
        ? TmuxBigramGrid.capture(
          pid: context.processID, bundleIdentifier: context.bundleIdentifier,
          window: window)
        : nil
      self.resolveIfReady(generation: generation)
    }
  }

  func setQuery(_ query: String) {
    let generation = currentGeneration
    queue.async { [weak self] in
      guard let self, self.currentGeneration == generation else { return }
      self.query = query
      if query.isEmpty { self.resolvedQuery = nil }
      self.resolveIfReady(generation: generation)
    }
  }

  private func resolveIfReady(generation: UInt64) {
    guard query.count == 1, let corpus, resolvedQuery != query else { return }
    resolvedQuery = query
    let targets: [JumpTarget]
    let runCount: Int
    if corpus.runCount > 0 {
      targets = corpus.targets(matching: query)
      runCount = corpus.runCount
    } else if let tmuxGrid {
      targets = tmuxGrid.targets(
        matching: query, pid: focusedPID, bundleIdentifier: corpus.bundleIdentifier)
      runCount =
        tmuxGrid.panes.reduce(0) { $0 + $1.lines.count } + tmuxGrid.chrome.count
    } else {
      targets = []
      runCount = 0
    }
    let result = Result(
      generation: generation, query: query, targets: targets,
      runCount: runCount, bundleIdentifier: corpus.bundleIdentifier,
      windowFrame: windowFrame)
    let deliver = deliver
    DispatchQueue.main.async { deliver?(result) }
  }
}
