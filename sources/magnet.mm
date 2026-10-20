// magnet.mm — OB55 FIXED v2
//
// ROOT CAUSE (объясняет почему не работает НИ В КАКОМ режиме в OB55):
//
// WriteLocalRoot ранее: WriteAddr<Vector3>(TransformHierarchy* + 0x90, pos)
//   — это хардкод offset 0x90 внутри TransformHierarchy.
//   В OB54 это совпадало с реальной позицией потому что rootNode всегда
//   имел index=0 и layout TransformHierarchy был одним.
//
// В OB55 Unity изменил internal layout TransformHierarchy:
//   getPositionExt читает позицию как:
//     matrix_list = *(TransformHierarchy* + 0x18)
//     index       = *(inner + 0x40)            [kTransformIndex]
//     pos         = matrix_list[index * 48]    [sizeof(TMatrix)=48]
//
//   Хардкод 0x90 более не совпадает с matrix_list[index].position
//   в OB55 — отсюда запись уходит в неправильное место памяти
//   и движок не видит сдвига.
//
// FIX: WriteLocalRoot теперь делает то же что getPositionExt, но в обратную сторону:
//   читает index и matrix_list, пишет в matrix_list[index].position
//   Зеркальный путь чтения из UnityMath.mm.

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "../esp/Core/UnityMath.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t cachedMatch;
extern bool     aimMagnet;
extern bool     isAimIgnoreBot;
extern bool     isAimIgnoreKnock;

extern bool get_IsBot(uint64_t player);
extern bool get_IsKnockedDown(uint64_t player);

static constexpr float    kMagStrength    = 1.00f;
static constexpr float    kMagMaxDist     = 500.0f;
static constexpr float    kMagMinDist     = 1.0f;
static constexpr float    kMagDispCap     = 2.5f;   // работает везде вкл Custom Room

// ─── helpers ────────────────────────────────────────────
static inline float vlen3(Vector3 v){ return sqrtf(v.x*v.x+v.y*v.y+v.z*v.z); }
static inline bool  isSane3(Vector3 v){
    if(!isfinite(v.x)||!isfinite(v.y)||!isfinite(v.z)) return false;
    if(fabsf(v.x)>20000.f||fabsf(v.y)>20000.f||fabsf(v.z)>20000.f) return false;
    return !(v.x==0.f&&v.y==0.f&&v.z==0.f);
}

// ─── Matrix path (зеркало getPositionExt) ───────────────
struct MagMatPath {
    uint64_t matrix_list;   // TransformHierarchy* + 0x18
    size_t   index;         // *(inner + 0x40)
    bool     valid;
};

static MagMatPath ResolveMatPath(uint64_t nodePtr) {
    if (!isVaildPtr(nodePtr)) return {};

    // TransformNode.transform backing field @ 0x10
    uint64_t managedTransform = ReadAddr<uint64_t>(nodePtr + kTransformInner);
    if (!isVaildPtr(managedTransform)) return {};

    // managed Transform -> native ptr @ 0x10 (m_CachedPtr)
    uint64_t inner = ReadAddr<uint64_t>(managedTransform + kTransformInner);
    if (!isVaildPtr(inner)) return {};

    // inner -> TransformHierarchy* @ 0x38
    uint64_t matrix = ReadAddr<uint64_t>(inner + kTransformMatrix);
    if (!isVaildPtr(matrix)) return {};

    // index @ inner+0x40
    uint64_t indexU = ReadAddr<uint64_t>(inner + kTransformIndex);
    if (indexU > 8192) return {};

    // list = TransformHierarchy* + 0x18
    uint64_t matrix_list = ReadAddr<uint64_t>(matrix + kMatrixList);
    if (!isVaildPtr(matrix_list)) return {};

    return { matrix_list, (size_t)indexU, true };
}

// читаем только локальную позицию этого узла (matrix_list[index].position)
static Vector3 ReadLocalPos(const MagMatPath& p) {
    if (!p.valid) return {};
    return ReadAddr<Vector3>(p.matrix_list + sizeof(TMatrix) * p.index);
}

// пишем в matrix_list[index].position — зеркальный путь к getPositionExt
static bool WriteLocalPos(const MagMatPath& p, Vector3 pos) {
    if (!p.valid || !isSane3(pos)) return false;
    // TMatrix: Vector4 position (16 bytes) — пишем только xyz, w не трогаем
    WriteAddr<float>(p.matrix_list + sizeof(TMatrix)*p.index + 0,  pos.x);
    WriteAddr<float>(p.matrix_list + sizeof(TMatrix)*p.index + 4,  pos.y);
    WriteAddr<float>(p.matrix_list + sizeof(TMatrix)*p.index + 8,  pos.z);
    return true;
}

// ─── Root node path ──────────────────────────────────────
static MagMatPath RootMatPath(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kMagRootNodeOffset);   // 0x6C8
    return ResolveMatPath(node);
}

static Vector3 RootWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kMagRootNodeOffset);
    if (!isVaildPtr(node)) return {};
    return getPositionExt(node);   // world position через полный traversal
}

static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ─── shared state ────────────────────────────────────────
static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_active{false};
static std::atomic<bool> mag_started{false};

static uint64_t  mag_locked  = 0;
static Vector3   mag_origin  = {};   // world pos при захвате цели
static MagMatPath mag_path   = {};   // matrix path захваченной цели
static bool      mag_pathOk  = false;

static Vector3   mag_camPos  = {};
static Vector3   mag_camFwd  = {};
static std::chrono::steady_clock::time_point mag_lastUpdate =
    std::chrono::steady_clock::now();

static inline bool TargetValid(uint64_t p) {
    if (!isVaildPtr(p)) return false;
    if (get_CurHP(p) <= 0) return false;
    if (isAimIgnoreBot   && get_IsBot(p))         return false;
    if (isAimIgnoreKnock && get_IsKnockedDown(p)) return false;
    return true;
}

// ─── Apply ───────────────────────────────────────────────
static bool ApplyMagnet(const MagMatPath& path,
                        const Vector3& origin,
                        const Vector3& camPos,
                        const Vector3& camFwd,
                        uint64_t pawn) {
    if (!path.valid) return false;

    Vector3 headW = HeadWorld(pawn);
    if (!isSane3(headW)) return false;

    float dist = vlen3({headW.x-camPos.x, headW.y-camPos.y, headW.z-camPos.z});
    if (dist < kMagMinDist || dist > kMagMaxDist) return false;

    // читаем текущую локальную позицию узла
    Vector3 curLocal = ReadLocalPos(path);
    if (!isSane3(curLocal)) return false;

    // target = точка на луче камеры на дистанции цели
    Vector3 targetWorld = {
        camPos.x + camFwd.x * dist,
        origin.y + kMagVerticalLiftValue,
        camPos.z + camFwd.z * dist
    };

    // displacement cap от оригинальной позиции (world space)
    Vector3 deltaOrig = { targetWorld.x-origin.x, 0.f, targetWorld.z-origin.z };
    float d = sqrtf(deltaOrig.x*deltaOrig.x + deltaOrig.z*deltaOrig.z);
    if (d > kMagDispCap && d > 1e-4f) {
        float s = kMagDispCap / d;
        targetWorld.x = origin.x + deltaOrig.x*s;
        targetWorld.z = origin.z + deltaOrig.z*s;
    }

    // lerp
    Vector3 newLocal = {
        curLocal.x + (targetWorld.x - headW.x + curLocal.x - curLocal.x)*kMagStrength,
        curLocal.y,
        curLocal.z + (targetWorld.z - headW.z + curLocal.z - curLocal.z)*kMagStrength
    };
    // упрощённо: сдвигаем local на дельту world
    float dx = (targetWorld.x - headW.x) * kMagStrength;
    float dz = (targetWorld.z - headW.z) * kMagStrength;
    newLocal = { curLocal.x + dx, curLocal.y, curLocal.z + dz };

    return WriteLocalPos(path, newLocal);
}

// ─── Worker ──────────────────────────────────────────────
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMilliseconds));
        if (!mag_active.load(std::memory_order_acquire)) continue;

        std::lock_guard<std::mutex> lk(mag_lock);
        if (!mag_hasData.load(std::memory_order_acquire)) continue;

        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - mag_lastUpdate).count();
        if (since > kMagReleaseMilliseconds) {
            mag_hasData.store(false, std::memory_order_release);
            continue;
        }
        if (!isVaildPtr(mag_locked) || !TargetValid(mag_locked) || !mag_pathOk) continue;
        ApplyMagnet(mag_path, mag_origin, mag_camPos, mag_camFwd, mag_locked);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool enabled) {
    InitMagnetThread();

    if (!aimMagnet || !enabled) {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_hasData.store(false, std::memory_order_release);
        mag_active.store(false,  std::memory_order_release);
        mag_locked = 0; mag_pathOk = false;
        return;
    }

    std::lock_guard<std::mutex> lk(mag_lock);

    // дроп если цель умерла
    if (isVaildPtr(mag_locked) && !TargetValid(mag_locked)) {
        mag_locked = 0; mag_pathOk = false;
    }

    // захват новой цели
    if (!isVaildPtr(mag_locked) && isVaildPtr(target) && TargetValid(target)) {
        if (!isVaildPtr(cachedMatch)) { mag_active.store(false, std::memory_order_release); return; }
        Vector3 root = RootWorld(target);
        MagMatPath path = RootMatPath(target);
        if (isSane3(root) && path.valid) {
            mag_locked  = target;
            mag_origin  = root;
            mag_path    = path;
            mag_pathOk  = true;
        }
    }

    // обновление path если цель та же но path ещё не захвачен
    if (isVaildPtr(mag_locked) && !mag_pathOk) {
        MagMatPath path = RootMatPath(mag_locked);
        if (path.valid) {
            mag_path   = path;
            mag_pathOk = true;
            mag_origin = RootWorld(mag_locked);
        }
    }

    if (!isVaildPtr(mag_locked) || !mag_pathOk) {
        mag_active.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    mag_camPos     = camPos;
    mag_camFwd     = camForward;
    mag_lastUpdate = std::chrono::steady_clock::now();
    mag_active.store(true,  std::memory_order_release);
    mag_hasData.store(true, std::memory_order_release);
}

uint64_t GetMagnetLockedTarget() {
    std::lock_guard<std::mutex> lk(mag_lock);
    return mag_locked;
}

void ResetAimMagnet() {
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_hasData.store(false, std::memory_order_release);
    mag_active.store(false,  std::memory_order_release);
    mag_locked = 0; mag_camPos={}; mag_camFwd={};
    mag_origin={}; mag_path={}; mag_pathOk=false;
}
