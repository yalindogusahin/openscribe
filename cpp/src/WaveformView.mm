#import "WaveformView.h"
#import "AudioEngine.h"
#import "TimelineRulerView.h"

#include <algorithm>
#include <cmath>

namespace {
struct Vertex {
    simd_float2 position;
    simd_float4 color;
};

// Pre-compute a high-resolution peak buffer; the draw path rebins it down to
// pixel width for the visible window. 131K bins gives clean detail when zoomed
// way in without explosive vertex counts at the wide view.
constexpr int kPeakBins = 131072;
}

@interface BookmarkLabelsView : NSView
@property (nonatomic, copy) NSArray<NSDictionary*>* bookmarks;
@property (nonatomic) double viewStart;
@property (nonatomic) double viewEnd;
@property (nonatomic) double duration;
@property (nonatomic, copy) void (^jumpHandler)(NSInteger index);
@property (nonatomic, copy) void (^renameHandler)(NSInteger index);
@property (nonatomic, copy) void (^removeHandler)(NSInteger index);
- (NSInteger)bookmarkIndexAtLocalX:(CGFloat)x;
@end

@implementation BookmarkLabelsView
- (BOOL)isFlipped { return NO; }

- (NSInteger)bookmarkIndexAtLocalX:(CGFloat)x {
    if (_duration <= 0.0 || _bookmarks.count == 0) return -1;
    double span = std::max(1e-9, _viewEnd - _viewStart);
    constexpr CGFloat bw = 18.0;
    NSInteger best = -1;
    CGFloat bestDist = bw / 2.0 + 6.0;
    for (NSUInteger i = 0; i < _bookmarks.count; ++i) {
        NSDictionary* d = _bookmarks[i];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        double t = [d[@"time"] doubleValue];
        double tFrac = t / _duration;
        double tView = (tFrac - _viewStart) / span;
        if (tView < 0.0 || tView > 1.0) continue;
        CGFloat bx = (CGFloat)(tView * self.bounds.size.width);
        CGFloat dist = std::abs((double)(x - bx));
        if (dist <= bestDist) { bestDist = dist; best = (NSInteger)i; }
    }
    return best;
}

- (NSView*)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return [self bookmarkIndexAtLocalX:local.x] >= 0 ? self : nil;
}

- (void)mouseDown:(NSEvent*)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self bookmarkIndexAtLocalX:p.x];
    if (idx >= 0 && self.jumpHandler) self.jumpHandler(idx);
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self bookmarkIndexAtLocalX:p.x];
    if (idx < 0) return nil;
    NSMenu* m = [[NSMenu alloc] init];
    NSDictionary* b = _bookmarks[idx];
    NSString* lbl = [b[@"label"] isKindOfClass:[NSString class]] ? b[@"label"] : @"";
    NSString* title = lbl.length
        ? [NSString stringWithFormat:@"Bookmark %ld — %@", (long)(idx + 1), lbl]
        : [NSString stringWithFormat:@"Bookmark %ld", (long)(idx + 1)];
    NSMenuItem* hdr = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    hdr.enabled = NO;
    [m addItem:hdr];
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem* rn = [[NSMenuItem alloc] initWithTitle:@"Rename\u2026"
                                                action:@selector(_renameClicked:)
                                         keyEquivalent:@""];
    rn.target = self;
    rn.tag = idx;
    [m addItem:rn];
    NSMenuItem* rm = [[NSMenuItem alloc] initWithTitle:@"Remove"
                                                action:@selector(_removeClicked:)
                                         keyEquivalent:@""];
    rm.target = self;
    rm.tag = idx;
    [m addItem:rm];
    return m;
}

- (void)_renameClicked:(NSMenuItem*)sender {
    if (self.renameHandler) self.renameHandler(sender.tag);
}
- (void)_removeClicked:(NSMenuItem*)sender {
    if (self.removeHandler) self.removeHandler(sender.tag);
}

- (void)drawRect:(NSRect)dirty {
    if (_duration <= 0.0 || _bookmarks.count == 0) return;
    double span = std::max(1e-9, _viewEnd - _viewStart);
    NSDictionary* numAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor blackColor],
    };
    NSDictionary* labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.95 alpha:1.0],
    };
    NSDictionary* labelShadow = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.0 alpha:0.55],
    };
    CGFloat bw = 18, bh = 14;
    NSColor* badgeFill = [NSColor colorWithRed:1.0 green:0.92 blue:0.30 alpha:0.95];
    [_bookmarks enumerateObjectsUsingBlock:^(NSDictionary* d, NSUInteger idx, BOOL* stop) {
        if (![d isKindOfClass:[NSDictionary class]]) return;
        double t = [d[@"time"] doubleValue];
        NSString* lbl = [d[@"label"] isKindOfClass:[NSString class]] ? d[@"label"] : @"";
        double tFrac = t / self.duration;
        double tView = (tFrac - self.viewStart) / span;
        if (tView < 0.0 || tView > 1.0) return;
        CGFloat x = (CGFloat)(tView * self.bounds.size.width);
        NSRect r = NSMakeRect(x - bw/2, self.bounds.size.height - bh - 2, bw, bh);
        NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect:r xRadius:3 yRadius:3];
        [badgeFill setFill];
        [bp fill];
        NSString* s = [NSString stringWithFormat:@"%lu", (unsigned long)(idx + 1)];
        NSSize sz = [s sizeWithAttributes:numAttrs];
        [s drawAtPoint:NSMakePoint(r.origin.x + (bw - sz.width)/2,
                                   r.origin.y + (bh - sz.height)/2 + 0.5)
        withAttributes:numAttrs];
        if (lbl.length > 0) {
            NSPoint origin = NSMakePoint(r.origin.x + bw + 4,
                                         r.origin.y + (bh - 12) / 2.0);
            // 1px shadow for readability over the bright waveform.
            [lbl drawAtPoint:NSMakePoint(origin.x + 0.5, origin.y - 0.5)
              withAttributes:labelShadow];
            [lbl drawAtPoint:origin withAttributes:labelAttrs];
        }
    }];
}
@end

typedef NS_ENUM(NSInteger, LoopHit) {
    LoopHitNone = 0,
    LoopHitLeft,
    LoopHitRight,
    LoopHitInside,
};

typedef NS_ENUM(NSInteger, DragMode) {
    DragNone = 0,
    DragSeek,
    DragNewLoop,
    DragResizeLeft,
    DragResizeRight,
    DragMoveLoop,
    DragPan,
};

@interface StemLabelsView : NSView
@property (nonatomic, copy) NSArray<NSString*>* names;
@property (nonatomic, copy) NSArray<NSColor*>* colors;
@end

@implementation StemLabelsView
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)point { (void)point; return nil; }  // mouse passes through
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSUInteger n = _names.count;
    if (n < 2) return;
    CGFloat H = self.bounds.size.height;
    CGFloat lane = H / (CGFloat)n;
    NSDictionary* shadow = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.0 alpha:0.55],
    };
    for (NSUInteger i = 0; i < n; i++) {
        NSColor* c = (i < _colors.count) ? _colors[i] : [NSColor whiteColor];
        NSDictionary* attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: c,
        };
        NSString* label = [_names[i] uppercaseString];
        NSPoint p = NSMakePoint(8.0, (CGFloat)i * lane + 4.0);
        [label drawAtPoint:NSMakePoint(p.x + 0.5, p.y + 0.5) withAttributes:shadow];
        [label drawAtPoint:p withAttributes:attrs];
    }
}
@end

@interface WaveformView () {
    AudioEngine* _engine;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pso;
    // Per-stem peak buffers. Single-stem load → one entry; stems load → N.
    std::vector<std::vector<float>> _peaksMin;
    std::vector<std::vector<float>> _peaksMax;
    NSArray<NSString*>* _stemNames;
    StemLabelsView* _stemLabels;
    // MIDI piano-roll overlay, keyed by stem name. Each value is an
    // NSArray of NSDictionary {start, end, pitch, velocity}.
    NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>* _midiNotes;
    DragMode _dragMode;
    double _dragAnchorSec;
    double _dragStartLoopStartSec;
    double _dragStartLoopEndSec;
    double _dragStartCursorSec;
    double _dragStartViewStart;
    double _dragStartViewEnd;
    NSPoint _dragStartPoint;
    // View window in [0, 1] of total duration.
    double _viewStart;
    double _viewEnd;
    TimelineRulerView* _ruler;
    NSTrackingArea* _trackingArea;
    NSArray<NSDictionary*>* _bookmarks;
    BookmarkLabelsView* _bookmarkLabels;
    NSTextField* _zoomLabel;
}
@end

@implementation WaveformView

- (instancetype)initWithFrame:(NSRect)frame engine:(AudioEngine*)engine {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:device];
    if (!self) return nil;

    _engine = engine;
    _device = device;
    _queue = [device newCommandQueue];
    _viewStart = 0.0;
    _viewEnd = 1.0;
    _midiNotes = [NSMutableDictionary dictionary];

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0.058, 0.062, 0.070, 1.0);
    self.preferredFramesPerSecond = 60;
    self.enableSetNeedsDisplay = NO;
    self.paused = NO;

    [self buildPipeline];
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    CGFloat rulerH = 22.0;
    NSRect rulerFrame = NSMakeRect(0, frame.size.height - rulerH,
                                   frame.size.width, rulerH);
    _ruler = [[TimelineRulerView alloc] initWithFrame:rulerFrame];
    _ruler.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_ruler];

    CGFloat bmH = 18.0;
    NSRect bmFrame = NSMakeRect(0, frame.size.height - rulerH - bmH,
                                frame.size.width, bmH);
    _bookmarkLabels = [[BookmarkLabelsView alloc] initWithFrame:bmFrame];
    _bookmarkLabels.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_bookmarkLabels];

    CGFloat zoomW = 60, zoomH = 18;
    _zoomLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(frame.size.width - zoomW - 8,
                   frame.size.height - rulerH - bmH - zoomH - 4,
                   zoomW, zoomH)];
    _zoomLabel.bezeled = NO;
    _zoomLabel.editable = NO;
    _zoomLabel.selectable = NO;
    _zoomLabel.drawsBackground = NO;
    _zoomLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    _zoomLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    _zoomLabel.alignment = NSTextAlignmentRight;
    _zoomLabel.stringValue = @"";
    _zoomLabel.hidden = YES;
    _zoomLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:_zoomLabel];

    // Stem labels overlay sits behind the ruler/bookmark layers but above the
    // Metal waveform. Sized to the area below the ruler so each lane label
    // lands on the correct waveform slot.
    NSRect stemFrame = NSMakeRect(0, 0, frame.size.width,
                                  std::max<CGFloat>(1.0, frame.size.height - rulerH - bmH));
    _stemLabels = [[StemLabelsView alloc] initWithFrame:stemFrame];
    _stemLabels.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_stemLabels positioned:NSWindowBelow relativeTo:_bookmarkLabels];

    [self rebuildTrackingArea];
    return self;
}

- (void)setMIDINotes:(NSArray<NSDictionary*>*)notes forStemName:(NSString*)stemName {
    if (stemName.length == 0) return;
    if (notes.count > 0) {
        _midiNotes[stemName] = [notes copy];
    } else {
        [_midiNotes removeObjectForKey:stemName];
    }
    [self setNeedsDisplay:YES];
}

- (void)clearAllMIDINotes {
    [_midiNotes removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setStemNames:(NSArray<NSString*>*)names {
    _stemNames = [names copy];
    NSMutableArray<NSColor*>* cols = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; i++) {
        [cols addObject:[WaveformView nsStemColorForIndex:(int)i name:names[i]]];
    }
    _stemLabels.names = _stemNames;
    _stemLabels.colors = cols;
    [_stemLabels setNeedsDisplay:YES];
    // Lane count and peaks come from the engine, not the names — colors are
    // read at draw time from the latest _stemNames, so a redraw is enough.
    [self setNeedsDisplay:YES];
}

- (void)rebuildTrackingArea {
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited
                               | NSTrackingMouseMoved
                               | NSTrackingActiveInKeyWindow
                               | NSTrackingInVisibleRect;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                  options:opts
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self rebuildTrackingArea];
}

- (double)viewStart { return _viewStart; }
- (double)viewEnd { return _viewEnd; }
- (void)setViewStart:(double)start end:(double)end {
    _viewStart = std::clamp(start, 0.0, 1.0);
    _viewEnd = std::clamp(end, 0.0, 1.0);
    if (_viewEnd <= _viewStart) _viewEnd = std::min(1.0, _viewStart + 0.001);
    [self syncOverlays];
}

- (void)syncOverlays {
    double dur = _engine ? _engine->duration() : 0.0;
    [_ruler updateViewStart:_viewStart end:_viewEnd duration:dur];
    _bookmarkLabels.viewStart = _viewStart;
    _bookmarkLabels.viewEnd = _viewEnd;
    _bookmarkLabels.duration = dur;
    [_bookmarkLabels setNeedsDisplay:YES];

    double zoom = 1.0 / std::max(1e-6, _viewEnd - _viewStart);
    if (dur > 0.0 && zoom > 1.05) {
        _zoomLabel.stringValue = [NSString stringWithFormat:@"%.1f×", zoom];
        _zoomLabel.hidden = NO;
    } else {
        _zoomLabel.hidden = YES;
    }
}

- (void)setBookmarks:(NSArray<NSDictionary*>*)bookmarks {
    _bookmarks = [bookmarks copy];
    _bookmarkLabels.bookmarks = _bookmarks;
    [_bookmarkLabels setNeedsDisplay:YES];
}

- (NSArray<NSDictionary*>*)bookmarks { return _bookmarks; }

- (void)setBookmarkJumpHandler:(void (^)(NSInteger))h {
    _bookmarkJumpHandler = [h copy];
    _bookmarkLabels.jumpHandler = _bookmarkJumpHandler;
}
- (void)setBookmarkRenameHandler:(void (^)(NSInteger))h {
    _bookmarkRenameHandler = [h copy];
    _bookmarkLabels.renameHandler = _bookmarkRenameHandler;
}
- (void)setBookmarkRemoveHandler:(void (^)(NSInteger))h {
    _bookmarkRemoveHandler = [h copy];
    _bookmarkLabels.removeHandler = _bookmarkRemoveHandler;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return self.fileDropHandler ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (!self.fileDropHandler) return NO;
    NSPasteboard* pb = sender.draggingPasteboard;
    NSArray<NSURL*>* urls =
        [pb readObjectsForClasses:@[NSURL.class]
                          options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if (urls.count == 0) return NO;
    self.fileDropHandler(urls.firstObject.path);
    return YES;
}

- (void)buildPipeline {
    NSError* err = nil;
    NSString* libPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    id<MTLLibrary> lib = libPath
        ? [_device newLibraryWithFile:libPath error:&err]
        : [_device newDefaultLibrary];
    if (!lib) {
        NSLog(@"Metal library load failed: %@", err);
        return;
    }

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [lib newFunctionWithName:@"vs_main"];
    desc.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _pso = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pso) NSLog(@"PSO failed: %@", err);
}

- (void)reloadFromEngine {
    if (!_engine) return;
    _viewStart = 0.0;
    _viewEnd = 1.0;
    [self computePeaks];
    [self syncOverlays];
}

- (void)computePeaks {
    _peaksMin.clear();
    _peaksMax.clear();

    double dur = _engine->duration();
    if (dur <= 0.0) return;

    int n = _engine->stemCount();
    if (n <= 0) return;

    int64_t totalFrames = static_cast<int64_t>(dur * _engine->sampleRate());
    int bins = kPeakBins;
    int64_t framesPerBin = std::max<int64_t>(1, totalFrames / bins);

    _peaksMin.resize((size_t)n);
    _peaksMax.resize((size_t)n);

    for (int k = 0; k < n; ++k) {
        const float* s = _engine->stemSamplesPtr(k);
        // Fall back to the unity-mix buffer when only one stem exists. This
        // matches old behavior for single-file loads where samplesPtr is the
        // canonical source.
        if (!s && n == 1) s = _engine->samplesPtr();
        if (!s) continue;

        std::vector<float>& mins = _peaksMin[(size_t)k];
        std::vector<float>& maxs = _peaksMax[(size_t)k];
        mins.assign(bins, 0.0f);
        maxs.assign(bins, 0.0f);

        for (int b = 0; b < bins; ++b) {
            int64_t start = (int64_t)b * framesPerBin;
            int64_t end = std::min<int64_t>(start + framesPerBin, totalFrames);
            float mn = 0.0f, mx = 0.0f;
            for (int64_t f = start; f < end; ++f) {
                float v = 0.5f * (s[f * 2 + 0] + s[f * 2 + 1]);
                if (v < mn) mn = v;
                if (v > mx) mx = v;
            }
            mins[b] = mn;
            maxs[b] = mx;
        }
    }
}

// Stem palette — index-keyed but tweaked by name when recognizable. Stable
// across runs so users build muscle memory: vocals always pink, drums orange,
// bass green, etc. Picked for distinguishability against the dark background
// and from each other; alpha=1 keeps each lane crisp.
+ (simd_float4)stemColorForIndex:(int)idx name:(NSString*)name {
    NSString* n = name.lowercaseString;
    if ([n containsString:@"vocal"])  return (simd_float4){0.96f, 0.55f, 0.78f, 1.0f};
    if ([n containsString:@"drum"])   return (simd_float4){1.00f, 0.55f, 0.30f, 1.0f};
    if ([n containsString:@"bass"])   return (simd_float4){0.45f, 0.85f, 0.55f, 1.0f};
    if ([n containsString:@"guitar"]) return (simd_float4){0.95f, 0.85f, 0.40f, 1.0f};
    if ([n containsString:@"piano"])  return (simd_float4){0.55f, 0.85f, 0.95f, 1.0f};
    if ([n containsString:@"other"])  return (simd_float4){0.65f, 0.62f, 0.95f, 1.0f};
    static const simd_float4 fallback[6] = {
        {0.55f, 0.72f, 0.88f, 1.0f},
        {0.96f, 0.55f, 0.78f, 1.0f},
        {1.00f, 0.55f, 0.30f, 1.0f},
        {0.45f, 0.85f, 0.55f, 1.0f},
        {0.95f, 0.85f, 0.40f, 1.0f},
        {0.65f, 0.62f, 0.95f, 1.0f},
    };
    int i = ((idx % 6) + 6) % 6;
    return fallback[i];
}

+ (NSColor*)nsStemColorForIndex:(int)idx name:(NSString*)name {
    simd_float4 c = [self stemColorForIndex:idx name:name];
    return [NSColor colorWithRed:c.x green:c.y blue:c.z alpha:c.w];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_pso) return;
    MTLRenderPassDescriptor* rpd = self.currentRenderPassDescriptor;
    if (!rpd) return;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc =
        [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pso];

    std::vector<Vertex> verts;
    int laneCount = (int)_peaksMin.size();  // 0 when nothing loaded
    int firstLaneBins = laneCount > 0 ? (int)_peaksMin[0].size() : 0;
    verts.reserve((size_t)firstLaneBins * 6 * (size_t)std::max(1, laneCount) + 64);

    const double span = std::max(1e-9, _viewEnd - _viewStart);

    // Waveform bars: rebin source peaks to ~2 bins per pixel of the visible
    // window so we never push more triangles than necessary. With multi-stem
    // loads each stem renders into its own horizontal lane carved out of the
    // [-1, 1] vertical NDC; overlays (loop / playhead / bookmarks) still span
    // the full height so they stay legible across all lanes.
    for (int k = 0; k < laneCount; ++k) {
        int bins = (int)_peaksMin[(size_t)k].size();
        if (bins <= 0) continue;
        const std::vector<float>& mins = _peaksMin[(size_t)k];
        const std::vector<float>& maxs = _peaksMax[(size_t)k];

        NSString* nm = (k < (int)_stemNames.count) ? _stemNames[(NSUInteger)k] : nil;
        simd_float4 col = [WaveformView stemColorForIndex:k name:nm];

        // Lane y-range in NDC. Top of view is +1, bottom is -1. With a small
        // inset between lanes so adjacent waveforms don't visually merge.
        double laneTop    = 1.0 - 2.0 * (double)k       / (double)laneCount;
        double laneBottom = 1.0 - 2.0 * (double)(k + 1) / (double)laneCount;
        double inset = (laneCount > 1) ? 0.04 : 0.0;
        double topInset    = laneTop - inset;
        double bottomInset = laneBottom + inset;
        double center = 0.5 * (topInset + bottomInset);
        double half   = 0.5 * (topInset - bottomInset);  // >0

        int firstBin = std::max(0, (int)std::floor(_viewStart * bins));
        int lastBin  = std::min(bins, (int)std::ceil(_viewEnd  * bins));
        int visible = std::max(1, lastBin - firstBin);
        int pixelW = std::max(1, (int)self.drawableSize.width);
        int targetBars = std::min(visible, pixelW * 2);
        if (targetBars < 1) targetBars = 1;
        for (int t = 0; t < targetBars; ++t) {
            int s = firstBin + (int64_t)t * visible / targetBars;
            int e = firstBin + (int64_t)(t + 1) * visible / targetBars;
            if (e <= s) e = s + 1;
            if (e > lastBin) e = lastBin;
            float yMin = 1.0f, yMax = -1.0f;
            for (int b = s; b < e; ++b) {
                if (mins[b] < yMin) yMin = mins[b];
                if (maxs[b] > yMax) yMax = maxs[b];
            }
            yMax = std::clamp(yMax, -1.0f, 1.0f);
            yMin = std::clamp(yMin, -1.0f, 1.0f);
            if (yMax - yMin < 0.005f) { yMax += 0.0025f; yMin -= 0.0025f; }
            double bx0 = ((double)s / bins - _viewStart) / span;
            double bx1 = ((double)e / bins - _viewStart) / span;
            float x0 = -1.0f + 2.0f * (float)bx0;
            float x1 = -1.0f + 2.0f * (float)bx1;
            // Map [-1, 1] sample range into this lane's vertical slot.
            float lyMin = (float)(center + half * (double)yMin);
            float lyMax = (float)(center + half * (double)yMax);
            verts.push_back({{x0, lyMin}, col});
            verts.push_back({{x1, lyMin}, col});
            verts.push_back({{x1, lyMax}, col});
            verts.push_back({{x0, lyMin}, col});
            verts.push_back({{x1, lyMax}, col});
            verts.push_back({{x0, lyMax}, col});
        }
    }

    // MIDI piano-roll overlay per stem. Drawn between waveform bars and lane
    // dividers so notes layer on top of the audio peaks but stay below the
    // structural separator lines / playhead. Pitch range auto-fits per stem
    // (with a 1-octave minimum) so even a sparse note range fills the lane.
    double durForMidi = _engine ? _engine->duration() : 0.0;
    if (_midiNotes.count > 0 && durForMidi > 0.0 && laneCount > 0) {
        for (int k = 0; k < laneCount; ++k) {
            NSString* nm = (k < (int)_stemNames.count) ? _stemNames[(NSUInteger)k] : nil;
            if (!nm) continue;
            NSArray<NSDictionary*>* notes = _midiNotes[nm];
            if (notes.count == 0) continue;

            double laneTop    = 1.0 - 2.0 * (double)k       / (double)laneCount;
            double laneBottom = 1.0 - 2.0 * (double)(k + 1) / (double)laneCount;
            double inset = (laneCount > 1) ? 0.04 : 0.0;
            double topInset    = laneTop - inset;
            double bottomInset = laneBottom + inset;
            double center = 0.5 * (topInset + bottomInset);
            double half   = 0.5 * (topInset - bottomInset);

            int pmin = 127, pmax = 0;
            for (NSDictionary* nd in notes) {
                int p = [nd[@"pitch"] intValue];
                if (p < pmin) pmin = p;
                if (p > pmax) pmax = p;
            }
            if (pmin > pmax) continue;
            // Pad to at least one octave so a song with only a few pitches
            // doesn't blow each note up to fill the entire lane vertically.
            if (pmax - pmin < 12) {
                int mid = (pmin + pmax) / 2;
                pmin = mid - 6;
                pmax = mid + 6;
            }
            double pSpan = std::max(1.0, (double)(pmax - pmin));

            // 85% of lane height for notes, leaving a margin so they don't
            // collide with the lane dividers.
            double useHalf = half * 0.85;
            // Each pitch row's vertical thickness, slightly less than full
            // row pitch so adjacent semitones don't visually merge.
            double rowH = (2.0 * useHalf) / pSpan;
            double halfH = std::max(0.0008, rowH * 0.40);

            // White-ish notes pop against any stem color while keeping the
            // pitch bar legible. Velocity modulates alpha so louder notes
            // read brighter.
            simd_float4 baseCol = {1.0f, 1.0f, 1.0f, 0.85f};

            for (NSDictionary* nd in notes) {
                double t0 = [nd[@"start"] doubleValue];
                double t1 = [nd[@"end"] doubleValue];
                if (t1 <= t0) continue;
                int p = [nd[@"pitch"] intValue];
                double vel = [nd[@"velocity"] doubleValue];

                double f0 = t0 / durForMidi;
                double f1 = t1 / durForMidi;
                double xa = (f0 - _viewStart) / span;
                double xb = (f1 - _viewStart) / span;
                if (xb < 0.0 || xa > 1.0) continue;
                xa = std::max(0.0, xa);
                xb = std::min(1.0, xb);
                float x0 = -1.0f + 2.0f * (float)xa;
                float x1 = -1.0f + 2.0f * (float)xb;
                // Make ultra-short notes still visible: at least 1px wide.
                float minW = 1.0f / std::max<float>(1.0f, (float)self.drawableSize.width);
                if (x1 - x0 < minW * 2.0f) x1 = x0 + minW * 2.0f;

                double pf = (double)(p - pmin) / pSpan;  // 0 = lowest, 1 = highest
                double yc = center + useHalf * (pf * 2.0 - 1.0);
                float yMin = (float)(yc - halfH);
                float yMax = (float)(yc + halfH);

                simd_float4 nc = baseCol;
                nc.w = (float)std::clamp(0.55 + vel * 0.45, 0.5, 1.0);

                verts.push_back({{x0, yMin}, nc});
                verts.push_back({{x1, yMin}, nc});
                verts.push_back({{x1, yMax}, nc});
                verts.push_back({{x0, yMin}, nc});
                verts.push_back({{x1, yMax}, nc});
                verts.push_back({{x0, yMax}, nc});
            }
        }
    }

    // Subtle horizontal divider lines between lanes — a 1-px dark band right
    // at each split makes the lanes feel separated without dominating the eye.
    if (laneCount > 1) {
        float lineH = 1.0f / std::max<float>(1.0f, (float)self.drawableSize.height);
        simd_float4 div = {0.0f, 0.0f, 0.0f, 0.35f};
        for (int k = 1; k < laneCount; ++k) {
            float y = (float)(1.0 - 2.0 * (double)k / (double)laneCount);
            verts.push_back({{-1.0f, y - lineH}, div});
            verts.push_back({{ 1.0f, y - lineH}, div});
            verts.push_back({{ 1.0f, y + lineH}, div});
            verts.push_back({{-1.0f, y - lineH}, div});
            verts.push_back({{ 1.0f, y + lineH}, div});
            verts.push_back({{-1.0f, y + lineH}, div});
        }
    }

    // Loop region (drawn behind playhead) with edge handles.
    double durForLoop = _engine ? _engine->duration() : 0.0;
    if (durForLoop > 0.0 && _engine->hasLoop()) {
        double sr = _engine->sampleRate();
        double ls = _engine->loopStartFrame() / sr;
        double le = _engine->loopEndFrame() / sr;
        double lsV = (ls / durForLoop - _viewStart) / span;
        double leV = (le / durForLoop - _viewStart) / span;
        if (leV > 0.0 && lsV < 1.0) {
            float x0 = -1.0f + 2.0f * (float)lsV;
            float x1 = -1.0f + 2.0f * (float)leV;
            simd_float4 fill = {1.0f, 0.85f, 0.20f, 0.22f};
            verts.push_back({{x0, -1.0f}, fill});
            verts.push_back({{x1, -1.0f}, fill});
            verts.push_back({{x1,  1.0f}, fill});
            verts.push_back({{x0, -1.0f}, fill});
            verts.push_back({{x1,  1.0f}, fill});
            verts.push_back({{x0,  1.0f}, fill});

            // Bright edge bars so handles are visible even when zoomed out.
            float ew = 3.0f / std::max<float>(1.0f, (float)self.drawableSize.width);
            simd_float4 edge = {1.0f, 0.85f, 0.20f, 0.95f};
            verts.push_back({{x0 - ew, -1.0f}, edge});
            verts.push_back({{x0 + ew, -1.0f}, edge});
            verts.push_back({{x0 + ew,  1.0f}, edge});
            verts.push_back({{x0 - ew, -1.0f}, edge});
            verts.push_back({{x0 + ew,  1.0f}, edge});
            verts.push_back({{x0 - ew,  1.0f}, edge});
            verts.push_back({{x1 - ew, -1.0f}, edge});
            verts.push_back({{x1 + ew, -1.0f}, edge});
            verts.push_back({{x1 + ew,  1.0f}, edge});
            verts.push_back({{x1 - ew, -1.0f}, edge});
            verts.push_back({{x1 + ew,  1.0f}, edge});
            verts.push_back({{x1 - ew,  1.0f}, edge});
        }
    }

    // Bookmarks: yellow vertical lines (numbered flags drawn separately as text overlay).
    double durForBM = _engine ? _engine->duration() : 0.0;
    if (durForBM > 0.0 && _bookmarks.count > 0) {
        float bw = 2.0f / std::max<float>(1.0f, (float)self.drawableSize.width);
        simd_float4 bcol = {1.0f, 0.92f, 0.30f, 0.85f};
        for (NSDictionary* d in _bookmarks) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            double t = [d[@"time"] doubleValue];
            double tFrac = t / durForBM;
            double tView = (tFrac - _viewStart) / span;
            if (tView < 0.0 || tView > 1.0) continue;
            float x = -1.0f + 2.0f * (float)tView;
            verts.push_back({{x - bw, -1.0f}, bcol});
            verts.push_back({{x + bw, -1.0f}, bcol});
            verts.push_back({{x + bw,  1.0f}, bcol});
            verts.push_back({{x - bw, -1.0f}, bcol});
            verts.push_back({{x + bw,  1.0f}, bcol});
            verts.push_back({{x - bw,  1.0f}, bcol});
        }
    }

    // Playhead: thicker bright bar + downward triangle at the top.
    double dur = _engine ? _engine->duration() : 0.0;
    if (dur > 0.0) {
        double tFrac = _engine->currentTime() / dur;
        double tView = (tFrac - _viewStart) / span;
        if (tView >= 0.0 && tView <= 1.0) {
        float x = -1.0f + 2.0f * (float)tView;
        // ~2px wide line.
        float w = 2.0f / std::max<float>(1.0f, (float)self.drawableSize.width);
        simd_float4 col = {1.00f, 0.42f, 0.32f, 1.0f};
        verts.push_back({{x - w, -1.0f}, col});
        verts.push_back({{x + w, -1.0f}, col});
        verts.push_back({{x + w,  1.0f}, col});
        verts.push_back({{x - w, -1.0f}, col});
        verts.push_back({{x + w,  1.0f}, col});
        verts.push_back({{x - w,  1.0f}, col});

        // Downward triangle marker at the top (~10px tall, ~12px wide).
        float halfX = 12.0f / std::max<float>(1.0f, (float)self.drawableSize.width);
        float h     = 20.0f / std::max<float>(1.0f, (float)self.drawableSize.height);
        verts.push_back({{x - halfX,  1.0f}, col});
        verts.push_back({{x + halfX,  1.0f}, col});
        verts.push_back({{x,          1.0f - h}, col});
        }
    }

    if (!verts.empty()) {
        size_t bytes = verts.size() * sizeof(Vertex);
        // setVertexBytes is limited to 4KB; use a buffer for anything larger.
        if (bytes <= 4096) {
            [enc setVertexBytes:verts.data() length:bytes atIndex:0];
        } else {
            id<MTLBuffer> buf = [_device newBufferWithBytes:verts.data()
                                                      length:bytes
                                                     options:MTLResourceStorageModeShared];
            [enc setVertexBuffer:buf offset:0 atIndex:0];
        }
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:verts.size()];
    }

    [enc endEncoding];
    [cb presentDrawable:self.currentDrawable];
    [cb commit];
}

- (double)secondsAtPoint:(NSPoint)p {
    double xFrac = std::clamp(p.x / self.bounds.size.width, 0.0, 1.0);
    double frac = _viewStart + xFrac * (_viewEnd - _viewStart);
    return frac * _engine->duration();
}

- (void)scrollWheel:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) return;

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    double xFrac = std::clamp(p.x / self.bounds.size.width, 0.0, 1.0);
    double anchor = _viewStart + xFrac * (_viewEnd - _viewStart);

    double dy = event.scrollingDeltaY;
    double dx = event.scrollingDeltaX;
    double sensY = event.hasPreciseScrollingDeltas ? 0.005 : 0.10;
    double sensX = event.hasPreciseScrollingDeltas ? 0.002 : 0.05;

    constexpr double kMinSpan = 0.005;  // ~200x max zoom

    if (std::abs(dy) >= std::abs(dx)) {
        // Vertical wheel → zoom around cursor.
        double factor = std::exp(-dy * sensY);
        double oldSpan = _viewEnd - _viewStart;
        double newSpan = std::clamp(oldSpan * factor, kMinSpan, 1.0);
        _viewStart = anchor - xFrac * newSpan;
        _viewEnd   = _viewStart + newSpan;
    } else {
        // Horizontal wheel → pan.
        double curSpan = _viewEnd - _viewStart;
        double shift = -dx * sensX * curSpan;
        _viewStart += shift;
        _viewEnd   += shift;
    }

    // Clamp into [0, 1] without changing the span.
    if (_viewStart < 0.0) { _viewEnd -= _viewStart; _viewStart = 0.0; }
    if (_viewEnd   > 1.0) { _viewStart -= (_viewEnd - 1.0); _viewEnd = 1.0; }
    if (_viewStart < 0.0) _viewStart = 0.0;
    if (_viewEnd   > 1.0) _viewEnd   = 1.0;

    [self syncOverlays];
}

- (void)loopEdgesScreenX:(CGFloat*)leftX rightX:(CGFloat*)rightX {
    *leftX = NAN; *rightX = NAN;
    double dur = _engine ? _engine->duration() : 0.0;
    if (dur <= 0.0 || !_engine->hasLoop()) return;
    double sr = _engine->sampleRate();
    double ls = _engine->loopStartFrame() / sr;
    double le = _engine->loopEndFrame() / sr;
    double span = std::max(1e-9, _viewEnd - _viewStart);
    double lsV = (ls / dur - _viewStart) / span;
    double leV = (le / dur - _viewStart) / span;
    *leftX = (CGFloat)(lsV * self.bounds.size.width);
    *rightX = (CGFloat)(leV * self.bounds.size.width);
}

- (LoopHit)hitTestLoopAtX:(CGFloat)x {
    CGFloat l, r;
    [self loopEdgesScreenX:&l rightX:&r];
    if (std::isnan(l) || std::isnan(r)) return LoopHitNone;
    constexpr CGFloat kEdgeRadius = 12.0;
    BOOL nearLeft = std::abs(x - l) <= kEdgeRadius;
    BOOL nearRight = std::abs(x - r) <= kEdgeRadius;
    if (nearLeft && nearRight) {
        // Pick whichever is closer.
        return (std::abs(x - l) <= std::abs(x - r)) ? LoopHitLeft : LoopHitRight;
    }
    if (nearLeft) return LoopHitLeft;
    if (nearRight) return LoopHitRight;
    if (x > l && x < r) return LoopHitInside;
    return LoopHitNone;
}

- (void)mouseMoved:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) {
        [[NSCursor arrowCursor] set];
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    // Don't override cursor over the timeline ruler.
    if (p.y > self.bounds.size.height - 22.0) {
        [[NSCursor arrowCursor] set];
        return;
    }
    LoopHit h = [self hitTestLoopAtX:p.x];
    switch (h) {
        case LoopHitLeft:
        case LoopHitRight: [[NSCursor resizeLeftRightCursor] set]; break;
        case LoopHitInside: [[NSCursor openHandCursor] set]; break;
        default: [[NSCursor crosshairCursor] set]; break;
    }
}

- (void)mouseExited:(NSEvent*)event {
    [[NSCursor arrowCursor] set];
}

- (void)mouseDown:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) return;
    if (event.clickCount >= 2) {
        _engine->clearLoop();
        _dragMode = DragNone;
        return;
    }

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _dragStartPoint = p;
    _dragStartCursorSec = [self secondsAtPoint:p];
    _dragAnchorSec = _dragStartCursorSec;

    // Option+drag → pan view (don't seek/loop).
    if (event.modifierFlags & NSEventModifierFlagOption) {
        _dragMode = DragPan;
        _dragStartViewStart = _viewStart;
        _dragStartViewEnd = _viewEnd;
        [[NSCursor closedHandCursor] set];
        return;
    }

    LoopHit h = [self hitTestLoopAtX:p.x];
    if (h != LoopHitNone) {
        double sr = _engine->sampleRate();
        _dragStartLoopStartSec = _engine->loopStartFrame() / sr;
        _dragStartLoopEndSec = _engine->loopEndFrame() / sr;
        switch (h) {
            case LoopHitLeft:
                _dragMode = DragResizeLeft;
                [[NSCursor resizeLeftRightCursor] set];
                break;
            case LoopHitRight:
                _dragMode = DragResizeRight;
                [[NSCursor resizeLeftRightCursor] set];
                break;
            case LoopHitInside:
                _dragMode = DragMoveLoop;
                [[NSCursor closedHandCursor] set];
                break;
            default: break;
        }
        return;
    }

    _dragMode = DragSeek;
    _engine->seek(_dragStartCursorSec);
}

- (void)mouseDragged:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) return;
    constexpr double kMinLoop = 0.05;
    double dur = _engine->duration();

    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    double here = [self secondsAtPoint:p];

    switch (_dragMode) {
        case DragSeek: {
            // Promote to new-loop drag if user has actually moved.
            double a = std::min(_dragAnchorSec, here);
            double b = std::max(_dragAnchorSec, here);
            if (b - a < kMinLoop) return;
            _dragMode = DragNewLoop;
            _engine->setLoop(a, b);
            break;
        }
        case DragNewLoop: {
            double a = std::min(_dragAnchorSec, here);
            double b = std::max(_dragAnchorSec, here);
            if (b - a < kMinLoop) return;
            _engine->setLoop(a, b);
            break;
        }
        case DragResizeLeft: {
            double newStart = std::clamp(here, 0.0, _dragStartLoopEndSec - kMinLoop);
            _engine->setLoop(newStart, _dragStartLoopEndSec);
            break;
        }
        case DragResizeRight: {
            double newEnd = std::clamp(here, _dragStartLoopStartSec + kMinLoop, dur);
            _engine->setLoop(_dragStartLoopStartSec, newEnd);
            break;
        }
        case DragMoveLoop: {
            double delta = here - _dragStartCursorSec;
            double len = _dragStartLoopEndSec - _dragStartLoopStartSec;
            double newStart = std::clamp(_dragStartLoopStartSec + delta, 0.0, dur - len);
            _engine->setLoop(newStart, newStart + len);
            break;
        }
        case DragPan: {
            double w = std::max<double>(1.0, self.bounds.size.width);
            double dx = (p.x - _dragStartPoint.x) / w;
            double span = _dragStartViewEnd - _dragStartViewStart;
            double shift = -dx * span;
            double s = _dragStartViewStart + shift;
            double e = _dragStartViewEnd + shift;
            if (s < 0.0) { e -= s; s = 0.0; }
            if (e > 1.0) { s -= (e - 1.0); e = 1.0; }
            if (s < 0.0) s = 0.0;
            if (e > 1.0) e = 1.0;
            _viewStart = s;
            _viewEnd = e;
            [self syncOverlays];
            break;
        }
        default: break;
    }
}

- (void)mouseUp:(NSEvent*)event {
    _dragMode = DragNone;
    // Reset cursor based on current position.
    if (event) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        if (p.x >= 0 && p.x <= self.bounds.size.width &&
            p.y >= 0 && p.y <= self.bounds.size.height) {
            LoopHit h = [self hitTestLoopAtX:p.x];
            switch (h) {
                case LoopHitLeft:
                case LoopHitRight: [[NSCursor resizeLeftRightCursor] set]; break;
                case LoopHitInside: [[NSCursor openHandCursor] set]; break;
                default: [[NSCursor crosshairCursor] set]; break;
            }
        }
    }
}

@end
