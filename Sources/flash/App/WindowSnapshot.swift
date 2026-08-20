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
/// notification centre) are kept as occluders. For other applications,
/// same-pid interaction layers may become the active surface when they sit
/// above the main window — this is how NSPopover/status-item/password-manager
/// popups are scoped without hinting sibling windows behind them.
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

  /// Front-most interaction surface for the focused pid, before occlusion
  /// subtraction. Providers that need full-surface geometry (tmux cell
  /// math, popovers, modal panels) use this frame; AppMonitor filters
  /// returned targets against `visibleRegions` afterward.
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
    // The "active window" is the front-most interaction surface owned by the
    // focused pid. CGWindowList returns windows in z-order, so the first hit
    // is the right one. Every other window — including other windows of the
    // same app on another monitor — is treated purely as an occluder, never
    // as a hintable surface. This keeps hints scoped to one current surface
    // while still allowing same-pid popovers/dialogs/floating windows above a
    // main layer-0 window.
    // Some apps draw small sub-surfaces as their own layer-0 WindowServer
    // windows that float over the main window — Firefox's tab-hover preview
    // card, for one (a ~280×78 window with no accessibility presence). The
    // frontmost-same-pid rule would pick that card and collapse the whole active
    // surface onto it. Promote past such cards to the window they're anchored
    // over so the border and hint scope stay on the real surface; the card still
    // occludes its little patch like any other window.
    let layer0App = entries.filter { $0.pid == focusedPid && $0.layer == 0 }.map(\.nsBounds)
    var activeWindowIndex: Int? = nil
    for (idx, e) in entries.enumerated()
    where e.pid == focusedPid && isInteractionSurfaceLayer(e.layer) {
      if e.layer == 0, isAnchoredCard(e.nsBounds, amongLayer0App: layer0App) { continue }
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

  /// Multi-surface variant for screen-scope hints: the front-most interaction
  /// surface of EVERY pid in `focusedPids` is hintable (occluded by all
  /// higher-z windows); everything else purely occludes. Same painter's
  /// algorithm, anchored-card promotion, and fragmentation guard as the
  /// single-pid build.
  static func buildMultiSurfaceVisibleRegions(
    entries: [Entry],
    focusedPids: Set<pid_t>
  ) -> [pid_t: [CGRect]] {
    var activeIndexes = Set<Int>()
    for pid in focusedPids {
      let layer0App = entries.filter { $0.pid == pid && $0.layer == 0 }.map(\.nsBounds)
      for (idx, entry) in entries.enumerated()
      where entry.pid == pid && isInteractionSurfaceLayer(entry.layer) {
        if entry.layer == 0, isAnchoredCard(entry.nsBounds, amongLayer0App: layer0App) {
          continue
        }
        activeIndexes.insert(idx)
        break
      }
    }
    var byPid: [pid_t: [CGRect]] = [:]
    var occluders: [CGRect] = []
    occluders.reserveCapacity(entries.count)
    for (idx, entry) in entries.enumerated() {
      if activeIndexes.contains(idx) {
        var fragments: [CGRect] = [entry.nsBounds]
        for occluder in occluders {
          if fragments.isEmpty { break }
          var next: [CGRect] = []
          next.reserveCapacity(fragments.count * 2)
          for frag in fragments {
            subtract(frag, hole: occluder, into: &next)
          }
          if next.count > 32 {
            fragments = next
            break
          }
          fragments = next
        }
        if !fragments.isEmpty {
          byPid[entry.pid, default: []].append(contentsOf: fragments)
        }
      }
      occluders.append(entry.nsBounds)
    }
    return byPid
  }

  static func topApplicationWindowFrame(entries: [Entry], focusedPid: pid_t) -> CGRect? {
    let layer0App = entries.filter { $0.pid == focusedPid && $0.layer == 0 }.map(\.nsBounds)
    return entries.first {
      $0.pid == focusedPid && $0.layer == 0
        && !isAnchoredCard($0.nsBounds, amongLayer0App: layer0App)
    }?.nsBounds
  }

  /// A layer-0 window that floats over a larger layer-0 window of the same app —
  /// e.g. Firefox's tab-hover preview card drawn over the browser window. These
  /// are sub-surfaces, not real windows (the card isn't even in the app's
  /// accessibility tree), so letting one become the active surface collapses the
  /// active-window border and hint scope onto a tiny card. We merge them into the
  /// window they're anchored over instead.
  ///
  /// Restricted to layer 0 on purpose: genuine floating popovers, dialogs, and
  /// password-manager panels live above layer 0 (`.floatingWindow` &c.) and must
  /// keep their own scope (see `testFocusedHighLayerPopupBecomesActiveSurface`).
  /// A card qualifies only when it's fully contained (modulo a few px of slop)
  /// within a same-app layer-0 window whose area is ≥ `1 / anchoredCardMaxAreaFraction`×
  /// larger, so same-size sibling windows and substantial dialogs are left alone.
  static func isAnchoredCard(_ frame: CGRect, amongLayer0App parents: [CGRect]) -> Bool {
    let area = frame.width * frame.height
    guard area > 0 else { return false }
    for parent in parents where parent != frame {
      guard parent.width * parent.height >= area / anchoredCardMaxAreaFraction else { continue }
      if parent.insetBy(dx: -anchoredCardContainmentSlop, dy: -anchoredCardContainmentSlop)
        .contains(frame)
      {
        return true
      }
    }
    return false
  }

  /// A card is merged only when it covers at most this fraction of its parent's
  /// area — small enough to be a hover card/dropdown, not a peer dialog.
  static let anchoredCardMaxAreaFraction: CGFloat = 0.25
  /// Px of slack allowed when testing containment, so a card that poke a hair
  /// past the parent edge (screen-edge tabs) still counts as anchored.
  static let anchoredCardContainmentSlop: CGFloat = 8

  static func topInteractionEntry(
    at point: CGPoint,
    entries: [Entry],
    ignoringPids: Set<pid_t> = []
  ) -> Entry? {
    entries.first {
      isInteractionSurfaceLayer($0.layer)
        && $0.pid > 0
        && !ignoringPids.contains($0.pid)
        && $0.nsBounds.contains(point)
    }
  }

  static func isInteractionSurfaceLayer(_ layer: Int) -> Bool {
    if layer == 0 { return true }
    let allowedLevels = [
      CGWindowLevelForKey(.floatingWindow),
      CGWindowLevelForKey(.modalPanelWindow),
      CGWindowLevelForKey(.utilityWindow),
      CGWindowLevelForKey(.popUpMenuWindow),
      CGWindowLevelForKey(.statusWindow),
    ]
    return allowedLevels.contains(Int32(layer))
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
