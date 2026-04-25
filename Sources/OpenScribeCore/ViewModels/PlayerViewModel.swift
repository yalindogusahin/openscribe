import AVFoundation
import Combine
import CoreGraphics
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

    // MARK: – Waveform zoom (managed here so the app-level scroll monitor can update it)

    @Published public var waveformZoomLevel: Double = 1.0
    @Published public var waveformPanOffset: Double = 0.0
    /// Waveform frame in window coordinates — updated by WaveformView, read by scroll monitor
    public var waveformWindowFrame: CGRect = .zero

    public func handleWaveformScroll(dx: Double, dy: Double, mouseX: Double, viewWidth: Double) {
        if dy.magnitude > dx.magnitude {
            // Vertical → zoom centred on cursor
            let cursorRatio = viewWidth > 0 ? mouseX / viewWidth : 0.5
            let cursorNorm  = waveformPanOffset + cursorRatio / waveformZoomLevel
            let newZoom     = max(1.0, min(256.0, waveformZoomLevel * exp(-dy * 0.04)))
            let newPan      = max(0.0, min(1.0 - 1.0 / newZoom, cursorNorm - cursorRatio / newZoom))
            waveformZoomLevel = newZoom
            waveformPanOffset = newZoom == 1.0 ? 0.0 : newPan
        } else {
            // Horizontal → pan
            guard waveformZoomLevel > 1 else { return }
            let delta = dx * 0.003 / waveformZoomLevel
            waveformPanOffset = max(0.0, min(1.0 - 1.0 / waveformZoomLevel, waveformPanOffset + delta))
        }
    }

    // Pixel width for waveform rendering (set by the View). Informational only —
    // peaks are sampled at a fixed high resolution so resizing the window does
    // NOT trigger a re-analysis. The view buckets peaks down to actual pixels.
    public var waveformWidth: Int = 800

    // MARK: – Private

    private let engine = AudioEngine()
    private var scopedURL: URL?

    public init() {
        engine.delegate = self
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: – File loading

    public func load(url: URL) {
        do {
            try engine.load(url: url)
            duration = engine.duration
            currentTime = 0
            loop = nil
            // Release any previous sandbox scope before adopting the new one.
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
            loadedURL = url
            Task { await reloadWaveform(url: url) }
        } catch {
            print("AudioEngine load error: \(error)")
        }
    }

    @MainActor
    private func reloadWaveform(url: URL) async {
        // Fixed resolution: high enough that even at 64× zoom there are several
        // peaks per screen pixel on a wide display. The view buckets down to
        // the visible pixel range when drawing, so window resizes never trigger
        // a re-analysis.
        let peaks = try? await Task.detached(priority: .userInitiated) {
            try WaveformAnalyzer.peaks(from: url, pixelCount: 131_072)
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
