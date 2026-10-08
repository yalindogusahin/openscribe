#import <Cocoa/Cocoa.h>

@interface IRealLibrary : NSWindowController
@property (nonatomic, copy) void (^selectionHandler)(NSURL* pdfURL);
- (void)showLibrary;
@end
