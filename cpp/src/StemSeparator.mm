#import "StemSeparator.h"
#import <CommonCrypto/CommonDigest.h>

static NSString* const kStemNamesInEngineOrder[4] = {
    @"vocals.wav", @"drums.wav", @"bass.wav", @"other.wav",
};

@implementation StemSeparator {
    NSTask*    _task;
    NSPipe*    _stdoutPipe;
    NSPipe*    _stderrPipe;
    NSMutableString* _stdoutTail;
    NSMutableString* _stderrTail;
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
    if (_helperDir.length == 0) return NO;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* py = [_helperDir stringByAppendingPathComponent:@"venv/bin/python"];
    NSString* sc = [_helperDir stringByAppendingPathComponent:@"separate.py"];
    return [fm isExecutableFileAtPath:py] && [fm fileExistsAtPath:sc];
}

- (BOOL)isRunning {
    return _task != nil && _task.isRunning;
}

#pragma mark - cache

+ (NSString*)cacheRoot {
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = a.firstObject ?: NSTemporaryDirectory();
    NSString* root = [[base stringByAppendingPathComponent:@"OpenScribe"]
                            stringByAppendingPathComponent:@"stems"];
    [NSFileManager.defaultManager createDirectoryAtPath:root
                            withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    return root;
}

+ (NSString*)sha256OfString:(NSString*)s {
    NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, out);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", out[i]];
    }
    return hex;
}

- (NSString*)cacheDirForFile:(NSString*)inputPath {
    NSString* canon = inputPath.stringByStandardizingPath;
    NSString* hash = [[self class] sha256OfString:canon];
    return [[[self class] cacheRoot] stringByAppendingPathComponent:hash];
}

- (NSArray<NSString*>*)cachedStemPathsForFile:(NSString*)inputPath {
    NSString* dir = [self cacheDirForFile:inputPath];
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:4];
    for (int i = 0; i < 4; i++) {
        [out addObject:[dir stringByAppendingPathComponent:kStemNamesInEngineOrder[i]]];
    }
    return out;
}

- (BOOL)hasCachedStemsForFile:(NSString*)inputPath {
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* p in [self cachedStemPathsForFile:inputPath]) {
        if (![fm fileExistsAtPath:p]) return NO;
    }
    return YES;
}

#pragma mark - run

- (void)separateFile:(NSString*)inputPath {
    if (!self.isHelperAvailable) {
        [self emitError:@"Stem helper not found. Expected tools/stem-helper/ next to the app."];
        return;
    }
    if (self.isRunning) {
        [self emitError:@"A separation is already running."];
        return;
    }

    NSString* outDir = [self cacheDirForFile:inputPath];
    [NSFileManager.defaultManager createDirectoryAtPath:outDir
                            withIntermediateDirectories:YES
                                             attributes:nil error:nil];

    NSString* py = [_helperDir stringByAppendingPathComponent:@"venv/bin/python"];
    NSString* script = [_helperDir stringByAppendingPathComponent:@"separate.py"];
    NSString* torchHome = [_helperDir stringByAppendingPathComponent:@"torch_cache"];

    _task = [[NSTask alloc] init];
    _task.launchPath = py;
    _task.arguments = @[ script,
                         @"--input", inputPath,
                         @"--output-dir", outDir ];
    _task.currentDirectoryPath = _helperDir;

    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"TORCH_HOME"] = torchHome;
    env[@"PYTHONUNBUFFERED"] = @"1";
    _task.environment = env;

    _stdoutPipe = [NSPipe pipe];
    _stderrPipe = [NSPipe pipe];
    _task.standardOutput = _stdoutPipe;
    _task.standardError  = _stderrPipe;
    [_stdoutTail setString:@""];
    [_stderrTail setString:@""];

    __weak StemSeparator* weakSelf = self;
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

    NSString* expectedInput = [inputPath copy];
    _task.terminationHandler = ^(NSTask* t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf taskDidExit:t forInput:expectedInput];
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
    if (_task && _task.isRunning) {
        [_task terminate];
    }
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
            __weak StemSeparator* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                StemSeparator* s = weakSelf;
                if (s && [s.delegate respondsToSelector:@selector(stemSeparator:progress:)]) {
                    [s.delegate stemSeparator:s progress:frac];
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

- (void)taskDidExit:(NSTask*)t forInput:(NSString*)inputPath {
    _stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    _stderrPipe.fileHandleForReading.readabilityHandler = nil;

    int status = t.terminationStatus;
    NSTaskTerminationReason reason = t.terminationReason;
    _task = nil;

    if (reason != NSTaskTerminationReasonExit || status != 0) {
        NSString* tail = [_stderrTail copy];
        NSString* msg;
        if (reason != NSTaskTerminationReasonExit) {
            msg = @"Separation cancelled.";
        } else {
            msg = [NSString stringWithFormat:@"Helper exited with status %d.\n%@",
                   status, tail.length ? tail : @""];
        }
        [self emitError:msg];
        return;
    }

    NSArray<NSString*>* paths = [self cachedStemPathsForFile:inputPath];
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* p in paths) {
        if (![fm fileExistsAtPath:p]) {
            [self emitError:[NSString stringWithFormat:@"Helper succeeded but stem missing: %@",
                             p.lastPathComponent]];
            return;
        }
    }

    if ([_delegate respondsToSelector:@selector(stemSeparator:didFinishWithStemPaths:)]) {
        [_delegate stemSeparator:self didFinishWithStemPaths:paths];
    }
}

- (void)emitError:(NSString*)msg {
    if ([_delegate respondsToSelector:@selector(stemSeparator:didFailWithError:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate stemSeparator:self didFailWithError:msg];
        });
    } else {
        NSLog(@"[StemSeparator] %@", msg);
    }
}

#pragma mark - helper discovery

+ (NSString*)resolveHelperDir {
    NSString* fromEnv = NSProcessInfo.processInfo.environment[@"OPENSCRIBE_STEM_HELPER"];
    if ([self looksLikeHelperDir:fromEnv]) return fromEnv;

    // Walk up from the app bundle looking for tools/stem-helper/.
    NSString* base = NSBundle.mainBundle.bundlePath;
    for (int i = 0; i < 6 && base.length > 1; i++) {
        NSString* cand = [[base stringByAppendingPathComponent:@"tools"]
                                 stringByAppendingPathComponent:@"stem-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
        base = base.stringByDeletingLastPathComponent;
    }

    // Dev fallback — repo path on the original author's machine.
    NSString* devPath = @"/Users/yalinsahin/Desktop/TranscribeApp/tools/stem-helper";
    if ([self looksLikeHelperDir:devPath]) return devPath;
    return nil;
}

+ (BOOL)looksLikeHelperDir:(NSString*)dir {
    if (dir.length == 0) return NO;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* py = [dir stringByAppendingPathComponent:@"venv/bin/python"];
    NSString* sc = [dir stringByAppendingPathComponent:@"separate.py"];
    return [fm isExecutableFileAtPath:py] && [fm fileExistsAtPath:sc];
}

@end
