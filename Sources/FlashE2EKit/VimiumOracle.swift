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

    // 3. Wait for Firefox's AX tree to stabilize before snapshotting.
    //    Firefox builds the page's accessibility subtree lazily and
    //    asynchronously after content loads — on big pages
    //    (wikipedia, github, reddit) the tree isn't ready when the
    //    companion fires READY. Poll discover() and take the
    //    snapshot once the target count stops growing for two
    //    consecutive polls (or we hit the timeout).
    let stableDeadline = Date().addingTimeInterval(6)
    var resolvedFlashTargets = flashTargets
    var stableRuns = 0
    var lastCount = -1
    while Date() < stableDeadline {
      let now =
        (try? provider.discover(in: context, deadline: Date().addingTimeInterval(2))) ?? []
      if now.count == lastCount, now.count > 5 {
        stableRuns += 1
        resolvedFlashTargets = now
        if stableRuns >= 2 { break }
      } else {
        lastCount = now.count
        stableRuns = 0
        resolvedFlashTargets = now
      }
      Thread.sleep(forTimeInterval: 0.3)
    }

    // 4. Briefly bring Firefox foreground for the entire scroll-loop
    //    capture. The scroll loop posts 'f' / Escape repeatedly; each
    //    needs to land in Firefox's event queue. Restore previous
    //    frontmost app on exit so the user's editor/terminal comes
    //    back to focus.
    //
    //    Isolation guarantees:
    //    - CGEventSource(.privateState) ignores live HID modifier state
    //    - explicit flags = [] zeroes any latent source modifiers
    let prevFrontmost = NSWorkspace.shared.frontmostApplication
    firefox.activate()
    defer { prevFrontmost?.activate() }
    Thread.sleep(forTimeInterval: 0.15)

    // 5. Scroll-through loop. Per iteration: post 'f' until Vimium
    //    activates + companion captures + signals ANCHORS_READY, walk
    //    AX for payload + fiducials + per-scroll Flash hints, decode,
    //    project, accumulate. If companion reports atBottom, break.
    //    Otherwise post Escape (Vimium dismisses; companion auto-
    //    scrolls via its keydown listener, then sets title back to
    //    READY), wait for READY, continue.
    //
    //    Each scroll cycle is an independent mini-capture: same
    //    element visible across two scrolls yields two entries in
    //    accumulators. The diff matcher pairs by rect proximity and
    //    naturally handles the per-cycle pairing.
    var allFlashTargets: [JumpTarget] = resolvedFlashTargets
    var allVimiumAnchors: [VimiumAnchor] = []
    var lastTransform: OracleTransform?
    var lastResidual: Double = 0
    var lastPageRect: CGRect = .zero

    let maxScrolls = 50
    for scrollIdx in 0..<maxScrolls {
      // 5a. Post 'f' until ANCHORS_READY.
      let anchorsDeadline = Date().addingTimeInterval(anchorsTimeout)
      var gotAnchors = false
      while Date() < anchorsDeadline {
        postKey(kVK_ANSI_F, to: pid)
        let waitChunk = Date().addingTimeInterval(0.9)
        while Date() < waitChunk, Date() < anchorsDeadline {
          let t = readFocusedWindowTitle(pid: pid) ?? ""
          if t.contains(anchorsReadyTitle) {
            gotAnchors = true
            break
          }
          Thread.sleep(forTimeInterval: 0.1)
        }
        if gotAnchors { break }
      }
      if !gotAnchors {
        if scrollIdx == 0 { throw CaptureError.anchorsTimedOut }
        break  // partial result OK after at least one cycle
      }

      // 5b. Walk AX for payload + fiducials.
      let walked = walkForOracleMarkers(pid: pid, fiducialIDs: fiducialIDs)
      guard let payloadDesc = walked.payload else {
        if scrollIdx == 0 {
          throw CaptureError.decodeFailed("payload div not found")
        }
        break
      }
      let rawJSON = String(payloadDesc.dropFirst(payloadLabelPrefix.count))
      let decoded: ExtensionPayload
      do {
        decoded = try JSONDecoder().decode(
          ExtensionPayload.self, from: Data(rawJSON.utf8))
      } catch {
        if scrollIdx == 0 {
          throw CaptureError.decodeFailed(String(describing: error))
        }
        break
      }

      let missing = fiducialIDs.filter { walked.fiducials[$0] == nil }
      if !missing.isEmpty {
        if scrollIdx == 0 { throw CaptureError.missingFiducials(missing) }
        break
      }

      // 5c. Solve transform (fiducials are position:fixed, so the
      //     transform is constant across scrolls — we re-solve every
      //     cycle anyway as a sanity check against drift).
      var pairs: [(css: CGPoint, screen: CGPoint)] = []
      for fid in decoded.fiducials {
        guard let screenRect = walked.fiducials[fid.id] else { continue }
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
        if scrollIdx == 0 { throw CaptureError.transformFailed(error) }
        break
      }
      lastTransform = transform
      lastResidual = transform.maxResidual(pairs: pairs)
      lastPageRect = transform.screenRect(
        fromCSS: CGRect(
          x: 0, y: 0,
          width: decoded.viewport.innerWidth,
          height: decoded.viewport.innerHeight))

      // 5d. Project Vimium anchors + accumulate.
      let anchors: [VimiumAnchor] = decoded.anchors.map { a in
        let cssR = CGRect(
          x: a.rect[0], y: a.rect[1], width: a.rect[2], height: a.rect[3])
        return VimiumAnchor(
          tag: a.tag, role: a.role, label: a.label, marker: a.marker,
          cssRect: cssR, screenRect: transform.screenRect(fromCSS: cssR))
      }
      allVimiumAnchors.append(contentsOf: anchors)

      // 5e. Walk Flash AX again at this scroll position + accumulate.
      //     (First iteration's flashTargets came from the pre-loop
      //     snapshot; subsequent iterations add their post-scroll set.)
      if scrollIdx > 0 {
        let here =
          (try? provider.discover(
            in: context, deadline: Date().addingTimeInterval(2))) ?? []
        allFlashTargets.append(contentsOf: here)
      }

      // 5f. End-of-loop conditions. One line per scroll so a run is
      //     diagnosable from the log without dumping every poll.
      let msg =
        "[oracle] scroll #\(scrollIdx) y=\(Int(decoded.viewport.scrollY)) "
        + "anchors=\(anchors.count)"
        + (decoded.viewport.atBottom == true ? " (bottom)" : "") + "\n"
      FileHandle.standardError.write(Data(msg.utf8))
      if decoded.viewport.atBottom == true { break }

      // 5g. Dismiss Vimium + trigger companion auto-scroll, then
      //     wait for READY (companion has scrolled + reset the title).
      //     Send Escape TWICE: the first one is swallowed by Vimium's
      //     hint-mode handler (it's how Vimium exits hint mode). The
      //     second arrives with Vimium back in default mode, so the
      //     companion's window keydown listener actually sees it and
      //     runs reset() + scroll.
      postKey(kVK_Escape, to: pid)
      Thread.sleep(forTimeInterval: 0.05)
      postKey(kVK_Escape, to: pid)
      let readyDeadline = Date().addingTimeInterval(5)
      var sawReady = false
      while Date() < readyDeadline {
        let t = readFocusedWindowTitle(pid: pid) ?? ""
        if t.contains(readyTitle), !t.contains(anchorsReadyTitle) {
          sawReady = true
          break
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      if !sawReady { break }
      // Wait for Firefox to rebuild the post-scroll AX subtree. The
      // shorter waits we tried saw a 30-50% drop in match rate
      // because Flash's per-scroll discover ran while the new
      // viewport content was still mid-build.
      Thread.sleep(forTimeInterval: 0.9)
    }

    guard let transform = lastTransform else {
      throw CaptureError.anchorsTimedOut  // never got past iteration 0
    }
    return OracleSnapshot(
      flashTargets: allFlashTargets, vimiumAnchors: allVimiumAnchors,
      transform: transform, fiducialResidual: lastResidual,
      pageScreenRect: lastPageRect)
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
    let scrollHeight: Double?
    let atBottom: Bool?
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
