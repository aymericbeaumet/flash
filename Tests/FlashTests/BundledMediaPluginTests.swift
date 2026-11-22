import FlashCore
import XCTest

@testable import flash

/// The built `media` plugin, spawned under its sandbox profile by a real
/// `PluginManager`: its commands cross the wire, reach the host's audio and
/// AppleScript RPCs, and come back as the result the resident presents.
/// CoreAudio and the AppleScript runner are stubs, so no test here touches
/// the Mac's devices or a player.
final class BundledMediaPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!
  private let devices = AudioDeviceStub()
  private let scripts = Scripts()

  /// The scripts the host was asked to run, in order.
  private final class Scripts {
    private let lock = NSLock()
    private var sources: [String] = []

    func run(_ source: String) -> AppleScriptOutput {
      lock.lock()
      sources.append(source)
      lock.unlock()
      return AppleScriptOutput(
        status: 0, stdout: "playing\nOne More Time — Daft Punk\n", stderr: "")
    }

    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return sources
    }
  }

  override func setUpWithError() throws {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "media" })
    let binary = root.appendingPathComponent("flash-plugin-media").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the media plugin must be built")
      }
      throw XCTSkip("media is not built: run `mise run build:plugins`")
    }
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-media-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    manager.hostRPC.audioDevices = devices
    manager.hostRPC.appleScriptRunner = { [scripts] source, _ in scripts.run(source) }
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["media"])
    config.plugins.watchingEnabled = false
    manager.start(config: config)
    waitUntilTrue("media running") {
      self.manager.pluginStatuses().first { $0.id == "media" }?.state == "running"
    }
  }

  override func tearDown() {
    manager?.stop()
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private func run(
    _ command: String, _ subcommand: String, _ args: [String] = [], count: Int = 1
  ) -> PluginCommandResult {
    let answered = expectation(description: "\(command) \(subcommand)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: command, subcommand: subcommand, args: args, count: count) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  /// `3` then volume-up is one request and one CoreAudio step of three
  /// ticks, answered with the percent alert and the line the CLI prints.
  func testACountedVolumeStepIsOneMoveShownAsThePercentAlert() {
    let up = run("volume", "up", count: 3)
    XCTAssertEqual(
      up,
      PluginCommandResult(
        ok: true, message: "volume 56%",
        alert: PluginAlert(title: "volume", value: "56%", widestValue: "100%")))
    let down = run("volume", "down")
    XCTAssertEqual(down.alert?.value, "50%")
    XCTAssertEqual(run("volume", "mute"), PluginCommandResult(ok: true))
    XCTAssertEqual(devices.calls, ["step 3", "step -1", "mute"])
    XCTAssertTrue(devices.muted)
  }

  func testDevicesListAndSelectAndAFailureSaysWhy() {
    XCTAssertEqual(
      run("audio", "output").message,
      "* MacBook Pro Speakers [built-in]\n  USB Audio [usb-1]")
    // The name is one argument, whatever words it holds.
    XCTAssertEqual(
      run("audio", "input", ["--device=USB Audio"]),
      PluginCommandResult(ok: true, message: "input device: USB Audio"))
    XCTAssertEqual(devices.devices[.input]?.first { $0.isDefault }?.uid, "usb-1")
    XCTAssertEqual(devices.devices[.output]?.first { $0.isDefault }?.uid, "built-in")

    let missing = run("audio", "output", ["--device=Studio"])
    XCTAssertEqual(
      missing, PluginCommandResult(ok: false, error: "audio device not found: Studio"))
    XCTAssertEqual(missing.failureAlert, "audio device not found: Studio")
    // What the commands do not declare reaches no device.
    for (command, subcommand, args) in [
      ("volume", "up", ["--steps=2"]), ("audio", "input", ["--device=USB", "Audio"]),
      ("audio", "output", ["--device="]), ("media", "status", ["--json"]),
    ] {
      XCTAssertEqual(
        run(command, subcommand, args),
        PluginCommandResult(
          ok: false,
          error: "unknown command or invalid arguments: "
            + ([command, subcommand] + args).joined(separator: " ")), "\(args)")
    }
    XCTAssertEqual(
      devices.calls, ["list output", "list input", "select input usb-1", "list output"])
  }

  /// Only a running player is asked, through the host's fixed template and
  /// the manifest's Apple Events targets.
  func testStatusAsksTheRunningPlayersThroughTheHost() {
    XCTAssertEqual(run("media", "status").message, "no media app is running\nvolume 38%")
    XCTAssertEqual(scripts.all, [], "no player runs: no app is asked")

    manager.emitRunningApplicationsChanged {
      [
        ["bundle_id": "com.spotify.client", "pid": 4242, "localized_name": "Spotify"],
        ["bundle_id": "com.apple.Safari", "pid": 4243, "localized_name": "Safari"],
      ]
    }
    var status = ""
    waitUntilTrue("the plugin hears which apps run") {
      status = self.run("media", "status").message ?? ""
      return status.hasPrefix("Spotify")
    }
    XCTAssertEqual(status, "Spotify [playing]: One More Time — Daft Punk\nvolume 38%")
    let asked = scripts.all
    XCTAssertEqual(asked.count, 1)
    XCTAssertTrue(asked[0].contains("tell application id \"com.spotify.client\""))
    XCTAssertTrue(asked[0].contains("artist of current track"))
  }
}
