#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns RedAlien's native video-player page for a cached video, loading HTML for an
// in-progress job, or nil when the caller must resolve a media URL and call again.
NSString *RGPlaybackHTMLForVideo(NSString *videoID, NSString *mediaURL, NSString *userAgent);

// Saves an already-cached RedGIFs MP4 to the iOS Camera Roll.
void RGSaveVideoToPhotos(NSString *videoID);

#ifdef __cplusplus
}
#endif
