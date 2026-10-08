#import "ChordRecognizer.h"
#include <cmath>

@implementation ChordRecognizer {
    NSTask* _task;
    BOOL _cancelled;
}

- (NSString*)helperDirectory {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    NSString* override = NSProcessInfo.processInfo.environment[@"OPENSCRIBE_CHORD_HELPER"];
    if (override.length) [candidates addObject:override];
    NSString* resources = NSBundle.mainBundle.resourcePath;
    if (resources) [candidates addObject:[resources stringByAppendingPathComponent:@"chord-helper"]];
    NSString* base = NSBundle.mainBundle.bundlePath;
    for (int i = 0; i < 6 && base.length > 1; ++i) {
        [candidates addObject:[base stringByAppendingPathComponent:@"tools/chord-helper"]];
        base = base.stringByDeletingLastPathComponent;
    }
    for (NSString* candidate in candidates) {
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@"chord.py"]]) return candidate;
    }
    return nil;
}

- (NSString*)pythonPath {
    NSString* resources = NSBundle.mainBundle.resourcePath;
    NSString* bundled = [resources stringByAppendingPathComponent:@"python/bin/python3.11"];
    if ([NSFileManager.defaultManager isExecutableFileAtPath:bundled]) return bundled;
    NSString* dev = [[[self helperDirectory] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"stem-helper/venv/bin/python"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:dev] ? dev : nil;
}

- (BOOL)isHelperAvailable { return [self helperDirectory] && [self pythonPath]; }
- (BOOL)isRunning { return _task != nil; }

- (void)recognizeFile:(NSString*)path {
    if (self.isRunning) return;
    if (!self.isHelperAvailable) {
        [self.delegate chordRecognizer:self didFailWithError:@"Chord helper is not installed."];
        return;
    }
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self.delegate chordRecognizer:self didFailWithError:error.localizedDescription];
        return;
    }
    NSString* output = [directory stringByAppendingPathComponent:@"chords.json"];
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[self pythonPath]];
    task.arguments = @[[[self helperDirectory] stringByAppendingPathComponent:@"chord.py"],
                       @"--input", path, @"--output", output];
    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PYTHONUNBUFFERED"] = @"1";
    NSString* site = [NSBundle.mainBundle.resourcePath
        stringByAppendingPathComponent:@"stem-helper/site-packages"];
    if ([NSFileManager.defaultManager fileExistsAtPath:site]) env[@"PYTHONPATH"] = site;
    task.environment = env;
    NSPipe* stdoutPipe = [NSPipe pipe];
    NSPipe* stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    _cancelled = NO;
    _task = task;
    if (![task launchAndReturnError:&error]) {
        _task = nil;
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        [self.delegate chordRecognizer:self didFailWithError:error.localizedDescription];
        return;
    }

    // Drain both pipes concurrently. Completion waits for EOF on both so a
    // short-lived helper cannot lose its final progress or error message.
    dispatch_group_t readers = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block NSString* stderrText = @"";
    dispatch_group_async(readers, queue, ^{
        NSMutableData* pending = [NSMutableData data];
        for (;;) {
            NSData* chunk = stdoutPipe.fileHandleForReading.availableData;
            if (!chunk.length) break;
            [pending appendData:chunk];
            NSData* newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
            for (;;) {
                NSRange range = [pending rangeOfData:newline options:0 range:NSMakeRange(0, pending.length)];
                if (range.location == NSNotFound) break;
                NSString* line = [[NSString alloc] initWithData:[pending subdataWithRange:
                    NSMakeRange(0, range.location)] encoding:NSUTF8StringEncoding];
                [pending replaceBytesInRange:NSMakeRange(0, NSMaxRange(range)) withBytes:NULL length:0];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([line hasPrefix:@"progress:"]) {
                        double fraction = [[line substringFromIndex:9] doubleValue];
                        [self.delegate chordRecognizer:self progress:fmax(0, fmin(1, fraction))];
                    } else if ([line hasPrefix:@"stage:"]) {
                        [self.delegate chordRecognizer:self stage:[[line substringFromIndex:6]
                            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
                    }
                });
            }
        }
    });
    dispatch_group_async(readers, queue, ^{
        NSMutableData* tail = [NSMutableData data];
        for (;;) {
            NSData* chunk = stderrPipe.fileHandleForReading.availableData;
            if (!chunk.length) break;
            [tail appendData:chunk];
            if (tail.length > 8000) [tail replaceBytesInRange:NSMakeRange(0, tail.length - 8000)
                                                               withBytes:NULL length:0];
        }
        stderrText = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding] ?: @"";
    });
    dispatch_async(queue, ^{
        [task waitUntilExit];
        dispatch_group_notify(readers, dispatch_get_main_queue(), ^{
            self->_task = nil;
            NSData* data = [NSData dataWithContentsOfFile:output];
            id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            if (self->_cancelled || task.terminationStatus != 0) {
                NSString* message = self->_cancelled ? @"Chord detection cancelled." :
                    (stderrText.length ? stderrText : @"Chord detection failed.");
                [self.delegate chordRecognizer:self didFailWithError:message];
                return;
            }
            BOOL valid = [result isKindOfClass:NSDictionary.class];
            NSArray* chords = valid ? result[@"chords"] : nil;
            NSNumber* tempo = valid ? result[@"tempo"] : nil;
            valid = [chords isKindOfClass:NSArray.class] && [tempo isKindOfClass:NSNumber.class]
                && std::isfinite(tempo.doubleValue);
            if (valid) for (id chord in chords) {
                if (![chord isKindOfClass:NSDictionary.class]
                    || ![chord[@"start"] isKindOfClass:NSNumber.class]
                    || ![chord[@"end"] isKindOfClass:NSNumber.class]
                    || ![chord[@"label"] isKindOfClass:NSString.class]
                    || !std::isfinite([chord[@"start"] doubleValue])
                    || !std::isfinite([chord[@"end"] doubleValue])
                    || [chord[@"start"] doubleValue] < 0
                    || [chord[@"end"] doubleValue] <= [chord[@"start"] doubleValue]) {
                    valid = NO;
                    break;
                }
            }
            if (!valid) {
                [self.delegate chordRecognizer:self didFailWithError:@"Chord helper returned invalid output."];
                return;
            }
            [self.delegate chordRecognizer:self didFinishWithChords:chords tempo:tempo.doubleValue];
        });
    });
}

- (void)cancel {
    if (_task) {
        _cancelled = YES;
        if (_task.running) [_task terminate];
    }
}
@end
