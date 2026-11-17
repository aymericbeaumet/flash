import CoreGraphics
import Foundation

/// The resident's `/api/state` answered with something an oracle cannot read.
public struct ResidentStateError: Error, CustomStringConvertible {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { "Flash debug state unavailable: \(message)" }
}

/// One entry of `/api/state`'s `hints`, as an integration oracle reads it.
public struct ResidentHint: Equatable, Sendable {
  /// The mouse grid's cell roles, as the resident's `MouseGrid` names them.
  public static let gridCellRole = "FlashMouseGridCell"
  public static let gridFinalCellRole = "FlashMouseGridFinalCell"
  public static let gridFinalChipRole = "FlashMouseGridFinalChip"
  /// A cell of the step that follows one of the current cells, drawn faintly
  /// under them (`hints.mouse_grid_preview`) and labelled with the two keys
  /// that reach it. Listed in `hints`, but no key selects it.
  public static let gridPreviewCellRole = "FlashMouseGridPreviewCell"

  public let label: String
  public let accessibilityLabel: String?
  public let role: String?
  public let frame: CGRect

  /// A cell the mouse grid draws, its preview of the next step included.
  public var isGridCell: Bool {
    role == Self.gridCellRole || isFinalGridCell || isGridPreview
  }

  /// A preview cell of the next grid step.
  public var isGridPreview: Bool {
    role == Self.gridPreviewCellRole
  }

  /// A grid cell whose selection clicks.
  public var isFinalGridCell: Bool {
    role == Self.gridFinalCellRole || role == Self.gridFinalChipRole
  }

  public init(_ value: [String: Any]) throws {
    guard let label = value["label"] as? String, !label.isEmpty,
      let frame = value["frame"] as? [String: NSNumber],
      let x = frame["x"], let y = frame["y"],
      let width = frame["width"], let height = frame["height"]
    else { throw ResidentStateError("invalid hint label or frame") }
    self.label = label
    accessibilityLabel = value["accessibility_label"] as? String
    role = value["role"] as? String
    self.frame = CGRect(
      x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
  }
}

/// Which hint surface an oracle waits for.
public enum ResidentHintSurface: String, Sendable {
  case targets, grid
}

public enum ResidentHintLayout {
  /// The click hints `/api/state` shows on `surface`, or nil while it shows
  /// no finished click layout there: a click command, the overlay routing
  /// keys to hints, no walk in flight, and hints of that surface only.
  public static func clickHints(
    in state: [String: Any], surface: ResidentHintSurface
  ) throws -> [ResidentHint]? {
    guard let command = state["hint_command"] as? String, command.hasPrefix("click("),
      // `overlay` is `String(describing:)` of the panel's `OverlayInputMode`.
      let overlay = state["overlay"] as? String, overlay == "hints",
      state["activation_in_flight"] as? Bool == false,
      let values = state["hints"] as? [[String: Any]]
    else { return nil }
    let hints = try values.map(ResidentHint.init)
    // Target and grid sessions share the click command and hint input mode;
    // only the grid's cell roles distinguish the displayed surface.
    guard !hints.isEmpty,
      hints.allSatisfy({ $0.isGridCell == (surface == .grid) })
    else { return nil }
    return hints
  }

  /// The cells of a grid step that a key selects: its own, not the preview
  /// of the next step drawn under them.
  public static func typedCells(_ hints: [ResidentHint]) -> [ResidentHint] {
    hints.filter { !$0.isGridPreview }
  }
}
