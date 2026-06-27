import Foundation

public struct IntegrationTimingEvent: Codable, Sendable {
  public let name: String
  public let durationMs: Double?
}

public final class IntegrationTimer {
  private let startNs = DispatchTime.now().uptimeNanoseconds
  private let lock = NSLock()
  private var events: [IntegrationTimingEvent] = []

  public init() {}

  public func mark(_ name: String, detail: String? = nil) {
    append(
      IntegrationTimingEvent(
        name: name,
        durationMs: nil))
  }

  public func measure<T>(_ name: String, detail: String? = nil, _ body: () throws -> T) rethrows
    -> T
  {
    let stageStart = DispatchTime.now().uptimeNanoseconds
    defer {
      let now = DispatchTime.now().uptimeNanoseconds
      append(
        IntegrationTimingEvent(
          name: name,
          durationMs: ms(now - stageStart)))
    }
    return try body()
  }

  public var snapshot: [IntegrationTimingEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  public func writeJSON(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private func append(_ event: IntegrationTimingEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  private func ms(_ ns: UInt64) -> Double {
    (Double(ns) / 1_000_000.0 * 10).rounded() / 10
  }
}
