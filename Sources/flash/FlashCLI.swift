import AppKit
import Foundation

// CLI half of the `flash` binary. When the executable is launched with any
// extra argv (`flash mouse_target`, `flash app_open --name=Firefox`, …), main
// dispatches here instead of starting `NSApplication`. We then encode the
// verb + key=value args into a custom AppleEvent and send it to the running
// resident. The legacy `flash://` URL scheme is gone — this is the only
// external entry point.
//
// Wire format
// -----------
//
// AppleEvent class:  'Flsh' (0x466C7368)
// AppleEvent ID:     'Cmd ' (0x436D6420)
// Direct object:     AERecord with descriptor keys:
//                      'Verb' (typeUTF8Text) — the action name (`mouse_target`)
//                      'Args' (typeUTF8Text) — JSON dictionary of key→string
//
// `Args` is JSON rather than a nested record so the encoding stays trivial
// and the receiver doesn't need to walk an AEDesc list to read each key.
//
// Security
// --------
//
// The CLI and resident use the same executable, but macOS Automation can
// attribute a subprocess request to its launching app. GUI launchers need
// an AppleEvents usage description and the applicable Automation permission.
//
// This entry point is intentionally narrow: no shell expansion, no
// pass-through to other binaries — anything that isn't a known verb returns
// non-zero and exits.

enum FlashCLI {
  // Four-byte AE fourcc codes. Packed big-endian so the wire is stable
  // independently of host endianness; both ends decode them the same way.
  static let appleEventClass: AEEventClass = fourCharCode("Flsh")
  static let appleEventID: AEEventID = fourCharCode("Cmd ")
  static let verbKey: AEKeyword = fourCharCode("Verb")
  static let argsKey: AEKeyword = fourCharCode("Args")

  static let usage = """
    Usage:
      flash <verb> [--name=value | --flag ...]
      flash status [--json]            the resident's state
      flash doctor [--json]            check permissions, capture, config, plugins
      flash config_check [--file=path] validate a config file without the resident

    Examples:
      flash mouse_target
      flash mouse_target --modifiers=cmd
      flash mouse_target --double
      flash mouse_grid --move
      flash enter_normal_mode
      flash leave_mode

      flash app_open --name=Firefox
      flash window_move --position=lefthalf
      flash window_move --x=10% --y=10% --width=80% --height=80%
      flash help_show
    """

  static func run(args: [String]) -> Int32 {
    guard let first = args.first else {
      FileHandle.standardError.write((usage + "\n").data(using: .utf8) ?? Data())
      return 2
    }
    if first == "-h" || first == "--help" {
      print(usage)
      return 0
    }
    let verb = first
    let argEntries = Array(args.dropFirst())
    do {
      let argDict = try CommandArguments.parse(argEntries)
      if let query = FlashQuery(rawValue: verb) {
        return runQuery(query, args: argDict)
      }
      guard URLEventHandler.parseOrPluginVerb(verb: verb, args: argDict) != nil else {
        FileHandle.standardError.write(
          Data("flash: invalid command or arguments for '\(verb)'\n".utf8))
        return 2
      }
      return sendVerb(verb, args: argDict)
    } catch {
      FileHandle.standardError.write(Data("flash: \(error)\n".utf8))
      return 2
    }

  }

  private static func sendVerb(_ verb: String, args: [String: String]) -> Int32 {
    guard let (status, reply) = send(verb, args: args) else { return 1 }
    let result = response(verb: verb, status: status, reply: reply)
    if let message = result.message {
      FileHandle.standardError.write(Data("flash: \(message)\n".utf8))
    }
    return result.exitCode
  }

  /// `status` and `doctor` ask the resident; `config_check` runs here.
  private static func runQuery(_ query: FlashQuery, args: [String: String]) -> Int32 {
    guard let options = queryOptions(query, args: args) else {
      FileHandle.standardError.write(
        Data("flash: invalid arguments for '\(query.rawValue)'\n\(usage)\n".utf8))
      return 2
    }
    let result: (exitCode: Int32, output: String?, message: String?)
    switch query {
    case .configCheck:
      let url =
        options.file.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment)
      let check = ConfigCheck.run(
        fileURL: url.resolvingSymlinksInPath(),
        text: (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) },
        defaultLayer: ConfigLoader.embeddedDefaultLayer(in: appBundle))
      result = (
        check.exitCode, check.lines.isEmpty ? nil : check.lines.joined(separator: "\n"), nil
      )
    case .status, .doctor:
      // The doctor compiles every sandboxed plugin's profile: seconds, not ticks.
      let timeout = query == .doctor ? 60 * 60 : 5 * 60
      guard let (status, reply) = send(query.rawValue, args: [:], timeoutTicks: timeout) else {
        return 1
      }
      result = queryOutcome(query, json: options.json, status: status, reply: reply)
    }
    if let output = result.output { print(output) }
    if let message = result.message {
      FileHandle.standardError.write(Data("flash: \(message)\n".utf8))
    }
    return result.exitCode
  }

  /// The app bundle this executable lives in. Run through the
  /// `~/.local/bin/flash` symlink, `Bundle.main` is the symlink's directory,
  /// so the bundle is found from the executable's resolved path.
  static var appBundle: Bundle {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      return .main
    }
    return appBundle(containing: executable) ?? .main
  }

  /// `…/Flash.app` for `…/Flash.app/Contents/MacOS/flash`; nil outside a bundle.
  static func appBundle(containing executable: URL) -> Bundle? {
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      app.pathExtension == "app"
    else { return nil }
    return Bundle(url: app)
  }

  /// `--json` for `status` / `doctor`, `--file=<path>` for `config_check`;
  /// nil for anything else.
  static func queryOptions(_ query: FlashQuery, args: [String: String]) -> (
    json: Bool, file: String?
  )? {
    switch query {
    case .status, .doctor:
      guard args.keys.allSatisfy({ $0 == "json" }), args["json"].map({ $0 == "1" }) ?? true
      else { return nil }
      return (args["json"] != nil, nil)
    case .configCheck:
      guard args.keys.allSatisfy({ $0 == "file" }), args["file"].map({ !$0.isEmpty }) ?? true
      else { return nil }
      return (false, args["file"])
    }
  }

  /// A query's reply: the JSON in its direct object, printed as-is with
  /// `--json` or rendered as text. `doctor` exits 1 when it found an issue.
  static func queryOutcome(
    _ query: FlashQuery, json: Bool, status: OSStatus, reply: NSAppleEventDescriptor
  ) -> (exitCode: Int32, output: String?, message: String?) {
    let transport = response(verb: query.rawValue, status: status, reply: reply)
    guard transport.exitCode == 0 else { return (transport.exitCode, nil, transport.message) }
    guard
      let text = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
      let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    else { return (1, nil, "the resident's \(query.rawValue) reply carried no JSON") }
    let output: String
    if json {
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      output = data.flatMap { String(data: $0, encoding: .utf8) } ?? text
    } else {
      output = query == .doctor ? Doctor.render(object) : FlashStatusReport.render(object)
    }
    let failed = query == .doctor && (object["issues"] as? Int ?? 0) > 0
    return (failed ? 1 : 0, output, nil)
  }

  /// Send `verb` to the resident and wait for its reply; nil (after a
  /// diagnostic) when the event could not even be built.
  private static func send(_ verb: String, args: [String: String], timeoutTicks: Int = 5 * 60)
    -> (OSStatus, NSAppleEventDescriptor)?
  {
    let bundleID = "com.flash.app"
    var targetAddr = AEAddressDesc()
    guard
      AECreateDesc(
        DescType(typeApplicationBundleID),
        bundleID,
        bundleID.utf8.count,
        &targetAddr
      ) == noErr
    else {
      FileHandle.standardError.write(
        "flash: could not address \(bundleID)\n".data(using: .utf8) ?? Data())
      return nil
    }
    defer { AEDisposeDesc(&targetAddr) }

    var event = AppleEvent()
    guard
      AECreateAppleEvent(
        appleEventClass,
        appleEventID,
        &targetAddr,
        AEReturnID(kAutoGenerateReturnID),
        AETransactionID(kAnyTransactionID),
        &event
      ) == noErr
    else {
      FileHandle.standardError.write(
        "flash: could not build apple event\n".data(using: .utf8) ?? Data())
      return nil
    }
    defer { AEDisposeDesc(&event) }

    addUTF8(value: verb, to: &event, key: verbKey)
    let argsJSON: String
    if let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      argsJSON = text
    } else {
      argsJSON = "{}"
    }
    addUTF8(value: argsJSON, to: &event, key: argsKey)

    var reply = AppleEvent()
    // Quit tears down the resident before a reply can be sent.
    let sendMode = verb == "quit" ? kAENoReply : kAEWaitReply
    let status = AESendMessage(&event, &reply, AESendMode(sendMode), timeoutTicks)
    return (status, NSAppleEventDescriptor(aeDescNoCopy: &reply))
  }

  static func response(
    verb: String, status: OSStatus, reply: NSAppleEventDescriptor
  ) -> (exitCode: Int32, message: String?) {
    if status == procNotFound {
      return (1, "Flash is not running")
    }
    if status != noErr {
      return (1, "could not send \(verb) (OSStatus=\(status))")
    }
    guard let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value,
      error != 0
    else { return (0, nil) }
    let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
    if error == errAEEventNotHandled, let message, !message.isEmpty {
      return (2, message)
    }
    let detail = message.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
    return (1, "AppleEvent \(verb) failed (OSStatus=\(error))\(detail)")
  }

  private static func addUTF8(value: String, to event: inout AppleEvent, key: AEKeyword) {
    let data = Array(value.utf8)
    _ = AEPutParamPtr(&event, key, DescType(typeUTF8Text), data, data.count)
  }
}

/// Pack four ASCII characters into a big-endian fourcc the AppleEvent API
/// expects. Crashes deterministically if `s` isn't exactly four ASCII bytes
/// — keep callers to compile-time string literals.
private func fourCharCode(_ s: String) -> UInt32 {
  let bytes = Array(s.utf8)
  precondition(bytes.count == 4, "fourCharCode requires a 4-byte ASCII string")
  return (UInt32(bytes[0]) << 24)
    | (UInt32(bytes[1]) << 16)
    | (UInt32(bytes[2]) << 8)
    | UInt32(bytes[3])
}
