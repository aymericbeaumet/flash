import Foundation

struct InputFocusSnapshot: Equatable {
  enum Surface: Equatable {
    case unavailable
    case editable
    case transientInteraction(reason: String)
    case stableNonEditable
  }

  var pid: pid_t
  var surface: Surface
  var role: String?
  var windowRole: String?
  var windowSubrole: String?
  var documentURL: String?

  var isEditable: Bool {
    if case .editable = surface { return true }
    return false
  }

  var isTransientInteraction: Bool {
    if case .transientInteraction = surface { return true }
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
  ) -> String? {
    if let role, transientInteractionRoles.contains(role) {
      return "role:\(role)"
    }
    if let role, expanded, expandableTransientRoles.contains(role) {
      return "expanded:\(role)"
    }
    if let role = ancestorRoles.first(where: { transientInteractionRoles.contains($0) }) {
      return "ancestor:\(role)"
    }
    if let windowSubrole, transientWindowSubroles.contains(windowSubrole) {
      return "window:\(windowSubrole)"
    }
    if let scheme = documentURL.flatMap(URL.init(string:))?.scheme?.lowercased(),
      transientDocumentSchemes.contains(scheme)
    {
      return "url:\(scheme)"
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

enum InputFocusExitDecision: Equatable {
  case stay
  case exitToNormal
  case waitForPointerRelease
  case resampleAfter(milliseconds: Int)
}

enum NormalPointerHandoffDecision: Equatable {
  case enterInsert
  case recaptureNormal
  case resampleAfter(milliseconds: Int)
}

enum InsertModeFocusMachine {
  static let transientResampleMs = 160

  /// How many times a surface may keep classifying as `transientInteraction`
  /// before we stop resampling and commit. A genuine transient popup
  /// (autocomplete, combo dropdown, menu) resolves within a sample or two to
  /// either an editable surface or a stable one. A surface that stays
  /// "transient" past this budget is actually *persistent* content that
  /// merely matches the role/ancestor heuristic — most visibly Firefox web
  /// content focused on an `AXStaticText` nested under an `AXList`, which
  /// otherwise spun the resamplers forever and welded the user into NORMAL.
  /// `transientResampleMaxAttempts * transientResampleMs ≈ 0.8 s`.
  static let transientResampleMaxAttempts = 5

  static func shouldArmGenericExit(snapshot: InputFocusSnapshot) -> Bool {
    snapshot.isEditable
  }

  static func insertFocusChangeDecision(
    focusedPID: pid_t?,
    eventPID: pid_t,
    armedEditablePID: pid_t?,
    snapshot: InputFocusSnapshot,
    pointerPressed: Bool,
    attempt: Int = 0
  ) -> InputFocusExitDecision {
    guard let focusedPID, let armedEditablePID else { return .stay }
    guard focusedPID == eventPID, focusedPID == armedEditablePID else { return .stay }
    if snapshot.isEditable { return .stay }
    if pointerPressed { return .waitForPointerRelease }
    if snapshot.isTransientInteraction {
      // Budget exhausted: the surface is persistent, not a vanishing popup.
      // Keep the user in INSERT rather than resampling indefinitely — only a
      // genuinely *stable* non-editable surface (the branch below) exits.
      if attempt >= transientResampleMaxAttempts { return .stay }
      return .resampleAfter(milliseconds: transientResampleMs)
    }
    return .exitToNormal
  }

  static func normalPointerHandoffDecision(snapshot: InputFocusSnapshot?, attempt: Int = 0)
    -> NormalPointerHandoffDecision
  {
    guard let snapshot else { return .recaptureNormal }
    if snapshot.isEditable { return .enterInsert }
    if snapshot.isTransientInteraction {
      // Budget exhausted: the user deliberately clicked this element and it
      // hasn't dissolved like a real popup would, so treat it as a genuine
      // interaction target and hand the keyboard over instead of spinning.
      if attempt >= transientResampleMaxAttempts { return .enterInsert }
      return .resampleAfter(milliseconds: transientResampleMs)
    }
    return .recaptureNormal
  }
}
