import XCTest
@testable import flash
import FlashCore

final class HintAssignerTests: XCTestCase {
    private let alphabet: [Character] = Array("arstneio")

    func testPrefixFreeSmall() {
        check(count: 1)
        check(count: 5)
        check(count: 8)
        check(count: 26)
        check(count: 200)
        check(count: 1000)
    }

    func testUniqueLabels() {
        let labels = HintAssigner.generateLabels(count: 200, alphabet: alphabet)
        XCTAssertEqual(labels.count, 200)
        XCTAssertEqual(Set(labels).count, 200)
    }

    func testMinLengthRespected() {
        let labels = HintAssigner.generateLabels(count: 3, alphabet: alphabet, minLength: 2)
        XCTAssertTrue(labels.allSatisfy { $0.count >= 2 })
    }

    func testEmpty() {
        XCTAssertTrue(HintAssigner.generateLabels(count: 0, alphabet: alphabet).isEmpty)
    }

    private func check(count: Int) {
        let labels = HintAssigner.generateLabels(count: count, alphabet: alphabet)
        XCTAssertEqual(labels.count, count, "expected \(count) labels")
        XCTAssertEqual(Set(labels).count, count, "labels should be unique")
        for (i, a) in labels.enumerated() {
            for (j, b) in labels.enumerated() where i != j {
                XCTAssertFalse(a.hasPrefix(b), "label \(a) at \(i) starts with label \(b) at \(j)")
            }
        }
    }
}
