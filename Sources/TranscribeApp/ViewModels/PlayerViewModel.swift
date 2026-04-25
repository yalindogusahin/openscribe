import AVFoundation
import Combine
import Foundation
import SwiftUI

final class PlayerViewModel: ObservableObject {
    // MARK: – Yayınlanan durum

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var waveformPeaks: [(min: Float, max: Float)] = []
    @Published private(set) var loop: LoopRegion?
    @Published private(set) var loadedURL: URL?
    @Published var speed: Float = 1.0 {
        didSet { engine.setSpeed(speed) }
    }
    @Published var pitch: Float = 0.0 {
        didSet { engine.setPitch(pitch) }
    }

    // Waveform için pixel genişliği (View'dan ayarlanır)
    var waveformWidth: Int = 800 {
        didSet {
            if oldValue != waveformWidth, let url = loadedURL {
                Task { await reloadWaveform(url: url, width: waveformWidth) }
            }
        }
    }

    // MARK: – Özel

    private let engine = AudioEngine()

    init() {
        engine.delegate = self
    }

    // MARK: – Dosya açma

    func load(url: URL) {
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

    func play() {
        engine.play()
        isPlaying = true
    }

    func pause() {
        engine.pause()
        isPlaying = false
    }

    func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        engine.seek(to: time)
        currentTime = time
    }

    // MARK: – Loop

    func setLoop(_ region: LoopRegion) {
        let clamped = region.clamped(to: duration)
        loop = clamped
        engine.setLoop(clamped)
    }

    func clearLoop() {
        loop = nil
        engine.clearLoop()
    }

    // MARK: – Yardımcı

    func timeRatio(for time: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return time / duration
    }
}

// MARK: – AudioEngineDelegate

extension PlayerViewModel: AudioEngineDelegate {
    func audioEngineDidUpdatePosition(_ time: TimeInterval) {
        currentTime = time
    }

    func audioEngineDidFinish() {
        isPlaying = false
        currentTime = 0
    }
}
