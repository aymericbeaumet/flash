import FlashCore
import XCTest

@testable import flash

/// `menu choose`: the lines a file lists, how the flashlight filters them,
/// what Return answers, and how the CLI hands the resident its items.
final class MenuChoiceTests: XCTestCase {
  func testAFileListsItsNonBlankLinesAsWritten() {
    XCTAssertEqual(
      MenuChoice.items(from: "main\r\n  feature/a\n\n   \nrelease 1.2\n"),
      ["main", "  feature/a", "release 1.2"])
  }

  func testAnEmptyQueryListsEveryItemInItsOrderAndTypingFilters() {
    let pool = MenuChoice.candidates(["zeta", "alpha", "beta"])
    XCTAssertEqual(
      MenuChoice.matches(pool, query: "").map(\.candidate.title), ["zeta", "alpha", "beta"],
      "the file's order, not alphabetical")
    XCTAssertEqual(MenuChoice.matches(pool, query: "bet").first?.candidate.title, "beta")
    XCTAssertEqual(
      CandidateFinder.displayTitle(pool[0]), "zeta", "a row is the line, with no source label")
  }

  func testReturnPicksTheSelectionOrWhatWasTyped() {
    let pool = MenuChoice.candidates(["one", "two"])
    let all = MenuChoice.matches(pool, query: "")
    XCTAssertEqual(MenuChoice.pick(matches: all, selectedIndex: 1, query: ""), "two")
    XCTAssertEqual(MenuChoice.pick(matches: [], selectedIndex: 0, query: " new one "), "new one")
    XCTAssertNil(MenuChoice.pick(matches: [], selectedIndex: 0, query: ""))
  }

  func testLoadingReportsWhyAFileGivesNothing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let empty = dir.appendingPathComponent("empty.txt")
    try Data("\n\n".utf8).write(to: empty)
    XCTAssertEqual(MenuChoice.load(path: empty.path), .failure(.empty(empty.path)))
    XCTAssertEqual(
      MenuChoice.load(path: dir.appendingPathComponent("missing").path),
      .failure(.unreadable(dir.appendingPathComponent("missing").path)))
    let list = dir.appendingPathComponent("list.txt")
    try Data("a\nb\n".utf8).write(to: list)
    XCTAssertEqual(MenuChoice.load(path: list.path), .success(["a", "b"]))
  }

  func testTheCommandIsCanonicalAndNeedsAFile() {
    XCTAssertEqual(
      URLEventHandler.parse(words: ["menu", "choose", "--file=/tmp/x"]),
      .menuChoose(file: "/tmp/x"))
    XCTAssertNil(URLEventHandler.parse(words: ["menu", "choose"]))
    XCTAssertNil(URLEventHandler.parse(words: ["menu", "choose", "--file="]))
  }

  func testAPromptRoundTripsAndStaysOutsideTheEditableQuery() {
    let command = URLEventHandler.parse(words: [
      "menu", "choose", "--file=/tmp/x", "--prompt=Choose branch",
    ])
    XCTAssertEqual(command, .menuChoose(file: "/tmp/x", prompt: "Choose branch"))
    XCTAssertEqual(
      command.map { MappingCommand.flashCommand($0).argv },
      ["flash", "menu", "choose", "--file=/tmp/x", "--prompt=Choose branch"])
    XCTAssertNil(URLEventHandler.parse(words: ["menu", "choose", "--file=/tmp/x", "--prompt= "]))
    XCTAssertNil(
      URLEventHandler.parse(words: ["menu", "choose", "--file=/tmp/x", "--prompt=a\nb"]))
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    delegate.finder.menu = MenuSession(
      candidates: MenuChoice.candidates(["main", "dev"]), prompt: "Choose branch"
    ) { _ in }
    delegate.refreshCommandLine(text: "flashlight de")
    XCTAssertEqual(delegate.overlay.commandPromptPrefix, "Choose branch ")
    XCTAssertEqual(delegate.overlay.commandLineText, ":flashlight de")
    XCTAssertEqual(delegate.finder.matches.map(\.candidate.title), ["dev"])
  }

  func testTheCLIResolvesARelativeFileAndSavesPipedInput() throws {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    let relative = FlashCLI.preparedMenuWords(
      ["menu", "choose", "--file=list.txt"], directory: "/work", inventory: inventory,
      readStdin: {
        XCTFail("a --file never reads stdin")
        return nil
      })
    XCTAssertEqual(relative.words, ["menu", "choose", "--file=/work/list.txt"])
    XCTAssertNil(relative.temporaryFile)

    let piped = FlashCLI.preparedMenuWords(
      ["menu", "choose"], directory: "/work", inventory: inventory,
      readStdin: { Data("a\nb\n".utf8) })
    let file = try XCTUnwrap(piped.temporaryFile)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(piped.words, ["menu", "choose", "--file=\(file.path)"])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a\nb\n")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    XCTAssertEqual(mode as? Int, 0o600)

    let other = FlashCLI.preparedMenuWords(
      ["tab", "next"], directory: "/work", inventory: inventory,
      readStdin: {
        XCTFail("other commands never read stdin")
        return nil
      })
    XCTAssertEqual(other.words, ["tab", "next"])
  }

  /// The resident's half: a pick lists its rows only, Return answers, and
  /// a close without a pick cancels.
  func testAPickAnswersAndACloseCancels() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    var results: [Result<String, MenuChoiceError>] = []
    delegate.finder.menu = MenuSession(candidates: MenuChoice.candidates(["main", "dev"])) {
      results.append($0)
    }
    delegate.refreshCommandLine(text: "flashlight ")
    XCTAssertEqual(delegate.finder.matches.map(\.candidate.title), ["main", "dev"])
    delegate.refreshCommandLine(text: "flashlight !de")
    XCTAssertEqual(
      delegate.finder.matches.map(\.candidate.title), ["dev"], "`!` is filter text, not a bang")
    delegate.refreshCommandLine(text: "flashlight de")
    XCTAssertEqual(delegate.finder.matches.first?.candidate.title, "dev")
    delegate.actOnSelectedCandidateFinderCandidate(submit: false)
    XCTAssertEqual(results, [.success("dev")])
    XCTAssertNil(delegate.finder.menu)

    delegate.finder.menu = MenuSession(candidates: MenuChoice.candidates(["x"])) {
      results.append($0)
    }
    delegate.resetCommandLineState()
    XCTAssertEqual(results.last, .failure(.cancelled))
    XCTAssertNil(delegate.finder.menu)
  }
}
