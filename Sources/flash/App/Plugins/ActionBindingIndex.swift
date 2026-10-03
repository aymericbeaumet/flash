import CoreGraphics
import FlashCore

/// Every plugin's `action_bindings`, indexed once per publish: what each app
/// does for a Flash action. Pure data, so the per-app resolution is testable
/// from the manifests alone.
///
/// Precedence for one action in the focused app:
///   1. a plugin's entry for the app's bundle id beats any plugin-wide `""`
///      entry;
///   2. then the plugin whose root selector (`only_bundle_ids`,
///      `only_terminals`) matches the app beats an unscoped one — a plugin
///      whose selector doesn't match contributes nothing;
///   3. then the higher manifest `priority`;
///   4. then the plugin id, alphabetically first.
struct ActionBindingIndex {
  /// The winning binding for an action in one app, and who declared it.
  struct Resolution: Equatable {
    let spec: ActionBindingSpec
    let pluginID: String
    /// Declared for this app by bundle id or under a selector matching it,
    /// rather than for every app.
    let isAppSpecific: Bool
  }

  /// One plugin's bindings for one action.
  private struct Target {
    let pluginID: String
    let selector: PluginSelectorStack
    let priority: Int
    /// Bundle id, or `""` for every app the selector matches, → binding.
    let bindings: [String: ActionBindingSpec]

    func resolve(in context: PluginSelectorContext) -> (Resolution, rank: [Int])? {
      guard let specificity = selector.specificity(in: context) else { return nil }
      if let bundleID = context.bundleID, let exact = bindings[bundleID] {
        return (
          Resolution(spec: exact, pluginID: pluginID, isAppSpecific: true),
          [1, specificity, priority]
        )
      }
      guard let fallback = bindings[""] else { return nil }
      return (
        Resolution(spec: fallback, pluginID: pluginID, isAppSpecific: specificity > 0),
        [0, specificity, priority]
      )
    }
  }

  private var targets: [SourceActionName: [Target]] = [:]

  /// `manifests` in plugin-id order: an exact tie keeps the first.
  init(manifests: [PluginManifest] = []) {
    for manifest in manifests { add(manifest) }
  }

  mutating func add(_ manifest: PluginManifest) {
    let selector = PluginSelectorStack([manifest.selector])
    for (name, bindings) in manifest.actionBindings {
      targets[name, default: []].append(
        Target(
          pluginID: manifest.id, selector: selector, priority: manifest.priority,
          bindings: bindings))
    }
  }

  /// The winning binding for `action` in the focused app, or nil when no
  /// plugin binds it there.
  func resolve(_ action: SourceActionName, in context: PluginSelectorContext) -> Resolution? {
    var best: (resolution: Resolution, rank: [Int])?
    for target in targets[action] ?? [] {
      guard let candidate = target.resolve(in: context) else { continue }
      // Highest rank wins; an exact tie keeps the first plugin by id.
      if best.map({ $0.rank.lexicographicallyPrecedes(candidate.rank) }) ?? true {
        best = candidate
      }
    }
    return best?.resolution
  }

  /// `resolve`, ready to dispatch; `index` fills `tab_select`'s `{index}`.
  func binding(
    _ action: SourceActionName, index: Int? = nil, in context: PluginSelectorContext
  ) -> ActionBinding? {
    resolve(action, in: context)?.spec.binding(index: index)
  }

  /// Every action a plugin binds in the focused app, with its winner.
  func resolutions(in context: PluginSelectorContext) -> [(SourceActionName, Resolution)] {
    SourceActionName.allCases.compactMap { name in
      resolve(name, in: context).map { (name, $0) }
    }
  }

  /// Whether some plugin binds `key`+`flags` for the focused app itself — by
  /// bundle id or under a selector matching it — so the app runs it as a
  /// shortcut. A plugin-wide binding for every app says nothing about a
  /// terminal emulator, which would type an unbound chord as text.
  func declares(key: CGKeyCode, flags: CGEventFlags, in context: PluginSelectorContext) -> Bool {
    targets.values.contains { targets in
      targets.contains { target in
        guard let (resolution, _) = target.resolve(in: context), resolution.isAppSpecific,
          case .chords(let chords) = resolution.spec.binding()
        else { return false }
        return chords.contains { $0.keyCode == key && $0.eventFlags == flags }
      }
    }
  }
}
