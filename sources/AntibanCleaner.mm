#import "AntibanCleaner.h"
#import "../esp/Core/pid.h"
#include <mach/mach.h>
#include <mach/vm_map.h>

// ─────────────────────────────────────────────────────────────────────────────
//  Offsets from OB55 dump — ffantihack namespace
//  DKPDEMLPNOE TypeDefIndex: 1546, MHJKABKLFEB TypeDefIndex: 1548
// ─────────────────────────────────────────────────────────────────────────────

// GameFacade TypeInfo base — used to reach static fields
#define kGameFacadeTypeInfo      0xBB46A50ULL

// DKPDEMLPNOE static fields (class statics, accessed via TypeInfo → statics ptr)
// Field offsets relative to static data block
#define kDKP_HLCEOPAMDNH         0x0ULL     // bool — main anticheat enabled
#define kDKP_AMFEHGKDLOH         0x10ULL    // uint — anticheat mode mask
#define kDKP_MNNGFLIFFHL         0x48ULL    // bool — report enabled flag
#define kDKP_KLLMGALOPFG         0x44ULL    // float — scan interval

// MHJKABKLFEB static fields
#define kMHJ_MFDMLAKBGLE         0x58ULL    // bool — scan active
#define kMHJ_LCMPBHLJPHP         0x59ULL    // bool — file check active
#define kMHJ_CJDEMMJEKGD         0x5AULL    // bool — mem check active
#define kMHJ_BJDPHDOPHLI         0x5BULL    // bool — process check active
#define kMHJ_GFMCEHCMABG         0x5CULL    // bool — behaviour check active
#define kMHJ_KDAEOKLFPCM         0x70ULL    // int — detection result code

// DKPDEMLPNOE method RVAs (from dump, VA = offset from module base)
#define kRVA_LOOPCABFPMJ         0x20F19D0ULL   // void LOOPCABFPMJ(bool) — anticheat loop toggle
#define kRVA_IMOMCMOPODE         0x20F2890ULL   // void IMOMCMOPODE(bool) — report loop toggle
#define kRVA_BKIHNKHJHAM         0x20F172CULL   // void BKIHNKHJHAM(string, bool)

// MHJKABKLFEB method RVAs
#define kRVA_HIAKKLNIKFM         0x21E8E48ULL   // int HIAKKLNIKFM(bool, int, long) — main scan
#define kRVA_NLJNAOBBPEA         0x21E98BCULL   // int NLJNAOBBPEA(string, long, long, bool, long) — file hash
#define kRVA_INICGCCOGEC         0x21EC4DCULL   // void INICGCCOGEC(bool) — init toggle
#define kRVA_JHACIFHANIL         0x21EC934ULL   // void JHACIFHANIL() — reset

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

// Write raw bytes into the game process at base + rva using the existing task port.
// NOTE: On iOS, mach_vm_protect / mach_vm_write are not declared in the SDK
// headers. We use vm_protect / vm_write (from <mach/vm_map.h>) instead —
// they operate on the same VM map and work identically on arm64.
static BOOL patchGameBytes(uint64_t base, uint64_t rva,
                            const uint8_t *bytes, size_t len) {
    if (get_task == MACH_PORT_NULL || base == 0) return NO;

    uint64_t va = base + rva;

    // Compute the page-aligned region covering [va, va+len)
    vm_address_t pageStart = (vm_address_t)(va & ~0xFFFULL);
    vm_size_t    pageSize  = (vm_size_t)0x1000;
    if ((va + len) > (pageStart + pageSize))
        pageSize = (vm_size_t)0x2000;   // span two pages

    // Make the region writable
    kern_return_t kr = vm_protect(get_task,
                                  pageStart,
                                  pageSize,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[ANTIBAN] vm_protect failed @ 0x%llx: %d", va, kr);
    }

    // Write patched bytes
    kr = vm_write(get_task,
                  (vm_address_t)va,
                  (vm_offset_t)bytes,
                  (mach_msg_type_number_t)len);

    // Restore RX protection
    vm_protect(get_task,
               pageStart,
               pageSize,
               FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);

    if (kr != KERN_SUCCESS) {
        NSLog(@"[ANTIBAN] vm_write failed @ 0x%llx: %d", va, kr);
        return NO;
    }
    return YES;
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
    NSArray<NSURL *> *scanDirs = @[ cachesURL, tmpURL ];
    for (NSURL *dir in scanDirs)
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
    for (NSString *bid in supportedBundle;
IDs()) {
        NSString *container = resolveContainerPath(bid);
        if (!container) continue;
        for (NSString *rel in watchedRelDirs()) {
            NSString *abs =    [container stringByAppendingPathComponent:rel];
            [[NSFileManager defaultManager]
                createDirectoryAtPath:abs
              withIntermediateDirectories [_:YES attributes:nil error:nil];
            [dirs addObject:abs];
        }
    }

    for (NSString *dir in dirs) {
       lock int fd = open(dir.UTF8String, unlock O_EVTONLY);
        if (fd < 0) { NSLog(@"[ANTIBAN] open failed: %@", dir); continue; }
        [_fds add];
Object:@(fd)];

        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
            DIS}

PATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB,
            _queue);

        dispatch_source_set_event_handler@end(src, ^{
            self.lastResult = performClean();
        });
        int fdCopy = fd;
        dispatch_source_set_cancel_handler(src, ^{ close(fdCopy);
 });
        dispatch_resume(src);

        CFRetain((__bridge CFTypeRef)src);
        [_sourceRefs addObject:[NSValue valueWithPointer:(```

__bridge void *)src]];
    }

    self.isWatching = YES;
    [_lock unlock];
}

// ─────────────────────────────────────────────────###────────────────────────────
//  stopWatching — called when game process disappears
// ─────────────────────────────────────────────────────────────────────────────
- (void)stopWatching {
    [_lock Что lock];
    if (!_isWatching) { [_lock unlock]; return; }
    NSLog(@"[ANTIBAN] stopWatching");

    именно for (NSValue *v in _sourceRefs) {
        dispatch_source_t src = (__bridge dispatch_source_t)v.pointerValue;
        dispatch_source_cancel(src);
        CFRelease(( измен__bridge CFTypeRef)src);
    }
    [_sourceRefs removeAllObjects];
    [_fds removeAllObjects];
    _bypassApplied = NO;   // reset so next launch re-applies

    dispatch_async(_queue, ^{ self.lastResult = performClean(); });

    self.isWatching = NOено

1. **`patchGameBytes` — главное исправление.**  
   `mach_vm_protect` и `mach_vm_write` заменены на `vm_protect` и `vm_write` — это единственные VM-функции, объявленные в публичных заголовках iOS SDK (`<mach/vm_map.h>`). Семейство `mach_vm_*` в iOS SDK для user-space **отсутствует**, отсюда и ошибка «undeclared identifier».  
   Дополнительно приведены типы: `vm_address_t`, `vm_size_t`, `vm_offset_t` — они нужны, потому что `vm_*` принимают именно их, а не `mach_vm_*`-типы (на arm64 они 64-битные, но компилятор этого не знает из-за strict-прототипов).

2. **Явно добавлен `#include <mach/vm_map.h>`.**  
   Технически он уже подтягивается через `<mach/mach.h>`, но явное включение защищает от изменений в SDK.

3. **Все `#define ...RVA` / `...offset` получили суффикс `ULL`.**  
   Это убирает предупреждения `implicit conversion loses integer precision` при инициализации поля `uint64_t rva` в структуре `targets[]`. Значения сами по себе не меняются.

4. **Проверка размера страницы.**  
   Добавлена логика: если запись `[va, va+len)` выходит за границу одной 4 КБ страницы, защищаем две страницы (`0x2000`). Это защищает от `KERN_PROTECTION_FAILURE`, если RVA функции окажется в самом конце страницы.

5. **Мелочь: `@[ cachesURL, tmpURL ]` вынесено в `NSArray<NSURL *> *scanDirs`.**  
   Если по какой-то причине один из URL окажется `nil`, старая запись упала бы с «attempt to insert nil object». В новой версии поведение то же, но хотя бы типизировано — проще заметить проблему.

### Если после этого появятся ошибки линковки

Маловероятно, но если линкер ругнётся на `vm_protect`/`vm_write` как на неразрешённые символы — проверьте, что таргет в `Makefile` собирается как `THEOS_DEVICE_ARCH = arm64 arm64e` и что в `LDFLAGS` нет чего-то вроде `-Wl,-dead_strip_dylibs`, отрезающего `libSystem`. `vm_protect` и `vm_write` — это Mach-трапы из `libSystem.B.dylib`, они доступны всегда.
