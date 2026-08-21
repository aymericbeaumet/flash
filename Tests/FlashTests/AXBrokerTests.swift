import ApplicationServices
import Darwin
import XCTest

@testable import flash

final class AXBrokerTests: XCTestCase {
  func testElementIdentityDeduplicatesEquivalentAXHandles() {
    let first = AXUIElementCreateApplication(getpid())
    let equivalent = AXUIElementCreateApplication(getpid())
    var identities = AXElementIdentitySet()

    XCTAssertTrue(identities.insert(first))
    XCTAssertFalse(identities.insert(equivalent))
  }

  // MARK: - Headless broker plumbing (handle registry, error shapes)
  //
  // These tests stay off real AX trees: `roots: "app"` snapshots register the
  // application element itself without needing a granted AX permission, and
  // bogus collect/follow attribute names keep the walk from descending, so
  // node counts are deterministic on any machine. Anything that needs a real
  // tree (attribute values, geometry) is deliberately out of scope here.

  /// Synchronously collect one broker reply (the broker replies on its own
  /// serial queue).
  private func brokerReply(
    _ broker: AXBroker,
    _ method: String,
    _ params: [String: Any],
    pluginID: String
  ) -> [String: Any] {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: method)
    broker.handle(method: method, params: params, pluginID: pluginID) { result in
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
        "roots": "app",
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
        broker, "host.ax_set", ["handle": 12_345, "attribute": "AXValue", "value": "x"],
        pluginID: "a")["error"] as? String,
      "stale ax handle")
    XCTAssertEqual(
      brokerReply(
        broker, "host.ax_select_child", ["parent": 1, "child": 2], pluginID: "a")["error"]
        as? String,
      "stale ax handle")
  }

  func testHandlesAreScopedPerOwnerAndPurgedPerOwnerPidOnResnapshot() throws {
    let broker = AXBroker()
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
    let broker = AXBroker()
    let mine = try snapshotRootHandle(broker, pid: getpid(), owner: "owner-a")
    // launchd's application element registers headlessly too (`roots: "app"`
    // never reads the target's tree just to register the root).
    let launchd = try snapshotRootHandle(broker, pid: 1, owner: "owner-a")
    let reply = brokerReply(
      broker, "host.ax_select_child",
      ["parent": Int(mine), "child": Int(launchd)], pluginID: "owner-a")
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "ax handles belong to different processes")
  }
}
