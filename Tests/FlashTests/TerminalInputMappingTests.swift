import AppKit
import XCTest

@testable import flash

final class TerminalInputMappingTests: XCTestCase {
  private typealias Matcher = TerminalInputMappingState<String, String>

  func testUnmappedInputIncludingEscapeCountsAndQuotesPassesImmediately() {
    var matcher = make(["gg"])
    for key in ["escape", "3", "\"", "j", "ctrl-c", "space"] {
      XCTAssertEqual(describe(matcher.receive(input(key))), ["replay:one:\(key)"])
      XCTAssertFalse(matcher.isPending)
    }
  }

  func testKnownPrefixBuffersUntilExactMatch() {
    var matcher = make(["gg"])
    XCTAssertTrue(matcher.receive(input("g")).isEmpty)
    XCTAssertTrue(matcher.isPending)
    XCTAssertEqual(describe(matcher.receive(input("g"))), ["dispatch:one:gg"])
    XCTAssertFalse(matcher.isPending)
  }

  func testMismatchReplaysOriginalEventsExactlyOnce() {
    var matcher = make(["abc"])
    XCTAssertTrue(matcher.receive(input("a")).isEmpty)
    XCTAssertTrue(matcher.receive(input("b")).isEmpty)
    XCTAssertEqual(
      describe(matcher.receive(input("x"))), ["replay:one:a", "replay:one:b", "replay:one:x"])
    XCTAssertTrue(matcher.flush().isEmpty)
  }

  func testMismatchReprocessesTailAsNewSequence() {
    var matcher = make(["abc", "bx"])
    _ = matcher.receive(input("a"))
    _ = matcher.receive(input("b"))
    XCTAssertEqual(describe(matcher.receive(input("x"))), ["replay:one:a", "dispatch:one:bx"])
  }

  func testAmbiguousExactWaitsAndTimeoutDispatches() {
    var matcher = make(["g", "gg"])
    XCTAssertTrue(matcher.receive(input("g")).isEmpty)
    XCTAssertEqual(describe(matcher.expire(generation: matcher.generation)), ["dispatch:one:g"])
    XCTAssertFalse(matcher.isPending)
  }

  func testLongestCompletedPrefixDispatchesBeforeReprocessingTail() {
    var matcher = make(["a", "ab", "abcd", "x"])
    _ = matcher.receive(input("a"))
    _ = matcher.receive(input("b"))
    _ = matcher.receive(input("c"))
    XCTAssertEqual(
      describe(matcher.receive(input("x"))),
      ["dispatch:one:ab", "replay:one:c", "dispatch:one:x"])
  }

  func testTimeoutDrainsUncompletedTail() {
    var matcher = make(["a", "abc", "bd"])
    _ = matcher.receive(input("a"))
    _ = matcher.receive(input("b"))
    XCTAssertEqual(
      describe(matcher.expire(generation: matcher.generation)),
      ["dispatch:one:a", "replay:one:b"])
    XCTAssertFalse(matcher.isPending)
  }

  func testStaleTimerCannotResolveNewInput() {
    var matcher = make(["gg", "xyz"])
    _ = matcher.receive(input("g"))
    let stale = matcher.generation
    _ = matcher.flush()
    _ = matcher.receive(input("x"))
    XCTAssertTrue(matcher.expire(generation: stale).isEmpty)
    XCTAssertTrue(matcher.isPending)
  }

  func testFocusChangeReplaysToOriginalTerminalBeforeNewInput() {
    var matcher = make(["gg"])
    _ = matcher.receive(input("g"))
    XCTAssertEqual(
      describe(matcher.receive(input("x", origin: "two"))),
      ["replay:one:g", "replay:two:x"])
  }

  func testReloadReplaysAmbiguousExactWithoutDispatch() {
    var matcher = make(["g", "gg"])
    _ = matcher.receive(input("g"))
    XCTAssertEqual(describe(matcher.replaceMappings(CompiledMappings())), ["replay:one:g"])
    XCTAssertEqual(describe(matcher.receive(input("g"))), ["replay:one:g"])
  }

  func testRepeatIsOnlyEnabledByExplicitMetadata() {
    let key = NormalModeInterpreter.canonicalizeMappingKey("[x")!
    let mapping = ModeMapping(key: key, action: .shellCommand(["[x"]), repeatsOnFinalKey: true)
    var matcher = Matcher(mappings: CompiledMappings([mapping]))
    _ = matcher.receive(input("["))
    XCTAssertEqual(describe(matcher.receive(input("x"))), ["dispatch:one:[x"])
    XCTAssertEqual(describe(matcher.receive(input("x"))), ["dispatch:one:[x"])
    XCTAssertEqual(describe(matcher.receive(input("y"))), ["replay:one:y"])
    XCTAssertEqual(describe(matcher.receive(input("x"))), ["replay:one:x"])
  }

  func testEventAtomAlternativesRemainValidAcrossSequence() {
    var matcher = make(["ctrl+ix"])
    _ = matcher.receive(.init(atoms: ["ctrl-i", "tab"], event: "original-tab", origin: "one"))
    XCTAssertEqual(describe(matcher.receive(input("x"))), ["dispatch:one:ctrl+ix"])
  }

  func testAliasMatchHonorsMappingPriorityRatherThanAtomSortOrder() {
    var matcher = make(["cmd+escape", "cmd+esc"])
    XCTAssertEqual(
      describe(
        matcher.receive(
          .init(
            atoms: ["cmd+esc", "cmd+escape"], event: "escape", origin: "one"))),
      ["dispatch:one:cmd+escape"])
  }

  func testBareEscapeIsNotAnImplicitMapping() {
    let mappings = CompiledMappings()
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    XCTAssertEqual(
      TerminalInputMappingHandler<String>.atoms(for: event, mappings: mappings), ["escape"])
  }

  func testForwardDeleteMappingUsesItsPhysicalNamedAtom() {
    let mapping = ModeMapping(
      key: NormalModeInterpreter.canonicalizeMappingKey("<delete_forward>")!,
      action: .shellCommand(["delete"]))
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "\u{f728}",
      charactersIgnoringModifiers: "\u{f728}", isARepeat: false, keyCode: 117)!
    XCTAssertTrue(
      TerminalInputMappingHandler<String>.atoms(for: event, mappings: CompiledMappings([mapping]))
        .contains(mapping.key))
  }

  func testReleasesWaitForPrefixAndReplayInOriginalOrderOnMismatch() {
    var matcher = make(["gg"])
    XCTAssertTrue(matcher.receive(press("g", code: 5)).isEmpty)
    XCTAssertTrue(matcher.receive(release("g", code: 5)).isEmpty)
    XCTAssertEqual(
      describe(matcher.receive(press("x", code: 7))),
      ["replay:one:g-down", "replay:one:g-up", "replay:one:x-down"])
    XCTAssertEqual(describe(matcher.receive(release("x", code: 7))), ["replay:one:x-up"])
  }

  func testMatchedSequenceConsumesItsBufferedAndSubsequentReleases() {
    var matcher = make(["ab"])
    _ = matcher.receive(press("a", code: 0))
    XCTAssertTrue(matcher.receive(release("a", code: 0)).isEmpty)
    XCTAssertEqual(describe(matcher.receive(press("b", code: 11))), ["dispatch:one:ab"])
    XCTAssertTrue(matcher.receive(release("b", code: 11)).isEmpty)
    XCTAssertEqual(describe(matcher.receive(press("b", code: 11))), ["replay:one:b-down"])
    XCTAssertEqual(describe(matcher.receive(release("b", code: 11))), ["replay:one:b-up"])
  }

  func testReleaseDoesNotAdvanceMappingOrExtendItsTimeout() {
    var matcher = make(["g", "gg"])
    _ = matcher.receive(press("g", code: 5))
    let generation = matcher.generation
    XCTAssertTrue(matcher.receive(release("g", code: 5)).isEmpty)
    XCTAssertEqual(matcher.generation, generation)
    XCTAssertEqual(describe(matcher.expire(generation: generation)), ["dispatch:one:g"])
  }

  func testFlushReplaysReleasesAndRoutesLaterReleaseToOriginalView() {
    var matcher = make(["gg"])
    _ = matcher.receive(press("g", code: 5))
    _ = matcher.receive(release("g", code: 5))
    XCTAssertEqual(describe(matcher.flush()), ["replay:one:g-down", "replay:one:g-up"])
    _ = matcher.receive(press("g", code: 5))
    XCTAssertEqual(describe(matcher.flush()), ["replay:one:g-down"])
    XCTAssertEqual(
      describe(matcher.receive(release("g", code: 5, origin: "two"))), ["replay:one:g-up"])
  }

  func testConsumedMappingReleaseStaysConsumedAfterRebindAndReload() {
    var matcher = make(["g"])
    XCTAssertEqual(describe(matcher.receive(press("g", code: 5))), ["dispatch:one:g"])
    XCTAssertTrue(matcher.replaceMappings(CompiledMappings()).isEmpty)
    XCTAssertTrue(matcher.receive(release("g", code: 5, origin: "two")).isEmpty)
  }

  func testFreshPressReplacesOwnershipWhenPreviousReleaseWentToAnotherApp() {
    var matcher = make(["g"])
    _ = matcher.receive(press("g", code: 5))
    _ = matcher.replaceMappings(CompiledMappings())
    XCTAssertEqual(
      describe(matcher.receive(press("g", code: 5, origin: "two"))), ["replay:two:g-down"])
    XCTAssertEqual(
      describe(matcher.receive(release("g", code: 5, origin: "two"))), ["replay:two:g-up"])
  }

  func testModifierEventsStayOrderedWithoutAdvancingSequence() {
    var matcher = make(["ab"])
    _ = matcher.receive(press("a", code: 0))
    let generation = matcher.generation
    XCTAssertTrue(
      matcher.receive(
        .init(
          atoms: [], event: "shift-down", origin: "one",
          keyCode: 56, advancesMapping: false)
      ).isEmpty)
    XCTAssertEqual(matcher.generation, generation)
    XCTAssertTrue(
      matcher.receive(
        .init(
          atoms: [], event: "shift-up", origin: "one",
          keyCode: 56, isRelease: true, advancesMapping: false)
      ).isEmpty)
    XCTAssertEqual(
      describe(matcher.flush()),
      ["replay:one:a-down", "replay:one:shift-down", "replay:one:shift-up"])
  }

  private func press(_ atom: String, code: UInt16, origin: String = "one") -> Matcher.Input {
    .init(atoms: [atom], event: atom + "-down", origin: origin, keyCode: code)
  }

  private func release(_ atom: String, code: UInt16, origin: String = "one") -> Matcher.Input {
    .init(atoms: [], event: atom + "-up", origin: origin, keyCode: code, isRelease: true)
  }

  private func make(_ keys: [String]) -> Matcher {
    Matcher(
      mappings: CompiledMappings(
        keys.map {
          ModeMapping(
            key: NormalModeInterpreter.canonicalizeMappingKey($0)!, action: .shellCommand([$0]))
        }))
  }

  private func input(_ atom: String, origin: String = "one") -> Matcher.Input {
    .init(atoms: [atom], event: atom, origin: origin)
  }

  private func describe(_ effects: [Matcher.Effect]) -> [String] {
    effects.map {
      switch $0 {
      case .replay(let event, let origin): return "replay:\(origin):\(event)"
      case .dispatch(let mapping, let origin):
        guard case .shellCommand(let argv) = mapping.action else { return "unexpected" }
        return "dispatch:\(origin):\(argv[0])"
      }
    }
  }
}
