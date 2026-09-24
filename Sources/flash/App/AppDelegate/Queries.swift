import AppKit
import Carbon.HIToolbox
import FlashCore

/// The resident's answers to `flash status` and `flash doctor`, and `:doctor`.
extension AppDelegate {
  func statusReport() -> FlashStatusReport {
    let info = Bundle.main.infoDictionary ?? [:]
    let secure = IsSecureEventInputEnabled()
    noteSecureInput(secure)
    let sessionRunning = hintSession.isActive || activationInFlight
    return FlashStatusReport(
      version: info["CFBundleShortVersionString"] as? String ?? "unknown",
      build: info["CFBundleVersion"] as? String ?? "unknown",
      mode: FlashStatusReport.modeName(modeStore.mode),
      hintSession: FlashStatusReport.hintSessionPhase(
        route: hintSession.keyRoute, active: hintSession.isActive,
        discovering: activationInFlight),
      focusedApp: lastFocusedApplicationPID.flatMap {
        NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
      },
      accessibility: PermissionCheck.isAccessibilityTrusted,
      capture: FlashStatusReport.capture(
        tapInstalled: keyboardCaptureTap != nil, secureInputEnabled: secure,
        session: sessionRunning ? hintSession.capture : nil),
      secureInput: secure,
      inputSource: keyboardLayoutMonitor.state.inputSourceID,
      keyboardLayout: config.app.keyboardLayout,
      referenceLayout: keyboardLayoutMonitor.state.reference.table?.sourceID,
      configPath: ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment).path,
      configDiagnostics: config.loadingDiagnostics.count,
      plugins: FlashStatusReport.PluginCounts(pluginManager.statusBarInfos()),
      statusBar: statusBarVisible,
      autostart: config.app.autostart)
  }

  /// Gather the doctor's inputs — the main-thread state here, the slow
  /// probes (IORegistry, code signature, plugin sandbox compiles) on a
  /// background queue — and complete on the main thread.
  func runDoctor(completion: @escaping (Doctor.Report) -> Void) {
    let configPath = ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment)
      .path
    let secure = IsSecureEventInputEnabled()
    noteSecureInput(secure)
    let reference = keyboardLayoutMonitor.state.reference
    let base = Doctor.Inputs(
      accessibilityTrusted: PermissionCheck.isAccessibilityTrusted,
      tapInstalled: keyboardCaptureTap != nil,
      secureInputEnabled: secure,
      signature: .unknown,
      otherResidents: DoctorProbe.otherResidents(),
      configPath: configPath,
      configDiagnostics: ConfigCheck.lines(config.loadingDiagnostics, file: configPath),
      refusedHotkeys: mappings.refusedHotkeys,
      hintKeys: config.resolvedAlphabet.chars,
      gridKeys: Array(config.resolvedMouseGridKeys.joined()),
      readLayout: reference.table ?? InputSources.currentLayout(),
      missingKeyboardLayout: reference.missingSourceID)
    let statuses = pluginManager.pluginStatuses()
    let screenshotEnabled = pluginManager.statusBarInfos().contains { $0.id == "screenshot" }
    let bundleURL = Bundle.main.bundleURL
    DispatchQueue.global(qos: .userInitiated).async {
      var inputs = base
      if secure { inputs.secureInputHolders = DoctorProbe.secureInputHolders() }
      inputs.signature = DoctorProbe.signature(bundleURL: bundleURL)
      inputs.plugins = PluginDoctor.run(statuses: statuses)
      // Only asks whether the grant exists; Flash itself never captures.
      if screenshotEnabled { inputs.screenRecordingGranted = CGPreflightScreenCaptureAccess() }
      let report = Doctor.run(inputs)
      DispatchQueue.main.async { completion(report) }
    }
  }

  /// `:doctor`: the full report goes to the log, a summary to a banner.
  func runDoctorCommand() {
    runDoctor { [weak self] report in
      for line in report.lines {
        FlashLog.info("[doctor] \(line)")
      }
      let summary =
        report.issues == 0
        ? "doctor: no issues" + (report.warnings == 0 ? "" : ", \(report.warnings) warning(s)")
        : "doctor: \(report.issues) issue(s) — run flash doctor for details"
      self?.overlay.displayBanner(summary, durationMs: 4000)
    }
  }
}
