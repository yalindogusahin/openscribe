import AVFoundation
import Foundation

public struct WaveformAnalyzer {
    /// Reads the audio file and produces `pixelCount` (min, max) peak pairs.
    public static func peaks(from url: URL, pixelCount: Int) throws -> [(min: Float, max: Float)] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw WaveformError.bufferAllocation
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw WaveformError.noChannelData
        }

        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))
        let total = samples.count
        guard total > 0, pixelCount > 0 else { return [] }

        var peaks: [(min: Float, max: Float)] = []
        peaks.reserveCapacity(pixelCount)

        for i in 0 ..< pixelCount {
            let lo = Int(Double(i) * Double(total) / Double(pixelCount))
            let hi = max(lo + 1, Int(Double(i + 1) * Double(total) / Double(pixelCount)))
            let slice = samples[lo ..< min(hi, total)]
            let mn = slice.min() ?? 0
            let mx = slice.max() ?? 0
            peaks.append((min: mn, max: mx))
        }
        return peaks
    }

    public enum WaveformError: Error {
        case bufferAllocation
        case noChannelData
    }
}

