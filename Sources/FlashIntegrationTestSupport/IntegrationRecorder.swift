import Foundation

/// Recorder protocol shared by GUI integration runners.
public protocol FlashIntegrationRecorder: AnyObject {
  func pass(_ message: String)
  func fail(_ message: String)
}

/// Thread-safe failure accumulator for command-line integration runners.
public final class IntegrationFailureStore {
  private let lock = NSLock()
  private var messages: [String] = []

  public init() {}

  public func append(_ message: String) {
    lock.lock()
    messages.append(message)
    lock.unlock()
  }

  public var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return messages
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return messages.count
  }
}

public final class ConsoleIntegrationRecorder: FlashIntegrationRecorder {
  private let outputLock = NSLock()
  public let failures = IntegrationFailureStore()
  private let useColour: Bool

  public init(useColour: Bool = true) {
    self.useColour = useColour
  }

  public func pass(_ message: String) {
    write("\(green("PASS")) \(message)", to: .standardOutput)
  }

  public func fail(_ message: String) {
    failures.append(message)
    write("\(red("FAIL")) \(message)", to: .standardError)
  }

  public func info(_ message: String) {
    write(message, to: .standardOutput)
  }

  private func write(_ message: String, to handle: FileHandle) {
    outputLock.lock()
    defer { outputLock.unlock() }
    if let data = (message + "\n").data(using: .utf8) {
      handle.write(data)
    }
  }

  private func red(_ text: String) -> String {
    guard useColour else { return text }
    return "\u{1B}[31m\(text)\u{1B}[0m"
  }

  private func green(_ text: String) -> String {
    guard useColour else { return text }
    return "\u{1B}[32m\(text)\u{1B}[0m"
  }
}
