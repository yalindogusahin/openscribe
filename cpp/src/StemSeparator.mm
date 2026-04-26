#import "StemSeparator.h"
#import <CommonCrypto/CommonDigest.h>

@implementation StemSeparation
@end

@implementation StemSeparator {
    NSTask*    _task;
    NSPipe*    _stdoutPipe;
    NSPipe*    _stderrPipe;
    NSMutableString* _stdoutTail;
    NSMutableString* _stderrTail;
    NSString*  _runningModel;
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
                [_helperDir stringByAppendingPathComponent:@"separate.py"]];
}

// Two supported layouts:
//   1. Bundled (production): helper/site-packages/ next to a python
//      interpreter at $bundle/Contents/Resources/python/bin/python3.11.
//      Run via that interpreter with PYTHONPATH pointing at site-packages.
//   2. Dev (legacy): helper/venv/bin/python — a self-contained venv.
//      Run venv's python directly; site-packages handled internally.
// Returns the python executable path, or nil if neither layout is intact.
- (NSString*)resolvePython {
    if (_helperDir.length == 0) return nil;
    NSFileManager* fm = NSFileManager.defaultManager;

    NSString* venvPy = [_helperDir stringByAppendingPathComponent:@"venv/bin/python"];
    if ([fm isExecutableFileAtPath:venvPy]) return venvPy;

    NSString* site = [_helperDir stringByAppendingPathComponent:@"site-packages"];
    if (![fm fileExistsAtPath:site]) return nil;
    NSString* bundledPy = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"python/bin/python3.11"];
    if ([fm isExecutableFileAtPath:bundledPy]) return bundledPy;
    return nil;
}

- (NSString*)bundledSitePackages {
    NSString* site = [_helperDir stringByAppendingPathComponent:@"site-packages"];
    return [NSFileManager.defaultManager fileExistsAtPath:site] ? site : nil;
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

+ (NSString*)modelCacheRoot {
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = a.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"OpenScribe"];
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

- (NSString*)cacheDirForFile:(NSString*)inputPath model:(NSString*)model {
    NSString* canon = inputPath.stringByStandardizingPath;
    NSString* hash = [[self class] sha256OfString:canon];
    NSString* safeModel = model.length ? model : @"htdemucs";
    return [[[[self class] cacheRoot] stringByAppendingPathComponent:hash]
                                      stringByAppendingPathComponent:safeModel];
}

- (NSArray<StemSeparation*>*)cachedStemsForFile:(NSString*)inputPath
                                          model:(NSString*)model {
    NSString* dir = [self cacheDirForFile:inputPath model:model];
    NSString* manifest = [dir stringByAppendingPathComponent:@"stems.json"];
    NSData* data = [NSData dataWithContentsOfFile:manifest];
    if (!data) return @[];
    NSError* err = nil;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:&err];
    if (![root isKindOfClass:NSDictionary.class]) return @[];
    NSArray* stems = root[@"stems"];
    if (![stems isKindOfClass:NSArray.class]) return @[];

    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<StemSeparation*>* out = [NSMutableArray arrayWithCapacity:stems.count];
    for (NSDictionary* entry in stems) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString* name = entry[@"name"];
        NSString* file = entry[@"file"];
        if (!name.length || !file.length) continue;
        NSString* full = [dir stringByAppendingPathComponent:file];
        if (![fm fileExistsAtPath:full]) return @[]; // partial cache → reject
        StemSeparation* s = [[StemSeparation alloc] init];
        s.name = name;
        s.path = full;
        [out addObject:s];
    }
    return out;
}

- (BOOL)hasCachedStemsForFile:(NSString*)inputPath model:(NSString*)model {
    NSArray* cached = [self cachedStemsForFile:inputPath model:model];
    return cached.count >= 2;
}

#pragma mark - run

- (void)separateFile:(NSString*)inputPath model:(NSString*)model {
    if (!self.isHelperAvailable) {
        [self emitError:@"Stem helper not found. Expected tools/stem-helper/ next to the app."];
        return;
    }
    if (self.isRunning) {
        [self emitError:@"A separation is already running."];
        return;
    }
    NSString* m = model.length ? model : @"htdemucs";
    _runningModel = m;

    NSString* outDir = [self cacheDirForFile:inputPath model:m];
    [NSFileManager.defaultManager createDirectoryAtPath:outDir
                            withIntermediateDirectories:YES
                                             attributes:nil error:nil];

    NSString* py = [self resolvePython];
    if (!py) {
        [self emitError:@"Stem helper python interpreter not found."];
        return;
    }
    NSString* script = [_helperDir stringByAppendingPathComponent:@"separate.py"];
    NSString* sitePackages = [self bundledSitePackages];

    // Per-user model cache. Lives outside the .app so:
    //   1. The bundled helper directory stays untouched (codesign survives),
    //   2. Models persist across app updates,
    //   3. Multiple bundle locations share the same downloads.
    NSString* cacheRoot = [[self class] modelCacheRoot];
    NSString* torchHome = [cacheRoot stringByAppendingPathComponent:@"torch_cache"];
    NSString* sepModels = [cacheRoot stringByAppendingPathComponent:@"audio_separator_models"];
    [NSFileManager.defaultManager createDirectoryAtPath:torchHome
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:sepModels
                            withIntermediateDirectories:YES attributes:nil error:nil];

    _task = [[NSTask alloc] init];
    _task.launchPath = py;
    _task.arguments = @[ script,
                         @"--input", inputPath,
                         @"--output-dir", outDir,
                         @"--model", m ];
    _task.currentDirectoryPath = _helperDir;

    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"TORCH_HOME"] = torchHome;
    env[@"OPENSCRIBE_AUDIO_SEPARATOR_MODELS"] = sepModels;
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
    NSString* expectedModel = [m copy];
    _task.terminationHandler = ^(NSTask* t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf taskDidExit:t forInput:expectedInput model:expectedModel];
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
        } else if ([line hasPrefix:@"stage:"]) {
            NSString* msg = [[line substringFromIndex:6]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            __weak StemSeparator* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                StemSeparator* s = weakSelf;
                if (s && [s.delegate respondsToSelector:@selector(stemSeparator:stage:)]) {
                    [s.delegate stemSeparator:s stage:msg];
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

- (void)taskDidExit:(NSTask*)t forInput:(NSString*)inputPath model:(NSString*)model {
    _stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    _stderrPipe.fileHandleForReading.readabilityHandler = nil;

    int status = t.terminationStatus;
    NSTaskTerminationReason reason = t.terminationReason;
    _task = nil;
    _runningModel = nil;

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

    NSArray<StemSeparation*>* stems = [self cachedStemsForFile:inputPath model:model];
    if (stems.count < 2) {
        [self emitError:@"Helper succeeded but stems.json is missing or empty."];
        return;
    }

    if ([_delegate respondsToSelector:@selector(stemSeparator:didFinishWithStems:model:)]) {
        [_delegate stemSeparator:self didFinishWithStems:stems model:model];
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

    // Preferred for production: helper bundled inside the .app at
    // Contents/Resources/stem-helper/. Self-contained — new users get a
    // working install on first launch with no external setup.
    NSString* bundled = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"stem-helper"];
    if ([self looksLikeHelperDir:bundled]) return bundled;

    // Dev override: ~/Library/Application Support/OpenScribe/stem-helper/.
    // Lets developers iterate on the helper without rebundling the .app.
    // Lives outside TCC-protected user folders (Desktop/Documents/Downloads),
    // so Python's per-import file reads don't get throttled by amfid/syspolicyd.
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = a.firstObject;
    if (appSupport.length) {
        NSString* cand = [[appSupport stringByAppendingPathComponent:@"OpenScribe"]
                                      stringByAppendingPathComponent:@"stem-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
    }

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
    NSString* sc = [dir stringByAppendingPathComponent:@"separate.py"];
    if (![fm fileExistsAtPath:sc]) return NO;

    // Either dev venv layout, or bundled site-packages layout. resolvePython
    // (instance method) does the full check including the bundled python
    // interpreter; here we only need a cheap structural sniff.
    NSString* venvPy = [dir stringByAppendingPathComponent:@"venv/bin/python"];
    if ([fm isExecutableFileAtPath:venvPy]) return YES;
    NSString* site = [dir stringByAppendingPathComponent:@"site-packages"];
    return [fm fileExistsAtPath:site];
}

@end
