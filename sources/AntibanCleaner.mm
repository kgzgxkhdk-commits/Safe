#import "AntibanCleaner.h"

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container resolution — metadata plist scan
//  Requires: com.apple.private.security.no-sandbox
//            com.apple.private.security.storage.AppDataContainers
// ─────────────────────────────────────────────────────────────────────────────
static NSString * _Nullable resolveContainerPath(NSString *bundleID) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray<NSString *> *uuids = [[NSFileManager defaultManager]
                                    contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uuid in uuids) {
        NSString *dir  = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [dir stringByAppendingPathComponent:
                            @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([d[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) return dir;
    }
    return nil;
}

static NSArray<NSString *> *watchedRelDirs(void) {
    return @[ @"Documents", @"Library/Caches", @"tmp" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Clean one container
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

    // Documents — remove files, keep dirs and antiban decoys
    NSURL *docsURL = [base URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:docsURL
                           includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                              options:0 error:nil]) {
        NSString *lower = item.lastPathComponent.lowercaseString;
        if ([lower isEqualToString:@"assembly-csharp-patch.bytes"]) continue;
        if ([lower hasPrefix:@"antiban_"])       continue;
        if ([lower hasPrefix:@"innova_cheat_"])  continue;
        if ([lower hasSuffix:@".bytes"] && [lower containsString:@"antiban"]) continue;
        NSNumber *isDir = nil;
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        if ([fm removeItemAtURL:item error:nil]) r.deletedDocs++;
    }

    // Static telemetry paths
    NSArray<NSString *> *staticRel = @[
        @"Library/Caches/Analytics",       @"Library/Caches/CrashReporter",
        @"Library/Caches/crashes",         @"Library/Caches/bugly",
        @"Library/Caches/com.crashlytics.data",
        @"Library/Caches/com.google.firebase",
        @"Library/Caches/appsflyer-v1",   @"Library/Caches/com.appsflyer",
        @"Library/Caches/adjust-sdk",     @"Library/Caches/Snapshots",
        @"Library/Caches/Firebase",       @"Library/Caches/Crashlytics",
        @"Library/Caches/Cache.db",       @"Library/Caches/Cache.db-shm",
        @"Library/Caches/Cache.db-wal",   @"Library/Caches/fsCachedData",
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db",     bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-shm", bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-wal", bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/fsCachedData", bundleID],
        @"tmp/Analytics",   @"tmp/CrashReporter",
        @"tmp/crashes",     @"tmp/bugly",    @"tmp/appsflyer-v1",
    ];
    for (NSString *rel in staticRel) {
        NSURL *t = [base URLByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:t.path])
            if ([fm removeItemAtURL:t error:nil]) r.deletedCaches++;
    }

    // Dynamic keyword scan in Library/Caches
    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    NSArray<NSString *> *keywords = @[
        @"analytics", @"crash", @"bugly",
        @"firebase",  @"appsflyer", @"adjust",
        @"cache.db",  @"fscacheddata"
    ];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:cachesURL
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *lname = item.lastPathComponent.lowercaseString;
        for (NSString *kw in keywords)
            if ([lname containsString:kw]) {
                if ([fm removeItemAtURL:item error:nil]) r.deletedCaches++;
                break;
            }
    }

    // Specific config files
    NSURL *tmpURL = [base URLByAppendingPathComponent:@"tmp" isDirectory:YES];
    for (NSURL *dir in @[ cachesURL, tmpURL ])
        for (NSString *fn in @[ @"Assembly-CSharp-patch.bytes", @"menu_config.json",
                                 @"localConfig.json", @"token.json", @".innova_token.dat" ]) {
            NSURL *f = [dir URLByAppendingPathComponent:fn];
            if ([fm fileExistsAtPath:f.path])
                if ([fm removeItemAtURL:f error:nil]) r.deletedCaches++;
        }

    return r;
}

static AntibanResult performClean(void) {
    AntibanResult total = {0, 0};
    for (NSString *bid in supportedBundleIDs()) {
        NSString *path = resolveContainerPath(bid);
        if (!path) continue;
        AntibanResult r = cleanContainer(path, bid);
        total.deletedDocs   += r.deletedDocs;
        total.deletedCaches += r.deletedCaches;
        NSLog(@"[ANTIBAN] %@ docs:%ld caches:%ld",
              bid, (long)r.deletedDocs, (long)r.deletedCaches);
    }
    return total;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Private extension
// ─────────────────────────────────────────────────────────────────────────────
@interface AntibanCleaner ()
@property (nonatomic, assign, readwrite) BOOL          isWatching;
@property (nonatomic, assign, readwrite) AntibanResult lastResult;
@end

// ─────────────────────────────────────────────────────────────────────────────
//  AntibanCleaner
// ─────────────────────────────────────────────────────────────────────────────
@implementation AntibanCleaner {
    dispatch_queue_t    _queue;
    NSLock             *_lock;
    // Wrap dispatch_source_t in NSValue pointer — no __bridge id cast needed
    NSMutableArray<NSValue *> *_sourceRefs;
    NSMutableArray     *_fds;          // NSNumber(int) — open O_EVTONLY fds
}

+ (instancetype)shared {
    static AntibanCleaner *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [AntibanCleaner new]; });
    return inst;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue      = dispatch_queue_create("ext.ff.antiban", DISPATCH_QUEUE_SERIAL);
    _lock       = [NSLock new];
    _sourceRefs = [NSMutableArray new];
    _fds        = [NSMutableArray new];
    _lastResult = (AntibanResult){0, 0};
    return self;
}

- (AntibanResult)cleanOnce {
    __block AntibanResult r;
    dispatch_sync(_queue, ^{ r = performClean(); });
    self.lastResult = r;
    return r;
}

- (void)startWatching {
    [_lock lock];
    if (_isWatching) { [_lock unlock]; return; }
    NSLog(@"[ANTIBAN] startWatching");

    // Immediate first pass
    dispatch_async(_queue, ^{
        self.lastResult = performClean();
    });

    // Collect all dirs to watch
    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    for (NSString *bid in supportedBundleIDs()) {
        NSString *container = resolveContainerPath(bid);
        if (!container) continue;
        for (NSString *rel in watchedRelDirs()) {
            NSString *abs = [container stringByAppendingPathComponent:rel];
            [[NSFileManager defaultManager]
                createDirectoryAtPath:abs
              withIntermediateDirectories:YES attributes:nil error:nil];
            [dirs addObject:abs];
        }
    }

    for (NSString *dir in dirs) {
        int fd = open(dir.UTF8String, O_EVTONLY);
        if (fd < 0) { NSLog(@"[ANTIBAN] open failed: %@", dir); continue; }

        [_fds addObject:@(fd)];

        // Use CFRetain pattern — dispatch_source_t is toll-free bridged to CFTypeRef
        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB,
            _queue);

        dispatch_source_set_event_handler(src, ^{
            self.lastResult = performClean();
            NSLog(@"[ANTIBAN] vnode fired → docs:%ld caches:%ld",
                  (long)self.lastResult.deletedDocs, (long)self.lastResult.deletedCaches);
        });

        int fdCopy = fd;
        dispatch_source_set_cancel_handler(src, ^{ close(fdCopy); });
        dispatch_resume(src);

        // Store as opaque pointer in NSValue — avoids any __bridge id cast
        CFRetain((__bridge CFTypeRef)src);
        [_sourceRefs addObject:[NSValue valueWithPointer:(__bridge void *)src]];
    }

    self.isWatching = YES;
    [_lock unlock];
}

- (void)stopWatching {
    [_lock lock];
    if (!_isWatching) { [_lock unlock]; return; }
    NSLog(@"[ANTIBAN] stopWatching");

    for (NSValue *v in _sourceRefs) {
        dispatch_source_t src = (__bridge dispatch_source_t)v.pointerValue;
        dispatch_source_cancel(src);
        CFRelease((__bridge CFTypeRef)src);
    }
    [_sourceRefs removeAllObjects];
    [_fds removeAllObjects];

    // Final clean on game exit
    dispatch_async(_queue, ^{
        self.lastResult = performClean();
    });

    self.isWatching = NO;
    [_lock unlock];
}

@end
