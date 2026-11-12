import FlashCore

/// `updates check` and `updates install`. The topic is plural: vim's
/// `:up[date]` is the command line's save.
enum UpdatesCommand: String, Hashable, CaseIterable {
  /// Ask GitHub for the newest release now and say what it means here.
  case check
  /// Download, verify and install the newest release, then restart Flash.
  case install

  var name: CommandName { CommandName("updates", rawValue) }

  var summary: String {
    switch self {
    case .check: return "Check GitHub for a newer Flash and say what installing it means"
    case .install: return "Download, verify and install the newest Flash, then restart it"
    }
  }

  var explanation: String {
    switch self {
    case .check: return "Checks GitHub for a newer release of Flash."
    case .install: return "Installs the newest release of Flash and restarts it."
    }
  }
}
