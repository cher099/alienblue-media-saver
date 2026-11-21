#import <Foundation/Foundation.h>

// Returns cached player HTML, loading HTML for an in-progress job, or nil
// when the caller must resolve a media URL and call again to start processing.
NSString *RGPlaybackHTMLForVideo(NSString *videoID, NSString *mediaURL, NSString *userAgent);
