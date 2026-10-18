#import "AntibanCleaner.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────────────────────────
//  MCM private API — loaded at runtime via dlsym so the linker never sees it.
//  entitlement com.apple.private.MobileContainerManager.allowed already present.
// ─────────────────────────────────────────────────────────────────────────────
typedef NSString * (*MCMActivateContainerPathFn)(int type,
                                                 NSString *bundleID,
                                                 BOOL activate,
                                                 NSString * __autoreleasing *error);

static MCMActivateContainerPathFn _MCMActivateContainerPath(void) {
    static MCMActivateContainerPathFn fn = NULL;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
                              RTLD_NOW | RTLD_NOLOAD);
        if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
                                     RTLD_NOW);
        if (handle) fn = (MCMActivateContainerPathFn)dlsym(handle, "MCMActivateContainerPath");
        if (!fn) NSLog(@"[ANTIBAN] dlsym MCMActivateContainerPath failed: %s", dlerror());
    });
    return fn;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Supported game bundle IDs — FreeFire TH and MAX
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Resolve container path for a bundle ID via MCM → fallback metadata scan
// ─────────────────────────────────────────────────────────────────────────────
static NSString * _Nullable resolveContainerPath(NSString *bundleID) {
    // 1. MCM (fastest, uses the entitlement we already have)
    MCMActivateContainerPathFn mcmFn = _MCMActivateContainerPath();
    if (mcmFn) {
        NSString *mcmError = nil;
        NSString *path = mcmFn(2, bundleID, NO, &mcmError);
        if (path.length > 0) {
            NSLog(@"[ANTIBAN] MCM resolved %@ → %@", bundleID, path);
            return path;
        }
        NSLog(@"[ANTIBAN] MCM failed for %@: %@. Falling back to metadata scan.", bundleID, mcmError);
    } else {
        NSLog(@"[ANTIBAN] MCM unavailable — going to metadata scan.");
    }

    // 2. Metadata scan — iterate /var/mobile/Containers/Data/Application
    //    reading the .com.apple.mobile_container_manager.metadata.plist in each UUID dir
    NSString *appDataRoot = @"/var/mobile/Containers/Data/Application";
    NSError *fsErr = nil;
    NSArray<NSString *> *uuids = [[NSFileManager defaultManager]
                                    contentsOfDirectoryAtPath:appDataRoot
                                    error:&fsErr];
    if (!uuids || fsErr) {
        NSLog(@"[ANTIBAN] Metadata scan: cannot enumerate %@: %@", appDataRoot, fsErr);
        return nil;
    }

    for (NSString *uuid in uuids) {
        NSString *containerDir = [appDataRoot stringByAppendingPathComponent:uuid];
        NSString *metaPath = [containerDir
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *bid = meta[@"MCMMetadataIdentifier"];
        if ([bid isEqualToString:bundleID]) {
            NSLog(@"[ANTIBAN] Metadata scan resolved %@ → %@", bundleID, containerDir);
            return containerDir;
        }
    }
    NSLog(@"[ANTIBAN] Metadata scan: %@ not found", bundleID);
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Core clean logic — ported from DevicePatchService.cleanAntibanAndTelemetry
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult performClean(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult result = {0, 0};

    for (NSString *bundleID in supportedBundleIDs()) {
        NSString *containerPath = resolveContainerPath(bundleID);
        if (!containerPath) continue;

        NSURL *containerURL = [NSURL fileURLWithPath:containerPath isDirectory:YES];

        // ── 1. Documents: удаляем все файлы, оставляем папки и antiban decoy ──────
        NSURL *docsURL = [containerURL URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        NSArray<NSURL *> *docItems = [fm contentsOfDirectoryAtURL:docsURL
                                     includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                        options:0
                                                          error:nil];
        for (NSURL *item in docItems) {
            NSString *name = item.lastPathComponent;
            NSString *lower = name.lowercaseString;

            // Оставляем patch bytes и antiban decoy файлы (как в proxyapp)
            if ([lower isEqualToString:@"assembly-csharp-patch.bytes"]) continue;
            if ([lower hasPrefix:@"antiban_"])    continue;
            if ([lower hasPrefix:@"innova_cheat_"]) continue;
            if ([lower hasSuffix:@".bytes"] && [lower containsString:@"antiban"]) continue;

            // Оставляем папки
            NSNumber *isDir = nil;
            [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue) continue;

            NSError *err = nil;
            if ([fm removeItemAtURL:item error:&err]) {
                result.deletedDocs++;
                NSLog(@"[ANTIBAN] Deleted doc: %@", name);
            } else {
                NSLog(@"[ANTIBAN] Cannot delete %@: %@", name, err.localizedDescription);
            }
        }

        // ── 2. Telemetry paths (Library/Caches + tmp) — точный список из proxyapp ──
        NSArray<NSString *> *telemetryRelPaths = @[
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

        for (NSString *rel in telemetryRelPaths) {
            NSURL *target = [containerURL URLByAppendingPathComponent:rel];
            if ([fm fileExistsAtPath:target.path]) {
                NSError *err = nil;
                if ([fm removeItemAtURL:target error:&err]) {
                    result.deletedCaches++;
                } else {
                    NSLog(@"[ANTIBAN] Cannot delete cache %@: %@", rel, err.localizedDescription);
                }
            }
        }

        // ── 2b. Динамическое сканирование Library/Caches по ключевым словам ─────
        NSURL *cachesURL = [containerURL URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
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
            BOOL match = NO;
            for (NSString *kw in keywords) {
                if ([lname containsString:kw]) { match = YES; break; }
            }
            if (match) {
                if ([fm removeItemAtURL:item error:nil]) result.deletedCaches++;
            }
        }

        // ── 2c. Чистим Caches/tmp от явных config файлов ──────────────────────
        NSURL *tmpURL = [containerURL URLByAppendingPathComponent:@"tmp" isDirectory:YES];
        NSArray<NSString *> *specificFiles = @[
            @"Assembly-CSharp-patch.bytes",
            @"menu_config.json",
            @"localConfig.json",
            @"token.json",
            @".innova_token.dat"
        ];
        for (NSURL *cleanDir in @[ cachesURL, tmpURL ]) {
            for (NSString *fn in specificFiles) {
                NSURL *fURL = [cleanDir URLByAppendingPathComponent:fn];
                if ([fm fileExistsAtPath:fURL.path]) {
                    if ([fm removeItemAtURL:fURL error:nil]) result.deletedCaches++;
                }
            }
        }

        NSLog(@"[ANTIBAN] %@ — cleaned %ld docs, %ld caches",
              bundleID, (long)result.deletedDocs, (long)result.deletedCaches);
    }

    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
//  AntibanCleaner singleton
// ─────────────────────────────────────────────────────────────────────────────

// Private class extension — make readonly props writable internally
@interface AntibanCleaner ()
@property (nonatomic, assign, readwrite) BOOL        isLoopRunning;
@property (nonatomic, assign, readwrite) AntibanResult lastResult;
@end

@implementation AntibanCleaner {
    dispatch_queue_t     _queue;
    dispatch_source_t    _timer;
    NSRecursiveLock     *_lock;
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
    _lock  = [NSRecursiveLock new];
    _lastResult = (AntibanResult){0, 0};
    return self;
}

- (AntibanResult)cleanOnce {
    __block AntibanResult r;
    dispatch_sync(_queue, ^{ r = performClean(); });
    _lastResult = r;
    return r;
}

- (void)startLoop {
    [_lock lock];
    if (_timer) {
        [_lock unlock];
        return; // уже запущен
    }

    NSLog(@"[ANTIBAN] Starting continuous loop (10s interval)");

    // Разовый немедленный прогон
    dispatch_async(_queue, ^{
        AntibanResult r = performClean();
        self->_lastResult = r;
        NSLog(@"[ANTIBAN] Initial pass: %ld docs, %ld caches",
              (long)r.deletedDocs, (long)r.deletedCaches);
    });

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                              (uint64_t)(10.0 * NSEC_PER_SEC),
                              (uint64_t)(1.0  * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        AntibanResult r = performClean();
        self->_lastResult = r;
        if (r.deletedDocs > 0 || r.deletedCaches > 0) {
            NSLog(@"[ANTIBAN LOOP] Pass: %ld docs, %ld caches",
                  (long)r.deletedDocs, (long)r.deletedCaches);
        }
    });
    _timer = timer;
    dispatch_resume(timer);
    _isLoopRunning = YES;
    [_lock unlock];
}

- (void)stopLoop {
    [_lock lock];
    if (!_timer) {
        [_lock unlock];
        return;
    }
    NSLog(@"[ANTIBAN] Stopping loop");
    dispatch_source_cancel(_timer);
    _timer = nil;
    _isLoopRunning = NO;
    [_lock unlock];
}

@end
