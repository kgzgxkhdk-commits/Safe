#import "AntibanCleaner.h"
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Resolve container via metadata plist scan.
//  Works because entitlements include:
//    com.apple.private.security.no-sandbox
//    com.apple.private.security.storage.AppDataContainers
// ─────────────────────────────────────────────────────────────────────────────
static NSString * _Nullable resolveContainerPath(NSString *bundleID) {
    NSString *appDataRoot = @"/var/mobile/Containers/Data/Application";
    NSError *err = nil;
    NSArray<NSString *> *uuids = [[NSFileManager defaultManager]
                                    contentsOfDirectoryAtPath:appDataRoot
                                    error:&err];
    if (!uuids) {
        NSLog(@"[ANTIBAN] Cannot enumerate %@: %@", appDataRoot, err);
        return nil;
    }
    for (NSString *uuid in uuids) {
        NSString *dir  = [appDataRoot stringByAppendingPathComponent:uuid];
        NSString *meta = [dir stringByAppendingPathComponent:
                            @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([d[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) {
            NSLog(@"[ANTIBAN] Resolved %@ → %@", bundleID, dir);
            return dir;
        }
    }
    NSLog(@"[ANTIBAN] %@ not found", bundleID);
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Core clean — Documents telemetry files + Caches / tmp analytics dirs
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult performClean(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult result = {0, 0};

    for (NSString *bundleID in supportedBundleIDs()) {
        NSString *containerPath = resolveContainerPath(bundleID);
        if (!containerPath) continue;

        NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

        // ── Documents ────────────────────────────────────────────────────────
        NSURL *docsURL = [base URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        NSArray<NSURL *> *docs = [fm contentsOfDirectoryAtURL:docsURL
                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                      options:0
                                                        error:nil];
        for (NSURL *item in docs) {
            NSString *lower = item.lastPathComponent.lowercaseString;
            // keep patch bytes and antiban decoys
            if ([lower isEqualToString:@"assembly-csharp-patch.bytes"]) continue;
            if ([lower hasPrefix:@"antiban_"])     continue;
            if ([lower hasPrefix:@"innova_cheat_"]) continue;
            if ([lower hasSuffix:@".bytes"] && [lower containsString:@"antiban"]) continue;
            // keep directories
            NSNumber *isDir = nil;
            [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue) continue;

            if ([fm removeItemAtURL:item error:nil]) {
                result.deletedDocs++;
                NSLog(@"[ANTIBAN] doc removed: %@", item.lastPathComponent);
            }
        }

        // ── Static telemetry paths ────────────────────────────────────────────
        NSArray<NSString *> *staticPaths = @[
            @"Library/Caches/Analytics",
            @"Library/Caches/CrashReporter",
            @"Library/Caches/crashes",
            @"Library/Caches/bugly",
            @"Library/Caches/com.crashlytics.data",
            @"Library/Caches/com.google.firebase",
            @"Library/Caches/appsflyer-v1",
            @"Library/Caches/com.appsflyer",
            @"Library/Caches/adjust-sdk",
            @"Library/Caches/Snapshots",
            @"Library/Caches/Firebase",
            @"Library/Caches/Crashlytics",
            @"Library/Caches/Cache.db",
            @"Library/Caches/Cache.db-shm",
            @"Library/Caches/Cache.db-wal",
            @"Library/Caches/fsCachedData",
            [NSString stringWithFormat:@"Library/Caches/%@/Cache.db",     bundleID],
            [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-shm", bundleID],
            [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-wal", bundleID],
            [NSString stringWithFormat:@"Library/Caches/%@/fsCachedData", bundleID],
            @"tmp/Analytics",
            @"tmp/CrashReporter",
            @"tmp/crashes",
            @"tmp/bugly",
            @"tmp/appsflyer-v1",
        ];
        for (NSString *rel in staticPaths) {
            NSURL *target = [base URLByAppendingPathComponent:rel];
            if ([fm fileExistsAtPath:target.path]) {
                if ([fm removeItemAtURL:target error:nil]) result.deletedCaches++;
            }
        }

        // ── Dynamic scan Library/Caches by keyword ───────────────────────────
        NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
        NSArray<NSString *> *keywords = @[
            @"analytics", @"crash", @"bugly",
            @"firebase", @"appsflyer", @"adjust",
            @"cache.db", @"fscacheddata"
        ];
        NSArray<NSURL *> *cacheItems = [fm contentsOfDirectoryAtURL:cachesURL
                                        includingPropertiesForKeys:nil
                                                           options:0
                                                             error:nil];
        for (NSURL *item in cacheItems) {
            NSString *lname = item.lastPathComponent.lowercaseString;
            for (NSString *kw in keywords) {
                if ([lname containsString:kw]) {
                    if ([fm removeItemAtURL:item error:nil]) result.deletedCaches++;
                    break;
                }
            }
        }

        // ── Specific config files in Caches + tmp ────────────────────────────
        NSURL *tmpURL = [base URLByAppendingPathComponent:@"tmp" isDirectory:YES];
        NSArray<NSString *> *specific = @[
            @"Assembly-CSharp-patch.bytes",
            @"menu_config.json",
            @"localConfig.json",
            @"token.json",
            @".innova_token.dat"
        ];
        for (NSURL *dir in @[ cachesURL, tmpURL ]) {
            for (NSString *fn in specific) {
                NSURL *f = [dir URLByAppendingPathComponent:fn];
                if ([fm fileExistsAtPath:f.path])
                    if ([fm removeItemAtURL:f error:nil]) result.deletedCaches++;
            }
        }

        NSLog(@"[ANTIBAN] %@ done — docs:%ld caches:%ld",
              bundleID, (long)result.deletedDocs, (long)result.deletedCaches);
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Singleton
// ─────────────────────────────────────────────────────────────────────────────
@interface AntibanCleaner ()
@property (nonatomic, assign, readwrite) BOOL         isLoopRunning;
@property (nonatomic, assign, readwrite) AntibanResult lastResult;
@end

@implementation AntibanCleaner {
    dispatch_queue_t  _queue;
    dispatch_source_t _timer;
    NSLock           *_lock;
}

+ (instancetype)shared {
    static AntibanCleaner *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [AntibanCleaner new]; });
    return inst;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("ext.ff.antiban", DISPATCH_QUEUE_SERIAL);
    _lock  = [NSLock new];
    _lastResult = (AntibanResult){0, 0};
    return self;
}

- (AntibanResult)cleanOnce {
    __block AntibanResult r;
    dispatch_sync(_queue, ^{ r = performClean(); });
    self.lastResult = r;
    return r;
}

- (void)startLoop {
    [_lock lock];
    if (_timer) { [_lock unlock]; return; }

    NSLog(@"[ANTIBAN] loop start");

    dispatch_async(_queue, ^{
        AntibanResult r = performClean();
        self.lastResult = r;
    });

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
        (uint64_t)(10.0 * NSEC_PER_SEC),
        (uint64_t)(NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        AntibanResult r = performClean();
        self.lastResult = r;
    });
    _timer = timer;
    dispatch_resume(timer);
    self.isLoopRunning = YES;
    [_lock unlock];
}

- (void)stopLoop {
    [_lock lock];
    if (!_timer) { [_lock unlock]; return; }
    dispatch_source_cancel(_timer);
    _timer = nil;
    self.isLoopRunning = NO;
    NSLog(@"[ANTIBAN] loop stop");
    [_lock unlock];
}

@end
