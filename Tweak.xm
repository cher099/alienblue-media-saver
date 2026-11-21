#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

typedef BOOL (*RACanInitIMP)(id, SEL, NSURLRequest *);
typedef void (*RAPatchRequestIMP)(id, SEL, NSMutableURLRequest *);

static RACanInitIMP OriginalCanInitWithRequest = NULL;
static RAPatchRequestIMP OriginalPatchRequest = NULL;
static BOOL RGHooksInstalled = NO;

#import <stdarg.h>

static NSString * const RGLogPath = @"/var/mobile/Library/Logs/RedGIFsCompat.log";
static NSString * const RGLogDirectory = @"/var/mobile/Library/Logs";
static NSString * const RGFallbackLogPath = @"/tmp/RedGIFsCompat.log";

static void RGWriteLogFile(NSString *path, NSData *data) {
    int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSUInteger remaining = [data length];
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) break;
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    close(fd);
}

static void RGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [[NSDate date] description], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    @synchronized([NSString class]) {
        NSFileManager *manager = [NSFileManager defaultManager];
        if (![manager fileExistsAtPath:RGLogDirectory]) {
            [manager createDirectoryAtPath:RGLogDirectory
               withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // Write to both locations so a missing/unwritable Library/Logs folder
        // cannot hide whether MobileSubstrate loaded this tweak.
        RGWriteLogFile(RGLogPath, data);
        RGWriteLogFile(RGFallbackLogPath, data);
    }

    NSLog(@"[RedGIFsCompat] %@", message);
}

static NSString * const RGLogPrefix = @"[RedGIFsCompat] ";
static NSString * const RGAPIBase = @"https://api.redgifs.com/v2";
static NSString * const RGReferer = @"https://www.redgifs.com/";

static BOOL RGIsRedGIFsHost(NSString *host) {
    NSString *value = [host lowercaseString];
    return [value isEqualToString:@"redgifs.com"] ||
           [value isEqualToString:@"www.redgifs.com"];
}

static NSString *RGVideoIDFromURL(NSURL *url) {
    if (!url || !RGIsRedGIFsHost(url.host)) return nil;

    NSArray *parts = [url.path componentsSeparatedByString:@"/"];
    if ([parts count] < 3) return nil;

    NSString *kind = [[parts objectAtIndex:1] lowercaseString];
    if (![kind isEqualToString:@"watch"] && ![kind isEqualToString:@"ifr"]) {
        return nil;
    }

    NSString *videoID = [parts objectAtIndex:2];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if (![videoID length] || [videoID rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        return nil;
    }

    return videoID;
}

static NSDictionary *RGJSONRequest(NSString *urlString,
                                   NSString *userAgent,
                                   NSString *bearerToken,
                                   NSString *watchURL,
                                   NSInteger *statusCode) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:(userAgent.length ? userAgent : @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25")
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:RGReferer forHTTPHeaderField:@"Referer"];
    [request setValue:@"https://www.redgifs.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    if (bearerToken.length) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", bearerToken]
       forHTTPHeaderField:@"Authorization"];
        if (watchURL.length) {
            [request setValue:watchURL forHTTPHeaderField:@"x-customheader"];
        }
    }

    NSError *error = nil;
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&error];
    if (statusCode) {
        *statusCode = [(NSHTTPURLResponse *)response statusCode];
    }

    if (error || !data.length) {
        RGLog(@"API request failed: %@", error);
        return nil;
    }

    NSInteger httpStatus = [(NSHTTPURLResponse *)response statusCode];
    if (httpStatus < 200 || httpStatus >= 300) {
        RGLog(@"API returned HTTP %ld", (long)httpStatus);
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![object isKindOfClass:[NSDictionary class]]) {
        RGLog(@"API returned invalid JSON: %@", error);
        return nil;
    }

    return (NSDictionary *)object;
}

static NSString *RGResolveMP4(NSString *videoID, NSString *userAgent) {
    NSString *tokenURL = [RGAPIBase stringByAppendingString:@"/auth/temporary"];
    NSString *gifURL = [NSString stringWithFormat:@"%@/gifs/%@", RGAPIBase, videoID];
    // The API expects x-customheader to identify the canonical watch page,
    // not an /ifr URL or an embed URL with extra query parameters.
    NSString *apiWatchURL = [NSString stringWithFormat:@"https://www.redgifs.com/watch/%@", videoID];

    NSInteger status = 0;
    NSDictionary *auth = RGJSONRequest(tokenURL, userAgent, nil, nil, &status);
    NSString *token = [auth objectForKey:@"token"];
    if (![token isKindOfClass:[NSString class]] || !token.length) {
        RGLog(@"Could not obtain temporary API token (HTTP %ld)", (long)status);
        return nil;
    }

    // RedGIFs binds temporary tokens to the requesting IP and exact User-Agent.
    // Keep the same User-Agent for the token and metadata requests.
    for (int attempt = 0; attempt < 2; attempt++) {
        NSDictionary *metadata = RGJSONRequest(gifURL, userAgent, token, apiWatchURL, &status);
        if (status == 401 && attempt == 0) {
            RGLog(@"Temporary token rejected; refreshing once");
            auth = RGJSONRequest(tokenURL, userAgent, nil, nil, &status);
            token = [auth objectForKey:@"token"];
            if (![token isKindOfClass:[NSString class]] || !token.length) return nil;
            continue;
        }

        NSDictionary *gif = [metadata objectForKey:@"gif"];
        NSDictionary *urls = [gif objectForKey:@"urls"];
        NSString *mediaURL = [urls objectForKey:@"sd"];
        if (![mediaURL isKindOfClass:[NSString class]] || !mediaURL.length) {
            mediaURL = [urls objectForKey:@"hd"];
        }
        if ([mediaURL isKindOfClass:[NSString class]] &&
            ([mediaURL hasPrefix:@"https://"] || [mediaURL hasPrefix:@"http://"])) {
            return mediaURL;
        }

        RGLog(@"No usable SD/HD media URL in GIF metadata (HTTP %ld)", (long)status);
        return nil;
    }

    return nil;
}

static NSString *RGHTMLEscapeURL(NSString *value) {
    NSMutableString *escaped = [NSMutableString stringWithString:value];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;"
                                options:0 range:NSMakeRange(0, [escaped length])];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;"
                                options:0 range:NSMakeRange(0, [escaped length])];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;"
                                options:0 range:NSMakeRange(0, [escaped length])];
    return escaped;
}

static void RGRespondWithHTML(id protocol, NSString *html, NSInteger status) {
    SEL selector = @selector(respondWithStatus:headers:body:);
    if (![protocol respondsToSelector:selector]) {
        RGLog(@"RAProtocol response method is unavailable");
        return;
    }

    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"text/html; charset=utf-8", @"Content-Type",
                             @"no-store", @"Cache-Control", nil];
    NSData *body = [html dataUsingEncoding:NSUTF8StringEncoding];
    ((void (*)(id, SEL, NSInteger, NSDictionary *, NSData *))objc_msgSend)
        (protocol, selector, status, headers, body);
}

static BOOL RGHookCanInitWithRequest(id self, SEL command, NSURLRequest *request) {
    if (RGVideoIDFromURL(request.URL)) {
        RGLog(@"Recognized RedGIFs URL host=%@ path=%@", request.URL.host, request.URL.path);
        return YES;
    }
    return OriginalCanInitWithRequest ? OriginalCanInitWithRequest(self, command, request) : NO;
}

static void RGHookPatchRequest(id self, SEL command, NSMutableURLRequest *request) {
    // RAProtocol invokes patchRequest: on a background thread. Establish the
    // autorelease pool before URL parsing creates any autoreleased objects.
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *videoID = RGVideoIDFromURL(request.URL);
    if (!videoID) {
        if (OriginalPatchRequest) OriginalPatchRequest(self, command, request);
        [pool drain];
        return;
    }
    NSString *userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
    RGLog(@"Resolving RedGIFs ID=%@", videoID);
    NSLog(@"%@Resolving RedGIFs ID %@", RGLogPrefix, videoID);

    NSString *mediaURL = RGResolveMP4(videoID, userAgent);
    if (mediaURL.length) {
        NSString *escapedURL = RGHTMLEscapeURL(mediaURL);
        NSString *html = [NSString stringWithFormat:
                          @"<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>"
                           "<body style=\"margin:0;background:#000\"><video controls autoplay width=\"100%%\" "
                           "src=\"%@\"></video></body></html>", escapedURL];
        RGRespondWithHTML(self, html, 200);
        RGLog(@"Resolved %@ to an MP4 URL", videoID);
    } else {
        NSString *html = @"<!doctype html><html><body style=\"font-family:sans-serif\"><p>Unable to load this RedGIFs video. Please try again later.</p></body></html>";
        RGRespondWithHTML(self, html, 502);
        RGLog(@"Resolution failed for %@", videoID);
    }

    [pool drain];
}

static void RGInstallHooks(void) {
    @synchronized([NSObject class]) {
        if (RGHooksInstalled) return;

        Class protocolClass = NSClassFromString(@"RAProtocol");
        if (!protocolClass) { return; }

        Method classMethod = class_getClassMethod(protocolClass, @selector(canInitWithRequest:));
        Method instanceMethod = class_getInstanceMethod(protocolClass, @selector(patchRequest:));
        if (!classMethod || !instanceMethod) {
            RGLog(@"RAProtocol found, but expected selectors are not available yet");
            return;
        }

        MSHookMessageEx(object_getClass(protocolClass),
                        @selector(canInitWithRequest:),
                        (IMP)RGHookCanInitWithRequest,
                        (IMP *)&OriginalCanInitWithRequest);
        MSHookMessageEx(protocolClass,
                        @selector(patchRequest:),
                        (IMP)RGHookPatchRequest,
                        (IMP *)&OriginalPatchRequest);

        if (OriginalCanInitWithRequest && OriginalPatchRequest) {
            RGHooksInstalled = YES;
            RGLog(@"Installed RAProtocol RedGIFs hooks");
        } else {
            RGLog(@"RAProtocol hook installation did not return original IMPs");
        }
    }
}

// RAProtocol can be registered by RedAlien after our constructor runs.
// dyld notifies us for existing and subsequently loaded images. Defer the
// runtime lookup to a worker queue rather than doing hook work in dyld's callback.
static void RGImageAdded(const struct mach_header *header, intptr_t slide) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        RGInstallHooks();
        [pool drain];
    });
}

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    RGLog(@"Loaded in process=%@ bundle=%@",
          processName ? processName : @"(unknown)",
          bundleID ? bundleID : @"(unknown)");

    RGInstallHooks();
    _dyld_register_func_for_add_image(RGImageAdded);
    [pool drain];
}
