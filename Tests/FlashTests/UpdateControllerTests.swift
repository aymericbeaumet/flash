import Foundation
import XCTest

@testable import flash

/// The updater over fake GitHub, downloads, archives, signatures and
/// installs, in a temporary folder: no test reaches the network or touches
/// a real bundle.
final class UpdateControllerTests: XCTestCase {
  final class Log {
    var events: [String] = []
  }

  final class FakeSource: UpdateReleaseSource {
    let log: Log
    var answer: Result<(release: UpdateRelease?, etag: String?), UpdateError>
    var hold = false
    var pending: [() -> Void] = []

    init(log: Log, answer: Result<(release: UpdateRelease?, etag: String?), UpdateError>) {
      self.log = log
      self.answer = answer
    }

    func latest(
      etag: String?,
      completion: @escaping (Result<(release: UpdateRelease?, etag: String?), UpdateError>) -> Void
    ) {
      log.events.append("fetch etag=\(etag ?? "-")")
      let answer = self.answer
      if hold { pending.append { completion(answer) } } else { completion(answer) }
    }
  }

  /// Writes `payload` as the downloaded archive.
  final class FakeDownloader: UpdateDownloading {
    let log: Log
    var payload = Data("release archive".utf8)

    init(log: Log) { self.log = log }

    func download(
      _ url: URL, to destination: URL, completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
      log.events.append("download \(url.lastPathComponent)")
      do {
        try payload.write(to: destination)
        completion(.success(()))
      } catch {
        completion(.failure(UpdateError("\(error)")))
      }
    }
  }

  /// Creates `Flash.app/Contents/Info.plist` where ditto would.
  final class FakeUnpacker: UpdateUnpacking {
    let log: Log
    var version = "1.2.0"

    init(log: Log) { self.log = log }

    func unpack(_ archive: URL, into directory: URL) -> Result<URL, UpdateError> {
      log.events.append("unpack")
      let app = directory.appendingPathComponent("Flash.app")
      try? FakeUnpacker.makeBundle(at: app, version: version)
      return .success(app)
    }

    static func makeBundle(at app: URL, version: String) throws {
      let contents = app.appendingPathComponent("Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      let info: NSDictionary = [
        "CFBundleIdentifier": "com.flash.app", "CFBundleShortVersionString": version,
      ]
      info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }
  }

  final class FakeVerifier: UpdateBundleVerifying {
    let log: Log
    var refuse: String?

    init(log: Log) { self.log = log }

    func verify(_ bundle: URL, release: UpdateRelease, identity: BuildIdentity) -> Result<
      Void, UpdateError
    > {
      log.events.append("verify \(release.version)")
      if let refuse { return .failure(UpdateError(refuse)) }
      return .success(())
    }
  }

  /// A real swap, of two folders in the temporary directory.
  final class FakeInstaller: UpdateInstalling {
    let log: Log
    var replaceable = true

    init(log: Log) { self.log = log }

    func canReplace(_ bundle: URL) -> Bool { replaceable }

    func swap(_ staged: URL, with installed: URL) -> Result<Void, UpdateError> {
      log.events.append("swap")
      return BundleSwapInstaller().swap(staged, with: installed)
    }

    func register(_ bundle: URL) { log.events.append("register") }

    func sameVolume(_ a: URL, _ b: URL) -> Bool { true }
  }

  private let log = Log()
  private var root: URL!
  private lazy var source = FakeSource(log: log, answer: .success((release, "W/\"one\"")))
  private lazy var downloader = FakeDownloader(log: log)
  private lazy var unpacker = FakeUnpacker(log: log)
  private lazy var verifier = FakeVerifier(log: log)
  private lazy var installer = FakeInstaller(log: log)

  private lazy var release = UpdateRelease(
    version: "1.2.0", assetName: "Flash-1.2.0.zip",
    downloadURL: URL(string: "https://github.com/x/Flash-1.2.0.zip")!,
    sha256: UpdateRelease.sha256(of: archiveFixture)!, size: 15, pageURL: nil)

  private lazy var archiveFixture: URL = {
    let file = root.appendingPathComponent("fixture.zip")
    try! Data("release archive".utf8).write(to: file)
    return file
  }()

  private var bundle: URL { root.appendingPathComponent("Applications/Flash.app") }
  private var updatesDirectory: URL { root.appendingPathComponent("Updates") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flash-updates-\(UUID().uuidString)")
    try FakeUnpacker.makeBundle(at: bundle, version: "1.1.0")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func controller(identity: BuildIdentity = .adHoc, version: String = "1.1.0")
    -> UpdateController
  {
    UpdateController(
      environment: .init(
        currentVersion: version, bundleURL: bundle, identity: identity,
        directory: updatesDirectory, source: source, downloader: downloader,
        unpacker: unpacker, verifier: verifier, installer: installer),
      queue: DispatchQueue(label: "test.updates"))
  }

  private func check(_ updater: UpdateController, mode: UpdateMode = .install, prepare: Bool = true)
    -> UpdateCheckReport
  {
    var report: UpdateCheckReport?
    updater.check(mode: mode, prepare: prepare) { report = $0 }
    // Each step (the answer, the download) hops back onto the queue.
    for _ in 0..<10 where report == nil { updater.drain() }
    return report!
  }

  private func installedVersion() -> String? {
    NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?[
      "CFBundleShortVersionString"] as? String
  }

  func testANewerReleaseIsDownloadedVerifiedAndStaged() {
    let updater = controller()
    let report = check(updater)
    XCTAssertEqual(report.status, .ready(release))
    XCTAssertEqual(
      log.events, ["fetch etag=-", "download Flash-1.2.0.zip", "unpack", "verify 1.2.0"])
    XCTAssertEqual(updater.snapshot.staged, "1.2.0")
    XCTAssertEqual(updater.snapshot.etag, "W/\"one\"")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: updater.stagedBundle(for: "1.2.0").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: updater.stagingDirectory(for: "1.2.0").appendingPathComponent(
          "Flash-1.2.0.zip"
        ).path), "the archive goes once unpacked")
    // Checking again finds it staged and downloads nothing.
    log.events.removeAll()
    XCTAssertEqual(check(updater).status, .ready(release))
    XCTAssertEqual(log.events, ["fetch etag=W/\"one\""])
  }

  func testADownloadThatIsNotWhatGitHubPublishedIsRefused() {
    downloader.payload = Data("tampered".utf8)
    let updater = controller()
    guard case .failed(let reason) = check(updater).status else { return XCTFail() }
    XCTAssertTrue(reason.contains("SHA-256"), reason)
    XCTAssertFalse(log.events.contains("unpack"), "nothing unverified is unpacked")
    XCTAssertNil(updater.snapshot.staged)
    updater.drain()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: updater.stagingDirectory(for: "1.2.0").path))
  }

  func testABundleThatFailsItsSignatureCheckIsNotStaged() {
    verifier.refuse = "the bundle's signature does not hold"
    let updater = controller()
    guard case .failed(let reason) = check(updater).status else { return XCTFail() }
    XCTAssertTrue(reason.contains("signature"), reason)
    XCTAssertNil(updater.snapshot.staged)
  }

  func testNotModifiedReusesTheCachedRelease() {
    let updater = controller()
    _ = check(updater, mode: .check, prepare: false)
    source.answer = .success((nil, "W/\"one\""))
    log.events.removeAll()
    XCTAssertEqual(check(updater, mode: .check, prepare: false).status, .available(release))
    XCTAssertEqual(log.events, ["fetch etag=W/\"one\""])
  }

  func testCheckModeAndBuildsNoReleaseReplacesNeverDownload() {
    XCTAssertEqual(check(controller(), mode: .check, prepare: false).status, .available(release))
    XCTAssertFalse(log.events.contains { $0.hasPrefix("download") })
    let dev = controller(identity: .certificate("Flash Dev"))
    XCTAssertEqual(check(dev).status, .available(release))
    XCTAssertFalse(log.events.contains { $0.hasPrefix("download") })
  }

  func testUpToDateDiscardsAnOlderStagedRelease() {
    let updater = controller()
    _ = check(updater)
    let caughtUp = controller(version: "1.2.0")
    XCTAssertEqual(check(caughtUp).status, .upToDate)
    XCTAssertNil(caughtUp.snapshot.staged)
  }

  func testAFailedCheckSaysWhy() {
    source.answer = .failure(UpdateError("offline"))
    let report = check(controller())
    XCTAssertEqual(report.status, .failed("offline"))
    XCTAssertFalse(report.succeeded)
  }

  func testConcurrentChecksShareOneRequest() {
    source.hold = true
    let updater = controller()
    // Completions run on the controller's queue; the count is read on main.
    let lock = NSLock()
    var reports: [UpdateCheckReport] = []
    let record: (UpdateCheckReport) -> Void = { report in lock.withLock { reports.append(report) } }
    let count = { lock.withLock { reports.count } }
    updater.check(mode: .check, prepare: false, completion: record)
    updater.check(mode: .check, prepare: false, completion: record)
    updater.drain()
    XCTAssertEqual(log.events, ["fetch etag=-"])
    for completion in source.pending { completion() }
    for _ in 0..<10 where count() < 2 { updater.drain() }
    XCTAssertEqual(count(), 2)
  }

  func testInstallSwapsTheStagedBundleInAndKeepsTheOldOneAside() throws {
    let updater = controller()
    _ = check(updater)
    log.events.removeAll()
    XCTAssertEqual(try updater.install().get(), release)
    XCTAssertEqual(log.events, ["verify 1.2.0", "swap", "register"], "verified again first")
    XCTAssertEqual(installedVersion(), "1.2.0")
    let aside = NSDictionary(
      contentsOf: updater.stagedBundle(for: "1.2.0").appendingPathComponent("Contents/Info.plist"))
    XCTAssertEqual(aside?["CFBundleShortVersionString"] as? String, "1.1.0", "the old bundle")
    XCTAssertNil(updater.snapshot.staged)
    XCTAssertEqual(updater.snapshot.installed, "1.2.0")
  }

  func testInstallRefusesWithoutAStagedUpdateAReplaceableBundleOrAReleaseBuild() {
    XCTAssertEqual(
      controller().install().failureReason, "no update is downloaded")
    let updater = controller()
    _ = check(updater)
    installer.replaceable = false
    XCTAssertTrue(updater.install().failureReason?.contains("cannot be replaced") == true)
    XCTAssertEqual(installedVersion(), "1.1.0")
    let dev = controller(identity: .certificate("Flash Dev"))
    XCTAssertTrue(dev.install().failureReason?.contains("Flash Dev") == true)
  }

  func testAStagedBundleThatNoLongerVerifiesIsDiscardedNotInstalled() {
    let updater = controller()
    _ = check(updater)
    verifier.refuse = "changed on disk"
    XCTAssertEqual(updater.install().failureReason, "changed on disk")
    XCTAssertNil(updater.snapshot.staged)
    XCTAssertEqual(installedVersion(), "1.1.0")
  }

  func testTheNewVersionCleansUpAndGreetsOnce() throws {
    let updater = controller()
    _ = check(updater)
    _ = try updater.install().get()
    try Data().write(to: updatesDirectory.appendingPathComponent("abandoned.zip"))
    let relaunched = controller(version: "1.2.0")
    var greeting: String??
    relaunched.settle { greeting = $0 }
    relaunched.drain()
    XCTAssertEqual(greeting, .some("1.2.0"))
    let left = try FileManager.default.contentsOfDirectory(atPath: updatesDirectory.path)
    XCTAssertEqual(left, ["state.json"], "the replaced bundle and leftovers are gone")
    relaunched.settle { greeting = $0 }
    relaunched.drain()
    XCTAssertEqual(greeting, .some(nil), "greets once")
  }

  func testSettlingKeepsAStagedUpdateStillNewer() {
    let updater = controller()
    _ = check(updater)
    updater.settle { _ in }
    updater.drain()
    XCTAssertEqual(updater.snapshot.staged, "1.2.0")
    XCTAssertNotNil(updater.stagedRelease)
  }

  func testEachReleaseIsAnnouncedOnce() {
    let updater = controller()
    XCTAssertTrue(updater.markAnnounced("1.2.0"))
    XCTAssertFalse(updater.markAnnounced("1.2.0"))
    XCTAssertTrue(controller().markAnnounced("1.3.0"), "persisted per version")
    XCTAssertFalse(controller().markAnnounced("1.3.0"))
  }

  // MARK: Relaunch

  func testARelaunchedResidentWaitsForTheOldOnesLock() {
    let url = root.appendingPathComponent("resident.lock")
    final class Holder: @unchecked Sendable { var lock: ResidentLock? }
    let holder = Holder()
    // Only the holder keeps the old resident's lock alive.
    if case .acquired(let lock) = ResidentLock.acquire(at: url) { holder.lock = lock }
    XCTAssertNotNil(holder.lock)
    guard case .heldByAnother = ResidentLock.acquire(at: url) else {
      return XCTFail("a plain launch exits as a duplicate")
    }
    let released = expectation(description: "old resident quit")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
      holder.lock = nil
      released.fulfill()
    }
    guard case .acquired = ResidentLock.acquire(at: url, waitingUpTo: 5) else {
      return XCTFail("the relaunched resident takes over once the old one let go")
    }
    wait(for: [released], timeout: 2)
  }

  func testBuildIdentityReadsTheSignature() {
    XCTAssertEqual(BuildIdentity.classify(signingInformation: [:]), .unsigned)
    XCTAssertEqual(
      BuildIdentity.classify(signingInformation: [
        kSecCodeInfoIdentifier as String: "com.flash.app",
        kSecCodeInfoFlags as String: NSNumber(value: BuildIdentity.adHocFlag),
      ]), .adHoc)
    XCTAssertEqual(
      BuildIdentity.classify(signingInformation: [
        kSecCodeInfoIdentifier as String: "com.flash.app",
        kSecCodeInfoTeamIdentifier as String: "ABCDE12345",
        kSecCodeInfoFlags as String: NSNumber(value: 0),
      ]), .certificate("an unknown certificate"),
      "a team without a Developer ID leaf is not trusted to keep permissions")
    XCTAssertEqual(BuildIdentity.current, .notBundled, "the test runner is no app bundle")
  }
}

extension Result {
  fileprivate var failureReason: String? {
    if case .failure(let error) = self { return "\(error)" }
    return nil
  }
}
