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
  /// trees off the main thread, so the walk stays off-main; only app
  /// activation (`ax.activate`) hops to the main thread.
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
    case "ax.activate":
      activate(params, reply: reply)
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
    let follow = (params["follow"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.defaultFollow
    let collect = params["collect"] as? [String] ?? []
    let maxNodes = params["max_nodes"] as? Int ?? 3_000

    queue.async { [weak self] in
      guard let self else {
        reply(["ok": false, "error": "broker released"])
        return
      }
      self.purge(pid: pid)
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
        var bfs = [root]
        var index = 0
        while index < bfs.count, nodes.count < maxNodes {
          let element = bfs[index]
          index += 1
          let handle = self.register(pid: pid, element: element)
          let (attrs, children) = self.readNode(element, collect: collect, follow: follow)
          nodes.append(["handle": handle, "root": rootIndex, "attrs": attrs])
          bfs.append(contentsOf: children)
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

  private func activate(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let pid = pidParam(params, key: "pid") else {
      reply(["ok": false, "error": "ax.activate requires pid"])
      return
    }
    DispatchQueue.main.async {
      guard let app = NSRunningApplication(processIdentifier: pid) else {
        reply(["ok": false, "error": "no running app for pid"])
        return
      }
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      reply(["ok": true])
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
  private func readNode(
    _ element: AXUIElement, collect: [String], follow: [String]
  ) -> (attrs: [String: String], children: [AXUIElement]) {
    let names = collect + follow
    guard !names.isEmpty else { return ([:], []) }
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
      return (attrs, children)
    }
    var attrs: [String: String] = [:]
    for (offset, name) in collect.enumerated() {
      if let text = coerce(values[offset]) { attrs[name] = text }
    }
    var children: [AXUIElement] = []
    let base = collect.count
    for offset in follow.indices {
      if let elems = values[base + offset] as? [AXUIElement] {
        children.append(contentsOf: elems)
      }
    }
    return (attrs, children)
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

  // MARK: - Param coercion

  private func handleParam(_ params: [String: Any]) -> UInt64? {
    if let number = params["handle"] as? NSNumber { return number.uint64Value }
    if let value = params["handle"] as? Int, value >= 0 { return UInt64(value) }
    return nil
  }

  private func pidParam(_ params: [String: Any], key: String) -> pid_t? {
    if let number = params[key] as? NSNumber { return pid_t(number.int32Value) }
    if let value = params[key] as? Int { return pid_t(value) }
    return nil
  }
}
