import Foundation

/// Which loaded plugins keep a child running before anything needs one.
///
/// Process creation can stall for seconds while `syspolicyd` is busy, and an
/// on-demand child used to pay `sandbox-exec` plus its own exec on the
/// keypress that first reached it. A plugin is *warm* when a configured
/// mapping — any mode, any app — a status-bar click or a plugin mapping can
/// run one of its commands: configuring the key is what asks for it, as a
/// template naming a segment asks for a status plugin. A warm on-demand
/// plugin is spawned once startup has settled (`PluginManager` asks after
/// each reconcile) and stays up when the status surfaces stop showing it.
/// Every other plugin keeps its surface-driven or first-perform activation,
/// so a command nothing maps costs nothing until it is used. Only loaded
/// plugins are asked: a disabled plugin, or a third-party one the
/// configuration does not list, never reaches this policy.
enum PluginWarmPolicy {
  /// A `flash <command> <subcommand>` pair, lowercased as dispatch matches it.
  struct CommandReference: Hashable {
    let command: String
    let subcommand: String

    init(command: String, subcommand: String) {
      self.command = command.lowercased()
      self.subcommand = subcommand.lowercased()
    }
  }

  /// Every action a configured mapping, in any mode or app scope, or a
  /// click on the enabled status bar can run.
  static func configuredActions(_ config: Config) -> [MappingCommand] {
    let mode = config.mode
    var mappings = mode.all + mode.normal + mode.insert + mode.terminal + mode.command
    mappings += mode.hyper + mode.hold + mode.layerMappingEntries
    for app in mode.appMappings.values {
      mappings += ModeScope.allCases.flatMap { app.mappings(for: $0) }
    }
    var actions = mappings.map(\.action)
    if config.statusBar.enabled {
      for case .command(let command) in config.statusBar.clickActions.values {
        actions.append(command)
      }
    }
    return actions
  }

  /// The plugin commands among `actions`.
  static func commandReferences(_ actions: [MappingCommand]) -> Set<CommandReference> {
    var references = Set<CommandReference>()
    for case .flashCommand(.pluginCommand(let command, let subcommand, _)) in actions {
      references.insert(CommandReference(command: command, subcommand: subcommand))
    }
    return references
  }

  /// The plugins `references` reach, resolved the way dispatch resolves
  /// them: the plugins registering the exact pair, else those registering
  /// the command's `*` wildcard. App selectors are ignored; which app will be
  /// focused when the key is pressed is not known ahead of time.
  static func warmPluginIDs(
    references: Set<CommandReference>, commands: [String: [PluginCommandRegistration]]
  ) -> Set<String> {
    var exact: [CommandReference: Set<String>] = [:]
    var wildcard: [String: Set<String>] = [:]
    for (id, registrations) in commands {
      for registration in registrations {
        let pair = CommandReference(
          command: registration.command, subcommand: registration.subcommand)
        if pair.subcommand == "*" {
          wildcard[pair.command, default: []].insert(id)
        } else {
          exact[pair, default: []].insert(id)
        }
      }
    }
    var warm = Set<String>()
    for reference in references {
      warm.formUnion(exact[reference] ?? wildcard[reference.command] ?? [])
    }
    return warm
  }

  /// Whether the settled-startup prewarm spawns the plugin now: a warm
  /// on-demand child that nothing has started. Every state but `idle`
  /// belongs to someone else: not yet started (a replacement may still share
  /// dispatch with its predecessor), starting, running, between restarts,
  /// parked or stopped.
  static func prewarms(
    activation: PluginActivation, state: PluginLifecycle.State, warm: Bool
  ) -> Bool {
    warm && activation == .onDemand && state == .idle
  }

  /// Whether a status-bound plugin's child stops once no status surface
  /// shows it: only when no perform started it and no mapping keeps it warm,
  /// and only while a child exists or is on its way.
  static func stopsWhenUnobserved(
    _ manifest: PluginManifest, state: PluginLifecycle.State, performActivated: Bool,
    warm: Bool
  ) -> Bool {
    guard manifest.isStatusBound, !performActivated, !warm else { return false }
    switch state {
    case .installing, .launching, .running, .backoff: return true
    case .initial, .idle, .published, .stopped, .failed: return false
    }
  }
}
