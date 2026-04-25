import XCTest
@testable import OpenScribeModels

final class LoopRegionTests: XCTestCase {

    func test_isValid_withValidRegion() {
        let region = LoopRegion(start: 1.0, end: 3.0)
        XCTAssertTrue(region.isValid(for: 5.0))
    }

    func test_isValid_startEqualsEnd_isFalse() {
        let region = LoopRegion(start: 2.0, end: 2.0)
        XCTAssertFalse(region.isValid(for: 5.0))
    }

    func test_isValid_endExceedsDuration_isFalse() {
        let region = LoopRegion(start: 1.0, end: 6.0)
        XCTAssertFalse(region.isValid(for: 5.0))
    }

    func test_isValid_negativeStart_isFalse() {
        let region = LoopRegion(start: -1.0, end: 2.0)
        XCTAssertFalse(region.isValid(for: 5.0))
    }

    func test_duration_isEndMinusStart() {
        let region = LoopRegion(start: 1.5, end: 4.0)
        XCTAssertEqual(region.duration, 2.5, accuracy: 0.001)
    }

    func test_clamped_clipsNegativeStart() {
        let region = LoopRegion(start: -2.0, end: 3.0).clamped(to: 5.0)
        XCTAssertEqual(region.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(region.end, 3.0, accuracy: 0.001)
    }

    func test_clamped_clipsEndBeyondDuration() {
        let region = LoopRegion(start: 1.0, end: 9.0).clamped(to: 5.0)
        XCTAssertEqual(region.end, 5.0, accuracy: 0.001)
    }

    func test_clamped_preservesValidRegion() {
        let region = LoopRegion(start: 1.0, end: 3.0).clamped(to: 5.0)
        XCTAssertEqual(region.start, 1.0, accuracy: 0.001)
        XCTAssertEqual(region.end, 3.0, accuracy: 0.001)
    }

    func test_equality() {
        let a = LoopRegion(start: 1.0, end: 3.0)
        let b = LoopRegion(start: 1.0, end: 3.0)
        let c = LoopRegion(start: 1.0, end: 4.0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
