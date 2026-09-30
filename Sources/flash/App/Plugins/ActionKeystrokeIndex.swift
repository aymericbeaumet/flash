import CoreGraphics
import FlashCore

/// Every plugin's `action_keystrokes`, parsed once per publish: the chord an
/// app binds for a high-level action, or that it has none. Pure data, so the
/// per-app resolution is testable from the manifests alone.
struct ActionKeystrokeIndex {
  /// One plugin's chords for one action.
  private struct Target {
    let selector: PluginSelectorStack
    let priority: Int
    /// Bundle id, or `""` for every app the selector matches, → chord.
    let chords: [String: ActionKeystroke]

    /// The chord for `context` and how specific its claim is: a bundle's own
    /// entry beats the plugin-wide one, then the more specific selector and
    /// the higher priority win.
    func resolve(in context: PluginSelectorContext) -> (chord: ActionKeystroke, rank: [Int])? {
      guard let specificity = selector.specificity(in: context) else { return nil }
      if let bundleID = context.bundleID, let exact = chords[bundleID] {
        return (exact, [1, specificity, priority])
      }
      guard let fallback = chords[""] else { return nil }
      return (fallback, [0, specificity, priority])
    }
  }

  private var targets: [SourceActionName: [Target]] = [:]

  /// `manifests` in plugin-id order: an exact tie keeps the first.
  init(manifests: [PluginManifest] = []) {
    for manifest in manifests { add(manifest) }
  }

  mutating func add(_ manifest: PluginManifest) {
    let selector = PluginSelectorStack([manifest.selector])
    for (name, chords) in manifest.actionKeystrokes {
      targets[name, default: []].append(
        Target(
          selector: selector,
          priority: manifest.priority,
          chords: chords.compactMapValues(ActionKeystroke.init(manifestValue:))))
    }
  }

  /// The chord a plugin declares for `action` in the focused app; `.unbound`
  /// when a plugin declares that the app has no shortcut for it.
  func keystroke(_ action: SourceActionName, in context: PluginSelectorContext)
    -> ActionKeystroke?
  {
    var best: (chord: ActionKeystroke, rank: [Int])?
    for target in targets[action] ?? [] {
      guard let candidate = target.resolve(in: context) else { continue }
      // Highest rank wins; an exact tie keeps the first plugin by id.
      if best.map({ $0.rank.lexicographicallyPrecedes(candidate.rank) }) ?? true {
        best = candidate
      }
    }
    return best?.chord
  }

  /// Whether some plugin declares `key`+`flags` as an action keystroke of the
  /// focused app: the app binds it, so synthesizing it runs a shortcut.
  func declares(key: CGKeyCode, flags: CGEventFlags, in context: PluginSelectorContext) -> Bool {
    targets.values.contains { targets in
      targets.contains { target in
        guard case .chord(let chord)? = target.resolve(in: context)?.chord else { return false }
        return chord.keyCode == key && chord.eventFlags == flags
      }
    }
  }
}
