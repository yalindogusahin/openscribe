import AVFoundation
import Combine
import Foundation

public final class PlayerViewModel: ObservableObject {
    // MARK: – Published state

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var waveformPeaks: [(min: Float, max: Float)] = []
    @Published public private(set) var loop: LoopRegion?
    @Published public private(set) var loadedURL: URL?
    @Published public var speed: Float = 1.0 {
        didSet { engine.setSpeed(speed) }
    }
    @Published public var pitch: Float = 0.0 {
        didSet { engine.setPitch(pitch) }
    }

    // Pixel width for waveform rendering (set by the View)
    public var waveformWidth: Int = 800 {
        didSet {
            if oldValue != waveformWidth, let url = loadedURL {
                Task { await reloadWaveform(url: url, width: waveformWidth) }
            }
        }
    }

    // MARK: – Private

    private let engine = AudioEngine()

    public init() {
        engine.delegate = self
    }

    // MARK: – File loading

    public func load(url: URL) {
        do {
            try engine.load(url: url)
            duration = engine.duration
            currentTime = 0
            loop = nil
            loadedURL = url
            Task { await reloadWaveform(url: url, width: waveformWidth) }
        } catch {
            print("AudioEngine load error: \(error)")
        }
    }

    @MainActor
    private func reloadWaveform(url: URL, width: Int) async {
        let peaks = try? await Task.detached(priority: .userInitiated) {
            try WaveformAnalyzer.peaks(from: url, pixelCount: width)
        }.value
        waveformPeaks = peaks ?? []
    }

    // MARK: – Transport

    public func play() {
        engine.play()
        isPlaying = true
    }

    public func pause() {
        engine.pause()
        isPlaying = false
    }

    public func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
    }

    public func seek(to time: TimeInterval) {
        engine.seek(to: time)
        currentTime = time
    }

    // MARK: – Loop

    public func setLoop(_ region: LoopRegion) {
        let clamped = region.clamped(to: duration)
        loop = clamped
        engine.setLoop(clamped)
    }

    public func clearLoop() {
        loop = nil
        engine.clearLoop()
    }

    // MARK: – Helpers

    public func timeRatio(for time: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return time / duration
    }
}

// MARK: – AudioEngineDelegate

extension PlayerViewModel: AudioEngineDelegate {
    public func audioEngineDidUpdatePosition(_ time: TimeInterval) {
        currentTime = time
    }

    public func audioEngineDidFinish() {
        isPlaying = false
        currentTime = 0
    }
}
