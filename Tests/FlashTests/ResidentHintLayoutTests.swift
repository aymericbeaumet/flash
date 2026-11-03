import AppKit
import FlashCore
import FlashIntegrationTestSupport
import XCTest

@testable import flash

/// The native oracle waits for each hint layout by polling `/api/state` with
/// no event stream open, then types one of its labels. These tests read what
/// the resident publishes for a real presentation the same way.
final class ResidentHintLayoutTests: XCTestCase {
  /// The access token the test server answers.
  static let token = HelpAccess.newToken()

  private var delegate: AppDelegate!
  private var port: UInt16 = 0

  override func setUpWithError() throws {
    try super.setUpWithError()
    _ = NSApplication.shared
    let delegate = AppDelegate()
    // The bundled grid defaults: three steps, with the next step previewed.
    delegate.config = ConfigLoader.parse(
      """
      [debug]
      http_inspector_enabled = true
      """)
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    // As in the resident, the session tap captures hint keys: the overlay
    // never takes the key window.
    delegate.overlay.keyboardCaptureActive = true
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.widgetController = WidgetController(
      setVisible: { _, _ in }, screenLayouts: { _, _ in [] })
    delegate.wireInspectorChangeSources()
    let server = DebugServer(host: "localhost", port: 0, accessToken: Self.token) {
      [weak delegate] in
      delegate?.debugStateJSON() ?? [:]
    }
    delegate.attachDebugServer(server)
    server.start()
    self.delegate = delegate
    // `listeningPort` belongs to the server's queue; the readiness callback
    // hands the port to main.
    let ready = expectation(description: "listening")
    var bound: UInt16?
    server.whenListening(timeoutSeconds: 10) { listening in
      bound = listening
      ready.fulfill()
    }
    wait(for: [ready], timeout: 11)
    port = try XCTUnwrap(bound, "DebugServer never started listening")
  }

  override func tearDown() {
    delegate.overlay.hide()
    delegate.overlay.orderOut(nil)
    delegate.hintSession = HintSession()
    delegate.stopDebugServer()
    delegate.overlay.statusTerminals.shutdown()
    delegate = nil
    super.tearDown()
  }

  /// The grid draws each cell's next step faintly under its own cells, and
  /// those preview cells are part of the published `hints`. The oracle has to
  /// recognise every step as a grid layout and type only the step's own
  /// cells, down to the clicking step.
  func testTheOracleReadsEveryPublishedGridStepAndTypesOnlyItsOwnCells() throws {
    XCTAssertTrue(delegate.config.hints.mouseGridPreview, "the default grid previews")
    XCTAssertNil(try ResidentHintLayout.clickHints(in: state(), surface: .grid), "no grid yet")

    delegate.hintSession.surface = .grid
    delegate.hintSession.gridShape = .keyboard(Alphabet.gridKeys(layoutName: "qwerty"))
    delegate.displayMouseGrid(
      MouseGrid.Navigation(root: CGRect(x: 0, y: 0, width: 1500, height: 1000), screenIndex: 0))
    let published = try state()
    XCTAssertEqual(published["hint_session"] as? String, "grid")
    let first = try XCTUnwrap(
      ResidentHintLayout.clickHints(in: published, surface: .grid),
      "the first step, previewing the next, is a grid layout")
    XCTAssertNil(try ResidentHintLayout.clickHints(in: published, surface: .targets))
    XCTAssertEqual(first.count, 420)
    XCTAssertEqual(first.filter(\.isGridPreview).count, 400)
    XCTAssertEqual(
      ResidentHintLayout.typedCells(first).map(\.label).joined(), "12345qwertasdfgzxcvb")

    // `t`, then `t` again: two drilling steps reach the clicking one.
    delegate.overlayDidGrid(.cell("t", []))
    let second = try XCTUnwrap(ResidentHintLayout.clickHints(in: state(), surface: .grid))
    XCTAssertNotEqual(second, first)
    XCTAssertEqual(ResidentHintLayout.typedCells(second).count, 20)
    delegate.overlayDidGrid(.cell("t", []))
    let last = try XCTUnwrap(ResidentHintLayout.clickHints(in: state(), surface: .grid))
    XCTAssertEqual(last.count, 20)
    XCTAssertTrue(last.allSatisfy(\.isFinalGridCell), "the clicking step previews nothing")
  }

  /// The roles the oracle reads are the ones `MouseGrid` publishes.
  func testTheOracleNamesTheGridRolesTheResidentPublishes() {
    XCTAssertEqual(ResidentHint.gridCellRole, MouseGrid.cellRole)
    XCTAssertEqual(ResidentHint.gridFinalCellRole, MouseGrid.finalCellRole)
    XCTAssertEqual(ResidentHint.gridFinalChipRole, MouseGrid.finalChipRole)
    XCTAssertEqual(ResidentHint.gridPreviewCellRole, MouseGrid.previewCellRole)
  }

  /// `GET /api/state`, decoded as the oracle decodes it. The main run loop
  /// keeps turning: a stale cache is refreshed by a hop to main.
  private func state() throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/state")))
    HelpAccess.authorize(&request, token: Self.token)
    var body: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      DispatchQueue.main.async { body = data ?? Data() }
    }.resume()
    let deadline = Date().addingTimeInterval(10)
    while body == nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let data = try XCTUnwrap(body, "no reply from /api/state")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
