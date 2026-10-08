#import <Foundation/Foundation.h>

@class ChordRecognizer;
@protocol ChordRecognizerDelegate <NSObject>
- (void)chordRecognizer:(ChordRecognizer*)recognizer progress:(double)fraction;
- (void)chordRecognizer:(ChordRecognizer*)recognizer stage:(NSString*)message;
- (void)chordRecognizer:(ChordRecognizer*)recognizer
   didFinishWithChords:(NSArray<NSDictionary*>*)chords tempo:(double)tempo;
- (void)chordRecognizer:(ChordRecognizer*)recognizer didFailWithError:(NSString*)message;
@end

@interface ChordRecognizer : NSObject
@property (nonatomic, weak) id<ChordRecognizerDelegate> delegate;
@property (nonatomic, readonly) BOOL isHelperAvailable;
@property (nonatomic, readonly) BOOL isRunning;
- (void)recognizeFile:(NSString*)path;
- (void)cancel;
@end
