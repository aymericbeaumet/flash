import AppKit
import ApplicationServices
import CoreGraphics
import FlashCore
import FlashProviders
import Foundation

/// One element Vimium-FF emitted a hint marker for, after CSS->screen
/// coordinate transformation.
public struct VimiumAnchor {
  public let tag: String
  public let role: String
  public let label: String
  public let marker: String
  public let cssRect: CGRect
  public let screenRect: CGRect

  public init(
    tag: String, role: String, label: String, marker: String,
    cssRect: CGRect, screenRect: CGRect
  ) {
    self.tag = tag
    self.role = role
    self.label = label
    self.marker = marker
    self.cssRect = cssRect
    self.screenRect = screenRect
  }
}

public struct OracleSnapshot {
  public let flashTargets: [JumpTarget]
  public let vimiumAnchors: [VimiumAnchor]
  public let transform: OracleTransform
  public let fiducialResidual: Double
  /// Screen-space bounds of the page viewport, derived from the
  /// companion-reported `viewport.innerWidth/innerHeight` projected
  /// through `transform`. The runner uses this to filter Flash AX
  /// targets to the page area — more reliable than `findWebAreaFrame`
  /// when the Firefox window is off-screen (the AX search can match
  /// stale or chrome-side AXWebAreas instead of the real one).
  public let pageScreenRect: CGRect

  public init(
    flashTargets: [JumpTarget], vimiumAnchors: [VimiumAnchor],
    transform: OracleTransform, fiducialResidual: Double,
    pageScreenRect: CGRect
  ) {
    self.flashTargets = flashTargets
    self.vimiumAnchors = vimiumAnchors
    self.transform = transform
    self.fiducialResidual = fiducialResidual
    self.pageScreenRect = pageScreenRect
  }
}

/// Drives the full per-fixture capture sequence: wait for companion
/// ready, snapshot Flash hints, post 'f' to wake Vimium, poll for
/// anchors payload, decode + solve fiducial transform, dismiss Vimium.
public enum VimiumOracle {
  public enum CaptureError: Error, CustomStringConvertible {
    case readyTimedOut
    case anchorsTimedOut
    case decodeFailed(String)
    case missingFiducials([String])
    case transformFailed(Error)

    public var description: String {
      switch self {
      case .readyTimedOut:
        return """
          Companion never signalled FLASH_ORACLE_READY. Check:
            - Firefox Developer Edition (not Release) — release Firefox refuses unsigned extensions
            - companion XPI installed at OracleProfile.companionXPIPath
            - Vimium-FF didn't crash the tab during load
          """
      case .anchorsTimedOut:
        return """
          Companion never signalled FLASH_ORACLE_ANCHORS after the 'f' keystroke. Check:
            - Vimium-FF actually loaded into the profile
            - the page (not the URL bar) had focus when 'f' was posted
            - markers actually rendered (smoke-test by pressing 'f' manually)
          """
      case .decodeFailed(let why):
        return "Failed to decode anchors payload: \(why)"
      case .missingFiducials(let ids):
        return "Fiducials not found in Firefox AX tree: \(ids.joined(separator: ", "))"
      case .transformFailed(let e):
        return "Could not solve coordinate transform: \(e)"
      }
    }
  }

  private static let readyTitle = "FLASH_ORACLE_READY"
  private static let anchorsReadyTitle = "FLASH_ORACLE_ANCHORS_READY"
  private static let payloadLabelPrefix = "FLASH_ORACLE_PAYLOAD|"
  private static let fiducialIDs = [
    "__flash_oracle_fiducial_a__",
    "__flash_oracle_fiducial_b__",
  ]
  // Apple HID virtual key codes.
  private static let kVK_ANSI_F: CGKeyCode = 0x03
  private static let kVK_Escape: CGKeyCode = 0x35

  public static func capture(
    firefox: NSRunningApplication,
    context: AppContext,
    provider: AccessibilityProvider,
    readyTimeout: TimeInterval = 30,
    anchorsTimeout: TimeInterval = 10
  ) throws -> OracleSnapshot {
    let pid = firefox.processIdentifier

    // 1. Wait for companion to signal READY (page idle + companion mounted).
    //    Log every distinct title we see so a timeout is diagnosable —
    //    "AX title was X" tells us instantly whether Firefox loaded the
    //    fixture, whether the companion fired, whether Firefox is
    //    showing a different window (about:welcome, etc.).
    var lastSeenTitle = ""
    if !waitForTitle(
      pid: pid, contains: readyTitle,
      deadline: Date().addingTimeInterval(readyTimeout),
      onPoll: { title in
        if title != lastSeenTitle {
          lastSeenTitle = title
          FileHandle.standardError.write(
            Data("[oracle] AX window title: \(title)\n".utf8))
        }
      })
    {
      throw CaptureError.readyTimedOut
    }

    // 2. Snapshot Flash AX hints *before* Vimium adds marker DOM —
    //    walking Vimium's own marker DOM into the AX set would be a
    //    nonsense input for the diff. AX walks work regardless of
    //    focus, so do this while we're still backgrounded.
    let flashTargets =
      (try? provider.discover(in: context, deadline: Date().addingTimeInterval(3))) ?? []

    // 3+4. Briefly bring Firefox foreground, post 'f', wait for the
    //      companion to flip the title to ANCHORS_READY. Re-post 'f'
    //      every second until the title changes or we hit the
    //      timeout — Vimium's keymap registration is racy and 'f'
    //      sometimes lands before it's listening; URL bar can also
    //      grab focus and swallow the first attempt.
    //
    //      Isolation guarantees:
    //      - CGEventSource(.privateState): does not inherit live HID
    //        modifier state (no Cmd+f / Shift+f if user is holding
    //        modifiers when we post)
    //      - explicit flags = [] zeroes any latent source modifiers
    //      - Firefox foreground window kept short (activate + post
    //        loop + restore-prev-frontmost) to minimize the slot
    //        where user keystrokes could leak into the page
    let prevFrontmost = NSWorkspace.shared.frontmostApplication
    firefox.activate()
    defer { prevFrontmost?.activate() }
    Thread.sleep(forTimeInterval: 0.15)

    let anchorsDeadline = Date().addingTimeInterval(anchorsTimeout)
    var lastAnchorTitle = ""
    var gotAnchors = false
    while Date() < anchorsDeadline {
      postKey(kVK_ANSI_F, to: pid)
      let waitChunk = Date().addingTimeInterval(0.9)
      while Date() < waitChunk, Date() < anchorsDeadline {
        let t = readFocusedWindowTitle(pid: pid) ?? ""
        if t != lastAnchorTitle {
          lastAnchorTitle = t
          FileHandle.standardError.write(
            Data("[oracle] post-'f' AX title: \(t)\n".utf8))
        }
        if t.contains(anchorsReadyTitle) {
          gotAnchors = true
          break
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      if gotAnchors { break }
    }
    if !gotAnchors {
      throw CaptureError.anchorsTimedOut
    }
    let resolvedFlashTargets = flashTargets

    // 5+6. One AX tree walk: collect the payload div (by description
    //      prefix) AND the fiducials. Cheaper than two passes, and
    //      ordering doesn't matter because the companion mounts both
    //      before flipping the title to ANCHORS_READY.
    let walked = walkForOracleMarkers(pid: pid, fiducialIDs: fiducialIDs)
    guard let payloadDesc = walked.payload else {
      // no dismiss needed: Firefox is terminated after each fixture run
      throw CaptureError.decodeFailed(
        "payload div not found in AX tree (companion crashed?)")
    }
    let rawJSON = String(payloadDesc.dropFirst(payloadLabelPrefix.count))
    let decoded: ExtensionPayload
    do {
      decoded = try JSONDecoder().decode(
        ExtensionPayload.self, from: Data(rawJSON.utf8))
    } catch {
      // no dismiss needed: Firefox is terminated after each fixture run
      throw CaptureError.decodeFailed(String(describing: error))
    }
    let measured = walked.fiducials
    let missing = fiducialIDs.filter { measured[$0] == nil }
    if !missing.isEmpty {
      // no dismiss needed: Firefox is terminated after each fixture run
      throw CaptureError.missingFiducials(missing)
    }

    // 7. Solve transform from fiducial pairs.
    //    Companion gives CSS top-left of each fiducial; AX (post-flip)
    //    gives NSScreen rect — the matching screen point for the CSS
    //    top-left is (rect.minX, rect.maxY).
    var pairs: [(css: CGPoint, screen: CGPoint)] = []
    for fid in decoded.fiducials {
      guard let screenRect = measured[fid.id] else { continue }
      pairs.append(
        (
          css: CGPoint(x: fid.x, y: fid.y),
          screen: CGPoint(x: screenRect.minX, y: screenRect.maxY)
        ))
    }
    let transform: OracleTransform
    do {
      transform = try OracleTransform.solve(pairs: pairs)
    } catch {
      // no dismiss needed: Firefox is terminated after each fixture run
      throw CaptureError.transformFailed(error)
    }
    let residual = transform.maxResidual(pairs: pairs)

    // 8. Project Vimium anchor rects from CSS to NSScreen.
    let anchors: [VimiumAnchor] = decoded.anchors.map { a in
      let cssR = CGRect(
        x: a.rect[0], y: a.rect[1], width: a.rect[2], height: a.rect[3])
      let screenR = transform.screenRect(fromCSS: cssR)
      return VimiumAnchor(
        tag: a.tag, role: a.role, label: a.label, marker: a.marker,
        cssRect: cssR, screenRect: screenR)
    }

    // 9. Project the page viewport rect (CSS) into screen space —
    //    Flash targets filtered by this rect end up corresponding to
    //    page DOM, ignoring Firefox chrome.
    let pageCSSRect = CGRect(
      x: 0, y: 0,
      width: decoded.viewport.innerWidth,
      height: decoded.viewport.innerHeight)
    let pageScreenRect = transform.screenRect(fromCSS: pageCSSRect)

    // 10. Dismiss Vimium hint mode + reset companion for the next capture.
    // no dismiss needed: Firefox is terminated after each fixture run

    return OracleSnapshot(
      flashTargets: resolvedFlashTargets, vimiumAnchors: anchors,
      transform: transform, fiducialResidual: residual,
      pageScreenRect: pageScreenRect)
  }

  // MARK: - Wire types (mirror Resources/oracle-extension/content.js)

  private struct ExtensionPayload: Decodable {
    let anchors: [RawAnchor]
    let fiducials: [Fiducial]
    let viewport: Viewport
  }
  private struct RawAnchor: Decodable {
    let tag: String
    let role: String
    let rect: [Double]
    let label: String
    let marker: String
  }
  private struct Fiducial: Decodable {
    let id: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
  }
  private struct Viewport: Decodable {
    let scrollX: Double
    let scrollY: Double
    let innerWidth: Double
    let innerHeight: Double
    let dpr: Double
  }

  // MARK: - AX helpers

  private static func waitForTitle(
    pid: pid_t, contains needle: String, deadline: Date,
    onPoll: ((String) -> Void)? = nil
  ) -> Bool {
    while Date() < deadline {
      let t = readFocusedWindowTitle(pid: pid) ?? ""
      onPoll?(t)
      if t.contains(needle) { return true }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return false
  }

  /// Wait for the focused window AX title to start with `prefix`, then
  /// return the embedded JSON object. Firefox appends " — Mozilla
  /// Firefox Developer Edition" to the document title; the balanced
  /// brace walker truncates the suffix.
  private static func waitForTitlePayload(
    pid: pid_t, prefix: String, deadline: Date,
    onPoll: ((String) -> Void)? = nil
  ) -> String? {
    while Date() < deadline {
      let t = readFocusedWindowTitle(pid: pid) ?? ""
      onPoll?(t)
      if let range = t.range(of: prefix) {
        if let json = extractJSONPrefix(String(t[range.upperBound...])) {
          return json
        }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
  }

  /// Extract a balanced JSON object starting at the first `{` in `s`.
  /// Tracks string state + escape sequences so `{` / `}` inside string
  /// literals don't confuse the depth counter.
  private static func extractJSONPrefix(_ s: String) -> String? {
    guard let start = s.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inStr = false
    var escape = false
    var i = start
    while i < s.endIndex {
      let ch = s[i]
      if escape {
        escape = false
        i = s.index(after: i)
        continue
      }
      if inStr {
        if ch == "\\" {
          escape = true
        } else if ch == "\"" {
          inStr = false
        }
      } else {
        if ch == "\"" {
          inStr = true
        } else if ch == "{" {
          depth += 1
        } else if ch == "}" {
          depth -= 1
          if depth == 0 {
            return String(s[start...i])
          }
        }
      }
      i = s.index(after: i)
    }
    return nil
  }

  private static func readFocusedWindowTitle(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var winRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRaw)
        == .success,
      let winCF = winRaw, CFGetTypeID(winCF) == AXUIElementGetTypeID()
    else { return nil }
    let win = winCF as! AXUIElement
    var titleRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRaw) == .success
    else { return nil }
    return titleRaw as? String
  }

  /// Single-pass AX tree walk that collects:
  ///   - the payload div's aria-label (description starts with PAYLOAD_LABEL_PREFIX)
  ///   - each fiducial's screen rect (description matches one of fiducialIDs)
  /// Bails as soon as both are satisfied to keep latency low.
  private static func walkForOracleMarkers(
    pid: pid_t, fiducialIDs: [String]
  ) -> (payload: String?, fiducials: [String: CGRect]) {
    let app = AXUIElementCreateApplication(pid)
    let screenH = primaryScreenHeight()
    var payload: String?
    var fiducials: [String: CGRect] = [:]
    let fiducialSet = Set(fiducialIDs)
    var queue: [AXUIElement] = [app]
    var visited = 0
    let maxNodes = 10000
    while !queue.isEmpty, visited < maxNodes {
      let node = queue.removeFirst()
      visited += 1
      var descRaw: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(
        node, kAXDescriptionAttribute as CFString, &descRaw)
      if let desc = descRaw as? String {
        if payload == nil, desc.hasPrefix(payloadLabelPrefix) {
          payload = desc
        } else if fiducialSet.contains(desc), fiducials[desc] == nil {
          if let rect = rectOf(node, screenH: screenH) {
            fiducials[desc] = rect
          }
        }
        if payload != nil, fiducials.count == fiducialIDs.count { break }
      }
      var childrenRaw: CFTypeRef?
      if AXUIElementCopyAttributeValue(
        node, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
        let children = childrenRaw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return (payload, fiducials)
  }

  private static func rectOf(_ element: AXUIElement, screenH: CGFloat) -> CGRect? {
    var posRaw: CFTypeRef?
    var sizeRaw: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw)
    _ = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw)
    guard let posCF = posRaw, let sizeCF = sizeRaw,
      CFGetTypeID(posCF) == AXValueGetTypeID(),
      CFGetTypeID(sizeCF) == AXValueGetTypeID()
    else { return nil }
    let posV = posCF as! AXValue
    let sizeV = sizeCF as! AXValue
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posV, .cgPoint, &pos),
      AXValueGetValue(sizeV, .cgSize, &size),
      size.width > 0, size.height > 0
    else { return nil }
    let nsY = screenH - pos.y - size.height
    return CGRect(x: pos.x, y: nsY, width: size.width, height: size.height)
  }

  private static func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
  }

  /// Synthesize a key down/up via CGEvent, modifier-isolated.
  ///
  /// `.privateState` does NOT inherit the live HID modifier flags —
  /// without this, if the user is physically holding Cmd/Shift/Opt/Ctrl
  /// when we post 'f', the OS would route Cmd+f (Find) instead of bare
  /// 'f'. `flags = []` is belt-and-suspenders for any latent state
  /// on the source itself.
  private static func postKey(_ keyCode: CGKeyCode, to pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    if let down = CGEvent(
      keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    {
      down.flags = []
      down.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.02)
    if let up = CGEvent(
      keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    {
      up.flags = []
      up.postToPid(pid)
    }
  }
}
