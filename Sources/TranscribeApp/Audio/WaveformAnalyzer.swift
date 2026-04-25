import AVFoundation
import Foundation

struct WaveformAnalyzer {
    /// Ses dosyasından `pixelCount` adet (min, max) peak çifti üretir.
    static func peaks(from url: URL, pixelCount: Int) throws -> [(min: Float, max: Float)] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioPCMStreamFormat(file.fileFormat)
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

    enum WaveformError: Error {
        case bufferAllocation
        case noChannelData
    }
}

// AVAudioPCMStreamFormat satırını derleyici kaldırabilir; basit alias:
private typealias AVAudioPCMStreamFormat = AVAudioFormat
