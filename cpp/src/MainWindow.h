#import <Cocoa/Cocoa.h>

@class WaveformView;
class AudioEngine;

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

- (void)updatePlayPauseButton:(BOOL)playing;
@end
