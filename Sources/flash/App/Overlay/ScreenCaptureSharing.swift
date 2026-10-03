import AppKit

extension ScreenCaptureVisibility {
  /// `hide` asks the window server to leave the window out of screenshots,
  /// recordings and screen sharing. Best effort: recent macOS capture APIs
  /// can still include it.
  var sharingType: NSWindow.SharingType {
    switch self {
    case .show: return .readOnly
    case .hide: return .none
    }
  }
}

extension OverlayPanel {
  /// `[overlay] screen_capture` on every Flash surface: the overlay panel,
  /// the status bar, its click windows and the popup panel. Click windows
  /// created later take it on creation.
  func applyScreenCaptureSharing() {
    let sharing = overlayConfig.screenCapture.sharingType
    sharingType = sharing
    statusBarWindow.sharingType = sharing
    for window in statusBarClickWindows { window.sharingType = sharing }
    statusPopupController.sharingType = sharing
  }
}
