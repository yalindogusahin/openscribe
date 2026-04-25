#import "AppDelegate.h"
#import "MainWindow.h"
#import "AudioEngine.h"
#import "WaveformView.h"
#import "SettingsWindowController.h"

#import <CommonCrypto/CommonCrypto.h>

#include <algorithm>
#include <cmath>
#include <memory>

@interface OSFlippedView : NSView @end
@implementation OSFlippedView - (BOOL)isFlipped { return YES; } @end

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
}

@interface AppDelegate () {
    std::unique_ptr<AudioEngine> _engine;
    id _keyMonitor;
    BOOL _torndown;
    std::vector<double> _bookmarks;
    NSTimeInterval _lastBookmarkToggleTime;
    SmartLoopState _smartLoop;
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
@end

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
    NSMenuItem* recentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
                                                        action:nil
                                                 keyEquivalent:@""];
    self.recentSubmenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    recentItem.submenu = self.recentSubmenu;
    [fileMenu addItem:recentItem];
    [fileItem setSubmenu:fileMenu];
    [self rebuildRecentMenu];

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

    self.smartLoopStartSlider = [[NSSlider alloc] init];
    self.smartLoopStartSlider.minValue = 0.25;
    self.smartLoopStartSlider.maxValue = 2.0;
    self.smartLoopStartSlider.target = self;
    self.smartLoopStartSlider.action = @selector(smartLoopStartChanged:);
    self.smartLoopStartLabel = [[NSTextField alloc] init];
    addRow(@"Start speed", self.smartLoopStartSlider, self.smartLoopStartLabel);

    self.smartLoopEndSlider = [[NSSlider alloc] init];
    self.smartLoopEndSlider.minValue = 0.25;
    self.smartLoopEndSlider.maxValue = 2.0;
    self.smartLoopEndSlider.target = self;
    self.smartLoopEndSlider.action = @selector(smartLoopEndChanged:);
    self.smartLoopEndLabel = [[NSTextField alloc] init];
    addRow(@"End speed", self.smartLoopEndSlider, self.smartLoopEndLabel);

    self.smartLoopStepSlider = [[NSSlider alloc] init];
    self.smartLoopStepSlider.minValue = 0.05;
    self.smartLoopStepSlider.maxValue = 0.5;
    self.smartLoopStepSlider.target = self;
    self.smartLoopStepSlider.action = @selector(smartLoopStepChanged:);
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

- (void)installKeyMonitor {
    __weak AppDelegate* weakSelf = self;
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent*(NSEvent* event) {
            AppDelegate* s = weakSelf;
            if (!s) return event;

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

- (void)playPauseClicked:(id)sender { [self togglePlayPause]; }
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
        if (std::abs(*it - t) <= kProx) {
            _bookmarks.erase(it);
            [self pushBookmarksToView];
            return;
        }
    }
    _bookmarks.push_back(t);
    std::sort(_bookmarks.begin(), _bookmarks.end());
    [self pushBookmarksToView];
}

- (void)jumpToBookmark:(NSInteger)index {
    if (!_engine) return;
    if (index < 0 || (size_t)index >= _bookmarks.size()) return;
    _engine->seek(_bookmarks[index]);
}

- (void)pushBookmarksToView {
    NSMutableArray<NSNumber*>* arr = [NSMutableArray arrayWithCapacity:_bookmarks.size()];
    for (double t : _bookmarks) [arr addObject:@(t)];
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
    NSMutableArray<NSNumber*>* bm = [NSMutableArray arrayWithCapacity:_bookmarks.size()];
    for (double t : _bookmarks) [bm addObject:@(t)];

    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    d[@"viewStart"] = @(self.mainWindow.waveformView.viewStart);
    d[@"viewEnd"]   = @(self.mainWindow.waveformView.viewEnd);
    d[@"speed"]     = @(_engine->speed());
    d[@"pitch"]     = @(_engine->pitch());
    d[@"volume"]    = @(_engine->volume());
    d[@"lastTime"]  = @(_engine->currentTime());
    d[@"bookmarks"] = bm;
    if (_engine->hasLoop()) {
        d[@"loopStart"] = @(_engine->loopStartFrame() / sr);
        d[@"loopEnd"]   = @(_engine->loopEndFrame() / sr);
    }
    d[@"smartLoopEnabled"]    = @(_smartLoop.enabled);
    d[@"smartLoopStartSpeed"] = @(_smartLoop.startSpeed);
    d[@"smartLoopEndSpeed"]   = @(_smartLoop.endSpeed);
    d[@"smartLoopStepSize"]   = @(_smartLoop.stepSize);
    d[@"smartLoopRepeats"]    = @(_smartLoop.repeatsPerStep);
    [[NSUserDefaults standardUserDefaults] setObject:d
                                              forKey:[self stateKeyForPath:path]];
}

- (void)restoreStateForPath:(NSString*)path {
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
        for (NSNumber* n in bm) {
            if ([n isKindOfClass:[NSNumber class]]) _bookmarks.push_back(n.doubleValue);
        }
        std::sort(_bookmarks.begin(), _bookmarks.end());
        [self pushBookmarksToView];
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
        [self.mainWindow setTitle:
            [NSString stringWithFormat:@"OpenScribe Native — %@", path.lastPathComponent]];
        [self.mainWindow.waveformView reloadFromEngine];
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
