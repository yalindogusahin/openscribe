#import "AudioEngine.h"
#import <Foundation/Foundation.h>

namespace {
constexpr UInt32 kChannels = 2;
constexpr UInt32 kBitsPerChannel = 32;
}

AudioEngine::AudioEngine() {
    setupOutputUnit();
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

    // 1. Default output unit.
    AudioComponentDescription outDesc = {};
    outDesc.componentType = kAudioUnitType_Output;
    outDesc.componentSubType = kAudioUnitSubType_DefaultOutput;
    outDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent outComp = AudioComponentFindNext(nullptr, &outDesc);
    if (!outComp) return false;
    if (AudioComponentInstanceNew(outComp, &outputUnit_) != noErr) return false;

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

    for (uint32_t i = 0; i < numFrames; ++i) {
        if (looping && pos >= lEnd) pos = lStart;
        if (!looping && pos >= total) {
            L[i] = 0.0f;
            R[i] = 0.0f;
            continue;
        }
        L[i] = samples_[pos * 2 + 0] * vol;
        R[i] = samples_[pos * 2 + 1] * vol;
        ++pos;
    }

    readFrame_.store(pos);
}
