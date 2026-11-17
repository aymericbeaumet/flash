import Foundation
import XCTest

@testable import flash

/// The updater's pure decisions: which release, which version is newer,
/// which digest, which build may install it, and when.
final class UpdateModelTests: XCTestCase {
  private let digest = "sha256:" + String(repeating: "ab", count: 32)

  private func latest(
    tag: String = "1.2.0", prerelease: Bool = false, draft: Bool = false,
    assets: [[String: Any]]? = nil
  ) -> Data {
    let assets =
      assets ?? [
        [
          "name": "Flash-\(tag).zip", "size": 35_122_241, "digest": digest,
          "browser_download_url":
            "https://github.com/aymericbeaumet/flash/releases/download/\(tag)/Flash-\(tag).zip",
        ]
      ]
    let object: [String: Any] = [
      "tag_name": tag, "prerelease": prerelease, "draft": draft, "assets": assets,
      "html_url": "https://github.com/aymericbeaumet/flash/releases/tag/\(tag)",
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func testVersionsCompareNumericallyAndRejectNonVersions() {
    let v = { SemanticVersion($0)! }
    XCTAssertLessThan(v("1.1.0"), v("1.2.0"))
    XCTAssertLessThan(v("1.9.0"), v("1.10.0"), "numeric, not lexical")
    XCTAssertEqual(v("1.2"), v("1.2.0"))
    XCTAssertEqual(Set([v("1.2"), v("1.2.0")]).count, 1)
    XCTAssertLessThan(v("1.2.0"), v("2"))
    XCTAssertEqual(v("v1.0.0"), v("1.0.0"))
    for raw in ["nightly-20260627-97fd2048", "1.2.0-beta", "", "1..2", "1.2.3.4.5", "١.٢"] {
      XCTAssertNil(SemanticVersion(raw), raw)
    }
  }

  func testTheLatestStableReleaseCarriesItsAssetAndDigest() throws {
    let release = try UpdateRelease.parse(latest: latest()).get()
    XCTAssertEqual(release.version, "1.2.0")
    XCTAssertEqual(release.assetName, "Flash-1.2.0.zip")
    XCTAssertEqual(release.sha256, String(repeating: "ab", count: 32))
    XCTAssertEqual(release.size, 35_122_241)
    XCTAssertEqual(release.downloadURL.host, "github.com")
  }

  func testAnythingButAStableReleaseWithItsDigestIsRefused() {
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(prerelease: true)), .failure(.notStable("1.2.0")))
    XCTAssertEqual(UpdateRelease.parse(latest: latest(draft: true)), .failure(.notStable("1.2.0")))
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(tag: "nightly-20260627-97fd2048")),
      .failure(.noVersion("nightly-20260627-97fd2048")))
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(tag: "v1.2.0")), .failure(.noVersion("v1.2.0")))
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(assets: [])), .failure(.noAsset("Flash-1.2.0.zip")))
    let noDigest: [[String: Any]] = [
      [
        "name": "Flash-1.2.0.zip",
        "browser_download_url": "https://github.com/x/Flash-1.2.0.zip",
      ]
    ]
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(assets: noDigest)), .failure(.noDigest("Flash-1.2.0.zip")))
    let plainHTTP: [[String: Any]] = [
      ["name": "Flash-1.2.0.zip", "digest": digest, "browser_download_url": "http://x/y.zip"]
    ]
    XCTAssertEqual(
      UpdateRelease.parse(latest: latest(assets: plainHTTP)), .failure(.noAsset("Flash-1.2.0.zip")))
    XCTAssertEqual(UpdateRelease.parse(latest: Data("[]".utf8)), .failure(.malformed))
  }

  func testOnlyASHA256DigestIsAccepted() {
    XCTAssertEqual(
      UpdateRelease.sha256(
        digest: digest.uppercased().replacingOccurrences(
          of: "SHA256:", with: "sha256:")), String(repeating: "ab", count: 32))
    XCTAssertNil(UpdateRelease.sha256(digest: "md5:" + String(repeating: "a", count: 32)))
    XCTAssertNil(UpdateRelease.sha256(digest: "sha256:abc"))
    XCTAssertNil(UpdateRelease.sha256(digest: "sha256:" + String(repeating: "zz", count: 32)))
  }

  func testAFileDigestIsItsSHA256() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("flash".utf8).write(to: file)
    // `printf flash | shasum -a 256`
    XCTAssertEqual(
      UpdateRelease.sha256(of: file),
      "851e43bd44a2c3d30e5f3acadc9240c12d9f1c610dba34761e8c47ba82d1daea")
    XCTAssertNil(UpdateRelease.sha256(of: file.appendingPathExtension("missing")))
  }

  func testOnlyABuildAReleaseCanReplaceInstallsAndOnlyDeveloperIDSilently() {
    XCTAssertEqual(BuildIdentity.developerID(team: "ABCDE12345").installability, .keepsPermissions)
    XCTAssertEqual(BuildIdentity.adHoc.installability, .resetsPermissions)
    for identity in [BuildIdentity.certificate("Flash Dev"), .notBundled, .unsigned] {
      guard case .never = identity.installability else { return XCTFail("\(identity)") }
      XCTAssertFalse(identity.checksAutomatically, "a development build never checks")
    }
    XCTAssertTrue(BuildIdentity.adHoc.checksAutomatically)
  }

  func testAStagedUpdateAppliesItselfOnlyWhileNobodyIsWorking() {
    let developer = BuildIdentity.developerID(team: "ABCDE12345")
    let idle = UpdateApplyPolicy.Activity()
    func applies(
      _ trigger: UpdateApplyPolicy.Trigger, _ mode: UpdateMode = .install,
      _ identity: BuildIdentity? = nil, _ activity: UpdateApplyPolicy.Activity? = nil
    ) -> Bool {
      UpdateApplyPolicy.appliesAutomatically(
        trigger, mode: mode, identity: identity ?? developer, activity: activity ?? idle)
    }
    XCTAssertTrue(applies(.away))
    XCTAssertTrue(applies(.quit))
    XCTAssertFalse(applies(.away, .check))
    XCTAssertFalse(applies(.quit, .off))
    XCTAssertFalse(applies(.away, .install, .adHoc), "an ad-hoc build asks first")
    XCTAssertFalse(applies(.quit, .install, .adHoc))
    XCTAssertFalse(applies(.away, .install, .certificate("Flash Dev")))
    for busy in [
      UpdateApplyPolicy.Activity(hintSession: true), .init(popup: true),
      .init(commandLine: true), .init(holdingButton: true),
    ] {
      XCTAssertFalse(applies(.away, .install, developer, busy), "\(busy)")
      XCTAssertTrue(applies(.quit, .install, developer, busy), "quitting interrupts nothing")
    }
    XCTAssertEqual(UpdateApplyPolicy.nextCheckDelayMs(succeeded: true), 86_400_000)
    XCTAssertEqual(UpdateApplyPolicy.nextCheckDelayMs(succeeded: false), 3_600_000)
  }

  func testTheReportSaysWhatInstallingMeansForThisBuild() throws {
    let release = try UpdateRelease.parse(latest: latest()).get()
    let report = { (status: UpdateCheckReport.Status, identity: BuildIdentity) in
      UpdateCheckReport(current: "1.1.0", status: status, identity: identity, mode: .install)
    }
    XCTAssertEqual(report(.upToDate, .adHoc).text, "Flash 1.1.0 is up to date.")
    let adHoc = report(.available(release), .adHoc)
    XCTAssertEqual(adHoc.installable, release)
    XCTAssertTrue(adHoc.text.contains("Accessibility again"), adHoc.text)
    let staged = report(.ready(release), .developerID(team: "ABCDE12345"))
    XCTAssertTrue(staged.text.contains("installs when you quit Flash or lock the screen"))
    let dev = report(.available(release), .certificate("Flash Dev"))
    XCTAssertNil(dev.installable)
    XCTAssertTrue(dev.text.contains("mise run install:dev"), dev.text)
    XCTAssertFalse(report(.failed("offline"), .adHoc).succeeded)
    XCTAssertEqual(adHoc.summary, "Flash 1.2.0 is available (this is 1.1.0).")
  }

  func testTheStateRoundTrips() throws {
    var state = UpdateState()
    state.etag = "W/\"abc\""
    state.latest = try UpdateRelease.parse(latest: latest()).get()
    state.checkedAt = Date(timeIntervalSince1970: 1_792_000_000)
    state.staged = "1.2.0"
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(UpdateState.self, from: data), state)
  }

  // MARK: Configuration and commands

  func testAppUpdatesDefaultsToInstallAndRejectsAnythingElse() throws {
    XCTAssertEqual(Config.default.app.updates, .install)
    XCTAssertEqual(ConfigLoader.parse("[app]\nupdates = \"off\"").app.updates, .off)
    XCTAssertEqual(ConfigLoader.parse("[app]\nupdates = \"check\"").app.updates, .check)
    let bad = ConfigLoader.parse("[app]\nupdates = \"auto\"")
    XCTAssertEqual(bad.app.updates, .install, "an invalid value keeps the default")
    XCTAssertTrue(
      bad.loadingDiagnostics.contains { $0.message.contains("app.updates") },
      "\(bad.loadingDiagnostics.map(\.message))")
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = ConfigLoader.parse(
      try String(contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8))
    XCTAssertEqual(bundled.app, Config.default.app, "config.default.toml states the default")
  }

  func testTheUpdatesCommandsAreCanonicalCommands() {
    XCTAssertEqual(URLEventHandler.parse(words: ["updates", "check"]), .updates(.check))
    XCTAssertEqual(URLEventHandler.parse(words: ["updates", "install"]), .updates(.install))
    XCTAssertNil(URLEventHandler.parse(words: ["updates", "check", "--now"]))
    XCTAssertEqual(URLCommand.updates(.install).argv, ["flash", "updates", "install"])
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(
        ":up", inventory: NormalModeDispatcher.CommandLineInventory.core()),
      .commands([.save]), "vim's :up[date] still saves")
  }
}
