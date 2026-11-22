import Darwin
import XCTest

@testable import FlashTerminal

final class TerminalLaunchTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func file(_ name: String, in directory: String, mode: Int16) throws -> String {
    let folder = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent(name).path
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    return path
  }

  private func state(
    of session: TerminalSession, until matches: @escaping (TerminalSessionState) -> Bool
  )
    -> TerminalSessionState?
  {
    var last: TerminalSessionState?
    let reached = expectation(description: "session state")
    reached.assertForOverFulfill = false
    session.onStateChange = { state in
      last = state
      if matches(state) { reached.fulfill() }
    }
    wait(for: [reached], timeout: terminalChildTimeout)
    session.onStateChange = nil
    return last
  }

  func testResolvesTheFirstExecutableFileOnPathAndNothingElse() throws {
    let executable = try file("tool", in: "b", mode: 0o755)
    _ = try file("tool", in: "a", mode: 0o644)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("dir/tool"), withIntermediateDirectories: true)
    let path = [
      "", root.appendingPathComponent("dir").path, root.appendingPathComponent("a").path,
      root.appendingPathComponent("b").path,
    ].joined(separator: ":")
    XCTAssertEqual(TerminalExecutable.resolve("tool", path: path), executable)
    XCTAssertNil(TerminalExecutable.resolve("absent", path: path))
    XCTAssertNil(TerminalExecutable.resolve("", path: path))
    XCTAssertEqual(TerminalExecutable.resolve("./tool", path: path), "./tool")
    XCTAssertEqual(TerminalExecutable.resolve("sh", path: nil), "/bin/sh")
  }

  func testOnlyChangesToTheCommandOrItsWorldMakeAFailureGoAway() {
    for failure: TerminalLaunchFailure in [
      .invalidCommand, .commandNotFound("x"), .cannotExecute("/x", errno: EACCES),
      .workingDirectory("/x", errno: ENOENT),
    ] {
      XCTAssertTrue(failure.isPermanent, "\(failure)")
    }
    XCTAssertFalse(TerminalLaunchFailure.spawnFailed(errno: EAGAIN).isPermanent)
    XCTAssertFalse(TerminalLaunchFailure.exitStatusUnavailable.isPermanent)
    XCTAssertEqual(
      TerminalLaunchFailure.commandNotFound("btop").description, "btop: command not found")
    XCTAssertFalse(TerminalLaunchFailure.commandNotFound("btop").reason.contains("btop"))
  }

  func testRestartDiscardsQueuedStateAndFramesFromPreviousProcess() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(command: ["/bin/cat"], columns: 8, rows: 2))
    defer { session.shutdown() }
    var states: [TerminalSessionState] = []
    var frames: [TerminalFrame] = []
    session.onStateChange = { states.append($0) }
    session.onFrame = { frames.append($0) }

    session.start()
    _ = session.currentFrame()
    session.resize(columns: 12, rows: 2)
    _ = session.currentFrame()
    session.restart()
    let replacementFrame = try XCTUnwrap(session.currentFrame())
    let delivered = expectation(description: "queued publications drained")
    DispatchQueue.main.async { delivered.fulfill() }
    wait(for: [delivered], timeout: terminalChildTimeout)

    XCTAssertEqual(states.count, 1, "only the replacement process may publish state: \(states)")
    guard case .running = states.last else { return XCTFail("replacement must be running") }
    XCTAssertEqual(frames.count, 1, "old frames must not repaint the replacement")
    XCTAssertTrue(frames.first == replacementFrame)
  }

  func testStopDiscardsQueuedProcessStateAndFramesBeforeItsCompletion() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(command: ["/bin/cat"], columns: 8, rows: 2))
    defer { session.shutdown() }
    var states: [TerminalSessionState] = []
    var frameCount = 0
    session.onStateChange = { states.append($0) }
    session.onFrame = { _ in frameCount += 1 }
    session.start()
    _ = session.currentFrame()
    let stopped = expectation(description: "stopped after dropping old publications")
    session.stop {
      XCTAssertEqual(states, [.stopped])
      XCTAssertEqual(frameCount, 0)
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: terminalChildTimeout)
  }

  func testQueuedFrameCannotReplaceANewerSynchronousSnapshot() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(command: ["/bin/cat"], columns: 8, rows: 2))
    defer { session.shutdown() }
    var deliveredColumns: [Int] = []
    session.onFrame = { deliveredColumns.append($0.columns) }
    session.start()
    _ = session.currentFrame()
    session.setWantsFrames(false)
    session.resize(columns: 12, rows: 2)
    let latest = try XCTUnwrap(session.currentFrame())
    XCTAssertEqual(latest.columns, 12)
    let drained = expectation(description: "old frame publication drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: terminalChildTimeout)

    XCTAssertEqual(session.frame?.generation, latest.generation)
    XCTAssertEqual(session.frame?.columns, 12)
    XCTAssertTrue(deliveredColumns.isEmpty, "a stale frame must not reach a rebound view")
  }

  func testAMissingCommandFailsWithoutForkingAndARestartUsesItsNewPath() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["tool"], environment: ["PATH": root.appendingPathComponent("bin").path]))
    defer { session.shutdown() }
    session.start()
    XCTAssertEqual(
      state(of: session) { if case .failed = $0 { true } else { false } },
      .failed(.commandNotFound("tool")))
    _ = try file("tool", in: "later", mode: 0o755)
    session.restart(environment: ["PATH": root.appendingPathComponent("later").path])
    let started = state(of: session) { if case .running = $0 { true } else { false } }
    guard case .running = started else { return XCTFail("\(String(describing: started))") }
  }

  func testExecAndDirectoryFailuresNameTheirStep() throws {
    let plain = try file("plain", in: "bin", mode: 0o644)
    let refused = TerminalSession(configuration: TerminalConfiguration(command: [plain]))
    defer { refused.shutdown() }
    refused.start()
    XCTAssertEqual(
      state(of: refused) { if case .failed = $0 { true } else { false } },
      .failed(.cannotExecute(plain, errno: EACCES)))

    let missing = root.appendingPathComponent("gone").path
    let lost = TerminalSession(
      configuration: TerminalConfiguration(command: ["/bin/sh"], workingDirectory: missing))
    defer { lost.shutdown() }
    lost.start()
    XCTAssertEqual(
      state(of: lost) { if case .failed = $0 { true } else { false } },
      .failed(.workingDirectory(missing, errno: ENOENT)))
  }
}
