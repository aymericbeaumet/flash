import CFlashTerminal
import Foundation

public enum TerminalText {
  /// Printable ASCII is one cell per byte without a trip through libghostty's
  /// grapheme segmentation; the pager measures every character of its text.
  public static func cellWidth(of text: String) -> Int {
    if text.utf8.allSatisfy({ (0x20..<0x7F).contains($0) }) { return text.utf8.count }
    let codepoints = text.unicodeScalars.map(\.value)
    return codepoints.withUnsafeBufferPointer { Int(flash_unicode_width($0.baseAddress, $0.count)) }
  }

  /// Literal content cannot inject terminal commands; LF and TAB retain their meaning.
  public static func sanitize(text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.map { scalar in
          if scalar == "\n" || scalar == "\t" { return scalar }
          if scalar.value < 32 || (127...159).contains(scalar.value) { return "�" }
          return scalar
        })
    )
  }
}
