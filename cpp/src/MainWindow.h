#import <Cocoa/Cocoa.h>

@class WaveformView;
class AudioEngine;

// NSSlider subclass that snaps back to a designated default value on a
// double-click (and fires its action so dependent UI / engine state stays
// in sync). Drop-in replacement — single-clicks behave identically.
@interface OSResettableSlider : NSSlider
@property (nonatomic, assign) double resetValue;
@end

// Adopted by the stem mixer sidebar so a row can ask its parent to handle
// the drag-to-reorder gesture. Lets the row delegate the heavy lifting
// (mouse tracking loop + visual reflow) without exposing the sidebar class
// itself across files.
@protocol OSStemRowDragHost <NSObject>
- (void)beginDragForRow:(NSView*)row event:(NSEvent*)event;
@end

@interface MainWindow : NSWindow
- (instancetype)initWithEngine:(AudioEngine*)engine;
@property (nonatomic, strong, readonly) WaveformView* waveformView;
@property (nonatomic, strong, readonly) NSTextField* timeLabel;
@property (nonatomic, strong, readonly) NSSlider* speedSlider;
@property (nonatomic, strong, readonly) NSTextField* speedLabel;
@property (nonatomic, strong, readonly) NSSlider* pitchSlider;
@property (nonatomic, strong, readonly) NSTextField* pitchLabel;
@property (nonatomic, strong, readonly) NSSlider* volumeSlider;
@property (nonatomic, strong, readonly) NSTextField* volumeLabel;
@property (nonatomic, strong, readonly) NSButton* speedResetButton;
@property (nonatomic, strong, readonly) NSButton* pitchResetButton;
@property (nonatomic, strong, readonly) NSButton* volumeResetButton;
@property (nonatomic, strong, readonly) NSView* dropHintContainer;

@property (nonatomic, strong, readonly) NSButton* startButton;
@property (nonatomic, strong, readonly) NSButton* skipBackButton;
@property (nonatomic, strong, readonly) NSButton* playPauseButton;
@property (nonatomic, strong, readonly) NSButton* skipForwardButton;

@property (nonatomic, strong, readonly) NSTextField* loopBadge;
@property (nonatomic, strong, readonly) NSButton* helpButton;
@property (nonatomic, strong, readonly) NSButton* smartLoopButton;
@property (nonatomic, strong, readonly) NSButton* isolateButton;

// Left-of-waveform mixer strip. Empty until populated by the app delegate.
// Subviews placed directly here are laid out as N equal-height rows, top-down,
// matching the per-stem lane layout in the waveform view.
@property (nonatomic, strong, readonly) NSView* stemSidebar;

// Show/hide the sidebar; when shown the waveform shrinks to make room.
- (void)setStemSidebarVisible:(BOOL)visible;

// Block invoked when the user drags a stem row to a new slot in the sidebar.
// Indices refer to the sidebar's row order (0 = topmost). Caller is expected
// to permute the engine + waveform peaks to match.
- (void)setStemReorderHandler:(void (^)(NSInteger from, NSInteger to))handler;

- (void)updatePlayPauseButton:(BOOL)playing;
@end
