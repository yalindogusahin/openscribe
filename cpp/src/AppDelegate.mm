#import "AppDelegate.h"
#import "MainWindow.h"
#import "AudioEngine.h"
#import "WaveformView.h"
#import "SettingsWindowController.h"
#import "StemSeparator.h"
#import "BasicPitchTranscriber.h"
#import "ChordRecognizer.h"
#import "MediaDownloader.h"

#import <CommonCrypto/CommonCrypto.h>

#include <algorithm>
#include <cmath>
#include <memory>

@interface OSFlippedView : NSView @end
@implementation OSFlippedView - (BOOL)isFlipped { return YES; } @end

// One row of the per-stem mixer sidebar. The row's frame is sized by the
// sidebar; this class lays out its 5 child controls (name, M, S, gain
// slider, gain %) into the row whenever it's resized.
@interface OSStemMixerRow : NSView
@property (nonatomic, weak) NSTextField* nameLabel;
@property (nonatomic, weak) NSButton*    muteButton;
@property (nonatomic, weak) NSButton*    soloButton;
@property (nonatomic, weak) NSSlider*    gainSlider;
@property (nonatomic, weak) NSTextField* gainLabel;
@property (nonatomic, weak) NSTextField* gainMinLabel;
@property (nonatomic, weak) NSTextField* gainMaxLabel;
@end

@implementation OSStemMixerRow
- (BOOL)isFlipped { return YES; }

// Forward whole-row clicks to the sidebar so it can run the drag-to-reorder
// gesture. Clicks that land on the M/S buttons or the gain slider are
// dispatched directly to those subviews by the standard hitTest path and
// never reach this method, so we don't need to filter them out here.
- (void)mouseDown:(NSEvent*)event {
    if ([self.superview conformsToProtocol:@protocol(OSStemRowDragHost)]) {
        [(id<OSStemRowDragHost>)self.superview beginDragForRow:self event:event];
        return;
    }
    [super mouseDown:event];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    (void)oldSize;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    CGFloat pad = 8;
    CGFloat gap = 4;
    CGFloat btnW = 24;
    CGFloat valW = 44;
    CGFloat nameH = 16;
    CGFloat ctrlH = 20;
    CGFloat boundLblH = 10;
    CGFloat boundGap = 1;
    CGFloat rowGap = 4;
    // Two-line layout: the single-line layout left only ~56pt of slider
    // width inside a 220pt sidebar, which made fine gain adjustments
    // fiddly. Splitting the row into "name + value" on top and
    // "M / S / slider" below frees the slider to span almost the whole
    // sidebar width.
    BOOL showBounds = (H >= nameH + rowGap + ctrlH + boundGap + boundLblH + 6);
    CGFloat boundExtra = showBounds ? (boundGap + boundLblH) : 0;
    CGFloat groupH = nameH + rowGap + ctrlH + boundExtra;
    CGFloat top = (H - groupH) / 2.0;
    if (top < 4) top = 4;

    // Top line — stem name on the left, current gain percentage on the right.
    CGFloat topLineW = W - 2 * pad;
    self.nameLabel.frame = NSMakeRect(pad, top, topLineW - valW - gap, nameH);
    self.gainLabel.frame = NSMakeRect(W - pad - valW, top, valW, nameH);

    // Bottom line — mute, solo, slider.
    CGFloat ctrlsY = top + nameH + rowGap;
    self.muteButton.frame = NSMakeRect(pad, ctrlsY, btnW, ctrlH);
    self.soloButton.frame = NSMakeRect(pad + btnW + gap, ctrlsY, btnW, ctrlH);
    CGFloat sliderX = pad + 2 * (btnW + gap);
    CGFloat sliderW = W - pad - sliderX;
    if (sliderW < 24) sliderW = 24;
    self.gainSlider.frame = NSMakeRect(sliderX, ctrlsY + 1, sliderW, ctrlH - 2);

    if (showBounds) {
        CGFloat boundY = ctrlsY + ctrlH + boundGap;
        CGFloat halfW = sliderW / 2.0;
        self.gainMinLabel.hidden = NO;
        self.gainMaxLabel.hidden = NO;
        self.gainMinLabel.frame = NSMakeRect(sliderX, boundY, halfW, boundLblH);
        self.gainMaxLabel.frame = NSMakeRect(sliderX + halfW, boundY, halfW, boundLblH);
    } else {
        self.gainMinLabel.hidden = YES;
        self.gainMaxLabel.hidden = YES;
    }
}
@end

namespace {
struct SmartLoopState {
    bool enabled = false;
    double startSpeed = 0.5;
    double endSpeed = 1.0;
    double stepSize = 0.1;
    int repeatsPerStep = 3;

    int64_t lastSeenWrapCount = 0;
    int currentStepIterations = 0;
};

struct Bookmark {
    double time = 0.0;
    NSString* label = @"";
};

struct IsolateState {
    double centerCancel = 0.0;        // 0..1, vocal-cancel amount
    bool   bassFocusEnabled = false;
    double bassFocusCutoffHz = 250.0; // 60..2000
};
}

// Forward declarations: defined alongside the isolate-popover code further
// down the file but referenced earlier when wiring the bass-focus slider's
// double-click reset value.
static double sliderToHz(double s);
static double hzToSlider(double hz);

// Row model for the Downloads Manager table — one entry per cached
// YouTube download dir. Built from the manifest.json the helper writes
// alongside each downloaded audio file.
@interface OSDownloadItem : NSObject
@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy) NSString* dir;          // hash dir on disk
@property (nonatomic, copy) NSString* audioPath;    // absolute path to .m4a/.webm
@property (nonatomic, copy) NSString* url;
@property (nonatomic, assign) double durationSeconds;
@property (nonatomic, assign) long long sizeBytes;  // dir total
@property (nonatomic, strong) NSDate* downloadedAt;
@end
@implementation OSDownloadItem
@end

// Row model for the Stem Cache view — one entry per <stems>/<hash>/<model>
// directory. The hash is sha256 of the source audio's standardized path,
// so we cross-reference with download manifests to recover a friendly
// title; otherwise the source shows as unknown.
@interface OSStemCacheItem : NSObject
@property (nonatomic, copy) NSString* dir;          // .../stems/<hash>/<model>
@property (nonatomic, copy) NSString* hashName;     // sha256 dir name
@property (nonatomic, copy) NSString* model;        // htdemucs / htdemucs_6s
@property (nonatomic, copy) NSString* sourceTitle;  // resolved from downloads, or nil
@property (nonatomic, assign) long long sizeBytes;
@property (nonatomic, strong) NSDate* createdAt;
@end
@implementation OSStemCacheItem
@end

@interface AppDelegate () <StemSeparatorDelegate,
                           BasicPitchTranscriberDelegate,
                           ChordRecognizerDelegate,
                           MediaDownloaderDelegate,
                           NSTableViewDataSource,
                           NSTableViewDelegate> {
    std::unique_ptr<AudioEngine> _engine;
    id _keyMonitor;
    BOOL _torndown;
    std::vector<Bookmark> _bookmarks;
    NSTimeInterval _lastBookmarkToggleTime;
    SmartLoopState _smartLoop;
    IsolateState _isolate;
}
@property (nonatomic, strong) MainWindow* mainWindow;
@property (nonatomic, strong) NSTimer* timeTimer;
@property (nonatomic, copy) NSString* currentFilePath;
@property (nonatomic, strong) NSMenu* recentSubmenu;

// Smart loop popover controls (kept around so we can refresh values).
@property (nonatomic, strong) NSPopover* smartLoopPopover;
@property (nonatomic, strong) NSButton* smartLoopToggle;
@property (nonatomic, strong) NSSlider* smartLoopStartSlider;
@property (nonatomic, strong) NSSlider* smartLoopEndSlider;
@property (nonatomic, strong) NSSlider* smartLoopStepSlider;
@property (nonatomic, strong) NSStepper* smartLoopRepeatsStepper;
@property (nonatomic, strong) NSTextField* smartLoopStartLabel;
@property (nonatomic, strong) NSTextField* smartLoopEndLabel;
@property (nonatomic, strong) NSTextField* smartLoopStepLabel;
@property (nonatomic, strong) NSTextField* smartLoopRepeatsLabel;
@property (nonatomic, strong) NSTextField* smartLoopStatusLabel;

// Isolate popover controls.
@property (nonatomic, strong) NSPopover* isolatePopover;
@property (nonatomic, strong) NSSlider* vocalCancelSlider;
@property (nonatomic, strong) NSTextField* vocalCancelLabel;
@property (nonatomic, strong) NSButton* bassFocusToggle;
@property (nonatomic, strong) NSSlider* bassFocusSlider;
@property (nonatomic, strong) NSTextField* bassFocusLabel;

// Stem separation + mixer controls (live in the isolate popover, rebuilt
// from scratch each time the popover opens).
@property (nonatomic, strong) StemSeparator* stemSeparator;
@property (nonatomic, strong) NSButton* separateStemsButton;
@property (nonatomic, strong) NSProgressIndicator* separateProgress;
@property (nonatomic, strong) NSTextField* separateStatusLabel;
@property (nonatomic, strong) NSPopUpButton* stemModelPopup;
@property (nonatomic, copy)   NSString* currentSeparateStage;
@property (nonatomic, assign) NSTimeInterval separateStartTime;
@property (nonatomic, strong) NSTimer* separateElapsedTimer;
@property (nonatomic, strong) NSArray<NSButton*>* stemMuteButtons;
@property (nonatomic, strong) NSArray<NSButton*>* stemSoloButtons;
@property (nonatomic, strong) NSArray<NSSlider*>* stemGainSliders;
@property (nonatomic, strong) NSArray<NSTextField*>* stemGainLabels;

// Parallel sets backing the always-visible sidebar mixer in the main window.
// Same target/action wiring as the popover rows; both reflect engine state.
@property (nonatomic, strong) NSArray<NSButton*>*    sidebarStemMuteButtons;
@property (nonatomic, strong) NSArray<NSButton*>*    sidebarStemSoloButtons;
@property (nonatomic, strong) NSArray<NSSlider*>*    sidebarStemGainSliders;
@property (nonatomic, strong) NSArray<NSTextField*>* sidebarStemGainLabels;

@property (nonatomic, copy) NSArray<NSString*>* currentStemNames;
@property (nonatomic, copy) NSArray<NSString*>* currentStemPaths;
@property (nonatomic, copy) NSString* stemModel;  // "htdemucs" or "htdemucs_6s"

// Basic Pitch transcription. Reuses the bundled stem-helper python.
@property (nonatomic, strong) BasicPitchTranscriber* basicPitch;
@property (nonatomic, strong) NSWindow* transcribeProgressSheet;
@property (nonatomic, strong) NSProgressIndicator* transcribeProgressBar;
@property (nonatomic, strong) NSTextField* transcribeStatusLabel;
@property (nonatomic, copy)   NSString* transcribePendingOutput;

// Chord progression recognition. Reuses the bundled stem-helper python+librosa.
@property (nonatomic, strong) ChordRecognizer* chordRecognizer;
@property (nonatomic, strong) NSWindow* chordProgressSheet;
@property (nonatomic, strong) NSProgressIndicator* chordProgressBar;
@property (nonatomic, strong) NSTextField* chordStatusLabel;
// Detected/edited chord segments: dicts {start, end, label}, sorted by start.
@property (nonatomic, copy)   NSArray<NSDictionary*>* chords;

// YouTube download UI: a transient sheet shown while the helper runs.
@property (nonatomic, strong) MediaDownloader* mediaDownloader;
@property (nonatomic, strong) NSWindow* mediaProgressSheet;
@property (nonatomic, strong) NSProgressIndicator* mediaProgressBar;
@property (nonatomic, strong) NSTextField* mediaStatusLabel;
@property (nonatomic, copy)   NSString* mediaPendingURL;
@property (nonatomic, assign) BOOL mediaUserCancelled;

// URL-entry sheet — kept around as a property so the Download/Cancel
// button actions can read the field and dismiss the sheet from outside
// the construction scope.
@property (nonatomic, strong) NSWindow* mediaURLSheet;
@property (nonatomic, strong) NSTextField* mediaURLField;

// Downloads Manager window state.
@property (nonatomic, strong) NSWindow* downloadsWindow;
@property (nonatomic, strong) NSTableView* downloadsTable;
@property (nonatomic, strong) NSTextField* downloadsTotalLabel;
@property (nonatomic, strong) NSSegmentedControl* downloadsSegment;
@property (nonatomic, strong) NSMutableArray<OSDownloadItem*>* downloadsItems;
@property (nonatomic, strong) NSMutableArray<OSStemCacheItem*>* stemCacheItems;
// 0 = downloads view, 1 = stem cache view.
@property (nonatomic, assign) NSInteger downloadsViewMode;
@end

// Strip the system NSBezelStyleRounded chrome off an M/S toggle button and
// turn it into a flat, layer-backed pill so we can paint a strong color
// when the toggle is on. The base style and tooltip are set once at
// creation; the on/off appearance is refreshed by
// updateStemToggleButtonAppearance from syncStemMixerControls.
static void configureStemToggleButton(NSButton* b, NSString* tip) {
    b.bordered = NO;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 4;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.16].CGColor;
    b.toolTip = tip;
}

static void updateStemToggleButtonAppearance(NSButton* b, BOOL on, BOOL isMute) {
    NSColor* bg;
    NSColor* fg;
    if (on) {
        if (isMute) {
            bg = [NSColor colorWithRed:0.95 green:0.32 blue:0.28 alpha:0.92];
            fg = [NSColor whiteColor];
        } else {
            bg = [NSColor colorWithRed:1.00 green:0.78 blue:0.20 alpha:0.95];
            fg = [NSColor blackColor];
        }
    } else {
        bg = [NSColor colorWithWhite:0.18 alpha:0.55];
        fg = [NSColor colorWithWhite:0.78 alpha:1.0];
    }
    b.layer.backgroundColor = bg.CGColor;

    NSMutableParagraphStyle* p = [[NSMutableParagraphStyle alloc] init];
    p.alignment = NSTextAlignmentCenter;
    NSString* letter = isMute ? @"M" : @"S";
    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: p,
    };
    b.attributedTitle =
        [[NSAttributedString alloc] initWithString:letter attributes:attrs];
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    _engine = std::make_unique<AudioEngine>();

    NSString* savedUID = [[NSUserDefaults standardUserDefaults]
                          stringForKey:@"openscribe.outputDeviceUID"];
    if (savedUID.length) {
        _engine->setOutputDeviceUID(std::string(savedUID.UTF8String));
    }

    [self installMenuBar];

    self.mainWindow = [[MainWindow alloc] initWithEngine:_engine.get()];
    self.mainWindow.delegate = self;
    [self.mainWindow makeKeyAndOrderFront:nil];

    __weak AppDelegate* weakReorderSelf = self;
    [self.mainWindow setStemReorderHandler:^(NSInteger from, NSInteger to) {
        [weakReorderSelf moveStemFrom:(int)from to:(int)to];
    }];

    self.mainWindow.speedSlider.target = self;
    self.mainWindow.speedSlider.action = @selector(speedChanged:);
    self.mainWindow.pitchSlider.target = self;
    self.mainWindow.pitchSlider.action = @selector(pitchChanged:);
    self.mainWindow.volumeSlider.target = self;
    self.mainWindow.volumeSlider.action = @selector(volumeChanged:);

    self.mainWindow.speedResetButton.target = self;
    self.mainWindow.speedResetButton.action = @selector(resetSpeedClicked:);
    self.mainWindow.pitchResetButton.target = self;
    self.mainWindow.pitchResetButton.action = @selector(resetPitchClicked:);
    self.mainWindow.volumeResetButton.target = self;
    self.mainWindow.volumeResetButton.action = @selector(resetVolumeClicked:);

    self.mainWindow.helpButton.target = self;
    self.mainWindow.helpButton.action = @selector(showHelpPopover:);

    self.mainWindow.smartLoopButton.target = self;
    self.mainWindow.smartLoopButton.action = @selector(showSmartLoopPopover:);

    self.mainWindow.isolateButton.target = self;
    self.mainWindow.isolateButton.action = @selector(showIsolatePopover:);

    self.stemSeparator = [[StemSeparator alloc] init];
    self.stemSeparator.delegate = self;
    self.stemModel = @"htdemucs";
    self.currentStemNames = @[];
    self.currentStemPaths = @[];

    self.basicPitch = [[BasicPitchTranscriber alloc] init];
    self.basicPitch.delegate = self;

    self.chordRecognizer = [[ChordRecognizer alloc] init];
    self.chordRecognizer.delegate = self;

    self.mediaDownloader = [[MediaDownloader alloc] init];
    self.mediaDownloader.delegate = self;

    self.mainWindow.startButton.target = self;
    self.mainWindow.startButton.action = @selector(seekToStartClicked:);
    self.mainWindow.skipBackButton.target = self;
    self.mainWindow.skipBackButton.action = @selector(skipBackClicked:);
    self.mainWindow.playPauseButton.target = self;
    self.mainWindow.playPauseButton.action = @selector(playPauseClicked:);
    self.mainWindow.skipForwardButton.target = self;
    self.mainWindow.skipForwardButton.action = @selector(skipForwardClicked:);

    __weak AppDelegate* weakSelfDrop = self;
    self.mainWindow.waveformView.fileDropHandler = ^(NSString* path) {
        [weakSelfDrop loadPath:path];
    };
    self.mainWindow.waveformView.bookmarkJumpHandler = ^(NSInteger i) {
        [weakSelfDrop jumpToBookmark:i];
    };
    self.mainWindow.waveformView.bookmarkRenameHandler = ^(NSInteger i) {
        [weakSelfDrop renameBookmarkAtIndex:i];
    };
    self.mainWindow.waveformView.bookmarkRemoveHandler = ^(NSInteger i) {
        [weakSelfDrop removeBookmarkAtIndex:i];
    };
    self.mainWindow.waveformView.chordSeekHandler = ^(double seconds) {
        [weakSelfDrop seekEngineToSeconds:seconds];
    };
    self.mainWindow.waveformView.chordEditHandler = ^(NSInteger i) {
        [weakSelfDrop editChordAtIndex:i];
    };
    self.mainWindow.waveformView.chordDeleteHandler = ^(NSInteger i) {
        [weakSelfDrop deleteChordAtIndex:i];
    };
    self.mainWindow.waveformView.chordAddHandler = ^(double seconds) {
        [weakSelfDrop addChordAtTime:seconds];
    };

    [self installKeyMonitor];

    __weak AppDelegate* weakSelf = self;
    self.timeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                     repeats:YES
                                                       block:^(NSTimer*) {
        [weakSelf updateTimeLabel];
    }];
}

- (NSString*)formatSeconds:(double)t {
    if (t < 0 || !std::isfinite(t)) t = 0;
    int total = (int)t;
    int m = total / 60;
    int s = total % 60;
    int cs = (int)std::floor((t - (double)total) * 100.0);
    if (cs < 0) cs = 0; if (cs > 99) cs = 99;
    return [NSString stringWithFormat:@"%02d:%02d.%02d", m, s, cs];
}

- (void)updateTimeLabel {
    if (!_engine) return;
    NSString* now = [self formatSeconds:_engine->currentTime()];
    NSString* dur = [self formatSeconds:_engine->duration()];
    self.mainWindow.timeLabel.stringValue =
        [NSString stringWithFormat:@"%@ / %@", now, dur];
    [self.mainWindow updatePlayPauseButton:_engine->isPlaying()];

    [self.mainWindow.waveformView updateChordPlayhead:_engine->currentTime()];
    [self updateChordReadout];

    [self pollSmartLoop];

    if (_engine->hasLoop()) {
        double sr = _engine->sampleRate();
        double ls = _engine->loopStartFrame() / sr;
        double le = _engine->loopEndFrame() / sr;
        NSString* base = [NSString stringWithFormat:@"  Loop  %@ → %@",
                          [self formatSeconds:ls], [self formatSeconds:le]];
        if (_smartLoop.enabled) {
            base = [base stringByAppendingFormat:@"   ·   %d/%d  @  %.2fx  ",
                    std::min(_smartLoop.currentStepIterations, _smartLoop.repeatsPerStep),
                    _smartLoop.repeatsPerStep,
                    _engine->speed()];
        } else {
            base = [base stringByAppendingString:@"  "];
        }
        self.mainWindow.loopBadge.stringValue = base;
        self.mainWindow.loopBadge.hidden = NO;
    } else {
        self.mainWindow.loopBadge.hidden = YES;
    }
}

- (void)pollSmartLoop {
    if (!_engine || !_smartLoop.enabled || !_engine->hasLoop()) {
        // Keep lastSeenWrapCount in sync so toggling enabled later starts fresh.
        if (_engine) _smartLoop.lastSeenWrapCount = _engine->loopWrapCount();
        return;
    }
    int64_t wraps = _engine->loopWrapCount();
    int64_t delta = wraps - _smartLoop.lastSeenWrapCount;
    if (delta <= 0) return;
    _smartLoop.lastSeenWrapCount = wraps;
    _smartLoop.currentStepIterations += (int)delta;

    while (_smartLoop.currentStepIterations >= _smartLoop.repeatsPerStep) {
        double cur = _engine->speed();
        // Round to 0.01 so 0.5 + 0.1 doesn't drift.
        double snappedCur = std::round(cur * 100.0) / 100.0;
        double snappedEnd = std::round(_smartLoop.endSpeed * 100.0) / 100.0;
        if (snappedCur >= snappedEnd) {
            // Reached top of the ramp — clamp the iteration counter so the UI
            // shows "3/3" instead of climbing forever.
            _smartLoop.currentStepIterations = _smartLoop.repeatsPerStep;
            break;
        }
        double next = std::min(_smartLoop.endSpeed, snappedCur + _smartLoop.stepSize);
        next = std::round(next * 100.0) / 100.0;
        [self applySmartLoopSpeed:next];
        _smartLoop.currentStepIterations -= _smartLoop.repeatsPerStep;
    }

    [self refreshSmartLoopStatusLabel];
}

- (void)applySmartLoopSpeed:(double)v {
    NSSlider* s = self.mainWindow.speedSlider;
    s.doubleValue = std::clamp(v, s.minValue, s.maxValue);
    [self speedChanged:s];
}

- (void)resetSmartLoopBaseline {
    if (_engine) _smartLoop.lastSeenWrapCount = _engine->loopWrapCount();
    _smartLoop.currentStepIterations = 0;
    [self refreshSmartLoopStatusLabel];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [self teardownForExit];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)windowWillClose:(NSNotification*)notification {
    // Pre-empt the audio + display-link threads as soon as the user clicks X,
    // so they can't race with engine teardown.
    [self teardownForExit];
}

- (void)teardownForExit {
    if (_torndown) return;
    _torndown = YES;

    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self.timeTimer invalidate];
    self.timeTimer = nil;

    if (_keyMonitor) {
        [NSEvent removeMonitor:_keyMonitor];
        _keyMonitor = nil;
    }

    // Pause the Metal display link before the engine goes away — its draw
    // path reads engine state on a separate thread.
    MainWindow* win = self.mainWindow;
    if (win && win.waveformView) {
        win.waveformView.paused = YES;
    }

    _engine.reset();
}

- (void)installMenuBar {
    NSMenu* menubar = [[NSMenu alloc] init];

    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [menubar addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    NSMenuItem* about = [[NSMenuItem alloc] initWithTitle:@"About OpenScribe Native"
                                                    action:@selector(showAboutPanel:)
                                             keyEquivalent:@""];
    about.target = self;
    [appMenu addItem:about];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* prefs = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                   action:@selector(showSettings:)
                                            keyEquivalent:@","];
    prefs.target = self;
    [appMenu addItem:prefs];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit OpenScribe Native"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];

    NSMenuItem* fileItem = [[NSMenuItem alloc] init];
    [menubar addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open…"
                        action:@selector(openFile:)
                 keyEquivalent:@"o"];
    NSMenuItem* ytItem = [[NSMenuItem alloc] initWithTitle:@"Import Media URL…"
                                                    action:@selector(openMediaURL:)
                                             keyEquivalent:@"o"];
    ytItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    ytItem.target = self;
    [fileMenu addItem:ytItem];
    NSMenuItem* scoreItem = [[NSMenuItem alloc] initWithTitle:@"Open Sheet Music…"
        action:@selector(openSheetMusic:) keyEquivalent:@""];
    scoreItem.target = self;
    [fileMenu addItem:scoreItem];
    NSMenuItem* libraryItem = [[NSMenuItem alloc] initWithTitle:@"Browse iReal Library…"
        action:@selector(showIRealLibrary:) keyEquivalent:@""];
    libraryItem.target = self;
    [fileMenu addItem:libraryItem];
    NSMenuItem* toggleScore = [[NSMenuItem alloc] initWithTitle:@"Show / Hide Sheet Music"
        action:@selector(toggleSheetMusic:) keyEquivalent:@""];
    toggleScore.target = self;
    [fileMenu addItem:toggleScore];
    NSMenuItem* recentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                        action:nil
                                                 keyEquivalent:@""];
    self.recentSubmenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    recentItem.submenu = self.recentSubmenu;
    [fileMenu addItem:recentItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* mgr = [[NSMenuItem alloc] initWithTitle:@"Manage Downloads…"
                                                 action:@selector(showDownloadsManager:)
                                          keyEquivalent:@""];
    mgr.target = self;
    [fileMenu addItem:mgr];
    [fileItem setSubmenu:fileMenu];
    [self rebuildRecentMenu];

    // Analyze menu — note transcription and chord detection.
    NSMenuItem* analyzeItem = [[NSMenuItem alloc] init];
    [menubar addItem:analyzeItem];
    NSMenu* analyzeMenu = [[NSMenu alloc] initWithTitle:@"Analyze"];
    NSMenuItem* transcribeTrack = [[NSMenuItem alloc] initWithTitle:@"Transcribe Track to MIDI…"
                                                             action:@selector(transcribeTrackClicked:)
                                                      keyEquivalent:@"m"];
    transcribeTrack.target = self;
    transcribeTrack.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [analyzeMenu addItem:transcribeTrack];
    [analyzeMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* detectChords = [[NSMenuItem alloc] initWithTitle:@"Detect Chords"
                                                          action:@selector(detectChordsClicked:)
                                                   keyEquivalent:@"k"];
    detectChords.target = self;
    [analyzeMenu addItem:detectChords];
    NSMenuItem* clearChords = [[NSMenuItem alloc] initWithTitle:@"Clear Chords"
                                                        action:@selector(clearChordsClicked:)
                                                 keyEquivalent:@""];
    clearChords.target = self;
    [analyzeMenu addItem:clearChords];
    [analyzeItem setSubmenu:analyzeMenu];

    // Standard Edit menu — without it, AppKit doesn't dispatch ⌘X/⌘C/⌘V/⌘A
    // to the responder chain, so text fields silently swallow paste/etc.
    // The action selectors are nil-targeted; AppKit walks the responder
    // chain to find a NSText that implements them.
    NSMenuItem* editItem = [[NSMenuItem alloc] init];
    [menubar addItem:editItem];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo"      action:@selector(undo:)        keyEquivalent:@"z"];
    NSMenuItem* redo = [editMenu addItemWithTitle:@"Redo"
                                           action:@selector(redo:)
                                    keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut"       action:@selector(cut:)         keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy"      action:@selector(copy:)        keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste"     action:@selector(paste:)       keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Delete"    action:@selector(delete:)      keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:)  keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu];

    [NSApp setMainMenu:menubar];
}

- (void)addToRecentFiles:(NSString*)path {
    if (!path.length) return;
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    NSMutableArray<NSString*>* list =
        [[d arrayForKey:@"openscribe.recentFiles"] mutableCopy]
        ?: [NSMutableArray array];
    [list removeObject:path];
    [list insertObject:path atIndex:0];
    while (list.count > 10) [list removeLastObject];
    [d setObject:list forKey:@"openscribe.recentFiles"];
    [self rebuildRecentMenu];
}

- (void)rebuildRecentMenu {
    [self.recentSubmenu removeAllItems];
    NSArray* list = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:@"openscribe.recentFiles"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"No Recent Files"
                                                      action:nil
                                               keyEquivalent:@""];
        item.enabled = NO;
        [self.recentSubmenu addItem:item];
        return;
    }
    for (NSString* p in list) {
        if (![p isKindOfClass:[NSString class]]) continue;
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:p.lastPathComponent
                                                     action:@selector(openRecentItem:)
                                              keyEquivalent:@""];
        it.target = self;
        it.representedObject = p;
        it.toolTip = p;
        [self.recentSubmenu addItem:it];
    }
    [self.recentSubmenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* clear = [[NSMenuItem alloc] initWithTitle:@"Clear Menu"
                                                   action:@selector(clearRecentFiles:)
                                            keyEquivalent:@""];
    clear.target = self;
    [self.recentSubmenu addItem:clear];
}

- (void)openRecentItem:(NSMenuItem*)sender {
    NSString* p = sender.representedObject;
    if ([p isKindOfClass:[NSString class]]) [self loadPath:p];
}

- (void)clearRecentFiles:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"openscribe.recentFiles"];
    [self rebuildRecentMenu];
}

- (void)showSettings:(id)sender {
    (void)sender;
    SettingsWindowController* c = [SettingsWindowController sharedController];
    [c setEngine:_engine.get()];
    [c showWindow];
}

- (void)showAboutPanel:(id)sender {
    NSString* link = @"https://github.com/yalinsahin/openscribe";
    NSString* body = [NSString stringWithFormat:
        @"Open-source macOS audio loop player.\n\n%@\n\nMIT License", link];
    NSMutableAttributedString* credits =
        [[NSMutableAttributedString alloc] initWithString:body];
    NSRange all = NSMakeRange(0, credits.length);
    [credits addAttribute:NSFontAttributeName
                    value:[NSFont systemFontOfSize:11]
                    range:all];
    [credits addAttribute:NSForegroundColorAttributeName
                    value:[NSColor secondaryLabelColor]
                    range:all];
    NSRange linkRange = [body rangeOfString:link];
    if (linkRange.location != NSNotFound) {
        [credits addAttribute:NSLinkAttributeName value:link range:linkRange];
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        @"ApplicationName": @"OpenScribe Native",
        @"ApplicationVersion": @"0.1.0",
        @"Credits": credits,
        @"Copyright": @"\u00a9 2026 yalinsahin",
    }];
}

- (void)showHelpPopover:(id)sender {
    NSArray<NSArray<NSString*>*>* rows = @[
        @[@"Space",         @"Play / Pause"],
        @[@"← / →",         @"Skip 5s"],
        @[@"↑ / ↓",         @"Volume \u00b15%"],
        @[@", / .",         @"Pitch \u00b11 semitone"],
        @[@"- / =",         @"Speed \u00b10.05\u00d7"],
        @[@"0",             @"Reset speed & pitch"],
        @[@"Home",          @"Seek to start"],
        @[@"Enter",         @"Loop start (else 0:00)"],
        @[@"Esc / L",       @"Clear loop"],
        @[@"[ / ]",         @"Set loop start / end"],
        @[@"Shift + [ / ]", @"Nudge loop edge"],
        @[@"B",             @"Toggle bookmark"],
        @[@"R",             @"Rename nearest bookmark"],
        @[@"1 \u2013 9",    @"Jump to bookmark"],
        @[@"\u2318 O",      @"Open file"],
        @[@"Drag",          @"Create loop"],
        @[@"Drag edge",     @"Resize loop"],
        @[@"Drag inside",   @"Move loop"],
        @[@"Double-click",  @"Clear loop"],
        @[@"Scroll",        @"Zoom"],
        @[@"\u2325 + drag", @"Pan waveform"],
    ];

    CGFloat w = 360;
    CGFloat rowH = 18;
    CGFloat top = 14, bot = 14, titleH = 22;
    CGFloat h = top + titleH + 8 + rowH * rows.count + bot;

    NSView* container = [[OSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    container.wantsLayer = YES;

    NSTextField* title = [[NSTextField alloc]
        initWithFrame:NSMakeRect(16, top, w - 32, titleH)];
    title.bezeled = NO; title.editable = NO; title.selectable = NO;
    title.drawsBackground = NO;
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.stringValue = @"Keyboard & Mouse";
    [container addSubview:title];

    CGFloat y = top + titleH + 8;
    NSDictionary* keyAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11
                                                              weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor],
    };
    NSDictionary* descAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
    };
    for (NSArray* r in rows) {
        NSTextField* k = [[NSTextField alloc]
            initWithFrame:NSMakeRect(16, y, 130, rowH)];
        k.bezeled = NO; k.editable = NO; k.selectable = NO; k.drawsBackground = NO;
        k.attributedStringValue =
            [[NSAttributedString alloc] initWithString:r[0] attributes:keyAttrs];
        [container addSubview:k];
        NSTextField* d = [[NSTextField alloc]
            initWithFrame:NSMakeRect(150, y, w - 150 - 16, rowH)];
        d.bezeled = NO; d.editable = NO; d.selectable = NO; d.drawsBackground = NO;
        d.attributedStringValue =
            [[NSAttributedString alloc] initWithString:r[1] attributes:descAttrs];
        [container addSubview:d];
        y += rowH;
    }

    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = container;

    NSPopover* p = [[NSPopover alloc] init];
    p.contentViewController = vc;
    p.behavior = NSPopoverBehaviorTransient;
    p.contentSize = NSMakeSize(w, h);

    NSView* anchor = (NSView*)sender;
    [p showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMinYEdge];
}

// MARK: – Smart loop popover

- (void)showSmartLoopPopover:(id)sender {
    if (!self.smartLoopPopover) {
        [self buildSmartLoopPopover];
    }
    [self syncSmartLoopControls];
    NSView* anchor = (NSView*)sender;
    [self.smartLoopPopover showRelativeToRect:anchor.bounds
                                       ofView:anchor
                                preferredEdge:NSMinYEdge];
}

- (void)buildSmartLoopPopover {
    CGFloat w = 340;
    CGFloat rowH = 24;
    CGFloat margin = 16;
    CGFloat labelW = 110;
    CGFloat valueW = 56;
    CGFloat sliderW = w - margin - labelW - 8 - valueW - margin;
    __block CGFloat y = margin;

    NSView* container = [[OSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 1)];
    container.wantsLayer = YES;

    NSTextField* title = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, w - 2 * margin - 60, 22)];
    title.bezeled = NO; title.editable = NO; title.selectable = NO;
    title.drawsBackground = NO;
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.stringValue = @"Smart Loop";
    [container addSubview:title];

    self.smartLoopToggle = [[NSButton alloc] initWithFrame:
        NSMakeRect(w - margin - 60, y, 60, 22)];
    [self.smartLoopToggle setButtonType:NSButtonTypeSwitch];
    self.smartLoopToggle.title = @"";
    self.smartLoopToggle.target = self;
    self.smartLoopToggle.action = @selector(smartLoopToggleChanged:);
    [container addSubview:self.smartLoopToggle];

    y += 30;

    NSTextField* sub = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 16)];
    sub.bezeled = NO; sub.editable = NO; sub.selectable = NO;
    sub.drawsBackground = NO;
    sub.font = [NSFont systemFontOfSize:11];
    sub.textColor = [NSColor secondaryLabelColor];
    sub.stringValue = @"Repeat the loop, gradually speeding up.";
    [container addSubview:sub];

    y += 24;

    auto addRow = ^(NSString* labelText, NSSlider* slider, NSTextField* valueLabel) {
        NSTextField* lbl = [[NSTextField alloc]
            initWithFrame:NSMakeRect(margin, y, labelW, rowH)];
        lbl.bezeled = NO; lbl.editable = NO; lbl.selectable = NO;
        lbl.drawsBackground = NO;
        lbl.font = [NSFont systemFontOfSize:11];
        lbl.textColor = [NSColor labelColor];
        lbl.stringValue = labelText;
        [container addSubview:lbl];

        slider.frame = NSMakeRect(margin + labelW, y + 1, sliderW, rowH - 2);
        slider.continuous = YES;
        [container addSubview:slider];

        valueLabel.frame = NSMakeRect(margin + labelW + sliderW + 8, y, valueW, rowH);
        valueLabel.bezeled = NO;
        valueLabel.editable = NO;
        valueLabel.selectable = NO;
        valueLabel.drawsBackground = NO;
        valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11
                                                            weight:NSFontWeightMedium];
        valueLabel.alignment = NSTextAlignmentRight;
        valueLabel.textColor = [NSColor secondaryLabelColor];
        [container addSubview:valueLabel];

        y += rowH + 4;
    };

    OSResettableSlider* slStart = [[OSResettableSlider alloc] init];
    slStart.minValue = 0.25;
    slStart.maxValue = 2.0;
    slStart.resetValue = 0.5;
    slStart.target = self;
    slStart.action = @selector(smartLoopStartChanged:);
    slStart.toolTip = @"Double-click to reset to 0.5×.";
    self.smartLoopStartSlider = slStart;
    self.smartLoopStartLabel = [[NSTextField alloc] init];
    addRow(@"Start speed", self.smartLoopStartSlider, self.smartLoopStartLabel);

    OSResettableSlider* slEnd = [[OSResettableSlider alloc] init];
    slEnd.minValue = 0.25;
    slEnd.maxValue = 2.0;
    slEnd.resetValue = 1.0;
    slEnd.target = self;
    slEnd.action = @selector(smartLoopEndChanged:);
    slEnd.toolTip = @"Double-click to reset to 1×.";
    self.smartLoopEndSlider = slEnd;
    self.smartLoopEndLabel = [[NSTextField alloc] init];
    addRow(@"End speed", self.smartLoopEndSlider, self.smartLoopEndLabel);

    OSResettableSlider* slStep = [[OSResettableSlider alloc] init];
    slStep.minValue = 0.05;
    slStep.maxValue = 0.5;
    slStep.resetValue = 0.1;
    slStep.target = self;
    slStep.action = @selector(smartLoopStepChanged:);
    slStep.toolTip = @"Double-click to reset to 0.1×.";
    self.smartLoopStepSlider = slStep;
    self.smartLoopStepLabel = [[NSTextField alloc] init];
    addRow(@"Step size", self.smartLoopStepSlider, self.smartLoopStepLabel);

    // Repeats per step (stepper instead of slider for integer values).
    NSTextField* repLbl = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, labelW, rowH)];
    repLbl.bezeled = NO; repLbl.editable = NO; repLbl.selectable = NO;
    repLbl.drawsBackground = NO;
    repLbl.font = [NSFont systemFontOfSize:11];
    repLbl.textColor = [NSColor labelColor];
    repLbl.stringValue = @"Repeats per step";
    [container addSubview:repLbl];

    self.smartLoopRepeatsStepper = [[NSStepper alloc] initWithFrame:
        NSMakeRect(w - margin - 24, y, 24, rowH)];
    self.smartLoopRepeatsStepper.minValue = 1;
    self.smartLoopRepeatsStepper.maxValue = 10;
    self.smartLoopRepeatsStepper.increment = 1;
    self.smartLoopRepeatsStepper.target = self;
    self.smartLoopRepeatsStepper.action = @selector(smartLoopRepeatsChanged:);
    [container addSubview:self.smartLoopRepeatsStepper];

    self.smartLoopRepeatsLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(w - margin - 24 - 32, y, 28, rowH)];
    self.smartLoopRepeatsLabel.bezeled = NO;
    self.smartLoopRepeatsLabel.editable = NO;
    self.smartLoopRepeatsLabel.selectable = NO;
    self.smartLoopRepeatsLabel.drawsBackground = NO;
    self.smartLoopRepeatsLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.smartLoopRepeatsLabel.alignment = NSTextAlignmentRight;
    self.smartLoopRepeatsLabel.textColor = [NSColor secondaryLabelColor];
    [container addSubview:self.smartLoopRepeatsLabel];

    y += rowH + 12;

    NSView* sep = [[NSView alloc] initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 1)];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.12].CGColor;
    [container addSubview:sep];
    y += 9;

    self.smartLoopStatusLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(margin, y, w - 2 * margin - 80, rowH)];
    self.smartLoopStatusLabel.bezeled = NO;
    self.smartLoopStatusLabel.editable = NO;
    self.smartLoopStatusLabel.selectable = NO;
    self.smartLoopStatusLabel.drawsBackground = NO;
    self.smartLoopStatusLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.smartLoopStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.smartLoopStatusLabel.stringValue = @"";
    [container addSubview:self.smartLoopStatusLabel];

    NSButton* resetBtn = [[NSButton alloc] initWithFrame:
        NSMakeRect(w - margin - 64, y - 2, 64, rowH + 4)];
    resetBtn.title = @"Reset";
    resetBtn.bezelStyle = NSBezelStyleRounded;
    resetBtn.target = self;
    resetBtn.action = @selector(smartLoopResetClicked:);
    [container addSubview:resetBtn];

    y += rowH + margin;
    container.frame = NSMakeRect(0, 0, w, y);

    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = container;

    self.smartLoopPopover = [[NSPopover alloc] init];
    self.smartLoopPopover.contentViewController = vc;
    self.smartLoopPopover.behavior = NSPopoverBehaviorTransient;
    self.smartLoopPopover.contentSize = NSMakeSize(w, y);
}

- (void)syncSmartLoopControls {
    self.smartLoopToggle.state = _smartLoop.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.smartLoopStartSlider.doubleValue = _smartLoop.startSpeed;
    self.smartLoopEndSlider.doubleValue = _smartLoop.endSpeed;
    self.smartLoopStepSlider.doubleValue = _smartLoop.stepSize;
    self.smartLoopRepeatsStepper.integerValue = _smartLoop.repeatsPerStep;
    self.smartLoopStartLabel.stringValue =
        [NSString stringWithFormat:@"%.2fx", _smartLoop.startSpeed];
    self.smartLoopEndLabel.stringValue =
        [NSString stringWithFormat:@"%.2fx", _smartLoop.endSpeed];
    self.smartLoopStepLabel.stringValue =
        [NSString stringWithFormat:@"+%.2fx", _smartLoop.stepSize];
    self.smartLoopRepeatsLabel.stringValue =
        [NSString stringWithFormat:@"%d", _smartLoop.repeatsPerStep];
    [self refreshSmartLoopStatusLabel];
}

- (void)refreshSmartLoopStatusLabel {
    if (!self.smartLoopStatusLabel) return;
    if (!_engine) {
        self.smartLoopStatusLabel.stringValue = @"";
        return;
    }
    int shown = std::min(_smartLoop.currentStepIterations, _smartLoop.repeatsPerStep);
    self.smartLoopStatusLabel.stringValue =
        [NSString stringWithFormat:@"%.2fx · rep %d/%d",
         _engine->speed(), shown, _smartLoop.repeatsPerStep];
}

- (void)smartLoopToggleChanged:(NSButton*)sender {
    bool wasEnabled = _smartLoop.enabled;
    _smartLoop.enabled = sender.state == NSControlStateValueOn;
    if (!wasEnabled && _smartLoop.enabled) {
        // On enable: snap speed to startSpeed and reset iteration counter
        // so practice begins from the slow end.
        [self resetSmartLoopBaseline];
        [self applySmartLoopSpeed:_smartLoop.startSpeed];
    }
    [self updateSmartLoopButtonTint];
    [self refreshSmartLoopStatusLabel];
}

- (void)smartLoopStartChanged:(NSSlider*)sender {
    double v = std::round(sender.doubleValue * 20.0) / 20.0;  // 0.05 step
    _smartLoop.startSpeed = v;
    if (_smartLoop.endSpeed < v) _smartLoop.endSpeed = v;
    [self syncSmartLoopControls];
}

- (void)smartLoopEndChanged:(NSSlider*)sender {
    double v = std::round(sender.doubleValue * 20.0) / 20.0;
    _smartLoop.endSpeed = v;
    if (_smartLoop.startSpeed > v) _smartLoop.startSpeed = v;
    [self syncSmartLoopControls];
}

- (void)smartLoopStepChanged:(NSSlider*)sender {
    double v = std::round(sender.doubleValue * 20.0) / 20.0;
    if (v < 0.05) v = 0.05;
    _smartLoop.stepSize = v;
    [self syncSmartLoopControls];
}

- (void)smartLoopRepeatsChanged:(NSStepper*)sender {
    _smartLoop.repeatsPerStep = (int)sender.integerValue;
    [self syncSmartLoopControls];
}

- (void)smartLoopResetClicked:(id)sender {
    if (_smartLoop.enabled) {
        [self applySmartLoopSpeed:_smartLoop.startSpeed];
    }
    [self resetSmartLoopBaseline];
}

- (void)updateSmartLoopButtonTint {
    NSColor* color = _smartLoop.enabled
        ? [NSColor colorWithRed:0.40 green:0.78 blue:1.0 alpha:1.0]
        : [NSColor colorWithWhite:0.65 alpha:1.0];
    self.mainWindow.smartLoopButton.contentTintColor = color;
}

// MARK: – Isolate popover (vocal cancel + bass focus)

- (BOOL)isolateActive {
    return _isolate.centerCancel > 0.001 || _isolate.bassFocusEnabled;
}

- (void)updateIsolateButtonTint {
    NSColor* color = [self isolateActive]
        ? [NSColor colorWithRed:0.96 green:0.62 blue:0.30 alpha:1.0]
        : [NSColor colorWithWhite:0.65 alpha:1.0];
    self.mainWindow.isolateButton.contentTintColor = color;
}

- (void)applyIsolateToEngine {
    if (!_engine) return;
    _engine->setCenterCancelAmount(_isolate.centerCancel);
    _engine->setLowPassEnabled(_isolate.bassFocusEnabled);
    _engine->setLowPassFrequencyHz(_isolate.bassFocusCutoffHz);
    [self updateIsolateButtonTint];
}

- (void)showIsolatePopover:(id)sender {
    // Rebuild on every open so stem rows match the engine's current
    // stemCount() and the helper's discovered stem names.
    if (self.isolatePopover.isShown) [self.isolatePopover close];
    [self buildIsolatePopover];
    [self syncIsolateControls];
    NSView* anchor = (NSView*)sender;
    [self.isolatePopover showRelativeToRect:anchor.bounds
                                     ofView:anchor
                              preferredEdge:NSMinYEdge];
}

- (void)buildIsolatePopover {
    CGFloat w = 340;
    CGFloat rowH = 24;
    CGFloat margin = 16;
    CGFloat labelW = 110;
    CGFloat valueW = 56;
    CGFloat sliderW = w - margin - labelW - 8 - valueW - margin;
    __block CGFloat y = margin;

    NSView* container = [[OSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 1)];
    container.wantsLayer = YES;

    NSTextField* title = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 22)];
    title.bezeled = NO; title.editable = NO; title.selectable = NO;
    title.drawsBackground = NO;
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.stringValue = @"Isolate";
    [container addSubview:title];
    y += 26;

    NSTextField* sub = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 16)];
    sub.bezeled = NO; sub.editable = NO; sub.selectable = NO;
    sub.drawsBackground = NO;
    sub.font = [NSFont systemFontOfSize:11];
    sub.textColor = [NSColor secondaryLabelColor];
    sub.stringValue = @"Drop vocals or focus on the bass line.";
    [container addSubview:sub];
    y += 22;

    // -- Vocal cancel row.
    NSTextField* vcLbl = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, labelW, rowH)];
    vcLbl.bezeled = NO; vcLbl.editable = NO; vcLbl.selectable = NO;
    vcLbl.drawsBackground = NO;
    vcLbl.font = [NSFont systemFontOfSize:11];
    vcLbl.textColor = [NSColor labelColor];
    vcLbl.stringValue = @"Vocal cancel";
    [container addSubview:vcLbl];

    OSResettableSlider* vcSlider = [[OSResettableSlider alloc] initWithFrame:
        NSMakeRect(margin + labelW, y + 1, sliderW, rowH - 2)];
    vcSlider.minValue = 0.0;
    vcSlider.maxValue = 1.0;
    vcSlider.resetValue = 0.0;
    vcSlider.continuous = YES;
    vcSlider.target = self;
    vcSlider.action = @selector(vocalCancelChanged:);
    vcSlider.toolTip = @"Double-click to reset to 0%.";
    self.vocalCancelSlider = vcSlider;
    [container addSubview:self.vocalCancelSlider];

    self.vocalCancelLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(margin + labelW + sliderW + 8, y, valueW, rowH)];
    self.vocalCancelLabel.bezeled = NO;
    self.vocalCancelLabel.editable = NO;
    self.vocalCancelLabel.selectable = NO;
    self.vocalCancelLabel.drawsBackground = NO;
    self.vocalCancelLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.vocalCancelLabel.alignment = NSTextAlignmentRight;
    self.vocalCancelLabel.textColor = [NSColor secondaryLabelColor];
    [container addSubview:self.vocalCancelLabel];

    y += rowH + 8;

    NSView* sep = [[NSView alloc] initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 1)];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.12].CGColor;
    [container addSubview:sep];
    y += 9;

    // -- Bass focus row.
    self.bassFocusToggle = [[NSButton alloc] initWithFrame:
        NSMakeRect(margin, y, labelW + 40, rowH)];
    [self.bassFocusToggle setButtonType:NSButtonTypeSwitch];
    self.bassFocusToggle.title = @"Bass focus";
    self.bassFocusToggle.font = [NSFont systemFontOfSize:11];
    self.bassFocusToggle.target = self;
    self.bassFocusToggle.action = @selector(bassFocusToggled:);
    [container addSubview:self.bassFocusToggle];

    OSResettableSlider* bfSlider = [[OSResettableSlider alloc] initWithFrame:
        NSMakeRect(margin + labelW, y + 1, sliderW, rowH - 2)];
    // Log scale: slider 0..1 maps to 60..2000 Hz.
    bfSlider.minValue = 0.0;
    bfSlider.maxValue = 1.0;
    bfSlider.resetValue = hzToSlider(250.0);
    bfSlider.continuous = YES;
    bfSlider.target = self;
    bfSlider.action = @selector(bassFocusCutoffChanged:);
    bfSlider.toolTip = @"Double-click to reset to 250 Hz.";
    self.bassFocusSlider = bfSlider;
    [container addSubview:self.bassFocusSlider];

    self.bassFocusLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(margin + labelW + sliderW + 8, y, valueW, rowH)];
    self.bassFocusLabel.bezeled = NO;
    self.bassFocusLabel.editable = NO;
    self.bassFocusLabel.selectable = NO;
    self.bassFocusLabel.drawsBackground = NO;
    self.bassFocusLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.bassFocusLabel.alignment = NSTextAlignmentRight;
    self.bassFocusLabel.textColor = [NSColor secondaryLabelColor];
    [container addSubview:self.bassFocusLabel];

    y += rowH + 12;

    // -- Stems section -----------------------------------------------------
    NSView* sep2 = [[NSView alloc] initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 1)];
    sep2.wantsLayer = YES;
    sep2.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.12].CGColor;
    [container addSubview:sep2];
    y += 9;

    NSTextField* stemsTitle = [[NSTextField alloc]
        initWithFrame:NSMakeRect(margin, y, w - 2 * margin, 18)];
    stemsTitle.bezeled = NO; stemsTitle.editable = NO; stemsTitle.selectable = NO;
    stemsTitle.drawsBackground = NO;
    stemsTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    stemsTitle.textColor = [NSColor labelColor];
    stemsTitle.stringValue = @"Stems";
    [container addSubview:stemsTitle];
    y += 22;

    // Model selector. New separations use the chosen model; cached results
    // for other models stay in their own subdir under stems/<sha>/<model>/.
    self.stemModelPopup = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(margin, y, w - 2 * margin, 24)];
    [self.stemModelPopup addItemWithTitle:@"Standard (4 stems)"];
    self.stemModelPopup.lastItem.representedObject = @"htdemucs";
    [self.stemModelPopup addItemWithTitle:@"+ Guitar / Piano (6 stems, slower)"];
    self.stemModelPopup.lastItem.representedObject = @"htdemucs_6s";
    [self.stemModelPopup addItemWithTitle:@"High quality (vocals + instrumental)"];
    self.stemModelPopup.lastItem.representedObject = @"mel_band_roformer";
    self.stemModelPopup.target = self;
    self.stemModelPopup.action = @selector(stemModelChanged:);
    NSInteger sel = 0;
    if ([self.stemModel isEqualToString:@"htdemucs_6s"])              sel = 1;
    else if ([self.stemModel isEqualToString:@"mel_band_roformer"])   sel = 2;
    [self.stemModelPopup selectItemAtIndex:sel];
    [container addSubview:self.stemModelPopup];
    y += 28;

    self.separateStemsButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(margin, y, 140, 24)];
    self.separateStemsButton.bezelStyle = NSBezelStyleRounded;
    self.separateStemsButton.title = @"Separate stems";
    self.separateStemsButton.target = self;
    self.separateStemsButton.action = @selector(separateStemsClicked:);
    [container addSubview:self.separateStemsButton];

    self.separateProgress = [[NSProgressIndicator alloc] initWithFrame:
        NSMakeRect(margin + 148, y + 4, w - margin - margin - 148, 16)];
    self.separateProgress.indeterminate = NO;
    self.separateProgress.minValue = 0.0;
    self.separateProgress.maxValue = 1.0;
    self.separateProgress.hidden = YES;
    [container addSubview:self.separateProgress];

    y += 28;

    self.separateStatusLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(margin, y, w - 2 * margin, 16)];
    self.separateStatusLabel.bezeled = NO;
    self.separateStatusLabel.editable = NO;
    self.separateStatusLabel.selectable = NO;
    self.separateStatusLabel.drawsBackground = NO;
    self.separateStatusLabel.font = [NSFont systemFontOfSize:10];
    self.separateStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.separateStatusLabel.stringValue = @"";
    [container addSubview:self.separateStatusLabel];
    y += 18;

    // Mixer rows — only built if stems are currently loaded.
    int liveStems = _engine ? _engine->stemCount() : 0;
    BOOL hasMixer = (liveStems >= 2) && (self.currentStemNames.count == (NSUInteger)liveStems);

    NSMutableArray<NSButton*>*    mutes  = [NSMutableArray array];
    NSMutableArray<NSButton*>*    solos  = [NSMutableArray array];
    NSMutableArray<NSSlider*>*    gains  = [NSMutableArray array];
    NSMutableArray<NSTextField*>* glabels = [NSMutableArray array];

    if (hasMixer) {
        CGFloat nameW = 56;
        CGFloat btnW  = 30;
        CGFloat gainSliderW = w - margin - nameW - 4 - btnW - 4 - btnW - 8 - valueW - margin;

        for (NSInteger i = 0; i < liveStems; i++) {
            CGFloat x = margin;

            NSTextField* name = [[NSTextField alloc] initWithFrame:
                NSMakeRect(x, y, nameW, rowH)];
            name.bezeled = NO; name.editable = NO; name.selectable = NO;
            name.drawsBackground = NO;
            name.font = [NSFont systemFontOfSize:11];
            name.textColor = [NSColor labelColor];
            name.stringValue = [self.currentStemNames[i] capitalizedString];
            [container addSubview:name];
            x += nameW + 4;

            NSButton* mute = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, btnW, rowH)];
            mute.title = @"M";
            mute.tag = i;
            mute.target = self;
            mute.action = @selector(stemMuteClicked:);
            [mute setButtonType:NSButtonTypePushOnPushOff];
            configureStemToggleButton(mute, @"Mute this stem (M)");
            updateStemToggleButtonAppearance(mute, NO, YES);
            [container addSubview:mute];
            [mutes addObject:mute];
            x += btnW + 4;

            NSButton* solo = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, btnW, rowH)];
            solo.title = @"S";
            solo.tag = i;
            solo.target = self;
            solo.action = @selector(stemSoloClicked:);
            [solo setButtonType:NSButtonTypePushOnPushOff];
            configureStemToggleButton(solo, @"Solo this stem (S) — silences other stems");
            updateStemToggleButtonAppearance(solo, NO, NO);
            [container addSubview:solo];
            [solos addObject:solo];
            x += btnW + 8;

            OSResettableSlider* gain = [[OSResettableSlider alloc] initWithFrame:NSMakeRect(x, y + 1, gainSliderW, rowH - 2)];
            gain.minValue = 0.0;
            gain.maxValue = 1.5;
            gain.doubleValue = 1.0;
            gain.resetValue = 1.0;
            gain.continuous = YES;
            gain.tag = i;
            gain.target = self;
            gain.action = @selector(stemGainChanged:);
            gain.toolTip = @"Drag to adjust stem gain (0–150%). Double-click to reset to 100%.";
            [container addSubview:gain];
            [gains addObject:gain];
            x += gainSliderW + 8;

            NSTextField* glabel = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, valueW, rowH)];
            glabel.bezeled = NO; glabel.editable = NO; glabel.selectable = NO;
            glabel.drawsBackground = NO;
            glabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
            glabel.alignment = NSTextAlignmentRight;
            glabel.textColor = [NSColor secondaryLabelColor];
            glabel.stringValue = @"100%";
            [container addSubview:glabel];
            [glabels addObject:glabel];

            y += rowH + 4;
        }
    }
    self.stemMuteButtons = mutes;
    self.stemSoloButtons = solos;
    self.stemGainSliders = gains;
    self.stemGainLabels  = glabels;

    y += 8;
    container.frame = NSMakeRect(0, 0, w, y);

    NSViewController* vc = [[NSViewController alloc] init];
    vc.view = container;

    self.isolatePopover = [[NSPopover alloc] init];
    self.isolatePopover.contentViewController = vc;
    self.isolatePopover.behavior = NSPopoverBehaviorTransient;
    self.isolatePopover.contentSize = NSMakeSize(w, y);
}

static double sliderToHz(double s) {
    // 60..2000 Hz, log
    double lo = std::log(60.0), hi = std::log(2000.0);
    return std::exp(lo + (hi - lo) * std::clamp(s, 0.0, 1.0));
}
static double hzToSlider(double hz) {
    double lo = std::log(60.0), hi = std::log(2000.0);
    return (std::log(std::clamp(hz, 60.0, 2000.0)) - lo) / (hi - lo);
}

- (void)syncIsolateControls {
    self.vocalCancelSlider.doubleValue = _isolate.centerCancel;
    self.vocalCancelLabel.stringValue =
        [NSString stringWithFormat:@"%d%%", (int)std::round(_isolate.centerCancel * 100.0)];
    self.bassFocusToggle.state =
        _isolate.bassFocusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.bassFocusSlider.doubleValue = hzToSlider(_isolate.bassFocusCutoffHz);
    self.bassFocusSlider.enabled = _isolate.bassFocusEnabled;
    self.bassFocusLabel.stringValue =
        [NSString stringWithFormat:@"%d Hz", (int)std::round(_isolate.bassFocusCutoffHz)];
    [self syncStemMixerControls];
}

- (void)syncStemMixerControls {
    int n = _engine ? _engine->stemCount() : 0;
    BOOL stemsLoaded = (n >= 2);
    BOOL hasFile = (self.currentFilePath.length > 0);
    BOOL running = self.stemSeparator.isRunning;

    self.separateStemsButton.enabled = hasFile && !running && self.stemSeparator.isHelperAvailable;
    self.separateStemsButton.title = stemsLoaded ? @"Re-separate" : @"Separate stems";

    BOOL cachedForChosenModel = hasFile &&
        [self.stemSeparator hasCachedStemsForFile:self.currentFilePath model:self.stemModel];

    if (!self.stemSeparator.isHelperAvailable) {
        self.separateStatusLabel.stringValue =
            @"Helper missing — see tools/stem-helper/README.md";
    } else if (!hasFile) {
        self.separateStatusLabel.stringValue = @"Load a track first.";
    } else if (running) {
        // status set by progress callbacks
    } else if (cachedForChosenModel) {
        self.separateStatusLabel.stringValue =
            @"Cached — click to load instantly.";
    } else if (stemsLoaded) {
        self.separateStatusLabel.stringValue = @"Stems loaded — adjust mute / solo / gain.";
    } else {
        self.separateStatusLabel.stringValue =
            @"~5–15 s of audio per second on CPU. Cached after first run.";
    }

    auto syncRows = ^(NSArray<NSButton*>* mutes,
                      NSArray<NSButton*>* solos,
                      NSArray<NSSlider*>* gains,
                      NSArray<NSTextField*>* glabels) {
        NSUInteger rows = mutes.count;
        for (NSUInteger i = 0; i < rows; i++) {
            NSButton* mute = mutes[i];
            NSButton* solo = solos[i];
            NSSlider* gain = gains[i];
            NSTextField* glabel = glabels[i];

            BOOL active = stemsLoaded && (NSInteger)i < n;
            mute.enabled = active;
            solo.enabled = active;
            gain.enabled = active;

            if (active) {
                mute.state = _engine->stemMuted((int)i)  ? NSControlStateValueOn : NSControlStateValueOff;
                solo.state = _engine->stemSoloed((int)i) ? NSControlStateValueOn : NSControlStateValueOff;
                double g = _engine->stemGain((int)i);
                gain.doubleValue = g;
                glabel.stringValue = [NSString stringWithFormat:@"%d%%", (int)std::round(g * 100.0)];
            } else {
                mute.state = NSControlStateValueOff;
                solo.state = NSControlStateValueOff;
                gain.doubleValue = 1.0;
                glabel.stringValue = @"—";
            }
            updateStemToggleButtonAppearance(mute, mute.state == NSControlStateValueOn, YES);
            updateStemToggleButtonAppearance(solo, solo.state == NSControlStateValueOn, NO);
        }
    };

    syncRows(self.stemMuteButtons, self.stemSoloButtons,
             self.stemGainSliders, self.stemGainLabels);
    syncRows(self.sidebarStemMuteButtons, self.sidebarStemSoloButtons,
             self.sidebarStemGainSliders, self.sidebarStemGainLabels);
}

- (void)stemModelChanged:(NSPopUpButton*)sender {
    NSString* m = sender.selectedItem.representedObject;
    if (m.length) self.stemModel = m;
    [self syncStemMixerControls];
}

- (void)separateStemsClicked:(id)sender {
    (void)sender;
    if (!self.currentFilePath.length) return;
    if (!_engine) return;

    NSString* input = self.currentFilePath;
    NSString* model = self.stemModel.length ? self.stemModel : @"htdemucs";

    // Cache hit: load instantly without invoking the helper.
    if ([self.stemSeparator hasCachedStemsForFile:input model:model]) {
        [self loadStemsFromSeparation:[self.stemSeparator cachedStemsForFile:input model:model]];
        return;
    }

    self.separateProgress.hidden = NO;
    self.separateProgress.doubleValue = 0.0;
    self.separateProgress.indeterminate = YES;
    [self.separateProgress startAnimation:nil];
    self.currentSeparateStage = @"Starting";
    self.separateStartTime = [NSDate.date timeIntervalSince1970];
    self.separateStatusLabel.stringValue = @"Starting… (0s)";
    [self.separateElapsedTimer invalidate];
    self.separateElapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                 repeats:YES
                                                                   block:^(NSTimer* t) {
        (void)t;
        [self refreshSeparateElapsedLabel];
    }];
    [self.stemSeparator separateFile:input model:model];
    [self syncStemMixerControls];
    self.separateStemsButton.enabled = NO;
}

- (void)loadStemsFromSeparation:(NSArray<StemSeparation*>*)stems {
    if (!_engine || stems.count < 2) return;

    std::vector<std::string> v;
    v.reserve(stems.count);
    NSMutableArray<NSString*>* names = [NSMutableArray arrayWithCapacity:stems.count];
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:stems.count];
    for (StemSeparation* s in stems) {
        v.emplace_back(s.path.fileSystemRepresentation);
        [names addObject:s.name];
        [paths addObject:s.path];
    }
    bool ok = _engine->loadStems(v);
    if (!ok) {
        self.separateStatusLabel.stringValue = @"Engine refused stems (length mismatch?)";
        return;
    }
    self.currentStemNames = names;
    self.currentStemPaths = paths;

    // Rebuild waveform peaks per stem and tell the view how to colour/label
    // each lane. Order matters: reloadFromEngine first (recomputes peaks
    // from the new stemCount), then setStemNames (cosmetic refresh).
    [self.mainWindow.waveformView reloadFromEngine];
    [self.mainWindow.waveformView setStemNames:names];
    [self rebuildStemSidebar];

    // The popover layout depends on stem count; rebuild it so the new mixer
    // rows appear (or change in count). If the popover isn't shown, this is
    // a no-op until next open.
    if (self.isolatePopover.isShown) {
        NSView* anchor = self.mainWindow.isolateButton;
        [self.isolatePopover close];
        [self showIsolatePopover:anchor];
    } else {
        [self syncStemMixerControls];
    }
}

- (void)rebuildStemSidebar {
    NSView* sidebar = self.mainWindow.stemSidebar;
    for (NSView* sv in [sidebar.subviews copy]) [sv removeFromSuperview];
    self.sidebarStemMuteButtons  = nil;
    self.sidebarStemSoloButtons  = nil;
    self.sidebarStemGainSliders  = nil;
    self.sidebarStemGainLabels   = nil;

    int n = _engine ? _engine->stemCount() : 0;
    if (n < 2 || self.currentStemNames.count != (NSUInteger)n) {
        [self.mainWindow setStemSidebarVisible:NO];
        return;
    }

    NSMutableArray<NSButton*>*    mutes   = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSButton*>*    solos   = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSSlider*>*    sliders = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSTextField*>* labels  = [NSMutableArray arrayWithCapacity:n];

    for (NSInteger i = 0; i < n; i++) {
        OSStemMixerRow* row = [[OSStemMixerRow alloc] initWithFrame:NSZeroRect];

        NSTextField* name = [[NSTextField alloc] initWithFrame:NSZeroRect];
        name.bezeled = NO; name.editable = NO; name.selectable = NO;
        name.drawsBackground = NO;
        name.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        name.textColor = [WaveformView nsStemColorForIndex:(int)i
                                                      name:self.currentStemNames[i]];
        name.stringValue = [self.currentStemNames[i] uppercaseString];
        [row addSubview:name];
        row.nameLabel = name;

        NSButton* mute = [[NSButton alloc] initWithFrame:NSZeroRect];
        mute.title = @"M";
        mute.tag = i;
        mute.target = self;
        mute.action = @selector(stemMuteClicked:);
        [mute setButtonType:NSButtonTypePushOnPushOff];
        configureStemToggleButton(mute, @"Mute this stem (M)");
        updateStemToggleButtonAppearance(mute, NO, YES);
        [row addSubview:mute];
        row.muteButton = mute;
        [mutes addObject:mute];

        NSButton* solo = [[NSButton alloc] initWithFrame:NSZeroRect];
        solo.title = @"S";
        solo.tag = i;
        solo.target = self;
        solo.action = @selector(stemSoloClicked:);
        [solo setButtonType:NSButtonTypePushOnPushOff];
        configureStemToggleButton(solo, @"Solo this stem (S) — silences other stems");
        updateStemToggleButtonAppearance(solo, NO, NO);
        [row addSubview:solo];
        row.soloButton = solo;
        [solos addObject:solo];

        OSResettableSlider* gain = [[OSResettableSlider alloc] initWithFrame:NSZeroRect];
        gain.minValue = 0.0;
        gain.maxValue = 1.5;
        gain.doubleValue = 1.0;
        gain.resetValue = 1.0;
        gain.continuous = YES;
        gain.tag = i;
        gain.target = self;
        gain.action = @selector(stemGainChanged:);
        gain.toolTip = @"Drag to adjust stem gain (0–150%). Double-click to reset to 100%.";
        [row addSubview:gain];
        row.gainSlider = gain;
        [sliders addObject:gain];

        NSTextField* glabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        glabel.bezeled = NO; glabel.editable = NO; glabel.selectable = NO;
        glabel.drawsBackground = NO;
        glabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
        glabel.alignment = NSTextAlignmentRight;
        glabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
        glabel.stringValue = @"100%";
        [row addSubview:glabel];
        row.gainLabel = glabel;
        [labels addObject:glabel];

        NSTextField* gMin = [[NSTextField alloc] initWithFrame:NSZeroRect];
        gMin.bezeled = NO; gMin.editable = NO; gMin.selectable = NO;
        gMin.drawsBackground = NO;
        gMin.font = [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightRegular];
        gMin.alignment = NSTextAlignmentLeft;
        gMin.textColor = [NSColor colorWithWhite:0.50 alpha:1.0];
        gMin.stringValue = @"0%";
        [row addSubview:gMin];
        row.gainMinLabel = gMin;

        NSTextField* gMax = [[NSTextField alloc] initWithFrame:NSZeroRect];
        gMax.bezeled = NO; gMax.editable = NO; gMax.selectable = NO;
        gMax.drawsBackground = NO;
        gMax.font = [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightRegular];
        gMax.alignment = NSTextAlignmentRight;
        gMax.textColor = [NSColor colorWithWhite:0.50 alpha:1.0];
        gMax.stringValue = @"150%";
        [row addSubview:gMax];
        row.gainMaxLabel = gMax;

        // Right-click menu — reorder is now a drag-drop gesture on the row
        // body, so the only action surfaced here is the less-frequent
        // "transcribe to MIDI" call.
        NSMenu* rowMenu = [[NSMenu alloc] init];
        NSMenuItem* tr = [[NSMenuItem alloc]
            initWithTitle:@"Transcribe to MIDI\u2026"
                   action:@selector(transcribeStemClicked:)
            keyEquivalent:@""];
        tr.target = self;
        tr.tag = i;
        [rowMenu addItem:tr];
        row.menu = rowMenu;

        [sidebar addSubview:row];
    }

    self.sidebarStemMuteButtons = mutes;
    self.sidebarStemSoloButtons = solos;
    self.sidebarStemGainSliders = sliders;
    self.sidebarStemGainLabels  = labels;

    [self.mainWindow setStemSidebarVisible:YES];
    [sidebar resizeSubviewsWithOldSize:sidebar.bounds.size];
    [self syncStemMixerControls];
}

- (void)stemMuteClicked:(NSButton*)sender {
    if (!_engine || _engine->stemCount() < 2) return;
    _engine->setStemMuted((int)sender.tag, sender.state == NSControlStateValueOn);
    [self syncStemMixerControls];
}

- (void)stemSoloClicked:(NSButton*)sender {
    if (!_engine || _engine->stemCount() < 2) return;
    _engine->setStemSoloed((int)sender.tag, sender.state == NSControlStateValueOn);
    [self syncStemMixerControls];
}

- (void)stemGainChanged:(NSSlider*)sender {
    if (!_engine || _engine->stemCount() < 2) return;
    _engine->setStemGain((int)sender.tag, sender.doubleValue);
    [self syncStemMixerControls];
}

#pragma mark - StemSeparatorDelegate

- (void)stemSeparator:(StemSeparator*)sep progress:(double)frac {
    (void)sep;
    if (self.separateProgress.indeterminate) {
        [self.separateProgress stopAnimation:nil];
        self.separateProgress.indeterminate = NO;
    }
    self.separateProgress.doubleValue = frac;
    NSString* base = self.currentSeparateStage.length ? self.currentSeparateStage : @"Separating";
    NSTimeInterval elapsed = self.separateStartTime > 0
        ? [NSDate.date timeIntervalSince1970] - self.separateStartTime : 0.0;
    self.separateStatusLabel.stringValue =
        [NSString stringWithFormat:@"%@ — %d%% (%@)", base,
         (int)std::round(frac * 100.0), [self formatElapsed:elapsed]];
}

- (void)stemSeparator:(StemSeparator*)sep stage:(NSString*)message {
    (void)sep;
    self.currentSeparateStage = message;
    // Stage transitions reset the bar to indeterminate until the next
    // progress line lands — RoFormer can spend minutes in a single stage
    // without ticking, and a frozen 0% bar reads like a hang.
    self.separateProgress.indeterminate = YES;
    [self.separateProgress startAnimation:nil];
    NSTimeInterval elapsed = self.separateStartTime > 0
        ? [NSDate.date timeIntervalSince1970] - self.separateStartTime : 0.0;
    self.separateStatusLabel.stringValue =
        [NSString stringWithFormat:@"%@… (%@)", message, [self formatElapsed:elapsed]];
}

- (NSString*)formatElapsed:(NSTimeInterval)s {
    int total = (int)s;
    int m = total / 60;
    int sec = total % 60;
    if (m > 0) return [NSString stringWithFormat:@"%dm %02ds", m, sec];
    return [NSString stringWithFormat:@"%ds", sec];
}

- (void)refreshSeparateElapsedLabel {
    if (self.separateStartTime <= 0 || !self.currentSeparateStage.length) return;
    NSTimeInterval elapsed = [NSDate.date timeIntervalSince1970] - self.separateStartTime;
    if (self.separateProgress.indeterminate) {
        self.separateStatusLabel.stringValue =
            [NSString stringWithFormat:@"%@… (%@)", self.currentSeparateStage,
             [self formatElapsed:elapsed]];
    } else {
        int pct = (int)std::round(self.separateProgress.doubleValue * 100.0);
        self.separateStatusLabel.stringValue =
            [NSString stringWithFormat:@"%@ — %d%% (%@)", self.currentSeparateStage,
             pct, [self formatElapsed:elapsed]];
    }
}

- (void)stemSeparator:(StemSeparator*)sep
   didFinishWithStems:(NSArray<StemSeparation*>*)stems
                model:(NSString*)model {
    (void)sep; (void)model;
    [self.separateElapsedTimer invalidate];
    self.separateElapsedTimer = nil;
    [self.separateProgress stopAnimation:nil];
    self.separateProgress.indeterminate = NO;
    self.separateProgress.hidden = YES;
    self.separateProgress.doubleValue = 0.0;
    self.currentSeparateStage = nil;
    self.separateStartTime = 0;
    self.separateStatusLabel.stringValue = @"Done.";
    [self loadStemsFromSeparation:stems];
}

- (void)stemSeparator:(StemSeparator*)sep didFailWithError:(NSString*)message {
    (void)sep;
    [self.separateElapsedTimer invalidate];
    self.separateElapsedTimer = nil;
    [self.separateProgress stopAnimation:nil];
    self.separateProgress.indeterminate = NO;
    self.separateProgress.hidden = YES;
    self.currentSeparateStage = nil;
    self.separateStartTime = 0;
    self.separateStatusLabel.stringValue =
        [NSString stringWithFormat:@"Failed: %@",
         [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    [self syncStemMixerControls];
}

- (void)vocalCancelChanged:(NSSlider*)sender {
    _isolate.centerCancel = std::clamp(sender.doubleValue, 0.0, 1.0);
    [self syncIsolateControls];
    [self applyIsolateToEngine];
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
}

- (void)bassFocusToggled:(NSButton*)sender {
    _isolate.bassFocusEnabled = (sender.state == NSControlStateValueOn);
    [self syncIsolateControls];
    [self applyIsolateToEngine];
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
}

- (void)bassFocusCutoffChanged:(NSSlider*)sender {
    _isolate.bassFocusCutoffHz = sliderToHz(sender.doubleValue);
    [self syncIsolateControls];
    [self applyIsolateToEngine];
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
}

- (void)installKeyMonitor {
    __weak AppDelegate* weakSelf = self;
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent*(NSEvent* event) {
            AppDelegate* s = weakSelf;
            if (!s) return event;
            if (event.window != s.mainWindow || s.mainWindow.attachedSheet) return event;

            // Skip if a text field is editing — don't steal letters.
            NSResponder* fr = s.mainWindow.firstResponder;
            if ([fr isKindOfClass:[NSText class]]) return event;

            BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
            switch (event.keyCode) {
                case 49:  [s togglePlayPause]; return nil;             // space
                case 123: [s nudgeBy:-5.0];    return nil;             // left
                case 124: [s nudgeBy:+5.0];    return nil;             // right
                case 125: [s nudgeVolume:-0.05]; return nil;           // down
                case 126: [s nudgeVolume:+0.05]; return nil;           // up
                case 43:  [s nudgePitchSemis:-1]; return nil;          // ,
                case 47:  [s nudgePitchSemis:+1]; return nil;          // .
                case 27:  [s nudgeSpeed:-0.05]; return nil;            // -
                case 24:  [s nudgeSpeed:+0.05]; return nil;            // = / +
                case 29:  [s resetSpeedPitch];   return nil;           // 0
                case 37:  [s clearLoop];         return nil;           // L
                case 53:  [s clearLoop];         return nil;           // Esc
                case 115: [s seekTo:0.0];        return nil;           // Home
                case 36:  [s seekToLoopOrStart];  return nil;          // Return
                case 76:  [s seekToLoopOrStart];  return nil;          // Numpad Enter
                case 33:  if (shift) [s nudgeLoopStartBy:-0.10];       // [
                          else      [s setLoopStartHere];
                          return nil;
                case 30:  if (shift) [s nudgeLoopEndBy:+0.10];         // ]
                          else      [s setLoopEndHere];
                          return nil;
                case 11:  [s toggleBookmark]; return nil;              // B
                case 15:  [s renameNearestBookmark]; return nil;       // R
                case 18:  [s jumpToBookmark:0]; return nil;            // 1
                case 19:  [s jumpToBookmark:1]; return nil;            // 2
                case 20:  [s jumpToBookmark:2]; return nil;            // 3
                case 21:  [s jumpToBookmark:3]; return nil;            // 4
                case 23:  [s jumpToBookmark:4]; return nil;            // 5
                case 22:  [s jumpToBookmark:5]; return nil;            // 6
                case 26:  [s jumpToBookmark:6]; return nil;            // 7
                case 28:  [s jumpToBookmark:7]; return nil;            // 8
                case 25:  [s jumpToBookmark:8]; return nil;            // 9
                default:  return event;
            }
        }];
}

- (void)togglePlayPause {
    if (!_engine) return;
    if (_engine->isPlaying()) _engine->pause();
    else _engine->play();
    [self.mainWindow updatePlayPauseButton:_engine->isPlaying()];
}

- (void)playPauseClicked:(id)sender { (void)sender; [self togglePlayPause]; }
- (void)seekToStartClicked:(id)sender { [self seekTo:0.0]; }
- (void)skipBackClicked:(id)sender { [self nudgeBy:-5.0]; }
- (void)skipForwardClicked:(id)sender { [self nudgeBy:+5.0]; }

- (void)nudgeBy:(double)delta {
    if (!_engine || _engine->duration() <= 0.0) return;
    _engine->seek(_engine->currentTime() + delta);
}

- (void)seekTo:(double)t {
    if (!_engine) return;
    _engine->seek(t);
}

- (void)seekToLoopOrStart {
    if (!_engine) return;
    if (_engine->hasLoop()) {
        double t = _engine->loopStartFrame() / _engine->sampleRate();
        _engine->seek(t);
    } else {
        _engine->seek(0.0);
    }
}

- (void)nudgeVolume:(double)delta {
    NSSlider* s = self.mainWindow.volumeSlider;
    s.doubleValue = std::clamp(s.doubleValue + delta, s.minValue, s.maxValue);
    [self volumeChanged:s];
}

- (void)nudgePitchSemis:(int)semis {
    NSSlider* s = self.mainWindow.pitchSlider;
    s.doubleValue = std::clamp(s.doubleValue + semis * 100.0, s.minValue, s.maxValue);
    [self pitchChanged:s];
}

- (void)nudgeSpeed:(double)delta {
    NSSlider* s = self.mainWindow.speedSlider;
    s.doubleValue = std::clamp(s.doubleValue + delta, s.minValue, s.maxValue);
    [self speedChanged:s];
}

- (void)resetSpeedPitch {
    self.mainWindow.speedSlider.doubleValue = 1.0;
    self.mainWindow.pitchSlider.doubleValue = 0.0;
    [self speedChanged:self.mainWindow.speedSlider];
    [self pitchChanged:self.mainWindow.pitchSlider];
}

- (void)resetSpeedClicked:(id)sender {
    self.mainWindow.speedSlider.doubleValue = 1.0;
    [self speedChanged:self.mainWindow.speedSlider];
}

- (void)resetPitchClicked:(id)sender {
    self.mainWindow.pitchSlider.doubleValue = 0.0;
    [self pitchChanged:self.mainWindow.pitchSlider];
}

- (void)resetVolumeClicked:(id)sender {
    self.mainWindow.volumeSlider.doubleValue = 1.0;
    [self volumeChanged:self.mainWindow.volumeSlider];
}

- (void)clearLoop {
    if (_engine) _engine->clearLoop();
}

- (void)setLoopStartHere {
    if (!_engine || _engine->duration() <= 0.0) return;
    double t = _engine->currentTime();
    double sr = _engine->sampleRate();
    constexpr double kMin = 0.05;
    if (_engine->hasLoop()) {
        double end = _engine->loopEndFrame() / sr;
        if (t >= end - kMin) return;
        _engine->setLoop(t, end);
    } else {
        double end = std::min(_engine->duration(), t + 1.0);
        if (end - t < kMin) return;
        _engine->setLoop(t, end);
    }
}

- (void)setLoopEndHere {
    if (!_engine || _engine->duration() <= 0.0) return;
    double t = _engine->currentTime();
    double sr = _engine->sampleRate();
    constexpr double kMin = 0.05;
    if (_engine->hasLoop()) {
        double start = _engine->loopStartFrame() / sr;
        if (t <= start + kMin) return;
        _engine->setLoop(start, t);
    } else {
        double start = std::max(0.0, t - 1.0);
        if (t - start < kMin) return;
        _engine->setLoop(start, t);
    }
}

- (void)nudgeLoopStartBy:(double)delta {
    if (!_engine || !_engine->hasLoop()) return;
    double sr = _engine->sampleRate();
    double s = _engine->loopStartFrame() / sr;
    double e = _engine->loopEndFrame() / sr;
    double newS = std::clamp(s + delta, 0.0, e - 0.05);
    _engine->setLoop(newS, e);
}

- (void)nudgeLoopEndBy:(double)delta {
    if (!_engine || !_engine->hasLoop()) return;
    double sr = _engine->sampleRate();
    double s = _engine->loopStartFrame() / sr;
    double e = _engine->loopEndFrame() / sr;
    double newE = std::clamp(e + delta, s + 0.05, _engine->duration());
    _engine->setLoop(s, newE);
}

- (void)toggleBookmark {
    if (!_engine || _engine->duration() <= 0.0) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastBookmarkToggleTime < 0.20) return;
    _lastBookmarkToggleTime = now;

    double t = _engine->currentTime();
    constexpr double kProx = 0.30;
    for (auto it = _bookmarks.begin(); it != _bookmarks.end(); ++it) {
        if (std::abs(it->time - t) <= kProx) {
            _bookmarks.erase(it);
            [self pushBookmarksToView];
            return;
        }
    }
    _bookmarks.push_back({t, @""});
    std::sort(_bookmarks.begin(), _bookmarks.end(),
              [](const Bookmark& a, const Bookmark& b) { return a.time < b.time; });
    [self pushBookmarksToView];
}

- (void)jumpToBookmark:(NSInteger)index {
    if (!_engine) return;
    if (index < 0 || (size_t)index >= _bookmarks.size()) return;
    _engine->seek(_bookmarks[index].time);
}

- (NSInteger)nearestBookmarkIndex {
    if (!_engine || _bookmarks.empty()) return -1;
    double t = _engine->currentTime();
    NSInteger best = -1;
    double bestDist = INFINITY;
    for (size_t i = 0; i < _bookmarks.size(); ++i) {
        double d = std::abs(_bookmarks[i].time - t);
        if (d < bestDist) { bestDist = d; best = (NSInteger)i; }
    }
    return best;
}

- (void)renameBookmarkAtIndex:(NSInteger)index {
    if (index < 0 || (size_t)index >= _bookmarks.size()) return;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Bookmark %ld", (long)(index + 1)];
    alert.informativeText = @"Label this section (e.g., Head, Solo 1, Bridge).";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField* input = [[NSTextField alloc]
        initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.stringValue = _bookmarks[index].label ?: @"";
    input.placeholderString = @"e.g. Head, Solo 1, Bridge";
    alert.accessoryView = input;
    [alert.window setInitialFirstResponder:input];

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        _bookmarks[index].label = [input.stringValue copy] ?: @"";
        [self pushBookmarksToView];
        if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
    }
}

- (void)removeBookmarkAtIndex:(NSInteger)index {
    if (index < 0 || (size_t)index >= _bookmarks.size()) return;
    _bookmarks.erase(_bookmarks.begin() + index);
    [self pushBookmarksToView];
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
}

- (void)renameNearestBookmark {
    NSInteger i = [self nearestBookmarkIndex];
    if (i < 0) return;
    [self renameBookmarkAtIndex:i];
}

- (void)pushBookmarksToView {
    NSMutableArray<NSDictionary*>* arr = [NSMutableArray arrayWithCapacity:_bookmarks.size()];
    for (const Bookmark& b : _bookmarks) {
        [arr addObject:@{ @"time": @(b.time), @"label": (b.label ?: @"") }];
    }
    self.mainWindow.waveformView.bookmarks = arr;
}

- (NSString*)stateKeyForPath:(NSString*)path {
    NSData* data = [path dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", hash[i]];
    return [@"openscribe.file." stringByAppendingString:hex];
}

- (void)saveStateForPath:(NSString*)path {
    if (!path.length || !_engine || _engine->duration() <= 0.0) return;
    double sr = _engine->sampleRate();
    NSMutableArray<NSDictionary*>* bm = [NSMutableArray arrayWithCapacity:_bookmarks.size()];
    for (const Bookmark& b : _bookmarks) {
        [bm addObject:@{ @"time": @(b.time), @"label": (b.label ?: @"") }];
    }

    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    d[@"viewStart"] = @(self.mainWindow.waveformView.viewStart);
    d[@"viewEnd"]   = @(self.mainWindow.waveformView.viewEnd);
    d[@"speed"]     = @(_engine->speed());
    d[@"pitch"]     = @(_engine->pitch());
    d[@"volume"]    = @(_engine->volume());
    d[@"lastTime"]  = @(_engine->currentTime());
    d[@"bookmarks"] = bm;
    d[@"chords"]    = self.chords ?: @[];
    if (_engine->hasLoop()) {
        d[@"loopStart"] = @(_engine->loopStartFrame() / sr);
        d[@"loopEnd"]   = @(_engine->loopEndFrame() / sr);
    }
    d[@"smartLoopEnabled"]    = @(_smartLoop.enabled);
    d[@"smartLoopStartSpeed"] = @(_smartLoop.startSpeed);
    d[@"smartLoopEndSpeed"]   = @(_smartLoop.endSpeed);
    d[@"smartLoopStepSize"]   = @(_smartLoop.stepSize);
    d[@"smartLoopRepeats"]    = @(_smartLoop.repeatsPerStep);
    d[@"vocalCancel"]         = @(_isolate.centerCancel);
    d[@"bassFocusEnabled"]    = @(_isolate.bassFocusEnabled);
    d[@"bassFocusCutoffHz"]   = @(_isolate.bassFocusCutoffHz);
    [[NSUserDefaults standardUserDefaults] setObject:d
                                              forKey:[self stateKeyForPath:path]];
}

- (void)restoreStateForPath:(NSString*)path {
    [self.mainWindow setSheetMusicAudioPath:path];
    if (!path.length || !_engine) return;
    NSDictionary* d = [[NSUserDefaults standardUserDefaults]
                          dictionaryForKey:[self stateKeyForPath:path]];
    if (!d) return;

    NSNumber* nSpeed  = d[@"speed"];
    NSNumber* nPitch  = d[@"pitch"];
    NSNumber* nVol    = d[@"volume"];
    NSNumber* nLast   = d[@"lastTime"];
    NSNumber* nVS     = d[@"viewStart"];
    NSNumber* nVE     = d[@"viewEnd"];

    if (nSpeed) {
        double v = std::clamp(nSpeed.doubleValue, 0.25, 2.0);
        self.mainWindow.speedSlider.doubleValue = v;
        [self speedChanged:self.mainWindow.speedSlider];
    }
    if (nPitch) {
        double v = std::clamp(nPitch.doubleValue, -1200.0, 1200.0);
        self.mainWindow.pitchSlider.doubleValue = v;
        [self pitchChanged:self.mainWindow.pitchSlider];
    }
    if (nVol) {
        double v = std::clamp(nVol.doubleValue, 0.0, 1.5);
        self.mainWindow.volumeSlider.doubleValue = v;
        [self volumeChanged:self.mainWindow.volumeSlider];
    }
    if (nVS && nVE) {
        double s = nVS.doubleValue, e = nVE.doubleValue;
        if (e > s && s >= 0.0 && e <= 1.0) {
            [self.mainWindow.waveformView setViewStart:s end:e];
        }
    }
    NSArray* bm = d[@"bookmarks"];
    if ([bm isKindOfClass:[NSArray class]]) {
        _bookmarks.clear();
        for (id entry in bm) {
            if ([entry isKindOfClass:[NSDictionary class]]) {
                NSNumber* nT = ((NSDictionary*)entry)[@"time"];
                NSString* lbl = ((NSDictionary*)entry)[@"label"];
                if ([nT isKindOfClass:[NSNumber class]]) {
                    _bookmarks.push_back({nT.doubleValue,
                                          [lbl isKindOfClass:[NSString class]] ? [lbl copy] : @""});
                }
            } else if ([entry isKindOfClass:[NSNumber class]]) {
                // Backwards-compat with the pre-label format.
                _bookmarks.push_back({((NSNumber*)entry).doubleValue, @""});
            }
        }
        std::sort(_bookmarks.begin(), _bookmarks.end(),
                  [](const Bookmark& a, const Bookmark& b) { return a.time < b.time; });
        [self pushBookmarksToView];
    }
    NSArray* savedChords = d[@"chords"];
    if ([savedChords isKindOfClass:[NSArray class]]) {
        NSMutableArray* valid = [NSMutableArray array];
        for (id e in savedChords) {
            if ([e isKindOfClass:[NSDictionary class]] &&
                [((NSDictionary*)e)[@"start"] isKindOfClass:[NSNumber class]] &&
                [((NSDictionary*)e)[@"end"]   isKindOfClass:[NSNumber class]] &&
                [((NSDictionary*)e)[@"label"] isKindOfClass:[NSString class]]) {
                [valid addObject:e];
            }
        }
        [self setChords:valid];
    }
    NSNumber* ls = d[@"loopStart"];
    NSNumber* le = d[@"loopEnd"];
    if (ls && le && ls.doubleValue < le.doubleValue) {
        _engine->setLoop(ls.doubleValue, le.doubleValue);
    }
    if (nLast) {
        double t = nLast.doubleValue;
        if (t > 0.0 && t < _engine->duration()) _engine->seek(t);
    }

    NSNumber* slEnabled = d[@"smartLoopEnabled"];
    NSNumber* slStart   = d[@"smartLoopStartSpeed"];
    NSNumber* slEnd     = d[@"smartLoopEndSpeed"];
    NSNumber* slStep    = d[@"smartLoopStepSize"];
    NSNumber* slReps    = d[@"smartLoopRepeats"];
    if (slStart) _smartLoop.startSpeed = std::clamp(slStart.doubleValue, 0.25, 2.0);
    if (slEnd)   _smartLoop.endSpeed   = std::clamp(slEnd.doubleValue,   0.25, 2.0);
    if (slStep)  _smartLoop.stepSize   = std::clamp(slStep.doubleValue,  0.05, 0.5);
    if (slReps)  _smartLoop.repeatsPerStep = std::clamp((int)slReps.integerValue, 1, 10);
    _smartLoop.enabled = slEnabled.boolValue;
    [self resetSmartLoopBaseline];
    [self updateSmartLoopButtonTint];
    if (self.smartLoopPopover) [self syncSmartLoopControls];

    NSNumber* vc      = d[@"vocalCancel"];
    NSNumber* bfOn    = d[@"bassFocusEnabled"];
    NSNumber* bfHz    = d[@"bassFocusCutoffHz"];
    if (vc)   _isolate.centerCancel      = std::clamp(vc.doubleValue, 0.0, 1.0);
    if (bfOn) _isolate.bassFocusEnabled  = bfOn.boolValue;
    if (bfHz) _isolate.bassFocusCutoffHz = std::clamp(bfHz.doubleValue, 60.0, 2000.0);
    [self applyIsolateToEngine];
    if (self.isolatePopover) [self syncIsolateControls];
}

- (void)speedChanged:(NSSlider*)sender {
    if (!_engine) return;
    double v = sender.doubleValue;
    _engine->setSpeed(v);
    self.mainWindow.speedLabel.stringValue =
        [NSString stringWithFormat:@"%.2fx", v];
}

- (void)pitchChanged:(NSSlider*)sender {
    if (!_engine) return;
    double cents = sender.doubleValue;
    _engine->setPitch(cents);
    double semis = cents / 100.0;
    self.mainWindow.pitchLabel.stringValue =
        [NSString stringWithFormat:@"%+.2f st", semis];
}

- (void)volumeChanged:(NSSlider*)sender {
    if (!_engine) return;
    double v = sender.doubleValue;
    _engine->setVolume(v);
    self.mainWindow.volumeLabel.stringValue =
        [NSString stringWithFormat:@"%d%%", (int)std::round(v * 100.0)];
}

- (void)showIRealLibrary:(id)sender {
    [self.mainWindow showIRealLibrary:sender];
}

- (void)openSheetMusic:(id)sender {
    [self.mainWindow openSheetMusic:sender];
}

- (void)toggleSheetMusic:(id)sender {
    [self.mainWindow toggleSheetMusic:sender];
}

- (void)openFile:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.allowedFileTypes = @[@"wav", @"mp3", @"m4a", @"aac", @"flac",
                                @"aif", @"aiff", @"caf"];

    if ([panel runModal] != NSModalResponseOK) return;
    NSURL* url = panel.URLs.firstObject;
    if (!url) return;
    [self loadPath:url.path];
}

#pragma mark - YouTube import

- (void)openMediaURL:(id)sender {
    (void)sender;

    if (!self.mediaDownloader.isHelperAvailable) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"Media import helper not installed";
        a.informativeText = @"Install yt-dlp into tools/media-helper/venv/ "
                            @"(see README) or rebundle the .app.";
        [a runModal];
        return;
    }

    NSWindow* parent = self.mainWindow;
    if (!parent) return;

    // Custom sheet instead of NSAlert+accessoryView: the latter has had
    // unreliable first-responder routing on recent macOS — keystrokes
    // (including ⌫ and printable characters) sometimes never reach the
    // text field. A real titled NSWindow gives us a proper responder
    // chain plus room for a usable URL-sized field.
    CGFloat W = 520, H = 150;
    NSWindow* sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    sheet.title = @"Import Media URL";
    NSView* content = sheet.contentView;

    NSTextField* prompt = [NSTextField labelWithString:
        @"Paste a supported media link. The audio will be downloaded and loaded into the editor."];
    prompt.font = [NSFont systemFontOfSize:12];
    prompt.frame = NSMakeRect(20, H - 44, W - 40, 32);
    prompt.lineBreakMode = NSLineBreakByWordWrapping;
    prompt.maximumNumberOfLines = 2;
    [content addSubview:prompt];

    NSTextField* field = [[NSTextField alloc] initWithFrame:
        NSMakeRect(20, 56, W - 40, 26)];
    field.placeholderString = @"https://…";
    field.font = [NSFont systemFontOfSize:13];
    field.editable = YES;
    field.selectable = YES;
    field.bezeled = YES;
    field.bezelStyle = NSTextFieldRoundedBezel;
    // NSTextField doesn't horizontally scroll long content by default — the
    // cursor moves but the visible window stays put, leaving the user stuck
    // looking at a fixed slice of the URL. Single-line + scrollable + no
    // wrapping makes arrow keys / Home / End reveal the rest as expected.
    field.usesSingleLineMode = YES;
    field.cell.scrollable = YES;
    field.cell.wraps = NO;
    [content addSubview:field];

    // Pre-fill from clipboard if it looks like a YouTube or Instagram URL —
    // saves a paste.
    NSString* clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (clip.length) {
        NSString* trimmed = [clip stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString* lower = trimmed.lowercaseString;
        BOOL looksRelevant = [lower rangeOfString:@"youtu"].location != NSNotFound
                           || [lower rangeOfString:@"instagram.com"].location != NSNotFound
                           || [lower rangeOfString:@"instagr.am"].location != NSNotFound;
        if (looksRelevant && [trimmed hasPrefix:@"http"]) {
            field.stringValue = trimmed;
        }
    }

    NSButton* download = [NSButton buttonWithTitle:@"Download"
                                            target:self
                                            action:@selector(submitMediaURL:)];
    download.bezelStyle = NSBezelStyleRounded;
    download.keyEquivalent = @"\r"; // Enter triggers Download
    download.frame = NSMakeRect(W - 120, 14, 100, 28);
    [content addSubview:download];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel"
                                          target:self
                                          action:@selector(cancelMediaURLSheet:)];
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.keyEquivalent = @"\e"; // Escape cancels
    cancel.frame = NSMakeRect(W - 220, 14, 90, 28);
    [content addSubview:cancel];

    self.mediaURLSheet = sheet;
    self.mediaURLField = field;

    [parent beginSheet:sheet completionHandler:^(NSModalResponse) {}];
    // beginSheet hands focus to the sheet asynchronously; making the field
    // first responder afterwards ensures the cursor lands in it on appear.
    [sheet makeFirstResponder:field];
    if (field.stringValue.length) {
        // Select all so the user can immediately overtype the prefilled URL.
        [field selectText:nil];
    }
}

- (void)submitMediaURL:(id)sender {
    (void)sender;
    NSString* url = [self.mediaURLField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self closeMediaURLSheet];
    if (!url.length) return;

    self.mediaPendingURL = url;
    self.mediaUserCancelled = NO;
    [self showMediaProgressSheet];
    [self.mediaDownloader downloadURL:url];
}

- (void)cancelMediaURLSheet:(id)sender {
    (void)sender;
    [self closeMediaURLSheet];
}

- (void)closeMediaURLSheet {
    if (!self.mediaURLSheet) return;
    NSWindow* parent = self.mainWindow;
    if (parent) [parent endSheet:self.mediaURLSheet returnCode:NSModalResponseOK];
    self.mediaURLSheet = nil;
    self.mediaURLField = nil;
}

#pragma mark - Downloads Manager

+ (NSString*)mediaCacheRoot {
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = a.firstObject ?: NSTemporaryDirectory();
    return [[base stringByAppendingPathComponent:@"OpenScribe"]
                  stringByAppendingPathComponent:@"youtube"];
}

+ (NSString*)stemsCacheRoot {
    NSArray* a = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = a.firstObject ?: NSTemporaryDirectory();
    return [[base stringByAppendingPathComponent:@"OpenScribe"]
                  stringByAppendingPathComponent:@"stems"];
}

+ (long long)dirSizeAtPath:(NSString*)path {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator* e = [fm enumeratorAtPath:path];
    long long total = 0;
    for (NSString* sub in e) {
        NSDictionary* attrs = [e fileAttributes];
        if ([attrs[NSFileType] isEqual:NSFileTypeRegular]) {
            total += [attrs[NSFileSize] longLongValue];
        }
    }
    return total;
}

+ (NSString*)formatBytes:(long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B", bytes];
    double kb = bytes / 1024.0;
    if (kb < 1024) return [NSString stringWithFormat:@"%.0f KB", kb];
    double mb = kb / 1024.0;
    if (mb < 1024) return [NSString stringWithFormat:@"%.1f MB", mb];
    return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
}

+ (NSString*)formatDuration:(double)seconds {
    if (seconds <= 0) return @"—";
    int s = (int)round(seconds);
    int m = s / 60;
    int sec = s % 60;
    int h = m / 60;
    m = m % 60;
    if (h > 0) return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, sec];
    return [NSString stringWithFormat:@"%d:%02d", m, sec];
}

+ (NSString*)sha256Hex:(NSString*)s {
    NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, hash);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", hash[i]];
    return hex;
}

- (void)showDownloadsManager:(id)sender {
    (void)sender;
    if (self.downloadsWindow) {
        [self.downloadsWindow makeKeyAndOrderFront:nil];
        [self reloadDownloadsList];
        return;
    }

    CGFloat W = 720, H = 460;
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"Downloads";
    w.minSize = NSMakeSize(560, 320);
    w.releasedWhenClosed = NO;
    NSView* content = w.contentView;

    // Top tab strip — segmented control swaps between YouTube downloads
    // and the stem-separation cache. Both lists support multi-select +
    // delete + reveal so users can prune either category independently.
    CGFloat topH = 40;
    NSSegmentedControl* seg = [NSSegmentedControl segmentedControlWithLabels:
        @[@"Downloads", @"Stem Cache"]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self
                                                                      action:@selector(downloadsSegmentChanged:)];
    seg.frame = NSMakeRect((W - 240) / 2.0, H - topH + 6, 240, 26);
    seg.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    [seg setSelectedSegment:0];
    [content addSubview:seg];
    self.downloadsSegment = seg;

    // Bottom toolbar — reserved 44pt strip with status label + buttons.
    CGFloat bottomH = 44;
    NSTextField* total = [NSTextField labelWithString:@"—"];
    total.frame = NSMakeRect(16, 14, 320, 18);
    total.font = [NSFont systemFontOfSize:11];
    total.textColor = [NSColor secondaryLabelColor];
    total.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:total];
    self.downloadsTotalLabel = total;

    NSButton* delBtn = [NSButton buttonWithTitle:@"Delete Selected"
                                          target:self
                                          action:@selector(deleteSelectedDownloads:)];
    delBtn.bezelStyle = NSBezelStyleRounded;
    delBtn.frame = NSMakeRect(W - 280, 8, 140, 28);
    delBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:delBtn];

    NSButton* revealBtn = [NSButton buttonWithTitle:@"Reveal in Finder"
                                             target:self
                                             action:@selector(revealSelectedDownload:)];
    revealBtn.bezelStyle = NSBezelStyleRounded;
    revealBtn.frame = NSMakeRect(W - 420, 8, 130, 28);
    revealBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:revealBtn];

    NSButton* closeBtn = [NSButton buttonWithTitle:@"Close"
                                            target:w
                                            action:@selector(performClose:)];
    closeBtn.bezelStyle = NSBezelStyleRounded;
    closeBtn.frame = NSMakeRect(W - 120, 8, 100, 28);
    closeBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:closeBtn];

    // Table inside a scroll view filling the rest of the window.
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, bottomH, W, H - bottomH - topH)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;

    NSTableView* table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    table.allowsMultipleSelection = YES;
    table.usesAlternatingRowBackgroundColors = YES;
    table.rowSizeStyle = NSTableViewRowSizeStyleMedium;
    table.dataSource = self;
    table.delegate = self;
    table.doubleAction = @selector(openSelectedDownload:);
    table.target = self;

    scroll.documentView = table;
    [content addSubview:scroll];

    self.downloadsWindow = w;
    self.downloadsTable = table;
    self.downloadsViewMode = 0;
    [self rebuildDownloadsTableColumns];
    [self reloadDownloadsList];

    [w center];
    [w makeKeyAndOrderFront:nil];
}

- (void)rebuildDownloadsTableColumns {
    // Wipe + recreate columns so the header titles + widths match the
    // active view mode. NSTableView has no concept of "preset column sets".
    NSArray* old = [self.downloadsTable.tableColumns copy];
    for (NSTableColumn* c in old) [self.downloadsTable removeTableColumn:c];

    void (^add)(NSString*, NSString*, CGFloat, CGFloat) =
    ^(NSString* ident, NSString* title, CGFloat width, CGFloat minWidth) {
        NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:ident];
        c.title = title;
        c.width = width;
        c.minWidth = minWidth;
        [self.downloadsTable addTableColumn:c];
    };

    if (self.downloadsViewMode == 0) {
        add(@"title",    @"Title",      360, 200);
        add(@"duration", @"Duration",    80,  60);
        add(@"size",     @"Size",        90,  60);
        add(@"date",     @"Downloaded", 150, 100);
    } else {
        add(@"title", @"Source",        330, 180);
        add(@"model", @"Model",         110,  80);
        add(@"size",  @"Size",           90,  60);
        add(@"date",  @"Created",       150, 100);
    }
}

- (void)downloadsSegmentChanged:(id)sender {
    (void)sender;
    self.downloadsViewMode = self.downloadsSegment.selectedSegment;
    [self rebuildDownloadsTableColumns];
    [self reloadDownloadsList];
}

- (void)reloadDownloadsList {
    [self loadDownloadItems];
    [self loadStemCacheItems];
    [self.downloadsTable reloadData];

    NSUInteger count = 0;
    long long total = 0;
    if (self.downloadsViewMode == 0) {
        count = self.downloadsItems.count;
        for (OSDownloadItem* it in self.downloadsItems) total += it.sizeBytes;
    } else {
        count = self.stemCacheItems.count;
        for (OSStemCacheItem* it in self.stemCacheItems) total += it.sizeBytes;
    }
    self.downloadsTotalLabel.stringValue =
        [NSString stringWithFormat:@"%lu item%@ • %@ total",
            (unsigned long)count,
            count == 1 ? @"" : @"s",
            [AppDelegate formatBytes:total]];
}

- (void)loadDownloadItems {
    NSString* root = [AppDelegate mediaCacheRoot];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray<OSDownloadItem*>* out = [NSMutableArray array];

    NSArray<NSString*>* entries = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString* name in entries) {
        if ([name hasPrefix:@"."]) continue;
        NSString* dir = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;

        OSDownloadItem* item = [[OSDownloadItem alloc] init];
        item.dir = dir;
        item.title = name; // fallback to hash if no manifest

        NSString* manifestPath = [dir stringByAppendingPathComponent:@"manifest.json"];
        NSData* mdata = [NSData dataWithContentsOfFile:manifestPath];
        if (mdata) {
            NSDictionary* m = [NSJSONSerialization JSONObjectWithData:mdata
                                                              options:0 error:nil];
            if ([m isKindOfClass:NSDictionary.class]) {
                if ([m[@"title"] isKindOfClass:NSString.class]) item.title = m[@"title"];
                if ([m[@"filepath"] isKindOfClass:NSString.class]) item.audioPath = m[@"filepath"];
                if ([m[@"url"] isKindOfClass:NSString.class]) item.url = m[@"url"];
                if ([m[@"duration"] isKindOfClass:NSNumber.class])
                    item.durationSeconds = [m[@"duration"] doubleValue];
            }
        }

        NSDictionary* attrs = [fm attributesOfItemAtPath:dir error:nil];
        item.downloadedAt = attrs[NSFileModificationDate];
        item.sizeBytes = [AppDelegate dirSizeAtPath:dir];
        [out addObject:item];
    }

    [out sortUsingComparator:^NSComparisonResult(OSDownloadItem* a, OSDownloadItem* b) {
        return [b.downloadedAt compare:a.downloadedAt]; // newest first
    }];
    self.downloadsItems = out;
}

- (void)loadStemCacheItems {
    NSString* root = [AppDelegate stemsCacheRoot];
    NSFileManager* fm = NSFileManager.defaultManager;

    // Build a hash → title map from current downloads so we can label
    // stem cache rows with a friendly source name.
    NSMutableDictionary<NSString*, NSString*>* hashToTitle =
        [NSMutableDictionary dictionary];
    for (OSDownloadItem* d in self.downloadsItems) {
        if (!d.audioPath.length) continue;
        NSString* canon = d.audioPath.stringByStandardizingPath;
        NSString* h = [AppDelegate sha256Hex:canon];
        if (h && d.title.length) hashToTitle[h] = d.title;
    }

    NSMutableArray<OSStemCacheItem*>* out = [NSMutableArray array];
    NSArray<NSString*>* hashes = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString* h in hashes) {
        if ([h hasPrefix:@"."]) continue;
        NSString* hashDir = [root stringByAppendingPathComponent:h];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:hashDir isDirectory:&isDir] || !isDir) continue;

        // Each <hash> dir contains one subdir per model run against that source.
        NSArray<NSString*>* models = [fm contentsOfDirectoryAtPath:hashDir error:nil];
        for (NSString* model in models) {
            if ([model hasPrefix:@"."]) continue;
            NSString* modelDir = [hashDir stringByAppendingPathComponent:model];
            BOOL isModelDir = NO;
            if (![fm fileExistsAtPath:modelDir isDirectory:&isModelDir] || !isModelDir) continue;

            OSStemCacheItem* item = [[OSStemCacheItem alloc] init];
            item.dir = modelDir;
            item.hashName = h;
            item.model = model;
            item.sourceTitle = hashToTitle[h]; // nil if orphaned (source no longer cached)
            NSDictionary* attrs = [fm attributesOfItemAtPath:modelDir error:nil];
            item.createdAt = attrs[NSFileModificationDate];
            item.sizeBytes = [AppDelegate dirSizeAtPath:modelDir];
            [out addObject:item];
        }
    }

    [out sortUsingComparator:^NSComparisonResult(OSStemCacheItem* a, OSStemCacheItem* b) {
        return [b.createdAt compare:a.createdAt];
    }];
    self.stemCacheItems = out;
}

- (void)deleteSelectedDownloads:(id)sender {
    (void)sender;
    NSIndexSet* sel = self.downloadsTable.selectedRowIndexes;
    if (sel.count == 0) return;

    BOOL stemMode = (self.downloadsViewMode == 1);

    NSAlert* a = [[NSAlert alloc] init];
    if (stemMode) {
        a.messageText = sel.count == 1
            ? @"Delete this stem cache entry?"
            : [NSString stringWithFormat:@"Delete %lu stem cache entries?",
                                          (unsigned long)sel.count];
        a.informativeText = @"The separated stem files will be removed from disk. "
                            @"The original audio is kept. You can re-run separation "
                            @"any time. This can't be undone.";
    } else {
        a.messageText = sel.count == 1
            ? @"Delete this download?"
            : [NSString stringWithFormat:@"Delete %lu downloads?", (unsigned long)sel.count];
        a.informativeText = @"The audio file and any cached stem separations for it "
                            @"will be removed from disk. This can't be undone.";
    }
    [a addButtonWithTitle:@"Delete"];
    [a addButtonWithTitle:@"Cancel"];
    a.alertStyle = NSAlertStyleWarning;
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    NSFileManager* fm = NSFileManager.defaultManager;

    if (stemMode) {
        NSMutableArray<OSStemCacheItem*>* toDelete = [NSMutableArray array];
        [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
            (void)stop;
            if (idx < self.stemCacheItems.count) [toDelete addObject:self.stemCacheItems[idx]];
        }];
        for (OSStemCacheItem* it in toDelete) {
            [fm removeItemAtPath:it.dir error:nil];
            // If the parent <hash> dir is now empty (no other models cached
            // for this source), prune it too so the cache root stays tidy.
            NSString* parent = it.dir.stringByDeletingLastPathComponent;
            NSArray* leftover = [fm contentsOfDirectoryAtPath:parent error:nil];
            if (leftover.count == 0) [fm removeItemAtPath:parent error:nil];
        }
    } else {
        NSString* stemsRoot = [AppDelegate stemsCacheRoot];
        NSMutableArray<OSDownloadItem*>* toDelete = [NSMutableArray array];
        [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
            (void)stop;
            if (idx < self.downloadsItems.count) [toDelete addObject:self.downloadsItems[idx]];
        }];
        for (OSDownloadItem* it in toDelete) {
            // Cascade to stem cache: the stems key is sha256 of the audio
            // file's standardized path, so we can locate and wipe any
            // precomputed separations alongside the download.
            if (it.audioPath.length) {
                NSString* canon = it.audioPath.stringByStandardizingPath;
                NSString* stemsHash = [AppDelegate sha256Hex:canon];
                NSString* stemsDir = [stemsRoot stringByAppendingPathComponent:stemsHash];
                [fm removeItemAtPath:stemsDir error:nil];
            }
            [fm removeItemAtPath:it.dir error:nil];
        }
    }

    [self reloadDownloadsList];
}

- (void)revealSelectedDownload:(id)sender {
    (void)sender;
    NSInteger row = self.downloadsTable.selectedRow;
    if (row < 0) return;
    NSString* target = nil;
    if (self.downloadsViewMode == 0) {
        if (row >= (NSInteger)self.downloadsItems.count) return;
        OSDownloadItem* it = self.downloadsItems[row];
        target = it.audioPath.length ? it.audioPath : it.dir;
    } else {
        if (row >= (NSInteger)self.stemCacheItems.count) return;
        target = self.stemCacheItems[row].dir;
    }
    if (!target.length) return;
    [[NSWorkspace sharedWorkspace] selectFile:target inFileViewerRootedAtPath:@""];
}

- (void)openSelectedDownload:(id)sender {
    (void)sender;
    if (self.downloadsViewMode != 0) return;   // double-click on stem rows is a no-op
    NSInteger row = self.downloadsTable.clickedRow;
    if (row < 0) row = self.downloadsTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.downloadsItems.count) return;
    OSDownloadItem* it = self.downloadsItems[row];
    if (!it.audioPath.length) return;
    [self loadPath:it.audioPath];
}

#pragma mark NSTableViewDataSource / Delegate (Downloads)

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    if (tableView != self.downloadsTable) return 0;
    return self.downloadsViewMode == 0
        ? (NSInteger)self.downloadsItems.count
        : (NSInteger)self.stemCacheItems.count;
}

- (NSView*)tableView:(NSTableView*)tableView
    viewForTableColumn:(NSTableColumn*)column
                   row:(NSInteger)row {
    if (tableView != self.downloadsTable) return nil;

    NSString* ident = column.identifier;
    NSString* text = @"";

    if (self.downloadsViewMode == 0) {
        if (row < 0 || row >= (NSInteger)self.downloadsItems.count) return nil;
        OSDownloadItem* it = self.downloadsItems[row];
        if ([ident isEqualToString:@"title"]) {
            text = it.title.length ? it.title : it.dir.lastPathComponent;
        } else if ([ident isEqualToString:@"duration"]) {
            text = [AppDelegate formatDuration:it.durationSeconds];
        } else if ([ident isEqualToString:@"size"]) {
            text = [AppDelegate formatBytes:it.sizeBytes];
        } else if ([ident isEqualToString:@"date"]) {
            if (it.downloadedAt) {
                NSDateFormatter* df = [[NSDateFormatter alloc] init];
                df.dateStyle = NSDateFormatterMediumStyle;
                df.timeStyle = NSDateFormatterShortStyle;
                text = [df stringFromDate:it.downloadedAt];
            }
        }
    } else {
        if (row < 0 || row >= (NSInteger)self.stemCacheItems.count) return nil;
        OSStemCacheItem* it = self.stemCacheItems[row];
        if ([ident isEqualToString:@"title"]) {
            text = it.sourceTitle.length
                ? it.sourceTitle
                : [NSString stringWithFormat:@"(unknown source · %@…)",
                            [it.hashName substringToIndex:MIN((NSUInteger)10, it.hashName.length)]];
        } else if ([ident isEqualToString:@"model"]) {
            text = it.model ?: @"";
        } else if ([ident isEqualToString:@"size"]) {
            text = [AppDelegate formatBytes:it.sizeBytes];
        } else if ([ident isEqualToString:@"date"]) {
            if (it.createdAt) {
                NSDateFormatter* df = [[NSDateFormatter alloc] init];
                df.dateStyle = NSDateFormatterMediumStyle;
                df.timeStyle = NSDateFormatterShortStyle;
                text = [df stringFromDate:it.createdAt];
            }
        }
    }

    NSTableCellView* cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 22)];
        cell.identifier = ident;
        NSTextField* tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.font = [NSFont systemFontOfSize:12];
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = text;
    return cell;
}

- (void)showMediaProgressSheet {
    NSWindow* parent = self.mainWindow;
    if (!parent) return;

    NSRect frame = NSMakeRect(0, 0, 420, 120);
    NSWindow* sheet = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    sheet.title = @"Downloading audio";

    NSView* content = sheet.contentView;

    NSTextField* status = [NSTextField labelWithString:@"Resolving video…"];
    status.frame = NSMakeRect(20, 70, 380, 20);
    status.font = [NSFont systemFontOfSize:12];
    [content addSubview:status];

    NSProgressIndicator* bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 44, 380, 16)];
    bar.style = NSProgressIndicatorStyleBar;
    bar.indeterminate = YES;
    bar.minValue = 0.0;
    bar.maxValue = 1.0;
    [bar startAnimation:nil];
    [content addSubview:bar];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel"
                                          target:self
                                          action:@selector(cancelMediaDownload:)];
    cancel.frame = NSMakeRect(330, 10, 70, 24);
    cancel.bezelStyle = NSBezelStyleRounded;
    [content addSubview:cancel];

    self.mediaProgressSheet = sheet;
    self.mediaStatusLabel = status;
    self.mediaProgressBar = bar;

    [parent beginSheet:sheet completionHandler:^(NSModalResponse) {}];
}

- (void)dismissMediaProgressSheet {
    if (!self.mediaProgressSheet) return;
    NSWindow* parent = self.mainWindow;
    [self.mediaProgressBar stopAnimation:nil];
    if (parent) {
        [parent endSheet:self.mediaProgressSheet returnCode:NSModalResponseOK];
    }
    self.mediaProgressSheet = nil;
    self.mediaStatusLabel = nil;
    self.mediaProgressBar = nil;
}

- (void)cancelMediaDownload:(id)sender {
    (void)sender;
    self.mediaUserCancelled = YES;
    [self.mediaDownloader cancel];
}

#pragma mark - MediaDownloaderDelegate

- (void)mediaDownloader:(MediaDownloader*)dl progress:(double)frac {
    (void)dl;
    if (!self.mediaProgressBar) return;
    if (frac > 0.0) {
        self.mediaProgressBar.indeterminate = NO;
        self.mediaProgressBar.doubleValue = frac;
    }
    self.mediaStatusLabel.stringValue =
        [NSString stringWithFormat:@"Downloading… %d%%", (int)std::round(frac * 100.0)];
}

- (void)mediaDownloader:(MediaDownloader*)dl stage:(NSString*)message {
    (void)dl;
    if (self.mediaStatusLabel && message.length) {
        self.mediaStatusLabel.stringValue = message;
    }
}

- (void)mediaDownloader:(MediaDownloader*)dl
       didFinishWithPath:(NSString*)audioPath
                   title:(NSString*)title {
    (void)dl;
    (void)title;
    [self dismissMediaProgressSheet];
    self.mediaPendingURL = nil;
    [self loadPath:audioPath];
}

- (void)mediaDownloader:(MediaDownloader*)dl didFailWithError:(NSString*)message {
    (void)dl;
    BOOL wasCancel = self.mediaUserCancelled;
    [self dismissMediaProgressSheet];
    self.mediaPendingURL = nil;
    self.mediaUserCancelled = NO;
    if (wasCancel) return;  // user-initiated cancel — don't badger them
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"Download failed";
    a.informativeText = message.length ? message : @"Unknown error.";
    a.alertStyle = NSAlertStyleWarning;

    NSString* lower = message.lowercaseString;
    BOOL needsLogin = [lower rangeOfString:@"login required"].location != NSNotFound
                    || [lower rangeOfString:@"rate-limit"].location != NSNotFound;
    [a addButtonWithTitle:@"OK"];
    if (needsLogin) [a addButtonWithTitle:@"Open Settings…"];

    if ([a runModal] == NSAlertSecondButtonReturn) {
        [self showSettings:nil];
    }
}

#pragma mark - Stem reordering

// Move a stem from one position to another in lockstep across engine, peaks,
// and the parallel name/path arrays the UI uses. The waveform reload picks
// up the new peak order from the engine; setStemNames re-tints labels;
// rebuildStemSidebar regenerates the rows in the new order. MIDI overlay
// notes are keyed by stem name so they automatically follow the renamed
// lane. Handles non-adjacent moves (drag-drop crosses multiple slots) via
// remove-then-insert on the order vector.
- (void)moveStemFrom:(int)from to:(int)to {
    if (!_engine) return;
    int n = _engine->stemCount();
    if (from < 0 || to < 0 || from >= n || to >= n || from == to) return;
    if ((NSUInteger)n != self.currentStemNames.count
     || (NSUInteger)n != self.currentStemPaths.count) return;

    std::vector<int> order;
    order.reserve((size_t)n);
    for (int k = 0; k < n; ++k) order.push_back(k);
    int moved = order[(size_t)from];
    order.erase(order.begin() + from);
    order.insert(order.begin() + to, moved);

    _engine->reorderStems(order);

    NSMutableArray<NSString*>* names = [self.currentStemNames mutableCopy];
    NSMutableArray<NSString*>* paths = [self.currentStemPaths mutableCopy];
    NSString* nameMoved = names[(NSUInteger)from];
    NSString* pathMoved = paths[(NSUInteger)from];
    [names removeObjectAtIndex:(NSUInteger)from];
    [paths removeObjectAtIndex:(NSUInteger)from];
    [names insertObject:nameMoved atIndex:(NSUInteger)to];
    [paths insertObject:pathMoved atIndex:(NSUInteger)to];
    self.currentStemNames = names;
    self.currentStemPaths = paths;

    [self.mainWindow.waveformView reloadFromEngine];
    [self.mainWindow.waveformView setStemNames:names];
    [self rebuildStemSidebar];

    if (self.isolatePopover.isShown) {
        NSView* anchor = self.mainWindow.isolateButton;
        [self.isolatePopover close];
        [self showIsolatePopover:anchor];
    } else {
        [self syncStemMixerControls];
    }
}

#pragma mark - Basic Pitch transcription

- (void)transcribeTrackClicked:(id)sender {
    (void)sender;
    if (!self.currentFilePath.length) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Open an audio track first";
        alert.informativeText = @"Choose File → Open, then transcribe the loaded track to MIDI.";
        [alert runModal];
        return;
    }
    [self transcribeAudioPath:self.currentFilePath name:@"Full Track" tag:@"__full_track__"];
}

- (void)transcribeStemClicked:(id)sender {
    NSInteger idx = [sender isKindOfClass:NSMenuItem.class]
        ? [(NSMenuItem*)sender tag] : -1;
    if (idx < 0 || (NSUInteger)idx >= self.currentStemPaths.count) return;
    NSString* stemPath = self.currentStemPaths[(NSUInteger)idx];
    NSString* stemName = (NSUInteger)idx < self.currentStemNames.count
                         ? self.currentStemNames[(NSUInteger)idx] : @"stem";

    [self transcribeAudioPath:stemPath name:stemName tag:stemName];
}

- (void)transcribeAudioPath:(NSString*)audioPath name:(NSString*)sourceName tag:(NSString*)sourceTag {
    if (!self.basicPitch.isHelperAvailable) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"Transcribe helper not found";
        a.informativeText = @"The basic-pitch helper is missing. Re-run "
                            @"bundle_helper.sh to install it.";
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
        return;
    }
    if (self.basicPitch.isRunning) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"Transcription already running";
        a.informativeText = @"Wait for the current MIDI export to finish.";
        a.alertStyle = NSAlertStyleInformational;
        [a runModal];
        return;
    }

    // Default filename: <source-stem>-<stemName>.mid next to the source file.
    NSString* baseName =
        [self.currentFilePath.lastPathComponent stringByDeletingPathExtension];
    if (!baseName.length) baseName = @"transcription";
    NSString* defaultName =
        [NSString stringWithFormat:@"%@-%@.mid", baseName, sourceName];

    NSSavePanel* sp = [NSSavePanel savePanel];
    sp.title = @"Export MIDI";
    sp.nameFieldStringValue = defaultName;
    sp.allowedFileTypes = @[ @"mid", @"midi" ];
    if (self.currentFilePath.length) {
        sp.directoryURL = [NSURL fileURLWithPath:
            [self.currentFilePath stringByDeletingLastPathComponent]];
    }
    NSWindow* parent = self.mainWindow;
    [sp beginSheetModalForWindow:parent completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !sp.URL.path.length) return;
        // Spin up the progress sheet *after* the save panel dismisses, on
        // the next runloop tick — beginSheet doesn't like being called
        // directly from another sheet's completion handler.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.transcribePendingOutput = sp.URL.path;
            [self showTranscribeProgressSheetForStem:sourceName];
            [self.basicPitch transcribeFile:audioPath
                                     toMIDI:sp.URL.path
                                        tag:sourceTag];
        });
    }];
}

- (void)showTranscribeProgressSheetForStem:(NSString*)stemName {
    NSWindow* parent = self.mainWindow;
    if (!parent) return;

    NSRect frame = NSMakeRect(0, 0, 420, 120);
    NSWindow* sheet = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    sheet.title = [NSString stringWithFormat:@"Transcribing %@…", stemName];

    NSView* content = sheet.contentView;

    NSTextField* status = [NSTextField labelWithString:@"Loading model…"];
    status.frame = NSMakeRect(20, 70, 380, 20);
    status.font = [NSFont systemFontOfSize:12];
    [content addSubview:status];

    NSProgressIndicator* bar = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(20, 44, 380, 16)];
    bar.style = NSProgressIndicatorStyleBar;
    bar.indeterminate = YES;
    bar.minValue = 0.0;
    bar.maxValue = 1.0;
    [bar startAnimation:nil];
    [content addSubview:bar];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel"
                                          target:self
                                          action:@selector(cancelTranscribe:)];
    cancel.frame = NSMakeRect(330, 10, 70, 24);
    cancel.bezelStyle = NSBezelStyleRounded;
    [content addSubview:cancel];

    self.transcribeProgressSheet = sheet;
    self.transcribeStatusLabel = status;
    self.transcribeProgressBar = bar;

    [parent beginSheet:sheet completionHandler:^(NSModalResponse) {}];
}

- (void)dismissTranscribeProgressSheet {
    if (!self.transcribeProgressSheet) return;
    NSWindow* parent = self.mainWindow;
    [self.transcribeProgressBar stopAnimation:nil];
    if (parent) {
        [parent endSheet:self.transcribeProgressSheet returnCode:NSModalResponseOK];
    }
    self.transcribeProgressSheet = nil;
    self.transcribeStatusLabel = nil;
    self.transcribeProgressBar = nil;
}

- (void)cancelTranscribe:(id)sender {
    (void)sender;
    [self.basicPitch cancel];
}

#pragma mark - BasicPitchTranscriberDelegate

- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t progress:(double)frac {
    (void)t;
    if (!self.transcribeProgressBar) return;
    if (frac > 0.0) {
        self.transcribeProgressBar.indeterminate = NO;
        self.transcribeProgressBar.doubleValue = frac;
    }
}

- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t stage:(NSString*)message {
    (void)t;
    if (self.transcribeStatusLabel && message.length) {
        self.transcribeStatusLabel.stringValue = message;
    }
}

- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t
            didFinishWithMIDI:(NSString*)midiPath
                    sourceTag:(NSString*)tag {
    (void)t;
    [self dismissTranscribeProgressSheet];
    self.transcribePendingOutput = nil;

    // transcribe.py drops a sibling notes.json with structured note events.
    // Load it (best-effort) and overlay the notes on the matching stem lane.
    if (tag.length > 0) {
        NSString* notesPath = [[midiPath stringByDeletingPathExtension]
                               stringByAppendingString:@".notes.json"];
        if ([NSFileManager.defaultManager fileExistsAtPath:notesPath]) {
            NSData* data = [NSData dataWithContentsOfFile:notesPath];
            NSError* err = nil;
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data
                                                            options:0
                                                              error:&err]
                          : nil;
            if ([obj isKindOfClass:NSArray.class]) {
                [self.mainWindow.waveformView setMIDINotes:(NSArray*)obj
                                              forStemName:tag];
            }
        }
    }

    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"%@ transcribed", [tag isEqualToString:@"__full_track__"] ? @"Track" : (tag.length ? tag : @"Stem")];
    a.informativeText = [NSString stringWithFormat:@"MIDI saved to:\n%@", midiPath];
    a.alertStyle = NSAlertStyleInformational;
    [a addButtonWithTitle:@"Show in Finder"];
    [a addButtonWithTitle:@"OK"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace]
            selectFile:midiPath inFileViewerRootedAtPath:@""];
    }
}

- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t didFailWithError:(NSString*)message {
    (void)t;
    [self dismissTranscribeProgressSheet];
    self.transcribePendingOutput = nil;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"Transcription failed";
    a.informativeText = message.length ? message : @"Unknown error.";
    a.alertStyle = NSAlertStyleWarning;
    [a runModal];
}

#pragma mark - Chords

- (void)seekEngineToSeconds:(double)seconds {
    if (_engine) _engine->seek(seconds);
}

// Canonical setter: keep the array sorted by start, push to the lane, refresh
// the readout. All chord mutations funnel through here.
- (void)setChords:(NSArray<NSDictionary*>*)chords {
    NSArray* sorted = [(chords ?: @[]) sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            double sa = [a[@"start"] doubleValue], sb = [b[@"start"] doubleValue];
            if (sa < sb) return NSOrderedAscending;
            if (sa > sb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    _chords = [sorted copy];
    [self.mainWindow.waveformView setChords:_chords];
    [self updateChordReadout];
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
}

- (void)updateChordReadout {
    NSTextField* badge = self.mainWindow.chordBadge;
    if (!badge) return;
    if (self.chords.count == 0) { badge.hidden = YES; return; }
    double t = _engine ? _engine->currentTime() : 0.0;
    NSString* now = nil;
    NSString* next = nil;
    for (NSUInteger i = 0; i < self.chords.count; i++) {
        NSDictionary* c = self.chords[i];
        double s = [c[@"start"] doubleValue], e = [c[@"end"] doubleValue];
        if (t >= s && t < e) {
            now = c[@"label"];
            for (NSUInteger j = i + 1; j < self.chords.count; j++) {
                NSString* l = self.chords[j][@"label"];
                if (![l isEqualToString:@"N"]) { next = l; break; }
            }
            break;
        }
        if (s > t && !next) {  // before the first chord: preview what's coming
            if (![c[@"label"] isEqualToString:@"N"]) next = c[@"label"];
        }
    }
    if ([now isEqualToString:@"N"]) now = @"—";
    NSString* text = next.length
        ? [NSString stringWithFormat:@"%@  →  %@", now ?: @"—", next]
        : [NSString stringWithFormat:@"%@", now ?: @"—"];
    badge.stringValue = text;
    badge.hidden = NO;
}

- (void)detectChordsClicked:(id)sender {
    (void)sender;
    if (!self.currentFilePath.length || !_engine || _engine->duration() <= 0.0) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"No audio loaded";
        a.informativeText = @"Open a song first, then detect its chords.";
        [a runModal];
        return;
    }
    if (!self.chordRecognizer.isHelperAvailable) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"Chord helper not found";
        a.informativeText = @"The bundled chord-helper or its Python runtime is missing.";
        [a runModal];
        return;
    }
    if (self.chordRecognizer.isRunning) return;

    [self showChordProgressSheet];
    [self.chordRecognizer recognizeFile:self.currentFilePath];
}

- (void)clearChordsClicked:(id)sender {
    (void)sender;
    [self setChords:@[]];
}

- (void)showChordProgressSheet {
    NSWindow* parent = self.mainWindow;
    if (!parent) return;
    NSRect frame = NSMakeRect(0, 0, 420, 120);
    NSWindow* sheet = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    sheet.title = @"Detecting chords…";
    NSView* content = sheet.contentView;

    NSTextField* status = [NSTextField labelWithString:@"Loading audio…"];
    status.frame = NSMakeRect(20, 70, 380, 20);
    status.font = [NSFont systemFontOfSize:12];
    [content addSubview:status];

    NSProgressIndicator* bar = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(20, 44, 380, 16)];
    bar.style = NSProgressIndicatorStyleBar;
    bar.indeterminate = YES;
    bar.minValue = 0.0;
    bar.maxValue = 1.0;
    [bar startAnimation:nil];
    [content addSubview:bar];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel"
                                          target:self
                                          action:@selector(cancelChordDetect:)];
    cancel.frame = NSMakeRect(330, 10, 70, 24);
    cancel.bezelStyle = NSBezelStyleRounded;
    [content addSubview:cancel];

    self.chordProgressSheet = sheet;
    self.chordStatusLabel = status;
    self.chordProgressBar = bar;
    [parent beginSheet:sheet completionHandler:^(NSModalResponse) {}];
}

- (void)dismissChordProgressSheet {
    if (!self.chordProgressSheet) return;
    NSWindow* parent = self.mainWindow;
    [self.chordProgressBar stopAnimation:nil];
    if (parent) [parent endSheet:self.chordProgressSheet returnCode:NSModalResponseOK];
    self.chordProgressSheet = nil;
    self.chordStatusLabel = nil;
    self.chordProgressBar = nil;
}

- (void)cancelChordDetect:(id)sender {
    (void)sender;
    [self.chordRecognizer cancel];
}

#pragma mark - ChordRecognizerDelegate

- (void)chordRecognizer:(ChordRecognizer*)r progress:(double)frac {
    (void)r;
    if (!self.chordProgressBar) return;
    if (frac > 0.0) {
        self.chordProgressBar.indeterminate = NO;
        self.chordProgressBar.doubleValue = frac;
    }
}

- (void)chordRecognizer:(ChordRecognizer*)r stage:(NSString*)message {
    (void)r;
    if (self.chordStatusLabel && message.length) {
        self.chordStatusLabel.stringValue = message;
    }
}

- (void)chordRecognizer:(ChordRecognizer*)r
   didFinishWithChords:(NSArray<NSDictionary*>*)chords
                 tempo:(double)tempo {
    (void)r; (void)tempo;
    [self dismissChordProgressSheet];
    [self setChords:chords];
    if (chords.count == 0) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"No chords detected";
        a.informativeText = @"The analyzer didn't find a stable progression.";
        [a runModal];
    }
}

- (void)chordRecognizer:(ChordRecognizer*)r didFailWithError:(NSString*)message {
    (void)r;
    [self dismissChordProgressSheet];
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"Chord detection failed";
    a.informativeText = message.length ? message : @"Unknown error.";
    a.alertStyle = NSAlertStyleWarning;
    [a runModal];
}

#pragma mark - Manual chord editing

// Modal text prompt for a chord label. Returns the trimmed string, or nil if
// the user cancelled.
- (NSString*)promptChordLabel:(NSString*)initial title:(NSString*)title {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = @"Enter a chord label (e.g. Am, G7, Cmaj7). Use N for no chord.";
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Cancel"];
    NSTextField* tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    tf.stringValue = initial ?: @"";
    a.accessoryView = tf;
    [a.window setInitialFirstResponder:tf];
    NSModalResponse resp = [a runModal];
    if (resp != NSAlertFirstButtonReturn) return nil;
    return [tf.stringValue stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)editChordAtIndex:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.chords.count) return;
    NSDictionary* c = self.chords[index];
    NSString* lbl = [self promptChordLabel:c[@"label"] title:@"Edit Chord"];
    if (!lbl) return;
    NSMutableArray* m = [self.chords mutableCopy];
    if (lbl.length == 0) {
        [m removeObjectAtIndex:index];
    } else {
        m[index] = @{ @"start": c[@"start"], @"end": c[@"end"], @"label": lbl };
    }
    [self setChords:m];
}

- (void)deleteChordAtIndex:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.chords.count) return;
    NSMutableArray* m = [self.chords mutableCopy];
    [m removeObjectAtIndex:index];
    [self setChords:m];
}

- (void)addChordAtTime:(double)seconds {
    if (!_engine || _engine->duration() <= 0.0) return;
    double dur = _engine->duration();
    double t = std::clamp(seconds, 0.0, dur);
    NSString* lbl = [self promptChordLabel:@"" title:@"Add Chord"];
    if (!lbl.length) return;

    NSMutableArray* m = [self.chords mutableCopy];
    // If t lands inside an existing segment, split it: shorten the existing
    // one to end at t and insert the new chord from t to its old end.
    for (NSUInteger i = 0; i < m.count; i++) {
        NSDictionary* c = m[i];
        double s = [c[@"start"] doubleValue], e = [c[@"end"] doubleValue];
        if (t > s && t < e) {
            m[i] = @{ @"start": @(s), @"end": @(t), @"label": c[@"label"] };
            [m addObject:@{ @"start": @(t), @"end": @(e), @"label": lbl }];
            [self setChords:m];
            return;
        }
    }
    // Otherwise insert a fresh segment running until the next chord (or +2 s).
    double end = std::min(dur, t + 2.0);
    for (NSDictionary* c in m) {
        double s = [c[@"start"] doubleValue];
        if (s > t) { end = std::min(end, s); break; }
    }
    [m addObject:@{ @"start": @(t), @"end": @(end), @"label": lbl }];
    [self setChords:m];
}

- (void)loadPath:(NSString*)path {
    if (!path.length) return;
    if (self.currentFilePath) [self saveStateForPath:self.currentFilePath];
    if (_engine->load([path UTF8String])) {
        self.currentFilePath = path;
        [self addToRecentFiles:path];
        _bookmarks.clear();
        [self pushBookmarksToView];
        _engine->clearLoop();
        _smartLoop = SmartLoopState{};
        [self updateSmartLoopButtonTint];
        _isolate = IsolateState{};
        [self applyIsolateToEngine];
        self.currentStemNames = @[];
        self.currentStemPaths = @[];
        [self.mainWindow setTitle:
            [NSString stringWithFormat:@"OpenScribe Native — %@", path.lastPathComponent]];
        [self.mainWindow.waveformView setStemNames:@[]];
        [self.mainWindow.waveformView clearAllMIDINotes];
        [self setChords:@[]];   // restoreStateForPath re-populates if saved
        [self.mainWindow.waveformView reloadFromEngine];
        [self rebuildStemSidebar];
        self.mainWindow.dropHintContainer.hidden = YES;
        [self restoreStateForPath:path];
        _engine->play();
    } else {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Failed to load audio file";
        alert.informativeText = path;
        [alert runModal];
    }
}

@end
