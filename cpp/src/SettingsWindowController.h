#import <Cocoa/Cocoa.h>

class AudioEngine;

@interface SettingsWindowController : NSWindowController
+ (instancetype)sharedController;
- (void)setEngine:(AudioEngine*)engine;
- (void)showWindow;
@end
