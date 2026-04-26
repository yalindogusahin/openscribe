#import <Foundation/Foundation.h>

@class StemSeparator;

@protocol StemSeparatorDelegate <NSObject>
- (void)stemSeparator:(StemSeparator*)sep progress:(double)frac;
- (void)stemSeparator:(StemSeparator*)sep
   didFinishWithStemPaths:(NSArray<NSString*>*)paths;
- (void)stemSeparator:(StemSeparator*)sep didFailWithError:(NSString*)message;
@end

// Wraps the offline htdemucs helper at tools/stem-helper/. Resolves a helper
// directory at init time (env var → walk up from app bundle → dev fallback)
// and exposes per-file cached output under
// ~/Library/Application Support/OpenScribe/stems/<sha256>/.
//
// All public methods are main-thread-safe; delegate callbacks fire on the main
// queue. Stem path arrays are returned in engine index order:
// [vocals, drums, bass, other].
@interface StemSeparator : NSObject

@property (nonatomic, weak) id<StemSeparatorDelegate> delegate;
@property (nonatomic, readonly) BOOL isHelperAvailable;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, copy) NSString* helperDir;

- (instancetype)init;

- (NSArray<NSString*>*)cachedStemPathsForFile:(NSString*)inputPath;
- (BOOL)hasCachedStemsForFile:(NSString*)inputPath;

- (void)separateFile:(NSString*)inputPath;
- (void)cancel;

@end
