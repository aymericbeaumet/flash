/// `[mode] scroll_smooth_ms`: a vertical line scroll split into smaller
/// line-unit wheel events spread over the duration, so content glides instead
/// of jumping. Line units keep it safe in terminals, which turn each event
/// into wheel reports and refuse pixel streams; the steps add up to exactly
/// the configured lines. `ActionDispatcher.postWheelSteps` posts them, and a
/// newer scroll drops whatever an older one has left.
enum SmoothScroll {
  struct Step: Equatable {
    /// Milliseconds after the keypress.
    let delayMs: Int
    let lines: Int32
  }

  /// The longest spread `scroll_smooth_ms` accepts.
  static let maxDurationMs = 300
  /// One frame at 60 Hz: closer events add wheel reports without adding
  /// smoothness.
  static let minStepIntervalMs = 16

  /// The events one scroll of `lines` becomes. The first moves on the
  /// keypress; the rest follow at least a frame apart, carrying the larger
  /// shares first so the content decelerates. A single line, or no
  /// duration, is one event.
  static func steps(lines: Int32, durationMs: Int) -> [Step] {
    let duration = min(max(durationMs, 0), maxDurationMs)
    let magnitude = Int(lines.magnitude)
    guard duration > 0, magnitude > 1 else { return [Step(delayMs: 0, lines: lines)] }
    let count = min(magnitude, max(2, duration / minStepIntervalMs))
    let share = magnitude / count
    let remainder = magnitude % count
    let sign: Int32 = lines < 0 ? -1 : 1
    return (0..<count).map { index in
      Step(
        delayMs: duration * index / count,
        lines: sign * Int32(share + (index < remainder ? 1 : 0)))
    }
  }
}
