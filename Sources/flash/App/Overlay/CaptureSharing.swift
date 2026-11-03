import AppKit

/// `[app] hide_from_capture`: whether Flash's windows ask the window server
/// to stay out of screenshots, recordings and screen sharing. Every Flash
/// window takes it: the overlay panel (hints, the grid, the command line,
/// the flashlight, alerts and the focus border), the status bar and its
/// click windows, popups, widgets and About.
///
/// Best effort. `NSWindow.SharingType.none` acts at the CGWindow level, so
/// legacy window-list captures leave the window out, while the display
/// capture QuickTime, ⇧⌘5 and video calls use on macOS 15 and later,
/// AirPlay and remote screen sharing read the composed display below it and
/// still show it (docs/privacy.md#screen-capture). Apple documents the
/// constant as legacy and not a capture protection. The window server also
/// keeps a live window out once asked: a later `.readOnly` reads back as
/// `.none`, so turning the key off reaches only the windows created from
/// then on until Flash restarts.
enum CaptureSharing {
  static func sharingType(hidden: Bool) -> NSWindow.SharingType {
    hidden ? .none : .readOnly
  }
}

extension OverlayPanel {
  /// The overlay panel, the status bar, its click windows and the popup
  /// panel take `hidesFromCapture`; click windows created later take it on
  /// creation.
  func applyCaptureSharing() {
    let sharing = CaptureSharing.sharingType(hidden: hidesFromCapture)
    sharingType = sharing
    statusBarWindow.sharingType = sharing
    for window in statusBarClickWindows { window.sharingType = sharing }
    statusPopupController.sharingType = sharing
  }
}

extension AppDelegate {
  /// On every config load and reload: the windows the resident owns, and
  /// About. Widgets take it through `WidgetController.apply`.
  func applyCaptureSharing(hidden: Bool) {
    if !hidden, overlay.hidesFromCapture {
      FlashLog.info(
        "[capture] hide_from_capture off: windows already hidden stay out of capture "
          + "until Flash restarts")
    }
    overlay.hidesFromCapture = hidden
    statusItemController.hidesFromCapture = hidden
  }
}
