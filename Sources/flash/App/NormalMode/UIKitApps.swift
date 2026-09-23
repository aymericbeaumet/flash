import AppKit
import Carbon.HIToolbox

/// Mac Catalyst and iPad apps (Messages, WhatsApp) run on UIKit, which matches
/// key commands against the modifier state it tracks from modifier key
/// presses, not the flags a key event carries. A chord posted as one flagged
/// key reaches such an app and does nothing — WhatsApp ignored ⇧⌘] and ⌘F,
/// Messages ⌃⇥ — so `NormalModeDispatcher.sendKey` brackets the key with its
/// modifiers' own presses for these apps, as a keyboard sends it.
enum UIKitApps {
  private static let lock = NSLock()
  private static var hostsUIKitByBundlePath: [String: Bool] = [:]

  /// Cached per bundle; the first answer for a bundle reads its Info.plist.
  static func hostsUIKit(pid: pid_t) -> Bool {
    guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
      return false
    }
    let path = bundleURL.path
    lock.lock()
    let cached = hostsUIKitByBundlePath[path]
    lock.unlock()
    if let cached { return cached }
    let hosts = hostsUIKit(infoDictionary: Bundle(url: bundleURL)?.infoDictionary ?? [:])
    lock.lock()
    hostsUIKitByBundlePath[path] = hosts
    lock.unlock()
    return hosts
  }

  /// A UIKit app declares the device families it targets; an AppKit app does
  /// not.
  static func hostsUIKit(infoDictionary: [String: Any]) -> Bool {
    infoDictionary["UIDeviceFamily"] != nil
  }

  /// The modifier keys `flags` holds, in the order they go down.
  static func modifierKeys(in flags: CGEventFlags) -> [(key: CGKeyCode, flag: CGEventFlags)] {
    let modifiers: [(key: CGKeyCode, flag: CGEventFlags)] = [
      (CGKeyCode(kVK_Control), .maskControl),
      (CGKeyCode(kVK_Option), .maskAlternate),
      (CGKeyCode(kVK_Shift), .maskShift),
      (CGKeyCode(kVK_Command), .maskCommand),
    ]
    return modifiers.filter { flags.contains($0.flag) }
  }
}
