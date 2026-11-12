import XCTest
@testable import BetterTeX

final class PaneSplitTests: XCTestCase {
    private let unbounded = CGFloat.greatestFiniteMagnitude

    func testWantedSizeIsKeptWithinLimits() {
        XCTAssertEqual(PaneSplitController.firstLength(available: 1000, wanted: 400, first: (160, unbounded), last: (180, unbounded)), 400)
        XCTAssertEqual(PaneSplitController.firstLength(available: 1000, wanted: 950, first: (160, unbounded), last: (180, unbounded)), 820)
        XCTAssertEqual(PaneSplitController.firstLength(available: 1000, wanted: 10, first: (160, unbounded), last: (180, unbounded)), 160)
        XCTAssertEqual(PaneSplitController.firstLength(available: 1000, wanted: 900, first: (140, 640), last: (400, unbounded)), 600)
    }

    func testConflictingMinimumsShareTheSpaceInsteadOfOverflowing() {
        // 360 + 240 do not fit in 500: each pane shrinks in proportion, and together they fill exactly the space.
        let first = PaneSplitController.firstLength(available: 500, wanted: 400, first: (360, unbounded), last: (240, unbounded))
        XCTAssertEqual(first, 300)
        XCTAssertLessThanOrEqual(first, 500)
    }
}
