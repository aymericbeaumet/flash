import Foundation

/// Detects main-thread starvation. The keyboard capture tap, every AX
/// observer source, and all mode logic share the main run loop — when it
/// stalls, keystrokes stall system-wide (and past the OS time budget the
/// session tap gets disabled outright). Stalls were previously invisible:
/// Flash's logging is event-driven, so a blocked main thread simply logs
/// nothing and the episode leaves no trace to diagnose after the fact.
///
/// A background timer pings main every `pingIntervalMs`; the pong measures
/// the round-trip. Anything over `stallThresholdMs` is logged with its
/// duration, turning "the keyboard felt dead for a moment" into a grep-able
/// line with a timestamp. `DispatchTime` is uptime-based (does not advance
/// during system sleep), so sleep/wake cannot fake a stall.
final class MainThreadWatchdog {
  static let pingIntervalMs = 250
  static let stallThresholdMs = 300.0

  private let queue = DispatchQueue(label: "flash.main_thread_watchdog", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var awaitingPong = false
  private var pingSentAt = DispatchTime.now()

  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(Self.pingIntervalMs),
      repeating: .milliseconds(Self.pingIntervalMs),
      leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.ping() }
    self.timer = timer
    timer.resume()
  }

  private func ping() {
    // Main hasn't answered the previous ping — it's mid-stall. Let that
    // ping's pong measure the full blockage instead of stacking pings, so
    // one contiguous stall produces one line with its total duration.
    guard !awaitingPong else { return }
    awaitingPong = true
    pingSentAt = DispatchTime.now()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.queue.async {
        let ms =
          Double(DispatchTime.now().uptimeNanoseconds - self.pingSentAt.uptimeNanoseconds)
          / 1_000_000
        self.awaitingPong = false
        if ms >= Self.stallThresholdMs {
          FlashLog.warn(String(format: "[watchdog] main_thread_stall ms=%.0f", ms))
        }
      }
    }
  }
}
