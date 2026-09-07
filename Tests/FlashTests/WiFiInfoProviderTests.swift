import CoreLocation
import Foundation
import XCTest

@testable import flash

final class WiFiInfoProviderTests: XCTestCase {
  func testPassiveNotDeterminedReadResolvesAbsentWithoutPromptingOrRetention() {
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

    provider.fetchSSID(requestAuthorization: false) { replies.append($0) }

    XCTAssertEqual(replies.count, 1)
    XCTAssertNil(replies[0])
    XCTAssertEqual(authorizationRequests, 0)
    XCTAssertEqual(ssidReads, 0)

    status = .authorizedAlways

    XCTAssertEqual(replies.count, 1, "a passive read must not leave a pending callback")
    XCTAssertEqual(ssidReads, 0)
  }

  func testExplicitNotDeterminedReadsCanRetryAndReplyWithoutRetention() {
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

    provider.fetchSSID(requestAuthorization: true) { replies.append($0) }
    provider.fetchSSID(requestAuthorization: true) { replies.append($0) }
    provider.fetchSSID(requestAuthorization: true) { replies.append($0) }

    XCTAssertEqual(authorizationRequests, 3, "each explicit action can retry an ignored request")
    XCTAssertEqual(replies.count, 3)
    XCTAssertTrue(replies.allSatisfy { $0 == nil })
    XCTAssertEqual(ssidReads, 0, "SSID must not be read before authorization")

    status = .authorizedAlways
    provider.fetchSSID(requestAuthorization: false) { replies.append($0) }

    XCTAssertEqual(replies.count, 4)
    XCTAssertEqual(replies[3], "Studio")
    XCTAssertEqual(ssidReads, 1)
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

      provider.fetchSSID(requestAuthorization: false) {
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

      provider.fetchSSID(requestAuthorization: false) {
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

    provider.fetchSSID(requestAuthorization: false) { reply = $0 }

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
      provider.fetchSSID(requestAuthorization: false) { ssid in
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
