import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// `@menus` — the frontmost app's menu-bar items as a live flashlight source
/// (Shortcat / Paletro parity: run any app command without memorizing its
/// shortcut). Live because menus are per-app and change with focus and state;
/// the walk happens only when the user scopes a query to `@menus`. Selection
/// presses the AX menu item directly.
final class MenuBarSource: FlashSource {
  let identifier = "core.menus"
  let displayName = "core.menus"
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: "menus.items", type: "menus", priority: .high)]
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  /// Menu-item elements keyed by the id stamped into candidate metadata,
  /// replaced wholesale on every walk. Guarded because the walk runs on the
  /// worker queue while resolution reads on main.
  private let lock = NSLock()
  private var elementsByID: [String: AXUIElement] = [:]
  private var cache: (pid: pid_t, at: Date, candidates: [Candidate])?
  private static let cacheTTL: TimeInterval = 3
  private static let walkQueue = DispatchQueue(
    label: "flash.source.menus", qos: .userInitiated)

  static let idMetadataKey = "menu_item_id"
  private static let maxNodes = 2500
  private static let maxDepth = 4

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    _ = (text, environment, scope)
    // The flashlight itself may hold activation, so ask for the app whose
    // menus are actually installed rather than the frontmost app.
    guard
      let app = NSWorkspace.shared.menuBarOwningApplication
        ?? NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      DispatchQueue.main.async { completion([]) }
      return
    }
    let pid = app.processIdentifier
    lock.lock()
    let cached = cache
    lock.unlock()
    if let cached, cached.pid == pid, Date().timeIntervalSince(cached.at) < Self.cacheTTL {
      DispatchQueue.main.async { completion(cached.candidates) }
      return
    }
    Self.walkQueue.async { [weak self] in
      guard let self else { return }
      let (candidates, elements) = Self.walkMenuBar(pid: pid)
      self.lock.lock()
      self.elementsByID = elements
      self.cache = (pid, Date(), candidates)
      self.lock.unlock()
      FlashLog.trace("[menus] walk pid=\(pid) items=\(candidates.count)")
      DispatchQueue.main.async { completion(candidates) }
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    guard let id = candidate.metadata[Self.idMetadataKey] else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }
    lock.lock()
    let element = elementsByID[id]
    lock.unlock()
    guard let element else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }
    let pid = candidate.pid
    Self.walkQueue.async {
      let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
      DispatchQueue.main.async {
        completion(pressed ? .resolved(pid: pid) : .unresolved)
      }
    }
  }

  func candidate(
    matching target: String, in environment: FlashSourceEnvironment
  ) -> Candidate? { nil }
  func documentURL(in context: AppContext) -> String? { nil }

  /// The app's menu-bar titles in bar order, the Apple menu first: the
  /// children of its `AXMenuBar`. Shared by `@menus` and `mouse menubar`.
  static func menuBarItems(of app: AXUIElement) -> [AXUIElement] {
    var menuBarRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRaw)
        == .success,
      let menuBarValue = menuBarRaw,
      CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
    else { return [] }
    return AXAttribute.children(menuBarValue as! AXUIElement)
  }

  /// What one batched read of a menu element answers.
  struct MenuElementRead<Element> {
    var role: String?
    /// As the element reports it; the walk trims it.
    var title: String?
    /// True when the element does not say.
    var enabled: Bool
    var children: [Element]
  }

  /// The app's menu bar: top-level AXMenuBarItems (Apple menu skipped) down
  /// through nested AXMenus, collecting enabled, titled leaf items with their
  /// `File › Export…` path as the candidate title.
  private static func walkMenuBar(
    pid: pid_t
  ) -> ([Candidate], [String: AXUIElement]) {
    let app = AXApp.make(pid: pid)
    return walk(pid: pid, barItems: menuBarItems(of: app), read: readMenuElement)
  }

  /// The walk over `read`, which answers each element once: an element's
  /// role, title, enabled state and children come from one Accessibility
  /// round trip, and a submenu is descended through the read that found it.
  static func walk<Element>(
    pid: pid_t, barItems: [Element], read: (Element) -> MenuElementRead<Element>
  ) -> ([Candidate], [String: Element]) {
    var candidates: [Candidate] = []
    var elements: [String: Element] = [:]
    var visited = 0

    func descend(_ node: MenuElementRead<Element>, path: [String], depth: Int) {
      guard depth <= maxDepth, visited < maxNodes else { return }
      for child in node.children {
        visited += 1
        guard visited < maxNodes else { return }
        let item = read(child)
        switch item.role {
        case "AXMenu":
          descend(item, path: path, depth: depth)
        case "AXMenuItem", "AXMenuBarItem":
          guard let itemTitle = trimmedTitle(item.title) else { continue }
          let submenus = item.children.map(read).filter { $0.role == "AXMenu" }
          if submenus.isEmpty {
            guard item.role == "AXMenuItem", item.enabled else { continue }
            let fullPath = path + [itemTitle]
            let id = "menu:\(pid):\(candidates.count):\(fullPath.joined(separator: "/"))"
            elements[id] = child
            candidates.append(
              Candidate(
                title: fullPath.joined(separator: " › "),
                metadata: [
                  CandidateMetadataKey.source: "menus.items",
                  CandidateMetadataKey.sourceID: "core.menus",
                  CandidateMetadataKey.pid: "\(pid)",
                  idMetadataKey: id,
                ]))
          } else {
            for submenu in submenus {
              descend(submenu, path: path + [itemTitle], depth: depth + 1)
            }
          }
        default:
          continue
        }
      }
    }

    // Skip the Apple menu (first bar item) — its items are system-global.
    for barItem in barItems.dropFirst() {
      let bar = read(barItem)
      guard let barTitle = trimmedTitle(bar.title) else { continue }
      descend(bar, path: [barTitle], depth: 1)
    }
    return (candidates, elements)
  }

  private static let menuElementAttributes =
    [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute] as CFArray

  /// One `AXUIElementCopyMultipleAttributeValues` round trip. An unreadable
  /// attribute leaves an error in its slot: absent, as a single read would
  /// have found it. A children slot holding an error other than "no value"
  /// is read again on its own, and a batch the app refuses outright falls
  /// back to single reads.
  private static func readMenuElement(_ element: AXUIElement) -> MenuElementRead<AXUIElement> {
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, menuElementAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        == .success,
      let values = raw as? [Any], values.count == 4
    else {
      return MenuElementRead(
        role: AXAttribute.role(element),
        title: AXAttribute.string(element, kAXTitleAttribute as String),
        enabled: AXAttribute.bool(element, kAXEnabledAttribute as String) ?? true,
        children: AXAttribute.children(element))
    }
    let children: [AXUIElement]
    if let listed = values[3] as? [AXUIElement] {
      children = listed
    } else if let error = axError(values[3]), error != .noValue,
      error != .attributeUnsupported
    {
      children = AXAttribute.children(element)
    } else {
      children = []
    }
    return MenuElementRead(
      role: values[0] as? String, title: values[1] as? String,
      enabled: values[2] as? Bool ?? true, children: children)
  }

  private static func trimmedTitle(_ title: String?) -> String? {
    guard let trimmed = title?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// The error a batched read left in a slot, or nil for a value.
  private static func axError(_ value: Any) -> AXError? {
    let ref = value as CFTypeRef
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    let axValue = ref as! AXValue
    guard AXValueGetType(axValue) == .axError else { return nil }
    var error = AXError.success
    guard AXValueGetValue(axValue, .axError, &error) else { return nil }
    return error
  }
}
