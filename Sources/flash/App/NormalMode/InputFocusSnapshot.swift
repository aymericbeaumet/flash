import Foundation

struct InputFocusSnapshot: Equatable {
  enum TransientInteractionReason: Equatable, CustomStringConvertible {
    case role(String)
    case expandedRole(String)
    case ancestorRole(String)
    case windowSubrole(String)
    case extensionDocument(scheme: String)

    var description: String {
      switch self {
      case .role(let role):
        return "role:\(role)"
      case .expandedRole(let role):
        return "expanded:\(role)"
      case .ancestorRole(let role):
        return "ancestor:\(role)"
      case .windowSubrole(let subrole):
        return "window:\(subrole)"
      case .extensionDocument(let scheme):
        return "url:\(scheme)"
      }
    }

  }

  enum Surface: Equatable, CustomStringConvertible {
    case unavailable
    case editable
    case transientInteraction(reason: TransientInteractionReason)
    case stableNonEditable

    var description: String {
      switch self {
      case .unavailable:
        return "unavailable"
      case .editable:
        return "editable"
      case .transientInteraction(let reason):
        return "transient:\(reason)"
      case .stableNonEditable:
        return "stable_noneditable"
      }
    }
  }

  var surface: Surface

  var isEditable: Bool {
    if case .editable = surface { return true }
    return false
  }

  static func classifySurface(
    isEditable: Bool,
    role: String?,
    expanded: Bool,
    ancestorRoles: [String],
    windowSubrole: String?,
    documentURL: String?
  ) -> Surface {
    if isEditable {
      return .editable
    }
    if let reason = transientInteractionReason(
      role: role,
      expanded: expanded,
      ancestorRoles: ancestorRoles,
      windowSubrole: windowSubrole,
      documentURL: documentURL)
    {
      return .transientInteraction(reason: reason)
    }
    return .stableNonEditable
  }

  private static func transientInteractionReason(
    role: String?,
    expanded: Bool,
    ancestorRoles: [String],
    windowSubrole: String?,
    documentURL: String?
  ) -> TransientInteractionReason? {
    // Browser-extension popups are durable mini-documents, not autocomplete
    // menus. They still get the short settle window because password-manager
    // popovers reshuffle AX focus while opening, but after that budget they
    // must behave like ordinary non-editable web content.
    if let scheme = documentURL.flatMap(URL.init(string:))?.scheme?.lowercased(),
      transientDocumentSchemes.contains(scheme)
    {
      return .extensionDocument(scheme: scheme)
    }
    if let role, transientInteractionRoles.contains(role) {
      return .role(role)
    }
    if let role, expanded, expandableTransientRoles.contains(role) {
      return .expandedRole(role)
    }
    if let role = ancestorRoles.first(where: { transientInteractionRoles.contains($0) }) {
      return .ancestorRole(role)
    }
    if let windowSubrole, transientWindowSubroles.contains(windowSubrole) {
      return .windowSubrole(windowSubrole)
    }
    return nil
  }

  private static let transientInteractionRoles: Set<String> = [
    "AXComboBox",
    "AXList", "AXListItem",
    "AXMenu", "AXMenuItem", "AXMenuButton",
    "AXOption",
    "AXPopover",
  ]

  private static let expandableTransientRoles: Set<String> = [
    "AXComboBox", "AXPopUpButton",
  ]

  private static let transientWindowSubroles: Set<String> = [
    "AXDialog", "AXFloatingWindow", "AXPopover", "AXSystemDialog",
  ]

  private static let transientDocumentSchemes: Set<String> = [
    "chrome-extension", "moz-extension", "safari-web-extension",
  ]
}
