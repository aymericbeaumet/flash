import Foundation

/// Pure word segmentation for `mouse_target --words`: where the words of a
/// string sit, in UTF-16 indexes so a range can be handed to
/// `kAXBoundsForRangeParameterizedAttribute` and sliced from an `NSString`.
public enum WordMatcher {
  /// Every run of letters, digits, underscores and combining marks. A
  /// surrogate pair stays inside the word it belongs to. Punctuation and
  /// whitespace separate words and are never part of one.
  public static func words(in text: String) -> [BigramOccurrence] {
    let haystack = text as NSString
    let length = haystack.length
    var found: [BigramOccurrence] = []
    var index = 0
    var start: Int?
    while index < length {
      let unit = haystack.character(at: index)
      let step: Int
      let partOfWord: Bool
      if UTF16.isLeadSurrogate(unit), index + 1 < length,
        UTF16.isTrailSurrogate(haystack.character(at: index + 1))
      {
        step = 2
        let scalar = UTF16.decode(
          UTF16.EncodedScalar([unit, haystack.character(at: index + 1)]))
        partOfWord = isWordScalar(scalar)
      } else {
        step = 1
        partOfWord = Unicode.Scalar(unit).map(isWordScalar) ?? false
      }
      if partOfWord {
        if start == nil { start = index }
      } else if let begun = start {
        found.append(BigramOccurrence(location: begun, length: index - begun))
        start = nil
      }
      index += step
    }
    if let begun = start {
      found.append(BigramOccurrence(location: begun, length: length - begun))
    }
    return found
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
      || CharacterSet.nonBaseCharacters.contains(scalar)
  }

  /// Where the pointer lands on a word: just inside its leading edge, on the
  /// word's midline, so a click places the caret at the word boundary and a
  /// selection started there takes the whole word.
  public static func clickPoint(in frame: CGRect) -> CGPoint {
    CGPoint(x: frame.minX + min(1, frame.width / 2), y: frame.midY)
  }

  /// Where each word sits inside `lines`, as `BigramMatcher.glyphRects` does
  /// for a letter, from the same measured line boxes.
  public static func wordRects(
    in text: String, lines: [BigramMatcher.BigramLineBox], advances: GlyphAdvances? = nil
  ) -> [(occurrence: BigramOccurrence, rect: CGRect)] {
    let haystack = text as NSString
    var placed: [(occurrence: BigramOccurrence, rect: CGRect)] = []
    for line in lines {
      guard line.length > 0, line.location >= 0, line.location + line.length <= haystack.length
      else { continue }
      let slice = haystack.substring(
        with: NSRange(location: line.location, length: line.length))
      let columns = BigramMatcher.columns(of: slice)
      guard columns > 0 else { continue }
      let measured = BigramMatcher.measuredLine(slice, columns: columns, advances: advances)
      for word in words(in: slice) {
        guard
          let rect = BigramMatcher.rangeRect(
            frame: line.bounds, location: word.location, length: word.length, columns: columns,
            measured: measured)
        else { continue }
        placed.append(
          (
            occurrence: BigramOccurrence(
              location: line.location + word.location, length: word.length),
            rect: rect
          ))
      }
    }
    return placed
  }
}
