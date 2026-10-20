#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"
#include <mach/mach.h>

// ─────────────────────────────────────────────────────────────────────────────
//  OB55 verified RVAs (VA == RVA, offset from UnityFramework __TEXT base)
//  Cross-referenced OB49 (unobfuscated) ↔ OB55 via static field offsets:
//    OB49 AntihackSDKManager.Disable    @0x48 = OB55 DKPDEMLPNOE.MNNGFLIFFHL @0x48
//    OB49 AntihackSDKManager.mInitialized @0x0 = OB55 DKPDEMLPNOE.HLCEOPAMDNH @0x0
// ─────────────────────────────────────────────────────────────────────────────

// DKPDEMLPNOE (= AntihackSDKManager, OB49 RVA base: 0x57EDE58)
#define kRVA_MOFOEPHILGO   0x20F2D40  // RunOneFrame()         — per-frame TSS tick
#define kRVA_GIFIAMDDLOC   0x20F2494  // SendAntiDataToServer  — data upload wrapper
#define kRVA_DLIDMJONJKE   0x20F2554  // SendAntiDataToServer  — private actual send
#define kRVA_JAMOJCJLJNG   0x20F18E4  // InitTick()
#define kRVA_CJMDFFMNLAC   0x20F1924  // EnableData()
#define kRVA_INICGCCOGEC   0x21EC4DC  // INICGCCOGEC(bool)     — MHJKABKLFEB init toggle
#define kRVA_JHACIFHANIL   0x21EC934  // JHACIFHANIL()         — MHJKABKLFEB reset
#define kRVA_HIAKKLNIKFM   0x21E8E48  // HIAKKLNIKFM(bool,int,long) — main mem scan
#define kRVA_NLJNAOBBPEA   0x21E98BC  // NLJNAOBBPEA(...)      — file hash check
#define kRVA_BGBNLKACBPM   0x21E93AC  // scan trigger A
#define kRVA_DLNECOKKAHG   0x21E94F0  // scan trigger B
#define kRVA_MGKBGGIMJFD_S 0x21EA500  // MGKBGGIMJFD(string)   — report builder
#define kRVA_MGKBGGIMJFD_B 0x21EA690  // MGKBGGIMJFD(byte[])   — report builder

// arm64 patch bytes
static const uint8_t kRET[4]      = { 0xC0, 0x03, 0x5F, 0xD6 };
static const uint8_t kRET_ZERO[8] = { 0x00, 0x00, 0x80, 0xD2,   // MOV X0, #0
                                       0xC0, 0x03, 0x5F, 0xD6 }; // RET

// ─────────────────────────────────────────────────────────────────────────────
//  Neutral Seed 322B (from AntibanPatchService.swift — SHA-256 verified)
//  Written to Documents/Assembly-CSharp-patch.bytes to prevent TSS file scan
//  from finding the real patch bytes. The neutral seed is a valid-looking
//  but benign IFix payload that passes the file hash check.
// ─────────────────────────────────────────────────────────────────────────────
static NSData *neutralSeedData(void) {
    static NSData *seed = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        uint8_t raw[] = {
            0xcb, 0xa2, 0xb4, 0x0d, 0xb2, 0x19, 0xa3, 0x66, 0x64, 0x49, 0x46, 0x69,
            0x78, 0x2e, 0x49, 0x4c, 0x46, 0x69, 0x78, 0x49, 0x6e, 0x74, 0x65, 0x72,
            0x66, 0x61, 0x63, 0x65, 0x42, 0x72, 0x69, 0x64, 0x67, 0x65, 0x2c, 0x20,
            0x41, 0x73, 0x73, 0x65, 0x6d, 0x62, 0x6c, 0x79, 0x2d, 0x43, 0x53, 0x68,
            0x61, 0x72, 0x70, 0x2c, 0x20, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e,
            0x3d, 0x30, 0x2e, 0x38, 0x36, 0x2e, 0x30, 0x2e, 0x35, 0x31, 0x38, 0x2c,
            0x20, 0x43, 0x75, 0x6c, 0x74, 0x75, 0x72, 0x65, 0x3d, 0x6e, 0x65, 0x75,
            0x74, 0x72, 0x61, 0x6c, 0x2c, 0x20, 0x50, 0x75, 0x62, 0x6c, 0x69, 0x63,
            0x4b, 0x65, 0x79, 0x54, 0x6f, 0x6b, 0x65, 0x6e, 0x3d, 0x6e, 0x75, 0x6c,
            0x6c,
            // 28 zero bytes
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // part2
            0x63, 0x49, 0x46, 0x69, 0x78, 0x2e, 0x57, 0x72, 0x61, 0x70, 0x70, 0x65,
            0x72, 0x73, 0x4d, 0x61, 0x6e, 0x61, 0x67, 0x65, 0x72, 0x49, 0x6d, 0x70,
            0x6c, 0x2c, 0x20, 0x41, 0x73, 0x73, 0x65, 0x6d, 0x62, 0x6c, 0x79, 0x2d,
            0x43, 0x53, 0x68, 0x61, 0x72, 0x70, 0x2c, 0x20, 0x56, 0x65, 0x72, 0x73,
            0x69, 0x6f, 0x6e, 0x3d, 0x30, 0x2e, 0x38, 0x36, 0x2e, 0x30, 0x2e, 0x35,
            0x31, 0x38, 0x2c, 0x20, 0x43, 0x75, 0x6c, 0x74, 0x75, 0x72, 0x65, 0x3d,
            0x6e, 0x65, 0x75, 0x74, 0x72, 0x61, 0x6c, 0x2c, 0x20, 0x50, 0x75, 0x62,
            0x6c, 0x69, 0x63, 0x4b, 0x65, 0x79, 0x54, 0x6f, 0x6b, 0x65, 0x6e, 0x3d,
            0x6e, 0x75, 0x6c, 0x6c, 0x4b, 0x2c, 0x20, 0x41, 0x73, 0x73, 0x65, 0x6d,
            0x62, 0x6c, 0x79, 0x2d, 0x43, 0x53, 0x68, 0x61, 0x72, 0x70, 0x2c, 0x20,
            0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x3d, 0x30, 0x2e, 0x38, 0x36,
            0x2e, 0x30, 0x2e, 0x35, 0x31, 0x38, 0x2c, 0x20, 0x43, 0x75, 0x6c, 0x74,
            0x75, 0x72, 0x65, 0x3d, 0x6e, 0x65, 0x75, 0x74, 0x72, 0x61, 0x6c, 0x2c,
            0x20, 0x50, 0x75, 0x62, 0x6c, 0x69, 0x63, 0x4b, 0x65, 0x79, 0x54, 0x6f,
            0x6b, 0x65, 0x6e, 0x3d, 0x6e, 0x75, 0x6c, 0x6c,
            // 9 zero bytes
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        };
        seed = [NSData dataWithBytes:raw length:sizeof(raw)]; // 322 bytes
    });
    return seed;
}

static const char *kSafeConfig = "{\"testCodePatch\":true}\n";

// ─────────────────────────────────────────────────────────────────────────────
//  38 telemetry paths from AntibanPatchService.swift (Delta Mach-O extract)
//  These are relative paths inside the game container
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *telemetryPaths(void) {
    static NSArray *paths = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        paths = @[
            // File reports, crash dumps, telemetry logs
            @"Documents/report",          @"Documents/analytics",
            @"Documents/crash_dump",      @"Documents/beacon",
            @"Documents/feedback",        @"Documents/GCloud",
            @"Documents/MidasLog",        @"Documents/shadow_tracker",
            @"Documents/tencent_tdid",    @"Documents/anti_cheat_logs",
            @"Documents/vng_log",         @"Documents/msdk_log",
            @"Documents/garena_log",      @"Documents/gvoice",
            @"Documents/dp_log",          @"Documents/oss_log",
            @"Documents/upload",          @"Documents/pending_reports",
            // Behaviour analytics + crash SDK caches
            @"Library/Caches/Analytics",           @"Library/Caches/CrashReporter",
            @"Library/Caches/com.crashlytics.data",@"Library/Caches/crashes",
            @"Library/Caches/GCloud",              @"Library/Caches/GVoice",
            @"Library/Caches/com.google.firebase", @"Library/Caches/com.appsflyer",
            @"Library/Caches/adjust-sdk",          @"Library/Caches/bugly",
            @"Library/Caches/Snapshots",
            // File hash / integrity databases
            @"Documents/contentcache/res_version.hash",
            @"Documents/contentcache/file_hash.bin",
            @"Documents/contentcache/verify_cache.dat",
            @"Documents/contentcache/crc_cache.bin",
            @"Documents/contentcache/asset_verify.db",
            @"Documents/contentcache/patch_verify.dat",
            @"Documents/contentcache/resource_manifest.json",
            @"Documents/contentcache/checksum.bin",
            @"Documents/contentcache/integrity_db.sqlite",
            @"Documents/contentcache",
            // Bugly SDK preferences
            @"Library/Preferences/com.tencent.bugly",
            // Additional (from proxyapp + previous analysis)
            @"Documents/ffrtc_log.txt",
            @"Documents/ff_magicvoice_log.txt",
            @"Documents/BackendJsonLog",
            @"Library/Caches/Firebase",
            @"Library/Caches/Crashlytics",
            @"Library/Caches/Cache.db",
            @"Library/Caches/Cache.db-shm",
            @"Library/Caches/Cache.db-wal",
            @"Library/Caches/fsCachedData",
            @"tmp/Analytics", @"tmp/CrashReporter",
            @"tmp/crashes",   @"tmp/bugly",
        ];
    });
    return paths;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container resolution via metadata plist
//  Requires: com.apple.private.security.no-sandbox
//            com.apple.private.security.storage.AppDataContainers
// ─────────────────────────────────────────────────────────────────────────────
static NSString * _Nullable resolveContainerPath(NSString *bundleID) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *uuid in [[NSFileManager defaultManager]
                              contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir  = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [dir stringByAppendingPathComponent:
                            @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([d[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) return dir;
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dirs to watch with vnode source
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *watchedRelDirs(void) {
    return @[
        @"Documents",
        @"Documents/contentcache",
        @"Library/Caches",
        @"Library/Preferences",
        @"tmp"
    ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  _write from pid.mm — mach_vm_write via kernel task, bypasses page protection
// ─────────────────────────────────────────────────────────────────────────────
extern bool _write(long addr, const void *buffer, int len);
extern bool _read(long addr, void *buffer, int len);

static uint64_t getUnityBase(void) {
    if (get_task == MACH_PORT_NULL) return 0;
    mach_vm_address_t base = get_image_base_address(get_task, "UnityFramework");
    if (!base) base = get_image_base_address(get_task, "FreeFire");
    return (uint64_t)base;
}

static BOOL patchAt(uint64_t base, uint64_t rva, const uint8_t *bytes, size_t len) {
    if (!base) return NO;
    return _write((long)(base + rva), bytes, (int)len) ? YES : NO;
}

// ─────────────────────────────────────────────────────────────────────────────
//  5-tier bypass
// ─────────────────────────────────────────────────────────────────────────────
static void applyBypass(uint64_t base) {
    if (!base) return;
    // Tier 1 — Kill RunOneFrame → no TSS tick
    patchAt(base, kRVA_MOFOEPHILGO,   kRET,      4);
    // Tier 2 — Kill both SendAntiDataToServer paths → no upload
    patchAt(base, kRVA_GIFIAMDDLOC,   kRET,      4);
    patchAt(base, kRVA_DLIDMJONJKE,   kRET,      4);
    // Tier 3 — Kill MHJKABKLFEB scan + hash check → return 0 (clean)
    patchAt(base, kRVA_HIAKKLNIKFM,   kRET_ZERO, 8);
    patchAt(base, kRVA_NLJNAOBBPEA,   kRET_ZERO, 8);
    patchAt(base, kRVA_BGBNLKACBPM,   kRET_ZERO, 8);
    patchAt(base, kRVA_DLNECOKKAHG,   kRET_ZERO, 8);
    // Tier 4 — Kill report builders → return 0
    patchAt(base, kRVA_MGKBGGIMJFD_S, kRET_ZERO, 8);
    patchAt(base, kRVA_MGKBGGIMJFD_B, kRET_ZERO, 8);
    // Tier 5 — Block re-init
    patchAt(base, kRVA_JAMOJCJLJNG,   kRET,      4);
    patchAt(base, kRVA_INICGCCOGEC,   kRET,      4);
    NSLog(@"[ANTIBAN] bypass applied @ base 0x%llx", base);
}

static uint64_t _cachedBase = 0;

static void reapplyIfNeeded(void) {
    if (!_cachedBase) _cachedBase = getUnityBase();
    if (!_cachedBase) return;
    // Read first 4 bytes of RunOneFrame — if restored, re-patch
    uint8_t cur[4] = {0};
    _read((long)(_cachedBase + kRVA_MOFOEPHILGO), cur, 4);
    if (memcmp(cur, kRET, 4) != 0) {
        NSLog(@"[ANTIBAN] RunOneFrame restored by TSS — re-patching");
        applyBypass(_cachedBase);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  File-level clean — 38 telemetry paths + Documents wipe
//  Also writes Neutral Seed to Assembly-CSharp-patch.bytes (322 bytes)
//  and safe localConfig.json to prevent TSS file integrity check from
//  flagging the patch bytes file.
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

    // 1. Wipe 38+ telemetry paths
    for (NSString *rel in telemetryPaths()) {
        NSURL *target = [base URLByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:target.path]) continue;

        NSError *err = nil;
        if ([fm removeItemAtURL:target error:&err]) {
            r.deletedCaches++;
        } else {
            // If it's a directory we couldn't remove, wipe its contents
            NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:target
                                             includingPropertiesForKeys:nil
                                                                options:0 error:nil];
            for (NSURL *sub in contents) {
                if ([fm removeItemAtURL:sub error:nil]) r.deletedCaches++;
            }
        }
    }

    // 2. Documents — wipe all files except neutral seed and known-good files
    NSURL *docsURL = [base URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    NSArray<NSURL *> *docItems = [fm contentsOfDirectoryAtURL:docsURL
                                    includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                       options:0 error:nil];
    for (NSURL *item in docItems) {
        NSString *name  = item.lastPathComponent;
        NSString *lower = name.lowercaseString;
        // Keep neutral seed, safe config, dirs, innova files
        if ([lower isEqualToString:@"assembly-csharp-patch.bytes"]) continue;
        if ([lower isEqualToString:@"localconfig.json"])             continue;
        if ([lower hasPrefix:@"innova_cheat_"])                      continue;
        if ([lower isEqualToString:@"contentcache"])                 continue; // already handled
        NSNumber *isDir = nil;
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        if ([fm removeItemAtURL:item error:nil]) r.deletedDocs++;
    }

    // 3. Dynamic keyword scan on Library/Caches
    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    NSArray<NSString *> *keywords = @[
        @"analytics", @"crash", @"bugly", @"firebase",
        @"appsflyer", @"adjust", @"cache.db", @"fscacheddata", @"gcloud", @"gvoice"
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

    // 4. Write Neutral Seed 322B → Assembly-CSharp-patch.bytes
    NSURL *patchFile = [docsURL URLByAppendingPathComponent:@"Assembly-CSharp-patch.bytes"];
    NSData *seed = neutralSeedData();
    BOOL needWrite = YES;
    if ([fm fileExistsAtPath:patchFile.path]) {
        NSData *existing = [NSData dataWithContentsOfURL:patchFile];
        if (existing.length == seed.length && [existing isEqualToData:seed]) needWrite = NO;
    }
    if (needWrite) {
        [fm createDirectoryAtURL:docsURL withIntermediateDirectories:YES attributes:nil error:nil];
        [seed writeToURL:patchFile atomically:YES];
    }

    // 5. Write safe localConfig.json
    NSURL *cfgFile = [docsURL URLByAppendingPathComponent:@"localConfig.json"];
    if (![fm fileExistsAtPath:cfgFile.path]) {
        NSData *cfg = [NSData dataWithBytes:kSafeConfig length:strlen(kSafeConfig)];
        [cfg writeToURL:cfgFile atomically:YES];
    }

    // 6. Bundle ID specific caches
    for (NSString *suffix in @[ @"Cache.db", @"Cache.db-shm",
                                 @"Cache.db-wal", @"fsCachedData" ]) {
        NSURL *t = [cachesURL URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@/%@", bundleID, suffix]];
        if ([fm fileExistsAtPath:t.path])
            if ([fm removeItemAtURL:t error:nil]) r.deletedCaches++;
    }

    return r;
}

static AntibanResult performClean(void) {
    reapplyIfNeeded();  // integrity check on every clean tick

    AntibanResult total = {0, 0};
    for (NSString *bid in supportedBundleIDs()) {
        NSString *path = resolveContainerPath(bid);
        if (!path) continue;
        AntibanResult r = cleanContainer(path, bid);
        total.deletedDocs   += r.deletedDocs;
        total.deletedCaches += r.deletedCaches;
    }
    if (total.deletedDocs > 0 || total.deletedCaches > 0)
        NSLog(@"[ANTIBAN] clean docs:%ld caches:%ld",
              (long)total.deletedDocs, (long)total.deletedCaches);
    return total;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Private extension
// ─────────────────────────────────────────────────────────────────────────────
@interface AntibanCleaner ()
@property (nonatomic, assign, readwrite) BOOL          isWatching;
@property (nonatomic, assign, readwrite) AntibanResult lastResult;
@end

@implementation AntibanCleaner {
    dispatch_queue_t           _queue;
    NSLock                    *_lock;
    NSMutableArray<NSValue *> *_sourceRefs;
    NSMutableArray<NSNumber *> *_fds;
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

    dispatch_async(_queue, ^{
        // Apply bypass immediately when game starts
        _cachedBase = getUnityBase();
        if (_cachedBase) applyBypass(_cachedBase);
        // First clean pass
        self.lastResult = performClean();
    });

    // Open vnode watchers on all container subdirs
    NSMutableArray<NSString *> *dirsToWatch = [NSMutableArray new];
    for (NSString *bid in supportedBundleIDs()) {
        NSString *container = resolveContainerPath(bid);
        if (!container) continue;
        for (NSString *rel in watchedRelDirs()) {
            NSString *abs = [container stringByAppendingPathComponent:rel];
            [[NSFileManager defaultManager]
                createDirectoryAtPath:abs withIntermediateDirectories:YES
                           attributes:nil error:nil];
            [dirsToWatch addObject:abs];
        }
    }

    for (NSString *dir in dirsToWatch) {
        int fd = open(dir.UTF8String, O_EVTONLY);
        if (fd < 0) { NSLog(@"[ANTIBAN] open fd failed: %@", dir); continue; }
        [_fds addObject:@(fd)];

        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB, _queue);

        dispatch_source_set_event_handler(src, ^{
            // Any file write in a watched dir → immediate clean + bypass check
            self.lastResult = performClean();
        });
        int fdCopy = fd;
        dispatch_source_set_cancel_handler(src, ^{ close(fdCopy); });
        dispatch_resume(src);

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
    _cachedBase = 0;

    dispatch_async(_queue, ^{ self.lastResult = performClean(); });
    self.isWatching = NO;
    [_lock unlock];
}

@end
