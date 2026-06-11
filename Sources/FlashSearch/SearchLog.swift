import Foundation

/// Sink for diagnostics emitted by FlashSearch. The module never imports
/// the app's `FlashLog`; consumers adapt their logger to this protocol so
/// FlashSearch stays self-contained and unit-testable (tests pass a no-op
/// or capturing sink).
public protocol SearchLogging: AnyObject {
  func searchLog(_ level: SearchLogLevel, _ message: String, fields: [String: String])
}

public enum SearchLogLevel: String, Sendable {
  case trace, debug, info, warn, error
}

extension SearchLogging {
  func info(_ message: String, fields: [String: String] = [:]) {
    searchLog(.info, message, fields: fields)
  }
  func warn(_ message: String, fields: [String: String] = [:]) {
    searchLog(.warn, message, fields: fields)
  }
  func error(_ message: String, fields: [String: String] = [:]) {
    searchLog(.error, message, fields: fields)
  }
  func debug(_ message: String, fields: [String: String] = [:]) {
    searchLog(.debug, message, fields: fields)
  }
}

/// Drops every log line — used as a default and by tests that don't care.
public final class SearchSilentLog: SearchLogging {
  public init() {}
  public func searchLog(_ level: SearchLogLevel, _ message: String, fields: [String: String]) {}
}
