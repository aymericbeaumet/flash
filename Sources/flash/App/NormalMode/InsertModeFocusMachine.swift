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

    var remainsInteractiveAfterSettleBudget: Bool {
      if case .extensionDocument = self {
        return false
      }
      return true
    }

    var suspendsNormalCaptureAfterPointerHandoffBudget: Bool {
      switch self {
      case .role(let role):
        return normalPointerHandoffSuspendingRoles.contains(role)
      case .expandedRole(let role):
        return expandableTransientRoles.contains(role)
      case .ancestorRole(let role):
        // A focused AXStaticText nested under AXList is common persistent
        // browser content, so an AXList ancestor alone must not pin normal
        // capture open. Option/list-item/menu ancestors are actual popup
        // interaction surfaces and should keep native focus.
        return normalPointerHandoffSuspendingAncestorRoles.contains(role)
      case .windowSubrole, .extensionDocument:
        return true
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

enum InputFocusExitDecision: Equatable {
  case stay
  case exitToNormal
  case waitForPointerRelease
  case resampleAfter(milliseconds: Int)
}

enum NormalPointerHandoffDecision: Equatable {
  case enterInsert
  case recaptureNormal
  case suspendNativeSurface
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
    if case .transientInteraction(let reason) = snapshot.surface {
      // Budget exhausted: most role/window transient surfaces are persistent
      // interaction targets rather than vanishing popups. Extension document
      // popovers are different: after their opening settle budget, a
      // non-editable target should leave INSERT just like any other stable web
      // control.
      if attempt >= transientResampleMaxAttempts {
        return reason.remainsInteractiveAfterSettleBudget ? .stay : .exitToNormal
      }
      return .resampleAfter(milliseconds: transientResampleMs)
    }
    return .exitToNormal
  }

  static func normalPointerHandoffDecision(snapshot: InputFocusSnapshot?, attempt: Int = 0)
    -> NormalPointerHandoffDecision
  {
    guard let snapshot else { return .recaptureNormal }
    if snapshot.isEditable { return .enterInsert }
    if case .transientInteraction(let reason) = snapshot.surface {
      // Budget exhausted: if the surface never resolves to a true editable,
      // keep NORMAL. Popovers, extension panels, menus, and select/dropdown
      // options must keep native focus so Flash does not immediately close
      // them by re-keying the overlay. Persistent browser widgets that only
      // match by a broad AXList ancestor recapture instead.
      if attempt >= transientResampleMaxAttempts {
        return reason.suspendsNormalCaptureAfterPointerHandoffBudget
          ? .suspendNativeSurface
          : .recaptureNormal
      }
      return .resampleAfter(milliseconds: transientResampleMs)
    }
    return .recaptureNormal
  }

  static func normalPointerHandoffDecision(
    clickedSnapshot: InputFocusSnapshot?,
    focusedSnapshot: InputFocusSnapshot?,
    attempt: Int = 0
  ) -> NormalPointerHandoffDecision {
    let clickedDecision = normalPointerHandoffDecision(snapshot: clickedSnapshot, attempt: attempt)
    switch clickedDecision {
    case .enterInsert, .resampleAfter, .suspendNativeSurface:
      return clickedDecision
    case .recaptureNormal:
      break
    }

    let focusedDecision = normalPointerHandoffDecision(snapshot: focusedSnapshot, attempt: attempt)
    switch focusedDecision {
    case .resampleAfter, .suspendNativeSurface:
      return focusedDecision
    case .enterInsert, .recaptureNormal:
      // Do not let stale focus on a previous text input turn a toolbar/button
      // click into INSERT. Point hit-testing owns the editable decision.
      return clickedDecision
    }
  }
}

private let normalPointerHandoffSuspendingRoles: Set<String> = [
  "AXComboBox",
  "AXList", "AXListItem",
  "AXMenu", "AXMenuItem", "AXMenuButton",
  "AXOption",
  "AXPopover",
]

private let normalPointerHandoffSuspendingAncestorRoles: Set<String> = [
  "AXComboBox",
  "AXListItem",
  "AXMenu", "AXMenuItem", "AXMenuButton",
  "AXOption",
  "AXPopover",
]
