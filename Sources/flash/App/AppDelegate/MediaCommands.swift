import AppKit
import FlashCore

/// The audio and keep-awake commands: `MediaController` and
/// `CaffeinateController` do the work off the main thread; this shows the
/// result.
extension AppDelegate {
  /// `volume up`, `volume down`, `volume mute`, `audio input`,
  /// `audio output`, `media status`. A volume step shows the percent alert
  /// wherever it ran; a list, a selection and what is playing are a banner
  /// when `presents`, and otherwise `completion`'s output, which its caller
  /// presents (the CLI prints it, the command line shows it).
  func performMediaCommand(
    _ command: MediaCommand, repeatCount: Int = 1, presents: Bool = true,
    completion: ((NormalModeCommandOutcome, String?) -> Void)? = nil
  ) {
    mediaController.perform(command, repeatCount: normalizedRepeatCount(repeatCount)) {
      [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .volume(let percent): self.overlay.displayAlert(.volume(percent))
      case .message(let text): if presents { self.overlay.displayBanner(text) }
      case .done: break
      case .failed(let reason): self.displayCommandFailure(command.name, reason: reason)
      }
      if case .failed = outcome {
        completion?(.failed, outcome.output)
      } else {
        completion?(.performed, outcome.output)
      }
    }
  }

  /// `caffeinate on`, `caffeinate off`, `caffeinate toggle`,
  /// `caffeinate status`: each answers with the `caffeinate on|off` alert,
  /// `status` only when `presents`; `completion` gets the state as output.
  func performCaffeinate(
    _ request: CaffeinateRequest, presents: Bool = true,
    completion: ((NormalModeCommandOutcome, String?) -> Void)? = nil
  ) {
    caffeinate.perform(request) { [weak self] result in
      switch result {
      case .success(let on):
        if presents || request.showsWherever { self?.overlay.displayAlert(.caffeinate(on: on)) }
        completion?(.performed, request.output(on: on))
      case .failure(let error):
        self?.displayCommandFailure(request.name, reason: error.localizedDescription)
        completion?(.failed, error.localizedDescription)
      }
    }
  }

  /// The controller, made on first use so a resident that never keeps the
  /// Mac awake never arms its expiry.
  private var caffeinate: CaffeinateController {
    if let caffeinateController { return caffeinateController }
    let controller = CaffeinateController { [weak self] on in
      self?.statusBarController?.updateCaffeinate(on)
    }
    caffeinateController = controller
    return controller
  }

  /// A core command that did not run, with why: logged, and shown in the
  /// centred alert.
  func displayCommandFailure(_ name: CommandName, reason: String) {
    FlashLog.warn(
      "[command] failed", fields: ["command": "\(name)", "reason": reason], source: "core:Command")
    overlay.displayAlert(.message(reason, style: .error))
  }
}
