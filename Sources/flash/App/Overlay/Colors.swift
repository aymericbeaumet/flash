import AppKit
import QuartzCore

/// Nord palette + the mode-badge palettes derived from it. Owns the
/// `ModeBadgePalette` value type, the static NSColor + CGColor
/// constants, and the per-style palette factory.
///
/// Pre-bakes CGColors at type-init so the per-render path doesn't pay
/// the NSColor → CGColor conversion. The render path (`configureModeBadge`,
/// `configureCommandPrompt`, `configureCandidateFinderResults`) reads
/// only the `*CG` variants.
extension OverlayPanel {
  struct ModeBadgePalette {
    var topCG: CGColor
    var bottomCG: CGColor
    var foregroundCG: CGColor
    var borderCG: CGColor
  }

  static let nordPolarNight0 = NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.25, alpha: 1)
  static let nordPolarNight1 = NSColor(calibratedRed: 0.23, green: 0.26, blue: 0.32, alpha: 1)
  static let nordSnowStorm0 = NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.91, alpha: 1)
  static let nordSnowStorm1 = NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
  static let nordSnowStorm2 = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
  static let nordFrost2 = NSColor(calibratedRed: 0.53, green: 0.75, blue: 0.82, alpha: 1)
  static let nordAuroraGreen = NSColor(calibratedRed: 0.64, green: 0.75, blue: 0.55, alpha: 1)
  static let nordAuroraYellow = NSColor(calibratedRed: 0.92, green: 0.80, blue: 0.55, alpha: 1)
  static let nordAuroraPurple = NSColor(calibratedRed: 0.71, green: 0.56, blue: 0.68, alpha: 1)
  static let tmuxGrey245 = NSColor(calibratedWhite: 0.54, alpha: 1)
  static let tmuxRed196 = NSColor(calibratedRed: 1.00, green: 0.00, blue: 0.00, alpha: 1)

  static let nordPolarNight0CG = nordPolarNight0.cgColor
  static let nordSnowStorm1CG = nordSnowStorm1.cgColor
  static let nordSnowStorm2CG = nordSnowStorm2.cgColor
  static let nordFrost2CG = nordFrost2.cgColor
  static let nordAuroraGreenCG = nordAuroraGreen.cgColor
  static let nordAuroraYellowCG = nordAuroraYellow.cgColor
  static let nordAuroraPurpleCG = nordAuroraPurple.cgColor
  static let tmuxGrey245CG = tmuxGrey245.cgColor
  /// Faint outline for the NORMAL-mode pill. The normal pill is dark-on-dark
  /// (same fill as the bar) so without a border it has no visible edge — a
  /// 1px, low-alpha white hairline reads as a subtle frame around it.
  static let statusModeNormalBorderCG = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor

  static let insertPalette = ModeBadgePalette(
    topCG: nordFrost2CG,
    bottomCG: nordFrost2CG,
    foregroundCG: nordPolarNight0CG,
    borderCG: nordAuroraYellowCG)
  static let normalPalette = ModeBadgePalette(
    topCG: nordPolarNight0CG,
    bottomCG: nordPolarNight0CG,
    foregroundCG: nordAuroraGreenCG,
    borderCG: nordAuroraYellowCG)
  static let commandPaletteValue = ModeBadgePalette(
    topCG: nordAuroraPurpleCG,
    bottomCG: nordAuroraPurpleCG,
    foregroundCG: nordPolarNight0CG,
    borderCG: nordAuroraYellowCG)
  static let commandInputPaletteValue = ModeBadgePalette(
    topCG: nordPolarNight0CG,
    bottomCG: nordPolarNight0CG,
    foregroundCG: nordSnowStorm2CG,
    borderCG: nordAuroraPurpleCG)

  func modeBadgePalette() -> ModeBadgePalette {
    switch modeBadgeStyle {
    case .insert: return Self.insertPalette
    case .normal: return Self.normalPalette
    case .command: return Self.commandPaletteValue
    }
  }

  func commandInputPalette() -> ModeBadgePalette { Self.commandInputPaletteValue }
}
