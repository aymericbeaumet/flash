import XCTest

@testable import flash

/// The volume scale `host.audio_devices` steps on. No test touches the Mac's
/// real devices: the arithmetic is pure.
final class CoreAudioDevicesTests: XCTestCase {
  /// One step is one macOS volume-key tick: 16 between silence and full,
  /// drawn as the bezel's rounded percent.
  func testVolumeStepsLandOnTheBezelTicks() {
    let bezel = [0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 63, 69, 75, 81, 88, 94, 100]
    for (index, percent) in bezel.enumerated() {
      XCTAssertEqual(CoreAudioDevices.volumePercent(Float(index) / 16), percent, "tick \(index)")
    }
    var up = Float(0)
    for percent in bezel.dropFirst() {
      up = CoreAudioDevices.nativeVolume(up, direction: 1)
      XCTAssertEqual(CoreAudioDevices.volumePercent(up), percent)
    }
    XCTAssertEqual(CoreAudioDevices.nativeVolume(1, direction: 1), 1, accuracy: 0.0001)
    var down = Float(1)
    for percent in bezel.dropLast().reversed() {
      down = CoreAudioDevices.nativeVolume(down, direction: -1)
      XCTAssertEqual(CoreAudioDevices.volumePercent(down), percent)
    }
    XCTAssertEqual(CoreAudioDevices.nativeVolume(0, direction: -1), 0, accuracy: 0.0001)
    XCTAssertEqual(
      CoreAudioDevices.volumePercent(CoreAudioDevices.nativeVolume(0.40, direction: 1)), 44)
    XCTAssertEqual(
      CoreAudioDevices.volumePercent(CoreAudioDevices.nativeVolume(0.40, direction: -1)), 38)
  }

  /// Several ticks at once land where that many single steps do, and never
  /// past either end.
  func testAStepOfSeveralTicksIsThatManySingleSteps() {
    func percent(_ scalar: Float, _ ticks: Int) -> Int {
      CoreAudioDevices.volumePercent(CoreAudioDevices.nativeVolume(scalar, ticks: ticks))
    }
    XCTAssertEqual(percent(0.375, 2), 50)
    XCTAssertEqual(percent(0.40, 2), 50, "the first step lands on the neighbouring tick")
    XCTAssertEqual(percent(0.40, -2), 31)
    XCTAssertEqual(CoreAudioDevices.nativeVolume(0.5, ticks: 99), 1, accuracy: 0.0001)
    XCTAssertEqual(CoreAudioDevices.nativeVolume(0.5, ticks: -99), 0, accuracy: 0.0001)
  }
}
