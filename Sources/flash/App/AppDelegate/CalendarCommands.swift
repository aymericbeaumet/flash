import AppKit

/// `calendar join` and `calendar next`. `CalendarEvents` reads the calendar
/// off main; this shows the result.
extension AppDelegate {
  /// `completion` gets how the command ended and its one line of output, for
  /// a caller that presents it (the CLI prints it, the command line shows
  /// it). With `presents`, Flash shows `calendar next` itself, in the
  /// centred alert. Failures always show here, as every command's do.
  func performCalendarCommand(
    _ command: CalendarCommand, presents: Bool,
    completion: @escaping (NormalModeCommandOutcome, String?) -> Void
  ) {
    calendarEvents.perform(command) { [weak self] outcome in
      guard let self else { return completion(.failed, nil) }
      switch outcome {
      case .next(let title, let detail):
        if presents { self.overlay.displayAlert(StatusAlert(title: title, value: detail)) }
        completion(.performed, "\(title) \(detail)")
      case .joined(let title, _):
        completion(.performed, "Joining \(title)")
      case .noEvent(let message):
        // Nothing next is an answer, not an error.
        self.overlay.displayAlert(.message(message))
        completion(.failed, message)
      case .failed(let message, let log):
        // The log never names the event.
        FlashLog.warn(
          "[calendar] failed", fields: ["command": "\(command.name)", "reason": log],
          source: "core:Command")
        self.overlay.displayAlert(.message(message, style: .error))
        completion(.failed, message)
      }
    }
  }
}
