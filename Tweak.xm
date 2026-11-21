#import <Foundation/Foundation.h>
#import <objc/runtime.h>

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

    NSLog(@"[RedGIFsCompat] Loaded in process=%@ bundle=%@",
          processName ? processName : @"(unknown)",
          bundleID ? bundleID : @"(unknown)");

    /*
     * Phase 1 scaffold only.
     *
     * RAProtocol is defined inside RedAlien. Do not assume the class is
     * available at this tweak's constructor time or that its private
     * methods form a stable API. Runtime hook installation will be added
     * only after load order and class availability are verified.
     */

    [pool drain];
}
