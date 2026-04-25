#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <atomic>
#include <string>
#include <vector>

class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();

    bool load(const std::string& path);
    void play();
    void pause();
    void stop();
    void seek(double seconds);

    void setLoop(double start, double end);
    void clearLoop();
    bool hasLoop() const;
    int64_t loopStartFrame() const { return loopStart_.load(); }
    int64_t loopEndFrame() const { return loopEnd_.load(); }

    void setSpeed(double rate);   // 1.0 = normal; 0.25..4.0 valid
    double speed() const { return speed_; }

    void setPitch(double cents);  // 0 = no shift; ±2400 = ±2 octaves
    double pitch() const { return pitch_; }

    void setVolume(double v);     // linear gain, 0..1.5
    double volume() const { return volume_.load(); }

    double duration() const;
    double currentTime() const;
    bool isPlaying() const;
    double sampleRate() const { return sampleRate_; }

    // Read-only view for waveform rendering. Stable as long as no load() runs.
    const float* samplesPtr() const { return samples_.data(); }
    int64_t frameCount() const { return totalFrames_; }

private:
    static OSStatus sourceCallback(void* inRefCon,
                                   AudioUnitRenderActionFlags* ioActionFlags,
                                   const AudioTimeStamp* inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList* ioData);
    static OSStatus outputCallback(void* inRefCon,
                                   AudioUnitRenderActionFlags* ioActionFlags,
                                   const AudioTimeStamp* inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList* ioData);

    void render(uint32_t numFrames, AudioBufferList* ioData);
    bool setupOutputUnit();
    void teardownOutputUnit();

    AudioUnit outputUnit_ = nullptr;
    AudioUnit timePitch_ = nullptr;
    double sampleRate_ = 48000.0;
    double speed_ = 1.0;
    double pitch_ = 0.0;

    // Interleaved stereo float32 [L, R, L, R, ...]
    std::vector<float> samples_;
    int64_t totalFrames_ = 0;

    // Touched from audio thread + main thread — atomics keep it lock-free.
    std::atomic<int64_t> readFrame_{0};
    std::atomic<int64_t> loopStart_{-1};
    std::atomic<int64_t> loopEnd_{-1};
    std::atomic<bool> playing_{false};
    std::atomic<float> volume_{1.0f};
};
