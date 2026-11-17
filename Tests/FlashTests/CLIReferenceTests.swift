import Foundation
import XCTest

@testable import flash

/// The completion scripts and the man page are generated from the command
/// table: they cover every command and option, they parse in their shell,
/// and the man page lints clean.
final class CLIReferenceTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-cli-reference-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func write(_ text: String, _ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// Exit status and combined output of `executable arguments`.
  private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
  }

  func testEveryCommandAndOptionIsCompletedInEveryShell() {
    let entries = CLIReference.entries
    XCTAssertEqual(
      entries.count, URLEventHandler.commandNames.count + FlashQuery.allCases.count)
    for shell in CLIReference.Shell.allCases {
      let script = CLIReference.completion(for: shell)
      for entry in entries {
        XCTAssertTrue(script.contains(entry.topic), "\(shell): \(entry.topic)")
        XCTAssertTrue(script.contains(entry.action), "\(shell): \(entry.topic) \(entry.action)")
        for option in entry.options {
          let name = shell == .fish ? String(option.name.dropFirst(2)) : option.name
          XCTAssertTrue(script.contains(name), "\(shell): \(entry.topic) \(entry.action) \(name)")
          for value in option.values ?? [] {
            XCTAssertTrue(script.contains(value), "\(shell): \(option.name)=\(value)")
          }
        }
      }
      for word in CLIReference.words {
        XCTAssertTrue(script.contains(word.name), "\(shell): \(word.name)")
      }
    }
  }

  func testTheScriptsParseInTheirShell() throws {
    let zsh = try write(CLIReference.completion(for: .zsh), "_flash")
    let bash = try write(CLIReference.completion(for: .bash), "flash.bash")
    for (shell, script) in [("/bin/zsh", zsh), ("/bin/bash", bash)]
    where FileManager.default.isExecutableFile(atPath: shell) {
      let (status, output) = try run(shell, ["-n", script.path])
      XCTAssertEqual(status, 0, "\(shell): \(output)")
    }
    for fish in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    where FileManager.default.isExecutableFile(atPath: fish) {
      let script = try write(CLIReference.completion(for: .fish), "flash.fish")
      let (status, output) = try run(fish, ["-n", script.path])
      XCTAssertEqual(status, 0, output)
    }
  }

  /// Bash splits words at `=`; the script reads the typed line itself.
  func testBashCompletesTopicsActionsOptionsAndValues() throws {
    let script = try write(CLIReference.completion(for: .bash), "flash.bash")
    let probe = """
      source '\(script.path)'
      for line in 'flash mou' 'flash mouse tar' 'flash mouse target --sco' \\
        'flash mouse target --scope=sc' 'flash cli completion --shell=' 'flash nope '; do
        COMP_LINE="$line"; COMP_POINT=${#line}; _flash
        echo "$line|${COMPREPLY[*]}"
      done
      """
    let (status, output) = try run("/bin/bash", ["-c", probe])
    XCTAssertEqual(status, 0, output)
    let answers = Dictionary(
      uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
      })
    XCTAssertEqual(answers["flash mou"], "mouse")
    XCTAssertEqual(answers["flash mouse tar"], "target")
    XCTAssertEqual(answers["flash mouse target --sco"], "--scope=")
    XCTAssertEqual(answers["flash mouse target --scope=sc"], "screen")
    XCTAssertEqual(answers["flash cli completion --shell="], "zsh bash fish")
    XCTAssertEqual(answers["flash nope "], "")
  }

  func testTheManPageListsEveryCommandAndLintsClean() throws {
    let page = CLIReference.manPage(date: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(page.hasPrefix(".TH FLASH 1 1970-01-01"))
    for entry in CLIReference.entries {
      XCTAssertTrue(page.contains("flash \(entry.topic) \(entry.action)"), entry.action)
    }
    XCTAssertTrue(page.contains(".SH EXIT STATUS"))
    // Text lines wrap under 80 bytes; one token too long to break may not.
    for line in page.split(separator: "\n") where !line.hasPrefix(".") && line.contains(" ") {
      XCTAssertLessThanOrEqual(line.utf8.count, 80, String(line))
    }
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/mandoc") else { return }
    let url = try write(page, "flash.1")
    let (status, output) = try run("/usr/bin/mandoc", ["-T", "lint", "-W", "warning", url.path])
    XCTAssertEqual(status, 0, output)
    XCTAssertEqual(output, "")
  }

  func testTheQueriesTakeTheirArgumentsOnly() {
    XCTAssertTrue(FlashQuery.completion.accepts(["shell": "zsh"]))
    XCTAssertFalse(FlashQuery.completion.accepts(["shell": "tcsh"]))
    XCTAssertFalse(FlashQuery.completion.accepts([:]))
    XCTAssertTrue(FlashQuery.manPage.accepts([:]))
    XCTAssertFalse(FlashQuery.manPage.accepts(["json": "1"]))
    XCTAssertTrue(FlashQuery.configSchema.accepts([:]))
    XCTAssertTrue(FlashQuery.eventsWatch.accepts([:]))
    XCTAssertTrue(
      FlashQuery.eventsWatch.accepts(["name": "core:mode.changed,core:hints.*", "count": "1"]))
    XCTAssertFalse(FlashQuery.eventsWatch.accepts(["name": "core:ax.changed"]))
    XCTAssertFalse(FlashQuery.eventsWatch.accepts(["name": ","]))
    XCTAssertFalse(FlashQuery.eventsWatch.accepts(["count": "0"]))
    XCTAssertFalse(FlashQuery.eventsWatch.accepts(["json": "1"]))
    // The stream needs the resident, over the CLI's own connection.
    for query in FlashQuery.allCases {
      XCTAssertEqual(
        query.runsInCLI, ![.status, .doctor, .eventsWatch].contains(query), "\(query.name)")
    }
  }
}
