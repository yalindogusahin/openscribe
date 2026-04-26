#import <Foundation/Foundation.h>

@class StemSeparator;

// One result entry: human-readable stem name (e.g. "vocals") + absolute path
// to the WAV file. The array's order is the order to feed to the audio engine
// and to render in the mixer UI.
@interface StemSeparation : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* path;
@end

@protocol StemSeparatorDelegate <NSObject>
- (void)stemSeparator:(StemSeparator*)sep progress:(double)frac;
- (void)stemSeparator:(StemSeparator*)sep
   didFinishWithStems:(NSArray<StemSeparation*>*)stems
                model:(NSString*)model;
- (void)stemSeparator:(StemSeparator*)sep didFailWithError:(NSString*)message;
@optional
// Helper announces a coarse phase (e.g. "Loading model", "Separating",
// "Writing stems") so the UI can show *something* during long stretches
// where the inner tqdm doesn't tick (e.g. RoFormer single-shot inference).
- (void)stemSeparator:(StemSeparator*)sep stage:(NSString*)message;
@end

// Wraps the offline htdemucs helper at tools/stem-helper/. Resolves a helper
// directory at init time (env var → walk up from app bundle → dev fallback)
// and exposes per-(file, model) cached output under
// ~/Library/Application Support/OpenScribe/stems/<sha256>/<model>/.
//
// All public methods are main-thread-safe; delegate callbacks fire on the
// main queue. The result array is in the order chosen by the helper's
// stems.json manifest (vocals first, "other" last by convention).
@interface StemSeparator : NSObject

@property (nonatomic, weak) id<StemSeparatorDelegate> delegate;
@property (nonatomic, readonly) BOOL isHelperAvailable;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, copy) NSString* helperDir;

- (instancetype)init;

- (BOOL)hasCachedStemsForFile:(NSString*)inputPath model:(NSString*)model;
- (NSArray<StemSeparation*>*)cachedStemsForFile:(NSString*)inputPath
                                          model:(NSString*)model;

- (void)separateFile:(NSString*)inputPath model:(NSString*)model;
- (void)cancel;

@end
