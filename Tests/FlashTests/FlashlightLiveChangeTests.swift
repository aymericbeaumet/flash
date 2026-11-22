import AppKit
import FlashCore
import XCTest

@testable import flash

/// A plugin's `changed` notification against the flashlight: the rows of a
/// live source are pulled again only while a query shows them, a burst is
/// bounded, and the query and the selection stay as they are.
final class FlashlightLiveChangeTests: XCTestCase {
  // MARK: - The bound

  private let notes = LiveSourceChange(sourceID: "plugin:notes", source: "notes.notes")
  private let contacts = LiveSourceChange(sourceID: "plugin:contacts", source: "contacts.cards")

  func testTheFirstChangePullsAtOnceAndABurstOnceMoreAtTheEndOfItsInterval() {
    var gate = LiveSourceChangeGate(minIntervalMs: 500)
    XCTAssertEqual(gate.admit(notes, nowMs: 10_000), .pull)
    XCTAssertEqual(gate.admit(notes, nowMs: 10_100), .wait(ms: 400))
    for nowMs in stride(from: 10_101, to: 10_500, by: 7) {
      XCTAssertEqual(gate.admit(notes, nowMs: nowMs), .coalesced, "\(nowMs)")
    }
    XCTAssertEqual(gate.admit(contacts, nowMs: 10_499), .coalesced)
    XCTAssertEqual(gate.takeWaiting(), [notes, contacts])
    gate.pulled(nowMs: 10_500)
    XCTAssertEqual(gate.waiting, [])
    XCTAssertEqual(gate.admit(notes, nowMs: 10_700), .wait(ms: 300), "counted from that pull")
    XCTAssertEqual(gate.takeWaiting(), [notes])
    XCTAssertEqual(gate.admit(notes, nowMs: 11_000), .pull, "a quiet interval later")
  }

  /// A plugin that announces a change with every reply costs two searches a
  /// second, however fast it answers.
  func testAPluginThatAlwaysSaysChangedIsPulledTwiceASecond() {
    var gate = LiveSourceChangeGate(minIntervalMs: PluginProtocol.changedMinIntervalMs)
    var pulls = 0
    var deadline: Int?
    for nowMs in 0..<10_000 {
      if nowMs == deadline {
        deadline = nil
        XCTAssertFalse(gate.takeWaiting().isEmpty)
        gate.pulled(nowMs: nowMs)
        pulls += 1
      }
      switch gate.admit(notes, nowMs: nowMs) {
      case .pull: pulls += 1
      case .wait(let ms): deadline = nowMs + ms
      case .coalesced: break
      }
    }
    XCTAssertEqual(pulls, 20, "ten seconds of a change every millisecond")
  }

  func testAClosedSessionDropsWhatWaitedAndKeepsTheBound() {
    var gate = LiveSourceChangeGate(minIntervalMs: 500)
    XCTAssertEqual(gate.admit(notes, nowMs: 0), .pull)
    XCTAssertEqual(gate.admit(notes, nowMs: 100), .wait(ms: 400))
    gate.cancelWaiting()
    XCTAssertEqual(gate.waiting, [])
    XCTAssertEqual(gate.admit(notes, nowMs: 200), .wait(ms: 300), "the next session waits too")
  }

  func testAChangeIsShownOnlyByAQueryScopedToItsSource() {
    typealias Query = CandidateLiveQuery<Candidate>.Query
    let descriptors = [
      CandidateSourceDescriptor(name: "notes.notes", type: "notes", live: .perScope),
      CandidateSourceDescriptor(name: "notes.folders", type: "folders", live: .perScope),
    ]
    func shown(_ change: LiveSourceChange, _ query: Query?) -> Bool {
      change.isShown(by: query, descriptors: descriptors)
    }
    let byType = Query(
      filter: SourceScope.type("notes").signature, text: "",
      sourceIDs: [
        "plugin:notes"
      ])
    XCTAssertTrue(shown(notes, byType))
    XCTAssertTrue(
      shown(
        notes,
        Query(
          filter: SourceScope.source("Notes.Notes").signature, text: "",
          sourceIDs: ["plugin:notes"])), "a bang bound to the source")
    XCTAssertFalse(shown(notes, nil), "no scoped query")
    XCTAssertFalse(
      shown(LiveSourceChange(sourceID: "plugin:notes", source: "notes.folders"), byType),
      "the plugin's other source is pulled with it and filtered out")
    XCTAssertFalse(
      shown(LiveSourceChange(sourceID: "plugin:notes", source: "notes.gone"), byType),
      "not a source it declares")
    XCTAssertFalse(shown(contacts, byType), "another plugin")
    XCTAssertFalse(
      shown(
        notes,
        Query(
          filter: SourceScope.type("notes").signature, text: "", sourceIDs: ["plugin:other"])),
      "the query does not pull this plugin")
  }

  // MARK: - The flashlight

  /// One plugin's live `per_scope` source of type `notes`, answering from
  /// `titles` and counting its pulls.
  private final class LiveNotes: FlashSource {
    let identifier = "plugin:notes"
    let priority = 0
    let capabilities: FlashSourceCapabilities = [.candidates]
    let candidateSourceDescriptors = [
      CandidateSourceDescriptor(name: "notes.notes", type: "notes", live: .perScope)
    ]
    let servesLiveCandidates = true
    let liveCandidatesDependOnText = false
    var titles: [String] = []
    private(set) var pulls = 0

    func supports(_ context: AppContext) -> Bool { false }
    func discover(in context: AppContext) throws -> [JumpTarget] { [] }
    func liveCandidates(
      matching text: String, in environment: FlashSourceEnvironment, scope: CandidateScope,
      completion: @escaping ([Candidate]) -> Void
    ) {
      pulls += 1
      let rows = titles.map { title in
        Candidate(
          title: title,
          metadata: [
            CandidateMetadataKey.source: "notes.notes",
            CandidateMetadataKey.sourceID: identifier, CandidateMetadataKey.kind: "note",
          ])
      }
      // Runs on main alone: the hop is what confines it.
      nonisolated(unsafe) let completion = completion
      DispatchQueue.main.async { completion(rows) }
    }
  }

  private func flashlight(_ source: LiveNotes) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { [source] })
    // The command line is open and its catalogs already landed: typing
    // evaluates at once.
    delegate.overlay.inputMode = .commandLine
    delegate.finder.publishInitialSnapshot()
    return delegate
  }

  private func titles(_ delegate: AppDelegate) -> [String] {
    delegate.finder.matches.map(\.candidate.title)
  }

  /// The three cases a listing can land in: after the query answered empty,
  /// after the user answered a prompt, and while rows are on screen. Each
  /// redraws without the scope being typed again.
  func testAChangeRedrawsTheRowsOfTheScopeOnScreen() {
    let source = LiveNotes()
    let delegate = flashlight(source)
    defer { delegate.overlay.orderOut(nil) }

    delegate.refreshCommandLine(text: "flashlight @notes ")
    waitUntilTrue("the scope pulled its source") { source.pulls == 1 }
    settleRunLoop(0.1)
    XCTAssertEqual(titles(delegate), [], "the listing has not landed")

    source.titles = ["Groceries", "Taxes", "Travel"]
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    XCTAssertEqual(source.pulls, 2, "pulled again at once")
    waitUntilTrue("the rows appear") { self.titles(delegate).count == 3 }
    XCTAssertEqual(delegate.overlay.commandLineText, ":flashlight @notes ")

    // A relist that lands while rows are on screen replaces them where the
    // user is: the query and the selected position stay.
    delegate.finder.selectedIndex = 1
    source.titles = ["Groceries", "Taxes", "Travel", "Zebra"]
    settleRunLoop(Double(PluginProtocol.changedMinIntervalMs) / 1000 + 0.1)
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    XCTAssertEqual(source.pulls, 3)
    XCTAssertEqual(titles(delegate).count, 3, "the rows on screen stay until the new ones land")
    waitUntilTrue("the new rows replace them") { self.titles(delegate).count == 4 }
    XCTAssertEqual(delegate.finder.selectedIndex, 1)
    XCTAssertEqual(delegate.overlay.commandLineText, ":flashlight @notes ")
    XCTAssertEqual(source.pulls, 3, "one pull per change")
  }

  func testAChangeNobodyLooksAtPullsNothing() {
    let source = LiveNotes()
    source.titles = ["Groceries"]
    let delegate = flashlight(source)
    defer { delegate.overlay.orderOut(nil) }

    // No flashlight, then a flashlight on the default pool.
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    delegate.refreshCommandLine(text: "flashlight gro")
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    XCTAssertEqual(source.pulls, 0)

    delegate.refreshCommandLine(text: "flashlight @notes ")
    waitUntilTrue("the scope pulled its source") { source.pulls == 1 }
    // Another plugin's word for this source, and this plugin's for a source
    // it does not declare.
    delegate.pluginLiveSourceChanged(pluginID: "contacts", source: "notes.notes")
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.folders")
    XCTAssertEqual(source.pulls, 1)

    // Scoped elsewhere, then closed.
    delegate.refreshCommandLine(text: "flashlight @apps ")
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    delegate.refreshCommandLine(text: "flashlight @notes ")
    waitUntilTrue("back on the scope") { source.pulls == 2 }
    delegate.cancelCandidateFinderSessionWork()
    delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes")
    settleRunLoop(0.1)
    XCTAssertEqual(source.pulls, 2)
    XCTAssertFalse(delegate.liveSourceChangeDeadline.isArmed, "nothing is kept for later")
  }

  /// A burst pulls once at once and once more when its interval ends; a
  /// session that closed meanwhile is owed nothing.
  func testABurstOfChangesIsTwoPulls() {
    let source = LiveNotes()
    source.titles = ["Groceries"]
    let delegate = flashlight(source)
    defer { delegate.overlay.orderOut(nil) }
    delegate.refreshCommandLine(text: "flashlight @notes ")
    waitUntilTrue("the scope pulled its source") { source.pulls == 1 }

    for _ in 0..<50 { delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes") }
    XCTAssertEqual(source.pulls, 2, "the first is honoured at once")
    XCTAssertTrue(delegate.liveSourceChangeDeadline.isArmed)
    waitUntilTrue("the burst ends with one more pull") { source.pulls == 3 }
    settleRunLoop(0.2)
    XCTAssertEqual(source.pulls, 3)
    XCTAssertFalse(delegate.liveSourceChangeDeadline.isArmed)

    for _ in 0..<5 { delegate.pluginLiveSourceChanged(pluginID: "notes", source: "notes.notes") }
    XCTAssertTrue(delegate.liveSourceChangeDeadline.isArmed, "inside the interval: it waits")
    let pulls = source.pulls
    delegate.cancelCandidateFinderSessionWork()
    XCTAssertFalse(delegate.liveSourceChangeDeadline.isArmed, "the close cancels it")
    settleRunLoop(Double(PluginProtocol.changedMinIntervalMs) / 1000 + 0.2)
    XCTAssertEqual(source.pulls, pulls)
  }
}
