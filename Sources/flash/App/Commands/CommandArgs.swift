import AppKit
import FlashCore

/// Args bag for a command dispatch. Constructed from the JSON dictionary on
/// the AppleEvent payload (CLI path) or from a mapping array's `k=v`
/// tail (config path). The few `bool` / `int` accessors keep the
/// dispatch table tight.
struct CommandArgs {
  let args: [String: String]
  func value(_ name: String) -> String? {
    args[name]
  }
  func bool(_ name: String) -> Bool {
    let v = args[name]
    return v == "1" || v == "true"
  }
  func int(_ name: String) -> Int? {
    args[name].flatMap(Int.init)
  }
}

extension URLEventHandler {
  /// Read the optional register shared by yank, paste and selection commands.
  static func registerArg(_ a: CommandArgs) -> String? {
    a.value("register")
  }

  static func validRegisterArg(_ a: CommandArgs) -> Bool {
    guard let raw = registerArg(a) else { return true }
    return raw.count == 1 && raw.first.map(NormalModeInterpreter.isRegisterNameChar) == true
  }
}
