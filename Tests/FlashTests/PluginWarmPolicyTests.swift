import XCTest

@testable import flash

/// Which loaded plugins run before anything needs them: a plugin whose
/// command a configured mapping runs is warmed once startup settles and
/// outlives its status surfaces; every other plugin keeps its surface-driven
/// or first-perform activation.
final class PluginWarmPolicyTests: XCTestCase {
  private typealias Policy = PluginWarmPolicy
  private typealias Reference = PluginWarmPolicy.CommandReference
  private static let states: [PluginLifecycle.State] = [
    .initial, .idle, .installing, .launching, .running, .backoff, .stopped, .failed,
  ]

  private static func plugin(_ command: String, _ subcommand: String) -> MappingCommand {
    .flashCommand(.pluginCommand(command: command, subcommand: subcommand, args: []))
  }

  private static func mapping(_ key: String, _ action: MappingCommand) -> ModeMapping {
    ModeMapping(key: key, action: action)
  }

  func testEveryConfiguredMappingScopeAndEnabledBarClickIsRead() {
    var config = Config()
    config.mode.normal.append(Self.mapping("<leader>a", Self.plugin("alpha", "go")))
    config.mode.hyper.append(Self.mapping("b", Self.plugin("beta", "go")))
    config.mode.hold.append(Self.mapping("c", Self.plugin("gamma", "go")))
    config.mode.layers["resize", default: .init()].set(
      Self.mapping("e", Self.plugin("zeta", "go")))
    var app = Config.Mode.AppMappings()
    app.set(Self.mapping("d", Self.plugin("delta", "go")), in: .insert)
    config.mode.appMappings["com.example.app"] = app
    config.statusBar.clickActions["epsilon"] = .command(Self.plugin("epsilon", "go"))

    var references = Policy.commandReferences(Policy.configuredActions(config))
    XCTAssertEqual(
      references.map(\.command).sorted(), ["alpha", "beta", "delta", "gamma", "zeta"],
      "a click on a hidden bar runs nothing")

    config.statusBar.enabled = true
    references = Policy.commandReferences(Policy.configuredActions(config))
    XCTAssertTrue(references.contains(Reference(command: "epsilon", subcommand: "go")))
    XCTAssertFalse(
      references.contains { $0.command == "app" }, "Flash's own commands are not plugins")
  }

  func testReferencesResolveAsDispatchDoes() {
    let commands: [String: [PluginCommandRegistration]] = [
      "exact": [PluginCommandRegistration(command: "Tool", subcommand: "Run")],
      "wild": [PluginCommandRegistration(command: "tool", subcommand: "*")],
      "calc": [PluginCommandRegistration(command: "calc", subcommand: "*")],
      "idle": [PluginCommandRegistration(command: "idle", subcommand: "go")],
    ]
    XCTAssertEqual(
      Policy.warmPluginIDs(
        references: [Reference(command: "tool", subcommand: "RUN")], commands: commands),
      ["exact"], "an exact registration wins over the wildcard, case-insensitively")
    XCTAssertEqual(
      Policy.warmPluginIDs(
        references: [
          Reference(command: "tool", subcommand: "other"),
          Reference(command: "calc", subcommand: "2+2"),
        ], commands: commands),
      ["wild", "calc"])
    XCTAssertEqual(
      Policy.warmPluginIDs(
        references: [Reference(command: "missing", subcommand: "go")], commands: commands), [])
  }

  func testPrewarmSpawnsOnlyAnIdleWarmOnDemandPlugin() {
    for state in Self.states {
      XCTAssertEqual(
        Policy.prewarms(activation: .onDemand, state: state, warm: true), state == .idle,
        "\(state): only an idle child is the prewarm's to start")
      XCTAssertFalse(
        Policy.prewarms(activation: .onDemand, state: state, warm: false),
        "\(state): nothing maps it")
    }
    XCTAssertFalse(
      Policy.prewarms(activation: .resident, state: .idle, warm: true),
      "an observed status plugin is resident: its surface starts it")
    XCTAssertFalse(
      Policy.prewarms(activation: .manifestOnly, state: .idle, warm: true), "no exec, no child")
  }

  func testAnUnobservedStatusPluginStopsOnlyWhenNothingElseNeedsIt() {
    let statusBound = PluginManifest(
      id: "warm", name: "Warm", version: "1", description: "", exec: ["./run"],
      commands: [PluginCommandRegistration(command: "warm", subcommand: "go")],
      status: ["state"])
    let live: Set<PluginLifecycle.State> = [.installing, .launching, .running, .backoff]
    for state in Self.states {
      XCTAssertEqual(
        Policy.stopsWhenUnobserved(
          statusBound, state: state, performActivated: false, warm: false),
        live.contains(state), "\(state)")
      XCTAssertFalse(
        Policy.stopsWhenUnobserved(
          statusBound, state: state, performActivated: true, warm: false),
        "\(state): a perform started it")
      XCTAssertFalse(
        Policy.stopsWhenUnobserved(
          statusBound, state: state, performActivated: false, warm: true),
        "\(state): a mapping keeps it warm")
    }

    let resident = PluginManifest(
      id: "resident", name: "Resident", version: "1", description: "", exec: ["./run"],
      hints: PluginHints(), status: ["state"])
    XCTAssertFalse(
      Policy.stopsWhenUnobserved(resident, state: .running, performActivated: false, warm: false),
      "not status-bound: its other surfaces keep it")
  }
}
