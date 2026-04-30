#import <Foundation/Foundation.h>

@class BasicPitchTranscriber;

@protocol BasicPitchTranscriberDelegate <NSObject>
- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t progress:(double)frac;
- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t
            didFinishWithMIDI:(NSString*)midiPath
                    sourceTag:(NSString*)tag;
- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t
             didFailWithError:(NSString*)message;
@optional
- (void)basicPitchTranscriber:(BasicPitchTranscriber*)t stage:(NSString*)message;
@end

// Wraps the Spotify Basic Pitch helper at tools/transcribe-helper/. Resolves
// the helper directory at init time and reuses the bundled Python interpreter
// + stem-helper site-packages (basic-pitch is installed there to share heavy
// shared deps like numpy/scipy).
//
// Public methods are main-thread-safe; delegate callbacks fire on the main
// queue. Only one transcription can run at a time per instance.
@interface BasicPitchTranscriber : NSObject

@property (nonatomic, weak) id<BasicPitchTranscriberDelegate> delegate;
@property (nonatomic, readonly) BOOL isHelperAvailable;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, copy) NSString* helperDir;

- (instancetype)init;

// Transcribes `inputPath` into `outputPath` (.mid). `tag` is an opaque
// identifier echoed back in the finish callback so callers can correlate
// concurrent requests (e.g. "vocals" / "bass" stem name).
- (void)transcribeFile:(NSString*)inputPath
                toMIDI:(NSString*)outputPath
                   tag:(NSString*)tag;

- (void)cancel;

@end
