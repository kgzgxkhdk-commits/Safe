#pragma once
#include <stdint.h>

void InitSilentAimThread();
void RunSilentAim(uint64_t target, uint64_t localPawn, int posMode, bool firing);
void ResetSilentAim();
