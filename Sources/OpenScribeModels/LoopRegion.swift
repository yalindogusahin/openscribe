import Foundation

public struct LoopRegion: Equatable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }

    public func isValid(for totalDuration: TimeInterval) -> Bool {
        start >= 0 && end > start && end <= totalDuration
    }

    public func clamped(to totalDuration: TimeInterval) -> LoopRegion {
        let s = max(0, min(start, totalDuration))
        let e = max(s, min(end, totalDuration))
        return LoopRegion(start: s, end: e)
    }
}
