import AppKit
import FlashCore

/// Vimium-style DOM discovery for Safari + Chromium-family browsers via
/// AppleScript `do JavaScript`. Subclasses supply the bundle id list and the
/// AppleScript syntax for "run JS in the active tab".
///
/// Why a script bridge instead of the AX walker:
///   - AX exposes the page through `AXWebArea` descendants, but the rects
///     are often wrong (missing for non-rendered nodes, stale during
///     scrolling, missing entirely for elements without an accessible name).
///   - JS in the page has the authoritative geometry via
///     `getClientRects()` and the authoritative semantics via roles +
///     tabindex + click handlers.
///   - The browsers gate `do JavaScript` behind "Allow JavaScript from
///     Apple Events" (Safari Develop menu, Chromium View → Developer menu).
///     When that toggle is off, this provider returns nothing and the
///     generic AX walker handles the page anyway.
///
/// Permission requirements at runtime:
///   - Accessibility (read elsewhere)
///   - **Automation → Safari / Chrome** — prompted on first use
///   - **Allow JavaScript from Apple Events** — set by the user in the
///     browser's Develop menu. If denied, the bridge silently returns 0
///     targets and the AX walker fills in the rest.
///
/// **The clickability + visibility rules are a direct port of Vimium's
/// `LocalHints.getLocalHintsForElement` and `DomUtils.getVisibleClientRect`.**
/// See `discoveryJS` below for the per-rule citation. When updating, diff
/// against the upstream files and bump the commit SHA in the comment block.
/// The sync policy is documented in `AGENTS.md` under "Browser DOM bridge".
open class BrowserScriptProvider: JumpProvider {
  public let identifier: String
  public let priority: Int
  public let supportedBundles: Set<String>
  private var bridgeRetryAfter: Date?

  public init(
    identifier: String,
    priority: Int,
    supportedBundles: Set<String>
  ) {
    self.identifier = identifier
    self.priority = priority
    self.supportedBundles = supportedBundles
  }

  open func supports(_ context: AppContext) -> Bool {
    supportedBundles.contains(context.bundleIdentifier)
  }

  /// Build the AppleScript that runs `js` in the active tab. Subclasses
  /// emit the bundle-specific verb (`do JavaScript in document 1` vs
  /// `execute active tab of window 1 javascript`).
  open func appleScript(running js: String) -> String {
    fatalError("BrowserScriptProvider subclasses must override appleScript(running:)")
  }

  public func discover(in context: AppContext, deadline _: Date) throws -> [JumpTarget] {
    // The discovery JS returns a JSON array of
    // `[id, screenX_topLeft, screenY_topLeft, w, h, tag]` tuples — keys
    // chosen for compactness to keep the AppleScript string short.
    if let retryAfter = bridgeRetryAfter, Date() < retryAfter {
      return []
    }
    guard let raw = runEscapedJS(Self.escapedDiscoveryJS) else {
      // Bridge failures are usually permission/configuration problems:
      // Automation denied, no document, or "Allow JavaScript from Apple
      // Events" disabled. Back off briefly so the generic AX fallback
      // does not pay the same AppleScript failure cost on every
      // activation while still recovering quickly after the user fixes
      // the browser setting.
      bridgeRetryAfter = Date().addingTimeInterval(5)
      return []
    }
    bridgeRetryAfter = nil
    guard let data = raw.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
    else {
      return []
    }

    let screenH = primaryScreenHeight()
    var out: [JumpTarget] = []
    out.reserveCapacity(arr.count)

    for entry in arr {
      guard entry.count >= 5,
        let id = (entry[0] as? NSNumber)?.intValue,
        let sx = (entry[1] as? NSNumber)?.doubleValue,
        let sy = (entry[2] as? NSNumber)?.doubleValue,
        let w = (entry[3] as? NSNumber)?.doubleValue,
        let h = (entry[4] as? NSNumber)?.doubleValue
      else { continue }
      let tag = (entry.count > 5 ? entry[5] : nil) as? String
      // sx/sy are top-left in JS screen coords (Y-down, origin
      // top-left of primary). Flip to NSScreen (Y-up, origin
      // bottom-left of primary).
      let nsY = screenH - CGFloat(sy) - CGFloat(h)
      let frame = CGRect(x: CGFloat(sx), y: nsY, width: CGFloat(w), height: CGFloat(h))
      if frame.width < 2 || frame.height < 2 { continue }

      let provider = self
      let activate: ((JumpAction) -> Bool) = { action in
        provider.commitClick(id: id, action: action, tag: tag)
      }
      out.append(
        JumpTarget(
          id: "dom-\(context.processID)-\(id)",
          frame: frame,
          role: tag,
          accessibilityLabel: nil,
          pid: context.processID,
          activate: activate,
          providerID: identifier
        ))
    }
    return out
  }

  private func commitClick(id: Int, action: JumpAction, tag: String?) -> Bool {
    let isInput = (tag == "input" || tag == "textarea" || tag == "select")
    let js: String
    switch action {
    case .leftClick:
      // Focus inputs (so the user can immediately type), click
      // everything else. `el.click()` is gated to trusted-only for a
      // handful of actions (form submission via `submit()` etc) but
      // dispatches a real click on anchors, buttons, and
      // role=button. For inputs, focus + selection is what the user
      // actually wants from a hint.
      if isInput {
        js = """
          (function(){var e=document.querySelector('[data-flash-id="\(id)"]');if(!e)return false;e.focus();if(e.select)e.select();return true;})()
          """
      } else {
        js = """
          (function(){var e=document.querySelector('[data-flash-id="\(id)"]');if(!e)return false;e.click();return true;})()
          """
      }
    case .rightClick:
      // Synthetic contextmenu event. Native browser context menus
      // aren't always triggered from dispatchEvent but custom in-page
      // menus (Notion, Linear, GitHub) handle this fine.
      js = """
        (function(){var e=document.querySelector('[data-flash-id="\(id)"]');if(!e)return false;var r=e.getBoundingClientRect();var ev=new MouseEvent('contextmenu',{bubbles:true,cancelable:true,view:window,button:2,clientX:r.left+r.width/2,clientY:r.top+r.height/2});e.dispatchEvent(ev);return true;})()
        """
    }
    guard let raw = runJS(js) else { return false }
    return raw.trimmingCharacters(in: .whitespaces).lowercased() == "true"
  }

  /// Run `js` via AppleScript. Returns the JS expression's string value, or
  /// nil if the bridge failed (Automation denied, document missing,
  /// JavaScript-from-AE not enabled).
  private func runJS(_ js: String) -> String? {
    runEscapedJS(Self.escapeForAppleScript(js))
  }

  private func runEscapedJS(_ escaped: String) -> String? {
    let source = appleScript(running: escaped)
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let descriptor = script.executeAndReturnError(&error)
    if error != nil { return nil }
    return descriptor.stringValue
  }

  private static func escapeForAppleScript(_ js: String) -> String {
    js
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  // MARK: Vimium-ported discovery JS
  //
  // Ported from philc/vimium @ 7f4deb3f91dda66fe2aef0d4a34fc96ebef96c22.
  // Specifically these upstream files:
  //
  //   content_scripts/link_hints.js
  //     - LocalHints.getLocalHintsForElement  (clickability rules)
  //     - LocalHints.getLocalHints            (collect → reverse → false-pos → overlap)
  //     - LocalHints.getElementFromPoint      (shadow-DOM aware hit test)
  //
  //   lib/dom_utils.js
  //     - DomUtils.getVisibleClientRect       (rect iteration + crop + visibility)
  //     - DomUtils.cropRectToVisible          (viewport clip)
  //     - DomUtils.isSelectable               (input/textarea/contentEditable predicate)
  //
  // The port is intentionally line-by-line where possible so future
  // diffs against Vimium upstream are easy to read. Pieces deliberately
  // omitted (because they target Vimium-specific UX, not "click and
  // jump"):
  //   - Image-map (<area>) hint expansion. Rare on modern web; would need
  //     getClientRectsForAreas + map-name lookup. Add if reports show it's
  //     missed.
  //   - <body>-as-frame and scrollable <div>/<ol>/<ul> hints — Vimium uses
  //     these for frame focus + scroll commands; Flash has no equivalent
  //     semantic.
  //   - AngularJS ng-click attribute family — most modern pages don't use
  //     classic Angular. Trivial to re-add if reports show misses on
  //     legacy ng-scope pages.
  //   - Cross-frame walking. Vimium injects per-frame as a content
  //     script; we only get the top window via `do JavaScript`. Same-
  //     origin iframes are reachable via `iframe.contentDocument` but we
  //     don't recurse to keep the script size + latency budget tight.
  //
  // Shadow DOM is included.
  //
  // When updating: diff `link_hints.js` + `dom_utils.js` at the new
  // upstream commit against this file, bump the commit SHA above, and
  // update AGENTS.md → "Browser DOM bridge" if any predicate changes
  // category.
  private static let escapedDiscoveryJS = escapeForAppleScript(discoveryJS)

  static let discoveryJS: String = """
    (function(){
      // ----- DomUtils.cropRectToVisible -----
      // Origin clipped to (0,0) but right/bottom are left unbounded; rect
      // is rejected entirely if its origin is outside the viewport.
      function cropAndCheck(r){
        var left = Math.max(r.left, 0);
        var top = Math.max(r.top, 0);
        var width = r.right - left;
        var height = r.bottom - top;
        if (width < 3 || height < 3) return null;
        if (top >= window.innerHeight - 4) return null;
        if (left >= window.innerWidth - 4) return null;
        return {left: left, top: top, width: width, height: height};
      }

      // ----- DomUtils.getVisibleClientRect -----
      // Iterates getClientRects() so multi-line inline elements use their
      // first visible line as the hint anchor. Requires
      // computedStyle.visibility === 'visible' (rejects both 'hidden' and
      // 'collapse', matching Vimium).
      function getVisibleClientRect(el){
        var rects = el.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var cropped = cropAndCheck(rects[i]);
          if (!cropped) continue;
          var cs = getComputedStyle(el, null);
          if (cs.getPropertyValue('visibility') !== 'visible') continue;
          return cropped;
        }
        return null;
      }

      // ----- DomUtils.isSelectable -----
      // "Selectable" = input types where simulateSelect (focus + select
      // text) is the right action. Used by the <input readOnly> case in
      // hintData.
      function isSelectable(el){
        if (!(el instanceof Element)) return false;
        var unsel = ['button','checkbox','color','file','hidden','image','radio','reset','submit'];
        var name = el.nodeName.toLowerCase();
        return (name === 'input' && unsel.indexOf(el.type) === -1) ||
               name === 'textarea' || el.isContentEditable;
      }

      // ----- LocalHints.getElementFromPoint -----
      // elementFromPoint with shadow-DOM descent. The stack guards against
      // a shadow root pointing at its own host.
      function getElementFromPoint(x, y, root, stack){
        root = root || document;
        stack = stack || [];
        var el = root.elementsFromPoint
          ? root.elementsFromPoint(x, y)[0]
          : root.elementFromPoint(x, y);
        if (stack.indexOf(el) !== -1) return el;
        stack.push(el);
        if (el && el.shadowRoot) {
          return getElementFromPoint(x, y, el.shadowRoot, stack) || el;
        }
        return el;
      }

      // ----- LocalHints.getLocalHintsForElement -----
      // The clickability rules. Returns null (not clickable / aria-
      // disabled) or {falsePos, secondClass} on success.
      function hintData(el){
        if (!el || !el.tagName) return null;
        var tag = el.tagName.toLowerCase ? el.tagName.toLowerCase() : '';
        var clickable = false;
        var falsePos = false;
        var secondClass = false;

        // aria-disabled='' or 'true' suppresses entirely.
        var ad = el.getAttribute('aria-disabled');
        if (ad !== null) {
          var adl = ad.toLowerCase();
          if (adl === '' || adl === 'true') return null;
        }

        // onclick attribute → clickable.
        if (el.hasAttribute('onclick')) {
          clickable = true;
        } else {
          // role= one of the standard clickable roles → clickable.
          var role = el.getAttribute('role');
          var roles = {button:1,tab:1,link:1,checkbox:1,menuitem:1,menuitemcheckbox:1,menuitemradio:1,radio:1,textbox:1};
          if (role && roles[role.toLowerCase()]) {
            clickable = true;
          } else {
            // contentEditable='' / 'contenteditable' / 'true' → clickable.
            var ce = el.getAttribute('contentEditable');
            if (ce !== null) {
              var cel = ce.toLowerCase();
              if (cel === '' || cel === 'contenteditable' || cel === 'true') clickable = true;
            }
          }
        }

        // jsaction= attribute (Google framework — Gmail / Drive / Calendar
        // rely on this heavily). Parse `event[:namespace.action]`
        // semicolon-separated rules. A `click` event with namespace !==
        // 'none' and action !== '_' marks the element clickable.
        if (!clickable && el.hasAttribute('jsaction')) {
          var rules = el.getAttribute('jsaction').split(';');
          for (var i = 0; i < rules.length; i++) {
            var s = rules[i].trim().split(':');
            if (s.length < 1 || s.length > 2) continue;
            var ev, ns, an;
            if (s.length === 1) {
              var p = s[0].trim().split('.');
              ev = 'click'; ns = p[0]; an = p[1] || '_';
            } else {
              ev = s[0];
              var p2 = s[1].trim().split('.');
              ns = p2[0]; an = p2[1] || '_';
            }
            if (ev === 'click' && ns !== 'none' && an !== '_') {
              clickable = true;
              break;
            }
          }
        }

        // Native-tag rules.
        switch (tag) {
          case 'a':
            clickable = true;
            break;
          case 'textarea':
            clickable = clickable || (!el.disabled && !el.readOnly);
            break;
          case 'input':
            clickable = clickable || !(
              (el.getAttribute('type') || '').toLowerCase() === 'hidden' ||
              el.disabled ||
              (el.readOnly && isSelectable(el))
            );
            break;
          case 'button':
          case 'select':
            clickable = clickable || !el.disabled;
            break;
          case 'object':
          case 'embed':
            clickable = true;
            break;
          case 'label':
            // Only hint the label if its control would NOT otherwise get a
            // hint on its own — avoids double-hinting a label + its input.
            if (!clickable && el.control && !el.control.disabled) {
              if (hintData(el.control) === null) clickable = true;
            }
            break;
          case 'img':
            // `cursor: zoom-in/zoom-out` is the conventional opt-in for a
            // clickable image (lightbox, gallery).
            if (el.style.cursor === 'zoom-in' || el.style.cursor === 'zoom-out') clickable = true;
            break;
          case 'details':
            clickable = true;
            break;
        }

        // class~='button' / 'btn' heuristic. Real clickables are often
        // wrapped in elements with these class names, so we treat the
        // match as a possible false positive — the descendant filter below
        // will drop us if a closer-in clickable also matched.
        if (!clickable) {
          var cls = el.getAttribute('class');
          if (cls) {
            var cl = cls.toLowerCase();
            if (cl.indexOf('button') !== -1 || cl.indexOf('btn') !== -1) {
              clickable = true;
              falsePos = true;
            }
          }
        }

        // <span> is suspicious; same descendant-filter treatment.
        if (tag === 'span') falsePos = true;

        // tabindex >= 0 — second-class citizen (skipped by overlap filter).
        if (!clickable) {
          var ti = el.getAttribute('tabindex');
          if (ti !== null) {
            var n = parseInt(ti, 10);
            if (!isNaN(n) && n >= 0) {
              clickable = true;
              secondClass = true;
            }
          }
        }

        if (!clickable) return null;
        return {falsePos: falsePos, secondClass: secondClass};
      }

      // ----- LocalHints.getLocalHints (element collection) -----
      // querySelectorAll('*') for the document plus a recursive descent
      // into every element's shadowRoot. Iteration order matches DOM
      // order, which the false-positive + overlap filters depend on.
      function collectAll(root, out){
        var els = root.querySelectorAll('*');
        for (var i = 0; i < els.length; i++) {
          out.push(els[i]);
          if (els[i].shadowRoot) collectAll(els[i].shadowRoot, out);
        }
        return out;
      }

      if (!document.documentElement) return '[]';
      var all = collectAll(document.documentElement, []);

      // Run hintData + visible-rect for each element.
      var hints = [];
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        var d = hintData(el);
        if (!d) continue;
        var rect = getVisibleClientRect(el);
        if (!rect) continue;
        hints.push({el: el, rect: rect, falsePos: d.falsePos, secondClass: d.secondClass});
      }

      // Reverse so descendants are processed before ancestors — both
      // subsequent filters depend on this.
      hints.reverse();

      // False-positive descendant filter: drop a `falsePos` hint if a
      // descendant within 3 generations is also a hint, where the
      // descendant appeared within the previous 6 hints (DOM-order-wise
      // a close descendant).
      var kept = [];
      for (var i = 0; i < hints.length; i++) {
        var h = hints[i];
        if (!h.falsePos) { kept.push(h); continue; }
        var isFP = false;
        var lookback = Math.max(0, i - 6);
        for (var j = lookback; j < i && !isFP; j++) {
          var anc = hints[j].el;
          for (var g = 0; g < 3; g++) {
            anc = anc && anc.parentElement;
            if (anc === h.el) { isFP = true; break; }
          }
        }
        if (!isFP) kept.push(h);
      }

      // Overlap filter via elementFromPoint at the centre + 4 corners.
      // A hint passes if any probe lands on the hint's element or an
      // ancestor/descendant of it (handles covered-by-self-overlay cases
      // like an <a> with a transparent <span> on top).
      var nonOverlap = [];
      for (var i = 0; i < kept.length; i++) {
        var h = kept[i];
        if (h.secondClass) continue;
        var r = h.rect;
        var cx = r.left + r.width * 0.5;
        var cy = r.top + r.height * 0.5;
        function probe(x, y){
          var p = getElementFromPoint(x, y);
          return p && (h.el.contains(p) || p.contains(h.el));
        }
        if (probe(cx, cy)) { nonOverlap.push(h); continue; }
        // Vimium nudges corners by 0.1 px inward — empirically fixes the
        // case where elementFromPoint at an exact corner picks the
        // neighbour. Source: vimium PR #2251.
        var ys = [r.top + 0.1, r.top + r.height - 0.1];
        var xs = [r.left + 0.1, r.left + r.width - 0.1];
        var hit = false;
        for (var yi = 0; yi < 2 && !hit; yi++) {
          for (var xi = 0; xi < 2 && !hit; xi++) {
            if (probe(xs[xi], ys[yi])) hit = true;
          }
        }
        if (hit) nonOverlap.push(h);
      }

      // Reverse back to DOM order for stable output ordering.
      nonOverlap.reverse();

      // Project viewport coords → JS screen coords (Y-down, top-left of
      // primary). Swift flips to NSScreen on receipt.
      var ox = window.screenX + (window.outerWidth - window.innerWidth) / 2;
      var oy = window.screenY + (window.outerHeight - window.innerHeight);

      var out = [];
      for (var i = 0; i < nonOverlap.length; i++) {
        var h = nonOverlap[i];
        var r = h.rect;
        h.el.setAttribute('data-flash-id', i);
        out.push([i, r.left + ox, r.top + oy, r.width, r.height, h.el.tagName.toLowerCase()]);
      }
      return JSON.stringify(out);
    })()
    """
}

public final class SafariProvider: BrowserScriptProvider {
  public init() {
    super.init(
      identifier: "safari-dom",
      priority: 30,
      supportedBundles: [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
      ]
    )
  }

  public override func appleScript(running js: String) -> String {
    // `in document 1` is what targets the active document. If no
    // window is open the AppleScript fails — `runJS` returns nil and we
    // contribute no targets, which is the correct fallback (the AX
    // walker still runs).
    "tell application \"Safari\"\ndo JavaScript \"\(js)\" in document 1\nend tell"
  }
}

public final class ChromeProvider: BrowserScriptProvider {
  public init() {
    super.init(
      identifier: "chrome-dom",
      priority: 30,
      // Every Chromium-derived browser ships with the same AppleScript
      // dictionary verbs (`execute active tab of window 1 javascript`),
      // so we treat them as the same target. Each app id keeps its
      // own Automation grant.
      supportedBundles: [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.vivaldi.Vivaldi",
      ]
    )
  }

  public override func appleScript(running js: String) -> String {
    // Chromium dictionary syntax. We resolve the running app's display
    // name from the frontmost application — every Chromium variant
    // ships its own localized name but the same verb.
    let appName = chromeAppName()
    return
      "tell application \"\(appName)\"\nexecute active tab of window 1 javascript \"\(js)\"\nend tell"
  }

  private func chromeAppName() -> String {
    let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    switch bid {
    case "com.google.Chrome": return "Google Chrome"
    case "com.google.Chrome.canary": return "Google Chrome Canary"
    case "com.google.Chrome.dev": return "Google Chrome Dev"
    case "com.google.Chrome.beta": return "Google Chrome Beta"
    case "com.brave.Browser": return "Brave Browser"
    case "com.microsoft.edgemac": return "Microsoft Edge"
    case "company.thebrowser.Browser": return "Arc"
    case "com.vivaldi.Vivaldi": return "Vivaldi"
    default: return "Google Chrome"
    }
  }
}
