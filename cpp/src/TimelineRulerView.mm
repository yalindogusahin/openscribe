#import "TimelineRulerView.h"

#include <algorithm>
#include <cmath>

namespace {
double pickSpacing(double visibleSec) {
    // Aim for ~8 labels across the view; snap to readable values.
    static const double steps[] = {
        0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0
    };
    double target = visibleSec / 8.0;
    for (double s : steps) if (s >= target) return s;
    return 600.0;
}

NSString* formatTick(double t, double spacing) {
    int total = (int)std::floor(t);
    int m = total / 60;
    int s = total % 60;
    if (spacing < 1.0) {
        double frac = t - std::floor(t);
        return [NSString stringWithFormat:@"%d:%02d.%d", m, s, (int)std::round(frac * 10)];
    }
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}
}

@implementation TimelineRulerView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _viewStart = 0.0;
    _viewEnd = 1.0;
    _duration = 0.0;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.10 alpha:0.55].CGColor;
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)updateViewStart:(double)start end:(double)end duration:(double)dur {
    _viewStart = start;
    _viewEnd = end;
    _duration = dur;
    [self setNeedsDisplay:YES];
}

- (void)setViewStart:(double)v { _viewStart = v; [self setNeedsDisplay:YES]; }
- (void)setViewEnd:(double)v   { _viewEnd   = v; [self setNeedsDisplay:YES]; }
- (void)setDuration:(double)v  { _duration  = v; [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    if (_duration <= 0.0) return;
    double span = _viewEnd - _viewStart;
    if (span <= 1e-9) return;

    double tStart = _viewStart * _duration;
    double tEnd   = _viewEnd   * _duration;
    double visible = tEnd - tStart;

    double spacing = pickSpacing(visible);
    // Ticks at multiples of spacing within [tStart, tEnd].
    double firstTick = std::ceil(tStart / spacing) * spacing;

    NSColor* tickColor  = [NSColor colorWithWhite:0.55 alpha:1.0];
    NSColor* labelColor = [NSColor colorWithWhite:0.78 alpha:1.0];

    NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
                                                              weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: labelColor,
    };

    CGFloat width  = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat tickH = 5.0;

    [tickColor setStroke];
    NSBezierPath* path = [NSBezierPath bezierPath];
    path.lineWidth = 1.0;

    for (double t = firstTick; t <= tEnd + 1e-6; t += spacing) {
        double xFrac = (t / _duration - _viewStart) / span;
        if (xFrac < 0.0 || xFrac > 1.0) continue;
        CGFloat x = std::round((CGFloat)xFrac * width) + 0.5;

        // Tick at the bottom edge.
        [path moveToPoint:NSMakePoint(x, 0.0)];
        [path lineToPoint:NSMakePoint(x, tickH)];

        NSString* label = formatTick(t, spacing);
        NSSize sz = [label sizeWithAttributes:attrs];
        CGFloat lx = x - sz.width / 2.0;
        // Keep labels inside the bounds.
        lx = std::clamp(lx, (CGFloat)2.0, width - sz.width - 2.0);
        CGFloat ly = tickH + 1.0;
        if (ly + sz.height > height) ly = height - sz.height;
        [label drawAtPoint:NSMakePoint(lx, ly) withAttributes:attrs];
    }

    [path stroke];
}

// Pass clicks/scrolls through to the waveform underneath.
- (NSView*)hitTest:(NSPoint)point { return nil; }

@end
