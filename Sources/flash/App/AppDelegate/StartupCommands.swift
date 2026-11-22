import FlashCore
import Foundation

/// `[startup] run`: once at launch, after the configuration loaded, and on
/// `startup run`. The commands run through the monitors' executor (a Flash
/// command in process, an executable in its own process group with its
/// output kept and its timeout), sequenced by `StartupRunner` off main.
extension AppDelegate {
  /// The runner, waiting for the login environment so commands see the
  /// user's PATH. Each command: a Flash command on main, as a mapping runs
  /// it; an executable through `MonitorProcess`, spawned from the startup
  /// queue so an exec that stalls never holds main.
  func makeStartupRunner() -> StartupRunner {
    StartupRunner(
      whenReady: { queue, body in FlashProcessEnvironment.shared.whenResolved(on: queue, body) },
      execute: { [weak self] step, timeout, completion in
        switch step {
        case .flashCommand:
          DispatchQueue.main.async {
            guard let self else { return completion(.cancelled("Flash quit"), "") }
            _ = self.performMonitorStep(
              step, environment: [:], timeout: timeout, completion: completion)
          }
        case .shellCommand(let argv):
          MonitorProcess.run(
            argv, environment: FlashProcessEnvironment.shared.environment, timeout: timeout,
            completion: completion)
        }
      })
  }

  /// The launch's run, after the first configuration load. Failures go to
  /// the log; nothing is shown.
  func runStartupCommandsAtLaunch() {
    startupRunner.runAtLaunch(config.startup)
  }

  /// `startup run`: the list as the configuration holds it now; `completion`
  /// runs on main with each command's outcome.
  func performStartupCommand(
    _ command: StartupCommand, completion: @escaping (NormalModeCommandOutcome, String) -> Void
  ) {
    switch command {
    case .run:
      startupRunner.run(config.startup) { report in
        DispatchQueue.main.async {
          completion(report.succeeded ? .performed : .failed, report.text)
        }
      }
    }
  }
}
