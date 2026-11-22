#import "RedAlienMedia.h"
#import <UIKit/UIKit.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <pthread.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdarg.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <string.h>

static NSString * const RGRoot = @"/var/tmp/redalien";
static NSString * const RASupport = @"/Library/Application Support/RedAlien";
static NSMutableSet *RGBusy = nil;
static NSMutableSet *RGAssetSaveBusy = nil;
static ALAssetsLibrary *RGAssetsLibraryInstance = nil;

static void RGMediaWriteLog(NSString *path, NSData *data) {
    int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    const unsigned char *bytes = [data bytes];
    NSUInteger left = [data length];
    while (left) {
        ssize_t count = write(fd, bytes, left);
        if (count <= 0) break;
        bytes += count;
        left -= (NSUInteger)count;
    }
    close(fd);
}

static void RGMediaLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [Media] %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized([NSString class]) {
        NSString *directory = @"/var/mobile/Library/Logs";
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        RGMediaWriteLog(@"/var/mobile/Library/Logs/RedGIFsCompat.log", data);
        RGMediaWriteLog(@"/tmp/RedGIFsCompat.log", data);
    }
    NSLog(@"[RedGIFsCompat][Media] %@", message);
}
#define RGLOG(fmt, ...) RGMediaLog((fmt), ##__VA_ARGS__)

@interface RGDownloader : NSObject {
    NSFileHandle *_file;
    NSError *_error;
    BOOL _done;
    unsigned long long _size;
}
- (id)initWithPath:(NSString *)path;
- (BOOL)done;
- (NSError *)error;
- (unsigned long long)size;
- (void)finish:(NSError *)error;
@end

@implementation RGDownloader
- (id)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        _file = [[NSFileHandle fileHandleForWritingAtPath:path] retain];
        if (!_file) {
            _error = [[NSError errorWithDomain:@"RedGIFsCompat" code:1
                userInfo:[NSDictionary dictionaryWithObject:@"Cannot create download file" forKey:NSLocalizedDescriptionKey]] retain];
            _done = YES;
        }
    }
    return self;
}
- (BOOL)done { return _done; }
- (NSError *)error { return _error; }
- (unsigned long long)size { return _size; }
- (void)finish:(NSError *)error {
    if (_done) return;
    if (_file) {
        @try { [_file synchronizeFile]; } @catch (NSException *e) { (void)e; }
        [_file closeFile]; [_file release]; _file = nil;
    }
    if (error && !_error) _error = [error retain];
    _done = YES;
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        RGLOG(@"Download HTTP response=%ld expected=%lld", (long)code, (long long)[response expectedContentLength]);
        if (code < 200 || code >= 300) {
            NSError *error = [NSError errorWithDomain:@"RedGIFsCompat" code:code
                userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Media server returned HTTP %ld", (long)code]
                                                      forKey:NSLocalizedDescriptionKey]];
            [self finish:error]; [connection cancel];
        }
    }
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (_done || !_file) return;
    if (_size == 0) RGLOG(@"Download received first data chunk (%lu bytes)", (unsigned long)[data length]);
    if (_size + [data length] > 150ULL * 1024ULL * 1024ULL) {
        NSError *error = [NSError errorWithDomain:@"RedGIFsCompat" code:2
            userInfo:[NSDictionary dictionaryWithObject:@"Video exceeds 150 MB safety limit" forKey:NSLocalizedDescriptionKey]];
        [self finish:error]; [connection cancel]; return;
    }
    @try { [_file writeData:data]; _size += [data length]; }
    @catch (NSException *e) {
        NSError *error = [NSError errorWithDomain:@"RedGIFsCompat" code:3
            userInfo:[NSDictionary dictionaryWithObject:[e reason] ?: @"Disk write failed" forKey:NSLocalizedDescriptionKey]];
        [self finish:error]; [connection cancel];
    }
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { RGLOG(@"Download completed: %llu bytes", _size); [self finish:nil]; }
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { RGLOG(@"Download connection failed: %@", error); [self finish:error]; }
- (void)dealloc {
    if (_file) { [_file closeFile]; [_file release]; }
    [_error release]; [super dealloc];
}
@end

static NSString *RGDir(NSString *videoID) {
    NSString *path = [RGRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"redgifs-%@", videoID]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error] && error) {
        RGLOG(@"Directory creation failed: %@", error); return nil;
    }
    return path;
}
static BOOL RGValidMP4(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return NO;
    NSData *data = [file readDataOfLength:16]; [file closeFile];
    if ([data length] < 12) return NO;
    const unsigned char *b = [data bytes];
    return b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p';
}
static void RGStatus(NSString *dir, NSInteger progress, NSString *message, BOOL error) {
    NSDictionary *value = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInteger:progress], @"progress", message ?: @"Working...", @"text",
        [NSNumber numberWithBool:error], @"error", nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return;
    NSString *json = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [[NSString stringWithFormat:@"window.statusData = %@;", json]
        writeToFile:[dir stringByAppendingPathComponent:@"status.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *RGQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static BOOL RGDownload(NSString *urlString, NSString *path, NSString *userAgent, NSError **outError) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = [[NSError errorWithDomain:@"RedGIFsCompat" code:4
            userInfo:[NSDictionary dictionaryWithObject:@"Invalid MP4 URL" forKey:NSLocalizedDescriptionKey]] retain];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    RGDownloader *delegate = [[RGDownloader alloc] initWithPath:path];
    if ([delegate done]) {
        if (outError) *outError = [[delegate error] retain];
        [delegate release]; return NO;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:userAgent.length ? userAgent :
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25"
        forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"https://www.redgifs.com/" forHTTPHeaderField:@"Referer"];
    RGLOG(@"Starting media download URL host=%@ path=%@", url.host, url.path);
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:delegate startImmediately:NO];
    if (!connection) {
        if (outError) *outError = [[NSError errorWithDomain:@"RedGIFsCompat" code:5
            userInfo:[NSDictionary dictionaryWithObject:@"Cannot create download connection" forKey:NSLocalizedDescriptionKey]] retain];
        [delegate release]; return NO;
    }
    [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 240.0;
    while (![delegate done] && [NSDate timeIntervalSinceReferenceDate] < deadline)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    if (![delegate done]) {
        NSError *timeout = [NSError errorWithDomain:@"RedGIFsCompat" code:6
            userInfo:[NSDictionary dictionaryWithObject:@"Media download timed out" forKey:NSLocalizedDescriptionKey]];
        [delegate finish:timeout]; [connection cancel];
    }
    BOOL ok = ![delegate error] && [delegate size] > 12;
    RGLOG(@"Download result=%@ bytes=%llu error=%@", ok ? @"success" : @"failure", [delegate size], [delegate error]);
    if (!ok && outError) *outError = [[delegate error] retain];
    [connection cancel]; [connection release]; [delegate release];
    if (!ok) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return ok;
}
static BOOL RGRunFFmpeg(NSString *input, NSString *output, NSString *log) {
    // RedAlien already depends on the FFmpeg package and invokes its "ffmpeg" executable.
    NSString *cmd = [NSString stringWithFormat:
        @"ffmpeg -nostdin -hide_banner -loglevel warning -y -i %@ -c copy -movflags +faststart -f mp4 %@ 2> %@",
        RGQuote(input), RGQuote(output), RGQuote(log)];
    const char *command = [cmd UTF8String];
    if (!command) { RGLOG(@"FFmpeg command could not be encoded"); return NO; }
    RGLOG(@"Starting FFmpeg input=%@ output=%@ log=%@", input, output, log);
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) { dup2(fd, STDOUT_FILENO); close(fd); }
        execl("/bin/sh", "sh", "-c", command, (char *)NULL); _exit(127);
    }
    if (pid < 0) { RGLOG(@"FFmpeg fork failed: errno=%d", errno); return NO; }
    int status = 0; pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    BOOL exited = result == pid && WIFEXITED(status);
    int exitCode = exited ? WEXITSTATUS(status) : -1;
    BOOL ok = exited && exitCode == 0;
    NSString *fflog = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
    if (!ok && fflog.length > 3000) fflog = [fflog substringFromIndex:fflog.length - 3000];
    RGLOG(@"FFmpeg finished result=%@ exit=%d waitResult=%d log=%@", ok ? @"success" : @"failure", exitCode, (int)result, fflog ?: @"(no ffmpeg log)");
    return ok;
}

static BOOL RGRunFFmpegRedGIFsPhotoTranscode(NSString *input, NSString *output, NSString *log) {
    // Save-only transcode: MPEG-4 Part 2 Simple Profile + AAC-LC in MP4.
    // These are built-in FFmpeg encoders used by the upstream RedAlien
    // compatibility path; do not require optional libx264/libfdk-aac builds.
    NSString *filter = @"fps=30,scale='if(gte(iw,ih),min(640,iw),-2)':'if(gte(iw,ih),-2,min(640,ih))',setsar=1";
    NSString *cmd = [NSString stringWithFormat:
        @"ffmpeg -nostdin -hide_banner -loglevel warning -y -i %@ "
         "-map 0:v:0 -map 0:a:0? -vf %@ -sws_flags fast_bilinear "
         "-c:v mpeg4 -profile:v 0 -q:v 5 -pix_fmt yuv420p "
         "-c:a aac -b:a 128k -ac 2 -ar 44100 -tag:v mp4v "
         "-movflags +faststart -f mp4 %@ 2> %@",
        RGQuote(input), RGQuote(filter), RGQuote(output), RGQuote(log)];
    const char *command = [cmd UTF8String];
    if (!command) {
        RGLOG(@"RedGIFs Photo transcode command could not be encoded");
        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:log error:nil];
    RGLOG(@"Starting RedGIFs save-only FFmpeg transcode input=%@ output=%@ log=%@",
          input, output, log);

    pid_t pid = fork();
    if (pid == 0) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) { dup2(fd, STDOUT_FILENO); close(fd); }
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) {
        RGLOG(@"RedGIFs Photo transcode fork failed: errno=%d", errno);
        return NO;
    }

    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    BOOL exited = result == pid && WIFEXITED(status);
    int exitCode = exited ? WEXITSTATUS(status) : -1;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:output error:nil];
    unsigned long long outputSize = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    BOOL ok = exited && exitCode == 0 && outputSize > 12 && RGValidMP4(output);

    NSString *fflog = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
    if (fflog.length > 3000) fflog = [fflog substringFromIndex:fflog.length - 3000];
    RGLOG(@"RedGIFs Photo transcode finished result=%@ exit=%d waitResult=%d outputSize=%llu log=%@",
          ok ? @"success" : @"failure", exitCode, (int)result, outputSize,
          fflog ?: @"(no ffmpeg log)");

    if (!ok) [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    return ok;
}

static NSString *RGTemplate(NSString *name) {
    return [NSString stringWithContentsOfFile:[RASupport stringByAppendingPathComponent:name]
                                      encoding:NSUTF8StringEncoding error:nil];
}
static NSString *RGLoadingHTML(NSString *videoID) {
    NSString *html = RGTemplate(@"vLoading.html");
    NSString *statusURL = [NSString stringWithFormat:@"https://v.redd.it/redgifs-%@/status.js", videoID];
    return html ? [html stringByReplacingOccurrencesOfString:@"{{STATUS_URL}}" withString:statusURL]
                : @"<html><body>Preparing RedGIFs video...</body></html>";
}

static ALAssetsLibrary *RGGetAssetsLibrary(void) {
    @synchronized([NSObject class]) {
        if (!RGAssetsLibraryInstance) {
            RGAssetsLibraryInstance = [[ALAssetsLibrary alloc] init];
        }
        return RGAssetsLibraryInstance;
    }
}

static BOOL RGBeginAssetSave(NSString *key) {
    if (!key.length) return NO;
    @synchronized([NSObject class]) {
        if (!RGAssetSaveBusy) RGAssetSaveBusy = [[NSMutableSet alloc] init];
        if ([RGAssetSaveBusy containsObject:key]) {
            RGLOG(@"Photo-library save already in progress: %@", key);
            return NO;
        }
        [RGAssetSaveBusy addObject:key];
    }
    return YES;
}

static void RGEndAssetSave(NSString *key) {
    @synchronized([NSObject class]) {
        [RGAssetSaveBusy removeObject:key];
    }
}

static NSMutableSet *RGUIKitVideoSaveTargets = nil;
static NSMutableSet *RGRedGIFsExportSaveTargets = nil;

static UIView *RGPhotoSaveHUD = nil;
static UILabel *RGPhotoSaveHUDLabel = nil;
static UIProgressView *RGPhotoSaveHUDProgress = nil;
static UIActivityIndicatorView *RGPhotoSaveHUDSpinner = nil;

// The HUD is deliberately non-blocking: gallery progress can be watched while
// AlienBlue remains usable. A count-based bar is used for sequential image
// batches; videos show a spinner because AssetsLibrary does not expose progress.
static void RGShowPhotoSaveProgress(NSString *message, NSUInteger total) {
    NSString *messageCopy = [(message ?: @"Saving to Photos…") copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (window && !RGPhotoSaveHUD) {
            CGFloat windowWidth = window.bounds.size.width;
            CGFloat hudWidth = MIN(300.0, windowWidth - 20.0);
            CGFloat hudX = (windowWidth - hudWidth) / 2.0;
            RGPhotoSaveHUD = [[UIView alloc] initWithFrame:CGRectMake(hudX, 26.0, hudWidth, 70.0)];
            RGPhotoSaveHUD.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
            RGPhotoSaveHUD.userInteractionEnabled = NO;
            RGPhotoSaveHUD.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                UIViewAutoresizingFlexibleRightMargin;

            RGPhotoSaveHUDLabel = [[UILabel alloc] initWithFrame:CGRectMake(10.0, 7.0, hudWidth - 20.0, 31.0)];
            RGPhotoSaveHUDLabel.backgroundColor = [UIColor clearColor];
            RGPhotoSaveHUDLabel.textColor = [UIColor whiteColor];
            RGPhotoSaveHUDLabel.font = [UIFont systemFontOfSize:14.0];
            RGPhotoSaveHUDLabel.textAlignment = NSTextAlignmentCenter;
            RGPhotoSaveHUDLabel.numberOfLines = 2;
            [RGPhotoSaveHUD addSubview:RGPhotoSaveHUDLabel];
            [RGPhotoSaveHUDLabel release];

            RGPhotoSaveHUDProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            RGPhotoSaveHUDProgress.frame = CGRectMake(18.0, 48.0, hudWidth - 36.0, 9.0);
            [RGPhotoSaveHUD addSubview:RGPhotoSaveHUDProgress];
            [RGPhotoSaveHUDProgress release];

            RGPhotoSaveHUDSpinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
            RGPhotoSaveHUDSpinner.frame = CGRectMake((hudWidth - 24.0) / 2.0, 42.0, 24.0, 24.0);
            RGPhotoSaveHUDSpinner.hidesWhenStopped = YES;
            [RGPhotoSaveHUD addSubview:RGPhotoSaveHUDSpinner];
            [RGPhotoSaveHUDSpinner release];
            [window addSubview:RGPhotoSaveHUD];
        } else if (window && RGPhotoSaveHUD.superview != window) {
            [RGPhotoSaveHUD removeFromSuperview];
            [window addSubview:RGPhotoSaveHUD];
        }

        if (RGPhotoSaveHUDLabel) RGPhotoSaveHUDLabel.text = messageCopy;
        if (total > 0) {
            RGPhotoSaveHUDProgress.hidden = NO;
            RGPhotoSaveHUDSpinner.hidden = YES;
            [RGPhotoSaveHUDSpinner stopAnimating];
            [RGPhotoSaveHUDProgress setProgress:0.0f animated:NO];
        } else {
            RGPhotoSaveHUDProgress.hidden = YES;
            RGPhotoSaveHUDSpinner.hidden = NO;
            [RGPhotoSaveHUDSpinner startAnimating];
        }
        [messageCopy release];
    });
}

static void RGUpdatePhotoSaveProgress(NSString *message, NSUInteger completed, NSUInteger total) {
    NSString *messageCopy = [(message ?: @"Saving to Photos…") copy];
    CGFloat value = total ? MIN(1.0f, (CGFloat)completed / (CGFloat)total) : 0.0f;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RGPhotoSaveHUDLabel) RGPhotoSaveHUDLabel.text = messageCopy;
        if (RGPhotoSaveHUDProgress && total > 0) {
            RGPhotoSaveHUDProgress.hidden = NO;
            [RGPhotoSaveHUDProgress setProgress:value animated:YES];
        }
        [messageCopy release];
    });
}

static void RGFinishPhotoSaveProgress(NSString *title, NSString *message) {
    NSString *titleCopy = [(title ?: @"Save to Photos Finished") copy];
    NSString *messageCopy = [(message ?: @"The save operation has finished.") copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RGPhotoSaveHUD) {
            [RGPhotoSaveHUD removeFromSuperview];
            [RGPhotoSaveHUD release];
            RGPhotoSaveHUD = nil;
            RGPhotoSaveHUDLabel = nil;
            RGPhotoSaveHUDProgress = nil;
            RGPhotoSaveHUDSpinner = nil;
        }

        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:titleCopy
            message:messageCopy delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alert show];
        [alert release];

        [titleCopy release];
        [messageCopy release];
    });
}

static void RGStartRedGIFsAVExportFallback(NSString *sourcePath, NSString *saveKey, NSString *sourceID);
static void RGStartRedGIFsFFmpegSaveFallback(NSString *sourcePath, NSString *saveKey, NSString *sourceID);
static void RGSavePreparedRedGIFsVideoAtPath(NSString *path, NSString *saveKey, NSString *sourceID);

@interface RGUIKitVideoSaveTarget : NSObject {
    NSString *_saveKey;
    NSString *_sourceID;
}
- (id)initWithSaveKey:(NSString *)saveKey sourceID:(NSString *)sourceID;
- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo;
@end

@implementation RGUIKitVideoSaveTarget
- (id)initWithSaveKey:(NSString *)saveKey sourceID:(NSString *)sourceID {
    self = [super init];
    if (self) {
        _saveKey = [saveKey copy];
        _sourceID = [(sourceID ?: @"(unknown)") copy];
    }
    return self;
}
- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        RGLOG(@"UIKit fallback video save failed source=%@ path=%@: %@ (domain=%@ code=%ld)",
              _sourceID, videoPath, error, [error domain], (long)[error code]);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video",
            [NSString stringWithFormat:@"The video couldn't be saved: %@", [error localizedDescription] ?: @"iOS reported an error."]);
    } else {
        RGLOG(@"UIKit fallback video save completed without error source=%@ path=%@",
              _sourceID, videoPath);
        RGFinishPhotoSaveProgress(@"Saved to Photos", @"The video was saved to your Camera Roll.");
    }

    RGEndAssetSave(_saveKey);
    // Keep the target alive while removing the set's retaining reference.
    [self retain];
    @synchronized([NSObject class]) {
        [RGUIKitVideoSaveTargets removeObject:self];
    }
    [self release];
}
- (void)dealloc {
    [_saveKey release];
    [_sourceID release];
    [super dealloc];
}
@end

@interface RGRedGIFsExportSaveTarget : NSObject {
    AVAssetExportSession *_exportSession;
    NSString *_outputPath;
    NSString *_saveKey;
    NSString *_sourceID;
}
- (id)initWithSourcePath:(NSString *)sourcePath saveKey:(NSString *)saveKey sourceID:(NSString *)sourceID;
- (void)setExportSession:(AVAssetExportSession *)session outputPath:(NSString *)path;
- (void)start;
- (void)exportDidFinish;
@end

@implementation RGRedGIFsExportSaveTarget
- (id)initWithSourcePath:(NSString *)sourcePath saveKey:(NSString *)saveKey sourceID:(NSString *)sourceID {
    self = [super init];
    if (self) {
        _saveKey = [saveKey copy];
        _sourceID = [(sourceID ?: @"(unknown)") copy];

        NSString *directory = [sourcePath stringByDeletingLastPathComponent];
        _outputPath = [[directory stringByAppendingPathComponent:@"camera-roll.mp4"] copy];
    }
    return self;
}
- (void)setExportSession:(AVAssetExportSession *)session outputPath:(NSString *)path {
    [_exportSession release];
    _exportSession = [session retain];
    [_outputPath release];
    _outputPath = [path copy];
}
- (void)start {
    [_exportSession exportAsynchronouslyWithCompletionHandler:^{
        [self exportDidFinish];
    }];
}
- (void)exportDidFinish {
    AVAssetExportSessionStatus status = [_exportSession status];
    NSError *error = [_exportSession error];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_outputPath error:nil];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];

    if (status == AVAssetExportSessionStatusCompleted && size > 12) {
        RGLOG(@"RedGIFs Camera Roll compatibility export completed source=%@ path=%@ size=%llu",
              _sourceID, _outputPath, size);
        RGSavePreparedRedGIFsVideoAtPath(_outputPath, _saveKey, _sourceID);
    } else {
        RGLOG(@"RedGIFs Camera Roll compatibility export failed source=%@ status=%ld path=%@ size=%llu error=%@",
              _sourceID, (long)status, _outputPath, size, error);
        RGEndAssetSave(_saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video",
            [NSString stringWithFormat:@"RedGIFs couldn't be prepared for Photos: %@", [error localizedDescription] ?: @"video export failed."]);
    }

    [self retain];
    @synchronized([NSObject class]) {
        [RGRedGIFsExportSaveTargets removeObject:self];
    }
    [self release];
}
- (void)dealloc {
    [_exportSession release];
    [_outputPath release];
    [_saveKey release];
    [_sourceID release];
    [super dealloc];
}
@end

static void RGStartUIKitVideoSaveFallback(NSString *path, NSString *saveKey, NSString *sourceID) {
    BOOL compatible = UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path);
    RGLOG(@"UIKit fallback compatibility source=%@ path=%@ compatible=%@; attempting save regardless",
          sourceID ?: @"(unknown)", path, compatible ? @"YES" : @"NO");

    // On legacy iOS, the compatibility probe can be overly restrictive for
    // otherwise playable MP4 files. Let the save API return the definitive
    // result instead of skipping the attempt based on this probe.
    RGUIKitVideoSaveTarget *target = [[RGUIKitVideoSaveTarget alloc]
        initWithSaveKey:saveKey sourceID:sourceID];
    @synchronized([NSObject class]) {
        if (!RGUIKitVideoSaveTargets) RGUIKitVideoSaveTargets = [[NSMutableSet alloc] init];
        [RGUIKitVideoSaveTargets addObject:target];
    }

    RGLOG(@"Trying UIKit video-save fallback source=%@ path=%@",
          sourceID ?: @"(unknown)", path);
    UISaveVideoAtPathToSavedPhotosAlbum(path, target,
        @selector(video:didFinishSavingWithError:contextInfo:), NULL);
    [target release];
}

static void RGSavePreparedRedGIFsVideoAtPath(NSString *path, NSString *saveKey, NSString *sourceID) {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    ALAssetsLibrary *library = RGGetAssetsLibrary();
    RGLOG(@"Trying AssetsLibrary with RedGIFs compatibility export source=%@ path=%@",
          sourceID ?: @"(unknown)", path);

    [library writeVideoAtPathToSavedPhotosAlbum:fileURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (!error && assetURL) {
            RGLOG(@"RedGIFs compatibility export saved through AssetsLibrary source=%@ path=%@ assetURL=%@",
                  sourceID ?: @"(unknown)", path, assetURL);
            RGEndAssetSave(saveKey);
            RGFinishPhotoSaveProgress(@"Saved to Photos", @"The RedGIFs video was saved to your Camera Roll.");
        } else {
            RGLOG(@"RedGIFs compatibility export AssetsLibrary save failed source=%@ path=%@ assetURL=%@ error=%@; trying UIKit",
                  sourceID ?: @"(unknown)", path, assetURL, error);
            RGUpdatePhotoSaveProgress(@"Finishing video save…", 0, 0);
            RGStartUIKitVideoSaveFallback(path, saveKey, sourceID);
        }
    }];
}


static void RGSaveFFmpegPreparedRedGIFsVideoAtPath(NSString *path,
                                                    NSString *originalPath,
                                                    NSString *saveKey,
                                                    NSString *sourceID) {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    ALAssetsLibrary *library = RGGetAssetsLibrary();
    RGLOG(@"Trying AssetsLibrary with FFmpeg-transcoded RedGIFs save copy source=%@ path=%@",
          sourceID ?: @"(unknown)", path);

    [library writeVideoAtPathToSavedPhotosAlbum:fileURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (!error && assetURL) {
            RGLOG(@"FFmpeg-transcoded RedGIFs video saved through AssetsLibrary source=%@ path=%@ assetURL=%@",
                  sourceID ?: @"(unknown)", path, assetURL);
            RGEndAssetSave(saveKey);
            RGFinishPhotoSaveProgress(@"Saved to Photos", @"The RedGIFs video was transcoded with FFmpeg and saved to your Camera Roll.");
        } else {
            RGLOG(@"FFmpeg-transcoded RedGIFs save copy rejected by AssetsLibrary source=%@ path=%@ assetURL=%@ error=%@; trying AVFoundation on original",
                  sourceID ?: @"(unknown)", path, assetURL, error);
            RGUpdatePhotoSaveProgress(@"Trying iOS video converter…", 0, 0);
            RGStartRedGIFsAVExportFallback(originalPath, saveKey, sourceID);
        }
    }];
}

static void RGStartRedGIFsFFmpegSaveFallback(NSString *sourcePath, NSString *saveKey, NSString *sourceID) {
    if (![sourceID hasPrefix:@"redgifs:"]) {
        RGLOG(@"FFmpeg Photo transcode refused for non-RedGIFs source=%@", sourceID ?: @"(unknown)");
        RGEndAssetSave(saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video", @"FFmpeg conversion is only enabled for RedGIFs saves.");
        return;
    }

    NSString *directory = [sourcePath stringByDeletingLastPathComponent];
    NSString *outputPath = [directory stringByAppendingPathComponent:@"camera-roll-ffmpeg.mp4"];
    NSString *logPath = [directory stringByAppendingPathComponent:@"camera-roll-ffmpeg.log"];
    NSString *sourceCopy = [sourcePath copy];
    NSString *outputCopy = [outputPath copy];
    NSString *logCopy = [logPath copy];
    NSString *keyCopy = [saveKey copy];
    NSString *idCopy = [sourceID copy];

    RGUpdatePhotoSaveProgress(@"Transcoding RedGIFs for Photos with FFmpeg…", 0, 0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        BOOL ok = RGRunFFmpegRedGIFsPhotoTranscode(sourceCopy, outputCopy, logCopy);
        if (ok) {
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:outputCopy error:nil];
            unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
            RGLOG(@"RedGIFs FFmpeg save copy ready source=%@ path=%@ size=%llu",
                  idCopy ?: @"(unknown)", outputCopy, size);
            RGSaveFFmpegPreparedRedGIFsVideoAtPath(outputCopy, sourceCopy, keyCopy, idCopy);
        } else {
            RGLOG(@"RedGIFs FFmpeg save transcode failed; falling back to AVFoundation source=%@ input=%@",
                  idCopy ?: @"(unknown)", sourceCopy);
            RGUpdatePhotoSaveProgress(@"FFmpeg conversion unavailable; trying iOS converter…", 0, 0);
            RGStartRedGIFsAVExportFallback(sourceCopy, keyCopy, idCopy);
        }
        [sourceCopy release];
        [outputCopy release];
        [logCopy release];
        [keyCopy release];
        [idCopy release];
        [pool drain];
    });
}

static void RGStartRedGIFsAVExportFallback(NSString *sourcePath, NSString *saveKey, NSString *sourceID) {
    if (![sourceID hasPrefix:@"redgifs:"]) {
        RGLOG(@"Compatibility export refused for non-RedGIFs source=%@", sourceID ?: @"(unknown)");
        RGEndAssetSave(saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video", @"This video could not be prepared for Camera Roll.");
        return;
    }

    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    NSArray *presets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSString *preset = [presets containsObject:AVAssetExportPreset640x480] ?
        AVAssetExportPreset640x480 :
        ([presets containsObject:AVAssetExportPresetMediumQuality] ? AVAssetExportPresetMediumQuality : nil);
    if (!preset) {
        RGLOG(@"RedGIFs compatibility export unavailable: no 640x480/medium preset source=%@ presets=%@",
              sourceID, presets);
        RGEndAssetSave(saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video", @"This RedGIFs video cannot be converted to a Camera Roll format on this device.");
        return;
    }

    RGRedGIFsExportSaveTarget *target = [[RGRedGIFsExportSaveTarget alloc]
        initWithSourcePath:sourcePath saveKey:saveKey sourceID:sourceID];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    if (!exporter) {
        RGLOG(@"RedGIFs compatibility export could not create AVAssetExportSession source=%@ preset=%@",
              sourceID, preset);
        [target release];
        RGEndAssetSave(saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video", @"iOS could not prepare this RedGIFs video for Camera Roll.");
        return;
    }

    NSArray *fileTypes = [exporter supportedFileTypes];
    NSString *fileType = [fileTypes containsObject:AVFileTypeMPEG4] ? AVFileTypeMPEG4 :
        ([fileTypes containsObject:AVFileTypeQuickTimeMovie] ? AVFileTypeQuickTimeMovie : nil);
    if (!fileType) {
        RGLOG(@"RedGIFs compatibility export has no MP4/MOV output type source=%@ supported=%@",
              sourceID, fileTypes);
        [exporter release];
        [target release];
        RGEndAssetSave(saveKey);
        RGFinishPhotoSaveProgress(@"Couldn't Save Video", @"This device cannot create a Camera Roll copy of the RedGIFs video.");
        return;
    }

    NSString *outputPath = [[sourcePath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:[fileType isEqualToString:AVFileTypeMPEG4] ? @"camera-roll.mp4" : @"camera-roll.mov"];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    [target setExportSession:exporter outputPath:outputPath];

    [exporter setOutputURL:[NSURL fileURLWithPath:outputPath]];
    [exporter setOutputFileType:fileType];
    [exporter setShouldOptimizeForNetworkUse:YES];

    @synchronized([NSObject class]) {
        if (!RGRedGIFsExportSaveTargets) RGRedGIFsExportSaveTargets = [[NSMutableSet alloc] init];
        [RGRedGIFsExportSaveTargets addObject:target];
    }

    RGLOG(@"Starting RedGIFs-only Camera Roll compatibility export source=%@ preset=%@ outputType=%@ input=%@ output=%@",
          sourceID, preset, fileType, sourcePath, outputPath);
    RGUpdatePhotoSaveProgress(@"Preparing RedGIFs video for Camera Roll…", 0, 0);
    [exporter release];
    [target start];
    [target release];
}

void RGSaveVideoAtPathToPhotos(NSString *videoPath, NSString *sourceID) {
    if (!videoPath.length || ![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
        RGLOG(@"Video Save to Photos failed: file does not exist path=%@", videoPath ?: @"(nil)");
        return;
    }

    NSString *resolvedPath = [videoPath stringByResolvingSymlinksInPath];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:resolvedPath error:nil];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    if (size < 12) {
        RGLOG(@"Video Save to Photos rejected an empty/invalid file path=%@ size=%llu", resolvedPath, size);
        return;
    }

    NSString *key = [NSString stringWithFormat:@"video:%@", resolvedPath];
    if (!RGBeginAssetSave(key)) return;

    RGShowPhotoSaveProgress(@"Saving video to Photos…", 0);
    ALAssetsLibrary *library = RGGetAssetsLibrary();
    NSURL *fileURL = [NSURL fileURLWithPath:resolvedPath];
    BOOL assetsLibraryCompatible = [library videoAtPathIsCompatibleWithSavedPhotosAlbum:fileURL];
    BOOL uiKitCompatible = UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(resolvedPath);
    RGLOG(@"Video compatibility source=%@ path=%@ size=%llu AssetsLibrary=%@ UIKit=%@",
          sourceID ?: @"(unknown)", resolvedPath, size,
          assetsLibraryCompatible ? @"YES" : @"NO", uiKitCompatible ? @"YES" : @"NO");
    RGLOG(@"Submitting video to iOS Camera Roll: source=%@ path=%@ size=%llu",
          sourceID ?: @"(unknown)", resolvedPath, size);

    [library writeVideoAtPathToSavedPhotosAlbum:fileURL completionBlock:^(NSURL *assetURL, NSError *error) {
        BOOL isRedGIFs = [sourceID hasPrefix:@"redgifs:"];
        if (error) {
            RGLOG(@"Camera Roll video save failed source=%@ path=%@: %@ (domain=%@ code=%ld)",
                  sourceID ?: @"(unknown)", resolvedPath, error, [error domain], (long)[error code]);
            if (isRedGIFs) {
                // RedGIFs MP4s are rejected by both native compatibility checks
                // on this legacy device. Transcode a separate save-only copy now.
                RGLOG(@"RedGIFs source MP4 rejected by AssetsLibrary; starting save-only FFmpeg transcode source=%@ path=%@",
                      sourceID, resolvedPath);
                RGUpdatePhotoSaveProgress(@"Transcoding RedGIFs for Photos with FFmpeg…", 0, 0);
                RGStartRedGIFsFFmpegSaveFallback(resolvedPath, key, sourceID);
            } else {
                RGEndAssetSave(key);
                RGFinishPhotoSaveProgress(@"Couldn't Save Video",
                    [NSString stringWithFormat:@"The video couldn't be saved: %@", [error localizedDescription] ?: @"iOS reported an error."]);
            }
        } else if (assetURL) {
            RGLOG(@"Camera Roll video save succeeded source=%@ path=%@ assetURL=%@",
                  sourceID ?: @"(unknown)", resolvedPath, assetURL);
            RGEndAssetSave(key);
            RGFinishPhotoSaveProgress(@"Saved to Photos", @"The video was saved to your Camera Roll.");
        } else if (isRedGIFs) {
            // On this iOS 6 device, the AssetsLibrary callback returns nil URL
            // and nil NSError for RedGIFs files that do not actually get saved.
            // A UIKit nil-error callback was also a false positive, so skip that
            // redundant attempt and convert a separate Camera Roll copy instead.
            RGLOG(@"RedGIFs AssetsLibrary returned nil assetURL without NSError; bypassing UIKit false-positive path and starting save-only FFmpeg transcode source=%@ path=%@ AssetsLibraryCompatible=%@ UIKitCompatible=%@",
                  sourceID ?: @"(unknown)", resolvedPath,
                  assetsLibraryCompatible ? @"YES" : @"NO", uiKitCompatible ? @"YES" : @"NO");
            RGUpdatePhotoSaveProgress(@"Transcoding RedGIFs for Photos with FFmpeg…", 0, 0);
            RGStartRedGIFsFFmpegSaveFallback(resolvedPath, key, sourceID);
        } else {
            // Preserve the behavior that worked for regular Reddit videos on
            // AlienBlue/iOS 6: a nil assetURL with no NSError is not a failure
            // signal we can rely on for this legacy runtime.
            RGLOG(@"Regular Reddit video save callback completed without NSError; preserving legacy success behavior source=%@ path=%@ assetURL=(nil)",
                  sourceID ?: @"(unknown)", resolvedPath);
            RGEndAssetSave(key);
            RGFinishPhotoSaveProgress(@"Saved to Photos", @"The video was saved to your Camera Roll.");
        }
    }];
}

void RGSaveVideoToPhotos(NSString *videoID) {
    if (!videoID.length) return;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if ([videoID rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        RGLOG(@"RedGIFs photo save rejected invalid video ID");
        return;
    }

    NSString *cachePath = [RGDir(videoID) stringByAppendingPathComponent:@"video.mp4"];
    if (!RGValidMP4(cachePath)) {
        RGLOG(@"RedGIFs Save to Photos requested before a valid cached MP4 exists: %@ path=%@", videoID, cachePath);
        return;
    }

    RGSaveVideoAtPathToPhotos(cachePath, [@"redgifs:" stringByAppendingString:videoID]);
}

static NSData *RGDownloadImageData(NSString *urlString, NSError **outError) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !([url.scheme.lowercaseString isEqualToString:@"http"] ||
                  [url.scheme.lowercaseString isEqualToString:@"https"])) {
        if (outError) *outError = [NSError errorWithDomain:@"RedGIFsCompat" code:20
            userInfo:[NSDictionary dictionaryWithObject:@"Invalid image URL" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25"
        forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [request setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];

    NSError *error = nil;
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    if (error || !data.length) {
        if (outError) *outError = error ?: [NSError errorWithDomain:@"RedGIFsCompat" code:21
            userInfo:[NSDictionary dictionaryWithObject:@"Image download returned no data" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status < 200 || status >= 300) {
            if (outError) *outError = [NSError errorWithDomain:@"RedGIFsCompat" code:status
                userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Image server returned HTTP %ld", (long)status]
                                                      forKey:NSLocalizedDescriptionKey]];
            return nil;
        }
    }

    if ([data length] > 60ULL * 1024ULL * 1024ULL) {
        if (outError) *outError = [NSError errorWithDomain:@"RedGIFsCompat" code:22
            userInfo:[NSDictionary dictionaryWithObject:@"Image exceeds 60 MB safety limit" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }

    const unsigned char *bytes = (const unsigned char *)[data bytes];
    BOOL isGIF = [data length] >= 6 &&
        ((!memcmp(bytes, "GIF87a", 6)) || (!memcmp(bytes, "GIF89a", 6)));
    UIImage *image = isGIF ? nil : [UIImage imageWithData:data];
    if (!image && !isGIF) {
        if (outError) *outError = [NSError errorWithDomain:@"RedGIFsCompat" code:23
            userInfo:[NSDictionary dictionaryWithObject:@"Downloaded data is not a supported image or GIF" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    return data;
}

static void RGSaveImageURLAtIndex(NSArray *urls, NSUInteger index, NSString *batchKey,
                                  NSString *sourceID, NSMutableDictionary *stats) {
    if (index >= [urls count]) {
        NSUInteger saved = [[stats objectForKey:@"saved"] unsignedIntegerValue];
        NSUInteger failed = [[stats objectForKey:@"failed"] unsignedIntegerValue];
        NSUInteger total = [urls count];
        RGLOG(@"Image batch save finished source=%@ count=%lu saved=%lu failed=%lu",
              sourceID ?: @"(unknown)", (unsigned long)total,
              (unsigned long)saved, (unsigned long)failed);
        RGEndAssetSave(batchKey);

        if (failed == 0) {
            RGFinishPhotoSaveProgress(@"Saved to Photos",
                [NSString stringWithFormat:@"All %lu photos were saved to your Camera Roll.", (unsigned long)saved]);
        } else if (saved == 0) {
            RGFinishPhotoSaveProgress(@"Couldn't Save Photos",
                [NSString stringWithFormat:@"None of the %lu photos could be saved.", (unsigned long)total]);
        } else {
            RGFinishPhotoSaveProgress(@"Save Finished",
                [NSString stringWithFormat:@"Saved %lu of %lu photos. %lu couldn't be saved.",
                    (unsigned long)saved, (unsigned long)total, (unsigned long)failed]);
        }
        return;
    }

    RGUpdatePhotoSaveProgress(
        [NSString stringWithFormat:@"Saving photo %lu of %lu…",
            (unsigned long)(index + 1), (unsigned long)[urls count]],
        index, [urls count]);

    NSString *urlString = [urls objectAtIndex:index];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSError *downloadError = nil;
        NSData *downloaded = RGDownloadImageData(urlString, &downloadError);
        if (!downloaded) {
            RGLOG(@"Image download failed source=%@ url=%@: %@",
                  sourceID ?: @"(unknown)", urlString, downloadError);
            NSUInteger failed = [[stats objectForKey:@"failed"] unsignedIntegerValue] + 1;
            [stats setObject:[NSNumber numberWithUnsignedInteger:failed] forKey:@"failed"];
            RGUpdatePhotoSaveProgress(
                [NSString stringWithFormat:@"Processed %lu of %lu photos…",
                    (unsigned long)(index + 1), (unsigned long)[urls count]],
                index + 1, [urls count]);
            RGSaveImageURLAtIndex(urls, index + 1, batchKey, sourceID, stats);
            [pool drain];
            return;
        }

        NSData *imageData = [downloaded retain];
        ALAssetsLibrary *library = RGGetAssetsLibrary();
        RGLOG(@"Submitting image to Camera Roll source=%@ item=%lu/%lu url=%@ bytes=%lu",
              sourceID ?: @"(unknown)", (unsigned long)(index + 1), (unsigned long)[urls count],
              urlString, (unsigned long)[imageData length]);

        [library writeImageDataToSavedPhotosAlbum:imageData metadata:nil completionBlock:^(NSURL *assetURL, NSError *error) {
            if (error) {
                RGLOG(@"Camera Roll image save failed source=%@ url=%@: %@ (domain=%@ code=%ld)",
                      sourceID ?: @"(unknown)", urlString, error, [error domain], (long)[error code]);
                NSUInteger failed = [[stats objectForKey:@"failed"] unsignedIntegerValue] + 1;
                [stats setObject:[NSNumber numberWithUnsignedInteger:failed] forKey:@"failed"];
            } else {
                RGLOG(@"Camera Roll image save succeeded source=%@ url=%@ assetURL=%@",
                      sourceID ?: @"(unknown)", urlString, assetURL);
                NSUInteger saved = [[stats objectForKey:@"saved"] unsignedIntegerValue] + 1;
                [stats setObject:[NSNumber numberWithUnsignedInteger:saved] forKey:@"saved"];
            }
            NSUInteger completed = index + 1;
            RGUpdatePhotoSaveProgress(
                [NSString stringWithFormat:@"Processed %lu of %lu photos…",
                    (unsigned long)completed, (unsigned long)[urls count]],
                completed, [urls count]);
            [imageData release];
            RGSaveImageURLAtIndex(urls, index + 1, batchKey, sourceID, stats);
        }];
        [pool drain];
    });
}

void RGSaveImageURLsToPhotos(NSArray *imageURLs, NSString *sourceID) {
    if (![imageURLs isKindOfClass:[NSArray class]] || ![imageURLs count]) {
        RGLOG(@"Image Save to Photos requested with no image URLs source=%@", sourceID ?: @"(unknown)");
        return;
    }

    NSMutableArray *cleanURLs = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id value in imageURLs) {
        if (![value isKindOfClass:[NSString class]]) continue;
        NSString *url = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *parsed = [NSURL URLWithString:url];
        if (!parsed || !([parsed.scheme.lowercaseString isEqualToString:@"http"] ||
                         [parsed.scheme.lowercaseString isEqualToString:@"https"])) continue;
        if ([seen containsObject:url]) continue;
        [seen addObject:url];
        [cleanURLs addObject:url];
    }

    if (![cleanURLs count]) {
        RGLOG(@"Image Save to Photos found no usable HTTP image URLs source=%@", sourceID ?: @"(unknown)");
        return;
    }

    NSString *batchKey = [NSString stringWithFormat:@"images:%@:%@", sourceID ?: @"gallery",
                          [[NSProcessInfo processInfo] globallyUniqueString]];
    if (!RGBeginAssetSave(batchKey)) return;

    NSArray *urlCopy = [cleanURLs copy];
    NSString *sourceCopy = [(sourceID ?: @"gallery") copy];
    RGLOG(@"Starting image batch Save to Photos source=%@ count=%lu",
          sourceCopy, (unsigned long)[urlCopy count]);
    NSMutableDictionary *stats = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInteger:0], @"saved",
        [NSNumber numberWithUnsignedInteger:0], @"failed", nil];
    RGShowPhotoSaveProgress(
        [NSString stringWithFormat:@"Saving 0 of %lu photos…", (unsigned long)[urlCopy count]],
        [urlCopy count]);
    RGSaveImageURLAtIndex(urlCopy, 0, batchKey, sourceCopy, stats);
    [urlCopy release];
    [sourceCopy release];
}

static void *RGWorker(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *info = (NSDictionary *)arg;
    NSString *videoID = [info objectForKey:@"id"];
    NSString *mediaURL = [info objectForKey:@"url"];
    NSString *userAgent = [info objectForKey:@"ua"];
    RGLOG(@"Worker started for video=%@", videoID);
    NSString *dir = RGDir(videoID);
    RGLOG(@"Cache directory=%@", dir ?: @"(nil)");
    NSString *source = [dir stringByAppendingPathComponent:@"source.mp4"];
    NSString *temp = [dir stringByAppendingPathComponent:@"temp.mp4"];
    NSString *final = [dir stringByAppendingPathComponent:@"video.mp4"];
    NSString *log = [dir stringByAppendingPathComponent:@"ffmpeg.log"];
    NSError *downloadError = nil;
    BOOL ok = dir && RGDownload(mediaURL, source, userAgent, &downloadError);
    if (!dir) {
        RGLOG(@"Could not prepare cache directory for %@", videoID);
    } else if (!ok) {
        RGLOG(@"Download failed for %@: %@", videoID, downloadError);
        RGStatus(dir, 0, [NSString stringWithFormat:@"Download failed: %@", [downloadError localizedDescription] ?: @"unknown error"], YES);
    } else {
        NSDictionary *sourceAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:source error:nil];
        RGLOG(@"Downloaded source path=%@ size=%llu", source, [[sourceAttributes objectForKey:NSFileSize] unsignedLongLongValue]);
        RGStatus(dir, 35, @"Preparing video with RedAlien FFmpeg...", NO);
        [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
        ok = RGRunFFmpeg(source, temp, log) && RGValidMP4(temp);
        if (ok) {
            [[NSFileManager defaultManager] removeItemAtPath:final error:nil];
            NSError *moveError = nil;
            ok = [[NSFileManager defaultManager] moveItemAtPath:temp toPath:final error:&moveError];
            if (!ok) RGLOG(@"Final MP4 move failed: %@", moveError);
        }
        if (ok) {
            [[NSFileManager defaultManager] removeItemAtPath:source error:nil];
            RGStatus(dir, 100, @"Done!", NO);
            NSDictionary *finalAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:final error:nil];
            RGLOG(@"Cached RedGIFs MP4: %@ size=%llu valid=%@", final, [[finalAttributes objectForKey:NSFileSize] unsignedLongLongValue], RGValidMP4(final) ? @"YES" : @"NO");
        } else {
            [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
            RGLOG(@"Processing failed; tempExists=%@ tempValid=%@", [[NSFileManager defaultManager] fileExistsAtPath:temp] ? @"YES" : @"NO", RGValidMP4(temp) ? @"YES" : @"NO");
            RGStatus(dir, 0, @"FFmpeg could not create a valid MP4. Check ffmpeg.log.", YES);
        }
    }
    RGLOG(@"Worker finished for video=%@", videoID);
    [downloadError release];
    @synchronized([NSObject class]) { [RGBusy removeObject:videoID]; }
    [info release]; [pool drain]; return NULL;
}

NSString *RGPlaybackHTMLForVideo(NSString *videoID, NSString *mediaURL, NSString *userAgent) {
    if (!videoID.length) return nil;
    NSString *dir = RGDir(videoID);
    if (!dir) return nil;
    NSString *video = [dir stringByAppendingPathComponent:@"video.mp4"];
    if (RGValidMP4(video)) {
        RGLOG(@"Cached video found id=%@ path=%@", videoID, video);
        Class serverClass = NSClassFromString(@"HTTPServer");
        SEL portSelector = NSSelectorFromString(@"currentPort");
        NSInteger port = (serverClass && [serverClass respondsToSelector:portSelector]) ?
            ((NSInteger (*)(id, SEL))objc_msgSend)(serverClass, portSelector) : 0;
        if (port <= 0) {
            RGLOG(@"RedAlien HTTPServer is not ready; cannot build the native player URL");
            return RGLoadingHTML(videoID);
        }
        NSString *videoPath = [video stringByReplacingOccurrencesOfString:@"/private" withString:@""];
        NSString *videoURL = [NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)port, videoPath];
        NSString *player = RGTemplate(@"vPlayer.html");
        if (player.length) {
            RGLOG(@"Using RedAlien vPlayer.html for RedGIFs %@ at port %ld", videoID, (long)port);
            return [player stringByReplacingOccurrencesOfString:@"{{VIDEO_URL}}" withString:videoURL];
        }
        RGLOG(@"RedAlien vPlayer.html is missing; using a minimal HTML5 video fallback");
        return [NSString stringWithFormat:
            @"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0;background:#000'><video controls='controls' autoplay='autoplay' style='width:100%%;height:100%%' src='%@'></video></body></html>",
            videoURL];
    }
    @synchronized([NSObject class]) {
        if (!RGBusy) RGBusy = [[NSMutableSet alloc] init];
        if ([RGBusy containsObject:videoID]) { RGLOG(@"Video %@ already processing; returning loading HTML", videoID); return RGLoadingHTML(videoID); }
        if (!mediaURL.length) return nil;
        [RGBusy addObject:videoID];
    }
    RGLOG(@"Queueing video=%@ mediaURLPresent=%@", videoID, mediaURL.length ? @"YES" : @"NO");
    RGStatus(dir, 1, @"Queued RedGIFs video...", NO);
    NSDictionary *info = [[NSDictionary alloc] initWithObjectsAndKeys:
        videoID, @"id", mediaURL, @"url", userAgent ?: @"", @"ua", nil];
    pthread_t thread;
    int result = pthread_create(&thread, NULL, RGWorker, info);
    if (result == 0) { pthread_detach(thread); RGLOG(@"Worker thread created for %@", videoID); }
    else {
        [info release];
        @synchronized([NSObject class]) { [RGBusy removeObject:videoID]; }
        RGStatus(dir, 0, @"Could not start video processing thread.", YES);
        RGLOG(@"pthread_create failed: %d", result);
    }
    NSString *loading = RGLoadingHTML(videoID);
    RGLOG(@"Returning loading template for %@; status URL=https://v.redd.it/redgifs-%@/status.js template=%@", videoID, videoID, RGTemplate(@"vLoading.html") ? @"loaded" : @"missing");
    return loading;
}
