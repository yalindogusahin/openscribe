#import <Cocoa/Cocoa.h>

@interface TimelineRulerView : NSView
@property (nonatomic) double viewStart;   // 0..1 of duration
@property (nonatomic) double viewEnd;     // 0..1 of duration
@property (nonatomic) double duration;    // seconds
- (void)updateViewStart:(double)start end:(double)end duration:(double)dur;
@end
