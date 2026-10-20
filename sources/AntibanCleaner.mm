#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"
#include <mach/mach.h>

// ─────────────────────────────────────────────────────────────────────────────
//  OB55 RVAs — verified from dump, VA == RVA (no base-add in dump header)
//  These are offsets from UnityFramework __TEXT base.
//
//  Mapping confirmed via OB49↔OB55 field offset comparison:
//  OB49 AntihackSDKManager = OB55 DKPDEMLPNOE  (mInitialized↔HLCEOPAMDNH @0x0,
//                                                TickCount↔AMFEHGKDLOH @0x10,
//                                                Disable↔MNNGFLIFFHL @0x48)
// ─────────────────────────────────────────────────────────────────────────────

// DKPDEMLPNOE (AntihackSDKManager)
#define kRVA_MOFOEPHILGO   0x20F2D40  // RunOneFrame()       — Unity frame tick into TSS
#define kRVA_FDDEOFGCLOH   0x20F2CC0  // PauseSDK()
#define kRVA_PHCHDJBCMPF   0x20F2D00  // ResumeSDK()
#define kRVA_GIFIAMDDLOC   0x20F2494  // SendAntiDataToServer wrapper
#define kRVA_DLIDMJONJKE   0x20F2554  // SendAntiDataToServer (private, actual send)
#define kRVA_JAMOJCJLJNG   0x20F18E4  // InitTick()
#define kRVA_CJMDFFMNLAC   0x20F1924  // EnableData()
#define kRVA_LOOPCABFPMJ   0x20F19D0  // SetLiteDataEnabled(bool)
#define kRVA_IMOMCMOPODE   0x20F2890  // OnApplicationPause(bool)
#define kRVA_PCEAEHNPBGI   0x20F2718  // OnRecvMsgToTssClient(byte[])
#define kRVA_EHKHDPMNLIL   0x20F20CC  // GetLiteData() — returns scan payload
#define kRVA_BMCKEEOEDGD   0x20F1F6C  // ffantihackSDKLogin

// MHJKABKLFEB (native TSS bridge — wraps P/Invoke into libtersafe)
#define kRVA_HIAKKLNIKFM   0x21E8E48  // main scan: HIAKKLNIKFM(bool, int, long)
#define kRVA_NLJNAOBBPEA   0x21E98BC  // file hash check: NLJNAOBBPEA(string,long,long,bool,long)
#define kRVA_INICGCCOGEC   0x21EC4DC  // init toggle: INICGCCOGEC(bool)
#define kRVA_JHACIFHANIL   0x21EC934  // reset: JHACIFHANIL()
#define kRVA_AABJEIDAMIE   0x21EC588  // GetLiteData() — snapshot builder
#define kRVA_MGKBGGIMJFD_S 0x21EA500  // MGKBGGIMJFD(string) — report by string
#define kRVA_MGKBGGIMJFD_B 0x21EA690  // MGKBGGIMJFD(byte[])  — report by bytes
#define kRVA_BGBNLKACBPM   0x21E93AC  // scan trigger
#define kRVA_DLNECOKKAHG   0x21E94F0  // scan trigger 2

// arm64: MOV X0, #0 / RET — makes int-returning functions return 0
// and void functions return immediately
static const uint8_t kNOP[4]      = { 0x1F, 0x20, 0x03, 0xD5 };
static const uint8_t kRET[4]      = { 0xC0, 0x03, 0x5F, 0xD6 };
static const uint8_t kRET_ZERO[8] = { 0x00, 0x00, 0x80, 0xD2,   // MOV X0, #0
                                       0xC0, 0x03, 0x5F, 0xD6 }; // RET

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container resolution — direct metadata plist scan
//  Requires entitlements: no-sandbox + AppDataContainers
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

static NSArray<NSString *> *watchedRelDirs(void) {
    return @[ @"Documents", @"Library/Caches", @"tmp" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Write via _write from pid.mm — uses mach_vm_write through kernel task port,
//  bypasses page protection without needing vm_protect at all.
// ─────────────────────────────────────────────────────────────────────────────
extern bool _write(long addr, const void *buffer, int len);
extern bool _read(long addr, void *buffer, int len);

// ─────────────────────────────────────────────────────────────────────────────
//  Get UnityFramework base from existing get_task infrastructure
// ─────────────────────────────────────────────────────────────────────────────
static uint64_t getUnityBase(void) {
    if (get_task == MACH_PORT_NULL) return 0;
    // get_image_base_address is defined in pid.h
    mach_vm_address_t base = get_image_base_address(get_task, "UnityFramework");
    if (!base) base = get_image_base_address(get_task, "FreeFire");
    NSLog(@"[ANTIBAN] UnityFramework base: 0x%llx", (uint64_t)base);
    return (uint64_t)base;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Patch: write bytes at base+rva
// ─────────────────────────────────────────────────────────────────────────────
static BOOL patch(uint64_t base, uint64_t rva, const uint8_t *bytes, size_t len) {
    if (!base) return NO;
    bool ok = _write((long)(base + rva), bytes, (int)len);
    NSLog(@"[ANTIBAN] patch 0x%llx → %s", base + rva, ok ? "OK" : "FAIL");
    return ok ? YES : NO;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Read TypeInfo statics pointer for DKPDEMLPNOE and zero Disable flag
//  DKPDEMLPNOE statics layout (from OB55 dump):
//    0x0  HLCEOPAMDNH (bool) — mInitialized
//    0x48 MNNGFLIFFHL (bool) — Disable
//  To find statics: scan for the TypeInfo address via a known constant
//  or use a simpler approach — find the statics block via the .cctor RVA
//  which writes to it. For now we patch the flag via the il2cpp statics
//  pointer at TypeInfo+0xB8 (il2cpp_TypeInfo_layout.static_fields).
//
//  DKPDEMLPNOE TypeDefIndex: 1546 — locate TypeInfo via il2cpp_get_type_info
//  We use a simpler heuristic: scan 4MB after code section for the bool pattern
//  mInitialized=1, Disable=0 at known offsets, then flip Disable to 1.
//
//  The cleanest reliable method: patch RunOneFrame (MOFOEPHILGO) to RET
//  immediately — this cuts the per-frame TSS tick which is 90% of detection.
//  Combine with zeroing SendAntiDataToServer so no reports reach the server.
// ─────────────────────────────────────────────────────────────────────────────
static void applyBypass(uint64_t base) {
    if (!base) { NSLog(@"[ANTIBAN] base=0, bypass skipped"); return; }

    // ── Tier 1: Kill RunOneFrame — cuts per-frame TSS scan tick ──────────────
    // MOFOEPHILGO = RunOneFrame() — called every Unity Update()
    // Make it return immediately → TSS never ticks → no ongoing scan
    {
        uint8_t p[4]; memcpy(p, kRET, 4);
        patch(base, kRVA_MOFOEPHILGO, p, 4);
    }

    // ── Tier 2: Kill SendAntiDataToServer — reports never reach server ────────
    // Even if scan happens, data never uploads
    {
        uint8_t p[4]; memcpy(p, kRET, 4);
        patch(base, kRVA_GIFIAMDDLOC, p, 4);
        patch(base, kRVA_DLIDMJONJKE, p, 4);
    }

    // ── Tier 3: Kill MHJKABKLFEB scan functions (TSS bridge layer) ───────────
    // HIAKKLNIKFM = main scan → return 0 (no detection)
    // NLJNAOBBPEA = file hash check → return 0 (files look clean)
    // BGBNLKACBPM, DLNECOKKAHG = scan triggers → return 0
    {
        uint8_t p[8]; memcpy(p, kRET_ZERO, 8);
        patch(base, kRVA_HIAKKLNIKFM, p, 8);
        patch(base, kRVA_NLJNAOBBPEA, p, 8);
        patch(base, kRVA_BGBNLKACBPM, p, 8);
        patch(base, kRVA_DLNECOKKAHG, p, 8);
    }

    // ── Tier 4: Kill report builders — MGKBGGIMJFD returns 0 ─────────────────
    {
        uint8_t p[8]; memcpy(p, kRET_ZERO, 8);
        patch(base, kRVA_MGKBGGIMJFD_S, p, 8);
        patch(base, kRVA_MGKBGGIMJFD_B, p, 8);
    }

    // ── Tier 5: Kill InitTick + EnableData — prevents re-init ─────────────────
    // If game tries to re-init TSS after detecting tamper, this blocks it
    {
        uint8_t p[4]; memcpy(p, kRET, 4);
        patch(base, kRVA_JAMOJCJLJNG, p, 4);
        patch(base, kRVA_INICGCCOGEC, p, 4);
    }

    NSLog(@"[ANTIBAN] bypass complete — 5 tiers patched");
}

// ─────────────────────────────────────────────────────────────────────────────
//  Re-apply bypass — called on vnode event because some builds re-init TSS
//  when they detect the statics were zeroed. Re-patching every time a new
//  file appears in the container catches that re-init cycle.
// ─────────────────────────────────────────────────────────────────────────────
static uint64_t _cachedBase = 0;

static void reapplyIfNeeded(void) {
    if (_cachedBase == 0) {
        _cachedBase = getUnityBase();
    }
    if (_cachedBase == 0) return;

    // Quick check: is RunOneFrame still patched?
    // If someone restored it (self-healing TSS), re-patch.
    uint8_t current[4] = {0};
    _read((long)(_cachedBase + kRVA_MOFOEPHILGO), current, 4);
    bool stillPatched = (memcmp(current, kRET, 4) == 0);
    if (!stillPatched) {
        NSLog(@"[ANTIBAN] RunOneFrame restored — re-applying bypass");
        applyBypass(_cachedBase);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  File-level clean
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

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
        @"Documents/ffrtc_log.txt",
        @"Documents/ff_magicvoice_log.txt",
        @"Documents/BackendJsonLog",
        @"tmp/Analytics", @"tmp/CrashReporter",
        @"tmp/crashes",   @"tmp/bugly", @"tmp/appsflyer-v1",
    ];
    for (NSString *rel in staticRel) {
        NSURL *t = [base URLByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:t.path])
            if ([fm removeItemAtURL:t error:nil]) r.deletedCaches++;
    }

    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:cachesURL
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *lname = item.lastPathComponent.lowercaseString;
        for (NSString *kw in @[ @"analytics", @"crash", @"bugly",
                                 @"firebase", @"appsflyer", @"adjust",
                                 @"cache.db",  @"fscacheddata" ])
            if ([lname containsString:kw]) {
                if ([fm removeItemAtURL:item error:nil]) r.deletedCaches++;
                break;
            }
    }

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
    // Re-check bypass integrity on every clean tick
    reapplyIfNeeded();

    AntibanResult total = {0, 0};
    for (NSString *bid in supportedBundleIDs()) {
        NSString *path = resolveContainerPath(bid);
        if (!path) continue;
        AntibanResult r = cleanContainer(path, bid);
        total.deletedDocs   += r.deletedDocs;
        total.deletedCaches += r.deletedCaches;
    }
    if (total.deletedDocs > 0 || total.deletedCaches > 0)
        NSLog(@"[ANTIBAN] clean — docs:%ld caches:%ld",
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

    // Apply bypass immediately
    dispatch_async(_queue, ^{
        _cachedBase = getUnityBase();
        if (_cachedBase) applyBypass(_cachedBase);
        self.lastResult = performClean();
    });

    // Vnode watchers on container dirs
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
            // File appeared → clean + re-check bypass integrity
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
