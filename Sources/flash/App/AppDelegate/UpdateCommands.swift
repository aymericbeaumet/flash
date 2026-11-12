import AppKit

/// `[app] updates`, the `updates` commands and the About window's button,
/// over one `UpdateController`. Automatic checks ride `PollScheduler`
/// (`core:updates`, priority `low`), armed only for a build a release can
/// replace and while `[app] updates` is not `off`. A downloaded update a
/// Developer ID build may install on its own waits for a moment nobody is
/// working (the screen locks or the displays sleep, idle) or for quit;
/// those observers exist only while such an update waits.
extension AppDelegate {
  static let updateCheckPollID = "core:updates"
  /// The first automatic check waits for the resident to settle.
  static let updateFirstCheckDelayMs = 60_000

  /// Launch and every configuration load.
  func reconcileUpdates(_ mode: UpdateMode) {
    updateMode = mode
    guard let controller = updates else { return }
    if !updatesSettled {
      updatesSettled = true
      statusItemController.updateActions = AboutUpdateActions(
        check: { [weak self] done in self?.aboutCheckForUpdates(done) },
        install: { [weak self] done in self?.aboutInstallUpdate(done) })
      controller.settle { [weak self] greeting in
        guard let greeting else { return }
        DispatchQueue.main.async {
          FlashLog.info("[updates] running \(greeting)")
          self?.overlay.displayAlert(.message("Flash updated to \(greeting)."))
        }
      }
    }
    guard mode != .off, controller.environment.identity.checksAutomatically else {
      PollScheduler.shared.unregister(Self.updateCheckPollID)
      updateCheckArmed = false
      refreshUpdateApplyTriggers()
      return
    }
    if !updateCheckArmed {
      updateCheckArmed = true
      scheduleUpdateCheck(afterMs: Self.updateFirstCheckDelayMs)
    }
    refreshUpdateApplyTriggers()
  }

  private func scheduleUpdateCheck(afterMs delay: Int) {
    PollScheduler.shared.scheduleOnce(
      Self.updateCheckPollID, afterMs: delay, priority: .low, on: .main
    ) { [weak self] in
      self?.runAutomaticUpdateCheck()
    }
  }

  private func runAutomaticUpdateCheck() {
    guard let controller = updates, updateCheckArmed else { return }
    let mode = updateMode
    controller.check(mode: mode, prepare: mode == .install) { [weak self] report in
      DispatchQueue.main.async {
        guard let self, self.updateCheckArmed else { return }
        FlashLog.info("[updates] automatic check: \(report.summary)")
        self.announce(report)
        self.refreshUpdateApplyTriggers()
        self.scheduleUpdateCheck(
          afterMs: UpdateApplyPolicy.nextCheckDelayMs(succeeded: report.succeeded))
      }
    }
  }

  /// Once per release: what an automatic check found that needs the user.
  /// A Developer ID build installing by itself only says so once it ran.
  private func announce(_ report: UpdateCheckReport) {
    guard let release = report.installable ?? availableRelease(report) else { return }
    let silent = report.identity.installability == .keepsPermissions && updateMode == .install
    guard !silent, updates?.markAnnounced(release.version) == true else { return }
    let message: String
    switch (report.status, report.identity.installability) {
    case (.ready, .resetsPermissions):
      message =
        "Flash \(release.version) is ready: run updates install. macOS then asks you to allow "
        + "Flash in Accessibility again."
    default:
      message = "Flash \(release.version) is available: updates install installs it."
    }
    overlay.displayAlert(.message(message))
  }

  private func availableRelease(_ report: UpdateCheckReport) -> UpdateRelease? {
    if case .available(let release) = report.status { return release }
    return nil
  }

  // MARK: Commands

  func performUpdatesCommand(
    _ command: UpdatesCommand, completion: @escaping (NormalModeCommandOutcome, String?) -> Void
  ) {
    guard let controller = updates else {
      return completion(.failed, "Updates are unavailable in this process.")
    }
    switch command {
    case .check:
      controller.check(mode: updateMode, prepare: false) { [weak self] report in
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
      controller.check(mode: updateMode, prepare: true) { [weak self] report in
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
    guard case .available = report.status, updateMode == .install,
      let controller = updates, controller.environment.identity.checksAutomatically
    else { return }
    controller.check(mode: .install, prepare: true) { [weak self] staged in
      DispatchQueue.main.async {
        FlashLog.info("[updates] background staging: \(staged.summary)")
        self?.refreshUpdateApplyTriggers()
      }
    }
  }

  /// Swap the staged release in and restart into it. The reply goes out
  /// first, as `resident quit`'s does.
  private func installStagedUpdate(
    reason: String, completion: ((NormalModeCommandOutcome, String?) -> Void)?
  ) {
    guard let controller = updates else { return }
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
      disarmUpdateApply()
      let bundle = controller.environment.bundleURL
      DispatchQueue.main.async {
        UpdateRelaunch.relaunch(bundle) { [weak self] error in
          if let error {
            // The new version is installed; it runs from the next launch.
            FlashLog.error("[updates] relaunch failed: \(error)")
            self?.overlay.displayAlert(
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

  private var updateActivity: UpdateApplyPolicy.Activity {
    var activity = UpdateApplyPolicy.Activity()
    activity.hintSession = hintSession.isActive
    activity.popup = overlay.statusPopupController.presentation.name != nil
    if case .command = modeStore.mode { activity.commandLine = true }
    activity.holdingButton = modeStore.mode.isHold
    return activity
  }

  /// Observe the screen locking and the displays sleeping only while an
  /// update waits that may install itself then.
  func refreshUpdateApplyTriggers() {
    guard let controller = updates,
      UpdateApplyPolicy.appliesAutomatically(
        .quit, mode: updateMode, identity: controller.environment.identity,
        activity: UpdateApplyPolicy.Activity()),
      controller.stagedRelease != nil
    else { return disarmUpdateApply() }
    guard updateApplyTokens.isEmpty else { return }
    let away: (Notification) -> Void = { [weak self] _ in self?.applyUpdateWhileAway() }
    let distributed = DistributedNotificationCenter.default()
    let workspace = NSWorkspace.shared.notificationCenter
    updateApplyTokens = [
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

  private func disarmUpdateApply() {
    for (center, token) in updateApplyTokens { center.removeObserver(token) }
    updateApplyTokens.removeAll()
  }

  private func applyUpdateWhileAway() {
    guard let controller = updates,
      UpdateApplyPolicy.appliesAutomatically(
        .away, mode: updateMode, identity: controller.environment.identity,
        activity: updateActivity)
    else { return }
    installStagedUpdate(reason: "away", completion: nil)
  }

  /// `applicationWillTerminate`: a quit installs a waiting update, which the
  /// next launch runs. Nothing relaunches.
  func applyUpdateAtQuit() {
    disarmUpdateApply()
    guard let controller = updates, controller.stagedRelease != nil,
      UpdateApplyPolicy.appliesAutomatically(
        .quit, mode: updateMode, identity: controller.environment.identity,
        activity: updateActivity)
    else { return }
    if case .failure(let error) = controller.install() {
      FlashLog.error("[updates] install at quit failed: \(error)")
    }
  }

  // MARK: About

  private func aboutCheckForUpdates(_ done: @escaping (AboutUpdateStatus) -> Void) {
    guard let controller = updates else {
      return done(AboutUpdateStatus(message: "Updates are unavailable.", installVersion: nil))
    }
    controller.check(mode: updateMode, prepare: false) { [weak self] report in
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
    performUpdatesCommand(.install) { outcome, message in
      done(
        AboutUpdateStatus(
          message: message.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
            ?? (outcome == .failed ? "Flash was not updated." : ""),
          installVersion: nil))
    }
  }
}
