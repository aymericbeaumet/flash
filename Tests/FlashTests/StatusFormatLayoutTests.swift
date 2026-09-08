import AppKit
import Foundation
import XCTest

@testable import FlashTerminal
@testable import flash

final class StatusFormatLayoutTests: XCTestCase {
  func testOracleDecoderPreservesCombinedGlyphAtRightEdge() throws {
    let buffer = TerminalBuffer(columns: 20, rows: 1, scrollback: false)
    buffer.write(Data("\u{1b}[1;19H🇫🇷".utf8))
    let frame = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(frame.cells[18].text, "🇫🇷")
    XCTAssertEqual(frame.cells[18].width, 2)
    XCTAssertEqual(frame.cells[19].width, 0)
  }
  func testAlignmentClipsCentreBeforeEdgesAndKeepsRightTail() {
    XCTAssertEqual(row("LLLL#[align=centre]CENTER#[align=right]RRRR", 10), "LLLLNTRRRR")
    XCTAssertEqual(row("LLLL#[align=right]12345678", 10), "LLLL345678")
    XCTAssertEqual(row("123456789012", 10), "1234567890")
  }

  func testAbsoluteCentreOverlaysOtherAlignmentSections() {
    XCTAssertEqual(
      row("LLLL#[align=centre]CC#[align=right]RRRR#[align=absolute-centre]AB", 10),
      "LLLLABRRRR")
  }

  func testWideGlyphPaddingSurvivesAnOverlayAtItsTrailingCell() {
    XCTAssertEqual(row("界界界界#[align=absolute-centre]X", 8), "界界界界")
    XCTAssertEqual(row("界界界界#[align=absolute-centre]XX", 8), "界界X 界")
  }

  func testNegativeOneCentreOffsetKeepsThePreviousNativeCursor() {
    XCTAssertEqual(
      row("#[align=centre]BEFORE#[list=on]L#[nolist]A#[align=right]RRRRRRRRRR", 20),
      "     LA   BEFORERRRR")
  }

  func testNativeGridCombinesEmojiAndHangulWithoutUsingFormatWidth() {
    let result = layout("👩‍💻🇫🇷👍🏽각", 10)
    XCTAssertEqual(result.text, "👩‍💻🇫🇷👍🏽각  ")
    XCTAssertEqual(result.cells.filter { $0.columns == 2 }.count, 4)
  }

  func testMarkerOnlyFillColorsUnoccupiedCells() {
    let result = layout("A#[fill=red]", 4)
    XCTAssertEqual(result.text, "A   ")
    XCTAssertEqual(result.cells[1].segment.background, .palette(1))
    XCTAssertEqual(result.cells[0].segment.background, .defaultBackground)
  }

  func testWidthAndPadAreAcceptedButInertInNativeStatusDrawing() {
    XCTAssertEqual(row("A#[width=2,pad=5]BCDE#[width=50%]F", 12), "ABCDEF      ")
  }

  func testFocusAndMarkersKeepTheSelectedListRegionVisible() {
    XCTAssertEqual(
      row(
        "#[align=left,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
          + "#[list=left-marker]<#[list=right-marker]>#[nolist]", 8),
      "<456789>")
  }

  func testDefaultAlignmentDoesNotMakeAnImplicitListAlignment() {
    XCTAssertEqual(row("#[list=on]abc#[nolist]after", 10), "          ")
  }

  func testRangeCoordinatesFollowRightClipping() {
    let result = layout("LLLL#[align=right,range=user|item]12345678#[norange]", 10)
    XCTAssertEqual(result.ranges.count, 1)
    XCTAssertEqual(result.ranges.first?.columns, 4..<10)
    XCTAssertEqual(result.ranges.first?.range, .init(kind: .user, argument: "item"))
  }

  func testUnclosedNativeRangeIsNotPublished() {
    XCTAssertTrue(layout("#[range=user|item]abc", 10).ranges.isEmpty)
  }

  func testPositionedRunsRetainFlashInteractionIdentity() {
    let result = layout("#[align=right,popup=details,pill,cyc]AB#[nopopup]", 8)
    let run = result.positionedRuns.first { $0.segment.text == "AB" }
    XCTAssertEqual(run?.column, 6)
    XCTAssertEqual(run?.columns, 2)
    XCTAssertEqual(run?.segment.popup, "details")
    XCTAssertEqual(run?.segment.pill, true)
    XCTAssertEqual(run?.segment.cycle, true)
    XCTAssertNotNil(run?.segment.origin)
  }

  func testNativeDrawingMatchesIsolatedTmuxOracle() throws {
    let formats = [
      "plain text",
      "LLLL#[align=centre]CENTER#[align=right]RRRRRRRR",
      "#[align=right]1234567890123456789012345678901234567890",
      "LLLL#[align=absolute-centre]ABSOLUTE#[align=right]RRRR",
      "A#[width=2,pad=8]BCDE#[width=50%]F",
      "#[fill=#123456,width=-0,pad=-0]ABC",
      "#[fill=#123456,range=control|-0]ABC#[norange]",
      "A#[fill=#123456]",
      "#[fg=#123456,bg=#654321,bold]bold#[none]plain",
      "#[list=on]0123456789#[nolist]after",
      "#[align=left,list=on]012345678901234567890#[nolist]after#[align=right]RR",
      "LEFT#[align=centre,list=on]012345678901234567890#[nolist]end#[align=right]RR",
      "LEFT#[align=right,list=on]012345678901234567890#[nolist]end",
      "LEFT#[align=absolute-centre,list=on]012345678901234567890#[nolist]end#[align=right]RR",
      "#[align=left,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<#[list=right-marker]>#[nolist]",
      "#[align=centre,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<<#[list=right-marker]>>#[nolist]",
      "#[align=right,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<#[list=right-marker]>#[nolist]",
      "#[align=absolute-centre,list=on]012345#[list=focus]678#[list=on]9ABCDEF"
        + "#[list=left-marker]<#[list=right-marker]>#[nolist]",
      "LLLLLLLL#[align=centre]CC#[list=on]12345#[nolist]AFTER#[align=right]RRRRRRRR",
      "#[align=left,list=on]abc#[list=on]def#[nolist]after",
      "#[align=left,list=focus]abc#[list=on]def#[nolist]after",
      "A#[ignore]B#[fg=red]C#[noignore]D",
      "##[bold]literal",
      "abc界def#[align=right]界END",
      "#[align=right]abc界def界ghi界jkl",
      "cafe\u{301}#[align=centre]中#[align=right]終",
      "界界界界#[align=absolute-centre]X",
      "界界界界#[align=absolute-centre]XX",
      "#[fg=#112233,bg=#445566]界界界界#[fg=#778899,bg=#aabbcc,align=absolute-centre]XX",
      "界界界界界#[align=absolute-centre]X",
      "LEFT#[align=absolute-centre]界X#[align=right]RIGHT",
      "👩‍💻abc#[align=right]🇫🇷",
      "#[align=centre]BEFORE#[list=on]L#[nolist]A#[align=right]RRRRRRRRRR",
      "#[align=left,list=on]012345#[list=left-marker]<<<#[list=on]6789"
        + "#[list=right-marker]>>>#[nolist]END",
      "#[align=left,range=user|item]LLLL#[norange]#[align=right]RRRR",
      "#[bold,dim,italics,blink,reverse,hidden,overline,strikethrough]A#[none]B",
      "#[bold]A#[nobold,italics]B#[noitalics,dim]C#[nodim]D",
      "#[underscore]A#[double-underscore]B#[curly-underscore]C#[dotted-underscore]D#[dashed-underscore]E#[nounderscore]F",
      "#[fg=#112233,bg=#445566,us=#778899,curly-underscore]A#[default]B",
      "#[fg=#112233,push-default]A#[fg=#445566]B#[default]C#[pop-default,default]D",
      "#[bold,push-default]A#[italics,push-default]B#[pop-default,default]C#[pop-default,default]D",
      "A#[fg=#112233,bogus,bold]B#[fg=#445566]C",
      "#[fill=#112233]A#[fill=#445566]B#[fill=default]C",
      "#[fill=#112233]A#[fill=terminal]B",
      "#[bold|italics]A#[nobold|italics]B",
      "#[acs]lqqk#[noacs]ABC",
      "👍🏽X#[align=right]❤️Z",
      "각X#[align=right]終",
      "👩‍💻界X#[align=right]🇫🇷END",
    ]
    let executable = try tmuxExecutable()
    for columns in [8, 11, 20, 32] {
      let oracle = try DrawingOracle(executable: executable, columns: columns, test: self)
      defer { oracle.stop() }
      for (index, source) in formats.enumerated() {
        let native = try oracle.draw(source, marker: String(format: "x%02d", index), test: self)
        let actual = layout(source, columns)
        let nativeText = native.filter { $0.width != 0 }.map { $0.text.isEmpty ? " " : $0.text }
          .joined()
        XCTAssertEqual(actual.text, nativeText, "columns=\(columns), format=\(source)")
        // Explicit RGB styles and the default fg/bg avoid depending on the
        // terminal application's configurable ANSI palette.
        for column in 0..<columns where !actual.cells[column].isContinuation {
          let segment = actual.cells[column].segment
          if let color = rgb(segment.foreground, default: 0xc0c0c0) {
            XCTAssertEqual(
              rgb(native[column].foreground), color,
              "foreground column=\(column), columns=\(columns), format=\(source)")
          }
          if let color = rgb(segment.background, default: 0x000000) {
            XCTAssertEqual(
              rgb(native[column].background), color,
              "background column=\(column), columns=\(columns), format=\(source)")
          }
          let flags: [(UInt16, Bool)] = [
            (1, segment.bold), (2, segment.italics), (4, segment.dim),
            (8, segment.blink), (16, segment.reverse), (32, segment.hidden),
            (64, segment.strikethrough), (128, segment.overline),
          ]
          for (mask, enabled) in flags {
            XCTAssertEqual(
              native[column].flags & mask != 0, enabled,
              "attribute=\(mask), column=\(column), columns=\(columns), format=\(source)")
          }
          let underline: Int
          switch segment.underlineStyle {
          case .single: underline = 1
          case .double: underline = 2
          case .curly: underline = 3
          case .dotted: underline = 4
          case .dashed: underline = 5
          }
          XCTAssertEqual(
            native[column].underline, segment.underline ? underline : 0,
            "underline column=\(column), columns=\(columns), format=\(source)")
          if segment.underline,
            let expected = rgb(segment.underlineColor, default: 0xc0c0c0)
          {
            XCTAssertEqual(
              rgb(native[column].underlineColor), expected,
              "underline color column=\(column), columns=\(columns), format=\(source)")
          }
        }
      }
    }
  }

  private func layout(_ source: String, _ columns: Int) -> StatusFormatLayout.Result {
    StatusFormatLayout.layout(StatusFormatDocument.parse(source), columns: columns)
  }

  private func row(_ source: String, _ columns: Int) -> String {
    layout(source, columns).text
  }

  private func rgb(_ value: TerminalColor) -> UInt32 {
    UInt32(value.red) << 16 | UInt32(value.green) << 8 | UInt32(value.blue)
  }

  private func rgb(_ value: FlashStatusTextColor, default fallback: UInt32) -> UInt32? {
    switch value {
    case .defaultForeground, .defaultBackground: return fallback
    case .rgb(let rgb): return rgb
    case .palette: return nil
    }
  }

  private func tmuxExecutable() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let pinned = root.appendingPathComponent("build/tmux-oracle/bin/tmux").path
    let executable = environment["TMUX_ORACLE"] ?? pinned
    guard FileManager.default.isExecutableFile(atPath: executable)
    else { throw oracleUnavailable("tmux 3.7b is required for the native status drawing oracle") }
    let version = try DrawingOracle.run(executable, ["-V"])
    guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "tmux 3.7b" else {
      throw oracleUnavailable("native status drawing oracle requires tmux 3.7b, found \(version)")
    }
    let stampURL = URL(fileURLWithPath: executable).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".flash-build")
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    guard
      (try? String(contentsOf: stampURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "3.7b-2.11.3-\(architecture)"
    else { throw oracleUnavailable("Run Scripts/build-tmux-oracle.sh to pin tmux and utf8proc") }
    return executable
  }

  private func oracleUnavailable(_ message: String) -> Error {
    if ProcessInfo.processInfo.environment["FLASH_REQUIRE_TMUX_ORACLE"] == "1" {
      return NSError(
        domain: "TmuxDrawingOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
    return XCTSkip(message)
  }

  private final class DrawingOracle {
    let root: URL
    let socket: String
    let executable: String
    let terminal: TerminalSession
    let columns: Int
    var stopped = false

    init(executable: String, columns: Int, test: XCTestCase) throws {
      self.executable = executable
      self.columns = columns
      // macOS's per-user temporary directory can exhaust sockaddr_un.sun_path.
      root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
        "flash-layout-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      socket = root.appendingPathComponent("socket").path
      let config = root.appendingPathComponent("tmux.conf")
      try """
      set-option -g status 2
      set-option -g status-position top
      set-option -g status-interval 0
      set-option -g status-style 'fg=#c0c0c0,bg=#000000'
      set-option -g terminal-features 'xterm-256color:RGB:usstyle:overline:strikethrough'
      set-option -g status-format[0] 'warmup'
      set-option -g status-format[1] 'initial'
      """.write(to: config, atomically: true, encoding: .utf8)
      var environment = ProcessInfo.processInfo.environment
      environment.removeValue(forKey: "TMUX")
      environment["TERM"] = "xterm-256color"
      environment["LC_ALL"] = "en_US.UTF-8"
      terminal = TerminalSession(
        configuration: .init(
          command: [
            executable, "-S", socket, "-f", config.path, "new-session", "-s", "oracle",
            "/bin/sh", "-c", "printf READY; exec /bin/sleep 60",
          ],
          workingDirectory: root.path, environment: environment, columns: columns, rows: 5))
      terminal.setColors(
        foreground: NSColor(srgbRed: 192.0 / 255, green: 192.0 / 255, blue: 192.0 / 255, alpha: 1),
        background: .black)
      let ready = test.expectation(description: "isolated tmux status client ready")
      var fulfilled = false
      terminal.onFrame = { frame in
        guard !fulfilled, frame.rows == 5 else { return }
        let pane = frame.cells[(columns * 2)..<(columns * 3)].map(\.text).joined()
        if pane.hasPrefix("READY") {
          fulfilled = true
          ready.fulfill()
        }
      }
      terminal.start()
      test.wait(for: [ready], timeout: 5)
      terminal.onFrame = nil
    }

    func draw(_ source: String, marker: String, test: XCTestCase) throws -> [TerminalCell] {
      let changed = test.expectation(description: "native status row \(marker)")
      var captured: [TerminalCell]?
      terminal.onFrame = { [columns] frame in
        guard captured == nil, frame.rows == 5 else { return }
        let second = frame.cells[columns..<(columns * 2)].map(\.text).joined()
        if second.hasPrefix(marker) {
          captured = Array(frame.cells.prefix(columns))
          changed.fulfill()
        }
      }
      _ = try Self.run(executable, ["-S", socket, "set-option", "-g", "status-format[0]", source])
      _ = try Self.run(executable, ["-S", socket, "set-option", "-g", "status-format[1]", marker])
      test.wait(for: [changed], timeout: 5)
      terminal.onFrame = nil
      return try XCTUnwrap(captured)
    }

    func stop() {
      guard !stopped else { return }
      stopped = true
      _ = try? Self.run(executable, ["-S", socket, "kill-server"])
      terminal.shutdown()
      try? FileManager.default.removeItem(at: root)
    }

    deinit { stop() }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw NSError(
          domain: "TmuxDrawingOracle", code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
      }
      return String(decoding: data, as: UTF8.self)
    }
  }
}
