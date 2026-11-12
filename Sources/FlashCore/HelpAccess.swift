import Foundation
import Security

/// The help server's secret. The server listens on the loopback address,
/// which every account and process on the Mac shares, so the address alone
/// says nothing about who asks: its data endpoints (`/api/…`, except the
/// bundled documentation) answer only a request carrying this token.
///
/// The token lives in a file only your account can read
/// (`~/Library/Application Support/Flash/help-token`, `0600`): programs
/// running as you read it there, and the browser receives it once, in the
/// address Flash opens. It persists across launches, so a page you left
/// open or bookmarked keeps working.
public enum HelpAccess {
  /// `Authorization: Bearer <token>`.
  public static let headerName = "Authorization"
  /// `?token=<token>`, for what cannot set a header: the address Flash
  /// opens, an event stream, an image.
  public static let queryName = "token"

  public static var defaultFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Flash/help-token")
  }

  /// The stored token, or nil when there is none yet, it is malformed, or
  /// the file is not private to this account (it is then never trusted).
  public static func load(from url: URL = defaultFileURL) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
      let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & 0o077 == 0,
      let data = try? Data(contentsOf: url),
      let token = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      isWellFormed(token)
    else { return nil }
    return token
  }

  /// The stored token, created on first use. A file that is not private to
  /// this account is replaced: its token may have been read by someone else.
  public static func loadOrCreate(at url: URL = defaultFileURL) throws -> String {
    if let token = load(from: url) { return token }
    let token = newToken()
    try write(token, to: url)
    return token
  }

  /// 32 random bytes, as 64 lowercase hex characters.
  public static func newToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func isWellFormed(_ token: String) -> Bool {
    token.utf8.count == 64
      && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// Whether `candidate` is `token`, in time independent of where they
  /// first differ.
  public static func matches(_ candidate: String, _ token: String) -> Bool {
    let lhs = Array(candidate.utf8)
    let rhs = Array(token.utf8)
    guard lhs.count == rhs.count, !rhs.isEmpty else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }

  /// `request` with the token in its `Authorization` header.
  public static func authorize(_ request: inout URLRequest, token: String) {
    request.setValue("Bearer \(token)", forHTTPHeaderField: headerName)
  }

  /// Created private, then moved into place: no moment where another account
  /// could read the token, and no reader sees half a file.
  private static func write(_ token: String, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString)")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: Data(token.utf8),
        attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
    guard rename(temporary.path, url.path) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temporary)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }
}
