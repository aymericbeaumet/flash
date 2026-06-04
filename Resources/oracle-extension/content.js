// Flash Oracle companion content script.
//
// Wire protocol — Flash reads back via the AX tree:
//   document.title = FLASH_ORACLE_READY            — companion loaded, page idle
//   document.title = FLASH_ORACLE_ANCHORS_READY    — anchors captured + payload div mounted
//   <div role="img" aria-label="FLASH_ORACLE_PAYLOAD|{json}"
//        style="position:fixed;left:-9999px;...">  — full JSON
//
// Why a payload div instead of just document.title: macOS truncates
// AX window titles at ~300 chars, mangling any anchor list with more
// than ~5 entries. aria-label has no such cap — AX exposes it verbatim
// as kAXDescription, and Flash walks the AX tree to find the div by
// its known description prefix.
//
// Flash drives the handshake: waits for READY, posts 'f' (Vimium hint
// trigger), waits for ANCHORS_READY, then walks AX to read the payload.
// Escape dismisses Vimium hint mode and resets the companion.
//
// The companion intentionally never touches the page's interactive DOM
// beyond two absolutely-positioned fiducial markers + one off-screen
// payload div, all mounted after the page's own content is idle.

(function () {
  "use strict";
  if (window.top !== window) return; // top frame only

  const TITLE_READY = "FLASH_ORACLE_READY";
  const TITLE_ANCHORS_READY = "FLASH_ORACLE_ANCHORS_READY";
  const PAYLOAD_DIV_ID = "__flash_oracle_payload__";
  const PAYLOAD_LABEL_PREFIX = "FLASH_ORACLE_PAYLOAD|";
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
    let div = document.getElementById(PAYLOAD_DIV_ID);
    if (!div) {
      div = document.createElement("div");
      div.id = PAYLOAD_DIV_ID;
      div.setAttribute("role", "img");
      div.style.cssText =
        "position:fixed;left:-9999px;top:-9999px;" +
        "width:1px;height:1px;overflow:hidden;pointer-events:none;";
      document.documentElement.appendChild(div);
    }
    div.setAttribute("aria-label", PAYLOAD_LABEL_PREFIX + json);
    document.title = TITLE_ANCHORS_READY;
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
    const div = document.getElementById(PAYLOAD_DIV_ID);
    if (div) div.removeAttribute("aria-label");
    document.title = TITLE_READY;
  }

  function start() {
    injectFiducials();
    // Drag focus off the URL bar and onto the page. body.focus() is
    // unreliable from content scripts; explicitly focusing the first
    // real interactive element gets the page key context the OS
    // recognizes as "the page is what should receive keystrokes".
    // {preventScroll: true} avoids visual disruption if the element
    // is below the fold.
    const firstFocusable = document.querySelector(
      'a[href], button, input:not([disabled]), select:not([disabled]),' +
      ' textarea:not([disabled]), [tabindex]:not([tabindex="-1"])');
    if (firstFocusable) {
      firstFocusable.focus({ preventScroll: true });
    } else if (document.body) {
      document.body.setAttribute("tabindex", "-1");
      document.body.focus();
    }
    document.title = TITLE_READY;

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
    }, false);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
