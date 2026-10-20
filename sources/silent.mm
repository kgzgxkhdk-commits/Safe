// silent.mm — OB55 FIXED
//
// Root causes fixed vs original:
//
//  [FIX-1] kWriteAltAimInfo=true
//    OB55 добавил CGKJLKPMGDJ @ 0xB10 и 0xB20 (AEJHONDBJAD / IACGJCEFEBD) —
//    это новый pair AimInfo для нового типа оружия. Без записи в них damage
//    считается fake в обычных режимах.
//
//  [FIX-2] PGAIFNOGDAN (FollowCamera direction check) — NEW in OB55:
//    Движок сверяет RayDirection из AimInfo с forward-вектором камеры через dot().
//    Если угол > ~90° (dot < 0) — хит отклоняется как fake.
//    Фикс: перед записью в AimInfo нормализуем dir, и если dot(dir, camFwd) < 0,
//    отражаем dir относительно camFwd чтобы dot стал положительным.
//    В Duel 1v1 (IIV1v1) этот чек отключён — потому там работало.
//
//  [FIX-3] kNormalizeDir=true для OB55
//    PGAIFNOGDAN читает нормализованный RayDirection.
//    Ненормализованный вектор давал неверный dot → fake.
//
//  [FIX-4] Magnet: kMagRootNodeOffset 0x6C8 — верифицирован.
//    В Custom room сервер не принимает физическое смещение модели
//    если оно выходит за допустимую зону. Fix в magnet.mm отдельно.

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <cmath>
#include <pthread/qos.h>

extern uint64_t Moudule_Base;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Tunables ───────────────────────────────────────────
static constexpr float    kBulletSpeed      = 700.0f;
static constexpr float    kHitLag           = 0.020f;
static constexpr float    kMaxLeadTime      = 0.200f;
static constexpr float    kMinLeadTime      = 0.000f;
static constexpr float    kMaxVelXZ         = 15.0f;
static constexpr float    kMaxVelY          = 10.0f;
static constexpr float    kYBias            = 0.03f;
static constexpr float    kGravity          = 0.0f;
static constexpr uint64_t kGraceMs          = 60;
static constexpr uint64_t kFireWindowMs     = 200;
static constexpr uint64_t kPreFireBoostMs   = 60;
static constexpr uint64_t kHeartbeatMs      = 200;
static constexpr int      kFireRateSamples  = 8;
static constexpr float    kHeadCenterOffset = 0.03f;
static constexpr float    kFuseBoneWeight   = 0.5f;
static constexpr float    kBoneVelEmaAlpha  = 0.55f;
static constexpr float    kBoneVelMaxDiff   = 8.0f;

// [FIX-3] нормализуем dir — OB55 PGAIFNOGDAN читает нормализованный вектор
static constexpr bool kNormalizeDir     = true;
static constexpr bool kWriteScatter     = false;

// [FIX-1] записываем во все три слота AimInfo включая 0xB10 / 0xB20
static constexpr bool kWriteAltAimInfo  = true;
// OB55 extended slots @ 0xB10 / 0xB20
static constexpr uint64_t kAimInfo_B10  = 0xB10;
static constexpr uint64_t kAimInfo_B20  = 0xB20;

// [FIX-2] минимальный dot между записываемым dir и forward-вектором камеры.
// Если dot(dir, camFwd) < kMinDirDot — dir будет скорректирован.
// 0.0f = допускаем угол до 90°, отсекаем только > 90°.
static constexpr float kMinDirDot = 0.0f;

// ─── Shared camera forward ───────────────────────────────
static std::atomic<float> g_camFwdX{0.f};
static std::atomic<float> g_camFwdY{0.f};
static std::atomic<float> g_camFwdZ{1.f};

// Вызывать из main loop каждый кадр
void SilentUpdateCamFwd(Vector3 camFwd) {
    float m = sqrtf(camFwd.x*camFwd.x + camFwd.y*camFwd.y + camFwd.z*camFwd.z);
    if (m > 1e-4f) {
        g_camFwdX.store(camFwd.x / m, std::memory_order_relaxed);
        g_camFwdY.store(camFwd.y / m, std::memory_order_relaxed);
        g_camFwdZ.store(camFwd.z / m, std::memory_order_relaxed);
    }
}

static inline Vector3 GetCamFwd() {
    return { g_camFwdX.load(std::memory_order_relaxed),
             g_camFwdY.load(std::memory_order_relaxed),
             g_camFwdZ.load(std::memory_order_relaxed) };
}

// ─── Forward decls ───────────────────────────────────────
static inline uint64_t NowMs();

// ─── Shared state ────────────────────────────────────────
static std::mutex                g_lock;
static std::atomic<bool>         g_hasData{false};
static std::atomic<bool>         g_started{false};
static std::atomic<uint64_t>     g_lastActivityMs{0};
static std::atomic<uint64_t>     g_matchGen{0};
static std::atomic<uint64_t>     g_firingUntilMs{0};
static std::atomic<uint64_t>     g_aimPtr{0};

struct SilentSnapshot {
    Vector3  rawPos      = {};
    Vector3  vel         = {};
    Vector3  localVel    = {};
    float    bulletSpeed = kBulletSpeed;
    uint64_t timeMs      = 0;
    uint64_t localPawn   = 0;
    uint64_t enemy       = 0;
    int      posMode     = 0;
};
static SilentSnapshot g_snap;
static uint64_t g_lastMatch = 0;

// ─── Fire-rate tracker ───────────────────────────────────
struct FireRateTracker {
    uint64_t lastFrontMs              = 0;
    uint64_t intervalsMs[kFireRateSamples] = {};
    int count = 0, head = 0;
    bool wasOn = false;
};
static FireRateTracker g_fr;

static inline uint64_t FireWindowEstimate(bool nowFiring) {
    if (nowFiring && !g_fr.wasOn) {
        uint64_t now = NowMs();
        if (g_fr.lastFrontMs != 0) {
            uint64_t dt = now - g_fr.lastFrontMs;
            if (dt >= 20 && dt <= 1000) {
                g_fr.intervalsMs[g_fr.head] = dt;
                g_fr.head = (g_fr.head + 1) % kFireRateSamples;
                if (g_fr.count < kFireRateSamples) g_fr.count++;
            }
        }
        g_fr.lastFrontMs = now;
    }
    g_fr.wasOn = nowFiring;
    if (g_fr.count < 3) return kFireWindowMs;
    uint64_t sum = 0;
    for (int i = 0; i < g_fr.count; i++) sum += g_fr.intervalsMs[i];
    uint64_t est = (sum / (uint64_t)g_fr.count) * 3 / 2;
    return (est < kFireWindowMs) ? kFireWindowMs : est;
}

// ─── Helpers ─────────────────────────────────────────────
static inline uint64_t NowMs() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x==0.f && v.y==0.f && v.z==0.f);
}
static inline bool looksLikeWorldPos(const Vector3& p) {
    if (p.x==0.f && p.y==0.f && p.z==0.f) return false;
    if (isnan(p.x)||isnan(p.y)||isnan(p.z)) return false;
    if (fabsf(p.x)>20000.f||fabsf(p.y)>20000.f||fabsf(p.z)>20000.f) return false;
    return true;
}
static inline float Length3(const Vector3& v) {
    return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
}
static inline float Dot3(const Vector3& a, const Vector3& b) {
    return a.x*b.x + a.y*b.y + a.z*b.z;
}

// ─── PhysX velocity ──────────────────────────────────────
static inline bool GetWorldVelocity(uint64_t pawn, Vector3& out) {
    if (!validPtr(pawn)) return false;
    uint64_t cct = ReadAddr<uint64_t>(pawn + kPhysCCT);
    if (!validPtr(cct)) return false;
    Vector3 v = ReadAddr<Vector3>(cct + kPhysCCT_Velocity);
    if (!std::isfinite(v.x)||!std::isfinite(v.y)||!std::isfinite(v.z)) return false;
    if (fabsf(v.x)>100.f||fabsf(v.y)>100.f||fabsf(v.z)>100.f) return false;
    out = v;
    return true;
}

// ─── Local firing flags ──────────────────────────────────
static inline bool IsLocalFiring(uint64_t localPawn) {
    if (!validPtr(localPawn)) return false;
    return ReadAddr<uint8_t>(localPawn + kIsFiring) != 0;
}
static inline bool IsPreparingAttack(uint64_t localPawn) {
    if (!validPtr(localPawn)) return false;
    return ReadAddr<uint8_t>(localPawn + kSAim1) != 0;
}

// ─── QoS ─────────────────────────────────────────────────
static inline void BoostWorkerQoS() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

// ─── Bone velocity ───────────────────────────────────────
struct BoneTracker {
    uint64_t pawn=0; Vector3 lastPos={}, prevPos={};
    double lastTime=0, prevTime=0; Vector3 vel={};
    bool hasLast=false, hasPrev=false;
};
static BoneTracker g_boneTrack;

static inline Vector3 UpdateBoneVelocity(uint64_t pawn, const Vector3& headPos) {
    double now = CFAbsoluteTimeGetCurrent();
    if (g_boneTrack.pawn != pawn) {
        g_boneTrack = BoneTracker{};
        g_boneTrack.pawn=pawn; g_boneTrack.lastPos=headPos;
        g_boneTrack.lastTime=now; g_boneTrack.hasLast=true;
        return {};
    }
    g_boneTrack.prevPos=g_boneTrack.lastPos; g_boneTrack.prevTime=g_boneTrack.lastTime;
    g_boneTrack.lastPos=headPos; g_boneTrack.lastTime=now;
    if (!g_boneTrack.hasPrev) { g_boneTrack.hasPrev=true; return {}; }
    double dt = g_boneTrack.lastTime - g_boneTrack.prevTime;
    if (dt < 0.002 || dt > 0.100) return g_boneTrack.vel;
    Vector3 inst = {
        (float)((g_boneTrack.lastPos.x-g_boneTrack.prevPos.x)/dt),
        (float)((g_boneTrack.lastPos.y-g_boneTrack.prevPos.y)/dt),
        (float)((g_boneTrack.lastPos.z-g_boneTrack.prevPos.z)/dt)
    };
    if (!std::isfinite(inst.x)||!std::isfinite(inst.y)||!std::isfinite(inst.z))
        return g_boneTrack.vel;
    const float a = kBoneVelEmaAlpha;
    g_boneTrack.vel.x = g_boneTrack.vel.x*(1.f-a) + inst.x*a;
    g_boneTrack.vel.y = g_boneTrack.vel.y*(1.f-a) + inst.y*a;
    g_boneTrack.vel.z = g_boneTrack.vel.z*(1.f-a) + inst.z*a;
    float vXZ = sqrtf(g_boneTrack.vel.x*g_boneTrack.vel.x + g_boneTrack.vel.z*g_boneTrack.vel.z);
    if (vXZ > kMaxVelXZ) { float inv=kMaxVelXZ/vXZ; g_boneTrack.vel.x*=inv; g_boneTrack.vel.z*=inv; }
    if (fabsf(g_boneTrack.vel.y)>kMaxVelY) g_boneTrack.vel.y=(g_boneTrack.vel.y>0?1.f:-1.f)*kMaxVelY;
    return g_boneTrack.vel;
}

static inline Vector3 FuseVelocity(const Vector3& physX, const Vector3& boneVel) {
    float bLen = Length3(boneVel);
    if (bLen < 0.3f) return physX;
    Vector3 diff = {boneVel.x-physX.x, boneVel.y-physX.y, boneVel.z-physX.z};
    if (Length3(diff) > kBoneVelMaxDiff) return physX;
    const float w=kFuseBoneWeight, iw=1.f-w;
    return { physX.x*iw+boneVel.x*w, physX.y*iw+boneVel.y*w, physX.z*iw+boneVel.z*w };
}

// ─── Bones ───────────────────────────────────────────────
static inline Vector3 BonePos(uint64_t pawn, uint64_t boneOffset) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + boneOffset);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPartTransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

static inline Vector3 HeadHitboxCenter(uint64_t pawn, const Vector3& head) {
    if (kHeadCenterOffset <= 0.001f) return head;
    Vector3 chest = BonePos(pawn, kChestNode);
    if (!validVec(chest)) { Vector3 h=head; h.y+=kHeadCenterOffset; return h; }
    Vector3 d = {head.x-chest.x, head.y-chest.y, head.z-chest.z};
    float m = Length3(d);
    if (m < 0.05f) { Vector3 h=head; h.y+=kHeadCenterOffset; return h; }
    float k = kHeadCenterOffset/m;
    return Vector3(head.x+d.x*k, head.y+d.y*k, head.z+d.z*k);
}

static inline Vector3 ResolveAimBone(uint64_t pawn, int posMode) {
    if (!validPtr(pawn)) return {};
    if (posMode<0) posMode=0; if (posMode>2) posMode=2;
    if (posMode==0) {
        Vector3 head = BonePos(pawn, kHeadNode);
        if (!validVec(head)) return {};
        return HeadHitboxCenter(pawn, head);
    }
    if (posMode==1) {
        Vector3 neck = BonePos(pawn, kNeckNode);
        if (validVec(neck)) return neck;
        Vector3 chest = BonePos(pawn, kChestNode);
        if (validVec(chest)) return chest;
        Vector3 head = BonePos(pawn, kHeadNode);
        if (validVec(head)) { head.y-=0.12f; return head; }
        return {};
    }
    Vector3 chest = BonePos(pawn, kChestNode);
    if (validVec(chest)) return chest;
    Vector3 hip = BonePos(pawn, kHipNode);
    if (validVec(hip)) return hip;
    Vector3 head = BonePos(pawn, kHeadNode);
    if (validVec(head)) { head.y-=0.32f; return head; }
    return {};
}

// ─── Write ───────────────────────────────────────────────
// [FIX-2] CorrectDirForCam: если dot(dir, camFwd) < kMinDirDot,
// проецируем dir на полупространство камеры.
static inline Vector3 CorrectDirForCam(const Vector3& dir) {
    Vector3 camFwd = GetCamFwd();
    float dot = Dot3(dir, camFwd);
    if (dot >= kMinDirDot) return dir;  // уже ok
    // Отражаем компоненту направленную "против" камеры:
    // dir_corrected = dir - 2*(dir·camFwd)*camFwd  (reflect around plane perp to camFwd)
    // Но нам не нужно полное отражение, достаточно проекции:
    // dir_corrected = dir - (dot - kMinDirDot)*camFwd
    Vector3 corrected = {
        dir.x - (dot - kMinDirDot) * camFwd.x,
        dir.y - (dot - kMinDirDot) * camFwd.y,
        dir.z - (dot - kMinDirDot) * camFwd.z
    };
    float m = Length3(corrected);
    if (m < 1e-4f) return camFwd;
    return { corrected.x/m, corrected.y/m, corrected.z/m };
}

static inline bool WriteSilentDir(uint64_t aimingInfo,
                                   const Vector3& targetPos,
                                   const Vector3& targetVel,
                                   const Vector3& localVel,
                                   float bulletSpeed) {
    static thread_local Vector3 s_lastOrigin = {};
    if (!validPtr(aimingInfo) || !validVec(targetPos)) return false;

    Vector3 start = ReadAddr<Vector3>(aimingInfo + kHit_StartPositionOffset);
    if (!validVec(start)) {
        if (!validVec(s_lastOrigin)) return false;
        start = s_lastOrigin;
    } else {
        s_lastOrigin = start;
    }

    Vector3 origin = start, aim = targetPos;
    for (int i = 0; i < 4; i++) {
        Vector3 d = {aim.x-origin.x, aim.y-origin.y, aim.z-origin.z};
        float dist = Length3(d);
        float t = (bulletSpeed > 1.0f) ? (dist/bulletSpeed + kHitLag) : kHitLag;
        if (t < kMinLeadTime) t = kMinLeadTime;
        if (t > kMaxLeadTime) t = kMaxLeadTime;
        origin.x = start.x + localVel.x*t;
        origin.y = start.y + localVel.y*t;
        origin.z = start.z + localVel.z*t;
        aim.x = targetPos.x + targetVel.x*t;
        aim.y = targetPos.y + targetVel.y*t + kYBias;
        aim.z = targetPos.z + targetVel.z*t;
        if (kGravity > 0.01f) aim.y += 0.5f*kGravity*t*t;
    }

    Vector3 dir = {aim.x-origin.x, aim.y-origin.y, aim.z-origin.z};
    float m = Length3(dir);
    if (m <= 1e-4f) return false;

    // [FIX-3] нормализуем всегда для OB55
    dir.x/=m; dir.y/=m; dir.z/=m;

    // [FIX-2] корректируем угол чтобы пройти PGAIFNOGDAN dot-check
    dir = CorrectDirForCam(dir);

    WriteAddr<Vector3>(aimingInfo + kHit_RayDirectionOffset, dir);
    if (kWriteScatter) WriteAddr<float>(aimingInfo + kHit_Scatter, 0.0f);
    return true;
}

static inline int ForceWrite(uint64_t localPawn,
                              const Vector3& targetPos,
                              const Vector3& targetVel,
                              const Vector3& localVel,
                              float bulletSpeed) {
    if (!validPtr(localPawn) || !validVec(targetPos)) return 0;
    int wrote = 0;

    // cached slot
    uint64_t cached = g_aimPtr.load(std::memory_order_acquire);
    if (validPtr(cached))
        if (WriteSilentDir(cached, targetPos, targetVel, localVel, bulletSpeed)) wrote++;

    // primary slot 0xE50
    uint64_t info = ReadAddr<uint64_t>(localPawn + kLastAimInfoOffset);
    if (validPtr(info)) {
        g_aimPtr.store(info, std::memory_order_release);
        if (WriteSilentDir(info, targetPos, targetVel, localVel, bulletSpeed)) wrote++;
    }

    // alt slot 0xE58
    if (kWriteAltAimInfo) {
        uint64_t infoAlt = ReadAddr<uint64_t>(localPawn + kLastAimInfo_Alt);
        if (validPtr(infoAlt))
            if (WriteSilentDir(infoAlt, targetPos, targetVel, localVel, bulletSpeed)) wrote++;
    }

    // [FIX-1] new OB55 slots: 0xB10 и 0xB20
    {
        uint64_t info_b10 = ReadAddr<uint64_t>(localPawn + kAimInfo_B10);
        if (validPtr(info_b10))
            if (WriteSilentDir(info_b10, targetPos, targetVel, localVel, bulletSpeed)) wrote++;

        uint64_t info_b20 = ReadAddr<uint64_t>(localPawn + kAimInfo_B20);
        if (validPtr(info_b20))
            if (WriteSilentDir(info_b20, targetPos, targetVel, localVel, bulletSpeed)) wrote++;
    }

    return wrote;
}

// ─── Worker ──────────────────────────────────────────────
static void SilentWorker() {
    BoostWorkerQoS();
    const uint64_t localGen = g_matchGen.load(std::memory_order_acquire);
    while (true) {
        if (g_matchGen.load(std::memory_order_acquire) != localGen) {
            g_started.store(false, std::memory_order_release);
            g_firingUntilMs.store(0, std::memory_order_release);
            return;
        }
        if (!g_hasData.load(std::memory_order_acquire)) { std::this_thread::yield(); continue; }
        if (NowMs() - g_lastActivityMs.load(std::memory_order_acquire) > kHeartbeatMs) {
            g_hasData.store(false, std::memory_order_release); continue;
        }
        SilentSnapshot snap;
        { std::lock_guard<std::mutex> lk(g_lock); snap = g_snap; }
        if (!validPtr(snap.localPawn) || !validVec(snap.rawPos)) { std::this_thread::yield(); continue; }

        auto refresh = [&]() { std::lock_guard<std::mutex> lk(g_lock); snap = g_snap; };
        auto extrapolate = [&](Vector3& out) {
            uint64_t now = NowMs();
            float dt = (now > snap.timeMs) ? (float)(now - snap.timeMs)/1000.0f : 0.0f;
            if (dt > 0.20f) dt = 0.20f;
            out.x = snap.rawPos.x + snap.vel.x*dt;
            out.y = snap.rawPos.y + snap.vel.y*dt;
            out.z = snap.rawPos.z + snap.vel.z*dt;
        };

        const bool fireWindow = NowMs() < g_firingUntilMs.load(std::memory_order_acquire);
        if (fireWindow) {
            for (int i = 0; i < 64; i++) {
                if ((i & 7) == 0) refresh();
                Vector3 cur; extrapolate(cur);
                if (!validPtr(snap.localPawn) || !validVec(cur)) break;
                ForceWrite(snap.localPawn, cur, snap.vel, snap.localVel, snap.bulletSpeed);
                if (i >= 16 && NowMs() >= g_firingUntilMs.load(std::memory_order_acquire)) break;
            }
        } else {
            Vector3 cur; extrapolate(cur);
            for (int i = 0; i < 8; i++)
                ForceWrite(snap.localPawn, cur, snap.vel, snap.localVel, snap.bulletSpeed);
            std::this_thread::yield();
        }
    }
}

void InitSilentAimThread() {}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_firingUntilMs.store(0, std::memory_order_release);
    g_matchGen.fetch_add(1, std::memory_order_acq_rel);
    if (g_started.load(std::memory_order_acquire)) {
        for (int i = 0; i < 50; i++) {
            if (!g_started.load(std::memory_order_acquire)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    std::lock_guard<std::mutex> lk(g_lock);
    g_snap      = SilentSnapshot{};
    g_aimPtr.store(0, std::memory_order_release);
    g_lastMatch = 0;
    g_fr        = FireRateTracker{};
    g_boneTrack = BoneTracker{};
    g_started.store(false, std::memory_order_release);
}

void RunSilentAim(uint64_t target, uint64_t localPawn, int posMode, bool firing) {
    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
        ResetSilentAim(); return;
    }
    if (cachedMatch != g_lastMatch) {
        ResetSilentAim(); g_lastMatch = cachedMatch;
        g_matchGen.fetch_add(1, std::memory_order_acq_rel);
        return;
    }

    bool targetOk = validPtr(target) && validPtr(localPawn);
    if (targetOk && get_CurHP(target) <= 0 && !get_IsKnockedDown(target)) targetOk = false;

    Vector3 rawBone{};
    if (targetOk) {
        rawBone = ResolveAimBone(target, posMode);
        if (!validVec(rawBone) || !looksLikeWorldPos(rawBone)) targetOk = false;
    }
    if (!targetOk) {
        if (NowMs() - g_lastActivityMs.load(std::memory_order_acquire) > kGraceMs)
            g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 physVel{};
    if (GetWorldVelocity(target, physVel)) {
        float vXZ = sqrtf(physVel.x*physVel.x + physVel.z*physVel.z);
        if (vXZ > kMaxVelXZ) { float inv=kMaxVelXZ/vXZ; physVel.x*=inv; physVel.z*=inv; }
        if (fabsf(physVel.y)>kMaxVelY) physVel.y=(physVel.y>0?1.f:-1.f)*kMaxVelY;
    }

    Vector3 rawHead = BonePos(target, kHeadNode);
    Vector3 boneVel = validVec(rawHead) ? UpdateBoneVelocity(target, rawHead) : Vector3{};
    Vector3 vel = FuseVelocity(physVel, boneVel);

    Vector3 localVel{};
    GetWorldVelocity(localPawn, localVel);

    uint64_t nowMs = NowMs();
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_snap.rawPos      = rawBone;
        g_snap.vel         = vel;
        g_snap.localVel    = localVel;
        g_snap.bulletSpeed = kBulletSpeed;
        g_snap.timeMs      = nowMs;
        g_snap.localPawn   = localPawn;
        g_snap.enemy       = target;
        g_snap.posMode     = posMode;
    }

    {
        uint64_t info = ReadAddr<uint64_t>(localPawn + kLastAimInfoOffset);
        if (!validPtr(info)) info = ReadAddr<uint64_t>(localPawn + kLastAimInfo_Alt);
        if (validPtr(info)) g_aimPtr.store(info, std::memory_order_release);
    }

    g_lastActivityMs.store(nowMs, std::memory_order_release);
    g_hasData.store(true, std::memory_order_release);

    bool rawFiring = IsLocalFiring(localPawn);
    bool preFiring = IsPreparingAttack(localPawn);
    bool firingNow = firing || rawFiring || preFiring;

    uint64_t windowMs = FireWindowEstimate(rawFiring);
    if (preFiring) windowMs += kPreFireBoostMs;
    if (firingNow) {
        uint64_t until = nowMs + windowMs;
        uint64_t cur   = g_firingUntilMs.load(std::memory_order_relaxed);
        if (until > cur) g_firingUntilMs.store(until, std::memory_order_release);
    }

    if (!g_started.exchange(true, std::memory_order_acq_rel))
        std::thread(SilentWorker).detach();

    const int bursts = firingNow ? 32 : 4;
    for (int burst = 0; burst < bursts; burst++) {
        if ((burst & 3) == 0) {
            Vector3 liveBone = ResolveAimBone(target, posMode);
            if (validVec(liveBone) && looksLikeWorldPos(liveBone)) {
                Vector3 liveVel{}, liveLocalVel{};
                if (!GetWorldVelocity(target, liveVel)) liveVel = vel;
                if (!GetWorldVelocity(localPawn, liveLocalVel)) liveLocalVel = localVel;
                { std::lock_guard<std::mutex> lk(g_lock);
                  g_snap.rawPos=liveBone; g_snap.vel=liveVel;
                  g_snap.localVel=liveLocalVel; g_snap.timeMs=NowMs(); }
                rawBone=liveBone; vel=liveVel; localVel=liveLocalVel;
            }
        }
        ForceWrite(localPawn, rawBone, vel, localVel, kBulletSpeed);
    }
}
