import XCTest

@testable import flash

/// The resident's in-process AppleScript prints exactly what `osascript -e`
/// prints, and keeps its caller's deadline. Every script runs off main, as in
/// the resident; none addresses an app, so none needs Automation.
final class AppleScriptRunnerTests: XCTestCase {
  private func run(_ source: String, timeout: TimeInterval = 20) -> AppleScriptOutput {
    var output: AppleScriptOutput?
    let done = expectation(description: source)
    DispatchQueue.global(qos: .userInitiated).async {
      output = AppleScriptRunner.run(source, timeout: timeout)
      done.fulfill()
    }
    wait(for: [done], timeout: timeout + 30)
    return output ?? AppleScriptOutput(status: -2, stdout: "", stderr: "no output")
  }

  /// `/usr/bin/osascript -e <source>`, for the parity check.
  private func osascript(_ source: String) throws -> AppleScriptOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return AppleScriptOutput(
      status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
      stderr: String(decoding: err, as: UTF8.self))
  }

  /// Every expectation is what `/usr/bin/osascript -e <source>` printed on
  /// macOS 26, byte for byte (the Rust SDK's `osa.rs` pins the same).
  func testResultsPrintLikeOsascript() {
    let cases: [(String, String)] = [
      ("return \"ok\"", "ok\n"),
      ("return \"a\" & return & \"b\"", "a\rb\n"),
      ("return \"x\" & tab & \"y\" & linefeed", "x\ty\n\n"),
      (
        "set AppleScript's text item delimiters to linefeed\nreturn {\"a\", \"b\"} as text",
        "a\nb\n"
      ),
      ("return {1, \"two\", 3.5}", "1, two, 3.5\n"),
      ("return {a:1, b:\"x\"}", "a:1, b:x\n"),
      ("return {}", "\n"),
      ("return {{1, 2}, {\"a\", {b:3}}}", "1, 2, a, b:3\n"),
      ("return {\"a, b\", \"c\"}", "a, b, c\n"),
      ("return 12345678901", "1.2345678901E+10\n"),
      ("return true", "true\n"),
      ("return 50", "50\n"),
      ("return 3.0", "3.0\n"),
      ("return -1.5E-7", "-1.5E-7\n"),
      ("return \"\"", "\n"),
      ("return missing value", "missing value\n"),
      ("return \"é ü 😀\"", "é ü 😀\n"),
      ("set x to 1", "1\n"),
      ("return", ""),
    ]
    for (source, stdout) in cases {
      XCTAssertEqual(run(source), AppleScriptOutput(status: 0, stdout: stdout, stderr: ""), source)
    }
  }

  /// No `0:0:` range when the error has no source position.
  func testErrorsPrintLikeOsascript() {
    let cases: [(String, String)] = [
      ("error \"boom\" number 42", "6:12: execution error: boom (42)\n"),
      ("error \"x\"", "6:9: execution error: x (-2700)\n"),
      ("error number 42", "0:15: execution error: An error of type 42 has occurred. (42)\n"),
      (
        "foo bar baz",
        "0:7: syntax error: A identifier can’t go after this identifier. (-2740)\n"
      ),
      (
        "return «class utf8» of \"x\"",
        "execution error: Can’t get «class utf8» of \"x\". (-1728)\n"
      ),
      (
        "error \"Notes got an error: Application isn’t running.\" number -600",
        "6:54: execution error: Notes got an error: Application isn’t running. (-600)\n"
      ),
    ]
    for (source, stderr) in cases {
      let output = run(source)
      XCTAssertEqual(output, AppleScriptOutput(status: 1, stdout: "", stderr: stderr), source)
      XCTAssertFalse(output.ok)
    }
  }

  /// The same scripts through `/usr/bin/osascript` on this Mac: every field
  /// matches, results and errors alike.
  func testOutputMatchesOsascriptOnThisMac() throws {
    let sources = [
      "return {1, \"two\", 3.5}",
      "return {a:1, b:\"x\", c:{true, missing value}}",
      "return missing value",
      "return (2 ^ 10) div 3",
      "return id of application \"Finder\"",
      "error \"x\" number 7",
      "return «class utf8» of \"x\"",
      "foo bar baz",
    ]
    for source in sources {
      XCTAssertEqual(run(source), try osascript(source), source)
    }
  }

  func testFailureAndResultTextShapeTheCallersAnswers() {
    let ok = AppleScriptOutput(status: 0, stdout: "playing\nSong\n", stderr: "")
    XCTAssertNil(ok.failure)
    XCTAssertEqual(ok.resultText, "playing\nSong")
    let failed = AppleScriptOutput(
      status: 1, stdout: "", stderr: "6:12: execution error: boom (42)\n")
    XCTAssertEqual(failed.failure, "applescript status=1 6:12: execution error: boom (42)")
    XCTAssertNil(failed.resultText)
    XCTAssertEqual(run("return 1 + 1").resultText, "2")
  }

  /// A missed deadline answers at once, and the script stops soon after, so
  /// its thread and slot are free again.
  func testMissedDeadlineTimesOutAndFreesItsSlot() {
    let started = Date()
    let output = run("repeat\nend repeat", timeout: 0.3)
    XCTAssertEqual(output.status, AppleScriptOutput.timeoutStatus)
    XCTAssertEqual(output.stderr, "applescript timed out timeout_ms=300")
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)

    let group = DispatchGroup()
    let lock = NSLock()
    var answers: [Int: String] = [:]
    for index in 0..<AppleScriptRunner.maxScriptThreads {
      DispatchQueue.global().async(group: group) {
        let output = AppleScriptRunner.run("return \(index)", timeout: 20)
        lock.lock()
        answers[index] = output.stdout
        lock.unlock()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    for index in 0..<AppleScriptRunner.maxScriptThreads {
      XCTAssertEqual(answers[index], "\(index)\n")
    }
  }

  func testLateResultsBufferedBeforeTheWaitStillTimeOut() {
    for output in [
      AppleScriptOutput(status: 0, stdout: "late\n", stderr: ""),
      AppleScriptOutput(
        status: 1, stdout: "", stderr: "0:17: execution error: User canceled. (-128)\n"),
    ] {
      let result = ScriptResult(deadline: .now())
      result.finish(output)
      XCTAssertNil(result.wait())
    }
  }

  func testTimelyResultsKeepTheirSuccessOrScriptErrorWhenWaiterResumesLate() {
    for output in [
      AppleScriptOutput(status: 0, stdout: "ok\n", stderr: ""),
      AppleScriptOutput(
        status: 1, stdout: "", stderr: "0:17: execution error: User canceled. (-128)\n"),
    ] {
      let deadline = DispatchTime.now()
      let completedAt = deadline - .milliseconds(1)
      let result = ScriptResult(deadline: deadline)
      result.finish(output, at: completedAt)
      XCTAssertEqual(result.wait(), output)
    }
  }

  func testRunawayScriptStopsAtItsDeadline() {
    let started = Date()
    let output = AppleScriptRunner.execute(
      "repeat\n  try\n    set x to 1\n  end try\nend repeat",
      control: ScriptControl(timeout: 0.2))
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(output.status, 1)
    XCTAssertTrue(output.stderr.hasSuffix("(-128)\n"), output.stderr)
  }

  func testAbandonedScriptNeverEntersTheCompiler() {
    let control = ScriptControl(timeout: 600)
    control.abandon()
    let started = Date()
    let output = AppleScriptRunner.execute("foo bar baz", control: control)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(output.status, AppleScriptOutput.timeoutStatus)
  }

  func testExpiredScriptNeverEntersTheCompiler() {
    let output = AppleScriptRunner.execute("foo bar baz", control: ScriptControl(timeout: 0))
    XCTAssertEqual(output.status, AppleScriptOutput.timeoutStatus)
  }

  /// More scripts than threads: each waits for a slot and gets its own
  /// answer.
  func testConcurrentScriptsEachGetTheirOwnResult() {
    let group = DispatchGroup()
    let lock = NSLock()
    var answers: [Int: String] = [:]
    let count = AppleScriptRunner.maxScriptThreads * 2
    for index in 0..<count {
      DispatchQueue.global().async(group: group) {
        let output = AppleScriptRunner.run("return \(index)", timeout: 30)
        lock.lock()
        answers[index] = output.stdout
        lock.unlock()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
    for index in 0..<count {
      XCTAssertEqual(answers[index], "\(index)\n")
    }
  }

  func testEventTimeoutsAreCappedByTheDeadline() {
    XCTAssertEqual(AppleScriptRunner.clampTicks(-1, remaining: 1), 61, "default timeout")
    XCTAssertEqual(AppleScriptRunner.clampTicks(-2, remaining: 1), 61, "no timeout")
    XCTAssertEqual(AppleScriptRunner.clampTicks(7200, remaining: 1), 61)
    XCTAssertEqual(AppleScriptRunner.clampTicks(30, remaining: 1), 30, "a shorter timeout stands")
    XCTAssertEqual(AppleScriptRunner.clampTicks(7200, remaining: 0.01), 1)
  }
}
