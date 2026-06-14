import AppKit
import Foundation

// CLI half of the `flash` binary. When the executable is launched with any
// extra argv (`flash mouse_target`, `flash app_open name=Firefox`, …), main
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
// Apple Events between two binaries with the *same* code-signing identity
// don't trigger the macOS Automation TCC prompt; the CLI symlink at
// `~/.local/bin/flash` and the resident at `/Applications/Flash.app` point
// to the same Mach-O, so this stays prompt-free for the maintainer.
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
      flash <verb> [key=value ...]

    Examples:
      flash mouse_target
      flash mouse_target double=1
      flash mouse_grid move=1
      flash mode_normal
      flash app_open name=Firefox
      flash window_move position=lefthalf
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
    let verb = first.replacingOccurrences(of: "-", with: "_")
    let argEntries = Array(args.dropFirst())
    let argDict = parseKeyValueArgs(verb: verb, rest: argEntries)
    return sendVerb(verb, args: argDict)
  }

  /// Parses `key=value` argv into a flat dictionary. Two verb-specific
  /// conveniences match what users typed before the URL scheme was removed:
  ///   `flash app_open Firefox`            → name=Firefox
  ///   `flash alert_show hello world`      → message=hello world
  /// so existing user muscle memory doesn't break.
  private static func parseKeyValueArgs(verb: String, rest: [String]) -> [String: String] {
    if verb == "app_open", rest.count == 1, !rest[0].contains("=") {
      return ["name": rest[0]]
    }
    if verb == "alert_show", !rest.contains(where: { $0.contains("=") }) {
      return ["message": rest.joined(separator: " ")]
    }
    var out: [String: String] = [:]
    for entry in rest {
      guard let eq = entry.firstIndex(of: "=") else { continue }
      let key = String(entry[..<eq])
      let value = String(entry[entry.index(after: eq)...])
      out[key] = value
    }
    return out
  }

  private static func sendVerb(_ verb: String, args: [String: String]) -> Int32 {
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
      return 1
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
      return 1
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
    let status = AESendMessage(&event, &reply, AESendMode(kAENoReply), 5 * 60)
    defer { AEDisposeDesc(&reply) }
    if status != noErr {
      FileHandle.standardError.write(
        "flash: could not send \(verb) (OSStatus=\(status))\n".data(using: .utf8) ?? Data())
      return 1
    }
    return 0
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
