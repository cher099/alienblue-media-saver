#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns cached player HTML, loading HTML for an in-progress job, or nil
// when the caller must resolve a media URL and call again to start processing.
NSString *RGPlaybackHTMLForVideo(NSString *videoID, NSString *mediaURL, NSString *userAgent);

// Saves an already-cached RedGIFs MP4 to the iOS Camera Roll.
void RGSaveVideoToPhotos(NSString *videoID);

#ifdef __cplusplus
}
#endif
