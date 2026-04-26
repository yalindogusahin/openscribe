#import "AudioEngine.h"
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#include <algorithm>
#include <cmath>

namespace {
constexpr UInt32 kChannels = 2;
constexpr UInt32 kBitsPerChannel = 32;

AudioDeviceID DefaultOutputDeviceID() {
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                               0, nullptr, &sz, &dev);
    return dev;
}

bool DeviceHasOutputStreams(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &sz) != noErr) return false;
    if (sz == 0) return false;
    std::vector<uint8_t> buf(sz);
    auto* bl = reinterpret_cast<AudioBufferList*>(buf.data());
    if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, bl) != noErr) return false;
    UInt32 ch = 0;
    for (UInt32 i = 0; i < bl->mNumberBuffers; ++i) ch += bl->mBuffers[i].mNumberChannels;
    return ch > 0;
}

std::string CFStringToStd(CFStringRef s) {
    if (!s) return {};
    char buf[512] = {0};
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) return std::string(buf);
    return {};
}

std::string DeviceUIDString(AudioDeviceID dev) {
    CFStringRef uid = nullptr;
    UInt32 sz = sizeof(uid);
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, &uid) != noErr) return {};
    std::string out = CFStringToStd(uid);
    if (uid) CFRelease(uid);
    return out;
}

std::string DeviceNameString(AudioDeviceID dev) {
    CFStringRef name = nullptr;
    UInt32 sz = sizeof(name);
    AudioObjectPropertyAddress addr = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, &name) != noErr) return {};
    std::string out = CFStringToStd(name);
    if (name) CFRelease(name);
    return out;
}

AudioDeviceID DeviceIDForUID(const std::string& uid) {
    if (uid.empty()) return DefaultOutputDeviceID();
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,
                                       0, nullptr, &sz) != noErr) return kAudioObjectUnknown;
    UInt32 count = sz / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> ids(count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                   0, nullptr, &sz, ids.data()) != noErr) return kAudioObjectUnknown;
    for (auto id : ids) {
        if (DeviceUIDString(id) == uid) return id;
    }
    return kAudioObjectUnknown;
}
}

std::vector<AudioEngine::DeviceInfo> AudioEngine::listOutputDevices() {
    std::vector<DeviceInfo> out;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,
                                       0, nullptr, &sz) != noErr) return out;
    UInt32 count = sz / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> ids(count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                   0, nullptr, &sz, ids.data()) != noErr) return out;
    for (auto id : ids) {
        if (!DeviceHasOutputStreams(id)) continue;
        DeviceInfo info;
        info.uid = DeviceUIDString(id);
        info.name = DeviceNameString(id);
        if (!info.uid.empty()) out.push_back(info);
    }
    return out;
}

AudioEngine::AudioEngine() {
    setupOutputUnit();
    // Pre-compute the IIR alpha for the default cutoff so toggling LP on
    // immediately gives a sensible filter rather than a no-op.
    setLowPassFrequencyHz(lpFreqHz_.load());
}

AudioEngine::~AudioEngine() {
    teardownOutputUnit();
}

bool AudioEngine::setupOutputUnit() {
    // NewTimePitch requires non-interleaved Float32. Per-buffer = 1 channel.
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = sampleRate_;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat
                     | kAudioFormatFlagIsPacked
                     | kAudioFormatFlagIsNonInterleaved;
    fmt.mFramesPerPacket = 1;
    fmt.mChannelsPerFrame = kChannels;
    fmt.mBitsPerChannel = kBitsPerChannel;
    fmt.mBytesPerFrame = kBitsPerChannel / 8;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;

    // 1. HAL output unit (lets us pick a specific device).
    AudioComponentDescription outDesc = {};
    outDesc.componentType = kAudioUnitType_Output;
    outDesc.componentSubType = kAudioUnitSubType_HALOutput;
    outDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent outComp = AudioComponentFindNext(nullptr, &outDesc);
    if (!outComp) return false;
    if (AudioComponentInstanceNew(outComp, &outputUnit_) != noErr) return false;

    // HAL needs a device assigned before initialize. Default to system output.
    AudioDeviceID dev = DefaultOutputDeviceID();
    if (dev != kAudioObjectUnknown) {
        AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev, sizeof(dev));
        currentDeviceUID_ = DeviceUIDString(dev);
    }

    // 2. NewTimePitch — pitch-preserving rate change.
    AudioComponentDescription tpDesc = {};
    tpDesc.componentType = kAudioUnitType_FormatConverter;
    tpDesc.componentSubType = kAudioUnitSubType_NewTimePitch;
    tpDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent tpComp = AudioComponentFindNext(nullptr, &tpDesc);
    if (!tpComp) return false;
    if (AudioComponentInstanceNew(tpComp, &timePitch_) != noErr) return false;

    OSStatus s;
    s = AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (s != noErr) { NSLog(@"out fmt fail: %d", (int)s); return false; }

    s = AudioUnitSetProperty(timePitch_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (s != noErr) { NSLog(@"tp in fmt fail: %d", (int)s); return false; }

    s = AudioUnitSetProperty(timePitch_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 0, &fmt, sizeof(fmt));
    if (s != noErr) { NSLog(@"tp out fmt fail: %d", (int)s); return false; }

    AURenderCallbackStruct srcCb = {};
    srcCb.inputProc = sourceCallback;
    srcCb.inputProcRefCon = this;
    s = AudioUnitSetProperty(timePitch_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &srcCb, sizeof(srcCb));
    if (s != noErr) { NSLog(@"tp callback fail: %d", (int)s); return false; }

    AURenderCallbackStruct outCb = {};
    outCb.inputProc = outputCallback;
    outCb.inputProcRefCon = this;
    s = AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &outCb, sizeof(outCb));
    if (s != noErr) { NSLog(@"out callback fail: %d", (int)s); return false; }

    s = AudioUnitInitialize(timePitch_);
    if (s != noErr) { NSLog(@"tp init fail: %d", (int)s); return false; }
    s = AudioUnitInitialize(outputUnit_);
    if (s != noErr) { NSLog(@"out init fail: %d", (int)s); return false; }
    return true;
}

void AudioEngine::teardownOutputUnit() {
    if (outputUnit_) {
        AudioOutputUnitStop(outputUnit_);
        AudioUnitUninitialize(outputUnit_);
        AudioComponentInstanceDispose(outputUnit_);
        outputUnit_ = nullptr;
    }
    if (timePitch_) {
        AudioUnitUninitialize(timePitch_);
        AudioComponentInstanceDispose(timePitch_);
        timePitch_ = nullptr;
    }
}

bool AudioEngine::load(const std::string& path) {
    // Stop output before mutating samples_ — render callback reads it.
    AudioOutputUnitStop(outputUnit_);
    playing_.store(false);

    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSURL* url = [NSURL fileURLWithPath:nsPath];

    ExtAudioFileRef file = nullptr;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &file) != noErr) return false;

    AudioStreamBasicDescription clientFmt = {};
    clientFmt.mSampleRate = sampleRate_;
    clientFmt.mFormatID = kAudioFormatLinearPCM;
    clientFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientFmt.mFramesPerPacket = 1;
    clientFmt.mChannelsPerFrame = kChannels;
    clientFmt.mBitsPerChannel = kBitsPerChannel;
    clientFmt.mBytesPerFrame = (kBitsPerChannel / 8) * kChannels;
    clientFmt.mBytesPerPacket = clientFmt.mBytesPerFrame;

    if (ExtAudioFileSetProperty(file,
                                kExtAudioFileProperty_ClientDataFormat,
                                sizeof(clientFmt), &clientFmt) != noErr) {
        ExtAudioFileDispose(file);
        return false;
    }

    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    if (ExtAudioFileGetProperty(file,
                                kExtAudioFileProperty_FileLengthFrames,
                                &propSize, &totalFrames) != noErr) {
        ExtAudioFileDispose(file);
        return false;
    }

    samples_.assign(static_cast<size_t>(totalFrames) * kChannels, 0.0f);

    AudioBufferList bufList = {};
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = kChannels;
    bufList.mBuffers[0].mDataByteSize =
        static_cast<UInt32>(samples_.size() * sizeof(float));
    bufList.mBuffers[0].mData = samples_.data();

    UInt32 frames = static_cast<UInt32>(totalFrames);
    if (ExtAudioFileRead(file, &frames, &bufList) != noErr) {
        ExtAudioFileDispose(file);
        return false;
    }

    ExtAudioFileDispose(file);

    totalFrames_ = static_cast<int64_t>(frames);
    readFrame_.store(0);
    loopStart_.store(-1);
    loopEnd_.store(-1);
    lpPrevL_ = 0.0f;
    lpPrevR_ = 0.0f;
    return true;
}

void AudioEngine::play() {
    if (samples_.empty()) return;
    OSStatus s = AudioOutputUnitStart(outputUnit_);
    if (s == noErr) {
        playing_.store(true);
    } else {
        NSLog(@"AudioOutputUnitStart fail: %d", (int)s);
    }
}

void AudioEngine::pause() {
    AudioOutputUnitStop(outputUnit_);
    playing_.store(false);
}

void AudioEngine::stop() {
    pause();
    readFrame_.store(0);
}

void AudioEngine::seek(double seconds) {
    int64_t f = static_cast<int64_t>(seconds * sampleRate_);
    if (f < 0) f = 0;
    if (f > totalFrames_) f = totalFrames_;
    readFrame_.store(f);
}

void AudioEngine::setLoop(double start, double end) {
    int64_t s = static_cast<int64_t>(start * sampleRate_);
    int64_t e = static_cast<int64_t>(end * sampleRate_);
    if (s < 0) s = 0;
    if (e > totalFrames_) e = totalFrames_;
    if (e <= s) return;
    loopStart_.store(s);
    loopEnd_.store(e);
}

void AudioEngine::clearLoop() {
    loopStart_.store(-1);
    loopEnd_.store(-1);
}

bool AudioEngine::hasLoop() const {
    return loopStart_.load() >= 0 && loopEnd_.load() > loopStart_.load();
}

double AudioEngine::duration() const {
    return totalFrames_ / sampleRate_;
}

double AudioEngine::currentTime() const {
    return readFrame_.load() / sampleRate_;
}

bool AudioEngine::isPlaying() const {
    return playing_.load();
}

bool AudioEngine::setOutputDeviceUID(const std::string& uid) {
    AudioDeviceID dev = DeviceIDForUID(uid);
    if (dev == kAudioObjectUnknown) return false;
    if (!outputUnit_) return false;

    bool wasPlaying = playing_.load();
    AudioOutputUnitStop(outputUnit_);
    AudioUnitUninitialize(outputUnit_);

    OSStatus s = AudioUnitSetProperty(outputUnit_,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &dev, sizeof(dev));
    if (s != noErr) NSLog(@"set device fail: %d", (int)s);

    AudioUnitInitialize(outputUnit_);
    if (wasPlaying) AudioOutputUnitStart(outputUnit_);
    currentDeviceUID_ = uid.empty() ? DeviceUIDString(dev) : uid;
    return s == noErr;
}

std::string AudioEngine::currentOutputDeviceUID() const {
    return currentDeviceUID_;
}

void AudioEngine::setSpeed(double rate) {
    if (rate < 0.25) rate = 0.25;
    if (rate > 4.0) rate = 4.0;
    speed_ = rate;
    if (timePitch_) {
        AudioUnitSetParameter(timePitch_, kNewTimePitchParam_Rate,
                              kAudioUnitScope_Global, 0, (Float32)rate, 0);
    }
}

void AudioEngine::setVolume(double v) {
    if (v < 0.0) v = 0.0;
    if (v > 1.5) v = 1.5;
    volume_.store((float)v);
}

void AudioEngine::setCenterCancelAmount(double amount) {
    amount = std::clamp(amount, 0.0, 1.0);
    centerCancel_.store((float)amount);
}

void AudioEngine::setLowPassEnabled(bool enabled) {
    lpEnabled_.store(enabled);
}

void AudioEngine::setLowPassFrequencyHz(double hz) {
    hz = std::clamp(hz, 60.0, 18000.0);
    lpFreqHz_.store((float)hz);
    double rc = 1.0 / (2.0 * M_PI * hz);
    double dt = 1.0 / sampleRate_;
    double alpha = dt / (rc + dt);
    lpAlpha_.store((float)alpha);
}

void AudioEngine::setPitch(double cents) {
    if (cents < -2400.0) cents = -2400.0;
    if (cents > 2400.0) cents = 2400.0;
    pitch_ = cents;
    if (timePitch_) {
        AudioUnitSetParameter(timePitch_, kNewTimePitchParam_Pitch,
                              kAudioUnitScope_Global, 0, (Float32)cents, 0);
    }
}

OSStatus AudioEngine::sourceCallback(void* inRefCon,
                                     AudioUnitRenderActionFlags*,
                                     const AudioTimeStamp*,
                                     UInt32,
                                     UInt32 inNumberFrames,
                                     AudioBufferList* ioData) {
    static_cast<AudioEngine*>(inRefCon)->render(inNumberFrames, ioData);
    return noErr;
}

OSStatus AudioEngine::outputCallback(void* inRefCon,
                                     AudioUnitRenderActionFlags* ioActionFlags,
                                     const AudioTimeStamp* inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList* ioData) {
    AudioEngine* self = static_cast<AudioEngine*>(inRefCon);
    return AudioUnitRender(self->timePitch_, ioActionFlags, inTimeStamp,
                           inBusNumber, inNumberFrames, ioData);
}

void AudioEngine::render(uint32_t numFrames, AudioBufferList* ioData) {
    // Non-interleaved: separate buffers for L and R.
    float* L = static_cast<float*>(ioData->mBuffers[0].mData);
    float* R = static_cast<float*>(ioData->mBuffers[1].mData);
    const int64_t total = totalFrames_;
    const int64_t lStart = loopStart_.load();
    const int64_t lEnd = loopEnd_.load();
    const bool looping = (lStart >= 0 && lEnd > lStart);
    int64_t pos = readFrame_.load();
    const float vol = volume_.load();
    const float cancel = centerCancel_.load();
    const bool lpOn = lpEnabled_.load();
    const float alpha = lpAlpha_.load();
    float pL = lpPrevL_;
    float pR = lpPrevR_;

    int64_t wraps = 0;
    for (uint32_t i = 0; i < numFrames; ++i) {
        if (looping && pos >= lEnd) {
            pos = lStart;
            ++wraps;
        }
        if (!looping && pos >= total) {
            L[i] = 0.0f;
            R[i] = 0.0f;
            continue;
        }
        float l = samples_[pos * 2 + 0];
        float r = samples_[pos * 2 + 1];
        if (cancel > 0.0f) {
            float mid = 0.5f * (l + r);
            l -= cancel * mid;
            r -= cancel * mid;
        }
        if (lpOn) {
            pL += alpha * (l - pL);
            pR += alpha * (r - pR);
            l = pL;
            r = pR;
        }
        L[i] = l * vol;
        R[i] = r * vol;
        ++pos;
    }

    lpPrevL_ = pL;
    lpPrevR_ = pR;
    readFrame_.store(pos);
    if (wraps > 0) {
        loopWrapCount_.fetch_add(wraps);
    }
}
