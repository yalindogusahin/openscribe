#import <Foundation/Foundation.h>

@class MediaDownloader;

@protocol MediaDownloaderDelegate <NSObject>
- (void)mediaDownloader:(MediaDownloader*)dl progress:(double)frac;
- (void)mediaDownloader:(MediaDownloader*)dl
       didFinishWithPath:(NSString*)audioPath
                   title:(NSString*)title;
- (void)mediaDownloader:(MediaDownloader*)dl didFailWithError:(NSString*)message;
@optional
- (void)mediaDownloader:(MediaDownloader*)dl stage:(NSString*)message;
@end

// Wraps the offline yt-dlp helper at tools/media-helper/. Resolves the
// helper directory at init time (env var → bundled → walk up from app bundle
// → dev fallback) and exposes a per-URL cache under
// ~/Library/Application Support/OpenScribe/youtube/<sha256>/.
//
// Public methods are main-thread-safe; delegate callbacks fire on the main
// queue.
@interface MediaDownloader : NSObject

@property (nonatomic, weak) id<MediaDownloaderDelegate> delegate;
@property (nonatomic, readonly) BOOL isHelperAvailable;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, copy) NSString* helperDir;

- (instancetype)init;

// Returns the cached audio file path for url, or nil if no usable cache.
- (NSString*)cachedPathForURL:(NSString*)url;
- (NSString*)cachedTitleForURL:(NSString*)url;

- (void)downloadURL:(NSString*)url;
- (void)cancel;

@end
