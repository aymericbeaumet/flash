import Foundation
import XCTest

@testable import flash

/// What the resident sees of updates: the About actions, the commands'
/// answers and the alerts, over the fakes of `UpdateControllerTests`.
final class UpdateCoordinatorTests: XCTestCase {
  private typealias Fakes = UpdateControllerTests
  private var root: URL!
  private var alerts: [StatusAlert] = []
  private var aboutActions = 0

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flash-update-coordinator-\(UUID().uuidString)")
    try Fakes.FakeUnpacker.makeBundle(at: bundle, version: "1.1.0")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private var bundle: URL { root.appendingPathComponent("Applications/Flash.app") }

  private func controller(identity: BuildIdentity) throws -> UpdateController {
    let log = Fakes.Log()
    let archive = root.appendingPathComponent("fixture.zip")
    try Data("release archive".utf8).write(to: archive)
    let release = UpdateRelease(
      version: "1.2.0", assetName: "Flash-1.2.0.zip",
      downloadURL: URL(string: "https://github.com/x/Flash-1.2.0.zip")!,
      sha256: try XCTUnwrap(UpdateRelease.sha256(of: archive)), size: 15, pageURL: nil)
    return UpdateController(
      environment: .init(
        currentVersion: "1.1.0", bundleURL: bundle, identity: identity,
        directory: root.appendingPathComponent("Updates"),
        source: Fakes.FakeSource(log: log, answer: .success((release, nil))),
        downloader: Fakes.FakeDownloader(log: log), unpacker: Fakes.FakeUnpacker(log: log),
        verifier: Fakes.FakeVerifier(log: log), installer: Fakes.FakeInstaller(log: log)),
      queue: DispatchQueue(label: "test.update-coordinator"))
  }

  private func coordinator(_ controller: UpdateController?) -> UpdateCoordinator {
    UpdateCoordinator(
      controller: controller,
      host: UpdateCoordinator.Host(
        alert: { [unowned self] in alerts.append($0) },
        activity: { UpdateApplyPolicy.Activity() },
        installAboutActions: { [unowned self] _ in aboutActions += 1 }))
  }

  func testEveryConfigurationLoadReconcilesAndTheAboutButtonIsWiredOnce() throws {
    // A build no release replaces never arms the automatic check.
    let updates = coordinator(try controller(identity: .certificate("Flash Dev")))
    updates.reconcile(.install)
    updates.reconcile(.check)
    updates.reconcile(.off)
    XCTAssertEqual(aboutActions, 1)
    let listed = expectation(description: "polls")
    PollScheduler.shared.registeredIDs { ids in
      XCTAssertFalse(ids.contains(UpdateCoordinator.checkPollID))
      listed.fulfill()
    }
    wait(for: [listed], timeout: 5)
    XCTAssertTrue(alerts.isEmpty)
  }

  func testACheckAnswersWithTheReleaseAndAsksNothingOfTheHost() throws {
    let updates = coordinator(try controller(identity: .adHoc))
    let answered = expectation(description: "check")
    updates.perform(.check) { outcome, text in
      dispatchPrecondition(condition: .onQueue(.main))
      XCTAssertEqual(outcome, .performed)
      XCTAssertEqual(
        text?.split(separator: "\n").first, "Flash 1.2.0 is available (this is 1.1.0).")
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
    XCTAssertTrue(alerts.isEmpty, "a command's answer is its own; nothing else is announced")
  }

  func testInstallIsRefusedForABuildNoReleaseReplaces() throws {
    let updates = coordinator(try controller(identity: .certificate("Flash Dev")))
    var answer: (NormalModeCommandOutcome, String?)?
    updates.perform(.install) { answer = ($0, $1) }
    XCTAssertEqual(answer?.0, .failed)
    XCTAssertTrue(answer?.1?.hasPrefix("Flash cannot update itself: ") ?? false)
  }

  func testWithoutAControllerEveryCommandSaysUpdatesAreUnavailable() {
    let updates = coordinator(nil)
    updates.reconcile(.install)
    XCTAssertEqual(aboutActions, 0)
    var answer: (NormalModeCommandOutcome, String?)?
    updates.perform(.check) { answer = ($0, $1) }
    XCTAssertEqual(answer?.0, .failed)
    XCTAssertEqual(answer?.1, "Updates are unavailable in this process.")
    updates.applyAtQuit()
  }
}
