import Foundation

/// Reads every URL string Flash did not build itself, the same way on each
/// supported macOS. From macOS 14 `URL(string:)` and `URLComponents(string:)`
/// parse RFC 3986 and repair a string a URL cannot hold: a component with an
/// invalid character is percent-encoded whole, and a non-ASCII host is
/// IDNA-encoded (`https://日本.jp/a b` reads as `https://xn--wgv71a.jp/a%20b`).
/// macOS 13 returns nil for such a string, so there `repaired` applies the
/// same rules first.
public enum URLParsing {
  public static func url(_ string: String) -> URL? {
    if #available(macOS 14.0, *) { return URL(string: string) }
    return URL(string: string)
      ?? repaired(string, allowingEmptyScheme: true).flatMap { URL(string: $0) }
  }

  public static func components(_ string: String) -> URLComponents? {
    if #available(macOS 14.0, *) { return URLComponents(string: string) }
    return URLComponents(string: string)
      ?? repaired(string, allowingEmptyScheme: false).flatMap { URLComponents(string: $0) }
  }

  /// `string` as macOS 14 rewrites it before parsing, or nil where it gives
  /// up: an invalid scheme, a port that is not digits, a host IDNA rejects.
  /// Unchanged when every component is already valid. `URL` reads a leading
  /// `:` as an empty scheme, `URLComponents` as part of a relative path.
  static func repaired(_ string: String, allowingEmptyScheme: Bool) -> String? {
    let bytes = Array(string.utf8)
    var index = 0
    var scheme: ArraySlice<UInt8>?
    if let end = bytes.firstIndex(where: { ByteSet.schemeEnd.contains($0) }),
      bytes[end] == UInt8(ascii: ":"), end > 0 || allowingEmptyScheme
    {
      let candidate = bytes[..<end]
      guard candidate.isEmpty || ByteSet.alpha.contains(candidate[0]),
        candidate.allSatisfy(ByteSet.scheme.contains)
      else { return nil }
      scheme = candidate
      index = end + 1
    }
    let schemeName = scheme.map { String(decoding: $0, as: UTF8.self).lowercased() }

    var authority: Authority?
    if bytes[index...].starts(with: [UInt8(ascii: "/"), UInt8(ascii: "/")]) {
      let start = index + 2
      let end = bytes[start...].firstIndex(where: ByteSet.authorityEnd.contains) ?? bytes.count
      guard let parsed = Authority(bytes[start..<end], scheme: schemeName) else { return nil }
      authority = parsed
      index = end
    }

    let pathEnd = bytes[index...].firstIndex(where: ByteSet.pathEnd.contains) ?? bytes.count
    let path = bytes[index..<pathEnd]
    index = pathEnd
    var query: ArraySlice<UInt8>?
    if index < bytes.count, bytes[index] == UInt8(ascii: "?") {
      let end = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "#")) ?? bytes.count
      query = bytes[(index + 1)..<end]
      index = end
    }
    let fragment = index < bytes.count ? bytes[(index + 1)...] : nil

    let pathValid = valid(path, .path)
    let queryValid = query.map { valid($0, .query) } ?? true
    let fragmentValid = fragment.map { valid($0, .query) } ?? true
    if authority?.valid ?? true, pathValid, queryValid, fragmentValid { return string }

    var output: [UInt8] = []
    if let scheme { output += scheme + [UInt8(ascii: ":")] }
    if let authority {
      guard let rebuilt = authority.rebuilt() else { return nil }
      output += [UInt8(ascii: "/"), UInt8(ascii: "/")] + rebuilt
    }
    output += pathValid ? Array(path) : encodedPath(path)
    if let query {
      output += [UInt8(ascii: "?")] + (queryValid ? Array(query) : encoded(query, .query))
    }
    if let fragment {
      output += [UInt8(ascii: "#")] + (fragmentValid ? Array(fragment) : encoded(fragment, .query))
    }
    return String(decoding: output, as: UTF8.self)
  }

  /// `user:password@host:port`, split as RFC 3986 reads it: the userinfo
  /// ends at the last `@`, an IP literal at its `]`.
  private struct Authority {
    var user: ArraySlice<UInt8>?
    var password: ArraySlice<UInt8>?
    var host: ArraySlice<UInt8>
    var port: ArraySlice<UInt8>?
    var scheme: String?

    init?(_ bytes: ArraySlice<UInt8>, scheme: String?) {
      self.scheme = scheme
      var hostStart = bytes.startIndex
      if let at = bytes.lastIndex(of: UInt8(ascii: "@")) {
        let info = bytes[..<at]
        if let colon = info.firstIndex(of: UInt8(ascii: ":")) {
          user = info[..<colon]
          password = info[(colon + 1)...]
        } else {
          user = info
        }
        hostStart = at + 1
      }
      let hostAndPort = bytes[hostStart...]
      if hostAndPort.first == UInt8(ascii: "["),
        let close = hostAndPort.firstIndex(of: UInt8(ascii: "]"))
      {
        host = hostAndPort[...close]
        let rest = hostAndPort[(close + 1)...]
        if let first = rest.first {
          guard first == UInt8(ascii: ":") else { return nil }
          port = rest.dropFirst()
        }
      } else if let colon = hostAndPort.firstIndex(of: UInt8(ascii: ":")) {
        host = hostAndPort[..<colon]
        port = hostAndPort[(colon + 1)...]
      } else {
        host = hostAndPort
      }
      guard port?.allSatisfy(ByteSet.digit.contains) ?? true || scheme == "addressbook" else {
        return nil
      }
    }

    var isIPLiteral: Bool { host.first == UInt8(ascii: "[") && host.last == UInt8(ascii: "]") }

    var hostValid: Bool {
      guard isIPLiteral else { return URLParsing.valid(host, .host) }
      return host.dropFirst().dropLast().allSatisfy(ByteSet.ipLiteral.contains)
    }

    var valid: Bool {
      (user.map { URLParsing.valid($0, .user) } ?? true)
        && (password.map { URLParsing.valid($0, .user) } ?? true) && hostValid
    }

    func rebuilt() -> [UInt8]? {
      var output: [UInt8] = []
      if let user {
        output += URLParsing.valid(user, .user) ? Array(user) : encoded(user, .user)
        if let password {
          output += [UInt8(ascii: ":")]
          output += URLParsing.valid(password, .user) ? Array(password) : encoded(password, .user)
        }
        output += [UInt8(ascii: "@")]
      }
      if hostValid {
        output += host
      } else if isIPLiteral {
        // Only a zone identifier (`fe80::1%en0`) needs repair: its `%`.
        let address = host.dropFirst().dropLast()
        guard let percent = address.firstIndex(of: UInt8(ascii: "%")),
          address[..<percent].allSatisfy(ByteSet.ipLiteral.contains)
        else { return nil }
        output += [UInt8(ascii: "[")] + address[..<percent] + Array("%25".utf8)
        output += encoded(address[(percent + 1)...], .user) + [UInt8(ascii: "]")]
      } else if let scheme, URLParsing.schemesEncodingHost.contains(scheme) {
        output += encoded(host, .host)
      } else {
        guard let ascii = idna(String(decoding: host, as: UTF8.self)) else { return nil }
        output += ascii.utf8
      }
      if let port, let number = Int(String(decoding: port, as: UTF8.self)) {
        output += Array(":\(number)".utf8)
      }
      return output
    }
  }

  /// Schemes whose host is not a DNS name: macOS percent-encodes it instead
  /// of IDNA-encoding it.
  static let schemesEncodingHost: Set<String> = [
    "tel", "telemergencycall", "telprompt", "callto", "facetime", "facetime-prompt",
    "facetime-audio", "facetime-audio-prompt", "imap", "pop", "addressbook", "contact", "phasset",
    "http+unix", "https+unix", "ws+unix", "wss+unix",
  ]

  /// Every byte allowed in `component`, and `%` only before two hex digits.
  static func valid(_ bytes: ArraySlice<UInt8>, _ component: ByteSet) -> Bool {
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let byte = bytes[index]
      if byte == UInt8(ascii: "%") {
        guard index + 2 < bytes.endIndex, ByteSet.hex.contains(bytes[index + 1]),
          ByteSet.hex.contains(bytes[index + 2])
        else { return false }
        index += 3
      } else {
        guard component.contains(byte) else { return false }
        index += 1
      }
    }
    return true
  }

  /// Percent-encodes every byte `component` does not allow, `%` included.
  static func encoded(_ bytes: ArraySlice<UInt8>, _ component: ByteSet) -> [UInt8] {
    let hex = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    for byte in bytes {
      if component.contains(byte) {
        output.append(byte)
      } else {
        output += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
      }
    }
    return output
  }

  /// A path's first segment keeps no `:` unless the path is absolute, so it
  /// cannot read as a scheme.
  private static func encodedPath(_ path: ArraySlice<UInt8>) -> [UInt8] {
    guard path.first != UInt8(ascii: "/") else { return encoded(path, .path) }
    let slash = path.firstIndex(of: UInt8(ascii: "/")) ?? path.endIndex
    return encoded(path[..<slash], .pathFirstSegment) + encoded(path[slash...], .path)
  }

  /// UTS 46 nontransitional processing as macOS applies it to a host:
  /// mapped to lowercase compatibility form (fullwidth letters and the
  /// ideographic full stop fold to ASCII), then each non-ASCII label in
  /// Punycode. Nil for an empty label or one holding a space, a control or
  /// an ASCII character a host cannot hold.
  static func idna(_ host: String) -> String? {
    let mapped = host.lowercased().precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "\u{3002}", with: ".")
    var labels = mapped.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let trailingDot = labels.count > 1 && labels.last == ""
    if trailingDot { labels.removeLast() }
    var output: [String] = []
    for label in labels {
      guard !label.isEmpty else { return nil }
      if label.utf8.allSatisfy({ $0 < 0x80 }) {
        guard label.utf8.allSatisfy(ByteSet.host.contains) else { return nil }
        output.append(label)
        continue
      }
      let scalars = Array(label.unicodeScalars)
      guard
        !scalars.contains(where: {
          $0.isASCII && !ByteSet.host.contains(UInt8($0.value))
            || $0.properties.generalCategory == .control
            || $0.properties.isWhitespace
        }),
        let encoded = punycode(scalars), encoded.utf8.count + 4 <= 63
      else { return nil }
      output.append("xn--" + encoded)
    }
    return output.joined(separator: ".") + (trailingDot ? "." : "")
  }

  /// RFC 3492 Punycode of one label.
  static func punycode(_ input: [Unicode.Scalar]) -> String? {
    let base = 36
    let tMin = 1
    let tMax = 26
    func digit(_ value: Int) -> Character {
      Character(Unicode.Scalar(UInt8(value < 26 ? 97 + value : 22 + value)))
    }
    func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
      var delta = first ? delta / 700 : delta / 2
      delta += delta / points
      var k = 0
      while delta > ((base - tMin) * tMax) / 2 {
        delta /= base - tMin
        k += base
      }
      return k + (base - tMin + 1) * delta / (delta + 38)
    }
    let codes = input.map { Int($0.value) }
    var output = String(String.UnicodeScalarView(input.filter(\.isASCII)))
    let basic = output.unicodeScalars.count
    if basic > 0 { output.append("-") }
    var handled = basic
    var n = 128
    var delta = 0
    var bias = 72
    while handled < codes.count {
      guard let next = codes.filter({ $0 >= n }).min() else { return nil }
      let (step, overflow) = (next - n).multipliedReportingOverflow(by: handled + 1)
      guard !overflow else { return nil }
      delta += step
      n = next
      for code in codes {
        if code < n { delta += 1 }
        guard code == n else { continue }
        var q = delta
        var k = base
        while true {
          let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
          if q < t { break }
          output.append(digit(t + (q - t) % (base - t)))
          q = (q - t) / (base - t)
          k += base
        }
        output.append(digit(q))
        bias = adapt(delta, handled + 1, handled == basic)
        delta = 0
        handled += 1
      }
      delta += 1
      n += 1
    }
    return output
  }

  /// The ASCII bytes a URL component allows (RFC 3986).
  struct ByteSet {
    let low: UInt64
    let high: UInt64

    init(_ characters: String) {
      var low: UInt64 = 0
      var high: UInt64 = 0
      for byte in characters.utf8 where byte < 0x80 {
        if byte < 64 { low |= 1 << UInt64(byte) } else { high |= 1 << UInt64(byte - 64) }
      }
      self.low = low
      self.high = high
    }

    func contains(_ byte: UInt8) -> Bool {
      byte < 64
        ? low & (1 << UInt64(byte)) != 0 : byte < 128 && high & (1 << UInt64(byte - 64)) != 0
    }

    static let alpha = ByteSet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let digit = ByteSet("0123456789")
    static let hex = ByteSet("0123456789ABCDEFabcdef")
    static let scheme = ByteSet(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-.")
    static let schemeEnd = ByteSet(":/?#[]@")
    static let authorityEnd = ByteSet("/?#")
    static let pathEnd = ByteSet("?#")
    static let unreservedAndSubDelims =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;="
    static let host = ByteSet(unreservedAndSubDelims)
    static let user = ByteSet(unreservedAndSubDelims)
    static let ipLiteral = ByteSet("0123456789ABCDEFabcdef:.vV")
    static let path = ByteSet(unreservedAndSubDelims + ":@/")
    static let pathFirstSegment = ByteSet(unreservedAndSubDelims + "@/")
    static let query = ByteSet(unreservedAndSubDelims + ":@/?")
  }
}
