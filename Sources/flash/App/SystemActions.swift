import AppKit
import FlashCore
import Foundation

/// The machine and session actions Flash performs itself: one command each
/// (`flash screen lock`), and one row each in `@actions`. The raw value
/// is the command's words.
enum SystemAction: String, CaseIterable, Hashable {
  case screenLock = "screen lock"
  case systemSleep = "system sleep"
  case displaySleep = "display sleep"
  case systemRestart = "system restart"
  case systemShutdown = "system shutdown"
  case systemLogout = "system logout"
  case trashEmpty = "trash empty"
  case darkModeToggle = "appearance toggle"
  case screensaverStart = "screensaver start"

  /// `flash <topic> <action>` for this action.
  var name: CommandName {
    let words = rawValue.split(separator: " ").map(String.init)
    return CommandName(words[0], words[1])
  }

  var title: String {
    switch self {
    case .screenLock: return "Lock screen"
    case .systemSleep: return "Sleep Mac"
    case .displaySleep: return "Turn display off"
    case .systemRestart: return "Restart Mac"
    case .systemShutdown: return "Shut down Mac"
    case .systemLogout: return "Log out"
    case .trashEmpty: return "Empty Trash"
    case .darkModeToggle: return "Toggle dark mode"
    case .screensaverStart: return "Start screen saver"
    }
  }

  var subtitle: String {
    switch self {
    case .screenLock: return "Require password and keep apps running"
    case .systemSleep: return "Put the machine to sleep"
    case .displaySleep: return "Sleep the display without sleeping the machine"
    case .systemRestart: return "Ask macOS to restart"
    case .systemShutdown: return "Ask macOS to power off"
    case .systemLogout: return "End the current macOS login session"
    case .trashEmpty: return "Ask Finder to empty the Trash"
    case .darkModeToggle: return "Switch between light and dark appearance"
    case .screensaverStart: return "Launch ScreenSaverEngine"
    }
  }

  /// Extra words the flashlight matches besides the title: synonyms, and
  /// the words the action is commonly typed as.
  var aliases: [String] {
    switch self {
    case .screenLock: return ["lock", "screen", "secure", "password"]
    case .systemSleep: return ["sleep", "suspend", "standby"]
    case .displaySleep: return ["displaysleep", "display", "screen", "off"]
    case .systemRestart: return ["restart", "reboot"]
    case .systemShutdown: return ["shutdown", "power", "poweroff", "halt"]
    case .systemLogout: return ["logout", "sign out", "signout"]
    case .trashEmpty: return ["trash", "bin", "garbage"]
    case .darkModeToggle: return ["dark", "appearance", "light"]
    case .screensaverStart: return ["screensaver", "screen saver", "screensave"]
    }
  }

  /// The mapping explanation: what the command does, as one sentence.
  var explanation: String {
    switch self {
    case .screenLock: return "Locks the screen."
    case .systemSleep: return "Puts the Mac to sleep."
    case .displaySleep: return "Turns the displays off; the Mac stays awake."
    case .systemRestart: return "Asks before restarting the Mac."
    case .systemShutdown: return "Asks before shutting down the Mac."
    case .systemLogout: return "Asks before logging out of macOS."
    case .trashEmpty: return "Asks before emptying the Trash."
    case .darkModeToggle: return "Switches macOS between light and dark appearance."
    case .screensaverStart: return "Starts the screen saver."
    }
  }

  /// The question asked first for an action nothing undoes; nil runs at once.
  var confirmation: String? {
    switch self {
    case .systemRestart: return "Restart this Mac?"
    case .systemShutdown: return "Shut down this Mac?"
    case .systemLogout: return "Log out of macOS?"
    case .trashEmpty: return "Empty the Trash?"
    case .screenLock, .systemSleep, .displaySleep, .darkModeToggle, .screensaverStart:
      return nil
    }
  }

  /// What the command does now: ask its question, unless the user already said
  /// `y`, or run.
  func step(confirmed: Bool) -> ConfirmationStep {
    guard !confirmed, let confirmation else { return .run }
    return .ask(confirmation)
  }

  /// The host action behind the command (`HostSystemAction`), which holds
  /// the mechanism.
  var hostAction: HostSystemAction {
    switch self {
    case .screenLock: return .lockScreen
    case .systemSleep: return .sleep
    case .displaySleep: return .displaySleep
    case .screensaverStart: return .screensaver
    case .systemRestart: return .restart
    case .systemShutdown: return .shutdown
    case .systemLogout: return .logout
    case .trashEmpty: return .emptyTrash
    case .darkModeToggle: return .toggleAppearance
    }
  }

  /// How Flash carries the action out.
  var execution: SystemActionExecution { hostAction.execution }
}

/// One gated command's next step.
enum ConfirmationStep: Equatable {
  /// Show the question; `y` runs the command, confirmed.
  case ask(String)
  case run
  /// Nothing to run, for this reason.
  case refuse(String)
}

/// `@actions`: every system action as a flashlight row. Selecting one
/// runs its verb, and so asks first for the ones nothing undoes. The rows are
/// fixed; a live source serves them only when a query names the source.
final class SystemActionSource: FlashSource {
  static let label = "system.actions"
  let identifier = "core.system"
  let displayName = "core.system"
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: Self.label, type: "system")]
  }

  private let perform: (URLCommand) -> Void

  /// `perform` runs a selected row's command on main.
  init(perform: @escaping (URLCommand) -> Void) {
    self.perform = perform
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  static let rows: [Candidate] = SystemAction.allCases.map { action in
    Candidate(
      kind: .plugin("system_action"), sourceID: "core.system", source: label,
      title: action.title, subtitle: action.subtitle, sourcePayload: action.rawValue,
      searchAliases: (action.aliases + [action.rawValue]).joined(separator: " "),
      finishesCommand: true)
  }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    DispatchQueue.main.async { completion(Self.rows) }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    let action = candidate.sourcePayload.flatMap(SystemAction.init(rawValue:))
    DispatchQueue.main.async { [perform] in
      guard let action else {
        completion(.unresolved)
        return
      }
      // The flashlight settles first; the command may then ask its question.
      completion(.resolved(pid: nil))
      perform(.systemAction(action))
    }
  }
}
