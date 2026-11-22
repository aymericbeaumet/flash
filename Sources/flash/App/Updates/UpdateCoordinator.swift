import AppKit

/// `[app] updates`, the `updates` commands and the About window's button,
/// over one `UpdateController`. Automatic checks ride `PollScheduler`
/// (`core:updates`, priority `low`), armed only for a build a release can
/// replace and while `[app] updates` is not `off`. A downloaded update a
/// Developer ID build may install on its own waits for a moment nobody is
/// working (the screen locks or the displays sleep, idle) or for quit;
/// those observers exist only while such an update waits.
///
/// Main queue only: every entry point and every completion it hands back.
final class UpdateCoordinator {
  /// What the coordinator asks of the resident around it.
  struct Host {
    var alert: (StatusAlert) -> Void
    /// What the user is in the middle of, read when an update could apply.
    var activity: () -> UpdateApplyPolicy.Activity
    /// The About window's update button.
    var installAboutActions: (AboutUpdateActions) -> Void
  }

  static let checkPollID = "core:updates"
  /// The first automatic check waits for the resident to settle.
  static let firstCheckDelayMs = 60_000

  /// Nil in the test runner, so no test reaches GitHub or replaces a bundle.
  private let controller: UpdateController?
  private let host: Host
  private var mode: UpdateMode = .install
  private var settled = false
  private var checkArmed = false
  /// The screen-lock and display-sleep observers armed while an update
  /// waits that may install itself.
  private var applyTokens: [(NotificationCenter, NSObjectProtocol)] = []

  init(controller: UpdateController?, host: Host) {
    self.controller = controller
    self.host = host
  }

  /// Launch and every configuration load.
  func reconcile(_ mode: UpdateMode) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.mode = mode
    guard let controller else { return }
    if !settled {
      settled = true
      host.installAboutActions(
        AboutUpdateActions(
          check: { [weak self] done in self?.aboutCheckForUpdates(done) },
          install: { [weak self] done in self?.aboutInstallUpdate(done) }))
      controller.settle { [weak self] greeting in
        guard let greeting else { return }
        DispatchQueue.main.async {
          FlashLog.info("[updates] running \(greeting)")
          self?.host.alert(.message("Flash updated to \(greeting)."))
        }
      }
    }
    guard mode != .off, controller.environment.identity.checksAutomatically else {
      PollScheduler.shared.unregister(Self.checkPollID)
      checkArmed = false
      refreshApplyTriggers()
      return
    }
    if !checkArmed {
      checkArmed = true
      scheduleCheck(afterMs: Self.firstCheckDelayMs)
    }
    refreshApplyTriggers()
  }

  private func scheduleCheck(afterMs delay: Int) {
    PollScheduler.shared.scheduleOnce(
      Self.checkPollID, afterMs: delay, priority: .low, on: .main
    ) { [weak self] in
      self?.runAutomaticCheck()
    }
  }

  private func runAutomaticCheck() {
    guard let controller, checkArmed else { return }
    let mode = mode
    controller.check(mode: mode, prepare: mode == .install) { [weak self] report in
      DispatchQueue.main.async {
        guard let self, self.checkArmed else { return }
        FlashLog.info("[updates] automatic check: \(report.summary)")
        self.announce(report)
        self.refreshApplyTriggers()
        self.scheduleCheck(
          afterMs: UpdateApplyPolicy.nextCheckDelayMs(succeeded: report.succeeded))
      }
    }
  }

  /// Once per release: what an automatic check found that needs the user.
  /// A Developer ID build installing by itself only says so once it ran.
  private func announce(_ report: UpdateCheckReport) {
    guard let release = report.installable ?? availableRelease(report) else { return }
    let silent = report.identity.installability == .keepsPermissions && mode == .install
    guard !silent, controller?.markAnnounced(release.version) == true else { return }
    let message: String
    switch (report.status, report.identity.installability) {
    case (.ready, .resetsPermissions):
      message =
        "Flash \(release.version) is ready: run updates install. macOS then asks you to allow "
        + "Flash in Accessibility again."
    default:
      message = "Flash \(release.version) is available: updates install installs it."
    }
    host.alert(.message(message))
  }

  private func availableRelease(_ report: UpdateCheckReport) -> UpdateRelease? {
    if case .available(let release) = report.status { return release }
    return nil
  }

  // MARK: Commands

  func perform(
    _ command: UpdatesCommand, completion: @escaping (NormalModeCommandOutcome, String?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let controller else {
      return completion(.failed, "Updates are unavailable in this process.")
    }
    switch command {
    case .check:
      controller.check(mode: mode, prepare: false) { [weak self] report in
        DispatchQueue.main.async {
          FlashLog.info("[updates] check: \(report.summary)")
          completion(report.succeeded ? .performed : .failed, report.text)
          self?.stageInBackground(after: report)
        }
      }
    case .install:
      if case .never(let reason) = controller.environment.identity.installability {
        FlashLog.info("[updates] install_refused", fields: ["reason": reason])
        return completion(.failed, "Flash cannot update itself: \(reason).")
      }
      controller.check(mode: mode, prepare: true) { [weak self] report in
        DispatchQueue.main.async {
          guard let self else { return }
          switch report.status {
          case .failed, .upToDate:
            completion(report.succeeded ? .performed : .failed, report.text)
          case .available, .ready:
            self.installStagedUpdate(reason: "command", completion: completion)
          }
        }
      }
    }
  }

  /// A check that found a release answers at once; with `[app] updates =
  /// "install"` the download and its verification follow in the background,
  /// as the daily check's would.
  private func stageInBackground(after report: UpdateCheckReport) {
    guard case .available = report.status, mode == .install,
      let controller, controller.environment.identity.checksAutomatically
    else { return }
    controller.check(mode: .install, prepare: true) { [weak self] staged in
      DispatchQueue.main.async {
        FlashLog.info("[updates] background staging: \(staged.summary)")
        self?.refreshApplyTriggers()
      }
    }
  }

  /// Swap the staged release in and restart into it. The reply goes out
  /// first, as `resident quit`'s does.
  private func installStagedUpdate(
    reason: String, completion: ((NormalModeCommandOutcome, String?) -> Void)?
  ) {
    guard let controller else { return }
    switch controller.install() {
    case .failure(let error):
      FlashLog.error("[updates] install failed (\(reason)): \(error)")
      completion?(.failed, "Flash was not updated: \(error).")
    case .success(let release):
      var message = "Installed Flash \(release.version); Flash restarts now."
      if controller.environment.identity.installability == .resetsPermissions {
        message += " macOS asks you to allow Flash in Accessibility again."
      }
      completion?(.performed, message)
      disarmApply()
      let bundle = controller.environment.bundleURL
      DispatchQueue.main.async {
        UpdateRelaunch.relaunch(bundle) { [weak self] error in
          if let error {
            // The new version is installed; it runs from the next launch.
            FlashLog.error("[updates] relaunch failed: \(error)")
            self?.host.alert(
              .message(
                "Flash \(release.version) is installed and starts the next time Flash opens.",
                style: .warning))
            return
          }
          FlashLog.info("[updates] relaunching into \(release.version)")
          NSApp.terminate(nil)
        }
      }
    }
  }

  // MARK: Applying by itself

  /// Observe the screen locking and the displays sleeping only while an
  /// update waits that may install itself then.
  func refreshApplyTriggers() {
    guard let controller,
      UpdateApplyPolicy.appliesAutomatically(
        .quit, mode: mode, identity: controller.environment.identity,
        activity: UpdateApplyPolicy.Activity()),
      controller.stagedRelease != nil
    else { return disarmApply() }
    guard applyTokens.isEmpty else { return }
    let away: (Notification) -> Void = { [weak self] _ in self?.applyWhileAway() }
    let distributed = DistributedNotificationCenter.default()
    let workspace = NSWorkspace.shared.notificationCenter
    applyTokens = [
      (
        distributed,
        distributed.addObserver(
          forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main,
          using: away)
      ),
      (
        workspace,
        workspace.addObserver(
          forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: away)
      ),
    ]
    FlashLog.debug("[updates] apply_armed")
  }

  private func disarmApply() {
    for (center, token) in applyTokens { center.removeObserver(token) }
    applyTokens.removeAll()
  }

  private func applyWhileAway() {
    guard let controller,
      UpdateApplyPolicy.appliesAutomatically(
        .away, mode: mode, identity: controller.environment.identity,
        activity: host.activity())
    else { return }
    installStagedUpdate(reason: "away", completion: nil)
  }

  /// `applicationWillTerminate`: a quit installs a waiting update, which the
  /// next launch runs. Nothing relaunches.
  func applyAtQuit() {
    dispatchPrecondition(condition: .onQueue(.main))
    disarmApply()
    guard let controller, controller.stagedRelease != nil,
      UpdateApplyPolicy.appliesAutomatically(
        .quit, mode: mode, identity: controller.environment.identity,
        activity: host.activity())
    else { return }
    if case .failure(let error) = controller.install() {
      FlashLog.error("[updates] install at quit failed: \(error)")
    }
  }

  // MARK: About

  private func aboutCheckForUpdates(_ done: @escaping (AboutUpdateStatus) -> Void) {
    guard let controller else {
      return done(AboutUpdateStatus(message: "Updates are unavailable.", installVersion: nil))
    }
    controller.check(mode: mode, prepare: false) { [weak self] report in
      DispatchQueue.main.async {
        FlashLog.info("[updates] about check: \(report.summary)")
        done(
          AboutUpdateStatus(
            message: report.summary, installVersion: report.installable?.version))
        self?.stageInBackground(after: report)
      }
    }
  }

  private func aboutInstallUpdate(_ done: @escaping (AboutUpdateStatus) -> Void) {
    perform(.install) { outcome, message in
      done(
        AboutUpdateStatus(
          message: message.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
            ?? (outcome == .failed ? "Flash was not updated." : ""),
          installVersion: nil))
    }
  }
}
