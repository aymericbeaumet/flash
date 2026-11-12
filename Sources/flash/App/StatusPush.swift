import FlashCore
import Foundation

/// `status set --name=<source> --value=<text>` and `status clear
/// --name=<source>`: a value pushed into a declared `[statusbar.sources]`
/// source the moment something happens — an AeroSpace workspace change, a
/// yabai signal, any script — instead of waiting for its poll. The value is
/// ingested exactly as a run's output would be (history, cycles); a source
/// with a command keeps running and replaces it on its next run, and one
/// without is only ever pushed.
struct StatusPush: Hashable {
  var source: String
  /// Nil clears the source.
  var value: String?

  var name: CommandName {
    CommandName("status", value == nil ? "clear" : "set")
  }

  var argTokens: [String] {
    var tokens = ["--name=\(source)"]
    if let value { tokens.append("--value=\(value)") }
    return tokens
  }

  var explanation: String {
    guard let value else { return "Clears the \(source) status source." }
    return "Sets the \(source) status source to “\(value)”."
  }

  /// Why a push to `source` cannot land, or nil when it can.
  static func rejection(source: String, declared: Set<String>) -> String? {
    declared.contains(source)
      ? nil : "no status source named \(source); declare [statusbar.sources.\(source)]"
  }
}

/// `status refresh --name=<source>`: run a declared source's command now.
enum StatusRefresh {
  static let name = CommandName("status", "refresh")

  static func explanation(_ source: String) -> String {
    "Runs the \(source) status source's command now."
  }

  /// Why `source` cannot refresh, or nil when it runs: it must be declared,
  /// have a command, and be shown by the bar or a widget (a source nothing
  /// shows runs nothing).
  static func refusal(source: String, definition: FlashStatusBarSourceDefinition?, shown: Bool)
    -> String?
  {
    guard let definition else {
      return "no status source named \(source); declare [statusbar.sources.\(source)]"
    }
    if definition.isPushed { return "\(source) has no command; status set changes it" }
    if !shown { return "\(source) is not shown: no bar or widget reads #{flash.source.\(source)}" }
    return nil
  }
}
