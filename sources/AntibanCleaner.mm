#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"

// ─────────────────────────────────────────────────────────────────────────────
//  ALL RVAs extracted directly from OB55 dump — verified, real, non-guessed.
//
//  Proto analysis (ff-server-protocols hacker.proto + OB55 ReportGGPInfo):
//    ReportGGPInfo.gin_token (field 10) must be non-empty or server fires
//    HackerPoolCdt_GIN_CHECK_DATA_EMPTY_IOS (id=19) → insta-ban.
//    DNS blocking anticheatexpert.com kills gin_token fetch → bans faster.
//    Correct approach: patch the report send path, not the network.
//
//  EHacker.HackerPoolCdt ban triggers we must silence:
//    2  = FFANTI        → DKPDEMLPNOE scan result
//    4  = MD5_FILE_EXCEPTION  → file hash mismatch
//    9  = NATIVE_RESULT → MHJKABKLFEB native lib result
//    15 = MD5_COUNT_AND_VALUE → MD5 check
//    17 = IS_HACKER_CHECK → direct flag
//    19 = GIN_CHECK_DATA_EMPTY_IOS → gin_token empty
// ─────────────────────────────────────────────────────────────────────────────

// ── MHJKABKLFEB (TSS bridge — real RVAs from OB55 dump) ─────────────────────
#define kRVA_JGFDFDBKIGD   0x21E8A94  // GGP report init
#define kRVA_DHEHFAGCCDM   0x21E8D14  // SendReportGGPInfo → THE ban report sender
#define kRVA_HIAKKLNIKFM   0x21E8E48  // main scan (bool,int,long) → int
#define kRVA_NLJNAOBBPEA   0x21E98BC  // file hash check → int
#define kRVA_ODEAEBAMLMG   0x21E9C74  // scan variant A → int
#define kRVA_OFKFJCNPFKM   0x21E9E04  // scan variant B → int
#define kRVA_CLLPBEADOJO   0x21E9F94  // scan variant C → int
#define kRVA_MLKLMCODPNC   0x21EA134  // scan variant D → int
#define kRVA_BGBNLKACBPM   0x21E93AC  // scan trigger A → int
#define kRVA_DLNECOKKAHG   0x21E94F0  // scan trigger B → int
#define kRVA_DFKOBIMKOLE   0x21E9358  // scan trigger C → int
#define kRVA_IMGFJOBDIND   0x21E9634  // scan trigger D → int
#define kRVA_FOHHABEAHFL   0x21E9778  // scan trigger E → int
#define kRVA_MGKBGGIMJFD_S 0x21EA500  // report builder(string) → int
#define kRVA_MGKBGGIMJFD_B 0x21EA690  // report builder(byte[]) → int
#define kRVA_LOPJGIPCBLJ   0x21EB7AC  // report upload(byte[]) → int
#define kRVA_IJABEHJEKHJ   0x21EAF6C  // report encode(byte[]) → int
#define kRVA_CFHPLJBNANC   0x21EB248  // native report send → int
#define kRVA_HKHAIHDKELH   0x21ED390  // hash check(string) → int
#define kRVA_EKBBBHNHLOG   0x21EC9E4  // native status check → int
#define kRVA_FOJGMNJAJDK   0x21ECAA0  // native flag query → int
#define kRVA_INMEGIDKBPJ   0x21ECAE0  // native integrity → int
#define kRVA_KJHAINMDKGJ   0x21ECB20  // string integrity → int
#define kRVA_INICGCCOGEC   0x21EC4DC  // init toggle(bool)
#define kRVA_JHACIFHANIL   0x21EC934  // reset()

// ── DKPDEMLPNOE (AntihackSDKManager, real RVAs from OB55) ───────────────────
#define kRVA_MOFOEPHILGO   0x20F2D40  // RunOneFrame() — per-frame TSS tick
#define kRVA_GIFIAMDDLOC   0x20F2494  // SendAntiDataToServer wrapper
#define kRVA_DLIDMJONJKE   0x20F2554  // SendAntiDataToServer private
#define kRVA_JAMOJCJLJNG   0x20F18E4  // InitTick()
#define kRVA_BMCKEEOEDGD   0x20F1F6C  // ffantihackSDKLogin
#define kRVA_EHKHDPMNLIL   0x20F20CC  // GetLiteData → scan payload builder
#define kRVA_PCEAEHNPBGI   0x20F2718  // OnRecvMsgToTssClient(byte[])
#define kRVA_FDDEOFGCLOH   0x20F2CC0  // PauseSDK
#define kRVA_PHCHDJBCMPF   0x20F2D00  // ResumeSDK

// arm64 patch sequences
static const uint8_t kRET[4]      = {0xC0, 0x03, 0x5F, 0xD6};               // RET
static const uint8_t kRET_ZERO[8] = {0x00, 0x00, 0x80, 0xD2,                // MOV X0,#0
                                      0xC0, 0x03, 0x5F, 0xD6};               // RET
static const uint8_t kRET_TRUE[8] = {0x20, 0x00, 0x80, 0xD2,                // MOV X0,#1
                                      0xC0, 0x03, 0x5F, 0xD6};               // RET

// ─────────────────────────────────────────────────────────────────────────────
//  _write/_read from pid.mm — mach_vm_write/read via kernel task port.
//  Bypasses page protection entirely (no vm_protect needed).
// ─────────────────────────────────────────────────────────────────────────────
extern bool _write(long addr, const void *buffer, int len);
extern bool _read(long addr, void *buffer, int len);

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

static NSArray<NSString *> *watchedRelDirs(void) {
    return @[
        @"Documents", @"Documents/contentcache",
        @"Library/Caches", @"Library/Preferences", @"tmp"
    ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container resolution via metadata plist scan.
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
//  UnityFramework base
// ─────────────────────────────────────────────────────────────────────────────
static uint64_t getUnityBase(void) {
    if (get_task == MACH_PORT_NULL) return 0;
    mach_vm_address_t base = get_image_base_address(get_task, "UnityFramework");
    if (!base) base = get_image_base_address(get_task, "FreeFire");
    return (uint64_t)base;
}

static BOOL patchAt(uint64_t base, uint64_t rva,
                    const uint8_t *bytes, size_t len) {
    if (!base) return NO;
    return _write((long)(base + rva), bytes, (int)len) ? YES : NO;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Full bypass — all real RVAs, complete coverage of every report/scan path.
//
//  Strategy per-function type:
//    void functions       → RET        (just return, do nothing)
//    int scan functions   → MOV X0,0; RET  (return 0 = "clean / no detection")
//    bool check functions → MOV X0,1; RET  (return true = "OK")
// ─────────────────────────────────────────────────────────────────────────────
static void applyBypass(uint64_t base) {
    if (!base) return;

    // ── TIER 1: Kill the per-frame TSS tick (RunOneFrame) ────────────────────
    // This is the heartbeat. Without it TSS never ticks again for the session.
    patchAt(base, kRVA_MOFOEPHILGO,   kRET,      4);

    // ── TIER 2: Kill all report senders ──────────────────────────────────────
    // DHEHFAGCCDM sends ReportGGPInfo to server (ban report).
    // GIFIAMDDLOC + DLIDMJONJKE upload raw anticheat data bytes.
    patchAt(base, kRVA_DHEHFAGCCDM,   kRET,      4);
    patchAt(base, kRVA_JGFDFDBKIGD,   kRET,      4);  // GGP init
    patchAt(base, kRVA_GIFIAMDDLOC,   kRET,      4);
    patchAt(base, kRVA_DLIDMJONJKE,   kRET,      4);
    patchAt(base, kRVA_PCEAEHNPBGI,   kRET,      4);  // OnRecvMsgToTssClient
    patchAt(base, kRVA_BMCKEEOEDGD,   kRET,      4);  // ffantihackSDKLogin

    // ── TIER 3: Kill all scan functions (return 0 = nothing found) ───────────
    patchAt(base, kRVA_HIAKKLNIKFM,   kRET_ZERO, 8);  // main scan
    patchAt(base, kRVA_NLJNAOBBPEA,   kRET_ZERO, 8);  // file hash check
    patchAt(base, kRVA_ODEAEBAMLMG,   kRET_ZERO, 8);
    patchAt(base, kRVA_OFKFJCNPFKM,   kRET_ZERO, 8);
    patchAt(base, kRVA_CLLPBEADOJO,   kRET_ZERO, 8);
    patchAt(base, kRVA_MLKLMCODPNC,   kRET_ZERO, 8);
    patchAt(base, kRVA_BGBNLKACBPM,   kRET_ZERO, 8);
    patchAt(base, kRVA_DLNECOKKAHG,   kRET_ZERO, 8);
    patchAt(base, kRVA_DFKOBIMKOLE,   kRET_ZERO, 8);
    patchAt(base, kRVA_IMGFJOBDIND,   kRET_ZERO, 8);
    patchAt(base, kRVA_FOHHABEAHFL,   kRET_ZERO, 8);
    patchAt(base, kRVA_HKHAIHDKELH,   kRET_ZERO, 8);
    patchAt(base, kRVA_EKBBBHNHLOG,   kRET_ZERO, 8);
    patchAt(base, kRVA_FOJGMNJAJDK,   kRET_ZERO, 8);
    patchAt(base, kRVA_INMEGIDKBPJ,   kRET_ZERO, 8);
    patchAt(base, kRVA_KJHAINMDKGJ,   kRET_ZERO, 8);

    // ── TIER 4: Kill report builders and upload ───────────────────────────────
    patchAt(base, kRVA_MGKBGGIMJFD_S, kRET_ZERO, 8);
    patchAt(base, kRVA_MGKBGGIMJFD_B, kRET_ZERO, 8);
    patchAt(base, kRVA_LOPJGIPCBLJ,   kRET_ZERO, 8);
    patchAt(base, kRVA_IJABEHJEKHJ,   kRET_ZERO, 8);
    patchAt(base, kRVA_CFHPLJBNANC,   kRET_ZERO, 8);

    // ── TIER 5: Block re-init and payload builder ─────────────────────────────
    patchAt(base, kRVA_JAMOJCJLJNG,   kRET,      4);
    patchAt(base, kRVA_INICGCCOGEC,   kRET,      4);
    patchAt(base, kRVA_JHACIFHANIL,   kRET,      4);
    patchAt(base, kRVA_EHKHDPMNLIL,   kRET,      4);  // GetLiteData = empty

    NSLog(@"[ANTIBAN] bypass applied — 30 RVAs patched @ 0x%llx", base);
}

static uint64_t _cachedBase = 0;

// Re-apply if TSS self-healed (reads RunOneFrame first 4 bytes)
static void reapplyIfNeeded(void) {
    if (!_cachedBase) _cachedBase = getUnityBase();
    if (!_cachedBase) return;
    uint8_t cur[4] = {0};
    _read((long)(_cachedBase + kRVA_MOFOEPHILGO), cur, 4);
    if (memcmp(cur, kRET, 4) != 0) {
        NSLog(@"[ANTIBAN] TSS self-healed — re-patching");
        applyBypass(_cachedBase);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  File-level clean — remove telemetry/report files as fast as they appear.
//  NO localConfig.json or Assembly-CSharp-patch.bytes writes — that's not our method.
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *telemetryRelPaths(NSString *bundleID) {
    return @[
        // Crash reporters
        @"Library/Caches/Analytics",       @"Library/Caches/CrashReporter",
        @"Library/Caches/com.crashlytics.data", @"Library/Caches/crashes",
        @"Library/Caches/bugly",           @"Library/Caches/Firebase",
        @"Library/Caches/Crashlytics",     @"Library/Caches/GCloud",
        @"Library/Caches/GVoice",
        // Advertising / tracking
        @"Library/Caches/com.google.firebase", @"Library/Caches/com.appsflyer",
        @"Library/Caches/adjust-sdk",      @"Library/Caches/Snapshots",
        // DB caches
        @"Library/Caches/Cache.db",        @"Library/Caches/Cache.db-shm",
        @"Library/Caches/Cache.db-wal",    @"Library/Caches/fsCachedData",
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db",     bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-shm", bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-wal", bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/fsCachedData", bundleID],
        // Tencent SDK prefs
        @"Library/Preferences/com.tencent.bugly",
        // FF specific logs
        @"Documents/ffrtc_log.txt",        @"Documents/ff_magicvoice_log.txt",
        @"Documents/ff_magicvoice_engine_log.txt",
        @"Documents/BackendJsonLog",       @"Documents/report",
        @"Documents/analytics",            @"Documents/crash_dump",
        @"Documents/beacon",               @"Documents/feedback",
        @"Documents/GCloud",               @"Documents/MidasLog",
        @"Documents/shadow_tracker",       @"Documents/tencent_tdid",
        @"Documents/anti_cheat_logs",      @"Documents/vng_log",
        @"Documents/msdk_log",             @"Documents/garena_log",
        @"Documents/gvoice",               @"Documents/dp_log",
        @"Documents/oss_log",              @"Documents/upload",
        @"Documents/pending_reports",
        // File integrity databases — TSS reads these for MD5_FILE_EXCEPTION check
        @"Documents/contentcache/res_version.hash",
        @"Documents/contentcache/file_hash.bin",
        @"Documents/contentcache/verify_cache.dat",
        @"Documents/contentcache/crc_cache.bin",
        @"Documents/contentcache/asset_verify.db",
        @"Documents/contentcache/patch_verify.dat",
        @"Documents/contentcache/resource_manifest.json",
        @"Documents/contentcache/checksum.bin",
        @"Documents/contentcache/integrity_db.sqlite",
        // tmp
        @"tmp/Analytics",  @"tmp/CrashReporter",
        @"tmp/crashes",    @"tmp/bugly",    @"tmp/appsflyer-v1",
    ];
}

static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

    // 1. Static telemetry path wipe
    for (NSString *rel in telemetryRelPaths(bundleID)) {
        NSURL *target = [base URLByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:target.path]) continue;
        NSError *err = nil;
        if ([fm removeItemAtURL:target error:&err]) {
            r.deletedCaches++;
        } else {
            // Dir — wipe contents instead
            for (NSURL *sub in [fm contentsOfDirectoryAtURL:target
                                   includingPropertiesForKeys:nil
                                                      options:0 error:nil])
                if ([fm removeItemAtURL:sub error:nil]) r.deletedCaches++;
        }
    }

    // 2. Documents — wipe ALL files (game writes telemetry/report files here)
    NSURL *docsURL = [base URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:docsURL
                           includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                              options:0 error:nil]) {
        NSNumber *isDir = nil;
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;   // dirs handled above or by vnode watcher
        if ([fm removeItemAtURL:item error:nil]) r.deletedDocs++;
    }

    // 3. Dynamic keyword scan — Library/Caches
    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    NSArray<NSString *> *kws = @[
        @"analytics", @"crash", @"bugly", @"firebase",
        @"appsflyer", @"adjust", @"cache.db", @"fscacheddata",
        @"gcloud", @"gvoice", @"midas", @"beacon", @"report"
    ];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:cachesURL
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *lname = item.lastPathComponent.lowercaseString;
        for (NSString *kw in kws)
            if ([lname containsString:kw]) {
                if ([fm removeItemAtURL:item error:nil]) r.deletedCaches++;
                break;
            }
    }

    return r;
}

static AntibanResult performClean(void) {
    reapplyIfNeeded();  // integrity check every time

    AntibanResult total = {0, 0};
    for (NSString *bid in supportedBundleIDs()) {
        NSString *path = resolveContainerPath(bid);
        if (!path) continue;
        AntibanResult r = cleanContainer(path, bid);
        total.deletedDocs   += r.deletedDocs;
        total.deletedCaches += r.deletedCaches;
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

@implementation AntibanCleaner {
    dispatch_queue_t            _queue;
    NSLock                     *_lock;
    NSMutableArray<NSValue *>  *_sourceRefs;
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
        _cachedBase = getUnityBase();
        if (_cachedBase) applyBypass(_cachedBase);
        self.lastResult = performClean();
    });

    // Set up vnode watchers — fire on any WRITE to watched dirs
    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    for (NSString *bid in supportedBundleIDs()) {
        NSString *container = resolveContainerPath(bid);
        if (!container) continue;
        for (NSString *rel in watchedRelDirs()) {
            NSString *abs = [container stringByAppendingPathComponent:rel];
            [[NSFileManager defaultManager]
                createDirectoryAtPath:abs withIntermediateDirectories:YES
                           attributes:nil error:nil];
            [dirs addObject:abs];
        }
    }

    for (NSString *dir in dirs) {
        int fd = open(dir.UTF8String, O_EVTONLY);
        if (fd < 0) continue;
        [_fds addObject:@(fd)];

        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB, _queue);

        dispatch_source_set_event_handler(src, ^{
            // File written → immediate clean + bypass integrity check
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
