import Foundation

/// `flash config check [--file=<path>]`: validates a config file exactly as
/// the resident loads it — the bundled defaults, then the file — without
/// contacting the resident, for editors and dotfile CI. Prints one
/// `path:line:col: message` line per diagnostic and fails on any.
enum ConfigCheck {
  struct Result: Equatable {
    var exitCode: Int32
    var lines: [String]
  }

  /// `text` nil means the file could not be read. Environment overrides are
  /// left out: they belong to a running resident, not to the file.
  static func run(fileURL: URL, text: String?, defaultLayer: ConfigLoader.Layer?) -> Result {
    guard let text else {
      return Result(exitCode: 2, lines: ["\(fileURL.path): cannot read the file"])
    }
    let lines = rows(fileURL: fileURL, text: text, defaultLayer: defaultLayer).map(\.text)
    return Result(exitCode: lines.isEmpty ? 0 : 1, lines: lines)
  }

  /// One diagnostic, placed: the file that raised it and where, when known.
  struct Row: Equatable {
    var path: String
    var line: Int?
    var column: Int?
    var message: String

    /// `path:line:col: message`, or `path: message` without a location.
    var text: String {
      guard let line, let column else { return "\(path): \(message)" }
      return "\(path):\(line):\(column): \(message)"
    }
  }

  /// What `text` raises as the file at `fileURL`, over the bundled defaults.
  /// A pure function of its arguments: any thread.
  static func rows(fileURL: URL, text: String, defaultLayer: ConfigLoader.Layer?) -> [Row] {
    let config = ConfigLoader.parseLayers(
      (defaultLayer.map { [$0] } ?? []) + [ConfigLoader.Layer(text: text, sourceURL: fileURL)],
      environment: [:])
    return rows(config.loadingDiagnostics, file: fileURL.path)
  }

  /// In file and line order; a diagnostic without a file of its own is the
  /// checked file's, and one without a location follows the located ones.
  static func rows(_ diagnostics: [ConfigDiagnostic], file: String) -> [Row] {
    let located = diagnostics.enumerated().map { index, diagnostic in
      (
        path: diagnostic.file ?? file, line: diagnostic.location?.line ?? Int.max,
        column: diagnostic.location?.column ?? 0, index: index, diagnostic: diagnostic
      )
    }
    return located.sorted {
      ($0.path, $0.line, $0.column, $0.index) < ($1.path, $1.line, $1.column, $1.index)
    }.map { entry in
      Row(
        path: entry.path, line: entry.diagnostic.location?.line,
        column: entry.diagnostic.location?.column, message: entry.diagnostic.message)
    }
  }

  static func lines(_ diagnostics: [ConfigDiagnostic], file: String) -> [String] {
    rows(diagnostics, file: file).map(\.text)
  }
}
