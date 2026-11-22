#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns RedAlien's native video-player page for a cached video, loading HTML for an
// in-progress job, or nil when the caller must resolve a media URL and call again.
NSString *RGPlaybackHTMLForVideo(NSString *videoID, NSString *mediaURL, NSString *userAgent);

// Saves a cached RedGIFs MP4 or a regular RedAlien video file to the iOS Camera Roll.
void RGSaveVideoToPhotos(NSString *videoID);
void RGSaveVideoAtPathToPhotos(NSString *videoPath, NSString *sourceID);

// Downloads and saves one or more still images. Raw GIF image data is preserved.
void RGSaveImageURLsToPhotos(NSArray *imageURLs, NSString *sourceID);

#ifdef __cplusplus
}
#endif
