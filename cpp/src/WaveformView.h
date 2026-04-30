#import <MetalKit/MetalKit.h>

#include <vector>

class AudioEngine;

@interface WaveformView : MTKView
- (instancetype)initWithFrame:(NSRect)frame engine:(AudioEngine*)engine;
- (void)reloadFromEngine;

// Bookmarks: array of NSDictionary entries with keys "time" (NSNumber seconds)
// and "label" (NSString, possibly empty). Set by app delegate.
@property (nonatomic, copy) NSArray<NSDictionary*>* bookmarks;

// Click handlers for bookmark badges in the labels overlay.
@property (nonatomic, copy) void (^bookmarkJumpHandler)(NSInteger index);
@property (nonatomic, copy) void (^bookmarkRenameHandler)(NSInteger index);
@property (nonatomic, copy) void (^bookmarkRemoveHandler)(NSInteger index);

// View window accessors (fraction of duration, 0..1).
- (double)viewStart;
- (double)viewEnd;
- (void)setViewStart:(double)start end:(double)end;

@property (nonatomic, copy) void (^fileDropHandler)(NSString* path);

// Stem name array for label overlays (one per lane). Pass nil/empty to revert
// to single-waveform mode. Triggers a peak recompute + redraw.
- (void)setStemNames:(NSArray<NSString*>*)names;

// Color used for the lane at `idx` (0-based). Falls back to a palette when
// `name` doesn't match a known stem. Exposed so other UI (sidebar mixer)
// can tint labels to match the waveform lanes.
+ (NSColor*)nsStemColorForIndex:(int)idx name:(NSString*)name;

// MIDI piano-roll overlay. Notes are drawn inside the matching stem's lane,
// pitch-mapped to the lane's vertical extent (auto-fit per stem). `notes` is
// an array of dicts with keys: "start" (sec), "end" (sec), "pitch" (MIDI 0..127),
// "velocity" (0..1). Pass nil/empty array to clear notes for that stem.
- (void)setMIDINotes:(NSArray<NSDictionary*>*)notes forStemName:(NSString*)stemName;
- (void)clearAllMIDINotes;
@end
