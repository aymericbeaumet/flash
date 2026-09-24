import Foundation
import XCTest

@testable import flash

final class PluginInstallJobTests: XCTestCase {
  func testReplacementInstallWaitsForCancelledProcessGroupToExit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flash-install-lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstDone = expectation(description: "old installer reaped")
    let first = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "trap '' TERM; echo $$ > first_pid; /bin/sleep 30 & wait"],
      environment: [:], workingDirectory: root.path, timeoutSeconds: 30, completionQueue: .main
    ) { output in
      XCTAssertTrue(output.cancelled)
      firstDone.fulfill()
    }
    waitUntilTrue("first install owns root") {
      FileManager.default.fileExists(atPath: root.appendingPathComponent("first_pid").path)
    }
    first.cancel()
    let secondDone = expectation(description: "replacement installer completes")
    let second = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "if kill -0 $(cat first_pid) 2>/dev/null; then exit 93; fi"],
      environment: [:], workingDirectory: root.path, timeoutSeconds: 3, completionQueue: .main
    ) { output in
      XCTAssertEqual(
        output.status, 0, "replacement entered the root while cancelled installer was still writing"
      )
      secondDone.fulfill()
    }
    withExtendedLifetime((first, second)) { wait(for: [firstDone, secondDone], timeout: 4) }
  }

  func testBothPipesDrainBeyondRetentionLimitsWithoutDeadlock() throws {
    let done = expectation(description: "install completes")
    let job = try PluginInstallJob(
      argv: [
        "/bin/sh", "-c",
        "/usr/bin/head -c 5242880 /dev/zero; /usr/bin/head -c 524288 /dev/zero >&2",
      ],
      environment: [:], workingDirectory: "/tmp", timeoutSeconds: 5, completionQueue: .main
    ) { output in
      XCTAssertEqual(output.status, 0)
      XCTAssertFalse(output.timedOut)
      XCTAssertEqual(output.stdout.count, PluginInstallJob.stdoutLimit)
      XCTAssertEqual(output.stderr.count, PluginInstallJob.stderrLimit)
      done.fulfill()
    }
    withExtendedLifetime(job) { wait(for: [done], timeout: 8) }
  }

  func testCancellingQueuedInstallSettlesWithoutSpawningIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flash-install-queued-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstDone = expectation(description: "root owner exits")
    let first = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "echo started > first_started; /bin/sleep 30"],
      environment: [:], workingDirectory: root.path, timeoutSeconds: 30, completionQueue: .main
    ) { _ in firstDone.fulfill() }
    waitUntilTrue("first installer spawned") {
      FileManager.default.fileExists(atPath: root.appendingPathComponent("first_started").path)
    }
    let queuedDone = expectation(description: "queued cancellation settles")
    let queued = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "touch should_not_exist"],
      environment: [:], workingDirectory: root.path, timeoutSeconds: 3, completionQueue: .main
    ) { output in
      XCTAssertTrue(output.cancelled)
      queuedDone.fulfill()
    }
    queued.cancel()
    wait(for: [queuedDone], timeout: 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("should_not_exist").path))
    first.cancel()
    withExtendedLifetime((first, queued)) { wait(for: [firstDone], timeout: 3) }
  }

  func testTimeoutKillsIgnoringShellAndDescendantHoldingPipes() throws {
    let done = expectation(description: "bounded escalation")
    let started = ProcessInfo.processInfo.systemUptime
    let job = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "trap '' TERM; /bin/sleep 30 & wait"],
      environment: [:], workingDirectory: "/tmp", timeoutSeconds: 0.1, completionQueue: .main
    ) { output in
      XCTAssertTrue(output.timedOut)
      XCTAssertNotEqual(output.status, 0)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
      done.fulfill()
    }
    withExtendedLifetime(job) { wait(for: [done], timeout: 3) }
  }

  func testCancellationSettlesOnceWithoutBlockingCaller() throws {
    let done = expectation(description: "cancelled")
    done.assertForOverFulfill = true
    let job = try PluginInstallJob(
      argv: ["/bin/sh", "-c", "trap '' TERM; /bin/sleep 30 & wait"],
      environment: [:], workingDirectory: "/tmp", timeoutSeconds: 30, completionQueue: .main
    ) { output in
      XCTAssertTrue(output.cancelled)
      done.fulfill()
    }
    let started = ProcessInfo.processInfo.systemUptime
    job.cancel()
    job.cancel()
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1)
    withExtendedLifetime(job) { wait(for: [done], timeout: 3) }
  }
}
