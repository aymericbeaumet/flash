import AppKit
import ApplicationServices
import FlashCore
import Foundation

/// CoreFoundation equality for AX elements is stable across independently
/// created handles for the same accessibility object. Keep traversal identity
/// separate from broker handles so following both AXChildren variants does not
/// visit and register the same browser subtree repeatedly.
struct AXElementIdentitySet {
  private var identities: Set<AnyHashable> = []

  mutating func insert(_ element: AXUIElement) -> Bool {
    identities.insert(AnyHashable(element)).inserted
  }
}

/// Host-side Accessibility broker. The core holds the single TCC grant, so it
/// is the only process that may touch AX trees; this class is the only place
/// `AXUIElement` handles live. Plugins reach AX through the `host.ax_*` RPCs
/// routed here from `PluginManager.handleHostRequest`.
///
/// `AXUIElement` values cannot cross a process boundary and per-element round
/// trips over stdio are catastrophic (a browser walk visits thousands of
/// nodes), so the surface is deliberately *coarse*: one `host.ax_snapshot` call
/// walks an app's windows and returns a flat node list, each node carrying an opaque
/// integer handle plus a batch of requested attributes. The plugin applies its
/// own domain logic (what counts as a "tab") and later acts on a node by its
/// handle via `host.ax_perform` / `host.ax_set`. The registry keeps the real elements
/// resident between the snapshot and those follow-up calls.
///
/// A snapshot walks one of two trees: an app's windows, or the menu bar of
/// the app that owns it (`root: "menu_bar"`), which the broker names itself.
/// Each tree has its own serial queue, and a handle's later calls run on the
/// queue of the walk that returned it.
final class AXBroker {
  /// A snapshot must release the tree even after its plugin stopped waiting.
  /// Match the SDK's default host-call budget; queue admission counts too.
  static let snapshotTimeoutMs = 5_000

  private enum SnapshotFailure: String, Error {
    case timedOut = "accessibility snapshot timed out"
    case failed = "accessibility snapshot failed"
    case cancelled = "accessibility snapshot cancelled"
  }

  /// The tree a snapshot walked, kept on each of its handles.
  private enum Tree {
    case windows
    case menuBar
  }

  private struct Entry {
    /// Owning plugin id. Handles are integers a plugin could guess; scoping
    /// every lookup and purge to the owner keeps two accessibility-capable
    /// plugins snapshotting the same app from invalidating (or acting on)
    /// each other's handles.
    let owner: String
    let pid: pid_t
    let tree: Tree
    let element: AXUIElement
  }

  /// Serial queue of the window walks and of every call on a handle one of
  /// them returned. AX attribute calls are thread-safe and the previous
  /// in-core sources walked trees off the main thread, so the walk stays
  /// off-main.
  /// `.userInitiated`: a snapshot or a perform answers a plugin's host RPC,
  /// and the plugin's own `perform` or `hints` reply — which a keypress
  /// waits on — waits on that answer.
  private let queue = DispatchQueue(label: "flash.ax.broker", qos: .userInitiated)
  /// Serial queue of the menu-bar walks and of every call on a handle one of
  /// them returned. Its own queue, because the two trees must not wait on
  /// each other: a window walk of a browser takes up to the snapshot budget
  /// and would hold a flashlight query past its deadline, and a menu bar of
  /// a few thousand items would take its walk out of the deadline of a
  /// hint provider's window snapshot. `.userInitiated`: a flashlight query
  /// and a picked row wait on it.
  private let menuBarQueue = DispatchQueue(label: "flash.ax.broker.menubar", qos: .userInitiated)
  /// Guards the registry below, which both queues read and write.
  private let registryLock = NSLock()
  private var entries: [UInt64: Entry] = [:]
  private var nextHandle: UInt64 = 0
  /// Apps that quit since an operation last ran.
  private var terminated: Set<pid_t> = []
  /// The elements a window snapshot walks from: the app's windows. Tests
  /// substitute the application element itself, which registers without an
  /// AX grant.
  private let roots: (AXUIElement) -> [AXUIElement]
  /// The app whose menus are installed, read on the main thread.
  private let menuBarOwner: () -> pid_t?
  /// The element a menu-bar snapshot walks from: the app's `AXMenuBar`.
  private let menuBar: (AXUIElement) -> AXUIElement?
  private let now: () -> DispatchTime
  private let readAttributes: (AXUIElement, [String]) -> (AXError, CFArray?)
  private let performAction: (AXUIElement, String) -> AXError

  init(
    roots: @escaping (AXUIElement) -> [AXUIElement] = AXBroker.windows(of:),
    menuBarOwner: @escaping () -> pid_t? = AXBroker.menuBarOwner,
    menuBar: @escaping (AXUIElement) -> AXUIElement? = AXMenuBar.element(of:),
    now: @escaping () -> DispatchTime = DispatchTime.now,
    readAttributes: @escaping (AXUIElement, [String]) -> (AXError, CFArray?) = AXBroker
      .readAttributes,
    performAction: @escaping (AXUIElement, String) -> AXError = AXBroker.performAction
  ) {
    self.roots = roots
    self.menuBarOwner = menuBarOwner
    self.menuBar = menuBar
    self.now = now
    self.readAttributes = readAttributes
    self.performAction = performAction
  }

  /// An app's `AXWindows`, where a window snapshot starts.
  static func windows(of app: AXUIElement) -> [AXUIElement] {
    elementArray(app, kAXWindowsAttribute as String)
  }

  /// The app whose menus the menu bar shows. The flashlight may hold
  /// activation while a plugin asks, so the owner of the installed menus is
  /// asked for ahead of the frontmost app.
  static func menuBarOwner() -> pid_t? {
    (NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication)?
      .processIdentifier
  }

  static func performAction(_ element: AXUIElement, _ action: String) -> AXError {
    AXUIElementPerformAction(element, action as CFString)
  }

  /// Child attributes a tree walk descends through by default. Browsers expose
  /// tabs under the navigation-order list in addition to the standard children
  /// list, so both are followed.
  private static let defaultFollow = [
    kAXChildrenAttribute as String,
    "AXChildrenInNavigationOrder",
  ]
  /// The node budget of a snapshot that names none.
  static let defaultMaxNodes = 3_000

  func handle(
    _ request: PluginHostRequest.AX,
    pluginID: String,
    scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch request {
    case .snapshot(let root, let follow, let collect, let pruneRoles, let maxNodes):
      let walk = Walk(
        follow: follow.isEmpty ? Self.defaultFollow : follow, collect: collect,
        pruneRoles: pruneRoles, maxNodes: maxNodes ?? Self.defaultMaxNodes, owner: pluginID,
        deadline: now() + .milliseconds(Self.snapshotTimeoutMs))
      switch root {
      case .windows(let pid):
        scope.enqueue(on: queue) { [weak self] in
          guard let self else {
            reply(["ok": false, "error": "broker released"])
            return
          }
          self.snapshot(pid: pid, tree: .windows, walk: walk, scope: scope, reply: reply)
        }
      case .menuBar:
        menuBarSnapshot(walk, scope: scope, reply: reply)
      }
    case .perform(let handle, let action):
      perform(
        handle: handle, action: action ?? (kAXPressAction as String),
        owner: pluginID, scope: scope, reply: reply)
    case .set(let handle, let attribute, let value):
      setAttribute(
        handle: handle, attribute: attribute, flag: value,
        owner: pluginID, scope: scope, reply: reply)
    case .selectChild(let parent, let child):
      selectChild(
        parentHandle: parent, childHandle: child, owner: pluginID, scope: scope, reply: reply)
    }
  }

  // MARK: - Snapshot

  /// What one snapshot reads, and the budget it started with: queue
  /// admission counts against the deadline.
  private struct Walk {
    let follow: [String]
    let collect: [String]
    let pruneRoles: Set<String>
    let maxNodes: Int
    let owner: String
    let deadline: DispatchTime
  }

  /// `root: "menu_bar"`: the menu bar of the app that owns it. The owner is
  /// read on the main thread, a property read and nothing else; the walk
  /// runs on the menu-bar queue. Flash's own process is never walked, and no
  /// owner is an empty tree, not a failure.
  private func menuBarSnapshot(
    _ walk: Walk, scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: .main) { [weak self] in
      guard let self else {
        reply(["ok": false, "error": "broker released"])
        return
      }
      guard let pid = self.menuBarOwner(), pid != ProcessInfo.processInfo.processIdentifier
      else {
        reply(["ok": true, "nodes": [[String: Any]]()])
        return
      }
      scope.enqueue(on: self.menuBarQueue) { [weak self] in
        guard let self else {
          reply(["ok": false, "error": "broker released"])
          return
        }
        self.snapshot(pid: pid, tree: .menuBar, walk: walk, scope: scope, reply: reply)
      }
    }
  }

  /// One breadth-first walk of `pid`'s `tree`. Runs on that tree's queue.
  private func snapshot(
    pid: pid_t, tree: Tree, walk: Walk, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    let owner = walk.owner
    purge(owner: owner, pid: pid, tree: tree)
    let checkCurrent = {
      guard scope.isCurrent() else { throw SnapshotFailure.cancelled }
      guard self.now() < walk.deadline else { throw SnapshotFailure.timedOut }
    }
    do {
      try checkCurrent()
      let app = AXApp.make(pid: pid)
      var response = try withAccessibilityTree(pid: pid, tree: tree, app: app) {
        app -> [String: Any] in
        // Waiting for Gecko's process lock may have consumed the budget.
        try checkCurrent()
        var nodes: [[String: Any]] = []
        var seen = AXElementIdentitySet()
        let roots: [AXUIElement]
        switch tree {
        case .windows: roots = self.roots(app)
        case .menuBar: roots = self.menuBar(app).map { [$0] } ?? []
        }
        try checkCurrent()
        for (rootIndex, root) in roots.enumerated() {
          var bfs: [(element: AXUIElement, parent: UInt64?)] = [(root, nil)]
          var index = 0
          while index < bfs.count, nodes.count < walk.maxNodes {
            try checkCurrent()
            let item = bfs[index]
            let element = item.element
            index += 1
            guard seen.insert(element) else { continue }
            let (attrs, children) = try self.readNode(
              element, collect: walk.collect, follow: walk.follow, checkCurrent: checkCurrent)
            let handle = self.register(owner: owner, pid: pid, tree: tree, element: element)
            var node: [String: Any] = ["handle": handle, "root": rootIndex, "attrs": attrs]
            if let parent = item.parent { node["parent"] = parent }
            nodes.append(node)
            if let role = attrs[kAXRoleAttribute as String], walk.pruneRoles.contains(role) {
              continue
            }
            bfs.append(contentsOf: children.map { ($0, handle) })
          }
        }
        try checkCurrent()
        return ["ok": true, "nodes": nodes]
      }
      // The plugin did not name the app: the reply does.
      if tree == .menuBar { response["pid"] = Int(pid) }
      reply(response)
    } catch {
      purge(owner: owner, pid: pid, tree: tree)
      let failure = error as? SnapshotFailure ?? .failed
      reply(["ok": false, "error": failure.rawValue])
    }
  }

  // MARK: - Actions

  private func perform(
    handle: UInt64, action: String, owner: String, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: queue(of: handle, owner: owner)) { [weak self] in
      guard let self, let entry = self.entry(handle, owner: owner) else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      let status = self.withAccessibilityTree(pid: entry.pid, tree: entry.tree) { _ in
        self.performAction(entry.element, action)
      }
      // Response law: ok:false always carries a non-empty, content-free error.
      reply(status == .success ? ["ok": true] : ["ok": false, "error": "ax action failed"])
    }
  }

  private func setAttribute(
    handle: UInt64, attribute: String, flag: Bool, owner: String,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: queue(of: handle, owner: owner)) { [weak self] in
      guard let self, let entry = self.entry(handle, owner: owner) else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      let cfValue: CFTypeRef = flag ? kCFBooleanTrue : kCFBooleanFalse
      let status = self.withAccessibilityTree(pid: entry.pid, tree: entry.tree) { _ in
        AXUIElementSetAttributeValue(entry.element, attribute as CFString, cfValue)
      }
      // Response law: ok:false always carries a non-empty, content-free error.
      reply(status == .success ? ["ok": true] : ["ok": false, "error": "ax set failed"])
    }
  }

  private func selectChild(
    parentHandle: UInt64, childHandle: UInt64, owner: String,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: queue(of: parentHandle, owner: owner)) { [weak self] in
      guard let self,
        let parentEntry = self.entry(parentHandle, owner: owner),
        let childEntry = self.entry(childHandle, owner: owner)
      else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      guard parentEntry.pid == childEntry.pid else {
        reply(["ok": false, "error": "ax handles belong to different processes"])
        return
      }
      let status = self.withAccessibilityTree(pid: parentEntry.pid, tree: parentEntry.tree) {
        _ in
        let value = [childEntry.element] as CFArray
        return AXUIElementSetAttributeValue(
          parentEntry.element, kAXSelectedChildrenAttribute as CFString, value)
      }
      // Response law: ok:false always carries a non-empty, content-free error.
      reply(status == .success ? ["ok": true] : ["ok": false, "error": "ax select failed"])
    }
  }

  // MARK: - Registry

  /// Runs `operation` on `pid`'s tree. A window tree of a Gecko app is read
  /// under its process lock, with its accessibility mode on. The menu bar is
  /// AppKit's own in a Gecko app too: reading or pressing it takes no part
  /// in that lock, so it never waits on a hint walk nor holds one up.
  private func withAccessibilityTree<T>(
    pid: pid_t,
    tree: Tree,
    app: AXUIElement? = nil,
    _ operation: (AXUIElement) throws -> T
  ) rethrows -> T {
    guard tree == .windows else { return try operation(app ?? AXApp.make(pid: pid)) }
    return try GeckoAccessibility.withTree(
      pid: pid,
      bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
      app: app,
      operation)
  }

  /// Registers `element` and returns its handle.
  private func register(owner: String, pid: pid_t, tree: Tree, element: AXUIElement) -> UInt64 {
    registryLock.lock()
    defer { registryLock.unlock() }
    nextHandle += 1
    let handle = nextHandle
    entries[handle] = Entry(owner: owner, pid: pid, tree: tree, element: element)
    return handle
  }

  /// The element `handle` names for `owner`, nil once it is stale.
  private func entry(_ handle: UInt64, owner: String) -> Entry? {
    registryLock.lock()
    defer { registryLock.unlock() }
    dropTerminatedApps()
    guard let entry = entries[handle], entry.owner == owner else { return nil }
    return entry
  }

  /// The queue a call on `handle` runs on: the one its snapshot walked on.
  /// A handle nobody holds answers stale on either.
  private func queue(of handle: UInt64, owner: String) -> DispatchQueue {
    entry(handle, owner: owner)?.tree == .menuBar ? menuBarQueue : queue
  }

  /// `pid` quit: its elements are dead, whoever snapshotted them. Without
  /// this they would stay registered until a snapshot of the same app,
  /// which a quit app never gets. Recorded here, from any thread, and
  /// dropped by the next operation (`dropTerminatedApps`): a walk of that
  /// app still in flight registers nothing that outlives it.
  func appTerminated(pid: pid_t) {
    registryLock.lock()
    terminated.insert(pid)
    registryLock.unlock()
  }

  /// Caller holds `registryLock`, before anything else an operation reads.
  private func dropTerminatedApps() {
    guard !terminated.isEmpty else { return }
    let pids = terminated
    terminated.removeAll()
    entries = entries.filter { !pids.contains($0.value.pid) }
  }

  /// Drops the handles a snapshot of `pid`'s `tree` supersedes: the owner's
  /// earlier ones for that app, and for a menu bar its earlier menu-bar
  /// handles of every app, since one app owns the bar at a time. A fresh
  /// snapshot supersedes the prior one, so the old handles can never be
  /// acted on again — this keeps the registry from growing without bound.
  private func purge(owner: String, pid: pid_t, tree: Tree) {
    registryLock.lock()
    defer { registryLock.unlock() }
    dropTerminatedApps()
    // Scoped to the owner: a fresh snapshot invalidates only the caller's
    // own handles, never another plugin's.
    entries = entries.filter { _, entry in
      guard entry.owner == owner else { return true }
      return !(entry.pid == pid || (tree == .menuBar && entry.tree == .menuBar))
    }
  }

  // MARK: - AX reads

  /// Reads a node's `collect` (string) attributes and `follow` (child element
  /// arrays) in a *single* `AXUIElementCopyMultipleAttributeValues` IPC round
  /// trip. Each AX attribute read is an IPC to the target app; the snapshot
  /// walk visits thousands of nodes, so collapsing the former per-attribute
  /// copies (~8 `collect` + ~2 `follow` ≈ 10 IPC hops per node) into one call
  /// is the dominant cost saving for a tree walk. Options is the empty set, so
  /// an unreadable attribute yields an `AXError` placeholder in its slot rather
  /// than aborting the batch; those slots coerce to "absent", preserving the
  /// prior per-attribute semantics.
  private func readNode(
    _ element: AXUIElement, collect: [String], follow: [String],
    checkCurrent: () throws -> Void
  ) throws -> (attrs: [String: String], children: [AXUIElement]) {
    let names = collect + follow
    guard !names.isEmpty else { return ([:], []) }
    let (status, raw) = readAttributes(element, names)
    try checkCurrent()
    // Retrying every attribute after a timeout multiplies the same unresponsive
    // app's wait while holding the Gecko lock that hint discovery also needs.
    guard status != .cannotComplete else { throw SnapshotFailure.failed }
    guard status == .success, let values = raw as? [Any], values.count == names.count else {
      // Wholesale failure (rare — a bad element). Fall back to per-attribute
      // copies so one unreadable attribute can't blank the whole node.
      var attrs: [String: String] = [:]
      for name in collect {
        try checkCurrent()
        if let text = attribute(element, name) { attrs[name] = text }
        try checkCurrent()
      }
      var children: [AXUIElement] = []
      for name in follow {
        try checkCurrent()
        children.append(contentsOf: Self.elementArray(element, name))
        try checkCurrent()
      }
      return (attrs, children)
    }
    var attrs: [String: String] = [:]
    for (offset, name) in collect.enumerated() {
      if let text = coerce(values[offset]) { attrs[name] = text }
    }
    var children: [AXUIElement] = []
    let followBase = collect.count
    for offset in follow.indices {
      if let elems = values[followBase + offset] as? [AXUIElement] {
        children.append(contentsOf: elems)
      }
    }
    return (attrs, children)
  }

  private static func elementArray(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let values = raw as? [AXUIElement]
    else { return [] }
    return values
  }

  static func readAttributes(_ element: AXUIElement, _ names: [String]) -> (AXError, CFArray?) {
    var raw: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, names as CFArray, AXCopyMultipleAttributeOptions(), &raw)
    return (status, raw)
  }

  /// Reads `name` and coerces it to a string. Used only on the rare batched-read
  /// failure fallback in `readNode`.
  private func attribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return coerce(value)
  }

  /// Coerces an AX attribute value to a string. Handles the value types the
  /// migrated sources need: plain strings, URLs (as `absoluteString`), and
  /// numbers. Anything else (including `AXError` placeholders) is absent.
  private func coerce(_ value: Any) -> String? {
    if let text = value as? String { return text }
    if let url = value as? URL { return url.absoluteString }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

}
