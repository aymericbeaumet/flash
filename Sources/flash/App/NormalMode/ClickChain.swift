import CoreGraphics
import Darwin
import FlashCore

/// A click chain: `mouse target --multi` (NORMAL's `alt+f`), `--sticky` and
/// `mouse grid --multi` keep their session up after every click until
/// Escape. What one click leads to, and what refreshes a chain's labels
/// between two picks, are decided here from values alone.
enum ClickChain {
  /// What a chain does once one of its clicks has gone out. A click on an
  /// input is no exception: no click enters INSERT, so the chain goes on
  /// after it like after any other until Escape.
  enum Step: Equatable {
    /// The click opened a menu (a secondary or Control-click, a click into
    /// the menu bar): the chain ends and the menu keeps the keyboard, as it
    /// does after `cf`.
    case nativeMenu
    /// The click left the surface the labels describe (a Mission Control
    /// window or desktop): the chain ends.
    case end
    /// `--multi`: discover the targets again; those still there keep their
    /// labels.
    case rediscover
    /// `--sticky`: the same labels again, with no new walk.
    case relabel
  }

  /// One click of a chain, as the decision reads it.
  struct Click: Equatable {
    var action: JumpAction
    /// The modifiers the click carried: the session's and those held on the
    /// final label key.
    var modifiers: ClickModifiers
    /// The point is in the native menu bar's band, not on Flash's own bar.
    var inMenuBar: Bool
    /// The click leaves the surface the labels were drawn for.
    var leavesSurface: Bool
  }

  static func step(after click: Click, sticky: Bool) -> Step {
    if opensMenu(action: click.action, modifiers: click.modifiers) || click.inMenuBar {
      return .nativeMenu
    }
    if click.leavesSurface { return .end }
    return sticky ? .relabel : .rediscover
  }

  /// A secondary click, or a Control-click (the macOS secondary click), opens
  /// a context menu.
  static func opensMenu(action: JumpAction, modifiers: ClickModifiers) -> Bool {
    action == .rightClick || modifiers.contains(.control)
  }

  /// How long the chain's app must stay quiet after reporting a change
  /// before its targets are discovered again: a page load or a list filling
  /// in reports in bursts, and one walk follows the burst.
  static let refreshSettleMs = 120

  /// Whether a change app `reportedPID` reported should discover the chain's
  /// targets again: only a `--multi` chain over that app's targets, while it
  /// waits for its next pick with nothing typed and no click going out.
  static func refreshes(_ session: HintSession, reportedPID: pid_t, committing: Bool) -> Bool {
    session.awaitsChainPick && session.sourceAppPID == reportedPID && !committing
  }

  /// A pick whose target changed or went away clicks nothing (identity is
  /// validated before every click). A `--multi` chain over targets then
  /// discovers again instead of ending; every other session ends.
  static func survivesUnavailableTarget(_ session: HintSession) -> Bool {
    session.command.isMulti && session.surface == .targets
  }
}

extension HintSession {
  /// A `--multi` chain over an app's targets showing its labels, with
  /// nothing typed and no first point of a gesture chosen: the state a
  /// change in that app may refresh.
  var awaitsChainPick: Bool {
    guard command.isMulti, surface == .targets, missionControl == nil, !hints.isEmpty,
      prefix.isEmpty
    else { return false }
    if case .labels(anchor: nil) = phase { return true }
    return false
  }
}
