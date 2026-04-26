#import <MetalKit/MetalKit.h>

#include <vector>

class AudioEngine;

@interface WaveformView : MTKView
- (instancetype)initWithFrame:(NSRect)frame engine:(AudioEngine*)engine;
- (void)reloadFromEngine;

// Bookmarks: array of NSDictionary entries with keys "time" (NSNumber seconds)
// and "label" (NSString, possibly empty). Set by app delegate.
@property (nonatomic, copy) NSArray<NSDictionary*>* bookmarks;

// Click handlers for bookmark badges in the labels overlay.
@property (nonatomic, copy) void (^bookmarkJumpHandler)(NSInteger index);
@property (nonatomic, copy) void (^bookmarkRenameHandler)(NSInteger index);
@property (nonatomic, copy) void (^bookmarkRemoveHandler)(NSInteger index);

// View window accessors (fraction of duration, 0..1).
- (double)viewStart;
- (double)viewEnd;
- (void)setViewStart:(double)start end:(double)end;

@property (nonatomic, copy) void (^fileDropHandler)(NSString* path);
@end
