import AppKit
import Foundation

/// An owned terminal window whose hyperlink handler records URLs instead of opening them.
final class TerminalLinkFixture {
  let label = "Open fixture document"
  let url: String
  private let directory: URL
  private let socketName: String
  private let terminal = Process()
  private let tmux: String
  private var log: FileHandle?

  init(tmux: String) throws {
    guard tmux.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: tmux) else {
      throw FixtureError(
        "Build the pinned tmux with mise run build:tmux-oracle, or pass --terminal-tmux <absolute-path>"
      )
    }
    self.tmux = tmux
    let nonce = UUID().uuidString.lowercased()
    socketName = "flash-terminal-oracle-\(nonce)"
    directory = URL(fileURLWithPath: "/tmp/\(socketName)", isDirectory: true)
    url = "https://example.invalid/flash-terminal-fixture/\(nonce)"
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  func start() throws -> NSRunningApplication {
    let executable = "/Applications/Alacritty.app/Contents/MacOS/alacritty"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw FixtureError("Install Alacritty before running --terminal-links")
    }
    let captureScript = directory.appendingPathComponent("capture.sh")
    try "printf '%s' \"$2\" > \"$1.pending\" && /bin/mv -f \"$1.pending\" \"$1\"\n".write(
      to: captureScript, atomically: true, encoding: .utf8)
    let displayScript = directory.appendingPathComponent("display.sh")
    try """
    printf '\\033[2J\\033[H'
    printf 'Terminal link fixture\\n\\n'
    printf '界  \\033]8;id=fixture;\(url)\\033\\\\\(label)\\033]8;;\\033\\\\\\n'
    IFS= read -r ignored
    """.write(to: displayScript, atomically: true, encoding: .utf8)
    let tmuxConfig = directory.appendingPathComponent("tmux.conf")
    try """
    set -g status off
    set -g mouse on
    set -as terminal-features ',*:hyperlinks'
    set -g default-terminal tmux-256color
    """.write(to: tmuxConfig, atomically: true, encoding: .utf8)
    let config = directory.appendingPathComponent("alacritty.toml")
    try """
    [general]
    ipc_socket = false
    [window]
    dimensions = { columns = 80, lines = 24 }
    padding = { x = 12, y = 10 }
    dynamic_padding = true
    dynamic_title = false
    decorations = "None"
    [font]
    size = 14
    [debug]
    print_events = true
    [[hints.enabled]]
    hyperlinks = true
    command = { program = "/bin/sh", args = ["\(captureScript.path)", "\(capturePath.path)"] }
    mouse = { enabled = true, mods = "Shift" }
    """.write(to: config, atomically: true, encoding: .utf8)
    let logURL = directory.appendingPathComponent("terminal.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    log = try FileHandle(forWritingTo: logURL)
    terminal.executableURL = URL(fileURLWithPath: executable)
    terminal.arguments = [
      "--config-file", config.path, "--title", socketName, "-e", tmux,
      "-L", socketName, "-f", tmuxConfig.path, "new-session", "-s", "fixture",
      "/bin/sh", displayScript.path,
    ]
    terminal.environment = environment
    terminal.standardOutput = log
    terminal.standardError = log
    try terminal.run()
    let deadline = Date().addingTimeInterval(10)
    while terminal.isRunning, Date() < deadline {
      if let app = NSRunningApplication(processIdentifier: terminal.processIdentifier),
        let pane = try? run(
          tmux,
          [
            "-L", socketName, "display-message", "-p", "-t", "fixture:0.0",
            "#{session_attached}", ";", "capture-pane", "-p", "-e", "-t", "fixture:0.0",
          ], timeout: min(1, max(0.01, deadline.timeIntervalSinceNow))),
        pane.hasPrefix("1\n"), pane.contains(label), pane.contains(url)
      {
        return app
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw FixtureError("Owned Alacritty/tmux did not attach and render the OSC8 fixture")
  }

  func capturedURL() -> String? {
    try? String(contentsOf: capturePath, encoding: .utf8)
  }

  func diagnostics() -> String {
    guard
      let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("terminal.log"))
    else {
      return "owned terminal log unavailable"
    }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
      ["MouseInput", "CursorMoved", "ModifiersChanged", "Focused", "ERROR", "WARN"].contains {
        line.contains($0)
      }
    }
    return "owned terminal event log:\n" + lines.suffix(24).joined(separator: "\n")
  }

  func stop() {
    _ = try? run(tmux, ["-L", socketName, "kill-server"])
    if terminal.isRunning {
      terminal.terminate()
      let deadline = Date().addingTimeInterval(2)
      while terminal.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if terminal.isRunning { kill(terminal.processIdentifier, SIGKILL) }
      terminal.waitUntilExit()
    }
    try? log?.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private var capturePath: URL { directory.appendingPathComponent("clicked-url") }

  private var environment: [String: String] {
    // In particular, do not inherit TMUX, TMUX_PANE or TMUX_TMPDIR: the named
    // server must use the normal socket root that terminal discovery inspects.
    ProcessInfo.processInfo.environment.filter {
      ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"]
        .contains($0.key)
    }
  }

  private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws
    -> String
  {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    guard !process.isRunning else {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw FixtureError(
        "Fixture subprocess timed out: \(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    guard process.terminationStatus == 0 else {
      throw FixtureError(
        "Fixture subprocess failed: \(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
