import ApplicationServices
import CoreGraphics
import Foundation
import XCTest

@testable import flash

/// Layouts saved to disk and restored on launch: the stored form of a tree,
/// the file's format, how stored windows are matched to live ones, and what
/// the engine does with a restored state.
final class TilingPersistenceTests: XCTestCase {
  private func tree(_ windows: String...) -> TilingTree<String> {
    var tree = TilingTree<String>()
    for window in windows { tree.insert(window) }
    return tree
  }

  private func identity(
    _ bundle: String = "com.example.App", number: UInt32? = nil, title: String? = nil,
    frame: CGRect? = nil
  ) -> TilingWindowIdentity {
    TilingWindowIdentity(
      bundleID: bundle, windowNumber: number,
      titleHash: title.map(TilingWindowIdentity.titleHash), frame: frame)
  }

  // MARK: The tree's stored form

  func testATreeRoundTripsThroughItsStoredForm() {
    var original = tree("a", "b", "c", "d")
    original.join("b", .right)
    original.join("d", .left)
    original.setLayout(.accordion, around: "b")
    XCTAssertTrue(original.resize("a", along: .horizontal, by: 0.2))
    XCTAssertEqual(original.shape, "h_tiles[a, v_tiles[h_accordion[b, c], d]]")
    let node = original.node
    XCTAssertEqual(node.windows, ["a", "b", "c", "d"])
    let restored = TilingTree(node)
    XCTAssertEqual(restored.shape, original.shape)
    XCTAssertEqual(restored.node, node, "weights and layouts survive")
    XCTAssertEqual(
      restored.containers[restored.root]?.weights[0] ?? 0, 1.4, accuracy: 1e-9,
      "a's share from the resize")
    XCTAssertEqual(TilingTree(TilingTreeNode.window("solo")).shape, "h_tiles[solo]")
  }

  func testDroppingWindowsFromAStoredTreeKeepsTheRestInPlace() {
    var original = tree("a", "b", "c")
    original.join("c", .left)
    let kept = original.node.compactMapWindows { $0 == "b" ? nil : $0 }
    XCTAssertEqual(kept.map(TilingTree.init)?.shape, "h_tiles[a, c]", "b's split collapses")
    let renamed = original.node.compactMapWindows { ["a": 0, "b": 1, "c": 2][$0] }
    XCTAssertEqual(renamed.map(TilingTree.init)?.shape, "h_tiles[0, v_tiles[1, 2]]")
    XCTAssertNil(TilingTreeNode.window("a").compactMapWindows { _ in nil as String? })
  }

  // MARK: The file

  private var sample: TilingPersistedState {
    var split = tree("0", "1", "2")
    split.join("1", .right)
    return TilingPersistedState(
      focusedDisplay: "MAIN", displays: ["MAIN": "1", "SIDE": "web"],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: "MAIN", tree: split.node.compactMapWindows { Int($0) }!,
          floating: [3], fullscreen: 0),
        TilingPersistedWorkspace(
          name: "web", display: "SIDE", tree: .window(4), floating: [], fullscreen: nil),
      ],
      windows: [
        identity(number: 10, title: "Alpha", frame: CGRect(x: 0, y: 0, width: 500, height: 600)),
        identity(number: 11, title: "Beta"),
        identity(number: 12),
        identity("com.example.Tool", title: "Palette"),
        identity("com.example.Browser", number: 40, title: "Docs"),
      ])
  }

  func testTheFileIsVersionedJSONWithSnakeCaseKeys() throws {
    let data = try sample.encoded()
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["version"] as? Int, 1)
    XCTAssertEqual(json["focused_display"] as? String, "MAIN")
    XCTAssertEqual(json["displays"] as? [String: String], ["MAIN": "1", "SIDE": "web"])
    let workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
    XCTAssertEqual(workspaces[0]["name"] as? String, "1")
    XCTAssertEqual(workspaces[0]["display"] as? String, "MAIN")
    XCTAssertEqual(workspaces[0]["floating"] as? [Int], [3])
    XCTAssertEqual(workspaces[0]["fullscreen"] as? Int, 0)
    let root = try XCTUnwrap(workspaces[0]["tree"] as? [String: Any])
    XCTAssertEqual(root["layout"] as? String, "tiles")
    XCTAssertEqual(root["orientation"] as? String, "horizontal")
    XCTAssertEqual(root["weights"] as? [Double], [1, 1])
    let children = try XCTUnwrap(root["children"] as? [[String: Any]])
    XCTAssertEqual(children[0]["window"] as? Int, 0)
    XCTAssertEqual(children[1]["orientation"] as? String, "vertical")
    XCTAssertEqual(workspaces[1]["tree"] as? [String: Int], ["window": 4])
    let windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
    XCTAssertEqual(windows[0]["bundle_id"] as? String, "com.example.App")
    XCTAssertEqual(windows[0]["window_number"] as? Int, 10)
    XCTAssertEqual(windows[0]["title_hash"] as? String, TilingWindowIdentity.titleHash("Alpha"))
    XCTAssertEqual(windows[0]["frame"] as? [Double], [0, 0, 500, 600])
    XCTAssertNil(windows[2]["title_hash"], "no title read: no hash")
    XCTAssertNil(windows[3]["window_number"])
    XCTAssertEqual(
      Set(windows[0].keys), ["bundle_id", "window_number", "title_hash", "frame"],
      "never a title, a path or a pid")
    XCTAssertEqual(try TilingPersistedState.decode(data), sample)
  }

  func testATitleHashIsStableAndNotTheTitle() {
    let hash = TilingWindowIdentity.titleHash("Inbox - Mail")
    XCTAssertEqual(hash.count, 16)
    XCTAssertEqual(hash, TilingWindowIdentity.titleHash("Inbox - Mail"))
    XCTAssertNotEqual(hash, TilingWindowIdentity.titleHash("Inbox - Mail "))
    XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    XCTAssertFalse(hash.contains("Inbox"))
  }

  func testMalformedFilesAreRejected() throws {
    var future = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try sample.encoded()) as? [String: Any])
    future["version"] = 2
    XCTAssertThrowsError(
      try TilingPersistedState.decode(JSONSerialization.data(withJSONObject: future)),
      "another version")
    var dangling = sample
    dangling.workspaces[1].tree = .window(9)
    XCTAssertThrowsError(try TilingPersistedState.decode(try dangling.encoded()), "no window 9")
    var twice = sample
    twice.workspaces[1].tree = .window(0)
    XCTAssertThrowsError(try TilingPersistedState.decode(try twice.encoded()), "0 tiled twice")
    var negative = sample
    negative.workspaces[1].tree = .container(
      layout: .tiles, orientation: .vertical, children: [.window(4)], weights: [-1])
    XCTAssertThrowsError(try TilingPersistedState.decode(try negative.encoded()), "weight")
    var unnamed = sample
    unnamed.workspaces[1].name = "two words"
    XCTAssertThrowsError(try TilingPersistedState.decode(try unnamed.encoded()), "name")
    XCTAssertThrowsError(try TilingPersistedState.decode(Data("{".utf8)))
  }

  func testTheStoreWritesAPrivateFileAndIgnoresGarbage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flash-tiling-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TilingLayoutStore(
      fileURL: directory.appendingPathComponent("tiling.json"))
    XCTAssertNil(store.load(), "nothing saved yet")
    store.save(sample)
    XCTAssertEqual(store.load(), sample)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    try Data("not json".utf8).write(to: store.fileURL)
    XCTAssertNil(store.load(), "a corrupt file is ignored, not trusted")
    store.remove()
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    store.remove()
  }

  // MARK: Matching stored windows to live ones

  func testWindowsMatchByNumberThenByTitleThenNearestFrame() {
    var restore = TilingRestore<String>(sample)
    XCTAssertEqual(restore.pending, 5)
    XCTAssertNil(
      restore.claim(
        "other", bundleID: "com.example.Other", windowNumber: { 10 }, title: { "Alpha" },
        frame: .zero), "another app never matches")
    var titleReads = 0
    XCTAssertEqual(
      restore.claim(
        "a", bundleID: "com.example.App", windowNumber: { 10 },
        title: {
          titleReads += 1
          return "Changed since"
        }, frame: .zero),
      TilingRestoreMatch(workspace: "1", floating: false, fullscreen: true),
      "the window number wins, whatever the title is now")
    XCTAssertEqual(titleReads, 0, "no title read when the number matched")
    XCTAssertEqual(
      restore.claim(
        "b", bundleID: "com.example.App", windowNumber: { 77 }, title: { "Beta" }, frame: .zero),
      TilingRestoreMatch(workspace: "1", floating: false, fullscreen: false),
      "a new number (the app restarted): the title hash")
    XCTAssertNil(
      restore.claim(
        "x", bundleID: "com.example.App", windowNumber: { 78 }, title: { "Alpha" },
        frame: .zero), "Alpha's entry is taken")
    XCTAssertEqual(
      restore.claim(
        "tool", bundleID: "com.example.Tool", windowNumber: { nil }, title: { "Palette" },
        frame: .zero),
      TilingRestoreMatch(workspace: "1", floating: true, fullscreen: false))
    XCTAssertNil(
      restore.claim(
        "c", bundleID: "com.example.App", windowNumber: { 79 }, title: { "Untitled" },
        frame: .zero), "an entry with neither number nor title cannot be told from a new window")
    XCTAssertEqual(restore.pending, 2)
    XCTAssertEqual(restore.projection(of: "1")?.tree.shape, "h_tiles[a, b]")
    XCTAssertEqual(restore.projection(of: "1")?.floating, ["tool"])
    XCTAssertEqual(restore.projection(of: "1")?.fullscreen, "a")
    XCTAssertEqual(restore.projection(of: "web")?.tree.shape, "h_tiles[]", "nothing matched yet")
    restore.forget("a")
    XCTAssertEqual(
      restore.projection(of: "1")?.tree.shape, "h_tiles[b]", "a left: its slot is spent")
    XCTAssertNil(restore.projection(of: "1")?.fullscreen)
    restore.close("1")
    XCTAssertNil(restore.projection(of: "1"), "closed: the live tree is its own")
    XCTAssertEqual(
      restore.claim(
        "browser", bundleID: "com.example.Browser", windowNumber: { 40 }, title: { nil },
        frame: .zero)?.workspace, "web", "a closed workspace still names where a window goes")
  }

  func testEqualTitlesPreferTheNearestStoredFrame() {
    let state = TilingPersistedState(
      focusedDisplay: nil, displays: [:],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: nil, tree: tree("0", "1").node.compactMapWindows { Int($0) }!,
          floating: [], fullscreen: nil)
      ],
      windows: [
        identity(number: 1, title: "zsh", frame: CGRect(x: 0, y: 0, width: 500, height: 600)),
        identity(number: 2, title: "zsh", frame: CGRect(x: 500, y: 0, width: 500, height: 600)),
      ])
    var restore = TilingRestore<String>(state)
    _ = restore.claim(
      "right", bundleID: "com.example.App", windowNumber: { 9 }, title: { "zsh" },
      frame: CGRect(x: 510, y: 10, width: 480, height: 580))
    _ = restore.claim(
      "left", bundleID: "com.example.App", windowNumber: { 8 }, title: { "zsh" },
      frame: CGRect(x: 0, y: 0, width: 500, height: 600))
    XCTAssertEqual(restore.projection(of: "1")?.tree.windows, ["left", "right"])
  }

  // MARK: The engine

  private let main = WindowScreenLayout(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
    usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 600), identity: "MAIN")

  private func window(
    _ key: String, in driver: TilingEngineTests.FakeDriver, number: UInt32? = nil,
    title: String? = nil, bundle: String = "com.example.App",
    subrole: String? = kAXStandardWindowSubrole as String
  ) -> TilingEngine<TilingEngineTests.FakeDriver>.Candidate {
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
    driver.frames[key] = frame
    driver.numbers[key] = number
    driver.titles[key] = title
    return .init(key: key, pid: 1, bundleID: bundle, frame: frame, subrole: subrole)
  }

  func testARestoredWorkspaceTakesItsStoredShapeAsItsWindowsArrive() throws {
    var stored = tree("0", "1", "2")
    stored.join("1", .left)
    XCTAssertTrue(stored.resize("2", along: .horizontal, by: 0.25))
    XCTAssertEqual(stored.shape, "h_tiles[v_tiles[0, 1], 2]")
    let state = TilingPersistedState(
      focusedDisplay: "MAIN", displays: ["MAIN": "2"],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: "MAIN", tree: stored.node.compactMapWindows { Int($0) }!,
          floating: [3], fullscreen: nil),
        TilingPersistedWorkspace(
          name: "2", display: "MAIN", tree: .window(4), floating: [], fullscreen: nil),
      ],
      windows: [
        identity(number: 10, title: "Alpha"), identity(number: 11, title: "Beta"),
        identity(number: 12, title: "Gamma"), identity("com.example.Tool", title: "Palette"),
        identity("com.example.Chat", number: 30, title: "Inbox"),
      ])
    let driver = TilingEngineTests.FakeDriver()
    let engine = TilingEngine(
      driver: driver, settings: TilingSettings(enabled: true, workspaces: ["1", "2"]))
    var changes = 0
    engine.layoutDidChange = { changes += 1 }
    engine.restore(state)
    engine.setScreens([main])
    XCTAssertEqual(engine.workspaces.focused, "2", "the display shows what it showed")

    engine.adopt([window("a", in: driver, number: 10), window("b", in: driver, number: 11)])
    XCTAssertEqual(engine.workspaces.workspace(of: "a"), "1")
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.shape, "v_tiles[a, b]")
    XCTAssertTrue(engine.isParked("a"), "workspace 1 is hidden behind 2")

    engine.adopt([
      window("c", in: driver, number: 99, title: "Gamma"),
      window("chat", in: driver, number: 30, bundle: "com.example.Chat"),
      window("new", in: driver, number: 50, title: "New"),
    ])
    XCTAssertEqual(
      engine.workspaces.workspaces["1"]?.tree.shape, "h_tiles[v_tiles[a, b], c]",
      "c by its title, in the stored place")
    XCTAssertEqual(engine.workspaces.workspace(of: "chat"), "2")
    XCTAssertFalse(engine.isParked("chat"), "workspace 2 is shown")
    XCTAssertEqual(
      engine.workspaces.workspaces["2"]?.tree.shape, "h_tiles[chat, new]",
      "new, unknown to the file, joins the workspace its display shows")

    engine.adopt([window("tool", in: driver, title: "Palette", bundle: "com.example.Tool")])
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.floating, ["tool"])
    XCTAssertGreaterThan(changes, 0, "every change asks to be saved")

    _ = engine.perform(.switchTo("1"))
    let root = try XCTUnwrap(engine.workspaces.workspaces["1"]?.tree)
    XCTAssertEqual(root.containers[root.root]?.weights[0] ?? 0, 0.5, accuracy: 1e-9)
    XCTAssertEqual(root.containers[root.root]?.weights[1] ?? 0, 1.5, accuracy: 1e-9, "the resize")

    let snapshot = engine.snapshot()
    XCTAssertEqual(snapshot.windows.count, 6, "the five live windows and tool; no stale entry")
    XCTAssertEqual(snapshot.displays, ["MAIN": "1"])
    XCTAssertEqual(snapshot.focusedDisplay, "MAIN")
    let one = try XCTUnwrap(snapshot.workspaces.first { $0.name == "1" })
    XCTAssertEqual(one.display, "MAIN")
    XCTAssertEqual(
      one.tree.windows.map { snapshot.windows[$0].windowNumber }, [10, 11, 99],
      "live numbers, not the file's")
    XCTAssertEqual(
      one.tree.windows.map { snapshot.windows[$0].titleHash }.compactMap { $0 },
      ["Alpha", "Beta", "Gamma"].map(TilingWindowIdentity.titleHash),
      "saved hashes survive number-only matches without extra AX title reads")
    XCTAssertEqual(
      snapshot.workspaces.first { $0.name == "2" }?.tree.windows.map {
        snapshot.windows[$0].titleHash
      }, [TilingWindowIdentity.titleHash("Inbox"), TilingWindowIdentity.titleHash("New")])
    XCTAssertEqual(one.floating.map { snapshot.windows[$0].bundleID }, ["com.example.Tool"])
    XCTAssertEqual(snapshot.windows[one.tree.windows[0]].frame, driver.frames["a"])
    XCTAssertEqual(try TilingPersistedState.decode(try snapshot.encoded()), snapshot)
  }

  func testACommandOnAWorkspaceEndsItsRestore() {
    let state = TilingPersistedState(
      focusedDisplay: nil, displays: [:],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: nil, tree: tree("0", "1", "2").node.compactMapWindows { Int($0) }!,
          floating: [], fullscreen: nil)
      ],
      windows: [
        identity(number: 10), identity(number: 11), identity(number: 12),
      ])
    let driver = TilingEngineTests.FakeDriver()
    let engine = TilingEngine(
      driver: driver, settings: TilingSettings(enabled: true, workspaces: ["1"]))
    engine.restore(state)
    engine.setScreens([main])
    engine.adopt([window("b", in: driver, number: 11), window("a", in: driver, number: 10)])
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["a", "b"], "stored order")
    engine.focus("a")
    XCTAssertEqual(engine.perform(.layout(.accordion)), .done)
    engine.adopt([window("c", in: driver, number: 12)])
    XCTAssertEqual(
      engine.workspaces.workspaces["1"]?.tree.shape, "h_accordion[a, c, b]",
      "after a command the tree is the user's: c tiles after the focused window")
  }

  func testAWindowThatLeftIsNotRestoredAgain() {
    let state = TilingPersistedState(
      focusedDisplay: nil, displays: [:],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: nil, tree: tree("0", "1").node.compactMapWindows { Int($0) }!,
          floating: [], fullscreen: nil)
      ],
      windows: [identity(number: 10), identity(number: 11)])
    let driver = TilingEngineTests.FakeDriver()
    let engine = TilingEngine(
      driver: driver, settings: TilingSettings(enabled: true, workspaces: ["1"]))
    engine.restore(state)
    engine.setScreens([main])
    engine.adopt([window("a", in: driver, number: 10)])
    engine.forget("a")
    engine.adopt([window("b", in: driver, number: 11)])
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.tree.windows, ["b"])
    XCTAssertEqual(engine.snapshot().windows.map(\.windowNumber), [11])
  }

  func testExplicitRulesOverrideARestoredWorkspaceAndFloatingState() {
    let state = TilingPersistedState(
      focusedDisplay: "MAIN", displays: ["MAIN": "1"],
      workspaces: [
        TilingPersistedWorkspace(
          name: "1", display: "MAIN", tree: .window(0), floating: [], fullscreen: nil)
      ],
      windows: [identity(number: 10)])
    let driver = TilingEngineTests.FakeDriver()
    let engine = TilingEngine(
      driver: driver,
      settings: TilingSettings(
        enabled: true, workspaces: ["1", "2"],
        rules: [TilingRule(bundleID: "com.example.App", floats: true, workspace: "2")]))
    engine.restore(state)
    engine.setScreens([main])
    engine.adopt([window("a", in: driver, number: 10)])
    XCTAssertEqual(engine.workspaces.workspace(of: "a"), "2")
    XCTAssertEqual(engine.workspaces.workspaces["1"]?.windows, [])
    XCTAssertEqual(engine.workspaces.workspaces["2"]?.floating, ["a"])
    XCTAssertNil(engine.snapshot().malformation)
  }

  func testEnablingPersistenceCapturesAlreadyManagedWindows() {
    let driver = TilingEngineTests.FakeDriver()
    var settings = TilingSettings(enabled: true, persist: false, workspaces: ["1"])
    let engine = TilingEngine(driver: driver, settings: settings)
    engine.setScreens([main])
    engine.adopt([window("a", in: driver, number: 10, title: "Alpha")])
    XCTAssertTrue(engine.snapshot().windows.isEmpty)
    settings.persist = true
    engine.update(settings)
    XCTAssertEqual(engine.snapshot().windows.map(\.windowNumber), [10])
    XCTAssertEqual(
      engine.snapshot().windows.map(\.titleHash), [TilingWindowIdentity.titleHash("Alpha")])
  }

  func testPersistIsOnByDefaultAndASwitch() {
    XCTAssertTrue(TilingSettings().persist)
    XCTAssertTrue(ConfigLoader.parse("[tiling]\nenabled = true").tiling.persist)
    XCTAssertFalse(ConfigLoader.parse("[tiling]\npersist = false").tiling.persist)
    XCTAssertEqual(
      ConfigLoader.parse("[tiling]\npersist = \"yes\"").loadingDiagnostics.map(\.message),
      ["tiling.persist must be true or false"])
  }
}
