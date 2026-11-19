import AppKit
import FlashCore

/// The keep-awake commands: `CaffeinateController` does the work off the
/// main thread; this shows the result.
extension AppDelegate {
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
