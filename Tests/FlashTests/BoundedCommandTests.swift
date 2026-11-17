import Darwin
import XCTest

@testable import flash

/// The resident's one bounded way to run a tool and read its answer.
final class BoundedCommandTests: XCTestCase {
  private let environment = ["PATH": "/usr/bin:/bin"]

  private func run(
    _ script: String, timeout: TimeInterval? = 5, capture: BoundedCommand.Capture = .stdout,
    outputLimit: Int = BoundedCommand.defaultOutputLimit, extra: [String: String] = [:],
    directory: String? = nil
  ) -> BoundedCommand.Result {
    BoundedCommand.run(
      ["/bin/sh", "-c", script], environment: environment.merging(extra) { $1 },
      directory: directory, timeout: timeout, capture: capture, outputLimit: outputLimit)
  }

  /// Whether `pid` is gone, waiting up to two seconds for launchd to reap an
  /// orphan.
  private func gone(_ pid: pid_t) -> Bool {
    for _ in 0..<200 {
      if kill(pid, 0) != 0, errno == ESRCH { return true }
      usleep(10_000)
    }
    return false
  }

  func testItReadsTheStreamsItIsAskedForAndTheExitStatus() {
    let script = "echo hi; echo err >&2; exit 3"
    let stdout = run(script)
    XCTAssertEqual(stdout.status, 3)
    XCTAssertEqual(stdout.text, "hi\n")
    XCTAssertEqual(stdout.errorOutput, Data())
    XCTAssertFalse(stdout.succeeded)
    XCTAssertEqual(run(script, capture: .merged).text, "hi\nerr\n")
    let separate = run(script, capture: .separate)
    XCTAssertEqual(separate.text, "hi\n")
    XCTAssertEqual(separate.errorText, "err\n")
    let stderr = run(script, capture: .stderr)
    XCTAssertEqual(stderr.text, "")
    XCTAssertEqual(stderr.errorText, "err\n")
    XCTAssertEqual(run(script, capture: .none).status, 3)
    XCTAssertTrue(run("exit 0").succeeded)
  }

  /// 4 MB through a pipe that holds 64 KB: the drain never lets the child
  /// block, and what passes the limit is dropped and said so.
  func testAChattyCommandIsCutAtTheLimitAndStillFinishes() {
    let result = run(
      "head -c 4194304 /dev/zero; echo done >&2", timeout: 20, capture: .separate,
      outputLimit: 1024)
    XCTAssertEqual(result.status, 0)
    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(result.output.count, 1024)
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.errorText, "done\n")
  }

  /// A timeout signals the whole process group: the background child the
  /// command started goes with it.
  func testATimeoutEndsTheWholeGroup() throws {
    let started = DispatchTime.now().uptimeNanoseconds
    let result = run("sleep 30 & echo $!; wait", timeout: 0.3)
    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    XCTAssertTrue(result.timedOut)
    XCTAssertEqual(result.status, 128 + SIGTERM)
    XCTAssertLessThan(elapsedMs, 3_000)
    let child = try XCTUnwrap(pid_t(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertTrue(gone(child), "the grandchild got the group's SIGTERM")
  }

  /// A command ignoring SIGTERM gets SIGKILL after the grace period.
  func testACommandIgnoringTheTerminationIsKilled() {
    let result = run("trap '' TERM; sleep 30", timeout: 0.2)
    XCTAssertTrue(result.timedOut)
    XCTAssertEqual(result.status, 128 + SIGKILL)
  }

  /// The run ends with its leader: a background child left holding the pipe
  /// is neither waited for nor killed.
  func testALeaderLeavingABackgroundChildReturnsAtOnce() throws {
    let started = DispatchTime.now().uptimeNanoseconds
    let result = run("sleep 5 & echo $!", timeout: 10)
    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    XCTAssertEqual(result.status, 0)
    XCTAssertLessThan(elapsedMs, 2_000)
    let child = try XCTUnwrap(pid_t(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(kill(child, 0), 0, "the background child still runs")
    kill(child, SIGKILL)
  }

  func testAMissingExecutableDoesNotStart() {
    let result = BoundedCommand.run(
      ["/nonexistent/flash-tool"], environment: environment, timeout: 1)
    XCTAssertNil(result.status)
    XCTAssertNotNil(result.launchFailure)
    XCTAssertFalse(result.succeeded)
  }

  /// The child runs from `directory` with exactly `environment`, reads
  /// `/dev/null` and leads its own process group.
  func testItSpawnsTheWayTheResidentSpawnsCommands() {
    let result = run(
      "pwd -P; echo \"$FLASH_PROBE\"; read line; echo read=$?; "
        + "[ \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"$$\" ] && echo leader",
      extra: ["FLASH_PROBE": "x"], directory: "/tmp")
    XCTAssertEqual(result.text, "/private/tmp\nx\nread=1\nleader\n")
  }
}

/// Every command Flash runs by name is found the one way a terminal popup's
/// is: a regular executable file on `PATH`, never a directory, never a name
/// resolved against Flash's own working directory.
final class ExecutableSearchTests: XCTestCase {
  func testAStatusCommandIsFoundTheWayATerminalCommandIs() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-path-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directoryNamedLikeATool = root.appendingPathComponent("first/tool", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryNamedLikeATool, withIntermediateDirectories: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let tool = second.appendingPathComponent("tool")
    try Data("#!/bin/sh\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let path = ":\(root.path)/first:\(second.path)"
    XCTAssertEqual(
      FlashStatusBarController.executablePath("tool", environment: ["PATH": path]), tool.path,
      "the empty entry and the directory named tool are skipped")
    XCTAssertEqual(
      FlashStatusBarController.executablePath("missing-tool", environment: ["PATH": path]),
      "missing-tool", "unfound, it stays as written")
    XCTAssertEqual(
      FlashStatusBarController.executablePath("/bin/sh", environment: [:]), "/bin/sh")
  }
}
