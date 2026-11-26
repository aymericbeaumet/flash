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

  func testSnapshotOfAnUnavailableAppFailsInsteadOfReportingZeroWindows() {
    let reply = brokerReply(
      AXBroker(), "host.ax_snapshot", ["pid": Int(pid_t.max)], pluginID: "browsers")
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "accessibility snapshot failed")
    XCTAssertNil(reply["nodes"])
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
    let snapshot = PluginHostRequest.AX.snapshot(
      root: .windows(pid: getpid()), follow: ["FlashNoSuchChildren"], collect: ["AXRole"],
      pruneRoles: [], maxNodes: nil)
    broker.handle(
      snapshot, pluginID: "a", scope: PluginHostRequestScope(isCurrent: { true })
    ) { _ in firstReply.fulfill() }
    wait(for: [entered], timeout: 2)
    broker.handle(
      snapshot, pluginID: "b", scope: PluginHostRequestScope(isCurrent: { true })
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
  /// serial queue). The params decode as the dispatcher decodes them, and a
  /// call the decoder refuses answers as the dispatcher answers it.
  private func brokerReply(
    _ broker: AXBroker,
    _ method: String,
    _ params: [String: Any],
    pluginID: String,
    scope: PluginHostRequestScope = PluginHostRequestScope(isCurrent: { true })
  ) -> [String: Any] {
    let request: PluginHostRequest.AX
    do {
      guard let kind = PluginHostRequest.Method(rawValue: method),
        case .ax(let decoded) = try PluginHostRequest(kind, params: params)
      else {
        XCTFail("\(method) is not an AX broker call")
        return [:]
      }
      request = decoded
    } catch {
      return ["ok": false, "error": error.message]
    }
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: method)
    broker.handle(request, pluginID: pluginID, scope: scope) { result in
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

  // MARK: - The menu bar root

  /// File › New Tab, and Edit with nothing under it, behind an Apple menu.
  private func menuBar() -> MenuBarFixture {
    let fixture = MenuBarFixture()
    fixture.set(fixture.bar, "AXMenuBar", nil, enabled: nil, [900_001, 900_002, 900_003])
    fixture.set(900_001, "AXMenuBarItem", "Apple", [900_010])
    fixture.set(900_002, "AXMenuBarItem", "File", [900_020])
    fixture.set(900_003, "AXMenuBarItem", "Edit", enabled: false)
    fixture.set(900_010, "AXMenu", nil, [900_011])
    fixture.set(900_011, "AXMenuItem", "About This Mac")
    fixture.set(900_020, "AXMenu", nil, [900_021])
    fixture.set(900_021, "AXMenuItem", "New Tab")
    return fixture
  }

  private static let menuBarWalk: [String: Any] = [
    "root": "menu_bar", "follow": ["AXChildren"], "collect": ["AXRole", "AXTitle", "AXEnabled"],
  ]

  private func handles(_ reply: [String: Any]) throws -> [UInt64] {
    try XCTUnwrap(reply["nodes"] as? [[String: Any]]).map {
      try XCTUnwrap(($0["handle"] as? NSNumber)?.uint64Value)
    }
  }

  /// One breadth-first walk from the owner's `AXMenuBar`: the reply names
  /// the app the plugin could not, and every element costs one read.
  func testMenuBarSnapshotWalksTheMenuBarOfTheAppThatOwnsIt() throws {
    let fixture = menuBar()
    let reply = brokerReply(
      fixture.broker(), "host.ax_snapshot", Self.menuBarWalk, pluginID: "a")

    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(reply["pid"] as? Int, Int(fixture.owner))
    let nodes = try XCTUnwrap(reply["nodes"] as? [[String: Any]])
    XCTAssertEqual(
      nodes.map { ($0["attrs"] as? [String: String])?["AXTitle"] ?? "" },
      ["", "Apple", "File", "Edit", "", "", "About This Mac", "New Tab"],
      "breadth first, in menu order")
    XCTAssertEqual(
      nodes.map { ($0["attrs"] as? [String: String])?["AXRole"] ?? "" },
      [
        "AXMenuBar", "AXMenuBarItem", "AXMenuBarItem", "AXMenuBarItem", "AXMenu", "AXMenu",
        "AXMenuItem", "AXMenuItem",
      ])
    XCTAssertEqual(
      nodes.map { ($0["attrs"] as? [String: String])?["AXEnabled"] },
      [nil, "1", "1", "0", "1", "1", "1", "1"], "a flag is 1 or 0, and absent when unsaid")
    XCTAssertTrue(nodes.allSatisfy { $0["root"] as? Int == 0 }, "one root: the bar")
    let handles = try handles(reply)
    XCTAssertNil(nodes[0]["parent"])
    XCTAssertEqual(
      nodes.dropFirst().map { ($0["parent"] as? NSNumber)?.uint64Value },
      [
        handles[0], handles[0], handles[0], handles[1], handles[2], handles[4], handles[5],
      ])
    XCTAssertEqual(
      fixture.reads,
      [fixture.bar, 900_001, 900_002, 900_003, 900_010, 900_020, 900_011, 900_021],
      "one batched read per element")
  }

  func testMenuBarSnapshotHoldsTheNodeBound() throws {
    let fixture = menuBar()
    var walk = Self.menuBarWalk
    walk["max_nodes"] = 5
    let reply = brokerReply(fixture.broker(), "host.ax_snapshot", walk, pluginID: "a")
    XCTAssertEqual(try handles(reply).count, 5)
    XCTAssertEqual(fixture.reads, [fixture.bar, 900_001, 900_002, 900_003, 900_010])
  }

  /// Flash's own menus are never walked, and neither an absent owner nor an
  /// app without a menu bar is a failure: there is nothing to list.
  func testMenuBarSnapshotOfNoAppOrOfFlashItselfIsEmpty() throws {
    for owner in [getpid(), nil] {
      let fixture = menuBar()
      let reply = brokerReply(
        fixture.broker(owner: { owner }), "host.ax_snapshot", Self.menuBarWalk, pluginID: "a")
      XCTAssertEqual(reply["ok"] as? Bool, true)
      XCTAssertEqual((reply["nodes"] as? [[String: Any]])?.count, 0)
      XCTAssertNil(reply["pid"], "no app was walked")
      XCTAssertEqual(fixture.reads, [], "nothing is read")
    }
    let fixture = menuBar()
    let bare = brokerReply(
      fixture.broker(hasMenuBar: false), "host.ax_snapshot", Self.menuBarWalk, pluginID: "a")
    XCTAssertEqual(bare["ok"] as? Bool, true)
    XCTAssertEqual(bare["pid"] as? Int, Int(fixture.owner))
    XCTAssertEqual((bare["nodes"] as? [[String: Any]])?.count, 0)
  }

  /// A handle presses the element its snapshot read, for the plugin that
  /// took the snapshot alone, and a press the app refuses says so.
  func testAMenuBarHandlePressesItsElement() throws {
    let fixture = menuBar()
    let broker = fixture.broker()
    let handles = try handles(
      brokerReply(broker, "host.ax_snapshot", Self.menuBarWalk, pluginID: "a"))
    let newTab = Int(handles[7])

    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": newTab], pluginID: "b")["error"]
        as? String, "stale ax handle", "another plugin's handle")
    XCTAssertEqual(fixture.presses.count, 0)

    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": newTab], pluginID: "a")["ok"] as? Bool,
      true)
    XCTAssertEqual(fixture.presses.map(\.element), [900_021])
    XCTAssertEqual(fixture.presses.map(\.action), ["AXPress"])

    fixture.answerPresses(with: .cannotComplete)
    let refused = brokerReply(broker, "host.ax_perform", ["handle": newTab], pluginID: "a")
    XCTAssertEqual(refused["ok"] as? Bool, false)
    XCTAssertEqual(refused["error"] as? String, "ax action failed")
  }

  /// One app owns the menu bar at a time: a menu-bar snapshot supersedes the
  /// plugin's earlier one whatever app that was of, and leaves its window
  /// handles of other apps alone. A stale handle presses nothing.
  func testAMenuBarSnapshotSupersedesThePluginsEarlierOne() throws {
    let fixture = menuBar()
    var owner = fixture.owner
    let broker = fixture.broker(owner: { owner })
    let window = try snapshotRootHandle(broker, pid: 1, owner: "a")
    let first = try handles(
      brokerReply(broker, "host.ax_snapshot", Self.menuBarWalk, pluginID: "a"))
    let others = try handles(
      brokerReply(broker, "host.ax_snapshot", Self.menuBarWalk, pluginID: "b"))

    owner = 4_243
    let second = try handles(
      brokerReply(broker, "host.ax_snapshot", Self.menuBarWalk, pluginID: "a"))
    XCTAssertTrue(Set(first).isDisjoint(with: second), "handles are never reused")

    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": Int(first[7])], pluginID: "a")["error"]
        as? String, "stale ax handle")
    XCTAssertEqual(fixture.presses.count, 0, "a stale handle presses nothing")
    for (handle, plugin) in [(second[7], "a"), (others[7], "b")] {
      XCTAssertEqual(
        brokerReply(broker, "host.ax_perform", ["handle": Int(handle)], pluginID: plugin)["ok"]
          as? Bool, true, plugin)
    }
    XCTAssertNotEqual(
      brokerReply(
        broker, "host.ax_perform", ["handle": Int(window), "action": "FlashNoSuchAction"],
        pluginID: "a")["error"] as? String,
      "stale ax handle", "the window handle of another app outlives a menu-bar snapshot")

    broker.appTerminated(pid: 4_243)
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": Int(second[7])], pluginID: "a")["error"]
        as? String, "stale ax handle", "the app quit")
  }

  /// The menu bar has its own queue: a window walk that holds the window
  /// queue (a browser's, for seconds) delays neither the menu-bar walk nor
  /// a press on one of its handles.
  func testTheMenuBarNeverWaitsOnAWindowWalk() throws {
    let fixture = menuBar()
    let entered = expectation(description: "window walk entered")
    let finished = expectation(description: "window walk finished")
    let release = DispatchSemaphore(value: 0)
    let broker = fixture.broker(roots: { app in
      entered.fulfill()
      _ = release.wait(timeout: .now() + 10)
      return [app]
    })
    broker.handle(
      .snapshot(
        root: .windows(pid: 1), follow: ["FlashNoSuchChildren"], collect: [], pruneRoles: [],
        maxNodes: nil),
      pluginID: "windows", scope: PluginHostRequestScope(isCurrent: { true })
    ) { _ in finished.fulfill() }
    wait(for: [entered], timeout: 2)

    let handles = try handles(
      brokerReply(broker, "host.ax_snapshot", Self.menuBarWalk, pluginID: "a"))
    XCTAssertEqual(handles.count, 8, "walked while the window queue was held")
    XCTAssertEqual(
      brokerReply(broker, "host.ax_perform", ["handle": Int(handles[7])], pluginID: "a")["ok"]
        as? Bool, true, "pressed while the window queue was held")

    release.signal()
    wait(for: [finished], timeout: 2)
  }

  /// `root` is one of two words. The menu bar's app is the host's to name,
  /// so a pid beside it is refused; windows still need one.
  func testSnapshotRootIsWindowsOrMenuBar() {
    let broker = headlessBroker()
    func error(_ params: [String: Any]) -> String? {
      brokerReply(broker, "host.ax_snapshot", params, pluginID: "a")["error"] as? String
    }
    XCTAssertEqual(error(["root": "windows"]), "host.ax_snapshot requires pid")
    XCTAssertEqual(
      error(["root": "menu_bar", "pid": Int(getpid())]),
      "host.ax_snapshot takes no pid with root menu_bar")
    for root: Any in ["dock", "", 1, NSNull(), ["menu_bar"]] {
      XCTAssertEqual(
        error(["root": root, "pid": Int(getpid())]), "invalid host.ax_snapshot params",
        "\(root)")
    }
    XCTAssertEqual(
      brokerReply(
        broker, "host.ax_snapshot",
        ["root": "windows", "pid": Int(getpid()), "max_nodes": 1], pluginID: "a")["ok"] as? Bool,
      true, "the default root, spelled out")
    XCTAssertEqual(PluginHostRequest.AX.SnapshotRoot.names, ["windows", "menu_bar"])
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
