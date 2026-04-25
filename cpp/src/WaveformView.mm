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

// Render at fixed peak resolution; rebinned to pixel width on draw.
constexpr int kPeakBins = 4096;
}

@interface WaveformView () {
    AudioEngine* _engine;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pso;
    std::vector<float> _peaksMin;
    std::vector<float> _peaksMax;
    BOOL _dragging;
    double _dragAnchorSec;
    // View window in [0, 1] of total duration.
    double _viewStart;
    double _viewEnd;
    TimelineRulerView* _ruler;
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

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0.07, 0.07, 0.08, 1.0);
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
    return self;
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
    [_ruler updateViewStart:_viewStart end:_viewEnd duration:_engine->duration()];
}

- (void)computePeaks {
    // AudioEngine samples are private; expose enough via duration + a peak
    // helper would be cleaner. For now, recompute by reading samples through
    // a friend-ish API: we'll skip if the file is empty.
    double dur = _engine->duration();
    if (dur <= 0.0) {
        _peaksMin.clear();
        _peaksMax.clear();
        return;
    }

    int64_t totalFrames = static_cast<int64_t>(dur * _engine->sampleRate());
    int bins = kPeakBins;
    _peaksMin.assign(bins, 0.0f);
    _peaksMax.assign(bins, 0.0f);

    // Pull samples via the engine's accessor (added below in AudioEngine).
    const float* s = _engine->samplesPtr();
    if (!s) return;

    int64_t framesPerBin = std::max<int64_t>(1, totalFrames / bins);
    for (int b = 0; b < bins; ++b) {
        int64_t start = b * framesPerBin;
        int64_t end = std::min<int64_t>(start + framesPerBin, totalFrames);
        float mn = 0.0f, mx = 0.0f;
        for (int64_t f = start; f < end; ++f) {
            float v = 0.5f * (s[f * 2 + 0] + s[f * 2 + 1]);
            if (v < mn) mn = v;
            if (v > mx) mx = v;
        }
        _peaksMin[b] = mn;
        _peaksMax[b] = mx;
    }
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
    verts.reserve(_peaksMin.size() * 6 + 6);

    const double span = std::max(1e-9, _viewEnd - _viewStart);

    // Waveform bars (two triangles per bin) — only iterate the visible range.
    int bins = static_cast<int>(_peaksMin.size());
    if (bins > 0) {
        simd_float4 col = {0.55f, 0.72f, 0.88f, 1.0f};
        int firstBin = std::max(0, (int)std::floor(_viewStart * bins));
        int lastBin  = std::min(bins, (int)std::ceil(_viewEnd  * bins));
        for (int b = firstBin; b < lastBin; ++b) {
            double bx0 = ((double)b      / bins - _viewStart) / span;
            double bx1 = ((double)(b + 1)/ bins - _viewStart) / span;
            float x0 = -1.0f + 2.0f * (float)bx0;
            float x1 = -1.0f + 2.0f * (float)bx1;
            float yMax = std::clamp(_peaksMax[b], -1.0f, 1.0f);
            float yMin = std::clamp(_peaksMin[b], -1.0f, 1.0f);
            // ensure visible thickness for silent regions
            if (yMax - yMin < 0.005f) {
                yMax += 0.0025f;
                yMin -= 0.0025f;
            }
            verts.push_back({{x0, yMin}, col});
            verts.push_back({{x1, yMin}, col});
            verts.push_back({{x1, yMax}, col});
            verts.push_back({{x0, yMin}, col});
            verts.push_back({{x1, yMax}, col});
            verts.push_back({{x0, yMax}, col});
        }
    }

    // Loop region (drawn behind playhead).
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
            simd_float4 col = {1.0f, 0.85f, 0.20f, 0.25f};
            verts.push_back({{x0, -1.0f}, col});
            verts.push_back({{x1, -1.0f}, col});
            verts.push_back({{x1,  1.0f}, col});
            verts.push_back({{x0, -1.0f}, col});
            verts.push_back({{x1,  1.0f}, col});
            verts.push_back({{x0,  1.0f}, col});
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

    [_ruler updateViewStart:_viewStart end:_viewEnd duration:_engine->duration()];
}

- (void)mouseDown:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) return;
    if (event.clickCount >= 2) {
        // Double-click clears any active loop.
        _engine->clearLoop();
        _dragging = NO;
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _dragAnchorSec = [self secondsAtPoint:p];
    _dragging = NO;
    _engine->seek(_dragAnchorSec);
}

- (void)mouseDragged:(NSEvent*)event {
    if (!_engine || _engine->duration() <= 0.0) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    double here = [self secondsAtPoint:p];
    double a = std::min(_dragAnchorSec, here);
    double b = std::max(_dragAnchorSec, here);
    // Need a minimum span so a tiny tremor doesn't create a 1-sample loop.
    if (b - a < 0.05) return;
    _dragging = YES;
    _engine->setLoop(a, b);
}

@end
