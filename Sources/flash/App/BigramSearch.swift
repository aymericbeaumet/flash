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
  }

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var corpus: BigramTextCollector.Corpus?
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
      self.query = ""
      self.resolvedQuery = nil
      self.deliver = nil
    }
    return generation
  }

  func start(context: AppContext, screenH: CGFloat, deliver: @escaping (Result) -> Void) {
    let generation = currentGeneration
    queue.async { [weak self] in
      guard let self, self.currentGeneration == generation else { return }
      self.deliver = deliver
      let corpus = BigramTextCollector.collect(in: context, screenH: screenH)
      guard self.currentGeneration == generation else { return }
      self.corpus = corpus
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
    let result = Result(
      generation: generation, query: query, targets: corpus.targets(matching: query),
      runCount: corpus.runCount, bundleIdentifier: corpus.bundleIdentifier)
    let deliver = deliver
    DispatchQueue.main.async { deliver?(result) }
  }
}
