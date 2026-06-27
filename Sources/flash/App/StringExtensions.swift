import Foundation

extension String {
  /// Shortcut for `trimmingCharacters(in: .whitespacesAndNewlines)`. The verbose
  /// form shows up dozens of times across the app target; this shortcut keeps
  /// call sites readable without pulling the helper into the public SDK
  /// (`FlashCore`) where it would pollute the SPI.
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
