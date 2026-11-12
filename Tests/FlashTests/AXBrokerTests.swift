import ApplicationServices
import Darwin
import XCTest

@testable import flash

final class AXBrokerTests: XCTestCase {
  private final class SnapshotClock {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1

    func read() -> DispatchTime {
      lock.lock()
      defer { lock.unlock() }
      return DispatchTime(uptimeNanoseconds: nanoseconds)
    }

    func expire() {
      lock.lock()
      nanoseconds += 5_000_000_000
      lock.unlock()
    }
  }

  func testSnapshotFailsAnUnreadableBatchWithoutReturningPartialNodes() {
    let second = AXUIElementCreateApplication(123_456)
    var reads = 0
    let broker = AXBroker(
      roots: { [$0, second] },
      readAttributes: { _, _ in
        reads += 1
        return reads == 1 ? (.success, ["AXGroup", []] as CFArray) : (.cannotComplete, nil)
      })
    let reply = brokerReply(
      broker, "host.ax_snapshot",
      ["pid": Int(getpid()), "collect": ["AXRole"], "follow": ["FlashNoSuchChildren"]],
      pluginID: "a")

    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "accessibility snapshot failed")
    XCTAssertNil(reply["nodes"])
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": 1], pluginID: "a")["error"]
        as? String,
      "stale ax handle", "an unreadable batch must discard earlier nodes' handles")
  }

  func testSnapshotRevokedDuringReadDiscardsPartialNodesAndHandles() {
    let second = AXUIElementCreateApplication(123_456)
    let third = AXUIElementCreateApplication(123_457)
    let scopeLock = NSLock()
    var current = true
    var reads = 0
    let scope = PluginHostRequestScope {
      scopeLock.lock()
      defer { scopeLock.unlock() }
      return current
    }
    let broker = AXBroker(
      roots: { [$0, second, third] },
      readAttributes: { _, _ in
        reads += 1
        if reads == 2 {
          scopeLock.lock()
          current = false
          scopeLock.unlock()
        }
        return (.success, ["AXGroup", []] as CFArray)
      })
    let reply = brokerReply(
      broker, "host.ax_snapshot",
      ["pid": Int(getpid()), "collect": ["AXRole"], "follow": ["FlashNoSuchChildren"]],
      pluginID: "a", scope: scope)

    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertNil(reply["nodes"])
    XCTAssertEqual(reads, 2, "a revoked walk must not read another root")
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": 1], pluginID: "a")["error"]
        as? String,
      "stale ax handle", "a revoked snapshot must discard earlier nodes' handles")
  }

  func testSnapshotDeadlineDiscardsPartialNodesAndHandles() {
    let clock = SnapshotClock()
    let second = AXUIElementCreateApplication(123_456)
    let third = AXUIElementCreateApplication(123_457)
    var reads = 0
    let broker = AXBroker(
      roots: { [$0, second, third] }, now: clock.read,
      readAttributes: { _, _ in
        reads += 1
        if reads == 2 { clock.expire() }
        return (.success, ["AXGroup", []] as CFArray)
      })
    let reply = brokerReply(
      broker, "host.ax_snapshot",
      ["pid": Int(getpid()), "collect": ["AXRole"], "follow": ["FlashNoSuchChildren"]],
      pluginID: "a")

    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "accessibility snapshot timed out")
    XCTAssertNil(reply["nodes"])
    XCTAssertEqual(reads, 2, "an expired walk must not read another root")
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": 1], pluginID: "a")["error"]
        as? String,
      "stale ax handle", "a failed snapshot must not leave actionable partial handles")

    let recovered = brokerReply(
      broker, "host.ax_snapshot",
      ["pid": Int(getpid()), "collect": ["AXRole"], "follow": ["FlashNoSuchChildren"]],
      pluginID: "a")
    XCTAssertEqual(recovered["ok"] as? Bool, true)
    XCTAssertEqual((recovered["nodes"] as? [[String: Any]])?.count, 3)
  }

  func testQueuedSnapshotDeadlineIncludesTimeWaitingForTheBroker() {
    let clock = SnapshotClock()
    let entered = expectation(description: "first snapshot entered")
    let firstReply = expectation(description: "first snapshot replied")
    let secondReply = expectation(description: "queued snapshot replied")
    let release = DispatchSemaphore(value: 0)
    var rootReads = 0
    let broker = AXBroker(
      roots: { app in
        rootReads += 1
        if rootReads == 1 {
          entered.fulfill()
          _ = release.wait(timeout: .now() + 5)
        }
        return [app]
      }, now: clock.read,
      readAttributes: { _, _ in (.success, ["AXGroup", []] as CFArray) })
    let params: [String: Any] = [
      "pid": Int(getpid()), "collect": ["AXRole"], "follow": ["FlashNoSuchChildren"],
    ]
    broker.handle(
      method: "host.ax_snapshot", params: params, pluginID: "a",
      scope: PluginHostRequestScope(isCurrent: { true })
    ) { _ in firstReply.fulfill() }
    wait(for: [entered], timeout: 2)
    broker.handle(
      method: "host.ax_snapshot", params: params, pluginID: "b",
      scope: PluginHostRequestScope(isCurrent: { true })
    ) { reply in
      XCTAssertEqual(reply["error"] as? String, "accessibility snapshot timed out")
      XCTAssertNil(reply["nodes"])
      secondReply.fulfill()
    }
    clock.expire()
    release.signal()
    wait(for: [firstReply, secondReply], timeout: 2)

    XCTAssertEqual(rootReads, 1, "expired queued work must not touch an AX root")
  }

  func testElementIdentityDeduplicatesEquivalentAXHandles() {
    let first = AXUIElementCreateApplication(getpid())
    let equivalent = AXUIElementCreateApplication(getpid())
    var identities = AXElementIdentitySet()

    XCTAssertTrue(identities.insert(first))
    XCTAssertFalse(identities.insert(equivalent))
  }

  // MARK: - Headless broker plumbing (handle registry, error shapes)
  //
  // Injected batch responses keep snapshots independent of real AX trees and
  // permission grants. Action tests use invalid attributes and actions only.

  /// A broker whose snapshots start at the application element.
  private func headlessBroker() -> AXBroker {
    AXBroker(
      roots: { [$0] },
      readAttributes: { _, names in
        (.success, names.map { _ in NSNull() } as CFArray)
      })
  }

  /// Synchronously collect one broker reply (the broker replies on its own
  /// serial queue).
  private func brokerReply(
    _ broker: AXBroker,
    _ method: String,
    _ params: [String: Any],
    pluginID: String,
    scope: PluginHostRequestScope = PluginHostRequestScope(isCurrent: { true })
  ) -> [String: Any] {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: method)
    broker.handle(
      method: method, params: params, pluginID: pluginID,
      scope: scope
    ) { result in
      lock.lock()
      reply = result
      lock.unlock()
      replied.fulfill()
    }
    wait(for: [replied], timeout: 10)
    lock.lock()
    defer { lock.unlock() }
    return reply
  }

  /// One-node snapshot of `pid`'s application element: nonexistent
  /// collect/follow names keep the BFS from descending and `max_nodes: 1`
  /// caps it regardless, so exactly the root registers.
  private func snapshotRootHandle(
    _ broker: AXBroker, pid: pid_t, owner: String
  ) throws -> UInt64 {
    let reply = brokerReply(
      broker, "host.ax_snapshot",
      [
        "pid": Int(pid),
        "max_nodes": 1,
        "collect": ["FlashNoSuchAttribute"],
        "follow": ["FlashNoSuchChildren"],
      ],
      pluginID: owner)
    XCTAssertEqual(reply["ok"] as? Bool, true)
    let nodes = try XCTUnwrap(reply["nodes"] as? [[String: Any]])
    XCTAssertEqual(nodes.count, 1, "max_nodes caps the BFS at exactly the root")
    let node = try XCTUnwrap(nodes.first)
    // Node encoding: opaque numeric handle + root index + attrs bag; the
    // root node carries no parent key.
    XCTAssertEqual(node["root"] as? Int, 0)
    XCTAssertNil(node["parent"])
    XCTAssertNotNil(node["attrs"] as? [String: String])
    return try XCTUnwrap((node["handle"] as? NSNumber)?.uint64Value)
  }

  func testSnapshotRejectsANonIntegerNodeCap() {
    let reply = brokerReply(
      headlessBroker(), "host.ax_snapshot", ["pid": Int(getpid()), "max_nodes": "1"],
      pluginID: "a")
    XCTAssertEqual(reply["error"] as? String, "invalid snapshot scalar params")
  }

  func testUnknownAXMethodRepliesTheCanonicalError() {
    let reply = brokerReply(AXBroker(), "host.ax_bogus", [:], pluginID: "a")
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "unknown method: host.ax_bogus")
  }

  func testUnregisteredHandlesAreStaleForPerformSetAndSelectChild() {
    let broker = AXBroker()
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": 12_345], pluginID: "a")["error"]
        as? String,
      "stale ax handle")
    XCTAssertEqual(
      brokerReply(
        broker, "host.ax_set", ["handle": 12_345, "attribute": "AXFocused", "value": true],
        pluginID: "a")["error"] as? String,
      "stale ax handle")
    XCTAssertEqual(
      brokerReply(
        broker, "host.ax_select_child", ["parent": 1, "child": 2], pluginID: "a")["error"]
        as? String,
      "stale ax handle")
  }

  /// `host.ax_set` sets boolean attributes only: any other value, or none,
  /// is rejected before the handle is looked up, live or stale.
  func testSetRejectsAnythingButABool() throws {
    let broker = headlessBroker()
    let live = try snapshotRootHandle(broker, pid: getpid(), owner: "a")
    let values: [Any?] = ["x", 1, ["nested": true], nil]
    for handle in [Int(live), 12_345] {
      for value in values {
        var params: [String: Any] = ["handle": handle, "attribute": "AXFocused"]
        params["value"] = value
        XCTAssertEqual(
          brokerReply(broker, "host.ax_set", params, pluginID: "a")["error"] as? String,
          "host.ax_set value must be a bool", "\(handle) \(String(describing: value))")
      }
    }
  }

  /// A snapshot's handles were dropped only by the next snapshot of the same
  /// app, so a quit app's elements stayed registered for the resident's
  /// life. Its termination drops them, every owner's.
  func testAQuitAppsHandlesAreDropped() throws {
    let broker = headlessBroker()
    let first = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-a")
    let second = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-b")
    broker.appTerminated(pid: getpid())
    for (handle, owner) in [(first, "owner-a"), (second, "owner-b")] {
      XCTAssertEqual(
        brokerReply(broker, "host.ax_perform", ["handle": Int(handle)], pluginID: owner)["error"]
          as? String,
        "stale ax handle", owner)
    }
  }

  func testHandlesAreScopedPerOwnerAndPurgedPerOwnerPidOnResnapshot() throws {
    let broker = headlessBroker()
    let mine = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-a")

    // Another plugin can never act on this owner's handle, even though the
    // integer is guessable.
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": Int(mine)], pluginID: "owner-b")["error"]
        as? String,
      "stale ax handle")

    // Owner B snapshotting the SAME pid must not purge owner A's handles.
    _ = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-b")
    let stillMine = brokerReply(
      broker, "host.ax_perform",
      ["handle": Int(mine), "action": "FlashNoSuchAction"], pluginID: "owner-a")
    XCTAssertNotEqual(
      stillMine["error"] as? String, "stale ax handle",
      "another owner's snapshot must not invalidate this owner's registry")
    // The bogus action fails, and per the response law the failure carries a
    // non-empty error (never a bare {"ok": false}).
    XCTAssertEqual(stillMine["ok"] as? Bool, false)
    XCTAssertEqual(stillMine["error"] as? String, "ax action failed")

    // A fresh snapshot by the same (owner, pid) supersedes the prior one:
    // the old handle is purged, the new one is live.
    let fresh = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-a")
    XCTAssertNotEqual(fresh, mine, "handles are never reused")
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": Int(mine)], pluginID: "owner-a")["error"]
        as? String,
      "stale ax handle")
    XCTAssertNotEqual(
      brokerReply(
        broker, "host.ax_perform",
        ["handle": Int(fresh), "action": "FlashNoSuchAction"], pluginID: "owner-a")["error"]
        as? String,
      "stale ax handle")
  }

  func testSelectChildRejectsHandlesFromDifferentProcesses() throws {
    let broker = headlessBroker()
    let mine = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-a")
    // launchd's application element registers headlessly too (a broker
    // rooted at the app never reads the target's tree to register the root).
    let launchd = try snapshotRootHandle(broker, pid: 1, owner: "owner-a")
    let reply = brokerReply(
      broker, "host.ax_select_child",
      ["parent": Int(mine), "child": Int(launchd)], pluginID: "owner-a")
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "ax handles belong to different processes")
  }
}
