#pragma once
#include <stdint.h>
#include "../esp/Core/UnityMath.h"

void InitSilentAimThread();
void RunSilentAim(uint64_t target, uint64_t localPawn, int posMode, bool firing);
void ResetSilentAim();

// [FIX-2] вызывай каждый кадр чтобы передать forward вектор камеры
// camFwd — нормализованный вектор направления камеры в world space
void SilentUpdateCamFwd(Vector3 camFwd);
