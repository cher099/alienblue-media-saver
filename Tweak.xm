#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import "RedAlienMedia.h"

typedef BOOL (*RACanInitIMP)(id, SEL, NSURLRequest *);
typedef void (*RAPatchRequestIMP)(id, SEL, NSMutableURLRequest *);

static RACanInitIMP OriginalCanInitWithRequest = NULL;
static RAPatchRequestIMP OriginalPatchRequest = NULL;
static BOOL RGHooksInstalled = NO;
typedef BOOL (*UIApplicationOpenURLIMP)(id, SEL, NSURL *);
static UIApplicationOpenURLIMP OriginalUIApplicationOpenURL = NULL;
static BOOL RGSaveHookInstalled = NO;
static IMP OriginalUIActionSheetShowInView = NULL;
static BOOL RGActionSheetHookInstalled = NO;
static NSString *RGActiveVideoID = nil;
static char RGActionSheetVideoIDKey;
static NSMutableDictionary *RGActionSheetDelegateOriginalIMPs = nil;


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

static void RGSetActiveVideoID(NSString *videoID) {
    if (!videoID.length) return;
    @synchronized([NSObject class]) {
        if (RGActiveVideoID != videoID) {
            [RGActiveVideoID release];
            RGActiveVideoID = [videoID copy];
        }
    }
}

static void RGClearActiveVideoID(void) {
    @synchronized([NSObject class]) {
        [RGActiveVideoID release];
        RGActiveVideoID = nil;
    }
}

static BOOL RGHandleSaveURL(NSURL *url) {
    if (![[url.scheme lowercaseString] isEqualToString:@"redgifscompat"] ||
        ![[url.host lowercaseString] isEqualToString:@"save"]) return NO;
    NSArray *parts = [url.path componentsSeparatedByString:@"/"];
    NSString *videoID = [parts count] > 1 ? [parts objectAtIndex:1] : nil;
    if (videoID.length) {
        RGLog(@"Save-to-Photos action requested for %@", videoID);
        RGSaveVideoToPhotos(videoID);
    } else {
        RGLog(@"Save-to-Photos URL missing video ID");
    }
    return YES;
}

static BOOL RGHookUIApplicationOpenURL(id self, SEL command, NSURL *url) {
    if (RGHandleSaveURL(url)) return YES;
    return OriginalUIApplicationOpenURL ? OriginalUIApplicationOpenURL(self, command, url) : NO;
}

static void RGHookActionSheetDelegateClickedButton(id delegate, SEL command, id sheet, NSInteger buttonIndex);

static void RGInstallActionSheetDelegateHook(id delegate) {
    if (!delegate) return;
    Class delegateClass = [delegate class];
    SEL selector = NSSelectorFromString(@"actionSheet:clickedButtonAtIndex:");
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (!method) {
        RGLog(@"Share-menu delegate %@ has no actionSheet:clickedButtonAtIndex: callback",
              NSStringFromClass(delegateClass));
        return;
    }

    @synchronized([NSObject class]) {
        if (!RGActionSheetDelegateOriginalIMPs) {
            RGActionSheetDelegateOriginalIMPs = [[NSMutableDictionary alloc] init];
        }
        NSString *classKey = NSStringFromClass(delegateClass);
        if ([RGActionSheetDelegateOriginalIMPs objectForKey:classKey]) return;

        IMP original = NULL;
        MSHookMessageEx(delegateClass, selector,
                        (IMP)RGHookActionSheetDelegateClickedButton, &original);
        if (original) {
            [RGActionSheetDelegateOriginalIMPs setObject:[NSValue valueWithBytes:&original objCType:@encode(IMP)]
                                                  forKey:classKey];
            RGLog(@"Hooked AlienBlue Share-menu callback on %@", classKey);
        }
    }
}

static void RGHookActionSheetDelegateClickedButton(id delegate, SEL command, id sheet, NSInteger buttonIndex) {
    SEL titleSelector = NSSelectorFromString(@"buttonTitleAtIndex:");
    NSString *title = [sheet respondsToSelector:titleSelector] ?
        ((id (*)(id, SEL, NSUInteger))objc_msgSend)(sheet, titleSelector, (NSUInteger)buttonIndex) : nil;
    NSString *videoID = objc_getAssociatedObject(sheet, &RGActionSheetVideoIDKey);
    BOOL isRedGIFsSheet = videoID.length > 0;

    if ([title isEqualToString:@"Save to Photos"] && isRedGIFsSheet) {
        RGLog(@"AlienBlue Share menu selected Save to Photos for %@", videoID);
        RGSaveVideoToPhotos(videoID);
        RGClearActiveVideoID();
        return;
    }

    if ([title isEqualToString:@"Save to Photos"]) {
        RGLog(@"Save to Photos selected on a non-RedGIFs sheet; passing through to AlienBlue");
    }

    NSString *classKey = NSStringFromClass([delegate class]);
    IMP original = NULL;
    @synchronized([NSObject class]) {
        NSValue *originalValue = [RGActionSheetDelegateOriginalIMPs objectForKey:classKey];
        if (originalValue) [originalValue getValue:&original];
    }
    if (original) {
        ((void (*)(id, SEL, id, NSInteger))original)(delegate, command, sheet, buttonIndex);
    }
    if (isRedGIFsSheet) RGClearActiveVideoID();
}

static void RGHookActionSheetShowInView(id self, SEL command, id view) {
    NSUInteger count = 0;
    SEL countSelector = NSSelectorFromString(@"numberOfButtons");
    SEL titleSelector = NSSelectorFromString(@"buttonTitleAtIndex:");
    if ([self respondsToSelector:countSelector] && [self respondsToSelector:titleSelector]) {
        count = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, countSelector);
        NSMutableArray *titles = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            NSString *title = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(self, titleSelector, i);
            [titles addObject:title ? title : @"(nil)"];
        }
        id delegate = [self respondsToSelector:@selector(delegate)] ?
            ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate)) : nil;
        NSString *delegateName = delegate ? NSStringFromClass([delegate class]) : @"(nil)";
        RGLog(@"UIActionSheet presented class=%@ delegate=%@ buttons=%@ cancelIndex=%ld",
              NSStringFromClass([self class]), delegateName, titles,
              (long)([self respondsToSelector:NSSelectorFromString(@"cancelButtonIndex")] ?
                  ((NSInteger (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"cancelButtonIndex")) : -1));

        BOOL isAlienBlueVideoMenu =
            [delegateName rangeOfString:@"BrowserViewController"].location != NSNotFound &&
            [titles containsObject:@"Open in Safari"] &&
            [titles containsObject:@"Save to Reddit"];

        NSString *videoID = nil;
        @synchronized([NSObject class]) {
            videoID = [[RGActiveVideoID retain] autorelease];
        }

        if (isAlienBlueVideoMenu && videoID.length && ![titles containsObject:@"Save to Photos"]) {
            SEL addButtonSelector = NSSelectorFromString(@"addButtonWithTitle:");
            if ([self respondsToSelector:addButtonSelector]) {
                ((NSInteger (*)(id, SEL, id))objc_msgSend)(self, addButtonSelector, @"Save to Photos");
                objc_setAssociatedObject(self, &RGActionSheetVideoIDKey, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
                RGInstallActionSheetDelegateHook(delegate);
                RGLog(@"Added Save to Photos to AlienBlue Share menu for %@", videoID);
            }
        }
    }
    if (OriginalUIActionSheetShowInView) {
        ((void (*)(id, SEL, id))OriginalUIActionSheetShowInView)(self, command, view);
    }
}

static void RGInstallActionSheetProbe(void) {
    if (RGActionSheetHookInstalled) return;
    Class sheetClass = NSClassFromString(@"UIActionSheet");
    Method method = sheetClass ? class_getInstanceMethod(sheetClass, @selector(showInView:)) : NULL;
    if (!method) return;
    MSHookMessageEx(sheetClass, @selector(showInView:),
                    (IMP)RGHookActionSheetShowInView, &OriginalUIActionSheetShowInView);
    if (OriginalUIActionSheetShowInView) {
        RGActionSheetHookInstalled = YES;
        RGLog(@"Installed UIActionSheet share-menu discovery probe");
    }
}

static void RGInstallSaveHook(void) {
    RGInstallActionSheetProbe();
    if (RGSaveHookInstalled) return;
    Class appClass = NSClassFromString(@"UIApplication");
    Method method = appClass ? class_getInstanceMethod(appClass, @selector(openURL:)) : NULL;
    if (!method) return;
    MSHookMessageEx(appClass, @selector(openURL:),
                    (IMP)RGHookUIApplicationOpenURL,
                    (IMP *)&OriginalUIApplicationOpenURL);
    if (OriginalUIApplicationOpenURL) {
        RGSaveHookInstalled = YES;
        RGLog(@"Installed UIApplication save-to-Photos URL hook");
    }
}

static BOOL RGHookCanInitWithRequest(id self, SEL command, NSURLRequest *request) {
    NSString *videoID = RGVideoIDFromURL(request.URL);
    if (videoID) {
        RGSetActiveVideoID(videoID);
        RGLog(@"Recognized RedGIFs URL host=%@ path=%@", request.URL.host, request.URL.path);
        return YES;
    }
    return OriginalCanInitWithRequest ? OriginalCanInitWithRequest(self, command, request) : NO;
}

static void RGHookPatchRequest(id self, SEL command, NSMutableURLRequest *request) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *videoID = RGVideoIDFromURL(request.URL);
    if (!videoID) {
        if ([[request.URL.host lowercaseString] isEqualToString:@"v.redd.it"] &&
            [[request.URL.path lowercaseString] hasSuffix:@"/status.js"] &&
            [[request.URL.path lowercaseString] rangeOfString:@"redgifs-"].location != NSNotFound) {
            RGLog(@"RedAlien status poll observed: %@", request.URL.path);
        }
        if (OriginalPatchRequest) OriginalPatchRequest(self, command, request);
        [pool drain];
        return;
    }

    RGSetActiveVideoID(videoID);
    NSString *userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
    // First check RedAlien's shared cache/worker state. Avoid repeating the
    // RedGIFs API lookup when a download is already running or cached.
    NSString *html = RGPlaybackHTMLForVideo(videoID, nil, userAgent);
    if (!html) {
        RGLog(@"Resolving RedGIFs ID=%@", videoID);
        NSString *mediaURL = RGResolveMP4(videoID, userAgent);
        if (mediaURL.length) {
            RGLog(@"Resolved %@ to an MP4 URL; starting local download", videoID);
            html = RGPlaybackHTMLForVideo(videoID, mediaURL, userAgent);
        }
    }

    if (html.length) {
        RGRespondWithHTML(self, html, 200);
        RGLog(@"Handed RedGIFs %@ to RedAlien local playback pipeline", videoID);
    } else {
        NSString *errorHTML = @"<!doctype html><html><body style=\"font-family:sans-serif\"><p>Unable to prepare this RedGIFs video. Please try again later.</p></body></html>";
        RGRespondWithHTML(self, errorHTML, 502);
        RGLog(@"Could not start RedAlien playback pipeline for %@", videoID);
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
        RGInstallSaveHook();
        RGInstallActionSheetProbe();
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

    RGInstallSaveHook();
    RGInstallActionSheetProbe();
    RGInstallHooks();
    _dyld_register_func_for_add_image(RGImageAdded);
    [pool drain];
}
