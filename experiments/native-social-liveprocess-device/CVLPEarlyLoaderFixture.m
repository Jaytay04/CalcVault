#import "CVLPEarlyLoaderFixture.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    void *handle;
    CVLPEarlyLoaderCounterFunction constructorCount;
    CVLPEarlyLoaderCounterFunction originalCallCount;
    CVLPEarlyLoaderCounterFunction overwriteCallCount;
    CVLPEarlyLoaderResultFunction constructorResult;
    CVLPEarlyLoaderAddressFunction gateAddress;
    CVLPEarlyLoaderAddressFunction originalAddress;
    CVLPEarlyLoaderSetGateFunction setGate;
    CVLPEarlyLoaderGateFunction overwrite;
} CVLPEarlyLoaderLoadedImage;

typedef struct {
    CVLPEarlyLoaderUUID targetUUID;
    CVLPEarlyLoaderUUID unrelatedUUID;
    CVLPEarlyLoaderUUID mismatchUUID;
    uint32_t targetResolverCalls;
    uint32_t unrelatedResolverCalls;
    uint32_t unrelatedReplayResolverCalls;
    uint32_t targetReplayResolverCalls;
    uint32_t mismatchResolverCalls;
    uint32_t otherResolverCalls;
    uintptr_t targetSlotAddress;
    uintptr_t targetOriginalAddress;
    const struct mach_header *targetHeader;
    intptr_t targetSlide;
    BOOL armInProgress;
} CVLPEarlyLoaderInstallerContext;

// The header keeps this TESTING resolver installed after the fixture returns;
// retain its context for the full process lifetime rather than pointing into
// the runner's stack frame.
static CVLPEarlyLoaderInstallerContext CVLPEarlyLoaderContext;
static BOOL CVLPEarlyLoaderReplayTerminalCompleted = NO;

static BOOL CVLPEarlyLoaderUUIDEquals(CVLPEarlyLoaderUUID left, CVLPEarlyLoaderUUID right) {
    return left.valid && right.valid && memcmp(left.uuid, right.uuid, sizeof(left.uuid)) == 0;
}

static CVLPEarlyLoaderUUID CVLPEarlyLoaderUUIDFromBytes(const void *bytes, size_t length) {
    CVLPEarlyLoaderUUID result = {0};
    if (bytes == NULL || length < sizeof(struct mach_header_64)) { return result; }
    struct mach_header_64 header;
    memcpy(&header, bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 || header.filetype != MH_DYLIB ||
        header.ncmds == 0 || header.ncmds > 4096 || header.sizeofcmds > 4 * 1024 * 1024 ||
        header.sizeofcmds > length - sizeof(header)) {
        return result;
    }

    const uint8_t *cursor = (const uint8_t *)bytes + sizeof(header);
    size_t remaining = header.sizeofcmds;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        struct load_command command;
        if (remaining < sizeof(command)) { return (CVLPEarlyLoaderUUID){0}; }
        memcpy(&command, cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) {
            return (CVLPEarlyLoaderUUID){0};
        }
        if (command.cmd == LC_UUID) {
            if (result.valid || command.cmdsize < sizeof(struct uuid_command)) {
                return (CVLPEarlyLoaderUUID){0};
            }
            struct uuid_command uuidCommand;
            memcpy(&uuidCommand, cursor, sizeof(uuidCommand));
            memcpy(result.uuid, uuidCommand.uuid, sizeof(result.uuid));
            result.valid = YES;
        }
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
    if (remaining != 0) { return (CVLPEarlyLoaderUUID){0}; }
    return result;
}

static CVLPEarlyLoaderUUID CVLPEarlyLoaderUUIDFromFile(NSString *path) {
    CVLPEarlyLoaderUUID result = {0};
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (data.length == 0 || data.length > 32 * 1024 * 1024) { return result; }
    return CVLPEarlyLoaderUUIDFromBytes(data.bytes, data.length);
}

static BOOL CVLPEarlyLoaderReadLoadedIdentity(const struct mach_header *header, intptr_t slide,
    CVLPEarlyLoaderUUID *uuid, uintptr_t *gateSlot) {
    if (header == NULL || uuid == NULL || gateSlot == NULL) { return NO; }
    struct mach_header_64 header64;
    memcpy(&header64, header, sizeof(header64));
    if (header64.magic != MH_MAGIC_64 || header64.cputype != CPU_TYPE_ARM64 ||
        header64.filetype != MH_DYLIB || header64.ncmds == 0 || header64.ncmds > 4096 ||
        header64.sizeofcmds > 4 * 1024 * 1024) {
        return NO;
    }

    CVLPEarlyLoaderUUID foundUUID = {0};
    uintptr_t foundSlot = 0;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    size_t remaining = header64.sizeofcmds;
    for (uint32_t index = 0; index < header64.ncmds; index++) {
        struct load_command command;
        if (remaining < sizeof(command)) { return NO; }
        memcpy(&command, cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) { return NO; }
        if (command.cmd == LC_UUID) {
            if (foundUUID.valid || command.cmdsize < sizeof(struct uuid_command)) { return NO; }
            struct uuid_command uuidCommand;
            memcpy(&uuidCommand, cursor, sizeof(uuidCommand));
            memcpy(foundUUID.uuid, uuidCommand.uuid, sizeof(foundUUID.uuid));
            foundUUID.valid = YES;
        } else if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) { return NO; }
            struct segment_command_64 segment;
            memcpy(&segment, cursor, sizeof(segment));
            if (segment.nsects > (command.cmdsize - sizeof(segment)) / sizeof(struct section_64)) { return NO; }
            if (strncmp(segment.segname, "__DATA", sizeof(segment.segname)) != 0) {
                cursor += command.cmdsize;
                remaining -= command.cmdsize;
                continue;
            }
            const struct section_64 *sections = (const struct section_64 *)(cursor + sizeof(segment));
            for (uint32_t sectionIndex = 0; sectionIndex < segment.nsects; sectionIndex++) {
                struct section_64 section;
                memcpy(&section, &sections[sectionIndex], sizeof(section));
                if (strncmp(section.sectname, "__cvlpgate", sizeof(section.sectname)) != 0) { continue; }
                if (foundSlot != 0 || section.size != sizeof(uintptr_t) ||
                    (section.flags & SECTION_TYPE) == S_ZEROFILL || segment.initprot != (VM_PROT_READ | VM_PROT_WRITE)) {
                    return NO;
                }
                if (!CVLPHighlightsDirectRangeContains(segment.vmaddr, segment.vmsize,
                    section.addr, section.size)) { return NO; }
                uintptr_t address = (uintptr_t)section.addr;
                if (slide >= 0) {
                    uintptr_t positiveSlide = (uintptr_t)slide;
                    if (address > UINTPTR_MAX - positiveSlide) { return NO; }
                    address += positiveSlide;
                } else {
                    uintptr_t negativeSlide = (uintptr_t)(-(slide + 1)) + 1;
                    if (address < negativeSlide) { return NO; }
                    address -= negativeSlide;
                }
                if ((address & (sizeof(uintptr_t) - 1)) != 0) { return NO; }
                foundSlot = address;
            }
        }
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
    if (remaining != 0 || !foundUUID.valid || foundSlot == 0) { return NO; }
    *uuid = foundUUID;
    *gateSlot = foundSlot;
    return YES;
}

static BOOL CVLPEarlyLoaderResolveSyntheticImage(const struct mach_header *header, intptr_t slide,
    uintptr_t *slotAddress, uintptr_t *expectedOriginal, void *opaque) {
    CVLPEarlyLoaderInstallerContext *context = opaque;
    if (context == NULL || slotAddress == NULL || expectedOriginal == NULL) { return NO; }
    context->otherResolverCalls++;

    CVLPEarlyLoaderUUID imageUUID = {0};
    uintptr_t imageSlot = 0;
    if (!CVLPEarlyLoaderReadLoadedIdentity(header, slide, &imageUUID, &imageSlot)) { return NO; }
    BOOL isTarget = CVLPEarlyLoaderUUIDEquals(imageUUID, context->targetUUID);
    BOOL isUnrelated = CVLPEarlyLoaderUUIDEquals(imageUUID, context->unrelatedUUID);
    BOOL isMismatch = CVLPEarlyLoaderUUIDEquals(imageUUID, context->mismatchUUID);
    if (isMismatch) { context->mismatchResolverCalls++; }
    if (isUnrelated) {
        context->unrelatedResolverCalls++;
        if (context->armInProgress) { context->unrelatedReplayResolverCalls++; }
    }
    if (!isTarget) { return NO; }
    if (!CVLPHighlightsDirectMachRegionAllows(imageSlot, sizeof(uintptr_t),
            VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE, NULL)) { return NO; }

    _Atomic(CVLPEarlyLoaderGateFunction) *gate = (_Atomic(CVLPEarlyLoaderGateFunction) *)imageSlot;
    CVLPEarlyLoaderGateFunction original = atomic_load_explicit(gate, memory_order_acquire);
    uintptr_t originalAddress = 0;
    if (original == NULL || sizeof(original) != sizeof(originalAddress)) { return NO; }
    memcpy(&originalAddress, &original, sizeof(originalAddress));

    if (isTarget) {
        context->targetResolverCalls++;
        if (context->armInProgress) { context->targetReplayResolverCalls++; }
        context->targetSlotAddress = imageSlot;
        context->targetOriginalAddress = originalAddress;
        context->targetHeader = header;
        context->targetSlide = slide;
    }
    *slotAddress = imageSlot;
    *expectedOriginal = originalAddress;
    return YES;
}

static void *CVLPEarlyLoaderResolveSymbol(void *handle, const char *name) {
    if (handle == NULL || name == NULL) { return NULL; }
    dlerror();
    void *symbol = dlsym(handle, name);
    return dlerror() == NULL ? symbol : NULL;
}

static BOOL CVLPEarlyLoaderLoadImage(NSString *resourceName, CVLPEarlyLoaderLoadedImage *image,
    NSString **failure) {
    if (image == NULL) { if (failure != NULL) { *failure = @"image_state_missing"; } return NO; }
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (frameworksURL == nil) { if (failure != NULL) { *failure = @"frameworks_resource_directory_missing"; } return NO; }
    NSString *path = [frameworksURL URLByAppendingPathComponent:resourceName].path;
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) { if (failure != NULL) { *failure = @"synthetic_dylib_load_failed"; } return NO; }
    memset(image, 0, sizeof(*image));
    image->handle = handle;
#define CVLP_EARLY_RESOLVE_FUNCTION(field, symbolName) \
    do { \
        void *resolvedSymbol = CVLPEarlyLoaderResolveSymbol(handle, symbolName); \
        if (resolvedSymbol == NULL || sizeof(image->field) != sizeof(resolvedSymbol)) { \
            if (failure != NULL) { *failure = @"synthetic_dylib_contract_missing"; } \
            return NO; \
        } \
        memcpy(&image->field, &resolvedSymbol, sizeof(resolvedSymbol)); \
    } while (0)
    CVLP_EARLY_RESOLVE_FUNCTION(constructorCount, "CVLPEarlyLoaderConstructorCount");
    CVLP_EARLY_RESOLVE_FUNCTION(originalCallCount, "CVLPEarlyLoaderOriginalCallCount");
    CVLP_EARLY_RESOLVE_FUNCTION(overwriteCallCount, "CVLPEarlyLoaderOverwriteCallCount");
    CVLP_EARLY_RESOLVE_FUNCTION(constructorResult, "CVLPEarlyLoaderConstructorResult");
    CVLP_EARLY_RESOLVE_FUNCTION(gateAddress, "CVLPEarlyLoaderGateAddress");
    CVLP_EARLY_RESOLVE_FUNCTION(originalAddress, "CVLPEarlyLoaderOriginalAddress");
    CVLP_EARLY_RESOLVE_FUNCTION(setGate, "CVLPEarlyLoaderSetGate");
    CVLP_EARLY_RESOLVE_FUNCTION(overwrite, "CVLPEarlyLoaderOverwrite");
#undef CVLP_EARLY_RESOLVE_FUNCTION
    return YES;
}

static CVLPEarlyLoaderGateFunction CVLPEarlyLoaderGateFromAddress(uintptr_t address) {
    CVLPEarlyLoaderGateFunction function = NULL;
    if (sizeof(function) == sizeof(address)) { memcpy(&function, &address, sizeof(function)); }
    return function;
}

static BOOL CVLPEarlyLoaderRunObserverPreservationCheck(CVLPHighlightsHookState expectedState,
    NSString **failure) {
    CFTimeInterval expectedStartTime = CVLPHighlightsStartedAt;
    CVLPHighlightsObserver *observer = [CVLPHighlightsObserver new];
    observer->_startedAt = CACurrentMediaTime();
    NSUInteger lineCount = CVLPFixtureDiagnosticLines.count;
    [observer startOnMainQueue];
    CVLPHighlightsHookState state;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    state = CVLPHighlightsState;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    NSString *startLine = lineCount < CVLPFixtureDiagnosticLines.count ? CVLPFixtureDiagnosticLines[lineCount] : nil;
    return CVLPFixtureRequire(state.earlyStatus == expectedState.earlyStatus &&
        state.earlyMatches == expectedState.earlyMatches && state.earlyRetained == expectedState.earlyRetained &&
        state.directStatus == expectedState.directStatus && state.directCalls == expectedState.directCalls &&
        state.directOverrideCalls == expectedState.directOverrideCalls && state.directLast == expectedState.directLast &&
        CVLPHighlightsStartedAt == expectedStartTime && observer->_startedAt == expectedStartTime &&
        CVLPHighlightsLineIsSanitized(startLine) &&
        [startLine containsString:[NSString stringWithFormat:@"earlyMode=1 earlyStatus=%d earlyMatches=%u earlyRetained=%d",
            expectedState.earlyStatus, expectedState.earlyMatches, expectedState.earlyRetained]],
        @"early_observer_start_preserves_counters_and_numeric_schema", failure);
}

static CVLPHighlightsHookState CVLPEarlyLoaderStateSnapshot(void) {
    CVLPHighlightsHookState state;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    state = CVLPHighlightsState;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    state.directStatus = atomic_load_explicit(&CVLPHighlightsEarlyDirectStatus, memory_order_acquire);
    state.earlyStatus = atomic_load_explicit(&CVLPHighlightsEarlyStatusValue, memory_order_acquire);
    state.earlyMatches = atomic_load_explicit(&CVLPHighlightsEarlyMatchCount, memory_order_acquire);
    state.earlyRetained = atomic_load_explicit(&CVLPHighlightsEarlyRetainedValue, memory_order_acquire);
    return state;
}

static void CVLPEarlyLoaderResetDirectCounters(void) {
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    CVLPHighlightsState.directCalls = 0;
    CVLPHighlightsState.directOverrideCalls = 0;
    CVLPHighlightsState.directLast = -1;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
}

static void CVLPEarlyLoaderConfigureContext(CVLPEarlyLoaderUUID targetUUID,
    CVLPEarlyLoaderUUID unrelatedUUID, CVLPEarlyLoaderUUID mismatchUUID) {
    memset(&CVLPEarlyLoaderContext, 0, sizeof(CVLPEarlyLoaderContext));
    CVLPEarlyLoaderContext.targetUUID = targetUUID;
    CVLPEarlyLoaderContext.unrelatedUUID = unrelatedUUID;
    CVLPEarlyLoaderContext.mismatchUUID = mismatchUUID;
    CVLPEarlyLoaderContext.armInProgress = YES;
    CVLPHighlightsEarlyTestSetInstaller(CVLPEarlyLoaderResolveSyntheticImage, &CVLPEarlyLoaderContext);
}

static BOOL CVLPEarlyLoaderRunNormalTimingPath(CVLPEarlyLoaderUUID targetUUID,
    CVLPEarlyLoaderUUID unrelatedUUID, CVLPEarlyLoaderUUID mismatchUUID, NSString **failure) {
    CVLPEarlyLoaderLoadedImage unrelated;
    if (!CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderAlreadyLoaded.dylib", &unrelated, failure)) { return NO; }
    uintptr_t unrelatedGateAddress = unrelated.gateAddress();
    CVLPEarlyLoaderGateFunction unrelatedOriginal =
        CVLPEarlyLoaderGateFromAddress(unrelated.originalAddress());
    if (!CVLPFixtureRequire(unrelated.constructorCount() == 1 && unrelated.constructorResult() == 0 &&
        unrelated.originalCallCount() == 1 && unrelatedGateAddress != 0 &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)unrelatedGateAddress,
            memory_order_acquire) == unrelatedOriginal,
        @"unrelated_preloaded_constructor_observed_natural_false", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=unrelated-preloaded-constructor-natural-false\n");

    CVLPEarlyLoaderConfigureContext(targetUUID, unrelatedUUID, mismatchUUID);
    CVLPEarlyLoaderResetDirectCounters();
    [CVLPHighlightsDiagnostics armEarlyViewing];
    CVLPEarlyLoaderContext.armInProgress = NO;
    CVLPHighlightsHookState afterArm = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestReplayDeliveries() > 0 &&
        afterArm.earlyStatus == CVLPHighlightsEarlyArmed && afterArm.earlyMatches == 0 &&
        CVLPHighlightsEarlyTestCASAttempts() == 0 &&
        CVLPEarlyLoaderContext.unrelatedReplayResolverCalls > 0 &&
        CVLPEarlyLoaderContext.targetResolverCalls == 0 &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)unrelatedGateAddress,
            memory_order_acquire) == unrelatedOriginal,
        @"unrelated_registration_replay_does_not_consume_target_attempt", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=unrelated-registration-replay-does-not-consume-attempt\n");

    CVLPEarlyLoaderLoadedImage mismatch;
    if (!CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderMismatch.dylib", &mismatch, failure)) { return NO; }
    CVLPHighlightsHookState afterMismatch = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPFixtureRequire(mismatch.constructorCount() == 1 && mismatch.constructorResult() == 0 &&
        mismatch.originalCallCount() == 1 && CVLPEarlyLoaderContext.targetResolverCalls == 0 &&
        CVLPEarlyLoaderContext.mismatchResolverCalls > 0 && CVLPHighlightsEarlyTestCASAttempts() == 0 &&
        afterMismatch.earlyStatus == CVLPHighlightsEarlyArmed && afterMismatch.earlyMatches == 0,
        @"synthetic_uuid_mismatch_resolved_without_install", failure)) { return NO; }
    CVLPEarlyLoaderGateFunction mismatchOriginal = CVLPEarlyLoaderGateFromAddress(mismatch.originalAddress());
    if (!CVLPFixtureRequire(atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)mismatch.gateAddress(),
            memory_order_acquire) == mismatchOriginal,
        @"mismatch_slot_remains_original", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=mismatch-rejected\n");

    CVLPEarlyLoaderLoadedImage target;
    if (!CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderTarget.dylib", &target, failure)) { return NO; }
    uintptr_t targetGateAddress = target.gateAddress();
    uintptr_t replacementAddress = CVLPHighlightsDirectReplacementAddress();
    uintptr_t currentGateAddress = 0;
    CVLPEarlyLoaderGateFunction currentGate = atomic_load_explicit(
        (_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress, memory_order_acquire);
    memcpy(&currentGateAddress, &currentGate, sizeof(currentGateAddress));
    CVLPHighlightsHookState targetState = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPFixtureRequire(target.constructorCount() == 1 && target.constructorResult() == 1 &&
        target.originalCallCount() == 1 && CVLPEarlyLoaderContext.targetResolverCalls == 1 &&
        CVLPEarlyLoaderContext.targetHeader != NULL && CVLPEarlyLoaderContext.targetSlotAddress == targetGateAddress &&
        CVLPEarlyLoaderContext.targetOriginalAddress == target.originalAddress() &&
        currentGateAddress == replacementAddress && CVLPHighlightsEarlyTestCASAttempts() == 1 &&
        targetState.directCalls == 1 && targetState.directOverrideCalls == 1 && targetState.directLast == 0,
        @"registered_dyld_callback_installed_forwarder_before_constructor", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=callback-before-constructor\n");

    CVLPHighlightsEarlyTestDeliverImageCallback(CVLPEarlyLoaderContext.targetHeader,
        CVLPEarlyLoaderContext.targetSlide);
    CVLPEarlyLoaderGateFunction afterDuplicate = atomic_load_explicit(
        (_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress, memory_order_acquire);
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestCASAttempts() == 1 &&
        afterDuplicate == CVLPEarlyLoaderGateFromAddress(replacementAddress) && target.overwriteCallCount() == 0,
        @"duplicate_callback_does_not_compare_exchange_or_reinstall", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=duplicate-no-second-cas\n");

    [CVLPHighlightsDiagnostics finishEarlyViewingLoad];
    CVLPHighlightsHookState afterFinish = CVLPEarlyLoaderStateSnapshot();
    CVLPEarlyLoaderGateFunction afterFinishGate = atomic_load_explicit(
        (_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress, memory_order_acquire);
    if (!CVLPFixtureRequire(afterFinish.earlyStatus == CVLPHighlightsEarlyInstalled &&
        afterFinish.earlyRetained == 1 && afterFinishGate == CVLPEarlyLoaderGateFromAddress(replacementAddress) &&
        CVLPHighlightsEarlyTestCASAttempts() == 1,
        @"installed_pointer_retained_on_writable_data_slot", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=early-slot-retained\n");

    uint32_t targetResolverCalls = CVLPEarlyLoaderContext.targetResolverCalls;
    CVLPHighlightsEarlyTestDeliverImageCallback(CVLPEarlyLoaderContext.targetHeader,
        CVLPEarlyLoaderContext.targetSlide);
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestCASAttempts() == 1 &&
        CVLPEarlyLoaderContext.targetResolverCalls == targetResolverCalls &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress,
            memory_order_acquire) == CVLPEarlyLoaderGateFromAddress(replacementAddress),
        @"finished_callback_is_inert_for_duplicate_image", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=callback-inert-after-finish\n");

    // This manual post-finish change tests retention reporting only; it does not
    // attribute an overwrite to the synthetic constructor or a proprietary initializer.
    CVLPEarlyLoaderGateFunction overwrite = target.overwrite;
    target.setGate(overwrite);
    [CVLPHighlightsDiagnostics finishEarlyViewingLoad];
    CVLPHighlightsHookState afterOverwrite = CVLPEarlyLoaderStateSnapshot();
    CVLPHighlightsEarlyTestDeliverImageCallback(CVLPEarlyLoaderContext.targetHeader,
        CVLPEarlyLoaderContext.targetSlide);
    CVLPEarlyLoaderGateFunction afterOverwriteCallback = atomic_load_explicit(
        (_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress, memory_order_acquire);
    if (!CVLPFixtureRequire(afterOverwrite.earlyStatus == CVLPHighlightsEarlyInstalled &&
        afterOverwrite.earlyRetained == 0 && afterOverwriteCallback == overwrite &&
        target.overwriteCallCount() == 0 && CVLPHighlightsEarlyTestCASAttempts() == 1 &&
        CVLPEarlyLoaderContext.targetResolverCalls == targetResolverCalls,
        @"post_finish_pointer_change_reported_without_reinstall", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=post-finish-pointer-change-reported\n");

    CVLPHighlightsHookState expectedState = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPEarlyLoaderRunObserverPreservationCheck(expectedState, failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=observer-start-preserved-counters\n");
    return YES;
}

static BOOL CVLPEarlyLoaderRunReplayOnlyPath(CVLPEarlyLoaderUUID targetUUID,
    CVLPEarlyLoaderUUID mismatchUUID, NSString **failure) {
    CVLPEarlyLoaderLoadedImage target;
    if (!CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderTarget.dylib", &target, failure)) { return NO; }
    uintptr_t targetGateAddress = target.gateAddress();
    CVLPEarlyLoaderGateFunction targetOriginal = CVLPEarlyLoaderGateFromAddress(target.originalAddress());
    if (!CVLPFixtureRequire(target.constructorCount() == 1 && target.constructorResult() == 0 &&
        target.originalCallCount() == 1 && targetGateAddress != 0 &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress,
            memory_order_acquire) == targetOriginal,
        @"target_preloaded_constructor_observed_natural_false", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=replay-target-preloaded-natural-false\n");

    CVLPEarlyLoaderConfigureContext(targetUUID, (CVLPEarlyLoaderUUID){0}, mismatchUUID);
    CVLPEarlyLoaderResetDirectCounters();
    [CVLPHighlightsDiagnostics armEarlyViewing];
    CVLPEarlyLoaderContext.armInProgress = NO;
    CVLPHighlightsHookState afterArm = CVLPEarlyLoaderStateSnapshot();
    CVLPEarlyLoaderGateFunction afterReplay = atomic_load_explicit(
        (_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress, memory_order_acquire);
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestReplayDeliveries() > 0 &&
        afterArm.earlyStatus == CVLPHighlightsEarlyReplaySkipped && afterArm.earlyMatches == 1 &&
        CVLPHighlightsEarlyTestCASAttempts() == 0 && CVLPEarlyLoaderContext.targetReplayResolverCalls == 1 &&
        CVLPEarlyLoaderContext.targetHeader != NULL && target.constructorResult() == 0 &&
        target.originalCallCount() == 1 && afterReplay == targetOriginal,
        @"matching_registration_replay_terminally_skips_without_cas", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=matching-target-replay-terminal-no-cas\n");

    uint32_t targetResolverCalls = CVLPEarlyLoaderContext.targetResolverCalls;
    CVLPHighlightsEarlyTestDeliverImageCallback(CVLPEarlyLoaderContext.targetHeader,
        CVLPEarlyLoaderContext.targetSlide);
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestCASAttempts() == 0 &&
        CVLPEarlyLoaderContext.targetResolverCalls == targetResolverCalls &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress,
            memory_order_acquire) == targetOriginal,
        @"matching_target_replay_remains_terminal_after_manual_delivery", failure)) { return NO; }

    CVLPEarlyLoaderLoadedImage mismatch;
    if (!CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderMismatch.dylib", &mismatch, failure)) { return NO; }
    CVLPEarlyLoaderGateFunction mismatchOriginal = CVLPEarlyLoaderGateFromAddress(mismatch.originalAddress());
    if (!CVLPFixtureRequire(mismatch.constructorCount() == 1 && mismatch.constructorResult() == 0 &&
        mismatch.originalCallCount() == 1 && CVLPEarlyLoaderContext.mismatchResolverCalls == 0 &&
        CVLPHighlightsEarlyTestCASAttempts() == 0 &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)mismatch.gateAddress(),
            memory_order_acquire) == mismatchOriginal &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress,
            memory_order_acquire) == targetOriginal,
        @"terminal_replay_attempt_rejects_later_mismatch_without_install", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=replay-terminal-blocks-later-mismatch\n");

    [CVLPHighlightsDiagnostics finishEarlyViewingLoad];
    CVLPHighlightsHookState afterFinish = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPFixtureRequire(afterFinish.earlyStatus == CVLPHighlightsEarlyReplaySkipped &&
        afterFinish.earlyRetained == 0 && CVLPHighlightsEarlyTestCASAttempts() == 0,
        @"replay_only_finish_preserves_skipped_and_unretained", failure)) { return NO; }
    CVLPHighlightsEarlyTestDeliverImageCallback(CVLPEarlyLoaderContext.targetHeader,
        CVLPEarlyLoaderContext.targetSlide);
    if (!CVLPFixtureRequire(CVLPHighlightsEarlyTestCASAttempts() == 0 &&
        atomic_load_explicit((_Atomic(CVLPEarlyLoaderGateFunction) *)targetGateAddress,
            memory_order_acquire) == targetOriginal,
        @"finished_replay_callback_is_inert", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=replay-only-finish-and-callback-inert\n");

    CVLPHighlightsHookState expectedState = CVLPEarlyLoaderStateSnapshot();
    if (!CVLPEarlyLoaderRunObserverPreservationCheck(expectedState, failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=replay-only-observer-preserved-counters\n");
    fprintf(stderr, "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=exact-target-replay-terminal\n");
    CVLPEarlyLoaderReplayTerminalCompleted = YES;
    return YES;
}

BOOL CVLPEarlyLoaderRunFixture(NSString **failure) {
#if !CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
    (void)failure;
    return YES;
#else
    if (failure != NULL) { *failure = nil; }
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (frameworksURL == nil) { if (failure != NULL) { *failure = @"frameworks_resource_directory_missing"; } return NO; }
    NSString *targetPath = [frameworksURL URLByAppendingPathComponent:@"CVLPEarlyLoaderTarget.dylib"].path;
    NSString *unrelatedPath = [frameworksURL URLByAppendingPathComponent:@"CVLPEarlyLoaderAlreadyLoaded.dylib"].path;
    NSString *mismatchPath = [frameworksURL URLByAppendingPathComponent:@"CVLPEarlyLoaderMismatch.dylib"].path;
    CVLPEarlyLoaderUUID targetUUID = CVLPEarlyLoaderUUIDFromFile(targetPath);
    CVLPEarlyLoaderUUID unrelatedUUID = CVLPEarlyLoaderUUIDFromFile(unrelatedPath);
    CVLPEarlyLoaderUUID mismatchUUID = CVLPEarlyLoaderUUIDFromFile(mismatchPath);
    if (!CVLPFixtureRequire(targetUUID.valid && unrelatedUUID.valid && mismatchUUID.valid &&
        !CVLPEarlyLoaderUUIDEquals(targetUUID, unrelatedUUID) &&
        !CVLPEarlyLoaderUUIDEquals(targetUUID, mismatchUUID) &&
        !CVLPEarlyLoaderUUIDEquals(unrelatedUUID, mismatchUUID),
        @"synthetic_resource_uuids_are_present_and_distinct", failure)) { return NO; }

    const char *replayOnlyValue = getenv("CV_HIGHLIGHTS_EARLY_REPLAY_ONLY");
    BOOL replayOnly = replayOnlyValue != NULL && strcmp(replayOnlyValue, "1") == 0;
    return replayOnly
        ? CVLPEarlyLoaderRunReplayOnlyPath(targetUUID, mismatchUUID, failure)
        : CVLPEarlyLoaderRunNormalTimingPath(targetUUID, unrelatedUUID, mismatchUUID, failure);
#endif
}
