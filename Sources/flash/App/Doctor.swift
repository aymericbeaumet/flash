import AppKit
import IOKit
import Security

/// `flash doctor` and `:doctor`: every check that turns "Flash doesn't work"
/// into a fix. `run` is pure over `Inputs`; `DoctorProbe` gathers them, the
/// slow ones (IORegistry, code signature, plugin sandbox compiles) off the
/// main thread. An `error` check is an issue and makes `flash doctor` exit 1;
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
    /// `path:line:col: message` lines, as `flash config_check` prints them.
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
            "It usually means a password field has focus, or an app left secure input on.",
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
