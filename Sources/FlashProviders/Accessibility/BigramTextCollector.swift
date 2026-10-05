import AppKit
import ApplicationServices
import FlashCore
import Foundation

/// Visible text in one focused window, collected for a bigram jump.
///
/// The clickable-target walk stops at controls and at `maxTargets`, so body
/// text never reaches `f`. This walk is separate and on demand: it keeps every
/// visible run of at least one character and resolves glyph rects only for
/// the query's matches. It does not read pixels.
public enum BigramTextCollector {
  public static let providerID = "bigram"

  struct Run {
    let element: AXUIElement
    let text: String
    let role: String
    let subrole: String?
    let frame: CGRect
  }

  public struct Corpus {
    let pid: pid_t
    public let bundleIdentifier: String
    let screenH: CGFloat
    let clip: CGRect
    let runs: [Run]

    public var runCount: Int { runs.count }

    public func targets(matching query: String) -> [JumpTarget] {
      guard query.count == 1 else { return [] }
      var located: [(rect: CGRect, value: Hit)] = []
      for (index, run) in runs.enumerated() {
        let haystack = run.text as NSString
        for occurrence in BigramMatcher.occurrences(in: run.text, query: query) {
          guard
            let rect = BigramTextCollector.matchRect(
              element: run.element, text: run.text, frame: run.frame,
              location: occurrence.location, length: occurrence.length, screenH: screenH)
          else { continue }
          let center = CGPoint(x: rect.midX, y: rect.midY)
          guard clip.containsInclusive(center) else { continue }
          let label = haystack.substring(
            with: NSRange(location: occurrence.location, length: occurrence.length))
          located.append(
            (
              rect: rect,
              value: Hit(
                runIndex: index, location: occurrence.location, length: occurrence.length,
                label: label)
            ))
        }
      }
      let kept = BigramMatcher.dedupe(located)
      let targets = kept.enumerated().map { ordinal, item in
        BigramTextCollector.target(
          hit: item.value, rect: item.rect, run: runs[item.value.runIndex], query: query,
          ordinal: ordinal, pid: pid, bundleIdentifier: bundleIdentifier, screenH: screenH,
          clip: clip)
      }
      return AccessibilityProvider.settlingInsertIntent(
        targets, bundleIdentifier: bundleIdentifier)
    }
  }

  public static func collect(in context: AppContext, screenH: CGFloat) -> Corpus {
    let clip = context.frontWindowFrame
    guard !clip.isNull, !clip.isInfinite else {
      return Corpus(
        pid: context.processID, bundleIdentifier: context.bundleIdentifier, screenH: screenH,
        clip: clip, runs: [])
    }
    let app = AXApp.make(pid: context.processID)
    let runs = GeckoAccessibility.withTree(
      pid: context.processID, bundleIdentifier: context.bundleIdentifier, app: app
    ) { app -> [Run] in
      let traits = AppTraits.of(
        bundleIdentifier: context.bundleIdentifier, pid: context.processID)
      if traits.needsAccessibilityWake {
        let enabled = kCFBooleanTrue as CFTypeRef
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, enabled)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, enabled)
      }
      let roots: [AXUIElement]
      switch context.walkRoot {
      case .focusedWindow:
        guard let window = AccessibilityProvider.focusedOrFirstWindow(in: app) else { return [] }
        roots = [window]
      case .elementsInFrame:
        roots = AccessibilityProvider.topLevelElements(in: app, meeting: clip, screenH: screenH)
      }
      return roots.flatMap { walk(root: $0, clip: clip, screenH: screenH) }
    }
    return Corpus(
      pid: context.processID, bundleIdentifier: context.bundleIdentifier, screenH: screenH,
      clip: clip, runs: runs)
  }

  private struct Hit {
    let runIndex: Int
    let location: Int
    let length: Int
    let label: String
  }

  /// Parent indexes live on the node because a sibling can sit on the stack
  /// between a node and its parent, so the stack top is not the parent.
  private struct Node {
    var element: AXUIElement
    var depth: Int
    var parent: Int?
    var insideWebArea: Bool
    var emitted = false
    var role: String?
    var subrole: String?
    var title: String?
    var value: String?
    var frame: CGRect?
  }

  /// Post-order: a node's own string is emitted only when no descendant was.
  private static func walk(root: AXUIElement, clip: CGRect, screenH: CGFloat) -> [Run] {
    var nodes = [Node(element: root, depth: 0, parent: nil, insideWebArea: false)]
    var stack: [(index: Int, leave: Bool)] = [(0, false)]
    var runs: [Run] = []
    while let step = stack.popLast() {
      if step.leave {
        finish(step.index, nodes: &nodes, runs: &runs, clip: clip)
        continue
      }
      let index = step.index
      if nodes[index].depth > AccessibilityProvider.maxDepth { continue }
      guard let snapshot = read(nodes[index].element, screenH: screenH) else { continue }
      if snapshot.hidden { continue }
      if AccessibilityProvider.skipsOffscreenSubtree(
        frame: snapshot.frame, visible: clip, depth: nodes[index].depth,
        insideWebArea: nodes[index].insideWebArea)
      {
        continue
      }
      nodes[index].role = snapshot.role
      nodes[index].subrole = snapshot.subrole
      nodes[index].title = snapshot.title
      nodes[index].value = snapshot.value
      nodes[index].frame = snapshot.frame
      var children = snapshot.children
      if snapshot.childrenMissing {
        children = AXAttribute.children(nodes[index].element)
      }
      children = tableChildren(
        of: nodes[index].element, role: snapshot.role, insideWebArea: nodes[index].insideWebArea,
        children: children)
      stack.append((index, true))
      let parent = index
      let depth = nodes[index].depth + 1
      let childInsideWeb = nodes[index].insideWebArea || snapshot.role == "AXWebArea"
      for child in children.reversed() {
        nodes.append(
          Node(element: child, depth: depth, parent: parent, insideWebArea: childInsideWeb))
        stack.append((nodes.count - 1, false))
      }
    }
    return runs
  }

  private static func finish(
    _ index: Int, nodes: inout [Node], runs: inout [Run], clip: CGRect
  ) {
    if nodes[index].emitted { return }
    guard let role = nodes[index].role,
      let text = BigramText.ownString(
        role: role, title: nodes[index].title, value: nodes[index].value, descendantEmitted: false),
      let frame = nodes[index].frame,
      clip.containsInclusive(CGPoint(x: frame.midX, y: frame.midY))
    else { return }
    runs.append(
      Run(
        element: nodes[index].element, text: text, role: role, subrole: nodes[index].subrole,
        frame: frame))
    markEmitted(&nodes, index)
  }

  /// Marks `index` and its ancestors. A descendant that emits suppresses the
  /// containers wrapped around the same glyphs.
  private static func markEmitted(_ nodes: inout [Node], _ index: Int) {
    var current: Int? = index
    while let cursor = current {
      if nodes[cursor].emitted { return }
      nodes[cursor].emitted = true
      current = nodes[cursor].parent
    }
  }

  private struct Snapshot {
    var role: String?
    var frame: CGRect?
    var children: [AXUIElement]
    var childrenMissing: Bool
    var title: String?
    var value: String?
    var hidden: Bool
    var subrole: String?
  }

  private static let batchNames: CFArray =
    [
      kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
      kAXTitleAttribute, kAXValueAttribute, kAXHiddenAttribute, kAXSubroleAttribute,
    ] as CFArray

  private static func read(_ element: AXUIElement, screenH: CGFloat) -> Snapshot? {
    var valuesRef: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, batchNames, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
    guard status == .success, let values = valuesRef as? [Any], values.count == 8 else {
      return nil
    }
    let children = values[3] as? [AXUIElement]
    return Snapshot(
      role: values[0] as? String,
      frame: frame(position: values[1], size: values[2], screenH: screenH),
      children: children ?? [],
      childrenMissing: children == nil,
      title: text(values[4]),
      value: text(values[5]),
      hidden: (values[6] as? Bool) ?? false,
      subrole: values[7] as? String)
  }

  private static func tableChildren(
    of element: AXUIElement, role: String?, insideWebArea: Bool, children: [AXUIElement]
  ) -> [AXUIElement] {
    guard role == "AXTable" || role == "AXOutline" else { return children }
    guard let visible = elements(element, kAXVisibleRowsAttribute as String), !visible.isEmpty
    else { return children }
    let rows = insideWebArea ? nil : elements(element, kAXRowsAttribute as String)
    return AccessibilityProvider.tableChildren(children: children, rows: rows, visibleRows: visible)
  }

  private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
      return nil
    }
    return raw as? [AXUIElement]
  }

  private static func matchRect(
    element: AXUIElement, text: String, frame: CGRect, location: Int, length: Int,
    screenH: CGFloat
  ) -> CGRect? {
    if let bounds = AXAttribute.boundsForRange(
      element, location: location, length: length, screenH: screenH)
    {
      return bounds
    }
    let total = (text as NSString).length
    guard BigramMatcher.allowsProportionalFallback(text: text, frame: frame) else { return nil }
    return BigramMatcher.proportionalRect(
      frame: frame, location: location, length: length, totalUTF16: total)
  }

  private static func target(
    hit: Hit, rect: CGRect, run: Run, query: String, ordinal: Int, pid: pid_t,
    bundleIdentifier: String, screenH: CGFloat, clip: CGRect
  ) -> JumpTarget {
    let element = run.element
    let role = run.role
    let location = hit.location
    let length = hit.length
    let capturedFrame = run.frame
    let resolve: (CGPoint) -> CGPoint? = { _ in
      GeckoAccessibility.withTree(pid: pid, bundleIdentifier: bundleIdentifier) { _ in
        let title = copiedText(element, kAXTitleAttribute as String)
        let value = copiedText(element, kAXValueAttribute as String)
        guard let text = BigramText.rawString(role: role, title: title, value: value),
          BigramMatcher.sliceMatches(text: text, location: location, length: length, query: query)
        else { return nil }
        if let bounds = AXAttribute.boundsForRange(
          element, location: location, length: length, screenH: screenH)
        {
          let center = CGPoint(x: bounds.midX, y: bounds.midY)
          if clip.containsInclusive(center) { return center }
          return nil
        }
        let frame = currentFrame(of: element, screenH: screenH) ?? capturedFrame
        guard BigramMatcher.allowsProportionalFallback(text: text, frame: frame),
          let estimated = BigramMatcher.proportionalRect(
            frame: frame, location: location, length: length,
            totalUTF16: (text as NSString).length)
        else { return nil }
        let center = CGPoint(x: estimated.midX, y: estimated.midY)
        return clip.containsInclusive(center) ? center : nil
      }
    }
    return JumpTarget(
      id: "bigram-\(pid)-\(ordinal)",
      frame: rect,
      role: role,
      accessibilityLabel: hit.label,
      pid: pid,
      resolveClickPoint: resolve,
      entersInsertMode: JumpTarget.isTextInput(role: role, subrole: run.subrole),
      providerID: providerID)
  }

  private static func copiedText(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success, let raw
    else { return nil }
    return text(raw)
  }

  private static func currentFrame(of element: AXUIElement, screenH: CGFloat) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size
    else { return nil }
    return frame(position: position, size: size, screenH: screenH)
  }

  private static func frame(position: Any, size: Any, screenH: CGFloat) -> CGRect? {
    let positionRef = position as CFTypeRef
    let sizeRef = size as CFTypeRef
    guard CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    return AccessibilityProvider.frameFromAX(
      pos: positionRef as! AXValue, size: sizeRef as! AXValue, screenH: screenH)
  }

  private static func text(_ value: Any) -> String? {
    if let text = value as? String { return text }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
  }
}
