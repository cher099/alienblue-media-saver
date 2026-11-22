#import "RedAlienMedia.h"
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
static NSMutableSet *RGPhotoSaveBusy = nil;
static id RGPhotoLibrary = nil;

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
static BOOL RGProbeLocalFileServer(NSInteger port, NSString *path) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { RGLOG(@"Local server probe socket failed errno=%d", errno); return NO; }
    struct timeval timeout;
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        RGLOG(@"Local HTTP server unavailable at 127.0.0.1:%ld errno=%d", (long)port, errno);
        close(fd);
        return NO;
    }
    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.0\r\nRange: bytes=0-15\r\n\r\n", path];
    send(fd, [request UTF8String], strlen([request UTF8String]), 0);
    char response[1024] = {0};
    ssize_t received = recv(fd, response, sizeof(response) - 1, 0);
    close(fd);
    if (received > 0) {
        response[received] = 0;
        char *end = strchr(response, '\n');
        if (end) *end = 0;
        RGLOG(@"Local HTTP probe response: %s", response);
        return strstr(response, "200") != NULL || strstr(response, "206") != NULL;
    }
    RGLOG(@"Local HTTP server accepted connection but returned no response");
    return NO;
}

void RGSaveVideoToPhotos(NSString *videoID) {
    if (!videoID.length) return;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if ([videoID rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        RGLOG(@"Photo save rejected invalid video ID");
        return;
    }

    NSString *path = [RGDir(videoID) stringByAppendingPathComponent:@"video.mp4"];
    if (!RGValidMP4(path)) {
        RGLOG(@"Photo save requested before a valid cached MP4 exists: %@", videoID);
        return;
    }

    @synchronized([NSObject class]) {
        if (!RGPhotoSaveBusy) RGPhotoSaveBusy = [[NSMutableSet alloc] init];
        if ([RGPhotoSaveBusy containsObject:videoID]) {
            RGLOG(@"Photo save already in progress for %@", videoID);
            return;
        }
        [RGPhotoSaveBusy addObject:videoID];
        if (!RGPhotoLibrary) {
            Class libraryClass = NSClassFromString(@"ALAssetsLibrary");
            if (libraryClass) RGPhotoLibrary = [[libraryClass alloc] init];
        }
    }

    RGLOG(@"Saving cached video to Photos: %@", path);
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    SEL saveSelector = NSSelectorFromString(@"writeVideoAtPathToSavedPhotosAlbum:completionBlock:");
    if (!RGPhotoLibrary || ![RGPhotoLibrary respondsToSelector:saveSelector]) {
        RGLOG(@"Photos save unavailable: ALAssetsLibrary API not present");
        @synchronized([NSObject class]) { [RGPhotoSaveBusy removeObject:videoID]; }
        return;
    }
    ((void (*)(id, SEL, NSURL *, id))objc_msgSend)(RGPhotoLibrary, saveSelector, fileURL,
        ^(NSURL *assetURL, NSError *error) {
            if (error) {
                RGLOG(@"Photos save failed for %@: %@", videoID, error);
            } else {
                RGLOG(@"Photos save completed for %@ assetURL=%@", videoID, assetURL);
            }
            @synchronized([NSObject class]) {
                [RGPhotoSaveBusy removeObject:videoID];
            }
        });
}

static NSString *RGSaveHTML(NSString *path, NSString *videoID) {
    if (!RGValidMP4(path)) return nil;
    NSString *saveButton = [NSString stringWithFormat:
        @"<button id=\\"rg-save-photo\\" style=\\"padding:14px 20px;background:#1877d2;border:0;border-radius:7px;color:#fff;font:bold 16px Helvetica,Arial,sans-serif;\\" onclick=\\"this.innerHTML='Saving to Photos...';window.location.href='redgifscompat://save/%@';return false;\\">Save to Photos</button>",
        videoID];
    return [NSString stringWithFormat:
        @"<!doctype html><html><head><meta name=\\"viewport\\" content=\\"width=device-width,initial-scale=1\\"></head><body style=\\"margin:0;padding:28px 16px;background:#111;color:#fff;font:16px Helvetica,Arial,sans-serif;text-align:center;\\"><p style=\\"margin:8px 0 22px;\\">RedGIFs video is ready.</p>%@<p style=\\"margin-top:18px;color:#aaa;font-size:12px;\\">The video will be saved to your Camera Roll.</p></body></html>",
        saveButton];
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
    if (RGValidMP4(video)) { RGLOG(@"Cached video found id=%@ path=%@", videoID, video); return RGSaveHTML(video, videoID); }
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
