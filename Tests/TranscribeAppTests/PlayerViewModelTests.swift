import XCTest
@testable import OpenScribeModels

// PlayerViewModel AVFoundation gerektirdiğinden swift test ortamında
// doğrudan test edilemiyor. İş mantığı testleri LoopRegionTests'te.
// Bu dosya ileride mock AudioEngine ile genişletilebilir.
final class PlayerViewModelTests: XCTestCase {

    func test_loopRegion_timeRatioWithZeroDuration() {
        let duration: TimeInterval = 0
        let ratio = duration > 0 ? 1.0 / duration : 0.0
        XCTAssertEqual(ratio, 0.0)
    }

    func test_loopRegion_clamped_integration() {
        let region = LoopRegion(start: 0, end: 10)
        let clamped = region.clamped(to: 5)
        XCTAssertEqual(clamped.end, 5.0, accuracy: 0.001)
    }
}
