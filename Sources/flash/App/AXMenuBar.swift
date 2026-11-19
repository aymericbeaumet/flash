import ApplicationServices
import FlashProviders

/// An app's menu bar as Accessibility exposes it: the `AXMenuBar` element
/// and the bar items under it. Shared by the menu-item bindings, the
/// `mouse menubar` hints and the plugin broker's menu-bar snapshot.
enum AXMenuBar {
  /// The app's `AXMenuBar`, nil when it has none or does not answer.
  static func element(of app: AXUIElement) -> AXUIElement? {
    AXAttribute.element(app, kAXMenuBarAttribute as String)
  }

  /// The app's menu-bar titles in bar order, the Apple menu first: the
  /// children of its `AXMenuBar`.
  static func items(of app: AXUIElement) -> [AXUIElement] {
    element(of: app).map(AXAttribute.children) ?? []
  }
}
