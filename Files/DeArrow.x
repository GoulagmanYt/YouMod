#import "Headers.h"

// DeArrow thumbnail & title replacement (https://dearrow.ajay.app)
// API docs: https://wiki.sponsor.ajay.app/w/API_Docs/DeArrow

@interface ASDisplayNode (YMDeArrow)
- (ASDisplayNode *)supernode;
- (NSArray<ASDisplayNode *> *)subnodes;
- (UIView *)view;
- (void)setNeedsLayout;
@end

@interface ELMTextNode : ASDisplayNode
@property (nonatomic, copy, readwrite) NSAttributedString *attributedText;
@end

@interface YMDeArrow ()
+ (NSString *)cachePath;
+ (void)loadCacheIfNeeded;
+ (void)scheduleCacheSave;
+ (NSDictionary *)cachedEntryForVideoID:(NSString *)videoID;
+ (NSNumber *)pickTimeFromBranding:(NSDictionary *)json;
+ (NSString *)pickTitleFromBranding:(NSDictionary *)json;
+ (void)fetchBrandingForVideoID:(NSString *)videoID completion:(void (^)(NSDictionary *entry))completion;
+ (void)loadImageForVideoID:(NSString *)videoID time:(double)time node:(ELMImageNode *)node;
+ (void)applyImage:(UIImage *)image toNode:(ELMImageNode *)node videoID:(NSString *)videoID;
+ (ELMTextNode *)findTitleNodeForImageNode:(ELMImageNode *)imageNode;
+ (void)applyTitle:(NSString *)title forImageNode:(ELMImageNode *)imageNode videoID:(NSString *)videoID;
@end

// videoID -> @{ @"time": NSNumber (optional), @"title": NSString (optional), @"expires": NSNumber }
static NSMutableDictionary<NSString *, NSDictionary *> *ymDeArrowCache = nil;
static NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSDictionary *)> *> *ymDeArrowInFlight = nil;
static NSCache<NSString *, UIImage *> *ymDeArrowImages = nil;
static BOOL ymDeArrowCacheLoaded = NO;

// Marks which video a node is currently displaying so late results are dropped after cell reuse.
static const void *kYMDeArrowNodeVideoID = &kYMDeArrowNodeVideoID;

@implementation YMDeArrow

#pragma mark - Entry point

+ (void)applyToNode:(ELMImageNode *)node forURL:(NSURL *)url {
    if (!node || !url) return;
    NSString *videoID = YMExtractYouTubeVideoID(url.absoluteString);
    if (videoID.length != 11 || ![url.host isEqualToString:@"i.ytimg.com"]) return;

    // Tag the node; if it gets reused for another video, late callbacks bail out.
    objc_setAssociatedObject(node, kYMDeArrowNodeVideoID, videoID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSDictionary *entry = [self cachedEntryForVideoID:videoID];
    if (entry) {
        NSString *title = entry[@"title"];
        if (title.length > 0) {
            [self applyTitle:title forImageNode:node videoID:videoID];
        }
        UIImage *cachedImage = [ymDeArrowImages objectForKey:videoID];
        if (cachedImage) {
            [self applyImage:cachedImage toNode:node videoID:videoID];
        } else {
            NSNumber *time = entry[@"time"];
            if (time) [self loadImageForVideoID:videoID time:time.doubleValue node:node];
        }
        return;
    }

    [self fetchBrandingForVideoID:videoID completion:^(NSDictionary *fetchedEntry) {
        if (!fetchedEntry) return;
        NSString *title = fetchedEntry[@"title"];
        if (title.length > 0) {
            [self applyTitle:title forImageNode:node videoID:videoID];
        }
        NSNumber *time = fetchedEntry[@"time"];
        if (time) {
            [self loadImageForVideoID:videoID time:time.doubleValue node:node];
        }
    }];
}

#pragma mark - Cache

+ (NSString *)cachePath {
    // Not NSCachesDirectory: Cache.x wipes it at launch when AutoClearCache is on.
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [appSupport stringByAppendingPathComponent:@"YouMod"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"DeArrowCache.plist"];
}

+ (void)loadCacheIfNeeded {
    @synchronized (ymDeArrowCache) {
        if (ymDeArrowCacheLoaded) return;
        ymDeArrowCacheLoaded = YES;
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:[self cachePath]];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        for (NSString *key in disk) {
            NSDictionary *entry = disk[key];
            if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"expires"] doubleValue] > now) {
                ymDeArrowCache[key] = entry;
            }
        }
    }
}

+ (void)scheduleCacheSave {
    static BOOL pending = NO;
    @synchronized (ymDeArrowCache) {
        if (pending) return;
        pending = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *snapshot;
        @synchronized (ymDeArrowCache) {
            snapshot = [ymDeArrowCache copy];
            pending = NO;
        }
        [snapshot writeToFile:[self cachePath] atomically:YES];
    });
}

+ (NSDictionary *)cachedEntryForVideoID:(NSString *)videoID {
    [self loadCacheIfNeeded];
    @synchronized (ymDeArrowCache) {
        NSDictionary *entry = ymDeArrowCache[videoID];
        if (entry && [entry[@"expires"] doubleValue] > NSDate.date.timeIntervalSince1970) return entry;
        if (entry) [ymDeArrowCache removeObjectForKey:videoID];
    }
    return nil;
}

#pragma mark - Branding lookup

// Returns the frame time (seconds) for the video, or nil to keep YouTube's thumbnail.
+ (NSNumber *)pickTimeFromBranding:(NSDictionary *)json {
    NSArray *thumbnails = [json[@"thumbnails"] isKindOfClass:[NSArray class]] ? json[@"thumbnails"] : nil;
    for (NSDictionary *thumb in thumbnails) {
        if (![thumb isKindOfClass:[NSDictionary class]]) continue;
        if (![thumb[@"locked"] boolValue] && [thumb[@"votes"] integerValue] < 0) continue;
        if ([thumb[@"original"] boolValue]) return nil;
        NSNumber *timestamp = thumb[@"timestamp"];
        if ([timestamp isKindOfClass:[NSNumber class]]) return timestamp;
    }
    NSNumber *duration = json[@"videoDuration"];
    NSNumber *randomTime = json[@"randomTime"];
    if ([duration isKindOfClass:[NSNumber class]] && [randomTime isKindOfClass:[NSNumber class]] && duration.doubleValue > 0) {
        return @(randomTime.doubleValue * duration.doubleValue);
    }
    return nil;
}

// Returns the replacement title for the video, or nil to keep YouTube's original title.
+ (NSString *)pickTitleFromBranding:(NSDictionary *)json {
    NSArray *titles = [json[@"titles"] isKindOfClass:[NSArray class]] ? json[@"titles"] : nil;
    for (NSDictionary *item in titles) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![item[@"locked"] boolValue] && [item[@"votes"] integerValue] < 0) continue;
        if ([item[@"original"] boolValue]) return nil;
        NSString *rawTitle = item[@"title"];
        if ([rawTitle isKindOfClass:[NSString class]]) {
            NSString *cleaned = [rawTitle stringByReplacingOccurrencesOfString:@">" withString:@""];
            cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cleaned.length > 0) return cleaned;
        }
    }
    return nil;
}

+ (void)fetchBrandingForVideoID:(NSString *)videoID completion:(void (^)(NSDictionary *entry))completion {
    if (!videoID) return;
    @synchronized (ymDeArrowInFlight) {
        NSMutableArray *callbacks = ymDeArrowInFlight[videoID];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }
        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        ymDeArrowInFlight[videoID] = callbacks;
    }

    NSString *urlStr = [NSString stringWithFormat:@"https://sponsor.ajay.app/api/branding?videoID=%@", videoID];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlStr] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *entry = nil;
        NSTimeInterval expires = NSDate.date.timeIntervalSince1970;
        if (!error) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode == 200 && data.length > 0) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSNumber *time = [self pickTimeFromBranding:json];
                    NSString *title = [self pickTitleFromBranding:json];
                    NSMutableDictionary *mutableEntry = [NSMutableDictionary dictionary];
                    if (time) mutableEntry[@"time"] = time;
                    if (title) mutableEntry[@"title"] = title;
                    mutableEntry[@"expires"] = @(expires + ((time || title) ? (7 * 24 * 3600) : (24 * 3600)));
                    entry = [mutableEntry copy];
                }
            } else if (statusCode == 404) {
                entry = @{ @"expires": @(expires + 24 * 3600) };
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (entry) {
                @synchronized (ymDeArrowCache) {
                    ymDeArrowCache[videoID] = entry;
                }
                [self scheduleCacheSave];
            }
            NSArray<void (^)(NSDictionary *)> *callbacks = nil;
            @synchronized (ymDeArrowInFlight) {
                callbacks = [ymDeArrowInFlight[videoID] copy];
                [ymDeArrowInFlight removeObjectForKey:videoID];
            }
            for (void (^cb)(NSDictionary *) in callbacks) {
                cb(entry);
            }
        });
    }];
    [task resume];
}

#pragma mark - Frame image

+ (void)loadImageForVideoID:(NSString *)videoID time:(double)time node:(ELMImageNode *)node {
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://dearrow-thumb.ajay.app/api/v1/getThumbnail"];
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"videoID" value:videoID],
        [NSURLQueryItem queryItemWithName:@"time" value:[NSString stringWithFormat:@"%.3f", time]],
    ];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = nil;
        if (!error && data.length > 0 && ((NSHTTPURLResponse *)response).statusCode == 200) {
            image = [UIImage imageWithData:data];
        }
        if (!image) return;
        [ymDeArrowImages setObject:image forKey:videoID];
        [self applyImage:image toNode:node videoID:videoID];
    }];
    [task resume];
}

+ (void)applyImage:(UIImage *)image toNode:(ELMImageNode *)node videoID:(NSString *)videoID {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *expected = objc_getAssociatedObject(node, kYMDeArrowNodeVideoID);
        if (![expected isEqualToString:videoID]) return;
        [node setImage:image];
        // %orig's own download may land after us and overwrite the frame; assert once more.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *current = objc_getAssociatedObject(node, kYMDeArrowNodeVideoID);
            if ([current isEqualToString:videoID]) [node setImage:image];
        });
    });
}

#pragma mark - Title replacement

static void YMCollectTextNodesExcludingBranch(ASDisplayNode *root, ASDisplayNode *excludedBranch, NSMutableArray<ELMTextNode *> *outNodes) {
    if (!root || root == excludedBranch) return;
    if ([root isKindOfClass:%c(ELMTextNode)]) {
        [outNodes addObject:(ELMTextNode *)root];
        return;
    }
    NSArray<ASDisplayNode *> *children = [root respondsToSelector:@selector(subnodes)] ? root.subnodes : nil;
    for (ASDisplayNode *child in children) {
        YMCollectTextNodesExcludingBranch(child, excludedBranch, outNodes);
    }
}

+ (ELMTextNode *)findTitleNodeForImageNode:(ELMImageNode *)imageNode {
    if (![imageNode respondsToSelector:@selector(supernode)]) return nil;
    ASDisplayNode *childBranch = (ASDisplayNode *)imageNode;
    ASDisplayNode *parent = [childBranch supernode];

    for (NSUInteger depth = 0; depth < 6 && parent != nil; depth++) {
        NSMutableArray<ELMTextNode *> *candidates = [NSMutableArray array];
        YMCollectTextNodesExcludingBranch(parent, childBranch, candidates);

        ELMTextNode *bestNode = nil;
        CGFloat bestFontSize = 0.0;

        for (ELMTextNode *textNode in candidates) {
            if (![textNode respondsToSelector:@selector(attributedText)]) continue;
            NSAttributedString *attr = textNode.attributedText;
            NSString *str = attr.string;
            if (str.length < 2) continue;
            // Skip metadata/byline strings ("Channel • 10K views • 2d ago")
            if ([str containsString:@" • "] || [str containsString:@" · "]) continue;

            NSDictionary *attrs = [attr attributesAtIndex:0 effectiveRange:NULL];
            UIFont *font = attrs[NSFontAttributeName];
            CGFloat fontSize = font ? font.pointSize : 14.0;
            if (!bestNode || fontSize > bestFontSize) {
                bestNode = textNode;
                bestFontSize = fontSize;
            }
        }

        if (bestNode) return bestNode;
        childBranch = parent;
        parent = [parent supernode];
    }
    return nil;
}

static void YMUpdateTextNodeWithTitle(ELMTextNode *textNode, NSString *title) {
    if (!textNode || ![textNode respondsToSelector:@selector(attributedText)] || ![textNode respondsToSelector:@selector(setAttributedText:)]) return;
    NSAttributedString *currentAttr = textNode.attributedText;
    if ([currentAttr.string isEqualToString:title]) return;
    NSDictionary *attrs = currentAttr.length > 0 ? [currentAttr attributesAtIndex:0 effectiveRange:NULL] : nil;
    textNode.attributedText = [[NSAttributedString alloc] initWithString:title attributes:attrs];
    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) [textNode setNeedsLayout];
}

+ (void)applyTitle:(NSString *)title forImageNode:(ELMImageNode *)imageNode videoID:(NSString *)videoID {
    if (!title || title.length == 0 || !imageNode) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *expected = objc_getAssociatedObject(imageNode, kYMDeArrowNodeVideoID);
        if (![expected isEqualToString:videoID]) return;
        ELMTextNode *titleNode = [self findTitleNodeForImageNode:imageNode];
        if (titleNode) YMUpdateTextNodeWithTitle(titleNode, title);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *current = objc_getAssociatedObject(imageNode, kYMDeArrowNodeVideoID);
            if (![current isEqualToString:videoID]) return;
            ELMTextNode *retryNode = [self findTitleNodeForImageNode:imageNode];
            if (retryNode) YMUpdateTextNodeWithTitle(retryNode, title);
        });
    });
}

@end

#pragma mark - ELMImageNode Hooks

%hook ELMImageNode

- (id)downloadImageWithURL:(NSURL *)URL shouldRetry:(BOOL)retry callbackQueue:(id)queue downloadProgress:(id)progress completion:(id)completion {
    if (IS_ENABLED(DeArrowEnabled)) [YMDeArrow applyToNode:self forURL:URL];
    return %orig;
}

- (void)cachedImageWithURL:(NSURL *)URL callbackQueue:(id)queue completion:(id)completion {
    if (IS_ENABLED(DeArrowEnabled)) [YMDeArrow applyToNode:self forURL:URL];
    %orig;
}

%end

%ctor {
    ymDeArrowCache = [NSMutableDictionary dictionary];
    ymDeArrowInFlight = [NSMutableDictionary dictionary];
    ymDeArrowImages = [NSCache new];
}
