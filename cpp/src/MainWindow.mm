#import "MainWindow.h"
#import "WaveformView.h"
#import <QuartzCore/QuartzCore.h>

// Container for per-stem mixer rows. Lays its subviews into N equal-height
// rows so each row aligns with its waveform lane on the right.
@interface StemMixerSidebar : NSView
@end

@implementation StemMixerSidebar
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    (void)oldSize;
    NSArray<NSView*>* rows = self.subviews;
    NSInteger n = (NSInteger)rows.count;
    if (n == 0) return;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    CGFloat rowH = H / (CGFloat)n;
    for (NSInteger i = 0; i < n; i++) {
        rows[i].frame = NSMakeRect(0, (CGFloat)i * rowH, W, rowH);
    }
}
@end

@interface MainWindow ()
@property (nonatomic, strong, readwrite) WaveformView* waveformView;
@property (nonatomic, strong, readwrite) NSView* stemSidebar;
@property (nonatomic, strong, readwrite) NSTextField* timeLabel;
@property (nonatomic, strong, readwrite) NSSlider* speedSlider;
@property (nonatomic, strong, readwrite) NSTextField* speedLabel;
@property (nonatomic, strong, readwrite) NSSlider* pitchSlider;
@property (nonatomic, strong, readwrite) NSTextField* pitchLabel;
@property (nonatomic, strong, readwrite) NSSlider* volumeSlider;
@property (nonatomic, strong, readwrite) NSTextField* volumeLabel;
@property (nonatomic, strong, readwrite) NSButton* speedResetButton;
@property (nonatomic, strong, readwrite) NSButton* pitchResetButton;
@property (nonatomic, strong, readwrite) NSButton* volumeResetButton;
@property (nonatomic, strong, readwrite) NSView* dropHintContainer;
@property (nonatomic, strong, readwrite) NSButton* startButton;
@property (nonatomic, strong, readwrite) NSButton* skipBackButton;
@property (nonatomic, strong, readwrite) NSButton* playPauseButton;
@property (nonatomic, strong, readwrite) NSButton* skipForwardButton;
@property (nonatomic, strong, readwrite) NSTextField* loopBadge;
@property (nonatomic, strong, readwrite) NSButton* helpButton;
@property (nonatomic, strong, readwrite) NSButton* smartLoopButton;
@property (nonatomic, strong, readwrite) NSButton* isolateButton;
@end

@implementation MainWindow

static NSTextField* makeLabel(NSRect frame, NSString* text, NSTextAlignment align) {
    NSTextField* tf = [[NSTextField alloc] initWithFrame:frame];
    tf.bezeled = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.drawsBackground = NO;
    tf.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    tf.textColor = [NSColor colorWithWhite:0.60 alpha:1.0];
    tf.alignment = align;
    tf.stringValue = text;
    return tf;
}

static NSTextField* makeMonoLabel(NSRect frame, NSString* text, NSTextAlignment align) {
    NSTextField* tf = makeLabel(frame, text, align);
    tf.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    tf.textColor = [NSColor colorWithWhite:0.82 alpha:1.0];
    return tf;
}

// Apply tracked-caps treatment to a label's existing string. Logic-style
// section headings use ~1.5pt kerning between letters for that "control
// surface" look.
static void applyTrackedCaps(NSTextField* tf, CGFloat kern) {
    NSDictionary* attrs = @{
        NSFontAttributeName: tf.font,
        NSForegroundColorAttributeName: tf.textColor,
        NSKernAttributeName: @(kern),
    };
    tf.attributedStringValue =
        [[NSAttributedString alloc] initWithString:tf.stringValue attributes:attrs];
}

static NSButton* makeResetButton(NSRect frame) {
    NSButton* b = [[NSButton alloc] initWithFrame:frame];
    NSImage* img = [NSImage imageWithSystemSymbolName:@"arrow.counterclockwise"
                                accessibilityDescription:@"Reset"];
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:11
                                                         weight:NSFontWeightRegular];
    img = [img imageWithSymbolConfiguration:cfg];
    b.image = img;
    b.imagePosition = NSImageOnly;
    b.bordered = NO;
    b.contentTintColor = [NSColor colorWithWhite:0.78 alpha:1.0];
    b.toolTip = @"Reset";
    return b;
}

static NSButton* makeIconButton(NSRect frame, NSString* symbol, CGFloat pointSize) {
    NSButton* b = [[NSButton alloc] initWithFrame:frame];
    NSImage* img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                         weight:NSFontWeightRegular];
    img = [img imageWithSymbolConfiguration:cfg];
    b.image = img;
    b.imagePosition = NSImageOnly;
    b.bordered = NO;
    b.contentTintColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    b.bezelStyle = NSBezelStyleRegularSquare;
    return b;
}

- (instancetype)initWithEngine:(AudioEngine*)engine {
    NSRect frame = NSMakeRect(0, 0, 960, 620);
    NSUInteger style = NSWindowStyleMaskTitled
                     | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable
                     | NSWindowStyleMaskResizable;
    self = [super initWithContentRect:frame
                            styleMask:style
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) return nil;

    [self setTitle:@"OpenScribe Native"];
    [self center];
    self.releasedWhenClosed = NO;
    self.contentView.wantsLayer = YES;
    // Cooler graphite — slight bluish cast reads as "pro audio app" vs.
    // neutral gray.
    self.contentView.layer.backgroundColor =
        [NSColor colorWithRed:0.085 green:0.090 blue:0.098 alpha:1.0].CGColor;

    NSRect bounds = self.contentView.bounds;
    CGFloat margin = 20;
    CGFloat sliderRowH = 22;
    CGFloat transportRowH = 40;
    CGFloat gap = 8;
    CGFloat innerGap = 6;
    CGFloat groupGap = 18;
    CGFloat labelW = 56;
    CGFloat valueW = 56;
    CGFloat resetW = 22;

    CGFloat sliderRowY_ = margin;
    CGFloat panelTop = sliderRowY_ + sliderRowH + gap + 4 + transportRowH + gap;

    // Bottom panel backdrop — Logic-style control-surface gradient, subtle
    // (~4% delta) so it reads as a panel without feeling skeuomorphic. Use
    // layer-backed mode + gradient sublayer (NOT layer-hosting): hosting
    // mode requires manual frame management on every resize and silently
    // breaks the surrounding view-hierarchy layout.
    NSView* bottomPanel = [[NSView alloc] initWithFrame:
        NSMakeRect(0, 0, bounds.size.width, panelTop)];
    bottomPanel.wantsLayer = YES;
    CAGradientLayer* panelGradient = [CAGradientLayer layer];
    panelGradient.colors = @[
        (__bridge id)[NSColor colorWithRed:0.155 green:0.158 blue:0.170 alpha:1.0].CGColor,
        (__bridge id)[NSColor colorWithRed:0.115 green:0.118 blue:0.128 alpha:1.0].CGColor,
    ];
    panelGradient.frame = bottomPanel.bounds;
    panelGradient.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [bottomPanel.layer addSublayer:panelGradient];
    bottomPanel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.contentView addSubview:bottomPanel];

    // Engraved divider: 1px shadow line at the seam plus a 1px highlight just
    // above it. Sells the "control panel sits below the timeline" feel.
    NSView* dividerShadow = [[NSView alloc] initWithFrame:
        NSMakeRect(0, panelTop, bounds.size.width, 1)];
    dividerShadow.wantsLayer = YES;
    dividerShadow.layer.backgroundColor =
        [NSColor colorWithRed:0.04 green:0.04 blue:0.05 alpha:1.0].CGColor;
    dividerShadow.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.contentView addSubview:dividerShadow];

    NSView* dividerHighlight = [[NSView alloc] initWithFrame:
        NSMakeRect(0, panelTop - 1, bounds.size.width, 1)];
    dividerHighlight.wantsLayer = YES;
    dividerHighlight.layer.backgroundColor =
        [NSColor colorWithWhite:1.0 alpha:0.06].CGColor;
    dividerHighlight.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.contentView addSubview:dividerHighlight];

    // Single-row slider layout: VOLUME · PITCH · SPEED side-by-side.
    CGFloat contentW = bounds.size.width - 2 * margin;
    CGFloat groupW = (contentW - 2 * groupGap) / 3.0;
    CGFloat sliderW = groupW - labelW - valueW - resetW - 3 * innerGap;

    auto layoutGroup =
        ^(CGFloat groupX, NSString* labelText, NSSlider* slider,
          NSTextField* valueLabel, NSButton* reset) {
        NSTextField* lbl = makeLabel(
            NSMakeRect(groupX, sliderRowY_, labelW, sliderRowH),
            labelText, NSTextAlignmentLeft);
        applyTrackedCaps(lbl, 1.6);
        [self.contentView addSubview:lbl];

        slider.frame = NSMakeRect(groupX + labelW + innerGap,
                                  sliderRowY_, sliderW, sliderRowH);
        slider.continuous = YES;
        [self.contentView addSubview:slider];

        valueLabel.frame = NSMakeRect(
            groupX + labelW + innerGap + sliderW + innerGap,
            sliderRowY_, valueW, sliderRowH);
        [self.contentView addSubview:valueLabel];

        reset.frame = NSMakeRect(groupX + groupW - resetW,
                                 sliderRowY_, resetW, sliderRowH);
        [self.contentView addSubview:reset];
    };

    // VOLUME (leftmost)
    self.volumeSlider = [[NSSlider alloc] init];
    self.volumeSlider.minValue = 0.0;
    self.volumeSlider.maxValue = 1.5;
    self.volumeSlider.doubleValue = 1.0;
    self.volumeLabel = makeMonoLabel(NSZeroRect, @"100%", NSTextAlignmentRight);
    self.volumeResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin, @"VOLUME", self.volumeSlider,
                self.volumeLabel, self.volumeResetButton);

    // PITCH (center)
    self.pitchSlider = [[NSSlider alloc] init];
    self.pitchSlider.minValue = -1200.0;
    self.pitchSlider.maxValue =  1200.0;
    self.pitchSlider.doubleValue = 0.0;
    self.pitchLabel = makeMonoLabel(NSZeroRect, @"+0.00 st", NSTextAlignmentRight);
    self.pitchResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin + groupW + groupGap, @"PITCH", self.pitchSlider,
                self.pitchLabel, self.pitchResetButton);

    // SPEED (right)
    self.speedSlider = [[NSSlider alloc] init];
    self.speedSlider.minValue = 0.25;
    self.speedSlider.maxValue = 2.0;
    self.speedSlider.doubleValue = 1.0;
    self.speedLabel = makeMonoLabel(NSZeroRect, @"1.00x", NSTextAlignmentRight);
    self.speedResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin + 2 * (groupW + groupGap), @"SPEED", self.speedSlider,
                self.speedLabel, self.speedResetButton);

    // TRANSPORT row, sits above the sliders
    CGFloat transportY = sliderRowY_ + sliderRowH + gap + 4;
    CGFloat btnW = 36;
    CGFloat btnGap = 12;
    CGFloat playW = 44;
    CGFloat transportGroupW = btnW * 3 + playW + btnGap * 3;
    CGFloat groupX = (bounds.size.width - transportGroupW) / 2.0;

    self.startButton = makeIconButton(
        NSMakeRect(groupX, transportY, btnW, transportRowH), @"backward.end.fill", 16);
    self.startButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.startButton];

    self.skipBackButton = makeIconButton(
        NSMakeRect(groupX + btnW + btnGap, transportY, btnW, transportRowH),
        @"gobackward.5", 18);
    self.skipBackButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.skipBackButton];

    self.playPauseButton = makeIconButton(
        NSMakeRect(groupX + 2 * (btnW + btnGap), transportY, playW, transportRowH),
        @"play.fill", 24);
    self.playPauseButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.playPauseButton];

    self.skipForwardButton = makeIconButton(
        NSMakeRect(groupX + 2 * (btnW + btnGap) + playW + btnGap, transportY, btnW, transportRowH),
        @"goforward.5", 18);
    self.skipForwardButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.skipForwardButton];

    // LCD-style time display: dark recessed panel hosting a centered
    // monospaced readout. Logic Pro's transport readout is the most
    // recognizable visual cue, and here it anchors the right side of the
    // transport row.
    CGFloat timeW = 240;
    CGFloat lcdH = 32;
    NSView* lcdPanel = [[NSView alloc] initWithFrame:
        NSMakeRect(bounds.size.width - margin - timeW,
                   transportY + (transportRowH - lcdH) / 2,
                   timeW, lcdH)];
    lcdPanel.wantsLayer = YES;
    lcdPanel.layer.backgroundColor =
        [NSColor colorWithRed:0.045 green:0.048 blue:0.055 alpha:1.0].CGColor;
    lcdPanel.layer.cornerRadius = 4;
    lcdPanel.layer.borderWidth = 1.0;
    lcdPanel.layer.borderColor =
        [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
    lcdPanel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:lcdPanel];

    self.timeLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(8, (lcdH - 22) / 2, timeW - 16, 22)];
    self.timeLabel.bezeled = NO;
    self.timeLabel.editable = NO;
    self.timeLabel.selectable = NO;
    self.timeLabel.drawsBackground = NO;
    self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightMedium];
    // Slight cool cast — reads as a backlit display without leaning retro.
    self.timeLabel.textColor =
        [NSColor colorWithRed:0.88 green:0.93 blue:0.98 alpha:1.0];
    self.timeLabel.alignment = NSTextAlignmentCenter;
    self.timeLabel.stringValue = @"00:00.00 / 00:00.00";
    self.timeLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [lcdPanel addSubview:self.timeLabel];

    // Help (?) button at top-left of transport row.
    CGFloat iconSize = 24;
    self.helpButton = makeIconButton(
        NSMakeRect(margin, transportY + (transportRowH - iconSize)/2,
                   iconSize, iconSize), @"questionmark.circle", 16);
    self.helpButton.contentTintColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    self.helpButton.toolTip = @"Keyboard shortcuts";
    self.helpButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.helpButton];

    // Smart loop (wand) button — to the right of help.
    self.smartLoopButton = makeIconButton(
        NSMakeRect(margin + iconSize + 8,
                   transportY + (transportRowH - iconSize)/2,
                   iconSize, iconSize),
        @"wand.and.stars", 15);
    self.smartLoopButton.contentTintColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    self.smartLoopButton.toolTip = @"Smart loop — gradually increase speed across reps";
    self.smartLoopButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.smartLoopButton];

    // Isolate (filter) button — to the right of smart loop.
    self.isolateButton = makeIconButton(
        NSMakeRect(margin + 2 * (iconSize + 8),
                   transportY + (transportRowH - iconSize)/2,
                   iconSize, iconSize),
        @"slider.horizontal.3", 15);
    self.isolateButton.contentTintColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    self.isolateButton.toolTip = @"Isolate — vocal cancel & bass focus";
    self.isolateButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.isolateButton];

    // Waveform fills everything above the transport row.
    CGFloat waveBottom = transportY + transportRowH + gap;
    CGFloat waveTotalW = bounds.size.width - 2 * margin;
    CGFloat waveH = bounds.size.height - margin - waveBottom;

    // Per-stem mixer strip on the left, anchored to the waveform's full
    // height so its rows can line up with each lane. Hidden (zero width)
    // until the app delegate populates it after a stem load.
    self.stemSidebar = [[StemMixerSidebar alloc] initWithFrame:
        NSMakeRect(margin, waveBottom, 0, waveH)];
    self.stemSidebar.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    self.stemSidebar.hidden = YES;
    [self.contentView addSubview:self.stemSidebar];

    NSRect waveFrame = NSMakeRect(margin, waveBottom, waveTotalW, waveH);
    self.waveformView = [[WaveformView alloc] initWithFrame:waveFrame engine:engine];
    self.waveformView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.waveformView.layer.cornerRadius = 6;
    self.waveformView.layer.masksToBounds = YES;
    self.waveformView.layer.borderWidth = 1.0;
    self.waveformView.layer.borderColor =
        [NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.55].CGColor;
    [self.contentView addSubview:self.waveformView];

    // Loop info badge — small pill anchored to bottom-left of waveform.
    CGFloat badgeW = 240, badgeH = 22;
    self.loopBadge = [[NSTextField alloc] initWithFrame:
        NSMakeRect(waveFrame.origin.x + 10,
                   waveFrame.origin.y + 10,
                   badgeW, badgeH)];
    self.loopBadge.bezeled = NO;
    self.loopBadge.editable = NO;
    self.loopBadge.selectable = NO;
    self.loopBadge.drawsBackground = YES;
    self.loopBadge.backgroundColor =
        [NSColor colorWithRed:1.0 green:0.85 blue:0.20 alpha:0.18];
    self.loopBadge.font = [NSFont monospacedDigitSystemFontOfSize:11
                                                            weight:NSFontWeightMedium];
    self.loopBadge.textColor = [NSColor colorWithRed:1.0 green:0.92 blue:0.50 alpha:1.0];
    self.loopBadge.alignment = NSTextAlignmentCenter;
    self.loopBadge.stringValue = @"";
    self.loopBadge.hidden = YES;
    self.loopBadge.wantsLayer = YES;
    self.loopBadge.layer.cornerRadius = 4;
    self.loopBadge.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.loopBadge];

    // Empty-state overlay: big icon + title + subtitle, centered on waveform.
    CGFloat hintW = 320;
    CGFloat hintH = 140;
    NSRect hintFrame = NSMakeRect(
        waveFrame.origin.x + (waveFrame.size.width - hintW) / 2,
        waveFrame.origin.y + (waveFrame.size.height - hintH) / 2,
        hintW, hintH);
    self.dropHintContainer = [[NSView alloc] initWithFrame:hintFrame];
    self.dropHintContainer.autoresizingMask =
        NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

    NSImage* icon = [NSImage imageWithSystemSymbolName:@"waveform"
                                accessibilityDescription:nil];
    NSImageSymbolConfiguration* iconCfg =
        [NSImageSymbolConfiguration configurationWithPointSize:64
                                                         weight:NSFontWeightUltraLight];
    icon = [icon imageWithSymbolConfiguration:iconCfg];
    NSImageView* iconView = [[NSImageView alloc] initWithFrame:
        NSMakeRect((hintW - 80) / 2, hintH - 80, 80, 80)];
    iconView.image = icon;
    iconView.contentTintColor = [NSColor colorWithWhite:0.40 alpha:1.0];
    [self.dropHintContainer addSubview:iconView];

    NSTextField* title = makeLabel(NSMakeRect(0, 30, hintW, 24),
                                   @"No audio file loaded", NSTextAlignmentCenter);
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    title.textColor = [NSColor colorWithWhite:0.70 alpha:1.0];
    [self.dropHintContainer addSubview:title];

    NSTextField* subtitle = makeLabel(NSMakeRect(0, 8, hintW, 20),
                                      @"Drag a file here  ·  ⌘O to open",
                                      NSTextAlignmentCenter);
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor colorWithWhite:0.45 alpha:1.0];
    [self.dropHintContainer addSubview:subtitle];

    [self.contentView addSubview:self.dropHintContainer];

    return self;
}

- (void)noResponderFor:(SEL)eventSelector {
    // Swallow the system beep for unhandled key events. Our local key monitor
    // already routes everything we care about — the rest should be silent.
    if (eventSelector == @selector(keyDown:)) return;
    [super noResponderFor:eventSelector];
}

- (void)setStemSidebarVisible:(BOOL)visible {
    static const CGFloat kSidebarW = 220.0;
    static const CGFloat kSidebarGap = 6.0;
    CGFloat targetW = visible ? kSidebarW : 0.0;
    CGFloat curW = self.stemSidebar.frame.size.width;
    if (fabs(curW - targetW) < 0.5 && self.stemSidebar.hidden != visible) {
        self.stemSidebar.hidden = !visible;
        return;
    }
    if (fabs(curW - targetW) < 0.5) return;

    NSRect sf = self.stemSidebar.frame;
    NSRect wf = self.waveformView.frame;
    CGFloat shift = visible ? (kSidebarW + kSidebarGap) : -(curW + kSidebarGap);

    sf.size.width = targetW;
    self.stemSidebar.frame = sf;
    self.stemSidebar.hidden = !visible;

    wf.origin.x += shift;
    wf.size.width -= shift;
    self.waveformView.frame = wf;

    [self.stemSidebar resizeSubviewsWithOldSize:sf.size];
}

- (void)updatePlayPauseButton:(BOOL)playing {
    NSString* sym = playing ? @"pause.fill" : @"play.fill";
    NSImage* img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightRegular];
    self.playPauseButton.image = [img imageWithSymbolConfiguration:cfg];
}

@end
