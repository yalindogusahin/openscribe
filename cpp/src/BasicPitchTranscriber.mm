#import "BasicPitchTranscriber.h"

@implementation BasicPitchTranscriber {
    NSTask*    _task;
    NSPipe*    _stdoutPipe;
    NSPipe*    _stderrPipe;
    NSMutableString* _stdoutTail;
    NSMutableString* _stderrTail;
    NSString*  _runningTag;
    NSString*  _runningOutPath;
}

- (instancetype)init {
    if ((self = [super init])) {
        _helperDir = [[self class] resolveHelperDir];
        _stdoutTail = [NSMutableString string];
        _stderrTail = [NSMutableString string];
    }
    return self;
}

- (BOOL)isHelperAvailable {
    return [self resolvePython] != nil
        && [NSFileManager.defaultManager fileExistsAtPath:
                [_helperDir stringByAppendingPathComponent:@"transcribe.py"]];
}

// Two supported layouts (mirror StemSeparator):
//   1. Bundled: $bundle/Contents/Resources/python/bin/python3.11 with
//      stem-helper/site-packages/ holding both stem and transcribe deps.
//   2. Dev: stem-helper/venv/bin/python (legacy).
- (NSString*)resolvePython {
    if (_helperDir.length == 0) return nil;
    NSFileManager* fm = NSFileManager.defaultManager;

    // Prefer bundled python+shared site-packages.
    NSString* bundledPy = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"python/bin/python3.11"];
    NSString* sharedSite = [self bundledSitePackages];
    if (sharedSite && [fm isExecutableFileAtPath:bundledPy]) return bundledPy;

    // Dev fallback: stem-helper sibling venv.
    NSString* venvPy = [[[_helperDir stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"stem-helper"]
                            stringByAppendingPathComponent:@"venv/bin/python"];
    if ([fm isExecutableFileAtPath:venvPy]) return venvPy;
    return nil;
}

// Basic-pitch is installed into the shared stem-helper site-packages so we
// don't double-ship 100MB+ of numpy/scipy/torch. Walk to the sibling
// directory at bundle/dev locations.
- (NSString*)bundledSitePackages {
    NSString* res = NSBundle.mainBundle.resourcePath;
    if (res.length) {
        NSString* shared = [[res stringByAppendingPathComponent:@"stem-helper"]
                                 stringByAppendingPathComponent:@"site-packages"];
        if ([NSFileManager.defaultManager fileExistsAtPath:shared]) return shared;
    }
    NSString* sibling = [[[_helperDir stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"stem-helper"]
                              stringByAppendingPathComponent:@"site-packages"];
    if ([NSFileManager.defaultManager fileExistsAtPath:sibling]) return sibling;
    return nil;
}

- (BOOL)isRunning {
    return _task != nil && _task.isRunning;
}

#pragma mark - run

- (void)transcribeFile:(NSString*)inputPath
                toMIDI:(NSString*)outputPath
                   tag:(NSString*)tag {
    if (!self.isHelperAvailable) {
        [self emitError:@"Transcribe helper not found."];
        return;
    }
    if (self.isRunning) {
        [self emitError:@"A transcription is already running."];
        return;
    }

    NSString* py = [self resolvePython];
    if (!py) {
        [self emitError:@"Helper python interpreter not found."];
        return;
    }
    NSString* script = [_helperDir stringByAppendingPathComponent:@"transcribe.py"];
    NSString* sitePackages = [self bundledSitePackages];

    _runningTag = [tag copy] ?: @"";
    _runningOutPath = [outputPath copy];

    _task = [[NSTask alloc] init];
    _task.launchPath = py;
    _task.arguments = @[ script,
                         @"--input",  inputPath,
                         @"--output", outputPath ];
    _task.currentDirectoryPath = _helperDir;

    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PYTHONUNBUFFERED"] = @"1";
    if (sitePackages.length) {
        env[@"PYTHONPATH"] = sitePackages;
    }
    _task.environment = env;

    _stdoutPipe = [NSPipe pipe];
    _stderrPipe = [NSPipe pipe];
    _task.standardOutput = _stdoutPipe;
    _task.standardError  = _stderrPipe;
    [_stdoutTail setString:@""];
    [_stderrTail setString:@""];

    __weak BasicPitchTranscriber* weakSelf = self;
    _stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (d.length == 0) return;
        NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) [weakSelf handleStdoutChunk:s];
    };
    _stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (d.length == 0) return;
        NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) [weakSelf handleStderrChunk:s];
    };

    _task.terminationHandler = ^(NSTask* t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf taskDidExit:t];
        });
    };

    @try {
        [_task launch];
    } @catch (NSException* e) {
        [self emitError:[NSString stringWithFormat:@"Failed to launch helper: %@", e.reason]];
        _task = nil;
    }
}

- (void)cancel {
    if (_task && _task.isRunning) [_task terminate];
}

#pragma mark - stdout/stderr parsing

- (void)handleStdoutChunk:(NSString*)chunk {
    [_stdoutTail appendString:chunk];
    NSRange nl;
    while ((nl = [_stdoutTail rangeOfString:@"\n"]).location != NSNotFound) {
        NSString* line = [_stdoutTail substringToIndex:nl.location];
        [_stdoutTail deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
        if ([line hasPrefix:@"progress:"]) {
            double frac = [[line substringFromIndex:9] doubleValue];
            __weak BasicPitchTranscriber* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                BasicPitchTranscriber* s = weakSelf;
                if (s && [s.delegate respondsToSelector:
                            @selector(basicPitchTranscriber:progress:)]) {
                    [s.delegate basicPitchTranscriber:s progress:frac];
                }
            });
        } else if ([line hasPrefix:@"stage:"]) {
            NSString* msg = [[line substringFromIndex:6]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            __weak BasicPitchTranscriber* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                BasicPitchTranscriber* s = weakSelf;
                if (s && [s.delegate respondsToSelector:
                            @selector(basicPitchTranscriber:stage:)]) {
                    [s.delegate basicPitchTranscriber:s stage:msg];
                }
            });
        }
    }
}

- (void)handleStderrChunk:(NSString*)chunk {
    [_stderrTail appendString:chunk];
    if (_stderrTail.length > 8000) {
        [_stderrTail deleteCharactersInRange:NSMakeRange(0, _stderrTail.length - 8000)];
    }
}

- (void)taskDidExit:(NSTask*)t {
    _stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    _stderrPipe.fileHandleForReading.readabilityHandler = nil;

    int status = t.terminationStatus;
    NSTaskTerminationReason reason = t.terminationReason;
    NSString* outPath = _runningOutPath;
    NSString* tag = _runningTag;
    _task = nil;
    _runningOutPath = nil;
    _runningTag = nil;

    if (reason != NSTaskTerminationReasonExit || status != 0) {
        NSString* tail = [_stderrTail copy];
        NSString* msg = (reason != NSTaskTerminationReasonExit)
            ? @"Transcription cancelled."
            : [NSString stringWithFormat:@"Helper exited with status %d.\n%@",
                                         status, tail.length ? tail : @""];
        [self emitError:msg];
        return;
    }

    if (![NSFileManager.defaultManager fileExistsAtPath:outPath]) {
        [self emitError:@"Helper succeeded but output MIDI is missing."];
        return;
    }

    if ([_delegate respondsToSelector:
            @selector(basicPitchTranscriber:didFinishWithMIDI:sourceTag:)]) {
        [_delegate basicPitchTranscriber:self didFinishWithMIDI:outPath sourceTag:tag];
    }
}

- (void)emitError:(NSString*)msg {
    if ([_delegate respondsToSelector:
            @selector(basicPitchTranscriber:didFailWithError:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate basicPitchTranscriber:self didFailWithError:msg];
        });
    } else {
        NSLog(@"[BasicPitchTranscriber] %@", msg);
    }
}

#pragma mark - helper discovery

+ (NSString*)resolveHelperDir {
    NSString* fromEnv =
        NSProcessInfo.processInfo.environment[@"OPENSCRIBE_TRANSCRIBE_HELPER"];
    if ([self looksLikeHelperDir:fromEnv]) return fromEnv;

    NSString* bundled = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"transcribe-helper"];
    if ([self looksLikeHelperDir:bundled]) return bundled;

    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = a.firstObject;
    if (appSupport.length) {
        NSString* cand = [[appSupport stringByAppendingPathComponent:@"OpenScribe"]
                                      stringByAppendingPathComponent:@"transcribe-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
    }

    NSString* base = NSBundle.mainBundle.bundlePath;
    for (int i = 0; i < 6 && base.length > 1; i++) {
        NSString* cand = [[base stringByAppendingPathComponent:@"tools"]
                                 stringByAppendingPathComponent:@"transcribe-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
        base = base.stringByDeletingLastPathComponent;
    }
    return nil;
}

+ (BOOL)looksLikeHelperDir:(NSString*)dir {
    if (dir.length == 0) return NO;
    NSString* sc = [dir stringByAppendingPathComponent:@"transcribe.py"];
    return [NSFileManager.defaultManager fileExistsAtPath:sc];
}

@end
