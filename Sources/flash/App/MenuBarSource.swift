import AppKit
import ApplicationServices
import FlashCore

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
  var candidateSourceLabels: [String] { ["menus.items"] }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [
      CandidateSourceDescriptor(
        name: "menus.items", kind: .standard, priority: .high, mode: .live)
    ]
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

  /// BFS the app's menu bar: top-level AXMenuBarItems (Apple menu skipped)
  /// down through nested AXMenus, collecting enabled, titled leaf items with
  /// their `File › Export…` path as the candidate title.
  private static func walkMenuBar(
    pid: pid_t
  ) -> ([Candidate], [String: AXUIElement]) {
    let app = AXUIElementCreateApplication(pid)
    var menuBarRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRaw)
        == .success,
      let menuBarValue = menuBarRaw,
      CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
    else { return ([], [:]) }
    let menuBar = menuBarValue as! AXUIElement

    var candidates: [Candidate] = []
    var elements: [String: AXUIElement] = [:]
    var visited = 0

    func title(of element: AXUIElement) -> String? {
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw)
          == .success,
        let value = raw as? String
      else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : trimmed
    }

    func isEnabled(_ element: AXUIElement) -> Bool {
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &raw)
          == .success,
        let value = raw as? Bool
      else { return true }
      return value
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
          == .success,
        let value = raw as? [AXUIElement]
      else { return [] }
      return value
    }

    func descend(_ element: AXUIElement, path: [String], depth: Int) {
      guard depth <= maxDepth, visited < maxNodes else { return }
      for child in children(of: element) {
        visited += 1
        guard visited < maxNodes else { return }
        var raw: CFTypeRef?
        let role =
          AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &raw) == .success
          ? raw as? String : nil
        switch role {
        case "AXMenu":
          descend(child, path: path, depth: depth)
        case "AXMenuItem", "AXMenuBarItem":
          guard let itemTitle = title(of: child) else { continue }
          let submenus = children(of: child).filter { grandchild in
            var grandRaw: CFTypeRef?
            return AXUIElementCopyAttributeValue(
              grandchild, kAXRoleAttribute as CFString, &grandRaw) == .success
              && (grandRaw as? String) == "AXMenu"
          }
          if submenus.isEmpty {
            guard role == "AXMenuItem", isEnabled(child) else { continue }
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
    let barItems = children(of: menuBar).dropFirst()
    for barItem in barItems {
      guard let barTitle = title(of: barItem) else { continue }
      descend(barItem, path: [barTitle], depth: 1)
    }
    return (candidates, elements)
  }
}
