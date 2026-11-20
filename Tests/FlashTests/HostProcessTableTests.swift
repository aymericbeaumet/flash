import Darwin
import XCTest

@testable import flash

/// The host's process table (`host.process_table`): what a list and a tree
/// hold, how a reply is bounded, and what the kernel is asked. Every kernel
/// here is scripted, except where the live one reads this test runner and a
/// child it spawned.
final class HostProcessTableTests: XCTestCase {
  private func table(_ kernel: any ProcessKernel) -> HostProcessTable {
    HostProcessTable(kernel: kernel)
  }

  private func json(_ value: Any) -> NSDictionary {
    value as? NSDictionary ?? [:]
  }

  // MARK: - list

  func testAListIsEveryProcessTheUserMayMeasureInTheKernelsOrder() {
    let kernel = ProcessKernelStub.corpus()
    let snapshot = table(kernel).list(pids: nil)
    XCTAssertEqual(snapshot.at, 90_000_000_000)
    XCTAssertEqual(snapshot.processes.map(\.pid), [4242, 4243, 4300], "launchd is root's")
    XCTAssertEqual(snapshot.processes.map(\.name), [nil, nil, nil], "a sweep reads no name")
    XCTAssertEqual(snapshot.processes[0].usage.cpuNs, 1_500_000_000)
    XCTAssertEqual(snapshot.processes[0].usage.residentBytes, 268_435_456)
    XCTAssertEqual(snapshot.processes[0].usage.startAbstime, 77_000)
    XCTAssertNil(snapshot.processes[0].detail, "a list carries no detail")
    XCTAssertNil(snapshot.path)
    XCTAssertNil(snapshot.startedAt)
    XCTAssertFalse(snapshot.truncated)

    XCTAssertEqual(
      json(HostProcessTable.wire(snapshot)),
      [
        "ok": true, "at": 90_000_000_000,
        "processes": [
          [
            "pid": 4242, "start": 77_000, "cpu_ns": 1_500_000_000,
            "resident_bytes": 268_435_456,
          ],
          ["pid": 4243, "start": 78_000, "cpu_ns": 250_000_000, "resident_bytes": 67_108_864],
          ["pid": 4300, "start": 90_000, "cpu_ns": 20_000_000, "resident_bytes": 4_194_304],
        ],
      ] as NSDictionary)
  }

  /// What the kernel is asked for a list: the clock, the pid list and one
  /// usage per process, and no path, which is the costly read of a sweep.
  /// Nothing else exists to ask: the seam has no way to read a process's
  /// arguments or environment.
  func testAListOfTheWholeTableAsksTheKernelForUsageAlone() {
    let kernel = ProcessKernelStub.corpus()
    _ = table(kernel).list(pids: nil)
    XCTAssertEqual(
      kernel.questions, ["now", "pids", "usage 1", "usage 4242", "usage 4243", "usage 4300"])
  }

  func testAListOfPidsIsOnlyThoseInTheOrderAskedEachWithItsName() {
    let kernel = ProcessKernelStub.corpus()
    let snapshot = table(kernel).list(pids: [4300, 9999, 1, 4242])
    XCTAssertEqual(snapshot.processes.map(\.pid), [4300, 4242], "gone and root's are left out")
    XCTAssertEqual(snapshot.processes.map(\.name), ["zsh", "Safari"])
    XCTAssertEqual(
      kernel.questions,
      [
        "now", "usage 4300", "path 4300", "usage 9999", "usage 1", "usage 4242", "path 4242",
      ], "the pid list is not read, and a path only of a process it may measure")
    XCTAssertEqual(table(kernel).list(pids: []).processes, [])
  }

  func testAProcessWithoutAReadablePathHasNoName() {
    let kernel = ProcessKernelStub()
    kernel.spawn(10, path: nil, start: 100)
    kernel.spawn(11, path: "/", start: 110)
    kernel.spawn(12, path: "/usr/bin/" + String(repeating: "n", count: 256), start: 120)
    kernel.spawn(13, path: "/Applications/A.app/Contents/MacOS/A/", start: 130)
    let snapshot = table(kernel).list(pids: [10, 11, 12, 13])
    XCTAssertEqual(snapshot.processes.map(\.name), [nil, nil, nil, "A"])
    XCTAssertNil(HostProcessTable.wire(snapshot.processes[0])["name"])

    XCTAssertEqual(
      HostProcessTable.name(ofExecutable: "/Applications/Safari.app/Contents/MacOS/Safari"),
      "Safari")
    XCTAssertEqual(HostProcessTable.name(ofExecutable: "zsh"), "zsh")
    XCTAssertNil(HostProcessTable.name(ofExecutable: "/"))
    XCTAssertNil(HostProcessTable.name(ofExecutable: ""))
    XCTAssertEqual(
      HostProcessTable.name(ofExecutable: "/bin/" + String(repeating: "é", count: 127))?.utf8
        .count, 254)
    XCTAssertNil(HostProcessTable.name(ofExecutable: "/bin/" + String(repeating: "é", count: 128)))
  }

  // MARK: - tree

  func testATreeIsTheRootAndEveryReachableDescendantWithTheirDetail() {
    let kernel = ProcessKernelStub.corpus()
    kernel.spawn(4250, parent: 4243, path: "/usr/libexec/helper", start: 79_000) {
      $0.threads = 2
    }
    kernel.spawn(4244, parent: 4242, path: "/usr/libexec/second", start: 78_500)
    let snapshot = table(kernel).tree(root: 4242)
    XCTAssertEqual(
      snapshot.processes.map(\.pid), [4242, 4243, 4244, 4250],
      "breadth first: the root, its children, then theirs")
    XCTAssertEqual(snapshot.processes.map(\.detail?.threads), [12, 5, 1, 2])
    XCTAssertEqual(snapshot.processes.map(\.detail?.sockets), [3, 1, 0, 0])
    XCTAssertEqual(snapshot.path, "/Applications/Safari.app/Contents/MacOS/Safari")
    XCTAssertEqual(snapshot.startedAt, 1_799_996_400)
    XCTAssertFalse(snapshot.processes.map(\.pid).contains(4300), "an unrelated process")

    let root = HostProcessTable.wire(snapshot.processes[0])
    XCTAssertEqual(
      json(root),
      [
        "pid": 4242, "start": 77_000, "cpu_ns": 1_500_000_000, "resident_bytes": 268_435_456,
        "name": "Safari", "threads": 12, "sockets": 3, "disk_read_bytes": 4_096,
        "disk_write_bytes": 8_192,
      ] as NSDictionary)
  }

  func testATreeOfAProcessThatIsGoneOrNotTheUsersHoldsNothing() {
    let kernel = ProcessKernelStub.corpus()
    for root: pid_t in [9999, 1] {
      let snapshot = table(kernel).tree(root: root)
      XCTAssertEqual(snapshot.processes, [], "\(root)")
      XCTAssertNil(snapshot.path, "\(root)")
      XCTAssertNil(snapshot.startedAt, "\(root)")
      XCTAssertEqual(
        json(HostProcessTable.wire(snapshot)),
        ["ok": true, "at": 90_000_000_000, "processes": [Any]()] as NSDictionary)
    }
    XCTAssertEqual(
      kernel.questions, ["now", "usage 9999", "now", "usage 1"], "nothing else is read of them")
  }

  /// A descendant another user owns is walked through, since its children
  /// may be the user's, and is not listed.
  func testATreeSkipsADescendantItMayNotMeasure() {
    let kernel = ProcessKernelStub()
    kernel.spawn(40, path: "/Applications/Web.app/Contents/MacOS/Web", start: 400)
    kernel.spawn(41, parent: 40, path: "/usr/bin/login", start: 410) { $0.measurable = false }
    kernel.spawn(42, parent: 41, path: "/bin/zsh", start: 420)
    XCTAssertEqual(table(kernel).tree(root: 40).processes.map(\.pid), [40, 42])
  }

  // MARK: - bounds

  /// The byte count of a reply is arithmetic, never a second encoding: it
  /// equals what the encoder writes, whatever a name holds.
  func testTheCountedBytesOfAProcessAreItsCompactEncoding() throws {
    let names: [String?] = [
      nil, "zsh", "com.apple.WebKit.WebContent", "quote\"back\\slash/", "tab\tline\nfeed\u{0C}",
      "bell\u{07}null\u{00}esc\u{1B}", "del\u{7F}", "é🦀\u{2028}\u{2029}", "",
    ]
    let figures: [UInt64] = [0, 9, 10, 1_500_000_000, UInt64(Int64.max)]
    for name in names {
      for figure in figures {
        for detail in [nil, HostProcessTable.Process.Detail(threads: 12, sockets: 0)] {
          let process = HostProcessTable.Process(
            pid: 4242,
            usage: ProcessUsage(
              cpuNs: figure, residentBytes: figure, diskReadBytes: figure, diskWriteBytes: 7,
              startAbstime: figure),
            name: name, detail: detail)
          XCTAssertEqual(
            HostProcessTable.encodedBytes(process),
            try XCTUnwrap(PluginJSON.encodedBytes(HostProcessTable.wire(process))),
            "\(String(describing: name)) \(figure)")
        }
      }
    }
  }

  func testAReplyHoldsAtMostTheContractsProcessesAndBytes() throws {
    let kernel = ProcessKernelStub()
    for pid in 1...pid_t(HostProcessTable.maxProcesses + 3) {
      kernel.spawn(pid + 100, path: "/bin/p", start: UInt64(pid))
    }
    let counted = table(kernel).list(pids: nil)
    XCTAssertEqual(counted.processes.count, HostProcessTable.maxProcesses)
    XCTAssertTrue(counted.truncated)
    XCTAssertEqual(counted.processes.last?.pid, pid_t(HostProcessTable.maxProcesses) + 100)
    XCTAssertEqual(json(HostProcessTable.wire(counted))["truncated"] as? Bool, true)
    XCTAssertNil(
      HostProcessTable.wire(table(ProcessKernelStub.corpus()).list(pids: nil))["truncated"])

    // Names as long as a name may be, each character six bytes encoded:
    // the bytes run out before the count does.
    let heavy = ProcessKernelStub()
    let name = String(repeating: "\u{01}", count: HostProcessTable.maxNameBytes)
    for pid in 1...2_000 as ClosedRange<pid_t> {
      heavy.spawn(pid + 100, path: "/bin/" + name, start: UInt64(pid))
    }
    let weighed = table(heavy).list(pids: Array(101...2_100))
    XCTAssertTrue(weighed.truncated)
    XCTAssertLessThan(weighed.processes.count, 2_000)
    let rows = weighed.processes.map(HostProcessTable.wire)
    let bytes = try XCTUnwrap(PluginJSON.encodedBytes(rows))
    XCTAssertLessThanOrEqual(bytes, HostProcessTable.maxReplyBytes)
    let one = try XCTUnwrap(PluginJSON.encodedBytes(rows[0]))
    XCTAssertGreaterThan(bytes + one + 1, HostProcessTable.maxReplyBytes, "one more would not fit")

    // A tree is bounded the same way.
    let wide = ProcessKernelStub()
    wide.spawn(50, path: "/bin/root", start: 5)
    for pid in 1...pid_t(HostProcessTable.maxProcesses + 3) {
      wide.spawn(pid + 100, parent: 50, path: "/bin/p", start: UInt64(pid))
    }
    let tree = table(wide).tree(root: 50)
    XCTAssertEqual(tree.processes.count, HostProcessTable.maxProcesses)
    XCTAssertTrue(tree.truncated)
    XCTAssertEqual(tree.processes.first?.pid, 50)
  }

  // MARK: - the live kernel

  private func spawnChild() throws -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["600"]
    try child.run()
    addTeardownBlock {
      child.terminate()
      child.waitUntilExit()
    }
    return child
  }

  /// libproc, on the two processes a test may read: this test runner and a
  /// child it spawned.
  func testTheLiveKernelReadsThisProcessAndAChildItSpawned() throws {
    let child = try spawnChild()
    let own = getpid()
    let kernel = LibprocKernel()
    let usage = try XCTUnwrap(kernel.usage(of: own))
    XCTAssertGreaterThan(usage.residentBytes, 0)
    XCTAssertGreaterThan(usage.startAbstime, 0)
    XCTAssertGreaterThan(usage.cpuNs, 0)
    XCTAssertEqual(try XCTUnwrap(kernel.path(of: own)).first, "/")
    XCTAssertGreaterThanOrEqual(kernel.threadCount(of: own), 1)
    XCTAssertGreaterThanOrEqual(kernel.socketCount(of: own), 0)
    let started = try XCTUnwrap(kernel.startTime(of: own))
    XCTAssertLessThan(abs(Date().timeIntervalSince1970 - TimeInterval(started)), 86_400)
    XCTAssertTrue(kernel.children(of: own).contains(child.processIdentifier))
    XCTAssertEqual(kernel.path(of: child.processIdentifier), "/bin/sleep")
    let before = kernel.now()
    XCTAssertGreaterThanOrEqual(kernel.now(), before)

    let gone = pid_t(Int32.max - 1)
    XCTAssertNil(kernel.usage(of: gone))
    XCTAssertNil(kernel.path(of: gone))
    XCTAssertNil(kernel.startTime(of: gone))
    XCTAssertEqual(kernel.threadCount(of: gone), 0)
    XCTAssertEqual(kernel.socketCount(of: gone), 0)
    XCTAssertEqual(kernel.children(of: gone), [])
  }

  func testTheLiveTableListsThisProcessAndSumsItsTree() throws {
    let child = try spawnChild()
    let own = getpid()
    let table = table(OwnProcessKernel(children: [child]))
    let list = table.list(pids: nil)
    XCTAssertEqual(Set(list.processes.map(\.pid)), [own, child.processIdentifier])
    XCTAssertGreaterThan(list.at, 0)
    XCTAssertEqual(table.list(pids: [child.processIdentifier]).processes.map(\.name), ["sleep"])

    let tree = table.tree(root: own)
    XCTAssertEqual(tree.processes.map(\.pid), [own, child.processIdentifier])
    XCTAssertGreaterThanOrEqual(tree.processes[0].detail?.threads ?? 0, 1)
    XCTAssertEqual(tree.processes[1].detail?.threads, 1)
    XCTAssertEqual(tree.path, LibprocKernel().path(of: own))
    XCTAssertNotNil(tree.startedAt)
  }
}
