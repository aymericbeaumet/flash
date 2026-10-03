import AppKit

// @unchecked Sendable: `runningApp` is `NSRunningApplication`, which Apple has
// not annotated `Sendable`. Each `AppContext` is constructed once on the main
// thread from a focus snapshot and treated as immutable thereafter; provider
// walks and source resolvers only read its fields from background queues.
public struct AppContext: @unchecked Sendable {
  /// Where an Accessibility walk of the app starts.
  public enum WalkRoot: Sendable, Equatable {
    /// The app's focused (else main, else first) window: every app surface.
    case focusedWindow
    /// The app's top-level elements that meet `frontWindowFrame`: a surface
    /// that is not the app's focused window, such as a Picture in Picture
    /// player or the Stage Manager strip (`mouse_target --scope=screen`).
    case elementsInFrame
  }

  public let bundleIdentifier: String
  public let processID: pid_t
  public let runningApp: NSRunningApplication
  public let frontWindowFrame: CGRect
  public let allScreensFrame: CGRect
  public let walkRoot: WalkRoot

  public init(
    bundleIdentifier: String,
    processID: pid_t,
    runningApp: NSRunningApplication,
    frontWindowFrame: CGRect,
    allScreensFrame: CGRect,
    walkRoot: WalkRoot = .focusedWindow
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.processID = processID
    self.runningApp = runningApp
    self.frontWindowFrame = frontWindowFrame
    self.allScreensFrame = allScreensFrame
    self.walkRoot = walkRoot
  }
}
