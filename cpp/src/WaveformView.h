#import <MetalKit/MetalKit.h>

#include <vector>

class AudioEngine;

@interface WaveformView : MTKView
- (instancetype)initWithFrame:(NSRect)frame engine:(AudioEngine*)engine;
- (void)reloadFromEngine;
@property (nonatomic, copy) void (^fileDropHandler)(NSString* path);
@end
