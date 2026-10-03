import CoreGraphics
import FlashCore

/// What `mouse_target --scope=screen` walks besides each app's front window:
/// Picture in Picture players and the Stage Manager strip. Chosen from
/// WindowServer geometry alone (owner, level, bounds; never content), then
/// walked by frame through Accessibility (`AppContext.WalkRoot.elementsInFrame`).
///
/// Neither surface's AX shape could be confirmed live, so the rules stay
/// geometric: every window of the Picture in Picture agent; an app's
/// player-sized window at the floating level, where browsers put their own
/// players; and the Stage Manager agent's thumbnail-sized windows.
enum ScreenScopeSurfaces {
  enum Kind: String, Equatable {
    case pictureInPicture = "picture_in_picture"
    case stageManager = "stage_manager"
  }

  struct Surface: Equatable {
    /// Its window's index in the snapshot the surfaces were chosen from.
    let entryIndex: Int
    let pid: pid_t
    let frame: CGRect
    let kind: Kind
  }

  /// What `auxiliary` needs to know about a window's owner.
  struct Owner: Equatable {
    let bundleIdentifier: String
    let isRegularApp: Bool
  }

  /// AVKit's Picture in Picture player (Safari, QuickTime, TV, …).
  static let pictureInPictureBundleID = "com.apple.PIPAgent"
  /// Stage Manager's strip of recent app sets.
  static let stageManagerBundleID = "com.apple.WindowManager"
  static let systemAgentBundleIDs: Set<String> = [pictureInPictureBundleID, stageManagerBundleID]
  /// Walks are bounded: at most this many extra surfaces per activation.
  static let maxSurfaces = 8
  /// A window larger than this share of the screen is a backdrop or a
  /// palette, not a thumbnail or a player.
  static let maxAreaFraction: CGFloat = 0.25
  /// Floating windows narrower than this are controls, not players.
  static let minPlayerSide: CGFloat = 100

  /// The extra surfaces on `screen`, front-most first. `entries` is the
  /// window list in z-order; `owner` resolves a window's app.
  static func auxiliary(
    entries: [WindowSnapshot.Entry], screen: CGRect, owner: (pid_t) -> Owner?
  ) -> [Surface] {
    let screenArea = screen.width * screen.height
    guard screenArea > 0 else { return [] }
    let floating = Int(CGWindowLevelForKey(.floatingWindow))
    var surfaces: [Surface] = []
    for (index, entry) in entries.enumerated() {
      guard surfaces.count < maxSurfaces else { break }
      let frame = entry.nsBounds
      guard entry.occludes, frame.intersects(screen), let owner = owner(entry.pid) else {
        continue
      }
      let small = frame.width * frame.height <= screenArea * maxAreaFraction
      let kind: Kind
      switch owner.bundleIdentifier {
      case pictureInPictureBundleID:
        kind = .pictureInPicture
      case stageManagerBundleID:
        guard small else { continue }
        kind = .stageManager
      default:
        guard owner.isRegularApp, entry.layer == floating, small,
          min(frame.width, frame.height) >= minPlayerSide
        else { continue }
        kind = .pictureInPicture
      }
      surfaces.append(Surface(entryIndex: index, pid: entry.pid, frame: frame, kind: kind))
    }
    return surfaces
  }

  /// A system agent never becomes the frontmost app, so its targets carry no
  /// pid and the commit clicks without waiting for an activation, like
  /// Notification Center's. An app's own player keeps its app.
  static func keepsPID(_ owner: Owner) -> Bool {
    owner.isRegularApp && !systemAgentBundleIDs.contains(owner.bundleIdentifier)
  }

  /// `target` as a hint of `surface`: its id namespaced by the surface so
  /// it cannot collide with the same app's front-window walk.
  static func retarget(
    _ target: JumpTarget, surface: Surface, ordinal: Int, keepsPID: Bool
  ) -> JumpTarget {
    JumpTarget(
      id: "\(surface.kind.rawValue)-\(ordinal)-\(target.id)", frame: target.frame,
      role: target.role, accessibilityLabel: target.accessibilityLabel, url: target.url,
      contextID: target.contextID, pid: keepsPID ? target.pid : nil,
      resolveClickPoint: target.resolveClickPoint, entersInsertMode: target.entersInsertMode,
      priority: target.priority, providerID: target.providerID)
  }
}
