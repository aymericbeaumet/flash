import Foundation
import XCTest

@testable import flash

/// Every TOML file under `docs/examples/` is a configuration a reader pastes
/// into `flash.toml`: it must load over the bundled defaults, exactly as the
/// resident and `flash config_check` load it, without a single diagnostic.
final class DocsExampleConfigTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  private func examples() throws -> [URL] {
    let directory = Self.root.appendingPathComponent("docs/examples")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "toml" }
      .sorted { $0.path < $1.path }
  }

  func testEveryExampleLoadsOverTheDefaultsWithoutDiagnostics() throws {
    let defaults = ConfigLoader.Layer(
      text: try String(
        contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8),
      diagnosticLabel: "config.default.toml")
    let files = try examples()
    let widgets = files.filter { $0.deletingLastPathComponent().lastPathComponent == "widgets" }
    XCTAssertGreaterThanOrEqual(widgets.count, 3)
    for file in files {
      let config = ConfigLoader.parseLayers(
        [defaults, .init(text: try String(contentsOf: file, encoding: .utf8), sourceURL: file)])
      XCTAssertEqual(config.loadingDiagnostics.map(\.message), [], file.lastPathComponent)
      if widgets.contains(file) {
        XCTAssertFalse(config.enabledWidgets.isEmpty, "\(file.lastPathComponent) shows a widget")
      }
    }
  }

  /// The README's snippets are the first configuration most people paste.
  func testEveryReadmeTOMLSnippetLoadsOverTheDefaultsWithoutDiagnostics() throws {
    let defaults = ConfigLoader.Layer(
      text: try String(
        contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8))
    let readme = try String(
      contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
    let snippets = readme.components(separatedBy: "```toml\n").dropFirst().compactMap {
      $0.components(separatedBy: "\n```").first
    }
    XCTAssertGreaterThanOrEqual(snippets.count, 5)
    for (index, snippet) in snippets.enumerated() {
      let config = ConfigLoader.parseLayers([defaults, .init(text: snippet)])
      XCTAssertEqual(config.loadingDiagnostics.map(\.message), [], "README snippet \(index + 1)")
    }
  }

  func testEveryExampleWidgetEvaluatesWithoutAnEmptyLine() throws {
    let defaults = ConfigLoader.Layer(
      text: try String(
        contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8))
    for file in try examples() {
      let config = ConfigLoader.parseLayers(
        [defaults, .init(text: try String(contentsOf: file, encoding: .utf8), sourceURL: file)])
      for (name, widget) in config.widgets where widget.enabled {
        var native = FlashStatusBarTemplateEngine.formatContext(.init())
        native.options = config.statusBar.options.merging(widget.template.options) { _, local in
          local
        }
        native.values["flash.widget.name"] = name
        native.values["flash.widget.columns"] = String(widget.spec.columns)
        let evaluation = FlashStatusBarTemplateEngine.evaluateDocument(
          widget.template, native: native, lineBreaksResetAlignment: true)
        let lines = StatusFormatDocument(runs: evaluation.runs).lines()
        XCTAssertFalse(lines.isEmpty, "\(file.lastPathComponent) widgets.\(name)")
        let raw = lines.flatMap(\.runs).map(\.text).joined()
        XCTAssertFalse(raw.contains("#{"), "\(name) leaves an unexpanded format: \(raw)")
      }
    }
  }
}
