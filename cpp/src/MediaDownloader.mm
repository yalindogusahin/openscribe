#import "MediaDownloader.h"
#import <CommonCrypto/CommonDigest.h>

// Matches SettingsWindowController's kPrefCookiesBrowser — duplicated (not
// shared via header) so this file stays self-contained.
static NSString* const kPrefCookiesBrowser = @"openscribe.cookiesBrowser";

@implementation MediaDownloader {
    NSTask*  _task;
    NSPipe*  _stdoutPipe;
    NSPipe*  _stderrPipe;
    NSMutableString* _stdoutTail;
    NSMutableString* _stderrTail;
    NSString* _runningURL;
    NSString* _runningOutDir;
    NSString* _runningPath;
    NSString* _runningTitle;
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
                [_helperDir stringByAppendingPathComponent:@"download.py"]];
}

// Mirrors StemSeparator: prefer a dev venv if one exists, otherwise fall
// back to the bundled python interpreter + sibling site-packages.
- (NSString*)resolvePython {
    if (_helperDir.length == 0) return nil;
    NSFileManager* fm = NSFileManager.defaultManager;

    NSString* venvPy = [_helperDir stringByAppendingPathComponent:@"venv/bin/python"];
    if ([fm isExecutableFileAtPath:venvPy]) return venvPy;

    NSString* site = [self bundledSitePackages];
    if (!site) return nil;
    NSString* bundledPy = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"python/bin/python3.11"];
    if ([fm isExecutableFileAtPath:bundledPy]) return bundledPy;
    return nil;
}

// In production both helpers share Resources/python/ + a single
// site-packages tree under one of the helper dirs. Probe the media-helper
// dir first, then fall back to the stem-helper's, since bundle_helper.sh
// installs everything into stem-helper/site-packages.
- (NSString*)bundledSitePackages {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* local = [_helperDir stringByAppendingPathComponent:@"site-packages"];
    if ([fm fileExistsAtPath:local]) return local;
    NSString* shared = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"stem-helper/site-packages"];
    if ([fm fileExistsAtPath:shared]) return shared;
    return nil;
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
                            stringByAppendingPathComponent:@"youtube"];
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

+ (NSString*)cacheDirForURL:(NSString*)url {
    NSString* trimmed = [url stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* hash = [self sha256OfString:trimmed];
    return [[self cacheRoot] stringByAppendingPathComponent:hash];
}

- (NSDictionary*)manifestForURL:(NSString*)url {
    NSString* dir = [[self class] cacheDirForURL:url];
    NSString* manifest = [dir stringByAppendingPathComponent:@"manifest.json"];
    NSData* data = [NSData dataWithContentsOfFile:manifest];
    if (!data) return nil;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:nil];
    return [root isKindOfClass:NSDictionary.class] ? root : nil;
}

- (NSString*)cachedPathForURL:(NSString*)url {
    NSDictionary* m = [self manifestForURL:url];
    NSString* p = m[@"filepath"];
    if (![p isKindOfClass:NSString.class]) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:p]) return nil;
    return p;
}

- (NSString*)cachedTitleForURL:(NSString*)url {
    NSDictionary* m = [self manifestForURL:url];
    NSString* t = m[@"title"];
    return [t isKindOfClass:NSString.class] ? t : nil;
}

#pragma mark - run

- (void)downloadURL:(NSString*)url {
    if (!self.isHelperAvailable) {
        [self emitError:@"YouTube/Instagram helper not found. Expected tools/media-helper/ next to the app."];
        return;
    }
    if (self.isRunning) {
        [self emitError:@"A download is already running."];
        return;
    }

    NSString* trimmed = [url stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        [self emitError:@"Empty URL."];
        return;
    }

    NSString* cached = [self cachedPathForURL:trimmed];
    if (cached) {
        NSString* title = [self cachedTitleForURL:trimmed] ?: cached.lastPathComponent;
        if ([_delegate respondsToSelector:@selector(mediaDownloader:progress:)]) {
            [_delegate mediaDownloader:self progress:1.0];
        }
        if ([_delegate respondsToSelector:@selector(mediaDownloader:didFinishWithPath:title:)]) {
            [_delegate mediaDownloader:self didFinishWithPath:cached title:title];
        }
        return;
    }

    NSString* outDir = [[self class] cacheDirForURL:trimmed];
    [NSFileManager.defaultManager createDirectoryAtPath:outDir
                            withIntermediateDirectories:YES
                                             attributes:nil error:nil];

    NSString* py = [self resolvePython];
    if (!py) {
        [self emitError:@"YouTube/Instagram helper python interpreter not found."];
        return;
    }
    NSString* script = [_helperDir stringByAppendingPathComponent:@"download.py"];
    NSString* sitePackages = [self bundledSitePackages];

    _runningURL = [trimmed copy];
    _runningOutDir = [outDir copy];
    _runningPath = nil;
    _runningTitle = nil;

    NSMutableArray<NSString*>* taskArgs = [@[ script,
                         @"--url", trimmed,
                         @"--output-dir", outDir ] mutableCopy];
    NSString* cookiesBrowser = [[NSUserDefaults standardUserDefaults]
        stringForKey:kPrefCookiesBrowser];
    if (cookiesBrowser.length) {
        [taskArgs addObjectsFromArray:@[ @"--cookies-from-browser", cookiesBrowser ]];
    }

    _task = [[NSTask alloc] init];
    _task.launchPath = py;
    _task.arguments = taskArgs;
    _task.currentDirectoryPath = _helperDir;

    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PYTHONUNBUFFERED"] = @"1";
    if (sitePackages.length) {
        env[@"PYTHONPATH"] = sitePackages;
    }
    NSString* basePath = env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    env[@"PATH"] = [@"/opt/homebrew/bin:/usr/local/bin:"
                        stringByAppendingString:basePath];
    _task.environment = env;

    _stdoutPipe = [NSPipe pipe];
    _stderrPipe = [NSPipe pipe];
    _task.standardOutput = _stdoutPipe;
    _task.standardError  = _stderrPipe;
    [_stdoutTail setString:@""];
    [_stderrTail setString:@""];

    __weak MediaDownloader* weakSelf = self;
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
        [self handleStdoutLine:line];
    }
}

- (void)handleStdoutLine:(NSString*)line {
    if ([line hasPrefix:@"progress:"]) {
        double frac = [[line substringFromIndex:9] doubleValue];
        __weak MediaDownloader* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MediaDownloader* s = weakSelf;
            if (s && [s.delegate respondsToSelector:@selector(mediaDownloader:progress:)]) {
                [s.delegate mediaDownloader:s progress:frac];
            }
        });
    } else if ([line hasPrefix:@"stage:"]) {
        NSString* msg = [[line substringFromIndex:6]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        __weak MediaDownloader* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MediaDownloader* s = weakSelf;
            if (s && [s.delegate respondsToSelector:@selector(mediaDownloader:stage:)]) {
                [s.delegate mediaDownloader:s stage:msg];
            }
        });
    } else if ([line hasPrefix:@"title:"]) {
        _runningTitle = [[line substringFromIndex:6]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    } else if ([line hasPrefix:@"path:"]) {
        _runningPath = [[line substringFromIndex:5]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
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
    NSString* path = [_runningPath copy];
    NSString* title = [_runningTitle copy];
    NSString* tail = [_stderrTail copy];
    _task = nil;
    _runningURL = nil;
    _runningOutDir = nil;
    _runningPath = nil;
    _runningTitle = nil;

    if (reason != NSTaskTerminationReasonExit || status != 0) {
        NSString* msg;
        if (reason != NSTaskTerminationReasonExit) {
            msg = @"Download cancelled.";
        } else {
            // Pull the most recent "error: ..." line from stderr if present —
            // it's the actionable message. Otherwise show the tail.
            NSString* err = [self lastErrorLineIn:tail];
            if (err.length) {
                msg = err;
            } else {
                msg = [NSString stringWithFormat:@"Helper exited with status %d.\n%@",
                       status, tail.length ? tail : @""];
            }
        }
        [self emitError:msg];
        return;
    }

    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [self emitError:@"Helper finished but no audio file was produced."];
        return;
    }

    NSString* finalTitle = title.length ? title : path.lastPathComponent;
    if ([_delegate respondsToSelector:@selector(mediaDownloader:didFinishWithPath:title:)]) {
        [_delegate mediaDownloader:self didFinishWithPath:path title:finalTitle];
    }
}

- (NSString*)lastErrorLineIn:(NSString*)stderrTail {
    if (!stderrTail.length) return nil;
    NSArray<NSString*>* lines = [stderrTail componentsSeparatedByString:@"\n"];
    for (NSString* line in lines.reverseObjectEnumerator) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"error: "]) return [trimmed substringFromIndex:7];
    }
    return nil;
}

- (void)emitError:(NSString*)msg {
    if ([_delegate respondsToSelector:@selector(mediaDownloader:didFailWithError:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate mediaDownloader:self didFailWithError:msg];
        });
    } else {
        NSLog(@"[MediaDownloader] %@", msg);
    }
}

#pragma mark - helper discovery

+ (NSString*)resolveHelperDir {
    NSString* fromEnv = NSProcessInfo.processInfo.environment[@"OPENSCRIBE_MEDIA_HELPER"];
    if ([self looksLikeHelperDir:fromEnv]) return fromEnv;

    // Production: bundled at Contents/Resources/media-helper/.
    NSString* bundled = [NSBundle.mainBundle.resourcePath
                            stringByAppendingPathComponent:@"media-helper"];
    if ([self looksLikeHelperDir:bundled]) return bundled;

    // Dev override under Application Support — same convention as stem-helper.
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = a.firstObject;
    if (appSupport.length) {
        NSString* cand = [[appSupport stringByAppendingPathComponent:@"OpenScribe"]
                                      stringByAppendingPathComponent:@"media-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
    }

    // Walk up from the app bundle looking for tools/media-helper/.
    NSString* base = NSBundle.mainBundle.bundlePath;
    for (int i = 0; i < 6 && base.length > 1; i++) {
        NSString* cand = [[base stringByAppendingPathComponent:@"tools"]
                                 stringByAppendingPathComponent:@"media-helper"];
        if ([self looksLikeHelperDir:cand]) return cand;
        base = base.stringByDeletingLastPathComponent;
    }
    return nil;
}

+ (BOOL)looksLikeHelperDir:(NSString*)dir {
    if (dir.length == 0) return NO;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* sc = [dir stringByAppendingPathComponent:@"download.py"];
    if (![fm fileExistsAtPath:sc]) return NO;

    // Either a dev venv exists locally, OR the bundled site-packages exists
    // (locally or shared via stem-helper). resolvePython handles the full
    // check at runtime; here we just confirm the script is present.
    return YES;
}

@end
