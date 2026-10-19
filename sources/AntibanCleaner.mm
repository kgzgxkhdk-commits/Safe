#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"
#include <mach/mach.h>

// ─────────────────────────────────────────────────────────────────────────────
//  Offsets from OB55 dump — ffantihack namespace
//  DKPDEMLPNOE TypeDefIndex: 1546, MHJKABKLFEB TypeDefIndex: 1548
// ─────────────────────────────────────────────────────────────────────────────

// GameFacade TypeInfo base — used to reach static fields
#define kGameFacadeTypeInfo      0xBB46A50

// DKPDEMLPNOE static fields (class statics, accessed via TypeInfo → statics ptr)
// Field offsets relative to static data block
#define kDKP_HLCEOPAMDNH         0x0     // bool — main anticheat enabled
#define kDKP_AMFEHGKDLOH         0x10    // uint — anticheat mode mask
#define kDKP_MNNGFLIFFHL         0x48    // bool — report enabled flag
#define kDKP_KLLMGALOPFG         0x44    // float — scan interval

// MHJKABKLFEB static fields
#define kMHJ_MFDMLAKBGLE         0x58    // bool — scan active
#define kMHJ_LCMPBHLJPHP         0x59    // bool — file check active
#define kMHJ_CJDEMMJEKGD         0x5A    // bool — mem check active
#define kMHJ_BJDPHDOPHLI         0x5B    // bool — process check active
#define kMHJ_GFMCEHCMABG         0x5C    // bool — behaviour check active
#define kMHJ_KDAEOKLFPCM         0x70    // int — detection result code

// DKPDEMLPNOE method RVAs (from dump, VA = offset from module base)
#define kRVA_LOOPCABFPMJ         0x20F19D0   // void LOOPCABFPMJ(bool) — anticheat loop toggle
#define kRVA_IMOMCMOPODE         0x20F2890   // void IMOMCMOPODE(bool) — report loop toggle
#define kRVA_BKIHNKHJHAM         0x20F172C   // void BKIHNKHJHAM(string, bool)

// MHJKABKLFEB method RVAs
#define kRVA_HIAKKLNIKFM         0x21E8E48   // int HIAKKLNIKFM(bool, int, long) — main scan
#define kRVA_NLJNAOBBPEA         0x21E98BC   // int NLJNAOBBPEA(string, long, long, bool, long) — file hash
#define kRVA_INICGCCOGEC         0x21EC4DC   // void INICGCCOGEC(bool) — init toggle
#define kRVA_JHACIFHANIL         0x21EC934   // void JHACIFHANIL() — reset

// ─────────────────────────────────────────────────────────────────────────────
//  Bundle IDs
// ─────────────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *supportedBundleIDs(void) {
    return @[ @"com.dts.freefireth", @"com.dts.freefiremax" ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  Container resolution — direct metadata scan
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
//  Patch one byte at an RVA within the game's dyld-loaded image.
//  Writes NOP (0x1F 0x20 0x03 0xD5 on arm64) over the function prologue
//  so the anticheat method returns immediately.
// ─────────────────────────────────────────────────────────────────────────────

// arm64 NOP and RET instruction bytes
static const uint8_t kNOP4[4] = { 0x1F, 0x20, 0x03, 0xD5 };
static const uint8_t kRET[4]  = { 0xC0, 0x03, 0x5F, 0xD6 };

// Get game module base — uses get_image_base_address from pid.h
// get_task is populated by the esp layer when it first reads game memory
static uint64_t getGameBase(void) {
    // get_task is already set by pid.mm when esp first accesses the game.
    // get_image_base_address finds UnityFramework (the main il2cpp binary).
    if (get_task == MACH_PORT_NULL) return 0;
    mach_vm_address_t base = get_image_base_address(get_task, "UnityFramework");
    if (!base) base = get_image_base_address(get_task, "FreeFire");
    return (uint64_t)base;
}

// Write raw bytes into the game process at base + rva using the existing task port
// _write is declared in pid.mm — uses mach_vm_write via kernel task port,
// which bypasses page protection entirely (no vm_protect needed).
extern bool _write(long addr, const void *buffer, int len);

static BOOL patchGameBytes(uint64_t base, uint64_t rva,
                            const uint8_t *bytes, size_t len) {
    if (base == 0) return NO;
    long va = (long)(base + rva);
    bool ok = _write(va, bytes, (int)len);
    if (!ok) NSLog(@"[ANTIBAN] _write failed @ 0x%lx", va);
    return ok ? YES : NO;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Bypass — patch anticheat functions to return immediately (NOP+RET)
//  and zero out the static enable flags via kernel W
// ─────────────────────────────────────────────────────────────────────────────
static void applyAnticheatBypass(uint64_t base) {
    if (base == 0) { NSLog(@"[ANTIBAN] base=0, bypass skipped"); return; }

    // Patch → NOP NOP NOP RET (4 arm64 instructions = 16 bytes)
    // Makes each anticheat function return immediately
    struct { uint64_t rva; const char *name; } targets[] = {
        { kRVA_LOOPCABFPMJ, "LOOPCABFPMJ" },
        { kRVA_IMOMCMOPODE, "IMOMCMOPODE" },
        { kRVA_HIAKKLNIKFM, "HIAKKLNIKFM" },
        { kRVA_NLJNAOBBPEA, "NLJNAOBBPEA" },
        { kRVA_INICGCCOGEC, "INICGCCOGEC" },
        { kRVA_JHACIFHANIL, "JHACIFHANIL" },
    };
    uint8_t patch[16];
    memcpy(patch + 0,  kNOP4, 4);
    memcpy(patch + 4,  kNOP4, 4);
    memcpy(patch + 8,  kNOP4, 4);
    memcpy(patch + 12, kRET,  4);

    for (size_t i = 0; i < sizeof(targets)/sizeof(targets[0]); i++) {
        if (patchGameBytes(base, targets[i].rva, patch, sizeof(patch)))
            NSLog(@"[ANTIBAN] ✓ %s @ 0x%llx", targets[i].name, base + targets[i].rva);
    }
    NSLog(@"[ANTIBAN] bypass done — %zu functions patched",
          sizeof(targets)/sizeof(targets[0]));
}

// ─────────────────────────────────────────────────────────────────────────────
//  File-level clean — removes telemetry files the anticheat reads/writes
// ─────────────────────────────────────────────────────────────────────────────
static AntibanResult cleanContainer(NSString *containerPath, NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    AntibanResult r   = {0, 0};
    NSURL *base = [NSURL fileURLWithPath:containerPath isDirectory:YES];

    // Documents — remove all files except patch bytes and antiban decoys
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

    // Static telemetry dirs + files
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
        // ffrtc_log.txt — from DebuggerFileOutput.RTC_LOG_NAME
        @"Documents/ffrtc_log.txt",
        @"Documents/ff_magicvoice_log.txt",
        @"Documents/ff_magicvoice_engine_log.txt",
        @"Documents/BackendJsonLog",
        @"tmp/Analytics",   @"tmp/CrashReporter",
        @"tmp/crashes",     @"tmp/bugly", @"tmp/appsflyer-v1",
    ];
    for (NSString *rel in staticRel) {
        NSURL *t = [base URLByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:t.path])
            if ([fm removeItemAtURL:t error:nil]) r.deletedCaches++;
    }

    // Dynamic keyword scan in Library/Caches
    NSURL *cachesURL = [base URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:cachesURL
                            includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *lname = item.lastPathComponent.lowercaseString;
        for (NSString *kw in @[ @"analytics", @"crash", @"bugly",
                                 @"firebase",  @"appsflyer", @"adjust",
                                 @"cache.db",  @"fscacheddata" ])
            if ([lname containsString:kw]) {
                if ([fm removeItemAtURL:item error:nil]) r.deletedCaches++;
                break;
            }
    }

    // Specific files
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

// ─────────────────────────────────────────────────────────────────────────────
//  AntibanCleaner
// ─────────────────────────────────────────────────────────────────────────────
@implementation AntibanCleaner {
    dispatch_queue_t           _queue;
    NSLock                    *_lock;
    NSMutableArray<NSValue *> *_sourceRefs;
    NSMutableArray<NSNumber *> *_fds;
    BOOL                       _bypassApplied;
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
    _bypassApplied = NO;
    return self;
}

- (AntibanResult)cleanOnce {
    __block AntibanResult r;
    dispatch_sync(_queue, ^{ r = performClean(); });
    self.lastResult = r;
    return r;
}

// ─────────────────────────────────────────────────────────────────────────────
//  startWatching — called when game process is detected
// ─────────────────────────────────────────────────────────────────────────────
- (void)startWatching {
    [_lock lock];
    if (_isWatching) { [_lock unlock]; return; }
    NSLog(@"[ANTIBAN] startWatching");

    // 1. Apply anticheat bypass (once per process lifetime)
    if (!_bypassApplied) {
        uint64_t base = getGameBase();
        if (base > 0) {
            applyAnticheatBypass(base);
            _bypassApplied = YES;
        } else {
            NSLog(@"[ANTIBAN] game base not ready yet — bypass deferred");
        }
    }

    // 2. Immediate file clean pass
    dispatch_async(_queue, ^{
        self.lastResult = performClean();
    });

    // 3. Set up vnode watchers on container dirs
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

        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB,
            _queue);

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

// ─────────────────────────────────────────────────────────────────────────────
//  stopWatching — called when game process disappears
// ─────────────────────────────────────────────────────────────────────────────
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
    _bypassApplied = NO;   // reset so next launch re-applies

    dispatch_async(_queue, ^{ self.lastResult = performClean(); });

    self.isWatching = NO;
    [_lock unlock];
}

@end
