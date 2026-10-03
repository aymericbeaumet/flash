import ApplicationServices
import FlashCore

/// A cheap, bounded look at whether an app's accessibility tree has been
/// built yet. Chromium and Flutter build theirs asynchronously after the wake
/// flags, and Gecko once the tree is read, so a walk right after a focus
/// change can find nothing (the logged 1–5 ms zero-target walks). The probe
/// reads the walked window and a few dozen containers below it — one batched
/// read each — instead of paying a whole walk to learn the tree is not there.
///
/// It never replaces a walk and never decides what the hints are: it only
/// decides when the one walk that follows is worth doing. Call it off the
/// main thread (the AX queue). Gecko's tree is woken inside
/// `GeckoAccessibility.withTree`, and a focused app keeps it once built.
public enum AccessibilityReadiness {
  /// What the bounded breadth-first look saw under the walked window.
  public struct Sample: Equatable {
    /// Direct children of the window.
    public var windowChildren: Int
    /// Children of the first `AXWebArea` reached; nil when none was.
    public var webAreaChildren: Int?
    /// Elements read, the window included.
    public var visited: Int

    public init(windowChildren: Int, webAreaChildren: Int?, visited: Int) {
      self.windowChildren = windowChildren
      self.webAreaChildren = webAreaChildren
      self.visited = visited
    }
  }

  /// Elements the probe reads at most. A tree that runs past it is
  /// substantial, which is all readiness asks.
  public static let visitBudget = 32
  /// A window unready for Accessibility exposes little beyond its title-bar
  /// buttons and one content group.
  public static let windowChildThreshold = 5

  /// A web area with content is ready; an empty one is a page (or an
  /// Electron view) still being built. Without a web area in reach, a window
  /// with more than decorations at the top, or a tree larger than the probe
  /// looks at, is ready. No window at all is not.
  public static func isReady(_ sample: Sample?) -> Bool {
    guard let sample else { return false }
    if let webAreaChildren = sample.webAreaChildren { return webAreaChildren > 0 }
    return sample.windowChildren > windowChildThreshold || sample.visited >= visitBudget
  }

  /// Probe the app's walked window. Synchronous AX IPC, at most
  /// `visitBudget` batched reads plus the window lookup.
  public static func probe(pid: pid_t, bundleIdentifier: String?) -> Bool {
    GeckoAccessibility.withTree(pid: pid, bundleIdentifier: bundleIdentifier) { app in
      isReady(sample(app: app))
    }
  }

  static func sample(app: AXUIElement) -> Sample? {
    guard let window = AccessibilityProvider.focusedOrFirstWindow(in: app) else { return nil }
    let top = AXAttribute.children(window)
    var queue = top
    var index = 0
    var visited = 1
    while index < queue.count, visited < visitBudget {
      let element = queue[index]
      index += 1
      visited += 1
      let (role, children) = roleAndChildren(of: element)
      if role == "AXWebArea" {
        return Sample(windowChildren: top.count, webAreaChildren: children.count, visited: visited)
      }
      // Controls lead nowhere a page could be: skipping their children keeps
      // a browser's tab strip and toolbar from spending the budget before
      // the content group is reached.
      if role.map(containerRoles.contains) ?? true {
        queue.append(contentsOf: children)
      }
    }
    return Sample(windowChildren: top.count, webAreaChildren: nil, visited: visited)
  }

  private static let containerRoles: Set<String> = [
    "AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown",
  ]

  /// One IPC per element: its role and its children.
  private static func roleAndChildren(of element: AXUIElement) -> (String?, [AXUIElement]) {
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
      let values = raw as? [Any], values.count == 2
    else { return (nil, []) }
    return (values[0] as? String, values[1] as? [AXUIElement] ?? [])
  }

  private static let attributes = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray
}
