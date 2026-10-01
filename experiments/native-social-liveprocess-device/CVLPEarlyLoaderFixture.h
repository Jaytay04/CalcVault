#ifndef CVLP_EARLY_LOADER_FIXTURE_H
#define CVLP_EARLY_LOADER_FIXTURE_H

#include <stdint.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*CVLPEarlyLoaderGateFunction)(void);

typedef uint32_t (*CVLPEarlyLoaderCounterFunction)(void);
typedef int32_t (*CVLPEarlyLoaderResultFunction)(void);
typedef uintptr_t (*CVLPEarlyLoaderAddressFunction)(void);
typedef void (*CVLPEarlyLoaderSetGateFunction)(CVLPEarlyLoaderGateFunction gate);

// Exported symbols resolved by the host fixture with each dlopen handle.
uint32_t CVLPEarlyLoaderConstructorCount(void);
uint32_t CVLPEarlyLoaderOriginalCallCount(void);
uint32_t CVLPEarlyLoaderOverwriteCallCount(void);
int32_t CVLPEarlyLoaderConstructorResult(void);
uintptr_t CVLPEarlyLoaderGateAddress(void);
uintptr_t CVLPEarlyLoaderOriginalAddress(void);
void CVLPEarlyLoaderSetGate(CVLPEarlyLoaderGateFunction gate);
BOOL CVLPEarlyLoaderOverwrite(void);

typedef struct {
    uint8_t uuid[16];
    BOOL valid;
} CVLPEarlyLoaderUUID;

/// Runs a synthetic dyld callback timing check. The real callback must observe
/// the target dylib before its constructor; this test does not exercise or claim
/// proprietary initializer behavior.
BOOL CVLPEarlyLoaderRunFixture(NSString * _Nullable * _Nullable failure);

NS_ASSUME_NONNULL_END

#endif
