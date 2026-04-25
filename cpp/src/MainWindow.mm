#import "MainWindow.h"
#import "WaveformView.h"

@interface MainWindow ()
@property (nonatomic, strong, readwrite) WaveformView* waveformView;
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
@end

@implementation MainWindow

static NSTextField* makeLabel(NSRect frame, NSString* text, NSTextAlignment align) {
    NSTextField* tf = [[NSTextField alloc] initWithFrame:frame];
    tf.bezeled = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.drawsBackground = NO;
    tf.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    tf.textColor = [NSColor colorWithWhite:0.72 alpha:1.0];
    tf.alignment = align;
    tf.stringValue = text;
    return tf;
}

static NSTextField* makeMonoLabel(NSRect frame, NSString* text, NSTextAlignment align) {
    NSTextField* tf = makeLabel(frame, text, align);
    tf.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    tf.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    return tf;
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
    self.contentView.layer.backgroundColor =
        [NSColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1.0].CGColor;

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

    // Bottom panel backdrop — distinguishes controls area from the waveform.
    NSView* bottomPanel = [[NSView alloc] initWithFrame:
        NSMakeRect(0, 0, bounds.size.width, panelTop)];
    bottomPanel.wantsLayer = YES;
    bottomPanel.layer.backgroundColor =
        [NSColor colorWithRed:0.135 green:0.135 blue:0.145 alpha:1.0].CGColor;
    bottomPanel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.contentView addSubview:bottomPanel];

    // 1pt divider between waveform and panel.
    NSView* divider = [[NSView alloc] initWithFrame:
        NSMakeRect(0, panelTop, bounds.size.width, 1)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = [NSColor colorWithWhite:0.22 alpha:1.0].CGColor;
    divider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.contentView addSubview:divider];

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

    // Big time label, right of transport.
    CGFloat timeW = 240;
    self.timeLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(bounds.size.width - margin - timeW, transportY + (transportRowH - 26) / 2,
                   timeW, 26)];
    self.timeLabel.bezeled = NO;
    self.timeLabel.editable = NO;
    self.timeLabel.selectable = NO;
    self.timeLabel.drawsBackground = NO;
    self.timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:18 weight:NSFontWeightLight];
    self.timeLabel.textColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    self.timeLabel.alignment = NSTextAlignmentRight;
    self.timeLabel.stringValue = @"00:00.00 / 00:00.00";
    self.timeLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.timeLabel];

    // Help (?) button at top-right of transport row.
    CGFloat helpSize = 24;
    self.helpButton = makeIconButton(
        NSMakeRect(margin, transportY + (transportRowH - helpSize)/2,
                   helpSize, helpSize), @"questionmark.circle", 16);
    self.helpButton.contentTintColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    self.helpButton.toolTip = @"Keyboard shortcuts";
    self.helpButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.helpButton];

    // Waveform fills everything above the transport row.
    CGFloat waveBottom = transportY + transportRowH + gap;
    NSRect waveFrame = NSMakeRect(margin,
                                  waveBottom,
                                  bounds.size.width - 2 * margin,
                                  bounds.size.height - margin - waveBottom);
    self.waveformView = [[WaveformView alloc] initWithFrame:waveFrame engine:engine];
    self.waveformView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.waveformView.layer.cornerRadius = 6;
    self.waveformView.layer.masksToBounds = YES;
    self.waveformView.layer.borderWidth = 1.0;
    self.waveformView.layer.borderColor =
        [NSColor colorWithWhite:0.22 alpha:1.0].CGColor;
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

- (void)updatePlayPauseButton:(BOOL)playing {
    NSString* sym = playing ? @"pause.fill" : @"play.fill";
    NSImage* img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightRegular];
    self.playPauseButton.image = [img imageWithSymbolConfiguration:cfg];
}

@end
