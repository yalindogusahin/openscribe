import AVFoundation
import Foundation

// MARK: - Delegate

public protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidUpdatePosition(_ time: TimeInterval)
    func audioEngineDidFinish()
}

// MARK: - AudioEngine

public final class AudioEngine {
    public weak var delegate: AudioEngineDelegate?

    // AVAudioEngine pipeline:
    //   playerNode → timePitchNode → engine.mainMixerNode → output
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()

    private var audioFile: AVAudioFile?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100

    // Oynatma durumu
    public private(set) var isPlaying = false
    private var currentFrame: AVAudioFramePosition = 0  // son seek pozisyonu

    // Loop
    public private(set) var loop: LoopRegion?

    // Hız & Pitch
    public private(set) var speed: Float = 1.0
    public private(set) var pitch: Float = 0.0

    // Timer → delegate çağrısı
    private var positionTimer: Timer?

    // MARK: Init

    public init() {
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.connect(playerNode, to: timePitchNode, format: nil)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)
    }

    // MARK: – Dosya yükleme

    public func load(url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        audioFile = file
        totalFrames = file.length
        sampleRate = file.processingFormat.sampleRate
        currentFrame = 0
        loop = nil

        // Engine'i bu dosyanın formatıyla yeniden bağla
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: timePitchNode, format: file.processingFormat)

        try engine.start()
        applyTimePitch()
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }

    public var currentTime: TimeInterval {
        currentTimeFromNode() ?? (Double(currentFrame) / sampleRate)
    }

    // MARK: – Transport

    public func play() {
        guard let file = audioFile else { return }
        if !engine.isRunning { try? engine.start() }
        scheduleSegment(from: currentFrame, file: file)
        playerNode.play()
        isPlaying = true
        startPositionTimer()
    }

    public func pause() {
        playerNode.pause()
        currentFrame = currentFrameFromNode()
        isPlaying = false
        stopPositionTimer()
    }

    public func stop() {
        playerNode.stop()
        currentFrame = 0
        isPlaying = false
        stopPositionTimer()
    }

    public func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        playerNode.stop()
        currentFrame = AVAudioFramePosition(time * sampleRate)
        currentFrame = max(0, min(currentFrame, totalFrames))
        if wasPlaying, let file = audioFile {
            scheduleSegment(from: currentFrame, file: file)
            playerNode.play()
        }
    }

    // MARK: – Loop

    public func setLoop(_ region: LoopRegion) {
        loop = region.clamped(to: duration)
        if isPlaying {
            seek(to: max(region.start, currentTime))
        }
    }

    public func clearLoop() {
        loop = nil
    }

    // MARK: – Hız & Pitch

    public func setSpeed(_ value: Float) {
        speed = max(0.25, min(4.0, value))
        applyTimePitch()
    }

    public func setPitch(_ semitones: Float) {
        pitch = max(-12, min(12, semitones))
        applyTimePitch()
    }

    // MARK: – Private helpers

    private func applyTimePitch() {
        timePitchNode.rate = speed
        timePitchNode.pitch = pitch * 100  // AVAudioUnitTimePitch cents kullanıyor
    }

    private func scheduleSegment(from startFrame: AVAudioFramePosition, file: AVAudioFile) {
        let endFrame: AVAudioFramePosition
        if let loop = loop {
            endFrame = AVAudioFramePosition(loop.end * sampleRate)
        } else {
            endFrame = totalFrames
        }

        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0 else { return }

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.isPlaying {
                    if self.loop != nil {
                        // Loop: başa dön
                        let loopStart = AVAudioFramePosition((self.loop?.start ?? 0) * self.sampleRate)
                        self.scheduleSegment(from: loopStart, file: file)
                    } else {
                        self.isPlaying = false
                        self.currentFrame = 0
                        self.stopPositionTimer()
                        self.delegate?.audioEngineDidFinish()
                    }
                }
            }
        }
    }

    private func currentTimeFromNode() -> TimeInterval? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return nil }
        let frame = currentFrame + playerTime.sampleTime
        return Double(max(0, frame)) / sampleRate
    }

    private func currentFrameFromNode() -> AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return currentFrame }
        return max(0, currentFrame + playerTime.sampleTime)
    }

    // MARK: – Timer

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegate?.audioEngineDidUpdatePosition(self.currentTime)
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }
}
