#import "Headers.h"

// Auto clear cache
%hook YTAppDelegate
%new
- (void)YouModAutoClearCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cachePath) return;
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:cachePath error:nil];
    for (NSString *item in contents) {
        NSString *itemPath = [cachePath stringByAppendingPathComponent:item];
        [fm removeItemAtPath:itemPath error:nil];
    }
}
- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)launchOptions {
    if (IS_ENABLED(AutoClearCache)) {
        // Clear cache on app launch
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self YouModAutoClearCache];
        });
    }
    return %orig;
}
%end
