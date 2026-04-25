#import "AppDelegate.h"
#import "MainWindow.h"
#import "AudioEngine.h"
#import "WaveformView.h"

#include <algorithm>
#include <cmath>
#include <memory>

@interface AppDelegate () {
    std::unique_ptr<AudioEngine> _engine;
    id _keyMonitor;
    BOOL _torndown;
}
@property (nonatomic, strong) MainWindow* mainWindow;
@property (nonatomic, strong) NSTimer* timeTimer;
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
    return [NSString stringWithFormat:@"%02d:%02d", m, s];
}

- (void)updateTimeLabel {
    if (!_engine) return;
    NSString* now = [self formatSeconds:_engine->currentTime()];
    NSString* dur = [self formatSeconds:_engine->duration()];
    self.mainWindow.timeLabel.stringValue =
        [NSString stringWithFormat:@"%@ / %@", now, dur];
    [self.mainWindow updatePlayPauseButton:_engine->isPlaying()];
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
    [appMenu addItemWithTitle:@"About OpenScribe Native"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
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
    [fileItem setSubmenu:fileMenu];

    [NSApp setMainMenu:menubar];
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
                case 36:  [s seekToLoopOrStart];  return nil;           // Return
                case 76:  [s seekToLoopOrStart];  return nil;           // Numpad Enter
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
    panel.allowedFileTypes = @[@"wav", @"mp3", @"m4a", @"flac", @"aif", @"aiff", @"caf"];

    if ([panel runModal] != NSModalResponseOK) return;
    NSURL* url = panel.URLs.firstObject;
    if (!url) return;
    [self loadPath:url.path];
}

- (void)loadPath:(NSString*)path {
    if (!path.length) return;
    if (_engine->load([path UTF8String])) {
        [self.mainWindow setTitle:
            [NSString stringWithFormat:@"OpenScribe Native — %@", path.lastPathComponent]];
        [self.mainWindow.waveformView reloadFromEngine];
        self.mainWindow.dropHintContainer.hidden = YES;
        _engine->play();
    } else {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Failed to load audio file";
        alert.informativeText = path;
        [alert runModal];
    }
}

@end
