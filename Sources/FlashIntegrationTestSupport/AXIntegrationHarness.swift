import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import Foundation

public struct AXNodeSnapshot: Sendable {
  public let role: String?
  public let label: String?
  public let frame: CGRect?
  public let enabled: Bool
  public let actions: [String]
  public let depth: Int
}

public enum AXIntegrationHarness {
  public static func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  public static func unionScreenFrame() -> CGRect {
    var frame: CGRect = .null
    for screen in NSScreen.screens { frame = frame.union(screen.frame) }
    if frame.isNull { return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    return frame
  }

  public static func waitForRunningApplication(
    bundleIdentifier: String,
    excluding existing: Set<pid_t> = [],
    timeout: TimeInterval = 20
  ) -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      if let app = apps.first(where: { !existing.contains($0.processIdentifier) }) {
        return app
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
  }

  public static func waitForAXWindow(
    _ app: NSRunningApplication,
    timeout: TimeInterval = 20
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !windows(pid: app.processIdentifier).isEmpty { return true }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return false
  }

  public static func windows(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement]
    else { return [] }
    return windows
  }

  public static func focusedWindow(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw)
        == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  public static func frame(of element: AXUIElement) -> CGRect? {
    var posRaw: CFTypeRef?
    var sizeRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
      let posCF = posRaw,
      let sizeCF = sizeRaw,
      CFGetTypeID(posCF) == AXValueGetTypeID(),
      CFGetTypeID(sizeCF) == AXValueGetTypeID()
    else { return nil }
    return frameFromAX(pos: posCF as! AXValue, size: sizeCF as! AXValue)
  }

  public static func frameFromAX(pos: AXValue, size: AXValue) -> CGRect? {
    guard AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
    var origin = CGPoint.zero
    var axSize = CGSize.zero
    guard AXValueGetValue(pos, .cgPoint, &origin),
      AXValueGetValue(size, .cgSize, &axSize),
      axSize.width > 0,
      axSize.height > 0
    else { return nil }
    return CGRect(
      x: origin.x,
      y: primaryScreenHeight() - origin.y - axSize.height,
      width: axSize.width,
      height: axSize.height)
  }

  public static func role(of element: AXUIElement) -> String? {
    stringAttribute(element, kAXRoleAttribute as CFString)
  }

  public static func label(of element: AXUIElement) -> String? {
    stringAttribute(element, kAXTitleAttribute as CFString)
      ?? stringAttribute(element, kAXDescriptionAttribute as CFString)
      ?? stringAttribute(element, kAXValueAttribute as CFString)
      ?? stringAttribute(element, kAXHelpAttribute as CFString)
  }

  public static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
      let value = raw as? String,
      !value.isEmpty
    else { return nil }
    return value
  }

  public static func boolAttribute(
    _ element: AXUIElement,
    _ attribute: CFString,
    default defaultValue: Bool = false
  ) -> Bool {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else {
      return defaultValue
    }
    return (raw as? Bool) ?? defaultValue
  }

  public static func children(of element: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
      let children = raw as? [AXUIElement]
    else { return [] }
    return children
  }

  public static func actions(of element: AXUIElement) -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
      let actions = raw as? [String]
    else { return [] }
    return actions
  }

  public static func walk(
    root: AXUIElement,
    maxNodes: Int = 10_000
  ) -> [AXNodeSnapshot] {
    var out: [AXNodeSnapshot] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    while !queue.isEmpty, out.count < maxNodes {
      let (element, depth) = queue.removeFirst()
      out.append(
        AXNodeSnapshot(
          role: role(of: element),
          label: label(of: element),
          frame: frame(of: element),
          enabled: boolAttribute(element, kAXEnabledAttribute as CFString, default: true),
          actions: actions(of: element),
          depth: depth))
      queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
    }
    return out
  }

  public static func makeContext(
    for app: NSRunningApplication,
    frontWindowFrame: CGRect? = nil
  ) -> AppContext {
    let frame =
      frontWindowFrame ?? focusedWindow(pid: app.processIdentifier).flatMap(frame(of:))
      ?? unionScreenFrame()
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: frame,
      allScreensFrame: unionScreenFrame())
  }

  public static func discoverFinalizedTargets(
    app: NSRunningApplication,
    provider: AccessibilityProvider,
    visibleRegions: [CGRect]? = nil
  ) -> [JumpTarget] {
    let frame = focusedWindow(pid: app.processIdentifier).flatMap(frame(of:)) ?? unionScreenFrame()
    let context = makeContext(for: app, frontWindowFrame: frame)
    let raw = (try? provider.discover(in: context)) ?? []
    let candidates = raw.enumerated().map { ordinal, target in
      TargetCandidate(
        target: target,
        priority: provider.priority,
        providerOrder: 0,
        ordinal: ordinal)
    }
    return TargetFinalizer.finalize(
      candidates,
      visibleRegions: visibleRegions ?? [frame])
  }
}
