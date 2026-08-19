import ApplicationServices

/// AX action inspection used only to confirm tentative targets during
/// discovery. Production hint commits never invoke an AX action: the host
/// delegates through a real mouse event in `ActionDispatcher`.
public enum AXClick {
  /// Action names that make an otherwise tentative AX node a clickable target.
  private static let pressActions: [String] = [
    kAXPressAction, "AXOpen", "AXConfirm",
  ]

  public static func hasPressAction(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
      let actions = names as? [String]
    else { return false }
    return pressActions.contains(where: actions.contains)
  }
}
