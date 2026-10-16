import CoreGraphics
import Darwin
import Foundation

/// Lets Flash hide the pointer while another app is frontmost. AppKit's
/// `NSCursor.setHiddenUntilMouseMoves` is ignored from a background app, and
/// Flash never becomes active while hints are up (the session tap reads the
/// keys), so the hint cursor stayed visible. The window server honours it
/// once the connection carries `SetsCursorInBackground`.
///
/// That property is private API. It is resolved at run time, so a macOS
/// without it leaves the pointer visible instead of failing to launch.
enum BackgroundCursor {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias SetConnectionProperty =
    @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

  /// Allow cursor visibility changes from the background. Returns false
  /// when the window server does not offer it.
  @discardableResult
  static func enable() -> Bool {
    let process = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let main = dlsym(process, "CGSMainConnectionID"),
      let set = dlsym(process, "CGSSetConnectionProperty")
    else { return false }
    let connection = unsafeBitCast(main, to: MainConnection.self)()
    let status = unsafeBitCast(set, to: SetConnectionProperty.self)(
      connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    return status == 0
  }
}
