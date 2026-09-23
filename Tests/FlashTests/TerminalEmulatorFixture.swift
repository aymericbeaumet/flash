import FlashCore

@testable import flash

/// The bundled `terminals` plugin's declaration, which production publishes
/// with every plugin snapshot. A test that exercises terminal rules declares
/// it itself: a plugin-manager test may have published another set.
enum TerminalEmulatorFixture {
  static let official: Set<String> = {
    guard
      let root = PluginRepository.officialPluginRoots().first(where: {
        $0.lastPathComponent == "terminals"
      }),
      let manifest = try? PluginManifest.load(from: root)
    else { return [] }
    return Set(manifest.terminalEmulators)
  }()

  static func declareOfficial() {
    TerminalEmulators.declare(official)
  }
}
