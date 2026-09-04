import CoreLocation
import Foundation
import XCTest

@testable import flash

final class WiFiInfoProviderTests: XCTestCase {
  func testNotDeterminedCoalescesRequestsAndResolvesTheBatchAfterAuthorization() {
    var status = CLAuthorizationStatus.notDetermined
    var authorizationRequests = 0
    var ssidReads = 0
    let provider = WiFiInfoProvider(
      authorizationStatus: { status },
      requestAuthorization: { authorizationRequests += 1 },
      readSSID: {
        ssidReads += 1
        return "Studio"
      })
    var replies: [String?] = []

    provider.fetchSSID { replies.append($0) }
    provider.fetchSSID { replies.append($0) }
    provider.authorizationDidChange()
    provider.fetchSSID { replies.append($0) }

    XCTAssertEqual(authorizationRequests, 1, "one system prompt can serve every pending caller")
    XCTAssertTrue(replies.isEmpty)
    XCTAssertEqual(ssidReads, 0, "SSID must not be read before authorization")

    status = .authorizedAlways
    provider.authorizationDidChange()

    XCTAssertEqual(replies.count, 3)
    XCTAssertEqual(replies[0], "Studio")
    XCTAssertEqual(replies[1], "Studio")
    XCTAssertEqual(replies[2], "Studio")
    XCTAssertEqual(ssidReads, 1, "one authorized read resolves the complete pending batch")
  }

  func testDeniedAndRestrictedResolveAbsentWithoutReadingSSID() {
    for deniedStatus in [CLAuthorizationStatus.denied, .restricted] {
      var authorizationRequests = 0
      var ssidReads = 0
      var replyCount = 0
      let provider = WiFiInfoProvider(
        authorizationStatus: { deniedStatus },
        requestAuthorization: { authorizationRequests += 1 },
        readSSID: {
          ssidReads += 1
          return "must-not-be-read"
        })
      var reply: String?

      provider.fetchSSID {
        replyCount += 1
        reply = $0
      }

      XCTAssertNil(reply)
      XCTAssertEqual(replyCount, 1)
      XCTAssertEqual(authorizationRequests, 0)
      XCTAssertEqual(ssidReads, 0)
    }
  }

  func testAuthorizedNilOrEmptySSIDResolvesAbsent() {
    for rawSSID in [nil, ""] as [String?] {
      var replyCount = 0
      let provider = WiFiInfoProvider(
        authorizationStatus: { .authorizedAlways },
        requestAuthorization: { XCTFail("already authorized") },
        readSSID: { rawSSID })
      var reply: String?

      provider.fetchSSID {
        replyCount += 1
        reply = $0
      }

      XCTAssertNil(reply)
      XCTAssertEqual(replyCount, 1)
    }
  }

  func testAuthorizedSSIDIsReturnedExactly() {
    let provider = WiFiInfoProvider(
      authorizationStatus: { .authorizedAlways },
      requestAuthorization: { XCTFail("already authorized") },
      readSSID: { " Studio " })
    var reply: String?

    provider.fetchSSID { reply = $0 }

    XCTAssertEqual(reply, " Studio ")
  }

  func testProviderSerializesFrameworkAccessAndReplyOntoMainThread() {
    let replyExpectation = expectation(description: "SSID reply")
    let provider = WiFiInfoProvider(
      authorizationStatus: {
        XCTAssertTrue(Thread.isMainThread)
        return .authorizedAlways
      },
      requestAuthorization: { XCTFail("already authorized") },
      readSSID: {
        XCTAssertTrue(Thread.isMainThread)
        return "Studio"
      })

    DispatchQueue.global(qos: .userInitiated).async {
      provider.fetchSSID { ssid in
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(ssid, "Studio")
        replyExpectation.fulfill()
      }
    }

    wait(for: [replyExpectation], timeout: 2)
  }

  func testInfoPlistExplainsTheSSIDLocationPermission() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: url)
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    let explanation = try XCTUnwrap(plist["NSLocationUsageDescription"] as? String)
    XCTAssertTrue(explanation.localizedCaseInsensitiveContains("Wi-Fi"))
  }
}
