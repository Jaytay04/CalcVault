#import "CVLPEarlyLoaderFixture.h"
#include <stdatomic.h>

#if !defined(__APPLE__)
#error This synthetic dyld fixture requires Apple platforms.
#endif

static _Atomic(uint32_t) CVLPEarlyLoaderConstructorCountValue = 0;
static _Atomic(uint32_t) CVLPEarlyLoaderOriginalCallCountValue = 0;
static _Atomic(uint32_t) CVLPEarlyLoaderOverwriteCallCountValue = 0;
static _Atomic(int32_t) CVLPEarlyLoaderConstructorResultValue = -1;

static BOOL CVLPEarlyLoaderOriginal(void) {
    atomic_fetch_add_explicit(&CVLPEarlyLoaderOriginalCallCountValue, 1, memory_order_relaxed);
    return NO;
}

BOOL CVLPEarlyLoaderOverwrite(void) {
    atomic_fetch_add_explicit(&CVLPEarlyLoaderOverwriteCallCountValue, 1, memory_order_relaxed);
    return NO;
}

__attribute__((visibility("default"), used, section("__DATA,__cvlpgate")))
_Atomic(CVLPEarlyLoaderGateFunction) CVLPEarlyLoaderGate = CVLPEarlyLoaderOriginal;

uint32_t CVLPEarlyLoaderConstructorCount(void) {
    return atomic_load_explicit(&CVLPEarlyLoaderConstructorCountValue, memory_order_relaxed);
}

uint32_t CVLPEarlyLoaderOriginalCallCount(void) {
    return atomic_load_explicit(&CVLPEarlyLoaderOriginalCallCountValue, memory_order_relaxed);
}

uint32_t CVLPEarlyLoaderOverwriteCallCount(void) {
    return atomic_load_explicit(&CVLPEarlyLoaderOverwriteCallCountValue, memory_order_relaxed);
}

int32_t CVLPEarlyLoaderConstructorResult(void) {
    return atomic_load_explicit(&CVLPEarlyLoaderConstructorResultValue, memory_order_relaxed);
}

uintptr_t CVLPEarlyLoaderGateAddress(void) {
    return (uintptr_t)&CVLPEarlyLoaderGate;
}

uintptr_t CVLPEarlyLoaderOriginalAddress(void) {
    return (uintptr_t)&CVLPEarlyLoaderOriginal;
}

void CVLPEarlyLoaderSetGate(CVLPEarlyLoaderGateFunction gate) {
    atomic_store_explicit(&CVLPEarlyLoaderGate, gate, memory_order_release);
}

static void CVLPEarlyLoaderRunConstructor(void) __attribute__((constructor));
static void CVLPEarlyLoaderRunConstructor(void) {
    atomic_fetch_add_explicit(&CVLPEarlyLoaderConstructorCountValue, 1, memory_order_relaxed);
    CVLPEarlyLoaderGateFunction gate = atomic_load_explicit(&CVLPEarlyLoaderGate, memory_order_acquire);
    int32_t result = gate == NULL ? -1 : (gate() ? 1 : 0);
    atomic_store_explicit(&CVLPEarlyLoaderConstructorResultValue, result, memory_order_release);
}
