import Foundation

@testable import flash

/// One app's items for the tests: the items a test gave it and the access
/// it says macOS grants. It records every call and on which thread, asks
/// macOS nothing, runs no script and reads no note, reminder or contact of
/// the Mac's.
final class AppItemStub: AppItemProviding {
  private let lock = NSLock()
  private var currentAccess: AppleCatalogAccess
  private let grants: Bool
  private var nextListing: HostAppItemListing
  private var running = true
  private var askCount = 0
  private var listCount = 0
  private var shownIDs: [String] = []
  private var mainCalls = false
  private var pendingAnswers: [(Bool) -> Void] = []
  private let holdsAnswer: Bool
  private var listingGate: DispatchSemaphore?
  private var showFailure: String?

  /// `grants`: what the user answers the prompt. `holdsAnswer`: the prompt
  /// stays open until `answer()`.
  init(
    access: AppleCatalogAccess, grants: Bool = true, items: [HostAppItem] = [],
    holdsAnswer: Bool = false
  ) {
    currentAccess = access
    self.grants = grants
    nextListing = .items(items)
    self.holdsAnswer = holdsAnswer
  }

  /// The items the conformance corpus describes, per app.
  static func corpus(_ kind: HostAppItemKind) -> AppItemStub {
    switch kind {
    case .notes:
      return AppItemStub(
        access: .granted,
        items: [
          HostAppItem(id: "x-coredata://4F1C/ICNote/p12", title: "Groceries"),
          HostAppItem(id: "x-coredata://4F1C/ICNote/p27", title: "Taxes 2026"),
        ])
    case .reminders:
      return AppItemStub(
        access: .granted,
        items: [
          HostAppItem(
            id: "5F8A-R1", title: "Buy milk", list: "Inbox", listIndex: 0,
            created: Date(timeIntervalSince1970: 1_800_000_000)),
          HostAppItem(id: "5F8A-R2", title: "Ship release", list: "Work", listIndex: 1),
        ])
    case .contacts:
      return AppItemStub(
        access: .granted,
        items: [
          HostAppItem(id: "5F8A-C1:ABPerson", title: "Ada Lovelace"),
          HostAppItem(id: "5F8A-C2:ABPerson", title: "Grace Hopper"),
        ])
    }
  }

  /// A host serving `stub` for `kind`.
  static func host(_ kind: HostAppItemKind, _ stub: AppItemStub) -> HostAppItems {
    HostAppItems(kind: kind, provider: stub)
  }

  var asks: Int { locked { askCount } }
  var lists: Int { locked { listCount } }
  var shown: [String] { locked { shownIDs } }
  var calledOnMain: Bool { locked { mainCalls } }
  var listing: HostAppItemListing {
    get { locked { nextListing } }
    set { locked { nextListing = newValue } }
  }
  /// What macOS answers without asking.
  var granted: AppleCatalogAccess {
    get { locked { currentAccess } }
    set { locked { currentAccess = newValue } }
  }
  /// Whether the app runs: a stopped one cannot be asked about.
  var isRunning: Bool {
    get { locked { running } }
    set { locked { running = newValue } }
  }
  /// Holds a listing in flight until signalled.
  var gate: DispatchSemaphore? {
    get { locked { listingGate } }
    set { locked { listingGate = newValue } }
  }
  /// Why a `show` fails; nil shows.
  var failure: String? {
    get { locked { showFailure } }
    set { locked { showFailure = newValue } }
  }

  func access() -> AppleCatalogAccess {
    locked {
      mainCalls = mainCalls || Thread.isMainThread
      return currentAccess
    }
  }

  func canRequestAccess() -> Bool { locked { running } }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    let answerNow = locked { () -> Bool in
      askCount += 1
      if holdsAnswer { pendingAnswers.append(done) }
      return !holdsAnswer
    }
    if answerNow { settle([done]) }
  }

  /// The user answers the open prompt.
  func answer() {
    settle(
      locked {
        defer { pendingAnswers = [] }
        return pendingAnswers
      })
  }

  private func settle(_ waiting: [(Bool) -> Void]) {
    let granted = locked { () -> Bool in
      currentAccess = grants ? .granted : .denied
      return grants
    }
    for done in waiting { DispatchQueue.global().async { done(granted) } }
  }

  func list() -> HostAppItemListing {
    let (listing, gate) = locked {
      listCount += 1
      mainCalls = mainCalls || Thread.isMainThread
      return (nextListing, listingGate)
    }
    gate?.wait()
    return listing
  }

  func show(id: String, done: @escaping (String?) -> Void) {
    let failure = locked { () -> String? in
      mainCalls = mainCalls || Thread.isMainThread
      if showFailure == nil { shownIDs.append(id) }
      return showFailure
    }
    DispatchQueue.global().async { done(failure) }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
