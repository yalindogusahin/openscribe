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
    @Published public private(set) var bookmarks: [TimeInterval] = []
    @Published public var speed: Float = 1.0 {
        didSet { engine.setSpeed(speed); persist() }
    }
    @Published public var pitch: Float = 0.0 {
        didSet { engine.setPitch(pitch); persist() }
    }
    @Published public var volume: Float = 1.0 {
        didSet { engine.setVolume(volume); persist() }
    }

    // MARK: – Waveform zoom (managed here so the app-level scroll monitor can update it)

    @Published public var waveformZoomLevel: Double = 1.0 { didSet { persist() } }
    @Published public var waveformPanOffset: Double = 0.0 { didSet { persist() } }
    /// Waveform frame in window coordinates — updated by WaveformView, read by scroll monitor
    public var waveformWindowFrame: CGRect = .zero

    public func handleWaveformScroll(dx: Double, dy: Double, mouseX: Double, viewWidth: Double) {
        if dy.magnitude > dx.magnitude {
            // Vertical → zoom centred on cursor
            let cursorRatio = viewWidth > 0 ? mouseX / viewWidth : 0.5
            let cursorNorm  = waveformPanOffset + cursorRatio / waveformZoomLevel
            let newZoom     = max(1.0, min(1024.0, waveformZoomLevel * exp(-dy * 0.04)))
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
            RecentFilesStore.add(url)
            restoreState(for: url)
            Task { await reloadWaveform(url: url) }
        } catch {
            print("AudioEngine load error: \(error)")
        }
    }

    private func restoreState(for url: URL) {
        guard let state = FileStateStore.load(for: url) else {
            bookmarks = []
            return
        }
        // Suspend persistence while we hydrate published properties.
        isRestoring = true
        defer { isRestoring = false }
        waveformZoomLevel = state.zoom
        waveformPanOffset = state.pan
        speed = state.speed
        pitch = state.pitch
        volume = state.volume ?? 1.0
        bookmarks = state.bookmarks ?? []
        if let region = state.loop {
            setLoop(region)
        }
        if state.lastTime > 0 && state.lastTime < duration {
            seek(to: state.lastTime)
        }
    }

    private var isRestoring = false

    private func persist() {
        guard !isRestoring, let url = loadedURL else { return }
        let state = FileState(
            loop: loop,
            zoom: waveformZoomLevel,
            pan: waveformPanOffset,
            speed: speed,
            pitch: pitch,
            lastTime: currentTime,
            volume: volume,
            bookmarks: bookmarks
        )
        FileStateStore.save(state, for: url)
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
        persist()
    }

    public func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
    }

    public func seek(to time: TimeInterval) {
        engine.seek(to: time)
        currentTime = time
        persist()
    }

    // MARK: – Loop

    public func setLoop(_ region: LoopRegion) {
        let clamped = region.clamped(to: duration)
        loop = clamped
        engine.setLoop(clamped)
        persist()
    }

    public func clearLoop() {
        loop = nil
        engine.clearLoop()
        persist()
    }

    public func setLoopStart(at time: TimeInterval) {
        let t = max(0, min(time, duration))
        let end = loop?.end ?? duration
        guard end - t >= 0.05 else { return }
        setLoop(LoopRegion(start: t, end: end))
    }

    public func setLoopEnd(at time: TimeInterval) {
        let t = max(0, min(time, duration))
        let start = loop?.start ?? 0
        guard t - start >= 0.05 else { return }
        setLoop(LoopRegion(start: start, end: t))
    }

    public func nudgeLoopStart(by delta: TimeInterval) {
        guard let loop else { return }
        let newStart = max(0, min(loop.end - 0.05, loop.start + delta))
        setLoop(LoopRegion(start: newStart, end: loop.end))
    }

    public func nudgeLoopEnd(by delta: TimeInterval) {
        guard let loop else { return }
        let newEnd = max(loop.start + 0.05, min(duration, loop.end + delta))
        setLoop(LoopRegion(start: loop.start, end: newEnd))
    }

    // MARK: – Bookmarks

    public func toggleBookmark(at time: TimeInterval) {
        let t = max(0, min(time, duration))
        // Remove if within 200ms of an existing bookmark.
        if let idx = bookmarks.firstIndex(where: { abs($0 - t) < 0.2 }) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(t)
            bookmarks.sort()
        }
        persist()
    }

    public func jumpToBookmark(_ index: Int) {
        guard index >= 0, index < bookmarks.count else { return }
        seek(to: bookmarks[index])
    }

    public func clearBookmarks() {
        bookmarks = []
        persist()
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
