// magnet.mm
// Aim Magnet с удержанием цели.
#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimMagnet;

extern bool isAimIgnoreBot;
extern bool isAimIgnoreKnock;

extern bool get_IsBot(uint64_t player);
extern bool get_IsKnockedDown(uint64_t player);

static constexpr float kMagStrength   = 1.00f;
static constexpr float kMagMaxDist    = 500.0f;
static constexpr float kMagMinDist    = 1.0f;

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_active{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_locked    = 0;
static Vector3  mag_originalRoot = {};
static bool     mag_originalRootValid = false;

static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};
static std::chrono::steady_clock::time_point mag_lastUpdate =
    std::chrono::steady_clock::now();

static inline uint64_t NowMs() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline bool  isZero3(Vector3 v) { return v.x==0.f && v.y==0.f && v.z==0.f; }
static inline bool  isSane3(Vector3 v) {
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    if (fabsf(v.x) > 20000.f || fabsf(v.y) > 20000.f || fabsf(v.z) > 20000.f) return false;
    return true;
}

static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static Vector3 RootWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kMagRootNodeOffset);
    if (!isVaildPtr(node)) return {};
    uint64_t tf = ReadAddr<uint64_t>(node + kMagBodyPartOffset);
    if (!isVaildPtr(tf)) return {};
    return getPositionExt(tf);
}

static uint64_t MatPtr(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t node = ReadAddr<uint64_t>(pawn + kMagRootNodeOffset);
    if (!isVaildPtr(node)) return 0;
    uint64_t tf = ReadAddr<uint64_t>(node + kMagBodyPartOffset);
    if (!isVaildPtr(tf)) return 0;
    uint64_t p3 = ReadAddr<uint64_t>(tf + kMagInnerOffset);
    if (!isVaildPtr(p3)) return 0;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMagMatrixOffset);
    return isVaildPtr(mat) ? mat : 0;
}

static bool WriteLocalRoot(uint64_t pawn, Vector3 pos) {
    if (!isSane3(pos)) return false;
    uint64_t mat = MatPtr(pawn);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kMagPositionOffset, pos);
    return true;
}

static bool TargetStillValid(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return false;
    if (get_CurHP(pawn) <= 0) return false;
    if (isAimIgnoreBot   && get_IsBot(pawn))         return false;
    if (isAimIgnoreKnock && get_IsKnockedDown(pawn)) return false;
    return true;
}

static bool ApplyMagnet(uint64_t pawn, const Vector3& camPos, const Vector3& camFwd) {
    if (!TargetStillValid(pawn)) return false;

    Vector3 headW = HeadWorld(pawn);
    if (!isSane3(headW) || isZero3(headW)) return false;

    float dist = vlen3({headW.x - camPos.x, headW.y - camPos.y, headW.z - camPos.z});
    if (dist < kMagMinDist || dist > kMagMaxDist) return false;

    Vector3 curRootW = RootWorld(pawn);
    if (!isSane3(curRootW) || isZero3(curRootW)) return false;

    if (!mag_originalRootValid) return false;

    Vector3 targetPt = {
        camPos.x + camFwd.x * dist,
        camPos.y + camFwd.y * dist,
        camPos.z + camFwd.z * dist
    };

    float upwardLift = fmaxf(0.0f, kMagVerticalLiftValue);

    float targetY = mag_originalRoot.y + upwardLift;

    Vector3 rootTgtWorld = {
        targetPt.x,
        targetY,
        targetPt.z
    };

    Vector3 lerped = {
        curRootW.x + (rootTgtWorld.x - curRootW.x) * kMagStrength,
        targetY,
        curRootW.z + (rootTgtWorld.z - curRootW.z) * kMagStrength
    };

    // ── Ограничение X/Z от якоря (Y уже клампнут выше) ────────
    Vector3 deltaOrig = {
        lerped.x - mag_originalRoot.x,
        0.f,
        lerped.z - mag_originalRoot.z
    };
    float dOrig = sqrtf(deltaOrig.x*deltaOrig.x + deltaOrig.z*deltaOrig.z);
    if (dOrig > kMagMaxDisplacementValue && dOrig > 0.0001f) {
        float s = kMagMaxDisplacementValue / dOrig;
        lerped.x = mag_originalRoot.x + deltaOrig.x * s;
        lerped.z = mag_originalRoot.z + deltaOrig.z * s;
    }

    return WriteLocalRoot(pawn, lerped);
}

static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMilliseconds));

        if (!mag_active.load(std::memory_order_acquire)) continue;

        std::lock_guard<std::mutex> lk(mag_lock);
        if (!mag_hasData.load(std::memory_order_acquire)) continue;

        auto now = std::chrono::steady_clock::now();
        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - mag_lastUpdate).count();
        if (since > kMagReleaseMilliseconds) {
            mag_hasData.store(false, std::memory_order_release);
            continue;
        }

        uint64_t target = mag_locked;
        Vector3 camPos = mag_camPos;
        Vector3 camFwd = mag_camFwd;
        if (!isVaildPtr(target)) continue;
        if (!TargetStillValid(target)) continue;

        ApplyMagnet(target, camPos, camFwd);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

// enabled = true  → ADS, тянем.
// enabled = false → не ADS, лок держим коротко.
void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool enabled) {
    InitMagnetThread();

    if (!aimMagnet) {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_hasData.store(false, std::memory_order_release);
        mag_active.store(false,  std::memory_order_release);
        mag_locked = 0;
        mag_originalRoot = {};
        mag_originalRootValid = false;
        return;
    }

    static uint64_t s_unscopeSinceMs = 0;
    static constexpr uint64_t kMagLockDropMs = 400;

    std::lock_guard<std::mutex> lk(mag_lock);

    if (isVaildPtr(mag_locked) && !TargetStillValid(mag_locked)) {
        mag_locked = 0;
        mag_originalRootValid = false;
    }

    if (!enabled) {
        uint64_t nowMs = NowMs();
        if (s_unscopeSinceMs == 0) s_unscopeSinceMs = nowMs;

        mag_originalRootValid = false;
        mag_active.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);

        if (nowMs - s_unscopeSinceMs >= kMagLockDropMs) {
            mag_locked = 0;
            mag_originalRoot = {};
            mag_originalRootValid = false;
            s_unscopeSinceMs = 0;
        }
        return;
    }

    s_unscopeSinceMs = 0;

    if (!isVaildPtr(mag_locked) && isVaildPtr(target) && TargetStillValid(target)) {
        if (!isVaildPtr(cachedMatch)) {
            mag_active.store(false, std::memory_order_release);
            mag_hasData.store(false, std::memory_order_release);
            return;
        }
        Vector3 root = RootWorld(target);
        if (isSane3(root) && !isZero3(root)) {
            mag_locked = target;
            mag_originalRoot = root;
            mag_originalRootValid = true;
        }
    }

    if (isVaildPtr(mag_locked) && !mag_originalRootValid) {
        Vector3 root = RootWorld(mag_locked);
        if (isSane3(root) && !isZero3(root)) {
            mag_originalRoot = root;
            mag_originalRootValid = true;
        }
    }

    if (!isVaildPtr(mag_locked) || !mag_originalRootValid) {
        mag_active.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    mag_camPos     = camPos;
    mag_camFwd     = camForward;
    mag_lastUpdate = std::chrono::steady_clock::now();
    mag_active.store(true, std::memory_order_release);
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
    mag_locked = 0;
    mag_camPos = {};
    mag_camFwd = {};
    mag_originalRoot = {};
    mag_originalRootValid = false;
}
