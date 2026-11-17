import Darwin
import Foundation

/// Where the resident's socket lives:
/// `~/Library/Application Support/Flash/run/flash.sock`, in a directory only
/// the user can enter (`0700`), the socket itself `0600`. One resident runs
/// per user (`ResidentLock`) and the dev and release bundles share it, so
/// one path serves both: whichever bundle holds the lock owns the socket.
/// The home directory comes from the account, never `$HOME`, so a shell
/// that changed `HOME` still finds the resident.
struct IPCEndpoint: Equatable {
  static let socketName = "flash.sock"
  /// `sun_path` holds 104 bytes, its terminating NUL included.
  static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

  /// The private directory holding the socket.
  let directory: URL

  var socketPath: String { directory.appendingPathComponent(Self.socketName).path }

  static var standard: IPCEndpoint {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return IPCEndpoint(
      directory: appSupport.appendingPathComponent("Flash").appendingPathComponent("run"))
  }

  enum Problem: Error, Equatable, CustomStringConvertible {
    /// The socket path does not fit `sun_path`.
    case pathTooLong(String)
    /// The directory could not be created or read.
    case unavailable(String, errno: Int32)
    /// Something other than a directory sits at the path.
    case notADirectory(String)
    /// Another account owns the directory: refuse to listen or connect there.
    case notOwned(String, owner: uid_t)

    var description: String {
      switch self {
      case .pathTooLong(let path):
        return "the socket path \(path) is longer than \(IPCEndpoint.maxPathBytes) bytes"
      case .unavailable(let path, let code):
        return "\(path): \(String(cString: strerror(code)))"
      case .notADirectory(let path):
        return "\(path) is not a directory"
      case .notOwned(let path, let owner):
        return "\(path) belongs to uid \(owner), not \(geteuid())"
      }
    }
  }

  /// Where the resident binds before renaming the socket into place, so a
  /// client never finds a path that does not accept yet.
  static let stagingName = socketName + ".new"

  /// The address of `name` in the directory; fails when the path does not
  /// fit.
  func address(of name: String = IPCEndpoint.socketName) throws -> sockaddr_un {
    let path = directory.appendingPathComponent(name).path
    let bytes = Array(path.utf8)
    guard bytes.count <= Self.maxPathBytes else { throw Problem.pathTooLong(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return address
  }

  /// Make the directory exist as the user's own `0700` directory: created
  /// when missing, its mode tightened when looser, and refused when it is a
  /// symbolic link, not a directory, or another account's.
  func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    let path = directory.path
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw Problem.unavailable(path, errno: errno)
    }
    var info = stat()
    guard lstat(path, &info) == 0 else { throw Problem.unavailable(path, errno: errno) }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw Problem.notADirectory(path) }
    guard info.st_uid == geteuid() else { throw Problem.notOwned(path, owner: info.st_uid) }
    if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
      throw Problem.unavailable(path, errno: errno)
    }
  }

  /// The directory's spellings a sandbox rule must name (`PluginSandbox`):
  /// as written, and as the kernel resolves it (`realpath` of the deepest
  /// part that exists; `/var` is `/private/var`), when that differs.
  var sandboxPaths: [String] {
    var existing = directory.standardizedFileURL
    var rest: [String] = []
    while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
      rest.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    guard let resolved = realpath(existing.path, nil) else { return [directory.path] }
    defer { free(resolved) }
    let canonical = rest.reduce(URL(fileURLWithPath: String(cString: resolved))) {
      $0.appendingPathComponent($1)
    }.path
    return canonical == directory.path ? [directory.path] : [directory.path, canonical]
  }
}

/// Socket plumbing both ends share.
enum IPCSocket {
  /// A new non-blocking-capable stream socket that never raises SIGPIPE and
  /// is not inherited by children.
  static func make() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var on: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  static func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }

  /// `connect(2)` to `address`; 0 or an errno.
  static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
    var address = address
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return status == 0 ? 0 : errno
  }

  static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
    var address = address
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return status == 0 ? 0 : errno
  }

  /// The effective uid of the process at the other end, or nil.
  static func peerUID(_ fd: Int32) -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
  }

  /// Whether a peer may talk to this resident: only the user's own
  /// processes. Every other account is refused before it sends a byte.
  static func admits(peer uid: uid_t?, own: uid_t = geteuid()) -> Bool {
    uid == own
  }

  /// Write what fits right now without blocking: the count written, 0 when
  /// the socket is full, -1 when it failed.
  static func writeAvailable(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Int {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { return 0 }
    while true {
      let count = Darwin.write(fd, base, bytes.count)
      if count >= 0 { return count }
      if errno == EINTR { continue }
      return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -1
    }
  }
}
