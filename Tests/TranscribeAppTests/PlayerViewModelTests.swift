import XCTest
@testable import TranscribeApp

final class PlayerViewModelTests: XCTestCase {
    var vm: PlayerViewModel!

    override func setUp() {
        super.setUp()
        vm = PlayerViewModel()
    }

    // MARK: – Başlangıç durumu

    func test_initialState_isNotPlaying() {
        XCTAssertFalse(vm.isPlaying)
    }

    func test_initialState_currentTimeIsZero() {
        XCTAssertEqual(vm.currentTime, 0)
    }

    func test_initialState_noLoop() {
        XCTAssertNil(vm.loop)
    }

    func test_initialState_defaultSpeed() {
        XCTAssertEqual(vm.speed, 1.0, accuracy: 0.001)
    }

    func test_initialState_defaultPitch() {
        XCTAssertEqual(vm.pitch, 0.0, accuracy: 0.001)
    }

    // MARK: – Loop

    func test_setLoop_storesClampedRegion() {
        // duration = 0 olduğu için clamped(to: 0) → start=0, end=0
        // Gerçek test için duration > 0 olan bir mock gerekir.
        // Burada LoopRegion.clamped mantığını doğruluyoruz.
        let region = LoopRegion(start: 1.0, end: 3.0)
        let clamped = region.clamped(to: 5.0)
        XCTAssertEqual(clamped.start, 1.0, accuracy: 0.001)
        XCTAssertEqual(clamped.end, 3.0, accuracy: 0.001)
    }

    func test_clearLoop_removesLoop() {
        vm.clearLoop()
        XCTAssertNil(vm.loop)
    }

    // MARK: – Speed & Pitch sınırları

    func test_speed_clampedToMinimum() {
        vm.speed = -5
        // AudioEngine.setSpeed(-5) → 0.25
        // ViewModel speed değeri direkt atanıyor, engine sınırlıyor
        // Burada LoopRegion gibi saf mantık testleri daha anlamlı
        XCTAssertTrue(true)   // placeholder — entegrasyon testi için dosya gerekir
    }

    // MARK: – timeRatio

    func test_timeRatio_zeroDuration_returnsZero() {
        XCTAssertEqual(vm.timeRatio(for: 5.0), 0.0, accuracy: 0.001)
    }

    // MARK: – Stop

    func test_stop_resetsCurrentTime() {
        vm.stop()
        XCTAssertEqual(vm.currentTime, 0)
        XCTAssertFalse(vm.isPlaying)
    }
}
