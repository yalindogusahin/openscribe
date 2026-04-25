import Foundation

struct LoopRegion: Equatable {
    var start: TimeInterval  // saniye
    var end: TimeInterval    // saniye

    var duration: TimeInterval { end - start }

    func isValid(for totalDuration: TimeInterval) -> Bool {
        start >= 0 && end > start && end <= totalDuration
    }

    func clamped(to totalDuration: TimeInterval) -> LoopRegion {
        let s = max(0, min(start, totalDuration))
        let e = max(s, min(end, totalDuration))
        return LoopRegion(start: s, end: e)
    }
}
