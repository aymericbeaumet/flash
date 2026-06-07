import AppKit
import Foundation

/// Z-order snapshot of every on-screen window, with each window's
/// genuinely-visible portion already computed. Built from a single
/// `CGWindowListCopyWindowInfo` call.
///
/// The painter's algorithm: iterate windows front → back (the order
/// CGWindowList returns them in). For each window, subtract every
/// already-seen (higher-z) window's bounds from this one's. What's left
/// is the part of the window the user can actually see. Then push this
/// window's bounds onto the occluder list so the next window down gets
/// chopped by it too.
///
/// Higher-layer windows (the Dock, the menu bar, status items, the
/// notification centre) are kept as occluders but excluded from the
/// per-pid region map — they're not user-clickable surfaces Flash should
/// hint, but they DO cover stuff behind them, so they need to chop the
/// regions of the apps they overlay.
struct WindowSnapshot {
  struct Entry {
    let pid: pid_t
    let layer: Int
    /// NSScreen-coord bounds (origin bottom-left of primary).
    let nsBounds: CGRect
  }

  /// All on-screen windows in z-order (front-most first).
  let entries: [Entry]

  /// Per-pid disjoint rectangles in NSScreen coords that represent the
  /// pid's currently-visible pixels (after subtracting every higher-z
  /// window). Empty for pids that are fully occluded.
  let visibleRegions: [pid_t: [CGRect]]

  /// Front-most layer-0 window for the focused pid, before occlusion
  /// subtraction. Providers that need full-window geometry (tmux cell
  /// math) use this frame; AppMonitor filters returned targets against
  /// `visibleRegions` afterward.
  let activeWindowFrame: CGRect?

  static func build(
    primaryH: CGFloat,
    onlyComputingVisibleRegionsFor focusedPid: pid_t,
    ignoringPids: Set<pid_t> = []
  )
    -> WindowSnapshot
  {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
      return WindowSnapshot(entries: [], visibleRegions: [:], activeWindowFrame: nil)
    }
    let entries = entries(from: info, primaryH: primaryH)
      .filter { !ignoringPids.contains($0.pid) }
    return build(
      entries: entries,
      focusedPid: focusedPid)
  }

  static func entries(from info: [[String: Any]], primaryH: CGFloat) -> [Entry] {
    var entries: [Entry] = []
    entries.reserveCapacity(info.count)
    for w in info {
      guard let wpid = w[kCGWindowOwnerPID as String] as? Int32,
        let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
        let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { continue }
      // Skip zero-area or pathological bounds — they can't occlude
      // anything and can't host hints.
      if cgBounds.width <= 0 || cgBounds.height <= 0 { continue }
      let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
      let ns = CGRect(
        x: cgBounds.minX,
        y: primaryH - cgBounds.minY - cgBounds.height,
        width: cgBounds.width,
        height: cgBounds.height
      )
      entries.append(Entry(pid: pid_t(wpid), layer: layer, nsBounds: ns))
    }
    return entries
  }

  static func build(entries: [Entry], focusedPid: pid_t) -> WindowSnapshot {
    // The "active window" is the front-most layer-0 window owned by the
    // focused pid. CGWindowList returns windows in z-order, so the
    // first hit is the right one. Every other window — including other
    // windows of the same app on another monitor — is treated purely
    // as an occluder, never as a hintable surface. This is what keeps
    // hints scoped to the single active window.
    var activeWindowIndex: Int? = nil
    for (idx, e) in entries.enumerated() where e.layer == 0 && e.pid == focusedPid {
      activeWindowIndex = idx
      break
    }

    var byPid: [pid_t: [CGRect]] = [:]
    var occluders: [CGRect] = []
    occluders.reserveCapacity(entries.count)
    for (idx, e) in entries.enumerated() {
      if idx == activeWindowIndex {
        var fragments: [CGRect] = [e.nsBounds]
        for occluder in occluders {
          if fragments.isEmpty { break }
          var next: [CGRect] = []
          next.reserveCapacity(fragments.count * 2)
          for frag in fragments {
            subtract(frag, hole: occluder, into: &next)
          }
          // Fragmentation guard. A window cross-hatched by many
          // higher-z windows can blow up the fragment count
          // quadratically; cap at 32 — we only need the
          // *approximate* visible region, not pixel-perfect.
          if next.count > 32 {
            fragments = next
            break
          }
          fragments = next
        }
        if !fragments.isEmpty {
          byPid[e.pid, default: []].append(contentsOf: fragments)
        }
      }
      occluders.append(e.nsBounds)
    }

    let activeWindowFrame = activeWindowIndex.map { entries[$0].nsBounds }
    return WindowSnapshot(
      entries: entries,
      visibleRegions: byPid,
      activeWindowFrame: activeWindowFrame)
  }

  /// Rectangle subtraction in NSScreen-coord (Y-up) space. Returns up to
  /// four non-overlapping fragments: top strip, bottom strip, left
  /// strip (within the y-range of the hole), right strip. The math is
  /// symmetric in Y so this also works in Y-down — the strip labels
  /// are only descriptive.
  private static func subtract(_ rect: CGRect, hole: CGRect, into out: inout [CGRect]) {
    let i = rect.intersection(hole)
    if i.isNull || i.width <= 0 || i.height <= 0 {
      out.append(rect)
      return
    }
    if i.equalTo(rect) {
      // Fully consumed by the hole — nothing left to emit.
      return
    }
    // Top strip (above the hole in Y-up).
    if i.maxY < rect.maxY {
      out.append(CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY))
    }
    // Bottom strip (below the hole).
    if i.minY > rect.minY {
      out.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY))
    }
    // Left strip (only within the y-range of the hole).
    if i.minX > rect.minX {
      out.append(CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height))
    }
    // Right strip (likewise).
    if i.maxX < rect.maxX {
      out.append(CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height))
    }
  }
}
