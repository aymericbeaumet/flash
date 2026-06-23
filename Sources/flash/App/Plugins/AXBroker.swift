import AppKit
import ApplicationServices
import FlashCore
import Foundation

/// Host-side Accessibility broker. The core holds the single TCC grant, so it
/// is the only process that may touch AX trees; this class is the only place
/// `AXUIElement` handles live. Plugins reach AX through the `ax.*` host RPCs
/// routed here from `PluginManager.handleHostRequest`.
///
/// `AXUIElement` values cannot cross a process boundary and per-element round
/// trips over stdio are catastrophic (a browser walk visits thousands of
/// nodes), so the surface is deliberately *coarse*: one `ax.snapshot` call
/// walks a subtree and returns a flat node list, each node carrying an opaque
/// integer handle plus a batch of requested attributes. The plugin applies its
/// own domain logic (what counts as a "tab") and later acts on a node by its
/// handle via `ax.perform` / `ax.set`. The registry keeps the real elements
/// resident between the snapshot and those follow-up calls.
final class AXBroker {
  private struct Entry {
    let pid: pid_t
    let element: AXUIElement
  }

  /// Serial queue guarding the handle registry and serializing AX reads. AX
  /// attribute calls are thread-safe and the previous in-core sources walked
  /// trees off the main thread, so the walk stays off-main.
  private let queue = DispatchQueue(label: "flash.ax.broker")
  private var entries: [UInt64: Entry] = [:]
  private var nextHandle: UInt64 = 0

  /// Child attributes a tree walk descends through by default. Browsers expose
  /// tabs under the navigation-order list in addition to the standard children
  /// list, so both are followed.
  private static let defaultFollow = [
    kAXChildrenAttribute as String,
    "AXChildrenInNavigationOrder",
  ]

  func handle(
    method: String,
    params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch method {
    case "ax.snapshot":
      snapshot(params, reply: reply)
    case "ax.perform":
      perform(params, reply: reply)
    case "ax.set":
      setAttribute(params, reply: reply)
    case "ax.select_child":
      selectChild(params, reply: reply)
    case "ax.click":
      click(params, reply: reply)
    case "ax.click_point":
      clickPoint(params, reply: reply)
    default:
      reply(["ok": false, "error": "unknown ax method: \(method)"])
    }
  }

  // MARK: - Snapshot

  private func snapshot(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let pid = pidParam(params, key: "pid") else {
      reply(["ok": false, "error": "ax.snapshot requires pid"])
      return
    }
    let rootsMode = params["roots"] as? String ?? "windows"
    let follow =
      (params["follow"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.defaultFollow
    let collect = params["collect"] as? [String] ?? []
    let pruneRoles = Set(params["prune_roles"] as? [String] ?? [])
    let maxNodes = params["max_nodes"] as? Int ?? 3_000
    let geometry = params["geometry"] as? Bool ?? false

    queue.async { [weak self] in
      guard let self else {
        reply(["ok": false, "error": "broker released"])
        return
      }
      self.purge(pid: pid)
      // Y-flip reference: AX reports top-left origins, NSScreen is
      // bottom-left. Resolved once per snapshot so every node's frame uses
      // the same basis. Only needed when geometry is requested.
      let screenH = geometry ? self.primaryScreenHeight() : 0
      let app = AXUIElementCreateApplication(pid)
      let roots: [AXUIElement]
      switch rootsMode {
      case "app":
        roots = [app]
      default:
        roots = self.elementArray(app, kAXWindowsAttribute as String)
      }
      var nodes: [[String: Any]] = []
      for (rootIndex, root) in roots.enumerated() {
        var bfs: [(element: AXUIElement, parent: UInt64?)] = [(root, nil)]
        var index = 0
        while index < bfs.count, nodes.count < maxNodes {
          let item = bfs[index]
          let element = item.element
          index += 1
          let handle = self.register(pid: pid, element: element)
          let (attrs, children, frame) = self.readNode(
            element, collect: collect, follow: follow,
            geometry: geometry, screenH: screenH)
          var node: [String: Any] = ["handle": handle, "root": rootIndex, "attrs": attrs]
          if let parent = item.parent { node["parent"] = parent }
          if let frame { node["frame"] = frame }
          nodes.append(node)
          if let role = attrs[kAXRoleAttribute as String], pruneRoles.contains(role) {
            continue
          }
          bfs.append(contentsOf: children.map { ($0, handle) })
        }
      }
      reply(["ok": true, "nodes": nodes])
    }
  }

  // MARK: - Actions

  private func perform(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let handle = handleParam(params) else {
      reply(["ok": false, "error": "ax.perform requires handle"])
      return
    }
    let action = params["action"] as? String ?? (kAXPressAction as String)
    queue.async { [weak self] in
      guard let entry = self?.entries[handle] else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      let status = AXUIElementPerformAction(entry.element, action as CFString)
      reply(["ok": status == .success])
    }
  }

  private func setAttribute(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let handle = handleParam(params), let attribute = params["attribute"] as? String else {
      reply(["ok": false, "error": "ax.set requires handle and attribute"])
      return
    }
    let value = params["value"]
    queue.async { [weak self] in
      guard let entry = self?.entries[handle] else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      let cfValue: CFTypeRef
      if let flag = value as? Bool {
        cfValue = flag ? kCFBooleanTrue : kCFBooleanFalse
      } else if let text = value as? String {
        cfValue = text as CFString
      } else {
        reply(["ok": false, "error": "ax.set value must be a bool or string"])
        return
      }
      let status = AXUIElementSetAttributeValue(entry.element, attribute as CFString, cfValue)
      reply(["ok": status == .success])
    }
  }

  private func selectChild(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let parentHandle = uint64Param(params["parent"]),
      let childHandle = uint64Param(params["child"])
    else {
      reply(["ok": false, "error": "ax.select_child requires parent and child"])
      return
    }
    queue.async { [weak self] in
      guard let self,
        let parentEntry = self.entries[parentHandle],
        let childEntry = self.entries[childHandle]
      else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      guard parentEntry.pid == childEntry.pid else {
        reply(["ok": false, "error": "ax handles belong to different processes"])
        return
      }
      let value = [childEntry.element] as CFArray
      let status = AXUIElementSetAttributeValue(
        parentEntry.element, kAXSelectedChildrenAttribute as CFString, value)
      reply(["ok": status == .success])
    }
  }

  private func click(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let handle = handleParam(params) else {
      reply(["ok": false, "error": "ax.click requires handle"])
      return
    }
    let action = jumpAction(params["action"] as? String)
    queue.async { [weak self] in
      guard let self, let entry = self.entries[handle] else {
        reply(["ok": false, "error": "stale ax handle"])
        return
      }
      guard let frame = self.frameFromAX(entry.element, screenH: self.primaryScreenHeight()) else {
        reply(["ok": false, "error": "ax.click could not read frame"])
        return
      }
      let point = CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2)
      DispatchQueue.main.async {
        reply(["ok": ActionDispatcher.synthesizeClick(at: point, action: action)])
      }
    }
  }

  private func clickPoint(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let point = pointParam(params) else {
      reply(["ok": false, "error": "ax.click_point requires x and y"])
      return
    }
    let action = jumpAction(params["action"] as? String)
    DispatchQueue.main.async {
      reply(["ok": ActionDispatcher.synthesizeClick(at: point, action: action)])
    }
  }

  // MARK: - Registry

  /// Registers `element` and returns its handle. Caller runs on `queue`.
  private func register(pid: pid_t, element: AXUIElement) -> UInt64 {
    nextHandle += 1
    let handle = nextHandle
    entries[handle] = Entry(pid: pid, element: element)
    return handle
  }

  /// Drops every handle owned by `pid`. A fresh snapshot supersedes the prior
  /// one, so the old handles can never be acted on again — this keeps the
  /// registry from growing without bound. Caller runs on `queue`.
  private func purge(pid: pid_t) {
    entries = entries.filter { $0.value.pid != pid }
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
  ///
  /// When `geometry` is set, `kAXPositionAttribute`+`kAXSizeAttribute` ride the
  /// *same* batch and the node gets a `frame:[x,y,w,h]` in NSScreen space,
  /// Y-flipped to match `AccessibilityProvider.frameFromAX` so plugin hints
  /// land pixel-for-pixel on the core hints.
  private func readNode(
    _ element: AXUIElement, collect: [String], follow: [String],
    geometry: Bool, screenH: CGFloat
  ) -> (attrs: [String: String], children: [AXUIElement], frame: [Double]?) {
    let geometryNames =
      geometry ? [kAXPositionAttribute as String, kAXSizeAttribute as String] : []
    let names = collect + follow + geometryNames
    guard !names.isEmpty else { return ([:], [], nil) }
    var raw: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, names as CFArray, AXCopyMultipleAttributeOptions(), &raw)
    guard status == .success, let values = raw as? [Any], values.count == names.count else {
      // Wholesale failure (rare — a bad element). Fall back to per-attribute
      // copies so one unreadable attribute can't blank the whole node.
      var attrs: [String: String] = [:]
      for name in collect {
        if let text = attribute(element, name) { attrs[name] = text }
      }
      var children: [AXUIElement] = []
      for name in follow { children.append(contentsOf: elementArray(element, name)) }
      let frame = geometry ? frameFromAX(element, screenH: screenH) : nil
      return (attrs, children, frame)
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
    var frame: [Double]? = nil
    if geometry {
      let geometryBase = collect.count + follow.count
      frame = frameArray(
        pos: values[geometryBase], size: values[geometryBase + 1], screenH: screenH)
    }
    return (attrs, children, frame)
  }

  private func elementArray(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let values = raw as? [AXUIElement]
    else { return [] }
    return values
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

  // MARK: - Geometry

  /// Y-flips a batched position/size pair (the opaque `Any` slots from
  /// `AXUIElementCopyMultipleAttributeValues`) into NSScreen-space
  /// `[x, y, w, h]`. Returns nil unless both slots are real `AXValue`s.
  ///
  /// Plugin callers can feed arbitrary payloads through `ax.snapshot` /
  /// `ax.perform`, so the `CFGetTypeID == AXValueGetTypeID()` guards must run
  /// *before* the force-bridge — Swift's `as!` on CoreFoundation refs cannot
  /// itself verify the type. A misbehaving plugin must never crash the host
  /// here.
  private func frameArray(pos: Any, size: Any, screenH: CGFloat) -> [Double]? {
    guard CFGetTypeID(pos as CFTypeRef) == AXValueGetTypeID(),
      CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID()
    else { return nil }
    return frameArray(pos: pos as! AXValue, size: size as! AXValue, screenH: screenH)
  }

  /// Per-attribute geometry read for the rare batched-read failure fallback.
  /// Same trust contract as `frameArray(pos:size:screenH:)` — the CFGetTypeID
  /// guard above each force-cast is what makes it safe.
  private func frameFromAX(_ element: AXUIElement, screenH: CGFloat) -> [Double]? {
    var posRaw: CFTypeRef?
    var sizeRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
      let posRaw, let sizeRaw,
      CFGetTypeID(posRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID()
    else { return nil }
    return frameArray(pos: posRaw as! AXValue, size: sizeRaw as! AXValue, screenH: screenH)
  }

  /// The actual flip. AX reports a top-left origin; NSScreen is bottom-left,
  /// so `y' = screenH - y - height` — identical to
  /// `AccessibilityProvider.frameFromAX`.
  private func frameArray(pos: AXValue, size: AXValue, screenH: CGFloat) -> [Double]? {
    guard AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
    var origin = CGPoint.zero
    var sz = CGSize.zero
    AXValueGetValue(pos, .cgPoint, &origin)
    AXValueGetValue(size, .cgSize, &sz)
    let flippedY = screenH - origin.y - sz.height
    return [Double(origin.x), Double(flippedY), Double(sz.width), Double(sz.height)]
  }

  private func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  // MARK: - Param coercion

  private func handleParam(_ params: [String: Any]) -> UInt64? {
    uint64Param(params["handle"])
  }

  private func uint64Param(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? UInt64 { return value }
    return nil
  }

  private func pidParam(_ params: [String: Any], key: String) -> pid_t? {
    if let number = params[key] as? NSNumber { return pid_t(number.int32Value) }
    if let value = params[key] as? Int { return pid_t(value) }
    return nil
  }

  private func pointParam(_ params: [String: Any]) -> CGPoint? {
    guard let x = doubleParam(params["x"]), let y = doubleParam(params["y"]) else { return nil }
    return CGPoint(x: x, y: y)
  }

  private func doubleParam(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    return nil
  }

  private func jumpAction(_ raw: String?) -> JumpAction {
    switch raw {
    case "right_click":
      return .rightClick
    case "double_click":
      return .doubleClick
    default:
      return .leftClick
    }
  }
}
