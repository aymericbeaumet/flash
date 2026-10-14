import CoreGraphics
import CoreText
import Foundation

/// The face an app reports for a run of text (`AXFont`): its name and size.
public struct TextFont: Equatable {
  public let name: String
  public let size: CGFloat

  public init(name: String, size: CGFloat) {
    self.name = name
    self.size = size
  }
}

/// Where characters sit along one line, from the face that draws it. A letter
/// search places a glyph at its share of the line's advance instead of its
/// share of the character count, which drifts on proportional faces: nine
/// `i`s before a `W` are far narrower than nine tenths of the line.
///
/// Only a face this Mac can load measures. CoreText substitutes another face
/// for an unknown name, whose advances would be no better than the count, so
/// such a run keeps the count.
public struct GlyphAdvances {
  let font: CTFont

  public init?(_ reported: TextFont) {
    guard reported.size > 0, reported.size.isFinite, !reported.name.isEmpty else { return nil }
    if reported.name.hasPrefix(".") {
      // The system UI face is reported under a private name that
      // `CTFontCreateWithName` refuses; the UI font is that face.
      guard let system = CTFontCreateUIFontForLanguage(.system, reported.size, nil) else {
        return nil
      }
      let bold = reported.name.range(of: "bold", options: .caseInsensitive) != nil
      font =
        bold
        ? CTFontCreateCopyWithSymbolicTraits(system, 0, nil, .traitBold, .traitBold) ?? system
        : system
      return
    }
    let created = CTFontCreateWithName(reported.name as CFString, reported.size, nil)
    let names = [kCTFontPostScriptNameKey, kCTFontFullNameKey, kCTFontFamilyNameKey]
      .compactMap { CTFontCopyName(created, $0) as String? }
    guard names.contains(where: { $0.caseInsensitiveCompare(reported.name) == .orderedSame })
    else { return nil }
    font = created
  }

  /// One line laid out once, for every match on it.
  public struct Line {
    let line: CTLine
    let width: CGFloat

    /// The start and end of a UTF-16 range as fractions of the line's width.
    public func span(location: Int, length: Int) -> (start: CGFloat, end: CGFloat) {
      let start = CTLineGetOffsetForStringIndex(line, location, nil)
      let end = CTLineGetOffsetForStringIndex(line, location + length, nil)
      return (min(max(start / width, 0), 1), min(max(end / width, 0), 1))
    }
  }

  /// `text` laid out on one line; nil when it draws nothing.
  public func line(_ text: String) -> Line? {
    let attributed = NSAttributedString(
      string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    guard width > 0, width.isFinite else { return nil }
    return Line(line: line, width: width)
  }
}
