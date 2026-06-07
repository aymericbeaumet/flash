import AppKit
import ApplicationServices
import FlashCore

/// Focused-app context resolution: turns workspace + WindowServer data
/// into the `AppContext` values that activation discovery and the
/// prepared-model builder consume. Handles "front-most app", "front-most
/// excluding Flash itself", and per-pid lookup.
extension AppMonitor {
  func currentContext() -> AppContext? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return makeContext(for: app)
  }

  func frontmostContext(excludingBundleIdentifier ignoredBundleIdentifier: String) -> AppContext? {
    if let context = currentContext(),
      context.bundleIdentifier != ignoredBundleIdentifier
    {
      return clip(context, to: topWindowFrame(for: context.processID) ?? context.frontWindowFrame)
    }
    return topVisibleWindowContext(excludingBundleIdentifier: ignoredBundleIdentifier)
  }

  func context(for pid: pid_t) -> AppContext? {
    guard pid > 0,
      let app = NSRunningApplication(processIdentifier: pid)
    else { return nil }
    guard let context = makeContext(for: app) else { return nil }
    return clip(context, to: topWindowFrame(for: pid) ?? context.frontWindowFrame)
  }


  func clip(_ context: AppContext, to frame: CGRect) -> AppContext {
    AppContext(
      bundleIdentifier: context.bundleIdentifier,
      processID: context.processID,
      runningApp: context.runningApp,
      frontWindowFrame: frame.isNull ? context.frontWindowFrame : frame,
      allScreensFrame: context.allScreensFrame
    )
  }

  func union(of rects: [CGRect]) -> CGRect {
    var out: CGRect = .null
    for rect in rects { out = out.union(rect) }
    return out
  }

  func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  /// Push runtime config that should take effect on the next activation.
  func configureRuntime(for cfg: Config) {
    FlashLog.setLevel(cfg.debug.logLevel)
  }

  // MARK: Context

  func makeContext(
    for app: NSRunningApplication,
    frontWindowFrame: CGRect? = nil
  ) -> AppContext? {
    let pid = app.processIdentifier
    guard pid > 0 else { return nil }

    var screenFrame: CGRect = .null
    for s in NSScreen.screens { screenFrame = screenFrame.union(s.frame) }
    if screenFrame.isNull { screenFrame = .zero }

    // Deliberately no AX IPC here. `makeContext` runs on the main thread
    // every time the user activates, and a single kAXFocusedWindowAttribute
    // call on a cold AX server can add 100-300 ms of latency to the
    // overlay appearing. The AX queue builds a WindowServer visibility
    // snapshot and passes a clipped context to providers, so the
    // centre-in-visible check works without needing a precomputed AX
    // window frame from main.
    let windowFrame = frontWindowFrame ?? screenFrame
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: pid,
      runningApp: app,
      frontWindowFrame: windowFrame,
      allScreensFrame: screenFrame
    )
  }

  private func topWindowFrame(for pid: pid_t) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight())
      .first { $0.layer == 0 && $0.pid == pid && $0.pid != getpid() }?
      .nsBounds
  }

  private func topVisibleWindowContext(
    excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    for entry in WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight()) {
      guard entry.layer == 0, entry.pid > 0, entry.pid != getpid(),
        let app = NSRunningApplication(processIdentifier: entry.pid),
        !app.isTerminated,
        app.bundleIdentifier != ignoredBundleIdentifier
      else { continue }
      return makeContext(for: app, frontWindowFrame: entry.nsBounds)
    }
    return nil
  }
}
