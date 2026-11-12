import FlashCore

/// Every `confirm` a plugin's core `commands[]` entries carry, indexed once
/// per publish: the question to ask before a command a plugin performs
/// destructively in the apps its selector matches (tmux's `tab close` kills
/// a window nothing can reopen). Pure data, so the per-app resolution is
/// testable from the manifests alone.
///
/// Precedence for one command in the focused app: the plugin whose root
/// selector (`only_bundle_ids`, `only_terminals`) matches the app beats an
/// unscoped one (a plugin whose selector doesn't match contributes nothing);
/// then the higher manifest `priority`; then the plugin id, alphabetically
/// first.
struct CommandConfirmationIndex {
  /// One plugin's question for one command.
  private struct Target {
    let pluginID: String
    let selector: PluginSelectorStack
    let priority: Int
    let prompt: String

    func rank(in context: PluginSelectorContext) -> [Int]? {
      selector.specificity(in: context).map { [$0, priority] }
    }
  }

  private var targets: [CommandName: [Target]] = [:]

  /// `manifests` in plugin-id order: an exact tie keeps the first.
  init(manifests: [PluginManifest] = []) {
    for manifest in manifests { add(manifest) }
  }

  mutating func add(_ manifest: PluginManifest) {
    let selector = PluginSelectorStack([manifest.selector])
    for (name, prompt) in manifest.confirmations {
      targets[name, default: []].append(
        Target(
          pluginID: manifest.id, selector: selector, priority: manifest.priority, prompt: prompt))
    }
  }

  /// The question for `name` in the focused app, or nil when no applicable
  /// plugin gates it.
  func prompt(for name: CommandName, in context: PluginSelectorContext) -> String? {
    var best: (prompt: String, rank: [Int])?
    for target in targets[name] ?? [] {
      guard let rank = target.rank(in: context) else { continue }
      if best.map({ $0.rank.lexicographicallyPrecedes(rank) }) ?? true {
        best = (target.prompt, rank)
      }
    }
    return best?.prompt
  }
}
