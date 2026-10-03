import Foundation

/// `flash config_check [--file=<path>]`: validates a config file exactly as
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
    let config = ConfigLoader.parseLayers(
      (defaultLayer.map { [$0] } ?? []) + [ConfigLoader.Layer(text: text, sourceURL: fileURL)],
      environment: [:])
    let lines = self.lines(config.loadingDiagnostics, file: fileURL.path)
    return Result(exitCode: lines.isEmpty ? 0 : 1, lines: lines)
  }

  /// In file and line order; a diagnostic without a file of its own is the
  /// checked file's, and one without a location follows the located ones.
  static func lines(_ diagnostics: [ConfigDiagnostic], file: String) -> [String] {
    let located = diagnostics.enumerated().map { index, diagnostic in
      (
        path: diagnostic.file ?? file, line: diagnostic.location?.line ?? Int.max,
        column: diagnostic.location?.column ?? 0, index: index, diagnostic: diagnostic
      )
    }
    return located.sorted {
      ($0.path, $0.line, $0.column, $0.index) < ($1.path, $1.line, $1.column, $1.index)
    }.map { entry in
      guard let location = entry.diagnostic.location else {
        return "\(entry.path): \(entry.diagnostic.message)"
      }
      return "\(entry.path):\(location.line):\(location.column): \(entry.diagnostic.message)"
    }
  }
}
