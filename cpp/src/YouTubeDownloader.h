#import <Foundation/Foundation.h>

@class YouTubeDownloader;

@protocol YouTubeDownloaderDelegate <NSObject>
- (void)youtubeDownloader:(YouTubeDownloader*)dl progress:(double)frac;
- (void)youtubeDownloader:(YouTubeDownloader*)dl
       didFinishWithPath:(NSString*)audioPath
                   title:(NSString*)title;
- (void)youtubeDownloader:(YouTubeDownloader*)dl didFailWithError:(NSString*)message;
@optional
- (void)youtubeDownloader:(YouTubeDownloader*)dl stage:(NSString*)message;
@end

// Wraps the offline yt-dlp helper at tools/youtube-helper/. Resolves the
// helper directory at init time (env var → bundled → walk up from app bundle
// → dev fallback) and exposes a per-URL cache under
// ~/Library/Application Support/OpenScribe/youtube/<sha256>/.
//
// Public methods are main-thread-safe; delegate callbacks fire on the main
// queue.
@interface YouTubeDownloader : NSObject

@property (nonatomic, weak) id<YouTubeDownloaderDelegate> delegate;
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
