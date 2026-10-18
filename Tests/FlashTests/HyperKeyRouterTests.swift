import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

/// Keys typed while the leader is held. Hyper mappings win. A key that extends
/// a NORMAL `<leader>` sequence still runs it. Anything else is swallowed,
/// including a key that would be an ordinary NORMAL command.
final class HyperKeyRouterTests: XCTestCase {
  private let leader = "space"
  private let volumeDown = URLCommand.pluginCommand(
    command: "media", subcommand: "volumedown", args: [])
  private let volumeUp = URLCommand.pluginCommand(
    command: "media", subcommand: "volumeup", args: [])

  func testMinusAndPlusStepVolume() {
    let down = route(keyCode: kVK_ANSI_Minus, characters: "-")
    XCTAssertEqual(down.transition.command, volumeDown)
    XCTAssertEqual(down.hyperPending, "")
    XCTAssertNil(down.leaderFallbackPending)

    let again = route(keyCode: kVK_ANSI_Minus, characters: "-")
    XCTAssertEqual(again.transition.command, volumeDown)

    let up = route(
      keyCode: kVK_ANSI_Equal, characters: "+", ignoring: "=", flags: .shift)
    XCTAssertEqual(up.transition.command, volumeUp)
    XCTAssertEqual(up.hyperPending, "")
    XCTAssertNil(up.leaderFallbackPending)
  }

  func testHeldLeaderStillCompletesALeaderSequence() {
    let exact = route(keyCode: kVK_ANSI_S, characters: "s")
    XCTAssertEqual(exact.transition.command, .showMappings)
    XCTAssertNil(exact.leaderFallbackPending)

    let partial = route(keyCode: kVK_ANSI_G, characters: "g")
    XCTAssertNil(partial.transition.action)
    XCTAssertEqual(partial.leaderFallbackPending, key("<space>g"))

    let finished = route(
      keyCode: kVK_ANSI_S, characters: "s", leaderFallbackPending: partial.leaderFallbackPending)
    XCTAssertEqual(finished.transition.command, .showAbout)
    XCTAssertNil(finished.leaderFallbackPending)
    XCTAssertEqual(finished.hyperPending, "")
  }

  func testUnmappedKeyDoesNotFireANormalCommand() {
    let swallowed = route(keyCode: kVK_ANSI_H, characters: "h")
    XCTAssertNil(swallowed.transition.action)
    XCTAssertEqual(swallowed.transition.pending, "")
    XCTAssertEqual(swallowed.hyperPending, "")
    XCTAssertNil(swallowed.leaderFallbackPending)
  }

  func testHyperMappingWinsOverALeaderSequenceOnTheSameKey() {
    let hyperAlsoBindsS = CompiledMappings(
      hyperMappings.ordered + [
        ModeMapping(key: "s", action: .flashCommand(.undo))
      ])
    let won = route(keyCode: kVK_ANSI_S, characters: "s", hyper: hyperAlsoBindsS)
    XCTAssertEqual(won.transition.command, .undo)
    XCTAssertNil(won.leaderFallbackPending)
  }

  func testBrokenLeaderSequenceDoesNotBecomeANormalCommand() {
    let started = route(keyCode: kVK_ANSI_G, characters: "g")
    let broken = route(
      keyCode: kVK_ANSI_H, characters: "h", leaderFallbackPending: started.leaderFallbackPending)
    XCTAssertNil(broken.transition.action)
    XCTAssertEqual(broken.transition.pending, "")
    XCTAssertNil(broken.leaderFallbackPending)
  }

  func testHyperKeyStillFiresAfterABrokenLeaderSequence() {
    let started = route(keyCode: kVK_ANSI_G, characters: "g")
    let volume = route(
      keyCode: kVK_ANSI_Minus, characters: "-",
      leaderFallbackPending: started.leaderFallbackPending)
    XCTAssertEqual(volume.transition.command, volumeDown)
    XCTAssertNil(volume.leaderFallbackPending)
  }

  func testHyperSequenceParksThenCompletes() {
    let hyper = CompiledMappings([
      ModeMapping(key: key("ab"), action: .flashCommand(.quit))
    ])
    let first = route(keyCode: kVK_ANSI_A, characters: "a", hyper: hyper)
    XCTAssertNil(first.transition.action)
    XCTAssertEqual(first.hyperPending, "a")
    XCTAssertNil(first.leaderFallbackPending)

    let second = route(
      keyCode: kVK_ANSI_B, characters: "b", hyperPending: first.hyperPending, hyper: hyper)
    XCTAssertEqual(second.transition.command, .quit)
    XCTAssertEqual(second.hyperPending, "")
  }

  private var hyperMappings: CompiledMappings {
    CompiledMappings([
      ModeMapping(key: "-", action: .flashCommand(volumeDown)),
      ModeMapping(key: "+", action: .flashCommand(volumeUp)),
    ])
  }

  private var normalMappings: CompiledMappings {
    CompiledMappings([
      ModeMapping(key: "h", action: .flashCommand(.scroll(.left))),
      ModeMapping(key: key("<space>s"), action: .flashCommand(.showMappings)),
      ModeMapping(key: key("<space>gs"), action: .flashCommand(.showAbout)),
    ])
  }

  private func route(
    keyCode: Int,
    characters: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    hyperPending: String = "",
    leaderFallbackPending: String? = nil,
    hyper: CompiledMappings? = nil,
    normal: CompiledMappings? = nil
  ) -> HyperKeyRouter.Result {
    HyperKeyRouter.route(
      hyperPending: hyperPending,
      leaderFallbackPending: leaderFallbackPending,
      leaderAtom: leader,
      keyCode: UInt16(keyCode),
      modifierFlags: flags,
      characters: characters,
      charactersIgnoringModifiers: ignoring ?? characters,
      hyperMappings: hyper ?? hyperMappings,
      normalMappings: normal ?? normalMappings)
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}
