import AppKit
import XCTest
@testable import BetterTeX

final class TransferBarTests: XCTestCase {
    @MainActor func testWaitingThenFillingThenHidden() {
        let bar = TransferBar()
        XCTAssertTrue(bar.isHidden)

        bar.state = .waiting
        XCTAssertFalse(bar.isHidden); XCTAssertTrue(bar.isIndeterminate)

        bar.state = .fraction(0.42)
        XCTAssertFalse(bar.isIndeterminate); XCTAssertEqual(bar.doubleValue, 0.42, accuracy: 0.0001)
        bar.state = .fraction(1.7)
        XCTAssertEqual(bar.doubleValue, 1, accuracy: 0.0001)

        bar.state = .hidden
        let gone = expectation(description: "bar fades out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertTrue(bar.isHidden)
    }
}
