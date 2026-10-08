#import "MainWindow.h"
#import "IRealLibrary.h"
#import "WaveformView.h"
#import <QuartzCore/QuartzCore.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation OSResettableSlider
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) _resetValue = 0.0;
    return self;
}
- (void)mouseDown:(NSEvent*)event {
    if (event.clickCount == 2) {
        self.doubleValue = self.resetValue;
        if (self.target && self.action) {
            [NSApp sendAction:self.action to:self.target from:self];
        }
        return;
    }
    [super mouseDown:event];
}
@end

// Container for per-stem mixer rows. Lays its subviews into N equal-height
// rows so each row aligns with its waveform lane on the right. Also hosts
// the drag-to-reorder gesture: rows call -beginDragForRow:event: from their
// own mouseDown when the click lands on a non-control area.
@interface StemMixerSidebar : NSView <OSStemRowDragHost>
@property (nonatomic, copy) void (^reorderHandler)(NSInteger from, NSInteger to);
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

- (void)beginDragForRow:(NSView*)dragRow event:(NSEvent*)downEvent {
    // Snapshot the original row order before any subview reshuffling so we
    // can compute display slots independently of self.subviews mutations.
    NSArray<NSView*>* rows = [self.subviews copy];
    NSInteger n = (NSInteger)rows.count;
    NSInteger origIndex = [rows indexOfObject:dragRow];
    if (origIndex == NSNotFound || n < 2) return;

    CGFloat rowH = self.bounds.size.height / (CGFloat)n;
    NSPoint pStart = [self convertPoint:downEvent.locationInWindow fromView:nil];
    CGFloat grabOffsetY = pStart.y - dragRow.frame.origin.y;

    NSInteger curIndex = origIndex;
    BOOL didStartDrag = NO;
    static const CGFloat kDragThreshold = 4.0;

    NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
    while (YES) {
        NSEvent* e = [self.window nextEventMatchingMask:mask
                                              untilDate:NSDate.distantFuture
                                                 inMode:NSEventTrackingRunLoopMode
                                                dequeue:YES];
        if (!e || e.type == NSEventTypeLeftMouseUp) break;

        NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
        if (!didStartDrag) {
            // Wait for a real movement before starting visual drag — a plain
            // click on the row body shouldn't kick off a reorder.
            if (fabs(p.y - pStart.y) < kDragThreshold &&
                fabs(p.x - pStart.x) < kDragThreshold) continue;
            didStartDrag = YES;
            // Bring the row to the front so it draws over its neighbors and
            // give it a small lift effect.
            [self addSubview:dragRow positioned:NSWindowAbove relativeTo:nil];
            dragRow.wantsLayer = YES;
            dragRow.layer.zPosition = 100;
            dragRow.layer.shadowOpacity = 0.45;
            dragRow.layer.shadowRadius = 8;
            dragRow.layer.shadowOffset = CGSizeMake(0, 2);
            dragRow.layer.shadowColor = [NSColor blackColor].CGColor;
            dragRow.alphaValue = 0.92;
        }

        CGFloat newY = p.y - grabOffsetY;
        if (newY < 0) newY = 0;
        if (newY > self.bounds.size.height - rowH) {
            newY = self.bounds.size.height - rowH;
        }
        NSRect f = dragRow.frame;
        f.origin.y = newY;
        dragRow.frame = f;

        // Target slot follows the dragged row's vertical center.
        CGFloat dragCenter = newY + rowH / 2.0;
        NSInteger newIndex = (NSInteger)floor(dragCenter / rowH);
        if (newIndex < 0) newIndex = 0;
        if (newIndex >= n) newIndex = n - 1;

        if (newIndex != curIndex) {
            curIndex = newIndex;
            // Slide the unaffected rows out of the dragged row's way. We do
            // this by computing each row's display slot under the assumption
            // that the dragged row will land at curIndex; rows in between
            // shift one slot toward the original index.
            for (NSInteger i = 0; i < n; ++i) {
                NSView* r = rows[i];
                if (r == dragRow) continue;
                NSInteger newSlot = i;
                if (origIndex < curIndex) {
                    if (i > origIndex && i <= curIndex) newSlot = i - 1;
                } else if (origIndex > curIndex) {
                    if (i >= curIndex && i < origIndex) newSlot = i + 1;
                }
                NSRect target = NSMakeRect(0, (CGFloat)newSlot * rowH,
                                           self.bounds.size.width, rowH);
                r.frame = target;
            }
        }
    }

    // Restore visual state — the model commit (or no-op) happens after.
    dragRow.alphaValue = 1.0;
    dragRow.layer.zPosition = 0;
    dragRow.layer.shadowOpacity = 0.0;

    if (didStartDrag && curIndex != origIndex && self.reorderHandler) {
        self.reorderHandler(origIndex, curIndex);
    } else {
        // No movement (or release without crossing a slot boundary): restore
        // the original layout.
        [self resizeSubviewsWithOldSize:self.bounds.size];
    }
}
@end

@interface OSScoreDivider : NSView
@property (nonatomic, copy) void (^dragHandler)(CGFloat delta);
@end
@implementation OSScoreDivider
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor]; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(NSMidX(self.bounds) - 1, NSMidY(self.bounds) - 22, 2, 44));
}
- (void)mouseDown:(NSEvent*)event {
    CGFloat lastX = event.locationInWindow.x;
    for (;;) {
        NSEvent* next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (!next || next.type == NSEventTypeLeftMouseUp) break;
        CGFloat delta = next.locationInWindow.x - lastX;
        lastX = next.locationInWindow.x;
        if (self.dragHandler) self.dragHandler(delta);
    }
}
@end

@interface MainWindow ()
@property (nonatomic, strong) IRealLibrary* irealLibrary;
@property (nonatomic, strong) NSView* scorePanel;
@property (nonatomic, strong) OSScoreDivider* scoreDivider;
@property (nonatomic, strong) NSSlider* scoreZoomSlider;
@property (nonatomic, strong) NSTextField* scoreZoomLabel;
@property (nonatomic) CGFloat preferredScoreWidth;
@property (nonatomic, strong) PDFView* scoreView;
@property (nonatomic, strong) NSTextField* scoreTitle;
@property (nonatomic, strong) NSButton* scoreButton;
@property (nonatomic, copy) NSString* scoreAudioPath;
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
@property (nonatomic, strong, readwrite) NSTextField* chordBadge;
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
    self.contentMinSize = NSMakeSize(960, 500);
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
          NSTextField* valueLabel, NSButton* reset,
          NSString* minText, NSString* maxText) {
        NSTextField* lbl = makeLabel(
            NSMakeRect(groupX, sliderRowY_, labelW, sliderRowH),
            labelText, NSTextAlignmentLeft);
        applyTrackedCaps(lbl, 1.6);
        [self.contentView addSubview:lbl];

        CGFloat sliderX = groupX + labelW + innerGap;
        slider.frame = NSMakeRect(sliderX, sliderRowY_, sliderW, sliderRowH);
        slider.continuous = YES;
        [self.contentView addSubview:slider];

        valueLabel.frame = NSMakeRect(
            groupX + labelW + innerGap + sliderW + innerGap,
            sliderRowY_, valueW, sliderRowH);
        [self.contentView addSubview:valueLabel];

        reset.frame = NSMakeRect(groupX + groupW - resetW,
                                 sliderRowY_, resetW, sliderRowH);
        [self.contentView addSubview:reset];

        // Bound hints: tiny min/max labels tucked below the slider track so
        // the user can read the slider's range without dragging to find it.
        // Width is half the slider so the two labels meet near the centre.
        CGFloat boundY = sliderRowY_ - 12;
        CGFloat halfW = sliderW / 2.0;
        NSTextField* minLbl = makeLabel(
            NSMakeRect(sliderX, boundY, halfW, 11),
            minText, NSTextAlignmentLeft);
        minLbl.font = [NSFont monospacedDigitSystemFontOfSize:9
                                                       weight:NSFontWeightRegular];
        minLbl.textColor = [NSColor colorWithWhite:0.50 alpha:1.0];
        [self.contentView addSubview:minLbl];

        NSTextField* maxLbl = makeLabel(
            NSMakeRect(sliderX + halfW, boundY, halfW, 11),
            maxText, NSTextAlignmentRight);
        maxLbl.font = [NSFont monospacedDigitSystemFontOfSize:9
                                                       weight:NSFontWeightRegular];
        maxLbl.textColor = [NSColor colorWithWhite:0.50 alpha:1.0];
        [self.contentView addSubview:maxLbl];
    };

    // VOLUME (leftmost)
    OSResettableSlider* volSlider = [[OSResettableSlider alloc] init];
    volSlider.minValue = 0.0;
    volSlider.maxValue = 1.5;
    volSlider.doubleValue = 1.0;
    volSlider.resetValue = 1.0;
    volSlider.toolTip = @"Drag to adjust volume (0–150%). Double-click to reset to 100%.";
    self.volumeSlider = volSlider;
    self.volumeLabel = makeMonoLabel(NSZeroRect, @"100%", NSTextAlignmentRight);
    self.volumeResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin, @"VOLUME", self.volumeSlider,
                self.volumeLabel, self.volumeResetButton,
                @"0%", @"150%");

    // PITCH (center)
    OSResettableSlider* pSlider = [[OSResettableSlider alloc] init];
    pSlider.minValue = -1200.0;
    pSlider.maxValue =  1200.0;
    pSlider.doubleValue = 0.0;
    pSlider.resetValue = 0.0;
    pSlider.toolTip = @"Drag to shift pitch (–12 to +12 semitones). Double-click to reset to 0.";
    self.pitchSlider = pSlider;
    self.pitchLabel = makeMonoLabel(NSZeroRect, @"+0.00 st", NSTextAlignmentRight);
    self.pitchResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin + groupW + groupGap, @"PITCH", self.pitchSlider,
                self.pitchLabel, self.pitchResetButton,
                @"-12 st", @"+12 st");

    // SPEED (right)
    OSResettableSlider* sSlider = [[OSResettableSlider alloc] init];
    sSlider.minValue = 0.25;
    sSlider.maxValue = 2.0;
    sSlider.doubleValue = 1.0;
    sSlider.resetValue = 1.0;
    sSlider.toolTip = @"Drag to adjust speed (0.25× to 2×). Double-click to reset to 1×.";
    self.speedSlider = sSlider;
    self.speedLabel = makeMonoLabel(NSZeroRect, @"1.00x", NSTextAlignmentRight);
    self.speedResetButton = makeResetButton(NSZeroRect);
    layoutGroup(margin + 2 * (groupW + groupGap), @"SPEED", self.speedSlider,
                self.speedLabel, self.speedResetButton,
                @"0.25x", @"2.00x");

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

    self.scoreButton = makeIconButton(
        NSMakeRect(margin + 3 * (iconSize + 8),
                   transportY + (transportRowH - iconSize)/2, iconSize, iconSize),
        @"doc.richtext", 16);
    self.scoreButton.toolTip = @"Show / hide sheet music";
    [self.scoreButton setAccessibilityLabel:@"Sheet music"];
    self.scoreButton.target = self;
    self.scoreButton.action = @selector(toggleSheetMusic:);
    self.scoreButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.contentView addSubview:self.scoreButton];

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

    self.chordBadge = makeLabel(NSMakeRect(10, 12, 220, 22), @"", NSTextAlignmentLeft);
    self.chordBadge.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.chordBadge.textColor = NSColor.whiteColor;
    self.chordBadge.hidden = YES;
    self.chordBadge.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.waveformView addSubview:self.chordBadge];
    // Keep the existing loop pill above the chord lane when both are visible.
    NSRect loopFrame = self.loopBadge.frame;
    loopFrame.origin.y += 64;
    self.loopBadge.frame = loopFrame;
    [self buildScorePanel];
    return self;
}

- (void)buildScorePanel {
    NSRect wave = self.waveformView.frame;
    CGFloat width = 360;
    self.preferredScoreWidth = width;
    self.scorePanel = [[NSView alloc] initWithFrame:
        NSMakeRect(NSMaxX(wave) - width, wave.origin.y, width, wave.size.height)];
    self.scorePanel.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    self.scorePanel.wantsLayer = YES;
    self.scorePanel.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    self.scorePanel.layer.cornerRadius = 6;
    self.scorePanel.layer.masksToBounds = YES;
    self.scorePanel.hidden = YES;
    [self.contentView addSubview:self.scorePanel];

    CGFloat height = wave.size.height;
    self.scoreTitle = makeLabel(NSMakeRect(12, height - 30, width - 54, 20),
                               @"Sheet Music", NSTextAlignmentLeft);
    self.scoreTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.scoreTitle.textColor = NSColor.labelColor;
    self.scoreTitle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.scoreTitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.scorePanel addSubview:self.scoreTitle];
    NSButton* close = makeIconButton(NSMakeRect(width - 32, height - 30, 22, 22), @"xmark", 12);
    close.contentTintColor = NSColor.labelColor;
    close.target = self;
    close.action = @selector(toggleSheetMusic:);
    close.toolTip = @"Hide sheet music";
    [close setAccessibilityLabel:close.toolTip];
    close.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.scorePanel addSubview:close];

    self.scoreView = [[PDFView alloc] initWithFrame:NSMakeRect(0, 76, width, height - 114)];
    self.scoreView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scoreView.autoScales = YES;
    self.scoreView.displayMode = kPDFDisplaySinglePageContinuous;
    self.scoreView.backgroundColor = [NSColor colorWithWhite:0.18 alpha:1];
    [self.scorePanel addSubview:self.scoreView];
    self.scoreZoomSlider = [NSSlider sliderWithValue:100 minValue:10 maxValue:400 target:self action:@selector(scoreZoomChanged:)];
    self.scoreZoomSlider.frame = NSMakeRect(16, 42, width - 88, 24);
    self.scoreZoomSlider.continuous = YES;
    self.scoreZoomSlider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.scoreZoomSlider.toolTip = @"PDF zoom";
    [self.scoreZoomSlider setAccessibilityLabel:@"PDF zoom percentage"];
    [self.scorePanel addSubview:self.scoreZoomSlider];
    self.scoreZoomLabel = makeLabel(NSMakeRect(width - 68, 44, 56, 20), @"100%", NSTextAlignmentRight);
    self.scoreZoomLabel.textColor = NSColor.labelColor;
    self.scoreZoomLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.scorePanel addSubview:self.scoreZoomLabel];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scoreScaleChanged:)
        name:PDFViewScaleChangedNotification object:self.scoreView];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scoreWindowResized:)
        name:NSWindowDidResizeNotification object:self];
    self.scoreDivider = [[OSScoreDivider alloc] initWithFrame:NSZeroRect];
    self.scoreDivider.hidden = YES;
    self.scoreDivider.toolTip = @"Drag to resize sheet music";
    [self.scoreDivider setAccessibilityLabel:@"Resize sheet music panel"];
    __weak MainWindow* weakWindow = self;
    self.scoreDivider.dragHandler = ^(CGFloat delta) {
        MainWindow* window = weakWindow;
        window.preferredScoreWidth = window.scorePanel.frame.size.width - delta;
        [window layoutScorePanel];
    };
    [self.contentView addSubview:self.scoreDivider];

    NSButton* libraryButton = [NSButton buttonWithTitle:@"Library…" target:self action:@selector(showIRealLibrary:)];
    libraryButton.frame = NSMakeRect(100, 8, 80, 26);
    libraryButton.toolTip = @"Choose an iReal chord chart";
    [self.scorePanel addSubview:libraryButton];
    NSArray* titles = @[@"Open…", @"−", @"+", @"Fit"];
    SEL actions[] = {@selector(openSheetMusic:), @selector(scoreZoomOut:),
                     @selector(scoreZoomIn:), @selector(scoreFit:)};
    CGFloat positions[] = {10, 180, 226, 272};
    CGFloat widths[] = {90, 40, 40, 76};
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSButton* button = [NSButton buttonWithTitle:titles[i] target:self action:actions[i]];
        button.frame = NSMakeRect(positions[i], 8, widths[i], 26);
        button.autoresizingMask = (i == 0 ? NSViewMaxXMargin : NSViewMinXMargin) | NSViewMaxYMargin;
        button.toolTip = (@[@"Open a PDF or image", @"Zoom out", @"Zoom in", @"Fit page"])[i];
        [button setAccessibilityLabel:button.toolTip];
        [self.scorePanel addSubview:button];
    }
}

- (void)layoutScorePanel {
    NSRect wave = self.waveformView.frame;
    CGFloat right = self.contentView.bounds.size.width - 20;
    if (self.scorePanel.hidden) {
        wave.size.width = right - wave.origin.x;
    } else {
        CGFloat maximum = MAX(360, right - wave.origin.x - 312);
        CGFloat width = MIN(MAX(360, self.preferredScoreWidth), maximum);
        self.scorePanel.frame = NSMakeRect(right - width, wave.origin.y, width, wave.size.height);
        self.scoreDivider.frame = NSMakeRect(right - width - 12, wave.origin.y, 12, wave.size.height);
        wave.size.width = right - width - 12 - wave.origin.x;
    }
    self.waveformView.frame = wave;
    self.scoreDivider.hidden = self.scorePanel.hidden;
    NSRect hint = self.dropHintContainer.frame;
    hint.origin.x = NSMidX(wave) - hint.size.width / 2;
    self.dropHintContainer.frame = hint;
    [self invalidateCursorRectsForView:self.scoreDivider];
}

- (void)scoreWindowResized:(NSNotification*)notification {
    (void)notification;
    [self layoutScorePanel];
}

- (void)toggleSheetMusic:(id)sender {
    (void)sender;
    self.scorePanel.hidden = !self.scorePanel.hidden;
    [self layoutScorePanel];
    self.scoreButton.contentTintColor = self.scorePanel.hidden ? NSColor.labelColor : NSColor.controlAccentColor;
    [self makeFirstResponder:self.waveformView];
}

- (void)scoreScaleChanged:(NSNotification*)notification {
    (void)notification;
    double percent = self.scoreView.scaleFactor * 100;
    self.scoreZoomSlider.doubleValue = percent;
    self.scoreZoomLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", percent];
    self.scoreZoomSlider.enabled = self.scoreView.document != nil;
}

- (void)setScoreScale:(CGFloat)scale {
    if (!self.scoreView.document) return;
    self.scoreView.autoScales = NO;
    self.scoreView.minScaleFactor = 0.1;
    self.scoreView.maxScaleFactor = 4.0;
    self.scoreView.scaleFactor = MIN(4.0, MAX(0.1, scale));
    [self scoreScaleChanged:nil];
}
- (void)scoreZoomChanged:(NSSlider*)sender { [self setScoreScale:sender.doubleValue / 100]; }
- (void)scoreZoomIn:(id)sender { (void)sender; [self setScoreScale:self.scoreView.scaleFactor * 1.25]; }
- (void)scoreZoomOut:(id)sender { (void)sender; [self setScoreScale:self.scoreView.scaleFactor / 1.25]; }
- (void)scoreFit:(id)sender {
    (void)sender;
    self.scoreView.autoScales = YES;
    [self scoreScaleChanged:nil];
}

- (BOOL)loadSheetMusicURL:(NSURL*)url {
    PDFDocument* document = [[PDFDocument alloc] initWithURL:url];
    if (!document) {
        NSImage* image = [[NSImage alloc] initWithContentsOfURL:url];
        PDFPage* page = image ? [[PDFPage alloc] initWithImage:image] : nil;
        if (page) {
            document = [[PDFDocument alloc] init];
            [document insertPage:page atIndex:0];
        }
    }
    if (!document || document.isLocked || document.pageCount == 0) return NO;
    self.scoreView.document = document;
    self.scoreView.autoScales = YES;
    [self scoreScaleChanged:nil];
    self.scoreTitle.stringValue = url.lastPathComponent;
    self.scoreTitle.toolTip = url.path;
    return YES;
}

- (void)showIRealLibrary:(id)sender {
    (void)sender;
    if (!self.irealLibrary) {
        self.irealLibrary = [[IRealLibrary alloc] init];
        __weak MainWindow* weakSelf = self;
        self.irealLibrary.selectionHandler = ^(NSURL* url) {
            MainWindow* window = weakSelf;
            if ([window loadSheetMusicURL:url]) {
                [window rememberSheetMusicURL:url];
                if (window.scorePanel.hidden) [window toggleSheetMusic:nil];
                [window makeKeyAndOrderFront:nil];
                [window makeFirstResponder:window.waveformView];
            }
        };
    }
    [self.irealLibrary showLibrary];
}

- (void)rememberSheetMusicURL:(NSURL*)url {
    if (self.scoreAudioPath.length) {
        [[NSUserDefaults standardUserDefaults] setObject:url.path
            forKey:[@"openscribe.score." stringByAppendingString:self.scoreAudioPath]];
    }
}

- (void)openSheetMusic:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePDF, UTTypeImage];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.message = @"Choose a lead sheet or Real Book page (PDF or image).";
    [panel beginSheetModalForWindow:self completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        if (![self loadSheetMusicURL:panel.URL]) {
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"Could not open sheet music";
            alert.informativeText = @"Choose a readable PDF without a password, or an image file.";
            [alert beginSheetModalForWindow:self completionHandler:nil];
            return;
        }
        [self rememberSheetMusicURL:panel.URL];
        if (self.scorePanel.hidden) [self toggleSheetMusic:nil];
        [self makeFirstResponder:self.waveformView];
    }];
}

- (void)setSheetMusicAudioPath:(NSString*)path {
    if ([self.scoreAudioPath isEqualToString:path]) return;
    self.scoreAudioPath = path;
    self.scoreView.document = nil;
    [self scoreScaleChanged:nil];
    self.scoreTitle.stringValue = @"Sheet Music — Open a PDF or image";
    self.scoreTitle.toolTip = nil;
    NSString* saved = path.length ? [[NSUserDefaults standardUserDefaults]
        stringForKey:[@"openscribe.score." stringByAppendingString:path]] : nil;
    if (saved && [self loadSheetMusicURL:[NSURL fileURLWithPath:saved]]) {
        if (self.scorePanel.hidden) [self toggleSheetMusic:nil];
    }
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
    [self layoutScorePanel];
}

- (void)setStemReorderHandler:(void (^)(NSInteger from, NSInteger to))handler {
    ((StemMixerSidebar*)self.stemSidebar).reorderHandler = handler;
}

- (void)updatePlayPauseButton:(BOOL)playing {
    NSString* sym = playing ? @"pause.fill" : @"play.fill";
    NSImage* img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightRegular];
    self.playPauseButton.image = [img imageWithSymbolConfiguration:cfg];
}

@end
