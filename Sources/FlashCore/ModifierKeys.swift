import AppKit

extension NSEvent.ModifierFlags {
  /// The modifier keys a key event can carry. Flash reads an event's
  /// modifiers through this set and nothing wider: the device-independent
  /// range also holds bits no key sets (an event another process posts
  /// arrives with `0x20000000`), and a check for "no modifier" that read them
  /// would refuse a posted key a keyboard's own would pass.
  public static let modifierKeys: NSEvent.ModifierFlags = [
    .capsLock, .shift, .control, .option, .command, .numericPad, .help, .function,
  ]
}
