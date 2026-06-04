// Flash Oracle companion content script.
//
// Wire protocol (one direction, content -> Flash via document.title):
//   FLASH_ORACLE_READY                           — companion loaded, page idle
//   FLASH_ORACLE_ANCHORS:{json}                  — Vimium markers captured
//
// Flash drives the handshake: it waits for READY, posts 'f' (Vimium hint
// trigger) to Firefox, then waits for ANCHORS. Escape dismisses Vimium
// hint mode and resets the companion for the next capture.
//
// The companion intentionally never touches the page's interactive DOM
// beyond two absolutely-positioned fiducial markers used to calibrate
// the CSS->screen affine transform on every run.

(function () {
  "use strict";
  if (window.top !== window) return; // top frame only

  const PREFIX_READY = "FLASH_ORACLE_READY";
  const PREFIX_ANCHORS = "FLASH_ORACLE_ANCHORS:";
  const MARKER_REGEX = /vimium.*[Hh]int.*[Mm]arker|vimium-hint-marker/;
  const FIDUCIAL_IDS = ["__flash_oracle_fiducial_a__", "__flash_oracle_fiducial_b__"];

  let capturing = false;
  let captureScheduled = null;

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

  function injectFiducials() {
    if (document.getElementById(FIDUCIAL_IDS[0])) return;
    const make = (id, left, top) => {
      const d = document.createElement("div");
      d.id = id;
      d.setAttribute("role", "img");
      d.setAttribute("aria-label", id);
      d.style.cssText =
        "position:fixed;left:" + left + "px;top:" + top + "px;" +
        "width:8px;height:8px;background:#ff00aa;z-index:2147483646;" +
        "pointer-events:none;";
      return d;
    };
    document.documentElement.appendChild(make(FIDUCIAL_IDS[0], 40, 40));
    document.documentElement.appendChild(make(FIDUCIAL_IDS[1], 800, 600));
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
    // Broad sweep — Vimium / Vimium-FF / Vimium-C all use a class
    // matching the regex above. Filter by visible + non-trivial size.
    const all = document.querySelectorAll("*");
    const out = [];
    for (const el of all) {
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
    // Markers are positioned at the target's top-left. Hide all markers
    // temporarily and probe just inside the marker's footprint to hit
    // the underlying element.
    const r = marker.getBoundingClientRect();
    const px = r.left + Math.max(1, r.width / 2);
    const py = r.top + Math.max(1, r.height / 2);
    const hit = document.elementFromPoint(px, py);
    if (!hit) return null;
    // Walk up until we find something interactive-looking; skip text
    // nodes and obvious wrappers.
    let cur = hit;
    let walked = 0;
    while (cur && walked < 8) {
      const tag = cur.tagName ? cur.tagName.toLowerCase() : "";
      if (
        tag === "a" || tag === "button" || tag === "input" ||
        tag === "select" || tag === "textarea" || tag === "summary" ||
        cur.hasAttribute("tabindex") || cur.hasAttribute("role") ||
        cur.hasAttribute("onclick") || cur.isContentEditable
      ) {
        return cur;
      }
      cur = cur.parentElement;
      walked++;
    }
    return hit;
  }

  function serializeAnchors(markers) {
    const hiddenStyles = markers.map((m) => m.style.visibility);
    markers.forEach((m) => (m.style.visibility = "hidden"));
    try {
      const seen = new Set();
      const anchors = [];
      for (const marker of markers) {
        const target = resolveAnchor(marker);
        if (!target || seen.has(target)) continue;
        seen.add(target);
        const r = target.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) continue;
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

  function emit(payloadObj) {
    const json = JSON.stringify(payloadObj);
    document.title = PREFIX_ANCHORS + json;
  }

  function scheduleCapture() {
    if (capturing) return;
    if (captureScheduled !== null) {
      clearTimeout(captureScheduled);
    }
    captureScheduled = setTimeout(() => {
      captureScheduled = null;
      capturing = true;
      try {
        const markers = findMarkers();
        if (markers.length === 0) return;
        const anchors = serializeAnchors(markers);
        const fiducials = readFiducials();
        emit({
          anchors,
          fiducials,
          viewport: {
            scrollX: window.scrollX,
            scrollY: window.scrollY,
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            dpr: window.devicePixelRatio
          }
        });
      } finally {
        capturing = false;
      }
    }, 120); // debounce; Vimium places markers in a burst
  }

  function reset() {
    capturing = false;
    if (captureScheduled !== null) {
      clearTimeout(captureScheduled);
      captureScheduled = null;
    }
    document.title = PREFIX_READY;
  }

  function start() {
    injectFiducials();
    document.title = PREFIX_READY;

    const observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        for (const node of m.addedNodes) {
          if (
            node.nodeType === 1 &&
            typeof node.className === "string" &&
            MARKER_REGEX.test(node.className)
          ) {
            scheduleCapture();
            return;
          }
        }
      }
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true
    });

    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape") reset();
    }, true);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
