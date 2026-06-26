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
  public let screenRect: CGRect

  public init(
    tag: String, role: String, label: String, marker: String,
    screenRect: CGRect
  ) {
    self.tag = tag
    self.role = role
    self.label = label
    self.marker = marker
    self.screenRect = screenRect
  }
}

public struct OracleSnapshot {
  /// The finalized Flash targets after visibility filtering and spatial
  /// deduplication, matching the resident app's hint pipeline.
  public let flashTargets: [JumpTarget]
  public let vimiumAnchors: [VimiumAnchor]
  public let hintWidthSamples: [HintWidthSample]
  public let fiducialResidual: Double
  /// Screen-space bounds of the page viewport, derived from the
  /// Marionette-reported `viewport.innerWidth/innerHeight` projected
  /// through `transform`.
  public let pageScreenRect: CGRect

  public init(
    flashTargets: [JumpTarget], vimiumAnchors: [VimiumAnchor],
    hintWidthSamples: [HintWidthSample],
    fiducialResidual: Double,
    pageScreenRect: CGRect
  ) {
    self.flashTargets = flashTargets
    self.vimiumAnchors = vimiumAnchors
    self.hintWidthSamples = hintWidthSamples
    self.fiducialResidual = fiducialResidual
    self.pageScreenRect = pageScreenRect
  }
}

public struct HintWidthSample {
  public let scrollIndex: Int
  public let vimiumTargetCount: Int
  public let vimiumMaxLabelLength: Int
  public let flashRawTargetCount: Int
  public let flashTargetCount: Int
  public let flashMaxLabelLength: Int

  public init(
    scrollIndex: Int,
    vimiumTargetCount: Int,
    vimiumMaxLabelLength: Int,
    flashRawTargetCount: Int,
    flashTargetCount: Int,
    flashMaxLabelLength: Int
  ) {
    self.scrollIndex = scrollIndex
    self.vimiumTargetCount = vimiumTargetCount
    self.vimiumMaxLabelLength = vimiumMaxLabelLength
    self.flashRawTargetCount = flashRawTargetCount
    self.flashTargetCount = flashTargetCount
    self.flashMaxLabelLength = flashMaxLabelLength
  }
}

/// Drives the per-fixture capture sequence. Vimium-FF remains the oracle,
/// but Marionette now owns the whole harness side: page setup, DOM marker
/// capture, keyboard input, and dismissal. No unsigned companion extension
/// is installed in Firefox.
public enum VimiumOracle {
  public enum CaptureError: Error, CustomStringConvertible {
    case setupFailed(String)
    case anchorsTimedOut
    case decodeFailed(String)
    case missingFiducials([String])
    case transformFailed(Error)

    public var description: String {
      switch self {
      case .setupFailed(let why):
        return "Browser fixture setup failed: \(why)"
      case .anchorsTimedOut:
        return """
          Vimium markers never appeared after the 'f' keystroke. Check:
            - Vimium-FF loaded into the test profile
            - the page context, not browser chrome, receives WebDriver key actions
            - the fixture did not intercept bare 'f'
          """
      case .decodeFailed(let why):
        return "Failed to decode Marionette capture payload: \(why)"
      case .missingFiducials(let ids):
        return "Fiducials not found in Firefox AX tree: \(ids.joined(separator: ", "))"
      case .transformFailed(let e):
        return "Could not solve coordinate transform: \(e)"
      }
    }
  }

  private static let fiducialIDs = [
    "__flash_oracle_fiducial_a__",
    "__flash_oracle_fiducial_b__",
  ]
  private static let webdriverEscape = "\u{e00C}"

  public static func capture(
    firefox: NSRunningApplication,
    context: AppContext,
    provider: AccessibilityProvider,
    marionette: MarionetteClient,
    anchorsTimeout: TimeInterval = 10
  ) throws -> OracleSnapshot {
    let pid = firefox.processIdentifier

    guard let setupValue = try marionette.executeScript(setupScript, args: [0])
    else {
      throw CaptureError.setupFailed("setup script returned nil")
    }
    _ = setupValue

    let flashTargets = waitForStableFlashTargets(
      provider: provider,
      context: context,
      timeout: 10)

    let anchorsDeadline = Date().addingTimeInterval(anchorsTimeout)
    var decoded: ExtensionPayload?
    while Date() < anchorsDeadline {
      _ = try? marionette.tapKey("f")
      let waitChunk = Date().addingTimeInterval(0.9)
      while Date() < waitChunk, Date() < anchorsDeadline {
        if let value = try? marionette.executeScript(captureScript),
          let payload = try? decodePayload(value),
          !payload.anchors.isEmpty
        {
          decoded = payload
          break
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      if decoded != nil { break }
    }
    guard let decoded else { throw CaptureError.anchorsTimedOut }

    var pairs: [(css: CGPoint, screen: CGPoint)] = []
    let walkedFiducials = waitForFiducials(pid: pid, fiducialIDs: fiducialIDs, timeout: 4)
    let missing = fiducialIDs.filter { walkedFiducials[$0] == nil }
    if missing.isEmpty {
      for fid in decoded.fiducials {
        guard let screenRect = walkedFiducials[fid.id] else { continue }
        pairs.append(
          (
            css: CGPoint(x: fid.x, y: fid.y),
            screen: CGPoint(x: screenRect.minX, y: screenRect.maxY)
          ))
      }
    }
    let transform: OracleTransform
    let residual: Double
    do {
      if pairs.count >= 2 {
        transform = try OracleTransform.solve(pairs: pairs)
        residual = transform.maxResidual(pairs: pairs)
      } else if let webAreaFrame = FirefoxHarness.findWebAreaFrame(pid: pid) {
        transform = try OracleTransform.viewport(
          webAreaFrame: webAreaFrame,
          innerWidth: decoded.viewport.innerWidth,
          innerHeight: decoded.viewport.innerHeight)
        residual = 0
      } else if let screenX = decoded.viewport.mozInnerScreenX,
        let screenY = decoded.viewport.mozInnerScreenY
      {
        transform = try OracleTransform.firefoxViewport(
          topLeftX: screenX,
          topLeftY: screenY,
          screenHeight: Double(primaryScreenHeight()),
          innerWidth: decoded.viewport.innerWidth,
          innerHeight: decoded.viewport.innerHeight)
        residual = 0
      } else {
        throw CaptureError.missingFiducials(missing)
      }
    } catch {
      throw CaptureError.transformFailed(error)
    }
    let pageRect = transform.screenRect(
      fromCSS: CGRect(
        x: 0, y: 0,
        width: decoded.viewport.innerWidth,
        height: decoded.viewport.innerHeight))

    let anchors: [VimiumAnchor] = decoded.anchors.map { a in
      let cssR = CGRect(
        x: a.rect[0], y: a.rect[1], width: a.rect[2], height: a.rect[3])
      return VimiumAnchor(
        tag: a.tag, role: a.role, label: a.label, marker: a.marker,
        screenRect: transform.screenRect(fromCSS: cssR))
    }

    let flashCandidates = flashTargets.enumerated().map { ordinal, target in
      TargetCandidate(
        target: target,
        priority: provider.priority,
        providerOrder: 0,
        ordinal: ordinal)
    }
    let flashFinalized = TargetFinalizer.finalizeWithStats(
      flashCandidates,
      visibleRegions: [pageRect])
    let finalizedTargets = flashFinalized.targets
    let samples = [
      HintWidthSample(
        scrollIndex: 0,
        vimiumTargetCount: anchors.count,
        vimiumMaxLabelLength: anchors.map { $0.marker.count }.max() ?? 0,
        flashRawTargetCount: flashFinalized.rawCount,
        flashTargetCount: flashFinalized.dedupedCount,
        flashMaxLabelLength: maxFlashHintLength(targetCount: flashFinalized.dedupedCount))
    ]

    _ = try? marionette.tapKey(webdriverEscape)

    return OracleSnapshot(
      flashTargets: finalizedTargets,
      vimiumAnchors: anchors,
      hintWidthSamples: samples,
      fiducialResidual: residual,
      pageScreenRect: pageRect)
  }

  /// Waits for Firefox's accessibility tree to finish materializing *and* for
  /// the page layout to stop moving, then returns the settled target set.
  ///
  /// Two independent races corrupt a naive "two equal readings" gate:
  ///
  ///  1. *Incomplete tree.* Firefox builds a page's AX tree incrementally and
  ///     lazily — window chrome surfaces first, then the document's controls
  ///     stream in, more slowly the busier the machine is. Settling on the
  ///     first stable count accepts a chrome-only plateau and returns a
  ///     partial set, which shows up as spurious vimium-only divergences.
  ///
  ///  2. *Reflow.* Captured pages run their own JS (banners animating in,
  ///     async fonts/images) that shifts every control's position after first
  ///     paint without changing the control *count*. Flash captures before
  ///     Vimium does, so if Flash reads during the shift the two see the same
  ///     buttons ~100pt apart and the diff reports them as unmatched.
  ///
  /// Both are caught by settling on a coarse signature — the target count plus
  /// the median centroid Y. The count catches an incomplete tree; the median Y
  /// catches a whole-page reflow (a banner pushing every control down moves the
  /// median sharply) while staying blind to the local sub-pixel jitter of an
  /// individual animating element, which a per-control comparison would treat
  /// as perpetual motion and never let the gate settle. A transient count dip
  /// (a node momentarily vanishing) is ignored so it can neither reset the
  /// timer nor lower the result. If the page never settles within `timeout`,
  /// the most recent reading is returned.
  private static func waitForStableFlashTargets(
    provider: AccessibilityProvider,
    context: AppContext,
    timeout: TimeInterval
  ) -> [JumpTarget] {
    let start = Date()
    let deadline = start.addingTimeInterval(timeout)
    // Don't accept a "settled" reading before this much wall time has passed.
    // Some captures inject content on a delay (a banner appearing a second or
    // two after first paint adds its own controls and pushes the rest of the
    // page down). The tree looks stable in the meantime, so without a floor the
    // gate exits before the injection fires and captures the pre-injection
    // layout — then Vimium, which reads a beat later, sees the post-injection
    // layout and the diff reports the moved controls as unmatched. Observing
    // for a minimum window lets the injection land and be absorbed as ordinary
    // count growth.
    let minObserve: TimeInterval = 3.0
    let settle: TimeInterval = 1.0
    let medianTolerance: CGFloat = 8
    var current: [JumpTarget] = []
    var currentMedianY = CGFloat.nan
    var lastChange = Date()
    while Date() < deadline {
      let now = (try? provider.discover(in: context)) ?? []
      let medianY = medianCentroidY(now)
      let changed =
        now.count != current.count
        || currentMedianY.isNaN
        || abs(medianY - currentMedianY) > medianTolerance
      if now.count < current.count {
        // Transient dip — keep the richer snapshot and the settle timer.
      } else if changed {
        current = now
        currentMedianY = medianY
        lastChange = Date()
      } else if !current.isEmpty,
        Date().timeIntervalSince(lastChange) >= settle,
        Date().timeIntervalSince(start) >= minObserve
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    return current
  }

  private static func medianCentroidY(_ targets: [JumpTarget]) -> CGFloat {
    guard !targets.isEmpty else { return .nan }
    let ys = targets.map { $0.frame.midY }.sorted()
    return ys[ys.count / 2]
  }

  private static func maxFlashHintLength(targetCount: Int) -> Int {
    guard targetCount > 0 else { return 0 }
    let alphabetSize = 26
    var length = 1
    var capacity = alphabetSize
    while capacity < targetCount {
      length += 1
      capacity *= alphabetSize
    }
    return length
  }

  private static func decodePayload(_ value: Any) throws -> ExtensionPayload {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw CaptureError.decodeFailed("non-JSON value \(value)")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    return try JSONDecoder().decode(ExtensionPayload.self, from: data)
  }

  // MARK: - Wire types

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
  }
  private struct Viewport: Decodable {
    let innerWidth: Double
    let innerHeight: Double
    let mozInnerScreenX: Double?
    let mozInnerScreenY: Double?
  }

  // MARK: - AX helpers

  private static func waitForFiducials(
    pid: pid_t, fiducialIDs: [String], timeout: TimeInterval
  ) -> [String: CGRect] {
    let deadline = Date().addingTimeInterval(timeout)
    var best: [String: CGRect] = [:]
    while Date() < deadline {
      let found = walkForFiducials(pid: pid, fiducialIDs: fiducialIDs)
      if found.count > best.count { best = found }
      if found.count == fiducialIDs.count { return found }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return best
  }

  private static func walkForFiducials(
    pid: pid_t, fiducialIDs: [String]
  ) -> [String: CGRect] {
    let app = AXUIElementCreateApplication(pid)
    wakeAccessibility(app)
    let screenH = primaryScreenHeight()
    var fiducials: [String: CGRect] = [:]
    let fiducialSet = Set(fiducialIDs)
    var queue = fiducialRoots(app)
    var visited = 0
    let maxNodes = 10000
    while !queue.isEmpty, visited < maxNodes {
      let node = queue.removeFirst()
      visited += 1
      if let label = fiducialLabel(node),
        fiducialSet.contains(label),
        fiducials[label] == nil,
        let rect = rectOf(node, screenH: screenH)
      {
        fiducials[label] = rect
        if fiducials.count == fiducialIDs.count { break }
      }
      var childrenRaw: CFTypeRef?
      if AXUIElementCopyAttributeValue(
        node, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
        let children = childrenRaw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return fiducials
  }

  private static func wakeAccessibility(_ app: AXUIElement) {
    let trueRef = kCFBooleanTrue as CFTypeRef
    _ = AXUIElementSetAttributeValue(
      app, "AXEnhancedUserInterface" as CFString, trueRef)
    _ = AXUIElementSetAttributeValue(
      app, "AXManualAccessibility" as CFString, trueRef)
  }

  private static func fiducialRoots(_ app: AXUIElement) -> [AXUIElement] {
    var roots: [AXUIElement] = []
    var focusedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRaw)
      == .success,
      let focused = focusedRaw,
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
      roots.append(focused as! AXUIElement)
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRaw)
      == .success,
      let windows = windowsRaw as? [AXUIElement]
    {
      roots.append(contentsOf: windows)
    }
    if roots.isEmpty { roots.append(app) }
    return roots
  }

  private static func fiducialLabel(_ element: AXUIElement) -> String? {
    for attribute in [
      kAXTitleAttribute,
      kAXDescriptionAttribute,
      kAXValueAttribute,
      kAXHelpAttribute,
      kAXIdentifierAttribute,
    ] {
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
        let value = raw as? String,
        !value.isEmpty
      {
        return value
      }
    }
    return nil
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

  // MARK: - Marionette scripts

  private static let setupScript = """
    const scrollY = Number(arguments[0] || 0);
    const fiducials = [
      ["__flash_oracle_fiducial_a__", 40, 40],
      ["__flash_oracle_fiducial_b__", 800, 600],
    ];
    for (const [id, left, top] of fiducials) {
      let d = document.getElementById(id);
      if (!d) {
        d = document.createElement("div");
        d.id = id;
        d.setAttribute("role", "img");
        d.setAttribute("aria-label", id);
        d.style.cssText =
          "position:fixed;left:" + left + "px;top:" + top + "px;" +
          "width:8px;height:8px;background:#ff00aa;z-index:2147483646;" +
          "pointer-events:none;";
        document.documentElement.appendChild(d);
      }
    }
    window.scrollTo(0, scrollY);
    window.focus();
    if (document.body) {
      document.body.setAttribute("tabindex", document.body.getAttribute("tabindex") || "-1");
      document.body.focus({ preventScroll: true });
    }
    return { ready: true, title: document.title, scrollY: window.scrollY };
    """

  private static let captureScript = """
    const MARKER_REGEX = /vimium.*[Hh]int.*[Mm]arker|vimium-hint-marker/;
    const FIDUCIAL_IDS = ["__flash_oracle_fiducial_a__", "__flash_oracle_fiducial_b__"];

    function implicitRole(el) {
      const tag = el.tagName.toLowerCase();
      switch (tag) {
        case "a": return el.hasAttribute("href") ? "link" : "";
        case "button": return "button";
        case "input": {
          const t = (el.getAttribute("type") || "text").toLowerCase();
          if (t === "submit" || t === "button" || t === "reset") return "button";
          if (t === "checkbox") return "checkbox";
          if (t === "radio") return "radio";
          if (t === "search") return "searchbox";
          return "textbox";
        }
        case "select": return "combobox";
        case "textarea": return "textbox";
        case "summary": return "button";
        default: return "";
      }
    }

    function readFiducials() {
      return FIDUCIAL_IDS.map((id) => {
        const el = document.getElementById(id);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { id, x: r.left, y: r.top, w: r.width, h: r.height };
      }).filter(Boolean);
    }

    function findMarkers() {
      const out = [];
      for (const el of document.querySelectorAll("*")) {
        const cls = el.className;
        if (typeof cls !== "string" || cls.length === 0) continue;
        if (!MARKER_REGEX.test(cls)) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        out.push(el);
      }
      return out;
    }

    function resolveAnchor(marker) {
      const r = marker.getBoundingClientRect();
      const probes = [
        [r.left + r.width / 2, r.bottom + 2],
        [r.right + 2, r.top + r.height / 2],
        [r.right + 2, r.bottom + 2],
        [r.left + r.width / 2, r.top + r.height / 2],
      ];
      const interactiveRoles = new Set([
        "button",
        "checkbox",
        "combobox",
        "link",
        "menuitem",
        "menuitemcheckbox",
        "menuitemradio",
        "option",
        "radio",
        "searchbox",
        "slider",
        "switch",
        "tab",
        "textbox"
      ]);
      function isInteractive(el) {
        if (!el || !el.tagName) return false;
        if (
          el.closest("[aria-hidden='true'], [hidden], [inert]") ||
          el.getAttribute("aria-disabled") === "true" ||
          el.disabled
        ) {
          return false;
        }
        const tag = el.tagName.toLowerCase();
        if (
          tag === "a" || tag === "button" || tag === "input" ||
          tag === "select" || tag === "textarea" || tag === "summary"
        ) {
          return true;
        }
        if (tag === "body" || tag === "html") return false;
        const role = (el.getAttribute("role") || "").toLowerCase();
        if (role && !interactiveRoles.has(role)) return false;
        return (
          el.hasAttribute("tabindex") || interactiveRoles.has(role) ||
          el.hasAttribute("onclick") || el.isContentEditable
        );
      }
      for (const [px, py] of probes) {
        const hit = document.elementFromPoint(px, py);
        let cur = hit;
        let walked = 0;
        while (cur && walked < 8) {
          if (isInteractive(cur)) return cur;
          cur = cur.parentElement;
          walked++;
        }
      }
      return null;
    }

    function serializeAnchors(markers) {
      const hiddenStyles = markers.map((m) => m.style.visibility);
      markers.forEach((m) => (m.style.visibility = "hidden"));
      try {
        const seen = new Set();
        const anchors = [];
        const viewport = {
          left: 0,
          top: 0,
          right: window.innerWidth,
          bottom: window.innerHeight
        };
        function hasVisibleCenter(r) {
          const cx = r.left + r.width / 2;
          const cy = r.top + r.height / 2;
          return cx >= viewport.left && cx <= viewport.right &&
            cy >= viewport.top && cy <= viewport.bottom;
        }
        for (const marker of markers) {
          const target = resolveAnchor(marker);
          if (!target || seen.has(target)) continue;
          seen.add(target);
          const r = target.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) continue;
          if (!hasVisibleCenter(r)) continue;
          const label =
            target.getAttribute("aria-label") ||
            target.getAttribute("title") ||
            (target.textContent || "").trim().slice(0, 40);
          anchors.push({
            tag: target.tagName.toLowerCase(),
            role: target.getAttribute("role") || implicitRole(target),
            rect: [
              Math.round(r.left * 100) / 100,
              Math.round(r.top * 100) / 100,
              Math.round(r.width * 100) / 100,
              Math.round(r.height * 100) / 100
            ],
            label,
            marker: (marker.textContent || "").trim()
          });
        }
        return anchors;
      } finally {
        markers.forEach((m, i) => (m.style.visibility = hiddenStyles[i] || ""));
      }
    }

    const docH = Math.max(
      document.documentElement.scrollHeight,
      document.body ? document.body.scrollHeight : 0
    );
    const markers = findMarkers();
    return {
      anchors: serializeAnchors(markers),
      fiducials: readFiducials(),
      viewport: {
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        dpr: window.devicePixelRatio,
        scrollHeight: docH,
        atBottom: window.scrollY + window.innerHeight >= docH - 10,
        mozInnerScreenX: Number.isFinite(window.mozInnerScreenX) ? window.mozInnerScreenX : null,
        mozInnerScreenY: Number.isFinite(window.mozInnerScreenY) ? window.mozInnerScreenY : null
      }
    };
    """
}
