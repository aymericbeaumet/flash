import Darwin
import Foundation
import XCTest

@testable import flash

final class FormatCommandJobTests: XCTestCase {
  func testDrainsOutputLargerThanPipeCapacityAndKeepsFinalPartialLine() throws {
    let queue = DispatchQueue(label: "test.status-format.output")
    let completed = expectation(description: "large command drained and reaped")
    var lastLine = ""
    var job: StatusFormatCommandJob?
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue,
        argv: [
          "/usr/bin/awk", "BEGIN { for (i = 0; i < 200000; i++) printf \"x\"; printf \"\\nlast\" }",
        ],
        environment: [:], onLine: { lastLine = $0 },
        onCompletion: { status, output in
          XCTAssertEqual(status, 0)
          XCTAssertEqual(output.utf8.count, 200_005)
          XCTAssertTrue(output.hasSuffix("\nlast"))
          XCTAssertEqual(lastLine, "last")
          completed.fulfill()
        })
    }
    wait(for: [completed], timeout: 5)
    queue.sync {
      if let job {
        XCTAssertEqual(waitpid(job.processIdentifier, nil, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
      }
      job = nil
    }
  }

  func testContinuousProducerYieldsQueueAndShutdownReapsItsGroup() throws {
    let queue = DispatchQueue(label: "test.status-format.continuous")
    let output = expectation(description: "producer is running")
    var signalled = false
    var job: StatusFormatCommandJob?
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue, argv: ["/usr/bin/yes", "status"], environment: [:],
        onLine: { _ in
          if !signalled {
            signalled = true
            output.fulfill()
          }
        },
        onCompletion: { _, _ in })
    }
    wait(for: [output], timeout: 3)
    let stopped = expectation(description: "continuous producer does not starve shutdown")
    queue.async {
      if let active = job {
        XCTAssertEqual(StatusFormatCommandJob.shutdown([active]), [])
        XCTAssertEqual(waitpid(active.processIdentifier, nil, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
      }
      job = nil
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 2)
  }

  func testShutdownKillsTermIgnoringPipelineAndReapsLeaderBeforeReturning() throws {
    let queue = DispatchQueue(label: "test.status-format.pipeline")
    let ready = expectation(description: "pipeline installed TERM handlers")
    var job: StatusFormatCommandJob?
    var signalled = false
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue,
        argv: [
          "/bin/sh", "-c",
          "trap '' TERM; (trap '' TERM; while :; do printf ready; printf '\\n'; sleep 0.01; done) | (trap '' TERM; cat)",
        ],
        environment: ["PATH": "/usr/bin:/bin"],
        onLine: { _ in
          if !signalled {
            signalled = true
            ready.fulfill()
          }
        },
        onCompletion: { _, _ in })
    }
    wait(for: [ready], timeout: 3)
    queue.sync {
      guard let active = job else { return XCTFail("Missing job") }
      let started = ProcessInfo.processInfo.systemUptime
      XCTAssertEqual(StatusFormatCommandJob.shutdown([active]), [])
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.2)
      XCTAssertEqual(kill(-active.processIdentifier, 0), -1)
      XCTAssertEqual(errno, ESRCH)
      XCTAssertEqual(waitpid(active.processIdentifier, nil, WNOHANG), -1)
      XCTAssertEqual(errno, ECHILD)
      job = nil
    }
  }

  func testTimeoutTerminatesAndCompletesInsteadOfWaitingForBlockedStdout() throws {
    let queue = DispatchQueue(label: "test.status-format.timeout")
    let completed = expectation(description: "timeout completed")
    var job: StatusFormatCommandJob?
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue, argv: ["/bin/sh", "-c", "trap '' TERM; exec sleep 30"],
        environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 0.05,
        onLine: { _ in },
        onCompletion: { status, output in
          XCTAssertEqual(status, 128 + SIGKILL)
          XCTAssertEqual(output, "")
          completed.fulfill()
        })
    }
    wait(for: [completed], timeout: 2)
    queue.sync {
      XCTAssertNotNil(job)
      job = nil
    }
  }

  func testWorkingDirectoryAndEnvironmentArePassedWithoutShellInterpolation() throws {
    let queue = DispatchQueue(label: "test.status-format.environment")
    let completed = expectation(description: "argv environment and cwd")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let physicalPath = try XCTUnwrap(realpath(directory.path, nil))
    defer { free(physicalPath) }
    let expectedDirectory = String(cString: physicalPath)
    var job: StatusFormatCommandJob?
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue, argv: ["/bin/sh", "-c", "printf '%s:%s' \"$PWD\" \"$VALUE\""],
        environment: ["VALUE": "$(not a command)"], workingDirectory: directory.path,
        onLine: { _ in },
        onCompletion: { status, output in
          XCTAssertEqual(status, 0)
          XCTAssertEqual(output, expectedDirectory + ":$(not a command)")
          completed.fulfill()
        })
    }
    wait(for: [completed], timeout: 3)
    queue.sync {
      XCTAssertNotNil(job)
      job = nil
    }
  }

  func testSpawnFailureThrowsWithoutAProcess() {
    let queue = DispatchQueue(label: "test.status-format.failure")
    XCTAssertThrowsError(
      try queue.sync {
        try StatusFormatCommandJob(
          queue: queue, argv: ["/not/a/status-command"], environment: [:],
          onLine: { _ in }, onCompletion: { _, _ in })
      })
  }

  func testSuccessfulShellCompletionCleansBackgroundChildrenWithClosedStdout() throws {
    let queue = DispatchQueue(label: "test.status-format.background")
    let completed = expectation(description: "successful shell completion")
    var job: StatusFormatCommandJob?
    try queue.sync {
      job = try StatusFormatCommandJob(
        queue: queue, argv: ["/bin/sh", "-c", "sleep 30 >/dev/null 2>&1 & printf done"],
        environment: ["PATH": "/usr/bin:/bin"], onLine: { _ in },
        onCompletion: { status, output in
          XCTAssertEqual(status, 0)
          XCTAssertEqual(output, "done")
          completed.fulfill()
        })
    }
    wait(for: [completed], timeout: 3)
    queue.sync {
      guard let active = job else { return XCTFail("Missing job") }
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      while kill(-active.processIdentifier, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline
      { usleep(2_000) }
      XCTAssertEqual(kill(-active.processIdentifier, 0), -1)
      XCTAssertEqual(errno, ESRCH)
      XCTAssertEqual(waitpid(active.processIdentifier, nil, WNOHANG), -1)
      XCTAssertEqual(errno, ECHILD)
      job = nil
    }
  }
}
