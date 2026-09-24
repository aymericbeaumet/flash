import Darwin

enum StatusFormatNumber {
  // Match tmux's strtonum: leading C whitespace and a sign are permitted,
  // but trailing whitespace, partial numbers, and overflow are rejected.
  static func integer(_ raw: String) -> Int? {
    guard !raw.utf8.contains(0) else { return nil }
    return raw.withCString { start in
      var end: UnsafeMutablePointer<CChar>?
      let savedError = errno
      errno = 0
      defer { errno = savedError }
      let value = strtoll(start, &end, 10)
      guard let end, end != start, end.pointee == 0, errno != ERANGE else { return nil }
      return Int(exactly: value)
    }
  }

  static func unsigned(_ raw: String) -> UInt32? {
    guard let value = integer(raw) else { return nil }
    return UInt32(exactly: value)
  }
}
