#import <MetalKit/MetalKit.h>

#include <vector>

class AudioEngine;

@interface WaveformView : MTKView
- (instancetype)initWithFrame:(NSRect)frame engine:(AudioEngine*)engine;
- (void)reloadFromEngine;

// Bookmarks: array of NSNumber doubles (seconds). Set by app delegate.
@property (nonatomic, copy) NSArray<NSNumber*>* bookmarks;

// View window accessors (fraction of duration, 0..1).
- (double)viewStart;
- (double)viewEnd;
- (void)setViewStart:(double)start end:(double)end;

@property (nonatomic, copy) void (^fileDropHandler)(NSString* path);
@end
