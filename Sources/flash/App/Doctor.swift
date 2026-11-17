import AppKit
import FlashTerminal
import IOKit
import Security

/// `flash resident doctor` and `:doctor`: every check that turns "Flash doesn't work"
/// into a fix. `run` is pure over `Inputs`; `DoctorProbe` gathers them, the
/// slow ones (IORegistry, code signature, plugin sandbox compiles) off the
/// main thread. An `error` check is an issue and makes `flash resident doctor` exit 1;
/// a `warn` is reported without failing it.
enum Doctor {
  struct Check: Equatable {
    enum Status: String {
      case ok, warn, error
    }

    var id: String
    var status: Status
    var summary: String
    var details: [String] = []
  }

  struct Report: Equatable {
    static let schema = 1

    var checks: [Check]
    var issues: Int { checks.filter { $0.status == .error }.count }
    var warnings: Int { checks.filter { $0.status == .warn }.count }

    var json: [String: Any] {
      [
        "schema": Self.schema,
        "issues": issues,
        "warnings": warnings,
        "checks": checks.map { check -> [String: Any] in
          [
            "id": check.id, "status": check.status.rawValue, "summary": check.summary,
            "details": check.details,
          ]
        },
      ]
    }

    var data: Data {
      (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        ?? Data("{}".utf8)
    }

    /// One line per check, then its details, as `:doctor` logs them.
    var lines: [String] {
      checks.flatMap { check in
        ["\(check.status.rawValue) \(check.id): \(check.summary)"]
          + check.details.map { "  \($0)" }
      }
    }
  }

  enum Signature: Equatable {
    /// Signed with a certificate; the grant follows its identity.
    case certificate(String)
    /// Ad-hoc: macOS ties the Accessibility grant to this exact binary.
    case adHoc
    case unsigned
    case unknown
  }

  struct Process: Equatable {
    var pid: pid_t
    var name: String?
  }

  struct Inputs {
    var accessibilityTrusted: Bool
    var tapInstalled: Bool
    var secureInputEnabled: Bool
    /// Who holds secure input, from IORegistry; empty when nobody does or
    /// it could not be read.
    var secureInputHolders: [Process] = []
    var signature: Signature
    /// Other Flash residents running beside this one.
    var otherResidents: [Process] = []
    var configPath: String
    /// `path:line:col: message` lines, as `flash config check` prints them.
    var configDiagnostics: [String] = []
    /// Native hotkeys macOS refused because another app registered them.
    var refusedHotkeys: [String] = []
    var plugins: PluginDoctor.Report?
    /// The hint alphabet and the grid keys, which must be typable.
    var hintKeys: [Character] = []
    var gridKeys: [Character] = []
    /// The layout keys are read on (`[app] keyboard_layout`'s reference, or
    /// the current source's own layout); nil when it could not be read.
    var readLayout: KeyboardLayout?
    /// An explicit `keyboard_layout` that names no installed source.
    var missingKeyboardLayout: String?
    /// Screen Recording, checked only while the screenshot plugin runs.
    var screenRecordingGranted: Bool?
    /// Recent target activations per app; empty until hints are asked for.
    var hintActivations: [HintActivationStats.Summary] = []
    /// Each terminal popup's executable, as its launch resolves it.
    var popupCommands: [String: String] = [:]
    /// The `PATH` popups launch with, from the login environment.
    var popupPath: String?
    /// Plugin id → the status names the bar, widgets, popups and monitors
    /// read (`Config.observedStatusSegments`).
    var statusSegmentsRead: [String: Set<String>] = [:]
    /// Plugin id → the status names each loaded plugin's manifest declares.
    var statusSegmentsDeclared: [String: Set<String>] = [:]
    var disabledPlugins: Set<String> = []
    /// URL schemes a status link was refused for since launch, each once
    /// (`StatusLinkOpener.refusedSchemes`): neither web, mail nor
    /// `[statusbar] link_schemes`.
    var refusedLinkSchemes: [String] = []
    /// The OTLP receiver and the monitors a received metric can fire; nil
    /// when the configuration was not asked.
    var telemetryReceiver: TelemetryReceiverState?
  }

  /// `[telemetry.receiver]` as the doctor judges it.
  struct TelemetryReceiverState: Equatable {
    var enabled: Bool
    var port: Int
    var hasToken: Bool
    /// The enabled value monitors with a `run` whose `value` reads a
    /// `#{flash.otel…}` metric (`Config.monitorsRunOnReceivedMetrics`).
    var monitorsRunOnReceivedMetrics: [String]
  }

  static func run(_ inputs: Inputs) -> Report {
    var checks: [Check] = []

    checks.append(
      inputs.accessibilityTrusted
        ? Check(id: "accessibility", status: .ok, summary: "Accessibility granted")
        : Check(
          id: "accessibility", status: .error,
          summary: "Accessibility is not granted, so Flash can neither see nor click targets",
          details: [
            "System Settings → Privacy & Security → Accessibility: turn Flash on.",
            "Already on after an update? Remove Flash with − and add it again.",
          ]))

    checks.append(
      inputs.tapInstalled
        ? Check(id: "keyboard_tap", status: .ok, summary: "keyboard tap installed")
        : Check(
          id: "keyboard_tap", status: .error,
          summary:
            "the keyboard tap is not installed; NORMAL and hints fall back to the key window",
          details: ["It installs once Accessibility is granted; restart Flash if it does not."]))

    if inputs.secureInputEnabled {
      let holders = inputs.secureInputHolders.map { holder in
        "\(holder.name ?? "unknown process") (pid \(holder.pid))"
      }
      checks.append(
        Check(
          id: "secure_input", status: .warn,
          summary: "secure input is on, held by "
            + (holders.isEmpty ? "an unknown process" : holders.joined(separator: ", ")),
          details: [
            "The keyboard tap sees no keys while it lasts; hints read keys through the key window.",
            "A focused password field is left alone. When the flag stays on without one, "
              + "Flash asks the holding app to release it.",
          ]))
    } else {
      checks.append(Check(id: "secure_input", status: .ok, summary: "secure input is off"))
    }

    switch inputs.signature {
    case .certificate(let authority):
      checks.append(Check(id: "signature", status: .ok, summary: "signed by \(authority)"))
    case .adHoc:
      checks.append(
        Check(
          id: "signature", status: .warn,
          summary: "ad-hoc signed: macOS can drop the Accessibility grant after an update",
          details: [
            "The toggle can still show on. If hints stop after an update, remove Flash from the "
              + "Accessibility list with − and add it again."
          ]))
    case .unsigned:
      checks.append(
        Check(
          id: "signature", status: .warn,
          summary: "unsigned: macOS cannot keep permissions across builds"))
    case .unknown:
      checks.append(
        Check(id: "signature", status: .warn, summary: "the code signature could not be read"))
    }

    checks.append(
      inputs.otherResidents.isEmpty
        ? Check(id: "residents", status: .ok, summary: "one Flash resident running")
        : Check(
          id: "residents", status: .error,
          summary: "\(inputs.otherResidents.count + 1) Flash residents are running",
          details: inputs.otherResidents.map { "\($0.name ?? "Flash") (pid \($0.pid))" }
            + ["Quit the extra copies; only one may own the keyboard tap."]))

    checks.append(
      inputs.configDiagnostics.isEmpty
        ? Check(id: "config", status: .ok, summary: "\(inputs.configPath): no diagnostics")
        : Check(
          id: "config", status: .error,
          summary: "\(inputs.configPath): \(inputs.configDiagnostics.count) diagnostic"
            + (inputs.configDiagnostics.count == 1 ? "" : "s"),
          details: inputs.configDiagnostics))

    checks.append(
      inputs.refusedHotkeys.isEmpty
        ? Check(id: "hotkeys", status: .ok, summary: "every native hotkey registered")
        : Check(
          id: "hotkeys", status: .error,
          summary: "macOS refused \(inputs.refusedHotkeys.count) hotkey"
            + (inputs.refusedHotkeys.count == 1 ? "" : "s")
            + "; another app already owns "
            + (inputs.refusedHotkeys.count == 1 ? "it" : "them"),
          details: inputs.refusedHotkeys))

    if let plugins = inputs.plugins {
      // `PluginDoctor` prefixes a plugin's problems with `!!`.
      let problems = plugins.lines.filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }
      let count = plugins.lines.filter { $0.hasPrefix("ok ") || $0.hasPrefix("!! ") }.count
      checks.append(
        plugins.issues == 0
          ? Check(
            id: "plugins", status: .ok,
            summary: "\(count) plugin\(count == 1 ? "" : "s") healthy")
          : Check(
            id: "plugins", status: .error,
            summary: "\(plugins.issues) plugin issue\(plugins.issues == 1 ? "" : "s")",
            details: problems))
    }

    checks.append(layoutCheck(inputs))

    if let hints = hintActivationCheck(inputs.hintActivations) {
      checks.append(hints)
    }

    if let popups = popupCommandCheck(inputs) { checks.append(popups) }

    if let values = statusValuesCheck(inputs) { checks.append(values) }

    if let links = statusLinksCheck(inputs.refusedLinkSchemes) { checks.append(links) }

    if let receiver = inputs.telemetryReceiver.flatMap(telemetryReceiverCheck) {
      checks.append(receiver)
    }

    if let granted = inputs.screenRecordingGranted {
      checks.append(
        granted
          ? Check(id: "screen_recording", status: .ok, summary: "Screen Recording granted")
          : Check(
            id: "screen_recording", status: .warn,
            summary: "Screen Recording is not granted; :screenshot asks for it on first use"))
    }
    return Report(checks: checks)
  }

  /// Status links refused since launch: a `#[link]` whose scheme is neither
  /// web, mail nor allowlisted does nothing, and the log names only the
  /// scheme, so this is where the user learns which setting would allow it.
  /// Absent while nothing was refused.
  static func statusLinksCheck(_ refused: [String]) -> Check? {
    guard !refused.isEmpty else { return nil }
    let list = refused.filter(StatusLinkPolicy.isSchemeName)
      .map { "\"\($0)\"" }.joined(separator: ", ")
    var details = ["A #[link] opens only http, https and mailto URLs; a refused link does nothing."]
    if !list.isEmpty {
      details.append(
        "Allow a scheme with [statusbar] link_schemes = [\(list)] "
          + "when you trust what writes those links.")
    }
    if refused.contains("(none)") {
      details.append("A link without a scheme needs an absolute URL; it cannot be allowlisted.")
    }
    return Check(
      id: "status_links", status: .warn,
      summary: "\(refused.count) status link scheme\(refused.count == 1 ? " was" : "s were") "
        + "refused since launch: " + refused.joined(separator: ", "),
      details: details)
  }

  /// The OTLP receiver listens on loopback, which every account and program
  /// on the Mac shares. Without a token that is harmless until a monitor
  /// runs a command from a received metric: then anyone local can fire it.
  /// Absent while the receiver is off; a warning, since the receiver is
  /// opt-in by design.
  static func telemetryReceiverCheck(_ receiver: TelemetryReceiverState) -> Check? {
    guard receiver.enabled else { return nil }
    let address = "127.0.0.1:\(receiver.port)"
    if receiver.hasToken {
      return Check(
        id: "telemetry_receiver", status: .ok,
        summary: "the OTLP receiver on \(address) requires its token")
    }
    let monitors = receiver.monitorsRunOnReceivedMetrics
    guard !monitors.isEmpty else {
      return Check(
        id: "telemetry_receiver", status: .ok,
        summary: "the OTLP receiver on \(address) has no token; "
          + "no monitor runs a command from a received metric")
    }
    return Check(
      id: "telemetry_receiver", status: .warn,
      summary: "the OTLP receiver on \(address) has no token, and \(monitors.count) monitor"
        + (monitors.count == 1 ? " runs" : "s run") + " commands from received metrics: "
        + monitors.joined(separator: ", "),
      details: [
        "Any program on this Mac, under any account, can post a metric there and fire them.",
        "Set [telemetry.receiver] token and send it as Authorization: Bearer <token> "
          + "(OTEL_EXPORTER_OTLP_HEADERS), or drop run from those monitors.",
      ])
  }

  /// An app is judged once it has this many recent activations.
  static let hintActivationsJudged = 5
  /// An app whose activations came back empty at least this often (a fifth)…
  static let hintEmptyShareWarning = 0.2
  /// …or whose shown hints took longer than this at the 95th percentile.
  static let hintP95WarningMs = 500.0

  /// How hint activations have gone lately, per app. Absent until Flash has
  /// recorded any; a warning, never an issue, since an app may simply have
  /// nothing to click.
  /// Terminal popups whose executable the popup `PATH` does not hold: they
  /// fail as `command not found` until the tool is installed.
  static func popupCommandCheck(_ inputs: Inputs) -> Check? {
    guard !inputs.popupCommands.isEmpty else { return nil }
    let missing = inputs.popupCommands.sorted { $0.key < $1.key }.filter {
      TerminalExecutable.resolve($0.value, path: inputs.popupPath) == nil
    }
    guard !missing.isEmpty else {
      return Check(
        id: "popup_commands", status: .ok, summary: "every terminal popup's command is installed")
    }
    return Check(
      id: "popup_commands", status: .warn,
      summary: "\(missing.count) terminal popup command(s) are not on the login PATH",
      details: missing.map { "popup.\($0.key): \($0.value)" } + [
        "Flash reads PATH from your login shell at launch and on config reload.",
        "After installing a tool, Command-R in its popup rereads it and starts it.",
      ])
  }

  /// Plugin values a surface reads that no loaded plugin publishes: they
  /// show nothing, and the config check cannot know which plugins exist. A
  /// value from a merged plugin names its replacement: `<old>_<name>` in a
  /// plugin that declares it (cpu.label is sysinfo.cpu_label), or the same
  /// name under another plugin (tmux.session is terminals.session).
  static func statusValuesCheck(_ inputs: Inputs) -> Check? {
    guard !inputs.statusSegmentsRead.isEmpty else { return nil }
    let declared = inputs.statusSegmentsDeclared
    func replacement(plugin: String, name: String) -> String? {
      for candidate in ["\(plugin)_\(name)", name] {
        if let owner = declared.keys.sorted().first(where: {
          $0 != plugin && declared[$0]?.contains(candidate) == true
        }) {
          return "flash.plugin.\(owner).\(candidate)"
        }
      }
      return nil
    }
    var problems: [String] = []
    for plugin in inputs.statusSegmentsRead.keys.sorted() {
      for name in inputs.statusSegmentsRead[plugin, default: []].sorted() {
        let value = "flash.plugin.\(plugin).\(name)"
        if inputs.disabledPlugins.contains(plugin) {
          problems.append("\(value): the \(plugin) plugin is disabled ([plugins] disabled)")
        } else if let names = declared[plugin] {
          guard !names.contains(name) else { continue }
          problems.append(
            "\(value): the \(plugin) plugin publishes no \(name) (it has "
              + names.sorted().joined(separator: ", ") + ")")
        } else {
          problems.append(
            "\(value): no \(plugin) plugin is loaded"
              + (replacement(plugin: plugin, name: name).map { "; did you mean \($0)?" } ?? ""))
        }
      }
    }
    guard !problems.isEmpty else {
      return Check(
        id: "status_values", status: .ok,
        summary: "every plugin value your bar, widgets and monitors read is published")
    }
    return Check(
      id: "status_values", status: .warn,
      summary: "\(problems.count) plugin value\(problems.count == 1 ? "" : "s") will stay empty",
      details: problems)
  }

  static func hintActivationCheck(_ apps: [HintActivationStats.Summary]) -> Check? {
    guard !apps.isEmpty else { return nil }
    let flagged = apps.filter { app in
      app.count >= hintActivationsJudged
        && (Double(app.empty) >= hintEmptyShareWarning * Double(app.count)
          || (app.p95Ms ?? 0) > hintP95WarningMs)
    }
    guard !flagged.isEmpty else {
      let total = apps.map(\.count).reduce(0, +)
      let shown = apps.map { $0.count - $0.empty }.reduce(0, +)
      return Check(
        id: "hint_activations", status: .ok,
        summary: "hints appeared in \(shown) of \(total) recent activations across "
          + "\(apps.count) app\(apps.count == 1 ? "" : "s")")
    }
    return Check(
      id: "hint_activations", status: .warn,
      summary: "hints were often empty or slow in \(flagged.count) app"
        + (flagged.count == 1 ? "" : "s") + ": "
        + flagged.map(\.bundleIdentifier).joined(separator: ", "),
      details: flagged.map { app in
        "\(app.bundleIdentifier): \(app.empty) of \(app.count) recent activations showed no hints"
          + (app.p95Ms.map { String(format: "; p95 %.0f ms", $0) } ?? "")
      } + [
        "`[latency] hints_visible` and `hints_empty` lines name each activation; "
          + "docs/performance.md explains them."
      ])
  }

  /// Keys the hint alphabet or the grid use that the layout keys are read
  /// on cannot type: those labels could never be selected.
  private static func layoutCheck(_ inputs: Inputs) -> Check {
    var details: [String] = []
    if let missing = inputs.missingKeyboardLayout {
      details.append(
        "app.keyboard_layout names \(missing), which is not an installed keyboard layout; "
          + "keys are read as US-ANSI")
    }
    guard let layout = inputs.readLayout else {
      return Check(
        id: "keyboard_layout", status: details.isEmpty ? .warn : .error,
        summary: "the current keyboard layout could not be read", details: details)
    }
    func untypable(_ keys: [Character], on characters: Set<Character>) -> String {
      let typable = Set(characters.flatMap { $0.lowercased() })
      var seen = Set<Character>()
      return String(
        keys.filter { key in
          key.lowercased().contains { !typable.contains($0) } && seen.insert(key).inserted
        })
    }
    // A hint key may need Shift; a grid key may not, since Shift on it
    // rides the click.
    let hints = untypable(inputs.hintKeys, on: layout.typableCharacters)
    let grid = untypable(inputs.gridKeys, on: layout.unshiftedCharacters)
    if !hints.isEmpty { details.append("hints.keys: \(hints)") }
    if !grid.isEmpty { details.append("mouse grid keys: \(grid)") }
    guard !details.isEmpty else {
      return Check(
        id: "keyboard_layout", status: .ok,
        summary: "every hint and grid key can be typed on \(layout.sourceID)")
    }
    return Check(
      id: "keyboard_layout", status: .error,
      summary: hints.isEmpty && grid.isEmpty
        ? "app.keyboard_layout names a keyboard layout that is not installed"
        : "some hint or grid keys cannot be typed on \(layout.sourceID)",
      details: details)
  }

  /// The CLI's readable rendering of a doctor reply.
  static func render(_ object: [String: Any]) -> String {
    let checks = object["checks"] as? [[String: Any]] ?? []
    var lines: [String] = []
    for check in checks {
      let status = check["status"] as? String ?? "?"
      let marker = status == "ok" ? "ok  " : status == "warn" ? "warn" : "FAIL"
      lines.append("\(marker)  \(check["summary"] as? String ?? "")")
      guard status != "ok" else { continue }
      for detail in check["details"] as? [String] ?? [] { lines.append("      \(detail)") }
    }
    let issues = object["issues"] as? Int ?? 0
    let warnings = object["warnings"] as? Int ?? 0
    lines.append("")
    lines.append(
      issues == 0
        ? "No issues\(warnings == 0 ? "" : " (\(warnings) warning\(warnings == 1 ? "" : "s"))")."
        : "\(issues) issue\(issues == 1 ? "" : "s") found.")
    return lines.joined(separator: "\n")
  }

  // MARK: Probe helpers (pure halves)

  /// `kCGSSessionSecureInputPID` from each `IOConsoleUsers` entry: the
  /// processes holding secure input on each console session.
  static func secureInputPIDs(consoleUsers: [[String: Any]]) -> [pid_t] {
    consoleUsers.compactMap { user in
      (user["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }.filter { $0 > 0 }
  }

  /// A code signature's kind from `SecCodeCopySigningInformation`'s flags
  /// and leaf certificate.
  static func signature(flags: UInt32, leafCertificate: String?, identifier: String?)
    -> Signature
  {
    if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }
    if let leafCertificate { return .certificate(leafCertificate) }
    return identifier == nil ? .unsigned : .unknown
  }
}

/// The live reads behind `Doctor.Inputs`.
enum DoctorProbe {
  /// Who holds secure input, read from the IORegistry root's console users.
  static func secureInputHolders() -> [Doctor.Process] {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return [] }
    defer { IOObjectRelease(root) }
    guard
      let users = IORegistryEntryCreateCFProperty(
        root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? [[String: Any]]
    else { return [] }
    return Doctor.secureInputPIDs(consoleUsers: users).map {
      Doctor.Process(pid: $0, name: processName($0))
    }
  }

  static func signature(bundleURL: URL) -> Doctor.Signature {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code
    else { return .unknown }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any]
    else { return .unknown }
    let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let leaf = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
      .flatMap { SecCertificateCopySubjectSummary($0) as String? }
    return Doctor.signature(
      flags: flags, leafCertificate: leaf,
      identifier: dictionary[kSecCodeInfoIdentifier as String] as? String)
  }

  /// Other residents with this bundle identifier. A CLI invocation of the
  /// same binary never registers as an app, so it is not counted.
  static func otherResidents() -> [Doctor.Process] {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != getpid() && $0.activationPolicy != .prohibited }
      .map { Doctor.Process(pid: $0.processIdentifier, name: $0.bundleURL?.path) }
  }

  static func processName(_ pid: pid_t) -> String? {
    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }
}
