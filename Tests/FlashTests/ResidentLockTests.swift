import XCTest

@testable import flash

final class ResidentLockTests: XCTestCase {
  func testASecondResidentFindsTheLockHeldUntilTheFirstReleasesIt() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-resident-lock-\(UUID().uuidString)")
      .appendingPathComponent("resident.lock")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    {
      guard case .acquired(let first) = ResidentLock.acquire(at: url) else {
        return XCTFail("the first resident takes the lock")
      }
      guard case .heldByAnother(let holder) = ResidentLock.acquire(at: url) else {
        return XCTFail("a second resident must not take a held lock")
      }
      XCTAssertEqual(holder, getpid())
      withExtendedLifetime(first) {}
    }()

    guard case .acquired = ResidentLock.acquire(at: url) else {
      return XCTFail("the lock is free once its holder is gone")
    }
  }
}
