#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"
#include <mach/mach.h>

// ─────────────────────────────────────────────────────────────────────────────
//  REAL ANTICHEAT ARCHITECTURE (from ff-ace-anticheat-analysis research):
//
//  FreeFire uses TWO independent native ACE libs:
//    libanogs.so — main scanner + report builder + kill chain
//    libanort.so — secondary file scanner + cert checker + upload
//
//  The il2cpp OB55 DKPDEMLPNOE/MHJKABKLFEB classes are thin C# WRAPPERS
//  that forward data to these native libs. Patching the C# wrappers is useless
//  because the native libs run on their own threads independently.
//
//  CRITICAL DETECTION VECTOR (from tfp_and_pft_detect research):
//  FreeFire/libanogs detects task_for_pid() via csops(CS_OPS_STATUS) →
//  bit CS_INVALID_ALLOWED (0x20) is SET by the kernel whenever ANY process
//  acquires the game's task port (even via pid_for_task workaround).
//  This means our external cheat IS DETECTED at the OS level before any scan.
//
//  CORRECT BYPASS STRATEGY:
//  1. Zero the .bss kill-switch flags in libanogs that gate all report building:
//       byte_3DB1EC (g_tdm_report_enabled) → 0  = silent drop on all reports
//       byte_3DB1ED (g_tdm_report_checked) → 1  = prevents re-init of reporting
//  2. Patch sub_3653D4 @ 0x3653D4 (TDM Report Packer) → MOV R0,#0; BX LR
//     (Thumb instruction pair: 00 20 70 47)
//  3. Patch init self-kill @ 0xDC146 → NOP NOP (Thumb: 00 BF 00 BF)
//     so init_info validation doesn't SIGKILL us
//  4. Patch tracer watchdog sub_15BE28 @ 0x15BE28 → BX LR (Thumb: 70 47)
//  5. File-level clean of telemetry files that libanort reads
//
//  WHY THIS WORKS:
//  - byte_3DB1EC=0 makes sub_3653D4 return 0 immediately → NO report packet
//    is ever built → sub_365540 (submit_corereport) is never called → server
//    never receives ban evidence → no ban regardless of what ACE detects
//  - This is PROVEN from decompiled sub_3653D4 pseudocode (kill_chain.md)
//
//  NOTE: CS_INVALID_ALLOWED detection means server already knows we use an
//  external cheat. The goal of byte_3DB1EC=0 is to suppress the EVIDENCE
//  that carries the specific ban trigger code (EHacker.HackerPoolCdt).
//
//  LIBANOGS .bss offsets (ARMv7a, OUR build — from kill_chain.md):
#define kANOGS_g_tdm_report_enabled  0x3DB1EC  // byte → write 0x00
#define kANOGS_g_tdm_report_checked  0x3DB1ED  // byte → write 0x01
#define kANOGS_g_corereport_singleton 0x3D6930  // dword
#define kANOGS_g_tdm_fail_count      0x3DB1F0  // dword → write 3 (force self-disable)

//  LIBANOGS function RVAs to patch (all Thumb — add 1 to get Thumb bit):
#define kANOGS_sub_3653D4  0x3653D4  // TDM Report Packer → MOV R0,#0; BX LR
#define kANOGS_sub_DC146   0x0DC146  // init SIGKILL site → NOP; NOP
#define kANOGS_sub_15BE28  0x15BE28  // tracer watchdog → BX LR
#define kANOGS_sub_356618  0x356618  // exit(1) wrapper → BX LR
#define kANOGS_sub_365540  0x365540  // report submit/flush → MOV R0,#0; BX LR

//  LIBANORT secondary pipeline (from PROVEN_DETECTION.md):
#define kANORT_sub_60D86   0x060D86  // report sink → MOV R0,#0; BX LR
#define kANORT_sub_B6CDC   0x0B6CDC  // report builder+upload → MOV R0,#0; BX LR
#define kANORT_sub_58970   0x058970  // detection aggregator → BX LR

// ─────────────────────────────────────────────────────────────────────────────
//  Thumb instruction bytes
//  MOV R0,#0; BX LR = { 0x00, 0x20, 0x70, 0x47 }
//  BX LR            = { 0x70, 0x47 }
//  NOP; NOP (Thumb) = { 0x00, 0xBF, 0x00, 0xBF }
// ─────────────────────────────────────────────────────────────────────────────
static const uint8_t kThumb_RET_ZERO[4] = {0x00, 0x20, 0x70, 0x47}; // MOV R0,#0; BX LR
static const uint8_t kThumb_BX_LR[2]   = {0x70, 0x47};              // BX LR
static const uint8_t kThumb_NOP_NOP[4] = {0x00, 0xBF, 0x00, 0xBF}; // NOP; NOP

// ─────────────────────────────────────────────────────────────────────────────
//  _write/_read from pid.mm (mach_vm_write via kernel task port)
// ─────────────────────────────────────────────────────────────────────────────
extern bool _write(long addr, const void *buffer, int len);
extern bool _read(long addr, void *buffer, int len);

// ─────────────────────────────────────────────────────────────────────────────
//  Simpler: find libanogs/libanort using dyld image list from the game process
//  get_image_base_address is declared in pid.h and already does this for us
// ─────────────────────────────────────────────────────────────────────────────
static uint64_t getLibBase(const char *name) {
    if (get_task == MACH_PORT_NULL) return 0;
    mach_vm_address_t base = get_image_base_address(get_task, name);
    if (base) NSLog(@"[ANTIBAN] %s base=0x%llx", name, (uint64_t)base);
    return (uint64_t)base;
}

static BOOL patchAt(uint64_t base, uint64_t rva,
                    const uint8_t *bytes, size_t len) {
    if (!base) return NO;
    bool ok = _write((long)(base + rva), bytes, (int)len);
    if (!ok) NSLog(@"[ANTIBAN] PATCH FAIL @ 0x%llx+0x%llx", base, rva);
    return ok ? YES : NO;
}

static void writeByte(uint64_t addr, uint8_t val) {
    _write((long)addr, &val, 1);
}

static void writeDword(uint64_t addr, uint32_t val) {
    _write((long)addr, &val, 4);
}

// ─────────────────────────────────────────────────────────────────────────────
//  LIBANOGS BYPASS — proven kill-switch approach from analysis/PROVEN_DETECTION
// ─────────────────────────────────────────────────────────────────────────────
static void bypassLibanogs(uint64_t base) {
    if (!base) return;

    // 1. KILL-SWITCH FLAGS in .bss (no .text scan risk — these are data)
    //    g_tdm_report_enabled = 0  → sub_3653D4 returns 0 immediately
    //    g_tdm_report_checked = 1  → prevents sub_133F6C re-init
    //    fail_count = 3            → engine self-disables (belt+suspenders)
    writeByte(base + kANOGS_g_tdm_report_enabled, 0x00);
    writeByte(base + kANOGS_g_tdm_report_checked, 0x01);
    writeDword(base + kANOGS_g_tdm_fail_count,    3);
    NSLog(@"[ANTIBAN] libanogs .bss kill-switch written");

    // 2. Patch sub_3653D4 (Report Packer) → MOV R0,#0; BX LR
    //    This is SAFE: sub_3653D4 is called by callers that check return != 0
    //    before proceeding to sub_365540 (submit). With 0 return, no submit.
    patchAt(base, kANOGS_sub_3653D4, kThumb_RET_ZERO, 4);

    // 3. Patch sub_365540 (Report Submit/Flush) → MOV R0,#0; BX LR
    //    Double protection: even if 3653D4 is bypassed, submit also returns 0
    patchAt(base, kANOGS_sub_365540, kThumb_RET_ZERO, 4);

    // 4. Patch init self-kill at 0xDC146 → NOP; NOP
    //    kill(getpid(), 9) on init_info validation failure → safely removed
    patchAt(base, kANOGS_sub_DC146, kThumb_NOP_NOP, 4);

    // 5. Patch tracer watchdog sub_15BE28 → BX LR
    //    The SIGSTOP/PTRACE_DETACH/SIGCONT anti-debugger loop is killed
    patchAt(base, kANOGS_sub_15BE28, kThumb_BX_LR, 2);

    // 6. Patch exit(1) wrapper sub_356618 → BX LR
    patchAt(base, kANOGS_sub_356618, kThumb_BX_LR, 2);

    NSLog(@"[ANTIBAN] libanogs bypass done");
}

// ─────────────────────────────────────────────────────────────────────────────
//  LIBANORT BYPASS — secondary pipeline (independent, must handle separately)
// ─────────────────────────────────────────────────────────────────────────────
static void bypassLibanort(uint64_t base) {
    if (!base) return;

    // Kill report sink (8 scanners feed into it)
    patchAt(base, kANORT_sub_60D86, kThumb_RET_ZERO, 4);

    // Kill report builder + upload (sub_B6CDC → formats + submits gamesafe URL)
    patchAt(base, kANORT_sub_B6CDC, kThumb_RET_ZERO, 4);

    // Kill detection aggregator (dispatched via fn-ptr table, runs file scanner)
    patchAt(base, kANORT_sub_58970, kThumb_BX_LR, 2);

    NSLog(@"[ANTIBAN] libanort bypass done");
}

// ─────────────────────────────────────────────────────────────────────────────
//  Integrity re-check: verify kill-switch bytes are still in place
//  (libanogs sub_E24BC rolling checksum VM may restore .bss in some builds)
// ─────────────────────────────────────────────────────────────────────────────
static uint64_t _baseAnogs = 0;
static uint64_t _baseAnort = 0;

static void reapplyIfNeeded(void) {
    if (!_baseAnogs) _baseAnogs = getLibBase("libanogs");
    if (!_baseAnort) _baseAnort = getLibBase("libanort");

    if (_baseAnogs) {
        uint8_t flagVal = 0xFF;
        _read((long)(_baseAnogs + kANOGS_g_tdm_report_enabled), &flagVal, 1);
        if (flagVal != 0x00) {
            NSLog(@"[ANTIBAN] libanogs kill-switch restored — re-applying");
            bypassLibanogs(_baseAnogs);
        }
    }
    if (_baseAnort) {
        uint8_t cur[4] = {0};
        _read((long)(_baseAnort + kANORT_sub_60D86), cur, 4);
        if (memcmp(cur, kThumb_RET_ZERO, 4) != 0) {
            NSLog(@"[ANTIBAN] libanort patch restored — re-applying");
            bypassLibanort(_baseAnort);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs + container resolution
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

static NSArray<NSString *> *watchedRelDirs(void) {
    return @[ @"Documents", @"Library/Caches", @"Library/Preferences", @"tmp" ];
}

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
//  File-level clean — libanort reads these files for cert/hash checks
//  Also libanogs reads /proc/self/maps and certain cache paths
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

    // Static telemetry paths (from proxyapp analysis + PROVEN_DETECTION.md)
    NSArray<NSString *> *paths = @[
        @"Library/Caches/Analytics",       @"Library/Caches/CrashReporter",
        @"Library/Caches/com.crashlytics.data", @"Library/Caches/crashes",
        @"Library/Caches/bugly",           @"Library/Caches/Firebase",
        @"Library/Caches/Crashlytics",     @"Library/Caches/GCloud",
        @"Library/Caches/GVoice",          @"Library/Caches/com.google.firebase",
        @"Library/Caches/com.appsflyer",   @"Library/Caches/adjust-sdk",
        @"Library/Caches/Snapshots",       @"Library/Caches/Cache.db",
        @"Library/Caches/Cache.db-shm",    @"Library/Caches/Cache.db-wal",
        @"Library/Caches/fsCachedData",
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db",     bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-shm", bundleID],
        [NSString stringWithFormat:@"Library/Caches/%@/Cache.db-wal", bundleID],
        @"Library/Preferences/com.tencent.bugly",
        @"Documents/ffrtc_log.txt",        @"Documents/ff_magicvoice_log.txt",
        @"Documents/BackendJsonLog",       @"Documents/report",
        @"Documents/analytics",            @"Documents/crash_dump",
        @"Documents/beacon",               @"Documents/GCloud",
        @"Documents/MidasLog",             @"Documents/shadow_tracker",
        @"Documents/tencent_tdid",         @"Documents/anti_cheat_logs",
        @"Documents/vng_log",              @"Documents/upload",
        @"Documents/pending_reports",
        @"tmp/Analytics", @"tmp/CrashReporter", @"tmp/crashes", @"tmp/bugly",
    ];

    for (NSString *rel in paths) {
        NSURL *target = [base URLByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:target.path]) continue;
        NSError *err = nil;
        if ([fm removeItemAtURL:target error:&err]) {
            r.deletedCaches++;
        } else {
            for (NSURL *sub in [fm contentsOfDirectoryAtURL:target
                                    includingPropertiesForKeys:nil options:0 error:nil])
                if ([fm removeItemAtURL:sub error:nil]) r.deletedCaches++;
        }
    }

    // Wipe all files in Documents (game writes telemetry here constantly)
    NSURL *docsURL = [base URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:docsURL
                           includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                              options:0 error:nil]) {
        NSNumber *isDir = nil;
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        if ([fm removeItemAtURL:item error:nil]) r.deletedDocs++;
    }

    // Dynamic keyword scan on Library/Caches
    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:cachesURL
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *lname = item.lastPathComponent.lowercaseString;
        for (NSString *kw in @[@"analytics",@"crash",@"bugly",@"firebase",
                                @"appsflyer",@"adjust",@"cache.db",@"gcloud",
                                @"gvoice",@"midas",@"beacon",@"report"])
            if ([lname containsString:kw]) {
                if ([fm removeItemAtURL:item error:nil]) r.deletedCaches++;
                break;
            }
    }

    return r;
}

static AntibanResult performClean(void) {
    // Always re-check bypass integrity
    reapplyIfNeeded();

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
        // Apply bypass immediately on game start
        _baseAnogs = getLibBase("libanogs");
        _baseAnort = getLibBase("libanort");
        if (_baseAnogs) bypassLibanogs(_baseAnogs);
        if (_baseAnort) bypassLibanort(_baseAnort);
        self.lastResult = performClean();
    });

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
    _baseAnogs = 0;
    _baseAnort = 0;

    dispatch_async(_queue, ^{ self.lastResult = performClean(); });
    self.isWatching = NO;
    [_lock unlock];
}

@end
