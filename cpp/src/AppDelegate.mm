#import "AppDelegate.h"
#import "MainWindow.h"
#import "AudioEngine.h"
#import "WaveformView.h"

#import <CommonCrypto/CommonCrypto.h>

#include <algorithm>
#include <cmath>
#include <memory>

@interface OSFlippedView : NSView @end
@implementation OSFlippedView - (BOOL)isFlipped { return YES; } @end

@interface AppDelegate () {
    std::unique_ptr<AudioEngine> _engine;
    id _keyMonitor;
    BOOL _torndown;
    std::vector<double> _bookmarks;
    NSTimeInterval _lastBookmarkToggleTime;
}
@property (nonatomic, strong) MainWindow* mainWindow;
@property (nonatomic, strong) NSTimer* timeTimer;
@property (nonatomic, copy) NSString* currentFilePath;
@property (nonatomic, strong) NSMenu* recentSubmenu;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    _engine = std::make_unique<AudioEngine>();

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

    if (_engine->hasLoop()) {
        double sr = _engine->sampleRate();
        double ls = _engine->loopStartFrame() / sr;
        double le = _engine->loopEndFrame() / sr;
        self.mainWindow.loopBadge.stringValue =
            [NSString stringWithFormat:@"  Loop  %@ → %@  ",
             [self formatSeconds:ls], [self formatSeconds:le]];
        self.mainWindow.loopBadge.hidden = NO;
    } else {
        self.mainWindow.loopBadge.hidden = YES;
    }
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
