#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <atomic>
#include <array>
#include <string>
#include <vector>

class AudioEngine {
public:
    // Maximum number of stems supported. Single-file load uses 1 stem;
    // stem-separated load uses 4 (vocals, drums, bass, other).
    static constexpr int kMaxStems = 4;

    AudioEngine();
    ~AudioEngine();

    bool load(const std::string& path);

    // 4-stem load. Each path is loaded into its own buffer; all four must
    // have identical frame counts and sample rates (the helper guarantees
    // this). Returns false if any file fails to open or lengths mismatch.
    // On success, replaces any prior load() / loadStems() state.
    //
    // Index convention: 0=vocals, 1=drums, 2=bass, 3=other.
    bool loadStems(const std::vector<std::string>& paths);

    int stemCount() const;             // 0 if nothing loaded; 1 after load(); 4 after loadStems()
    void setStemGain(int index, double gain);   // 0..1.5 linear
    double stemGain(int index) const;
    void setStemMuted(int index, bool muted);
    bool stemMuted(int index) const;
    void setStemSoloed(int index, bool soloed); // multiple stems can be soloed
    bool stemSoloed(int index) const;
    void clearStemSolosAndMutes();

    void play();
    void pause();
    void stop();
    void seek(double seconds);

    void setLoop(double start, double end);
    void clearLoop();
    bool hasLoop() const;
    int64_t loopStartFrame() const { return loopStart_.load(); }
    int64_t loopEndFrame() const { return loopEnd_.load(); }

    // Monotonic counter incremented every time the playhead wraps from
    // loopEnd back to loopStart. Read by the UI thread to detect completed
    // loop iterations (smart loop, iteration display).
    int64_t loopWrapCount() const { return loopWrapCount_.load(); }

    void setSpeed(double rate);   // 1.0 = normal; 0.25..4.0 valid
    double speed() const { return speed_; }

    void setPitch(double cents);  // 0 = no shift; ±2400 = ±2 octaves
    double pitch() const { return pitch_; }

    void setVolume(double v);     // linear gain, 0..1.5
    double volume() const { return volume_.load(); }

    // 0 = no effect, 1 = full center (mid) cancel — pulls vocals/kick
    // panned dead-center down to silence by subtracting the L+R sum.
    void setCenterCancelAmount(double amount);
    double centerCancelAmount() const { return centerCancel_.load(); }

    // One-pole low-pass for "bass focus" practice. Frequency in Hz.
    void setLowPassEnabled(bool enabled);
    bool lowPassEnabled() const { return lpEnabled_.load(); }
    void setLowPassFrequencyHz(double hz);
    double lowPassFrequencyHz() const { return lpFreqHz_.load(); }

    double duration() const;
    double currentTime() const;
    bool isPlaying() const;
    double sampleRate() const { return sampleRate_; }

    // Output device routing. Empty UID = system default output.
    // Returns true if the device was found and set; false on lookup failure
    // (engine continues running on its previous device in that case).
    bool setOutputDeviceUID(const std::string& uid);
    std::string currentOutputDeviceUID() const;

    struct DeviceInfo {
        std::string uid;
        std::string name;
    };
    static std::vector<DeviceInfo> listOutputDevices();

    // Read-only view for waveform rendering. Stable as long as no load()/
    // loadStems() runs. For single-stem loads this points at the only
    // buffer; for 4-stem loads it points at a precomputed unity-sum mix
    // (so the waveform shows the song's silhouette regardless of which
    // stems are currently muted/soloed).
    const float* samplesPtr() const { return mixedWaveform_.data(); }
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

    // Recompute mixedWaveform_ from current stemSamples_ at unity gain.
    // Called from load()/loadStems() (main thread, output stopped).
    void rebuildMixedWaveform();

    AudioUnit outputUnit_ = nullptr;
    AudioUnit timePitch_ = nullptr;
    std::string currentDeviceUID_;
    double sampleRate_ = 48000.0;
    double speed_ = 1.0;
    double pitch_ = 0.0;

    // Per-stem interleaved stereo float32 [L, R, L, R, ...]. Size 0 when
    // nothing is loaded, 1 after load(), 4 after loadStems(). All buffers
    // share the same frame count == totalFrames_.
    std::vector<std::vector<float>> stemSamples_;
    int stemCount_ = 0;

    // Unity-gain sum of all stems, interleaved stereo. Used by
    // samplesPtr() for waveform rendering. Computed once at load time;
    // never touched by the audio thread.
    std::vector<float> mixedWaveform_;

    int64_t totalFrames_ = 0;

    // Touched from audio thread + main thread — atomics keep it lock-free.
    std::atomic<int64_t> readFrame_{0};
    std::atomic<int64_t> loopStart_{-1};
    std::atomic<int64_t> loopEnd_{-1};
    std::atomic<int64_t> loopWrapCount_{0};
    std::atomic<bool> playing_{false};
    std::atomic<float> volume_{1.0f};

    // Per-stem state. Fixed-size arrays so the audio thread reads atomics
    // without touching any container metadata. Indices 0..stemCount_-1
    // are meaningful; the rest are inert (gain 1, not muted, not soloed).
    std::array<std::atomic<float>, kMaxStems> stemGain_;
    std::array<std::atomic<bool>,  kMaxStems> stemMuted_;
    std::array<std::atomic<bool>,  kMaxStems> stemSoloed_;
    std::atomic<int> anySoloed_{0}; // count of soloed stems; >0 → solo mode

    // Filter parameters — written by main thread, read on audio thread.
    std::atomic<float> centerCancel_{0.0f};
    std::atomic<bool>  lpEnabled_{false};
    std::atomic<float> lpFreqHz_{500.0f};
    std::atomic<float> lpAlpha_{0.0f};

    // Low-pass IIR state, audio thread only.
    float lpPrevL_ = 0.0f;
    float lpPrevR_ = 0.0f;
};
