#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <limits.h>
#import <stdint.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdatomic.h>
#import "CVLPProbe.h"

#ifndef CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT
#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 0
#endif

#if CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT != 0 && CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT != 1
#error CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT must be 0 or 1
#endif

#ifndef CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT 0
#endif

#if CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT != 0 && CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT != 1
#error CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT must be 0 or 1
#endif

#if CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT && CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
#error Highlights viewing experiments are mutually exclusive
#endif

NS_ASSUME_NONNULL_BEGIN

@interface CVLPProbe (CVLPHighlightsDiagnosticSink)
+ (void)recordGuestDiagnostic:(NSString *)line;
@end

@interface CVLPHighlightsDiagnostics : NSObject
+ (void)start;
#if defined(CVLP_HIGHLIGHTS_TESTING)
+ (BOOL)runFixtureSelfTest:(NSString * _Nullable * _Nullable)failure;
#endif
@end

#if defined(CVLP_HIGHLIGHTS_TESTING)
BOOL CVLPHighlightsRunFixtureSelfTest(NSString * _Nullable * _Nullable failure);
#endif

enum {
    CVLPHighlightsViewingExperimentMode = CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT,
    CVLPHighlightsDirectViewingExperimentMode = CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT,
    CVLPHighlightsMaximumEvents = 26,
    CVLPHighlightsMaximumSamples = 24,
    CVLPHighlightsMaximumClasses = 100000,
    CVLPHighlightsMaximumTreeNodes = 1499,
    CVLPHighlightsMaximumTreeDepth = 23,
    CVLPHighlightsMaximumWindows = 3,
    CVLPHighlightsCountMaximum = 65535,
};
static const CFTimeInterval CVLPHighlightsDeadline = 120.0;
static const CFTimeInterval CVLPHighlightsClassScanDeadline = 0.5;
static const char CVLPHighlightsCellClassName[] = "_TtC25TikTokProfilePlatformImpl39ProfileStoryHighlightCollectionViewCell";

typedef NS_ENUM(int, CVLPHighlightsInstallStatus) {
    CVLPHighlightsInstallUnknown = 0,
    CVLPHighlightsInstallInstalled = 1,
    CVLPHighlightsInstallNotFound = 2,
    CVLPHighlightsInstallInherited = 3,
    CVLPHighlightsInstallWrongABI = 4,
    CVLPHighlightsInstallAmbiguous = 5,
    CVLPHighlightsInstallBoundedIncomplete = 6,
    CVLPHighlightsInstallFailed = 7,
};

typedef NS_ENUM(int, CVLPHighlightsStopReason) {
    CVLPHighlightsStopDeadline = 0,
    CVLPHighlightsStopBackground = 1,
    CVLPHighlightsStopSceneDeactivated = 2,
};

typedef NS_ENUM(int, CVLPHighlightsDirectInstallStatus) {
    CVLPHighlightsDirectDisabled = 0,
    CVLPHighlightsDirectInstalled = 1,
    CVLPHighlightsDirectUnsupportedArchitecture = 2,
    CVLPHighlightsDirectImageUnavailable = 3,
    CVLPHighlightsDirectMalformedImage = 4,
    CVLPHighlightsDirectPinMismatch = 5,
    CVLPHighlightsDirectSectionMismatch = 6,
    CVLPHighlightsDirectMappingRejected = 7,
    CVLPHighlightsDirectCodeMismatch = 8,
    CVLPHighlightsDirectConsumptionSlotMismatch = 9,
    CVLPHighlightsDirectCreationSlotMismatch = 10,
    CVLPHighlightsDirectCompareExchangeFailed = 11,
};

typedef NS_ENUM(int, CVLPHighlightsLookupReason) {
    CVLPHighlightsLookupReasonNone = 0,
    CVLPHighlightsLookupReasonMissingAnchor = 1,
    CVLPHighlightsLookupReasonMissingImage = 2,
    CVLPHighlightsLookupReasonImageAddressMismatch = 3,
    CVLPHighlightsLookupReasonClassLimit = 4,
    CVLPHighlightsLookupReasonDeadline = 5,
    CVLPHighlightsLookupReasonInvalidClass = 6,
    CVLPHighlightsLookupReasonClassImageMismatch = 7,
    CVLPHighlightsLookupReasonAmbiguous = 8,
    CVLPHighlightsLookupReasonAnchorNotEnumerated = 9,
};

typedef NS_ENUM(NSUInteger, CVLPHighlightsTarget) {
    CVLPHighlightsConsumptionTarget = 0,
    CVLPHighlightsCreationTarget = 1,
    CVLPHighlightsModelTarget = 2,
    CVLPHighlightsMountTarget = 3,
    CVLPHighlightsUpdateTarget = 4,
    CVLPHighlightsHeightTarget = 5,
    CVLPHighlightsTargetCount = 6,
};

typedef struct {
    uint16_t counts[CVLPHighlightsTargetCount];
    uint16_t overrideCalls;
    uint16_t directCalls;
    uint16_t directOverrideCalls;
    int directStatus;
    int lastConsumption;
    int lastCreation;
    int directLast;
    int lastModelPresence;
    int lastMount;
    int lastUpdate;
    double lastHeight;
} CVLPHighlightsHookState;

typedef struct {
    NSUInteger nodes;
    NSUInteger windows;
    NSUInteger rows;
    int hidden;
    double alpha;
    double width;
    double height;
    int truncated;
    int error;
} CVLPHighlightsTreeSummary;

static os_unfair_lock CVLPHighlightsStateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock CVLPHighlightsImplementationLock = OS_UNFAIR_LOCK_INIT;

// Publish the actual displaced implementation before a concurrent wrapper can
// enter it. Never hold this lock while executing guest code.
static BOOL CVLPHighlightsPublishForwarder(Method method, IMP replacement, IMP *slot) {
    os_unfair_lock_lock(&CVLPHighlightsImplementationLock);
    IMP displaced = method_setImplementation(method, replacement);
    if (displaced != NULL) { *slot = displaced; }
    os_unfair_lock_unlock(&CVLPHighlightsImplementationLock);
    return displaced != NULL;
}

static IMP CVLPHighlightsReadForwarder(IMP *slot) {
    int incomingErrno = errno;
    os_unfair_lock_lock(&CVLPHighlightsImplementationLock);
    IMP result = *slot;
    os_unfair_lock_unlock(&CVLPHighlightsImplementationLock);
    errno = incomingErrno;
    return result;
}

static CVLPHighlightsHookState CVLPHighlightsState = {
    .lastConsumption = -1,
    .lastCreation = -1,
    .directLast = -1,
    .lastModelPresence = -1,
    .lastMount = -1,
    .lastUpdate = -1,
    .lastHeight = -1.0,
};
static BOOL CVLPHighlightsRecording = NO;
static CFTimeInterval CVLPHighlightsStartedAt = 0.0;
static __strong id CVLPHighlightsSharedObserver;

#if CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT || defined(CVLP_HIGHLIGHTS_TESTING)
typedef BOOL (*CVLPHighlightsDirectGateFunction)(void);
_Static_assert(sizeof(uintptr_t) == sizeof(CVLPHighlightsDirectGateFunction),
    "Direct gate pointers must match arm64 pointer width.");

typedef struct {
    BOOL (*regionAllows)(uintptr_t address, size_t length, vm_prot_t required,
        vm_prot_t forbidden, void *context);
    BOOL (*read)(uintptr_t address, void *destination, size_t length, void *context);
    BOOL (*compareExchange)(uintptr_t address, uintptr_t expected, uintptr_t replacement, void *context);
    void *context;
} CVLPHighlightsDirectMemory;

typedef struct {
    uint64_t textVMAddress;
    uint64_t textVMSize;
    uint64_t dataVMAddress;
    uint64_t dataVMSize;
    uint64_t classRefsAddress;
    uint64_t classRefsSize;
    uint64_t executableVMAddress;
    uint64_t executableVMSize;
} CVLPHighlightsDirectImagePin;

static _Atomic(uintptr_t) CVLPHighlightsDirectOriginalAddress = 0;
static CVLPHighlightsDirectInstallStatus CVLPHighlightsDirectValidateAndInstall(
    uintptr_t imageBase, const CVLPHighlightsDirectMemory *memory);
static BOOL CVLPHighlightsDirectRunFixture(NSString **failure);
#endif

@class CVLPHighlightsObserver;
static CVLPHighlightsTreeSummary CVLPHighlightsSampleTreeSafely(void);
static void CVLPHighlightsStoreLastTree(CVLPHighlightsObserver *observer, CVLPHighlightsTreeSummary tree);
static CVLPHighlightsTreeSummary CVLPHighlightsObserverLastTree(CVLPHighlightsObserver *observer);

static uint16_t CVLPHighlightsSaturatingIncrement(uint16_t value) {
    return value < CVLPHighlightsCountMaximum ? (uint16_t)(value + 1) : value;
}

static BOOL CVLPHighlightsShouldOverrideConsumption(CVLPHighlightsTarget target, SEL selector) {
#if CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT
    return target == CVLPHighlightsConsumptionTarget &&
        selector == sel_registerName("enableStoryHighlightConsumption");
#else
    (void)target;
    (void)selector;
    return NO;
#endif
}

static void CVLPHighlightsRecordOverrideInvocation(void) {
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    if (CVLPHighlightsRecording && CACurrentMediaTime() - CVLPHighlightsStartedAt >= CVLPHighlightsDeadline) {
        CVLPHighlightsRecording = NO;
    }
    if (CVLPHighlightsRecording) {
        CVLPHighlightsState.overrideCalls = CVLPHighlightsSaturatingIncrement(CVLPHighlightsState.overrideCalls);
    }
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
}

static void CVLPHighlightsRecordInvocation(CVLPHighlightsTarget target, int valueKind, int integerValue, double doubleValue) {
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    if (CVLPHighlightsRecording && CACurrentMediaTime() - CVLPHighlightsStartedAt >= CVLPHighlightsDeadline) {
        CVLPHighlightsRecording = NO;
    }
    if (CVLPHighlightsRecording) {
        CVLPHighlightsState.counts[target] = CVLPHighlightsSaturatingIncrement(CVLPHighlightsState.counts[target]);
        switch (target) {
            case CVLPHighlightsConsumptionTarget:
                if (valueKind != 0) { CVLPHighlightsState.lastConsumption = integerValue; }
                break;
            case CVLPHighlightsCreationTarget:
                if (valueKind != 0) { CVLPHighlightsState.lastCreation = integerValue; }
                break;
            case CVLPHighlightsModelTarget:
                if (valueKind != 0) { CVLPHighlightsState.lastModelPresence = integerValue; }
                break;
            case CVLPHighlightsMountTarget:
                break;
            case CVLPHighlightsUpdateTarget:
                break;
            case CVLPHighlightsHeightTarget:
                if (valueKind == 2 && isfinite(doubleValue)) { CVLPHighlightsState.lastHeight = doubleValue; }
                break;
            case CVLPHighlightsTargetCount:
                break;
        }
    }
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
}

#if CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT || defined(CVLP_HIGHLIGHTS_TESTING)
static const uint8_t CVLPHighlightsDirectExpectedUUID[16] = {
    0xe9, 0x94, 0xf2, 0xc7, 0x83, 0x49, 0x3e, 0x53,
    0x92, 0xef, 0xd2, 0x1c, 0x10, 0xde, 0xd9, 0xfc,
};
static const uint8_t CVLPHighlightsDirectExpectedStub[12] = {
    0xd1, 0x71, 0xee, 0x90, 0x31, 0x62, 0x42, 0xf9,
    0x20, 0x02, 0x1f, 0xd6,
};
static const uint8_t CVLPHighlightsDirectExpectedGetter[28] = {
    0x41, 0x8d, 0xef, 0xf0, 0x21, 0x80, 0x10, 0x91,
    0x40, 0x8d, 0xef, 0x90, 0x00, 0x40, 0x17, 0x91,
    0x63, 0x00, 0x00, 0x10, 0x1f, 0x20, 0x03, 0xd5,
    0xbf, 0xaf, 0xd8, 0x17,
};
static const uint64_t CVLPHighlightsDirectDataVM = 0x01804000ULL;
static const uint64_t CVLPHighlightsDirectDataVMSize = 0x0cdac000ULL;
static const uint64_t CVLPHighlightsDirectDataFileSize = 0x02b14000ULL;
static const uint64_t CVLPHighlightsDirectClassRefsVM = 0x03a00378ULL;
static const uint64_t CVLPHighlightsDirectClassRefsSize = 0x002f2db8ULL;
static const uint64_t CVLPHighlightsDirectExecutableVM = 0x0e5b0000ULL;
static const uint64_t CVLPHighlightsDirectExecutableVMSize = 0x196e0000ULL;
static const uint64_t CVLPHighlightsDirectTextVMSize = 0x01804000ULL;
static const uint64_t CVLPHighlightsDirectConsumptionSlotVM = 0x03c2c4c0ULL;
static const uint64_t CVLPHighlightsDirectCreationSlotVM = 0x03c2c4b8ULL;
static const uint64_t CVLPHighlightsDirectStubVM = 0x26df44a0ULL;
static const uint64_t CVLPHighlightsDirectConsumptionVM = 0x26df44acULL;
static const uint64_t CVLPHighlightsDirectCreationVM = 0x27002868ULL;
static const uint32_t CVLPHighlightsDirectExpectedCommandCount = 182;
static const uint32_t CVLPHighlightsDirectExpectedCommandBytes = 24664;

static BOOL CVLPHighlightsDirectRangeContains(uint64_t start, uint64_t size, uint64_t address, uint64_t length) {
    return address >= start && length <= size && address - start <= size - length;
}

static BOOL CVLPHighlightsDirectNameEquals(const char name[16], const char *expected) {
    size_t length = strlen(expected);
    return length < 16 && memcmp(name, expected, length) == 0 && name[length] == '\0';
}

static CVLPHighlightsDirectInstallStatus CVLPHighlightsDirectParseImage(
    const void *bytes, size_t length, CVLPHighlightsDirectImagePin *pin) {
    if (bytes == NULL || pin == NULL || length < sizeof(struct mach_header_64)) {
        return CVLPHighlightsDirectMalformedImage;
    }
    struct mach_header_64 header;
    memcpy(&header, bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64) { return CVLPHighlightsDirectMalformedImage; }
    if (header.cputype != CPU_TYPE_ARM64 || header.cpusubtype != CPU_SUBTYPE_ARM64_ALL) {
        return CVLPHighlightsDirectUnsupportedArchitecture;
    }
    if (header.filetype != MH_DYLIB) { return CVLPHighlightsDirectPinMismatch; }
    if (header.ncmds != CVLPHighlightsDirectExpectedCommandCount ||
        header.sizeofcmds != CVLPHighlightsDirectExpectedCommandBytes ||
        length < sizeof(header) + (size_t)header.sizeofcmds) {
        return CVLPHighlightsDirectPinMismatch;
    }

    BOOL hasUUID = NO;
    BOOL hasText = NO;
    BOOL hasData = NO;
    BOOL hasExecutable = NO;
    BOOL hasClassRefs = NO;
    memset(pin, 0, sizeof(*pin));
    const uint8_t *cursor = (const uint8_t *)bytes + sizeof(header);
    size_t remaining = header.sizeofcmds;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (remaining < sizeof(struct load_command)) { return CVLPHighlightsDirectMalformedImage; }
        struct load_command command;
        memcpy(&command, cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) {
            return CVLPHighlightsDirectMalformedImage;
        }
        if (command.cmd == LC_UUID) {
            if (command.cmdsize < sizeof(struct uuid_command) || hasUUID) {
                return CVLPHighlightsDirectMalformedImage;
            }
            struct uuid_command uuid;
            memcpy(&uuid, cursor, sizeof(uuid));
            hasUUID = YES;
            if (memcmp(uuid.uuid, CVLPHighlightsDirectExpectedUUID, sizeof(uuid.uuid)) != 0) {
                return CVLPHighlightsDirectPinMismatch;
            }
        } else if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) {
                return CVLPHighlightsDirectMalformedImage;
            }
            struct segment_command_64 segment;
            memcpy(&segment, cursor, sizeof(segment));
            if (segment.nsects > SIZE_MAX / sizeof(struct section_64)) {
                return CVLPHighlightsDirectMalformedImage;
            }
            size_t sectionBytes = (size_t)segment.nsects * sizeof(struct section_64);
            if (sectionBytes > command.cmdsize - sizeof(segment)) {
                return CVLPHighlightsDirectMalformedImage;
            }
            if (CVLPHighlightsDirectNameEquals(segment.segname, "__TEXT")) {
                if (hasText || segment.vmaddr != 0 || segment.fileoff != 0 ||
                    segment.vmsize != CVLPHighlightsDirectTextVMSize ||
                    segment.initprot != (VM_PROT_READ | VM_PROT_EXECUTE) ||
                    segment.maxprot != (VM_PROT_READ | VM_PROT_EXECUTE) ||
                    !CVLPHighlightsDirectRangeContains(segment.vmaddr, segment.vmsize,
                        0, sizeof(header) + header.sizeofcmds) ||
                    segment.filesize < sizeof(header) + header.sizeofcmds) {
                    return CVLPHighlightsDirectPinMismatch;
                }
                hasText = YES;
                pin->textVMAddress = segment.vmaddr;
                pin->textVMSize = segment.vmsize;
            } else if (CVLPHighlightsDirectNameEquals(segment.segname, "__DATA")) {
                if (hasData || segment.vmaddr != CVLPHighlightsDirectDataVM ||
                    segment.vmsize != CVLPHighlightsDirectDataVMSize ||
                    segment.filesize != CVLPHighlightsDirectDataFileSize ||
                    segment.initprot != (VM_PROT_READ | VM_PROT_WRITE) ||
                    segment.maxprot != (VM_PROT_READ | VM_PROT_WRITE)) {
                    return CVLPHighlightsDirectPinMismatch;
                }
                hasData = YES;
                const struct section_64 *sections = (const struct section_64 *)(cursor + sizeof(segment));
                for (uint32_t sectionIndex = 0; sectionIndex < segment.nsects; sectionIndex++) {
                    struct section_64 section;
                    memcpy(&section, &sections[sectionIndex], sizeof(section));
                    if (CVLPHighlightsDirectNameEquals(section.sectname, "__objc_clsrefs")) {
                        if (hasClassRefs || !CVLPHighlightsDirectNameEquals(section.segname, "__DATA") ||
                            section.addr != CVLPHighlightsDirectClassRefsVM ||
                            section.size != CVLPHighlightsDirectClassRefsSize) {
                            return CVLPHighlightsDirectSectionMismatch;
                        }
                        hasClassRefs = YES;
                        pin->classRefsAddress = section.addr;
                        pin->classRefsSize = section.size;
                    }
                }
                pin->dataVMAddress = segment.vmaddr;
                pin->dataVMSize = segment.vmsize;
            } else if (CVLPHighlightsDirectNameEquals(segment.segname, "__BD_TEXT")) {
                if (hasExecutable || segment.vmaddr != CVLPHighlightsDirectExecutableVM ||
                    segment.vmsize != CVLPHighlightsDirectExecutableVMSize ||
                    segment.initprot != (VM_PROT_READ | VM_PROT_EXECUTE) ||
                    segment.maxprot != (VM_PROT_READ | VM_PROT_EXECUTE)) {
                    return CVLPHighlightsDirectPinMismatch;
                }
                hasExecutable = YES;
                pin->executableVMAddress = segment.vmaddr;
                pin->executableVMSize = segment.vmsize;
            }
        }
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
    if (remaining != 0 || !hasUUID || !hasText || !hasData || !hasExecutable) {
        return CVLPHighlightsDirectPinMismatch;
    }
    if (!hasClassRefs ||
        !CVLPHighlightsDirectRangeContains(pin->dataVMAddress, pin->dataVMSize,
            pin->classRefsAddress, pin->classRefsSize) ||
        !CVLPHighlightsDirectRangeContains(pin->classRefsAddress, pin->classRefsSize,
            CVLPHighlightsDirectConsumptionSlotVM, sizeof(uintptr_t)) ||
        !CVLPHighlightsDirectRangeContains(pin->classRefsAddress, pin->classRefsSize,
            CVLPHighlightsDirectCreationSlotVM, sizeof(uintptr_t)) ||
        !CVLPHighlightsDirectRangeContains(pin->executableVMAddress, pin->executableVMSize,
            CVLPHighlightsDirectStubVM, sizeof(CVLPHighlightsDirectExpectedStub)) ||
        !CVLPHighlightsDirectRangeContains(pin->executableVMAddress, pin->executableVMSize,
            CVLPHighlightsDirectConsumptionVM, sizeof(CVLPHighlightsDirectExpectedGetter)) ||
        !CVLPHighlightsDirectRangeContains(pin->executableVMAddress, pin->executableVMSize,
            CVLPHighlightsDirectCreationVM, 1)) {
        return CVLPHighlightsDirectSectionMismatch;
    }
    return CVLPHighlightsDirectInstalled;
}

static BOOL CVLPHighlightsDirectAddress(uintptr_t base, uint64_t vmAddress, uintptr_t *result) {
    if (result == NULL || vmAddress > UINTPTR_MAX || base > UINTPTR_MAX - (uintptr_t)vmAddress) { return NO; }
    *result = base + (uintptr_t)vmAddress;
    return YES;
}

static BOOL CVLPHighlightsDirectReplacement(void) {
#if !CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
    return NO;
#else
    uintptr_t address = atomic_load_explicit(&CVLPHighlightsDirectOriginalAddress, memory_order_acquire);
    if (address == 0) { return NO; }
    CVLPHighlightsDirectGateFunction original = NULL;
    memcpy(&original, &address, sizeof(original));
    int incomingErrno = errno;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    if (CVLPHighlightsRecording && CACurrentMediaTime() - CVLPHighlightsStartedAt >= CVLPHighlightsDeadline) {
        CVLPHighlightsRecording = NO;
    }
    if (CVLPHighlightsRecording) {
        CVLPHighlightsState.directCalls = CVLPHighlightsSaturatingIncrement(CVLPHighlightsState.directCalls);
    }
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    errno = incomingErrno;
    BOOL naturalResult = original();
    int originalErrno = errno;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    if (CVLPHighlightsRecording && CACurrentMediaTime() - CVLPHighlightsStartedAt >= CVLPHighlightsDeadline) {
        CVLPHighlightsRecording = NO;
    }
    if (CVLPHighlightsRecording) {
        CVLPHighlightsState.directOverrideCalls = CVLPHighlightsSaturatingIncrement(CVLPHighlightsState.directOverrideCalls);
        CVLPHighlightsState.directLast = naturalResult ? 1 : 0;
    }
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    errno = originalErrno;
    return YES;
#endif
}

static CVLPHighlightsDirectInstallStatus CVLPHighlightsDirectValidateAndInstall(
    uintptr_t imageBase, const CVLPHighlightsDirectMemory *memory) {
#if !CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
    (void)imageBase;
    (void)memory;
    return CVLPHighlightsDirectDisabled;
#else
    if (imageBase == 0 || memory == NULL || memory->regionAllows == NULL ||
        memory->read == NULL || memory->compareExchange == NULL) {
        return CVLPHighlightsDirectImageUnavailable;
    }
    if ((imageBase & (sizeof(uintptr_t) - 1)) != 0) { return CVLPHighlightsDirectSectionMismatch; }
    struct mach_header_64 shortHeader;
    if (!memory->regionAllows(imageBase, sizeof(shortHeader), VM_PROT_READ, VM_PROT_WRITE, memory->context) ||
        !memory->read(imageBase, &shortHeader, sizeof(shortHeader), memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    if (shortHeader.magic != MH_MAGIC_64) { return CVLPHighlightsDirectMalformedImage; }
    if (shortHeader.cputype != CPU_TYPE_ARM64 || shortHeader.cpusubtype != CPU_SUBTYPE_ARM64_ALL) {
        return CVLPHighlightsDirectUnsupportedArchitecture;
    }
    if (shortHeader.ncmds != CVLPHighlightsDirectExpectedCommandCount ||
        shortHeader.sizeofcmds != CVLPHighlightsDirectExpectedCommandBytes) {
        return CVLPHighlightsDirectPinMismatch;
    }
    size_t imageBytesLength = sizeof(shortHeader) + (size_t)shortHeader.sizeofcmds;
    if (!memory->regionAllows(imageBase, imageBytesLength, VM_PROT_READ, VM_PROT_WRITE, memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    uint8_t *imageBytes = malloc(imageBytesLength);
    if (imageBytes == NULL) { return CVLPHighlightsDirectMalformedImage; }
    BOOL imageRead = memory->read(imageBase, imageBytes, imageBytesLength, memory->context);
    if (!imageRead) {
        free(imageBytes);
        return CVLPHighlightsDirectMappingRejected;
    }
    CVLPHighlightsDirectImagePin pin;
    CVLPHighlightsDirectInstallStatus status = CVLPHighlightsDirectParseImage(imageBytes, imageBytesLength, &pin);
    free(imageBytes);
    if (status != CVLPHighlightsDirectInstalled) { return status; }

    uintptr_t consumptionSlot = 0;
    uintptr_t creationSlot = 0;
    uintptr_t stubAddress = 0;
    uintptr_t consumptionAddress = 0;
    uintptr_t creationAddress = 0;
    if (!CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectConsumptionSlotVM, &consumptionSlot) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectCreationSlotVM, &creationSlot) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectStubVM, &stubAddress) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectConsumptionVM, &consumptionAddress) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectCreationVM, &creationAddress)) {
        return CVLPHighlightsDirectSectionMismatch;
    }
    if ((consumptionSlot & (sizeof(uintptr_t) - 1)) != 0 ||
        (creationSlot & (sizeof(uintptr_t) - 1)) != 0) {
        return CVLPHighlightsDirectSectionMismatch;
    }
    uintptr_t pageSize = vm_page_size;
    if (pageSize == 0 || (pageSize & (pageSize - 1)) != 0 ||
        (consumptionSlot & ~(pageSize - 1)) != (creationSlot & ~(pageSize - 1))) {
        return CVLPHighlightsDirectSectionMismatch;
    }
    uintptr_t slotPage = consumptionSlot & ~(pageSize - 1);
    if (slotPage < imageBase ||
        !CVLPHighlightsDirectRangeContains(pin.dataVMAddress, pin.dataVMSize,
            (uint64_t)(slotPage - imageBase), pageSize) ||
        !memory->regionAllows(slotPage, pageSize, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_EXECUTE, memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    if (!CVLPHighlightsDirectRangeContains(pin.executableVMAddress, pin.executableVMSize,
            (uint64_t)(stubAddress - imageBase), sizeof(CVLPHighlightsDirectExpectedStub)) ||
        !CVLPHighlightsDirectRangeContains(pin.executableVMAddress, pin.executableVMSize,
            (uint64_t)(consumptionAddress - imageBase), sizeof(CVLPHighlightsDirectExpectedGetter)) ||
        !memory->regionAllows(stubAddress, sizeof(CVLPHighlightsDirectExpectedStub),
            VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE, memory->context) ||
        !memory->regionAllows(consumptionAddress, sizeof(CVLPHighlightsDirectExpectedGetter),
            VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE, memory->context) ||
        !memory->regionAllows(creationAddress, 1, VM_PROT_READ | VM_PROT_EXECUTE,
            VM_PROT_WRITE, memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    uint8_t actualStub[sizeof(CVLPHighlightsDirectExpectedStub)];
    uint8_t actualGetter[sizeof(CVLPHighlightsDirectExpectedGetter)];
    if (!memory->read(stubAddress, actualStub, sizeof(actualStub), memory->context) ||
        !memory->read(consumptionAddress, actualGetter, sizeof(actualGetter), memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    if (memcmp(actualStub, CVLPHighlightsDirectExpectedStub, sizeof(actualStub)) != 0 ||
        memcmp(actualGetter, CVLPHighlightsDirectExpectedGetter, sizeof(actualGetter)) != 0) {
        return CVLPHighlightsDirectCodeMismatch;
    }

    uintptr_t actualConsumption = 0;
    uintptr_t actualCreation = 0;
    if (!memory->read(consumptionSlot, &actualConsumption, sizeof(actualConsumption), memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    if (!memory->read(creationSlot, &actualCreation, sizeof(actualCreation), memory->context)) {
        return CVLPHighlightsDirectMappingRejected;
    }
    uintptr_t expectedConsumption = 0;
    uintptr_t expectedCreation = 0;
    if (!CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectConsumptionVM, &expectedConsumption) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPHighlightsDirectCreationVM, &expectedCreation)) {
        return CVLPHighlightsDirectSectionMismatch;
    }
    if (actualConsumption != expectedConsumption) { return CVLPHighlightsDirectConsumptionSlotMismatch; }
    if (actualCreation != expectedCreation) { return CVLPHighlightsDirectCreationSlotMismatch; }

    CVLPHighlightsDirectGateFunction replacementFunction = &CVLPHighlightsDirectReplacement;
    uintptr_t replacementAddress = 0;
    memcpy(&replacementAddress, &replacementFunction, sizeof(replacementAddress));
    atomic_store_explicit(&CVLPHighlightsDirectOriginalAddress, actualConsumption, memory_order_release);
    if (!memory->compareExchange(consumptionSlot, actualConsumption, replacementAddress, memory->context)) {
        return CVLPHighlightsDirectCompareExchangeFailed;
    }
    return CVLPHighlightsDirectInstalled;
#endif
}

static BOOL CVLPHighlightsDirectMachRegionAllows(uintptr_t address, size_t length,
    vm_prot_t required, vm_prot_t forbidden, __unused void *context) {
    if (length == 0 || address > UINTPTR_MAX - length) { return NO; }
    _Static_assert(sizeof(vm_address_t) == sizeof(uintptr_t), "VM address must preserve native pointers");
    vm_address_t regionAddress = (vm_address_t)address;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t information = {0};
    mach_msg_type_number_t informationCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &regionAddress, &regionSize,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&information, &informationCount, &objectName);
    if (objectName != MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(), objectName); }
    if (result != KERN_SUCCESS || address < regionAddress ||
        address - regionAddress > regionSize || length > regionSize - (address - regionAddress)) {
        return NO;
    }
    return (information.protection & required) == required &&
        (information.protection & forbidden) == 0;
}

static BOOL CVLPHighlightsDirectMachRead(uintptr_t address, void *destination,
    size_t length, __unused void *context) {
    if (destination == NULL || length == 0) { return NO; }
    _Static_assert(sizeof(vm_size_t) == sizeof(size_t), "VM size must preserve native lengths");
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
        (vm_size_t)length, (vm_address_t)(uintptr_t)destination, &copied);
    return result == KERN_SUCCESS && copied == length;
}

static BOOL CVLPHighlightsDirectMachCompareExchange(uintptr_t address, uintptr_t expected,
    uintptr_t replacement, __unused void *context) {
    uintptr_t *slot = (uintptr_t *)address;
    return __atomic_compare_exchange_n(slot, &expected, replacement, false,
        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

static CVLPHighlightsDirectInstallStatus CVLPHighlightsDirectInstallForAnchor(Class anchor) {
#if !defined(__arm64__) || defined(__arm64e__)
    (void)anchor;
    return CVLPHighlightsDirectUnsupportedArchitecture;
#else
    if (anchor == Nil) { return CVLPHighlightsDirectImageUnavailable; }
    const char *anchorImage = class_getImageName(anchor);
    Dl_info imageInfo = {0};
    if (anchorImage == NULL || anchorImage[0] == '\0' ||
        !dladdr((__bridge const void *)anchor, &imageInfo) || imageInfo.dli_fbase == NULL ||
        imageInfo.dli_fname == NULL || strcmp(anchorImage, imageInfo.dli_fname) != 0) {
        return CVLPHighlightsDirectImageUnavailable;
    }
    CVLPHighlightsDirectMemory memory = {
        .regionAllows = CVLPHighlightsDirectMachRegionAllows,
        .read = CVLPHighlightsDirectMachRead,
        .compareExchange = CVLPHighlightsDirectMachCompareExchange,
        .context = NULL,
    };
    return CVLPHighlightsDirectValidateAndInstall((uintptr_t)imageInfo.dli_fbase, &memory);
#endif
}
#endif

static BOOL CVLPHighlightsMethodHasExactSignature(Method method, const char *returnEncoding) {
    if (method == NULL || method_getNumberOfArguments(method) != 2) { return NO; }
    char *returnType = method_copyReturnType(method);
    char *selfType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    BOOL matches = returnType != NULL && selfType != NULL && selectorType != NULL &&
        strcmp(returnType, returnEncoding) == 0 && strcmp(selfType, "@") == 0 && strcmp(selectorType, ":") == 0;
    free(returnType);
    free(selfType);
    free(selectorType);
    return matches;
}

// Do not query class_getInstanceMethod/class_getClassMethod for missing methods:
// those APIs can invoke a guest's dynamic method resolver. Enumerate declarations.
static Method _Nullable CVLPHighlightsDeclaredMethod(Class cls, SEL selector, NSUInteger *matches) {
    *matches = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method selected = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            (*matches)++;
            selected = methods[index];
        }
    }
    free(methods);
    return *matches == 1 ? selected : NULL;
}

static Method _Nullable CVLPHighlightsOwnInstanceMethod(Class _Nullable cls, SEL selector,
    CVLPHighlightsInstallStatus *failureStatus) {
    *failureStatus = CVLPHighlightsInstallNotFound;
    if (cls == Nil) { return NULL; }
    NSUInteger matches = 0;
    Method method = CVLPHighlightsDeclaredMethod(cls, selector, &matches);
    if (matches > 1) { *failureStatus = CVLPHighlightsInstallAmbiguous; return NULL; }
    if (method != NULL) { return method; }
    Class ancestor = class_getSuperclass(cls);
    for (NSUInteger depth = 0; ancestor != Nil && depth < 64; depth++) {
        (void)CVLPHighlightsDeclaredMethod(ancestor, selector, &matches);
        if (matches != 0) { *failureStatus = CVLPHighlightsInstallInherited; return NULL; }
        ancestor = class_getSuperclass(ancestor);
    }
    if (ancestor != Nil) { *failureStatus = CVLPHighlightsInstallBoundedIncomplete; }
    return NULL;
}

typedef struct {
    Class owner;
    Method method;
    NSUInteger matches;
    NSUInteger classes;
    BOOL complete;
    BOOL anchorSeen;
    CVLPHighlightsLookupReason reason;
    SEL selector;
    Class anchor;
    const char *anchorImage;
    CFTimeInterval startedAt;
    CFTimeInterval (*clock)(void *context);
    const char *(*imageName)(Class cls, void *context);
    void *context;
} CVLPHighlightsClassMethodSearch;

static CFTimeInterval CVLPHighlightsRuntimeClock(__unused void *context) {
    return CACurrentMediaTime();
}

static const char *CVLPHighlightsRuntimeImageName(Class cls, __unused void *context) {
    return class_getImageName(cls);
}

static CVLPHighlightsClassMethodSearch CVLPHighlightsClassSearchCreate(
    SEL selector, Class anchor, const char *anchorImage, CFTimeInterval startedAt,
    CFTimeInterval (*clock)(void *), const char *(*imageName)(Class, void *), void *context) {
    CVLPHighlightsClassMethodSearch search = {0};
    search.selector = selector;
    search.anchor = anchor;
    search.anchorImage = anchorImage;
    search.startedAt = startedAt;
    search.clock = clock;
    search.imageName = imageName;
    search.context = context;
    if (anchor == Nil) {
        search.reason = CVLPHighlightsLookupReasonMissingAnchor;
    } else if (anchorImage == NULL || anchorImage[0] == '\0') {
        search.reason = CVLPHighlightsLookupReasonMissingImage;
    } else if (clock == NULL || imageName == NULL) {
        search.reason = CVLPHighlightsLookupReasonMissingImage;
    }
    return search;
}

// The same per-class accumulator is used by the image iterator and the
// deterministic fixture. Runtime metadata calls may realize classes and may
// allocate internally; elapsed time is checked on both sides of each method
// list copy, but those runtime calls cannot be interrupted.
static BOOL CVLPHighlightsClassSearchObserve(CVLPHighlightsClassMethodSearch *search, Class cls) {
    if (search == NULL || search->reason != CVLPHighlightsLookupReasonNone) { return NO; }
    if (search->clock(search->context) - search->startedAt >= CVLPHighlightsClassScanDeadline) {
        search->reason = CVLPHighlightsLookupReasonDeadline;
        return NO;
    }
    if (search->classes >= CVLPHighlightsMaximumClasses) {
        search->classes = CVLPHighlightsMaximumClasses;
        search->reason = CVLPHighlightsLookupReasonClassLimit;
        return NO;
    }
    search->classes++;
    if (cls == Nil) {
        search->reason = CVLPHighlightsLookupReasonInvalidClass;
        return NO;
    }
    if (cls == search->anchor) { search->anchorSeen = YES; }
    const char *candidateImage = search->imageName(cls, search->context);
    if (candidateImage == NULL || strcmp(candidateImage, search->anchorImage) != 0) {
        search->reason = CVLPHighlightsLookupReasonClassImageMismatch;
        return NO;
    }

    CFTimeInterval beforeMethodList = search->clock(search->context);
    if (beforeMethodList - search->startedAt >= CVLPHighlightsClassScanDeadline) {
        search->reason = CVLPHighlightsLookupReasonDeadline;
        return NO;
    }
    NSUInteger ownMatches = 0;
    Method method = CVLPHighlightsDeclaredMethod(object_getClass(cls), search->selector, &ownMatches);
    CFTimeInterval afterMethodList = search->clock(search->context);
    if (afterMethodList - search->startedAt >= CVLPHighlightsClassScanDeadline) {
        search->reason = CVLPHighlightsLookupReasonDeadline;
        return NO;
    }
    if (ownMatches > 1) {
        search->reason = CVLPHighlightsLookupReasonAmbiguous;
        search->matches += ownMatches;
        return NO;
    }
    if (ownMatches == 1) {
        search->matches++;
        if (search->matches == 1) {
            search->owner = cls;
            search->method = method;
        } else {
            search->owner = Nil;
            search->method = NULL;
            search->reason = CVLPHighlightsLookupReasonAmbiguous;
            return NO;
        }
    }
    return YES;
}

static CVLPHighlightsClassMethodSearch CVLPHighlightsClassSearchFinish(
    CVLPHighlightsClassMethodSearch search) {
    if (search.reason != CVLPHighlightsLookupReasonNone) { return search; }
    if (search.clock(search.context) - search.startedAt >= CVLPHighlightsClassScanDeadline) {
        search.reason = CVLPHighlightsLookupReasonDeadline;
        return search;
    }
    if (!search.anchorSeen) {
        search.reason = CVLPHighlightsLookupReasonAnchorNotEnumerated;
        return search;
    }
    search.complete = YES;
    return search;
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPHighlightsClassMethodSearch CVLPHighlightsSearchProvidedClasses(
    SEL selector, Class anchor, const char *anchorImage, Class const *classes, NSUInteger count,
    CFTimeInterval startedAt, CFTimeInterval (*clock)(void *),
    const char *(*imageName)(Class, void *), void *context) {
    CVLPHighlightsClassMethodSearch search = CVLPHighlightsClassSearchCreate(
        selector, anchor, anchorImage, startedAt, clock, imageName, context);
    if (search.reason != CVLPHighlightsLookupReasonNone) { return search; }
    if (count > CVLPHighlightsMaximumClasses) {
        search.classes = CVLPHighlightsMaximumClasses;
        search.reason = CVLPHighlightsLookupReasonClassLimit;
        return search;
    }
    if (count > 0 && classes == NULL) {
        search.reason = CVLPHighlightsLookupReasonInvalidClass;
        return search;
    }
    for (NSUInteger index = 0; index < count; index++) {
        if (!CVLPHighlightsClassSearchObserve(&search, classes[index])) { return search; }
    }
    return CVLPHighlightsClassSearchFinish(search);
}
#endif

static CVLPHighlightsClassMethodSearch CVLPHighlightsFindClassMethod(SEL selector, Class anchor) {
    CFTimeInterval startedAt = CACurrentMediaTime();
    const char *anchorImage = anchor == Nil ? NULL : class_getImageName(anchor);
    __block CVLPHighlightsClassMethodSearch search = CVLPHighlightsClassSearchCreate(
        selector, anchor, anchorImage, startedAt, CVLPHighlightsRuntimeClock,
        CVLPHighlightsRuntimeImageName, NULL);
    if (search.reason != CVLPHighlightsLookupReasonNone) { return search; }

    Dl_info imageInfo = {0};
    if (dladdr((__bridge const void *)anchor, &imageInfo) == 0 ||
        imageInfo.dli_fbase == NULL || imageInfo.dli_fname == NULL) {
        search.reason = CVLPHighlightsLookupReasonMissingImage;
        return search;
    }
    if (strcmp(anchorImage, imageInfo.dli_fname) != 0) {
        search.reason = CVLPHighlightsLookupReasonImageAddressMismatch;
        return search;
    }
    if (CACurrentMediaTime() - startedAt >= CVLPHighlightsClassScanDeadline) {
        search.reason = CVLPHighlightsLookupReasonDeadline;
        return search;
    }

    // objc_enumerateClasses is image-scoped and does not copy a process-wide
    // class array. It may do runtime work between callbacks, so the deadline
    // is best-effort around each callback and at completion, not preemptive.
    objc_enumerateClasses(imageInfo.dli_fbase, NULL, NULL, Nil, ^(__unused Class cls, BOOL *stop) {
        if (!CVLPHighlightsClassSearchObserve(&search, cls)) { *stop = YES; }
    });
    return CVLPHighlightsClassSearchFinish(search);
}

static CVLPHighlightsInstallStatus CVLPHighlightsInstallClassBoolean(
    SEL selector, CVLPHighlightsTarget target, Class anchor,
    CVLPHighlightsClassMethodSearch *searchDetails) {
    CVLPHighlightsClassMethodSearch search = CVLPHighlightsFindClassMethod(selector, anchor);
    if (searchDetails != NULL) { *searchDetails = search; }
    if (search.reason == CVLPHighlightsLookupReasonAmbiguous) { return CVLPHighlightsInstallAmbiguous; }
    if (!search.complete) { return CVLPHighlightsInstallBoundedIncomplete; }
    if (search.matches == 0) { return CVLPHighlightsInstallNotFound; }
    if (search.method == NULL || search.owner == Nil) { return CVLPHighlightsInstallFailed; }
    if (!CVLPHighlightsMethodHasExactSignature(search.method, "B")) { return CVLPHighlightsInstallWrongABI; }

    __block IMP original = method_getImplementation(search.method);
    if (original == NULL) { return CVLPHighlightsInstallFailed; }
    SEL exactSelector = selector;
    id block = ^BOOL(__unsafe_unretained id receiver) {
        IMP invocation = CVLPHighlightsReadForwarder(&original);
        BOOL naturalResult = ((BOOL (*)(id, SEL))invocation)((id)receiver, exactSelector);
        int originalErrno = errno;
        CVLPHighlightsRecordInvocation(target, 1, naturalResult ? 1 : 0, 0.0);
        BOOL deliveredResult = naturalResult;
        if (CVLPHighlightsShouldOverrideConsumption(target, exactSelector)) {
            CVLPHighlightsRecordOverrideInvocation();
            deliveredResult = YES;
        }
        errno = originalErrno;
        return deliveredResult;
    };
    IMP replacement = imp_implementationWithBlock(block);
    if (replacement == NULL) { return CVLPHighlightsInstallFailed; }
    return CVLPHighlightsPublishForwarder(search.method, replacement, &original)
        ? CVLPHighlightsInstallInstalled : CVLPHighlightsInstallFailed;
}

static CVLPHighlightsInstallStatus CVLPHighlightsInstallInstance(Class cls, SEL selector, const char *returnEncoding,
    CVLPHighlightsTarget target) {
    if (cls == Nil) { return CVLPHighlightsInstallNotFound; }
    CVLPHighlightsInstallStatus lookupFailure = CVLPHighlightsInstallNotFound;
    Method method = CVLPHighlightsOwnInstanceMethod(cls, selector, &lookupFailure);
    if (method == NULL) { return lookupFailure; }
    if (!CVLPHighlightsMethodHasExactSignature(method, returnEncoding)) { return CVLPHighlightsInstallWrongABI; }

    __block IMP original = method_getImplementation(method);
    if (original == NULL) { return CVLPHighlightsInstallFailed; }
    SEL exactSelector = selector;
    IMP replacement = NULL;
    switch (target) {
        case CVLPHighlightsModelTarget: {
            id block = ^id(__unsafe_unretained id receiver) {
                IMP invocation = CVLPHighlightsReadForwarder(&original);
                id result = ((id (*)(id, SEL))invocation)((id)receiver, exactSelector);
                int originalErrno = errno;
                CVLPHighlightsRecordInvocation(CVLPHighlightsModelTarget, 1, result != nil ? 1 : 0, 0.0);
                errno = originalErrno;
                return result;
            };
            replacement = imp_implementationWithBlock(block);
            break;
        }
        case CVLPHighlightsMountTarget:
        case CVLPHighlightsUpdateTarget: {
            id block = ^(__unsafe_unretained id receiver) {
                IMP invocation = CVLPHighlightsReadForwarder(&original);
                ((void (*)(id, SEL))invocation)((id)receiver, exactSelector);
                int originalErrno = errno;
                CVLPHighlightsRecordInvocation(target, 0, -1, 0.0);
                errno = originalErrno;
            };
            replacement = imp_implementationWithBlock(block);
            break;
        }
        case CVLPHighlightsHeightTarget: {
            id block = ^double(__unsafe_unretained id receiver) {
                IMP invocation = CVLPHighlightsReadForwarder(&original);
                double result = ((double (*)(id, SEL))invocation)((id)receiver, exactSelector);
                int originalErrno = errno;
                CVLPHighlightsRecordInvocation(CVLPHighlightsHeightTarget, 2, -1, result);
                errno = originalErrno;
                return result;
            };
            replacement = imp_implementationWithBlock(block);
            break;
        }
        case CVLPHighlightsConsumptionTarget:
        case CVLPHighlightsCreationTarget:
        case CVLPHighlightsTargetCount:
            return CVLPHighlightsInstallFailed;
    }
    if (replacement == NULL) { return CVLPHighlightsInstallFailed; }
    return CVLPHighlightsPublishForwarder(method, replacement, &original)
        ? CVLPHighlightsInstallInstalled : CVLPHighlightsInstallFailed;
}

@interface CVLPHighlightsObserver : NSObject {
@public
    int _installStatuses[CVLPHighlightsTargetCount];
    int _classLookupReasons[2];
    NSUInteger _classLookupClasses[2];
    NSUInteger _eventCount;
    CFTimeInterval _startedAt;
    BOOL _stopped;
    __strong id _backgroundObserver;
    __strong id _sceneObserver;
    NSUInteger _lastNodes;
    NSUInteger _lastWindows;
    NSUInteger _lastRows;
    int _lastHidden;
    double _lastAlpha;
    double _lastWidth;
    double _lastViewHeight;
    int _lastTruncated;
    int _lastError;
}
- (void)startOnMainQueue;
- (void)takeSample:(NSUInteger)sampleNumber;
- (void)stopWithReason:(CVLPHighlightsStopReason)reason;
- (void)appendLineForPhase:(NSString *)phase sequence:(NSUInteger)sequence reason:(int)reason
                      tree:(CVLPHighlightsTreeSummary)tree;
@end

static CVLPHighlightsTreeSummary CVLPHighlightsEmptyTree(void) {
    CVLPHighlightsTreeSummary summary = { 0, 0, 0, -1, -1.0, -1.0, -1.0, 0, 0 };
    return summary;
}

static CVLPHighlightsTreeSummary CVLPHighlightsSampleViewTree(void) {
    CVLPHighlightsTreeSummary summary = CVLPHighlightsEmptyTree();
    NSMutableArray<UIWindow *> *windows = [NSMutableArray arrayWithCapacity:CVLPHighlightsMaximumWindows];
    UIApplication *application = UIApplication.sharedApplication;
    NSUInteger scenesVisited = 0;
    BOOL windowLimitReached = NO;
    for (UIScene *scene in application.connectedScenes) {
        if (scenesVisited >= 16) { summary.truncated = 1; break; }
        scenesVisited++;
        if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            BOOL alreadySeen = NO;
            for (UIWindow *knownWindow in windows) {
                if (knownWindow == window) { alreadySeen = YES; break; }
            }
            if (alreadySeen) { continue; }
            if (summary.windows >= CVLPHighlightsMaximumWindows) {
                summary.truncated = 1;
                windowLimitReached = YES;
                break;
            }
            [windows addObject:window];
            summary.windows = windows.count;
        }
        if (windowLimitReached) { break; }
    }
    if (windows.count == 0) {
        summary.truncated = 1;
        return summary;
    }

    NSMutableArray<UIView *> *stackViews = [NSMutableArray arrayWithCapacity:CVLPHighlightsMaximumTreeNodes];
    NSMutableArray<NSNumber *> *stackDepths = [NSMutableArray arrayWithCapacity:CVLPHighlightsMaximumTreeNodes];
    for (UIWindow *window in windows) {
        UIView *rootView = window.rootViewController.viewIfLoaded;
        if (rootView == nil) { summary.truncated = 1; continue; }
        if (stackViews.count < CVLPHighlightsMaximumTreeNodes) {
            [stackViews addObject:rootView];
            [stackDepths addObject:@0];
        } else {
            summary.truncated = 1;
        }
    }

    while (stackViews.count > 0 && summary.nodes < CVLPHighlightsMaximumTreeNodes) {
        UIView *view = stackViews.lastObject;
        NSUInteger depth = stackDepths.lastObject.unsignedIntegerValue;
        [stackViews removeLastObject];
        [stackDepths removeLastObject];
        if (view == nil) { continue; }
        summary.nodes++;
        const char *className = class_getName(object_getClass(view));
        if (className != NULL && strcmp(className, CVLPHighlightsCellClassName) == 0) {
            summary.rows = MIN(CVLPHighlightsCountMaximum, summary.rows + 1);
            if (summary.hidden == -1) {
                summary.hidden = view.hidden ? 1 : 0;
                double alpha = (double)view.alpha;
                CGSize size = view.frame.size;
                summary.alpha = isfinite(alpha) ? alpha : -1.0;
                summary.width = isfinite((double)size.width) ? (double)size.width : -1.0;
                summary.height = isfinite((double)size.height) ? (double)size.height : -1.0;
            }
        }

        NSArray<UIView *> *subviews = view.subviews;
        if (depth >= CVLPHighlightsMaximumTreeDepth) {
            if (subviews.count > 0) { summary.truncated = 1; }
            continue;
        }
        for (NSUInteger index = subviews.count; index > 0; index--) {
            if (stackViews.count >= CVLPHighlightsMaximumTreeNodes) {
                summary.truncated = 1;
                break;
            }
            [stackViews addObject:subviews[index - 1]];
            [stackDepths addObject:@(depth + 1)];
        }
    }
    if (stackViews.count > 0) { summary.truncated = 1; }
    return summary;
}

static const char *CVLPHighlightsFieldNames[] = {
    "seq", "ms", "reason", "st0", "st1", "st2", "st3", "st4", "st5",
    "c0", "c1", "c2", "c3", "c4", "c5", "l0", "l1", "l2", "l3", "l4", "l5",
    "n", "w", "r", "hidden", "alpha", "width", "height", "trunc", "err",
    "scope", "why0", "why1", "classes0", "classes1", "mode", "overrideCalls",
    "directMode", "directStatus", "directCalls", "directLast", "directOverrideCalls",
};

static BOOL CVLPHighlightsParseInteger(const char *value) {
    if (value == NULL || *value == '\0') { return NO; }
    errno = 0;
    char *end = NULL;
    (void)strtoll(value, &end, 10);
    return errno != ERANGE && end != value && end != NULL && *end == '\0';
}

static long long CVLPHighlightsIntegerField(NSString *part) {
    if (![part isKindOfClass:NSString.class]) { return LLONG_MIN; }
    NSRange separator = [part rangeOfString:@"="];
    if (separator.location == NSNotFound || separator.location + 1 >= part.length) { return LLONG_MIN; }
    const char *value = [[part substringFromIndex:separator.location + 1] UTF8String];
    if (!CVLPHighlightsParseInteger(value)) { return LLONG_MIN; }
    return strtoll(value, NULL, 10);
}

static BOOL CVLPHighlightsParseFiniteNumber(const char *value) {
    if (value == NULL || *value == '\0') { return NO; }
    const char *cursor = value;
    if (*cursor == '-' || *cursor == '+') { cursor++; }
    BOOL hasDigits = NO;
    while (*cursor >= '0' && *cursor <= '9') { hasDigits = YES; cursor++; }
    if (*cursor == '.') {
        cursor++;
        while (*cursor >= '0' && *cursor <= '9') { hasDigits = YES; cursor++; }
    }
    if (!hasDigits) { return NO; }
    if (*cursor == 'e' || *cursor == 'E') {
        cursor++;
        if (*cursor == '-' || *cursor == '+') { cursor++; }
        const char *exponentDigits = cursor;
        while (*cursor >= '0' && *cursor <= '9') { cursor++; }
        if (cursor == exponentDigits) { return NO; }
    }
    if (*cursor != '\0') { return NO; }
    errno = 0;
    char *end = NULL;
    double parsed = strtod(value, &end);
    return errno != ERANGE && end != value && end != NULL && *end == '\0' && isfinite(parsed);
}

static BOOL CVLPHighlightsLineIsSanitized(NSString *line) {
    if (![line isKindOfClass:NSString.class] || line.length == 0 || line.length > 2048 ||
        ![line hasPrefix:@"CVLP_HIGHLIGHTS "]) { return NO; }
    static NSCharacterSet *allowedCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _=.+-"];
    });
    if ([line rangeOfCharacterFromSet:allowedCharacters.invertedSet].location != NSNotFound) { return NO; }
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    if (parts.count != 44 || ![parts[0] isEqualToString:@"CVLP_HIGHLIGHTS"]) { return NO; }
    NSString *phase = nil;
    for (NSUInteger index = 1; index < parts.count; index++) {
        NSString *part = parts[index];
        NSRange separator = [part rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0 || separator.location == part.length - 1 ||
            [part rangeOfString:@"=" options:0 range:NSMakeRange(separator.location + 1, part.length - separator.location - 1)].location != NSNotFound) {
            return NO;
        }
        NSString *key = [part substringToIndex:separator.location];
        const char *expected = NULL;
        if (index == 1) {
            if (![key isEqualToString:@"phase"]) { return NO; }
            phase = [part substringFromIndex:separator.location + 1];
            if (![@[@"start", @"sample", @"stopped"] containsObject:phase]) { return NO; }
            continue;
        }
        expected = CVLPHighlightsFieldNames[index - 2];
        if (strcmp(key.UTF8String, expected) != 0) { return NO; }
        const char *value = [[part substringFromIndex:separator.location + 1] UTF8String];
        if (index == 22 || index == 27 || index == 28 || index == 29) {
            if (!CVLPHighlightsParseFiniteNumber(value)) { return NO; }
        } else if (!CVLPHighlightsParseInteger(value)) {
            return NO;
        }
        if (index >= 5 && index <= 10) {
            long long status = strtoll(value, NULL, 10);
            if (status < CVLPHighlightsInstallUnknown || status > CVLPHighlightsInstallFailed) { return NO; }
        } else if (index == 4) {
            long long reason = strtoll(value, NULL, 10);
            if (reason < -1 || reason > CVLPHighlightsStopSceneDeactivated) { return NO; }
        } else if (index >= 11 && index <= 16) {
            long long count = strtoll(value, NULL, 10);
            if (count < 0 || count > CVLPHighlightsCountMaximum) { return NO; }
        } else if (index >= 17 && index <= 21) {
            long long last = strtoll(value, NULL, 10);
            if (last < -1 || last > 1) { return NO; }
        } else if (index == 23) {
            long long nodes = strtoll(value, NULL, 10);
            if (nodes < 0 || nodes > CVLPHighlightsMaximumTreeNodes) { return NO; }
        } else if (index == 24) {
            long long windows = strtoll(value, NULL, 10);
            if (windows < 0 || windows > CVLPHighlightsMaximumWindows) { return NO; }
        } else if (index == 25) {
            long long rows = strtoll(value, NULL, 10);
            if (rows < 0 || rows > CVLPHighlightsMaximumTreeNodes) { return NO; }
        } else if (index == 26) {
            long long hidden = strtoll(value, NULL, 10);
            if (hidden < -1 || hidden > 1) { return NO; }
        } else if (index == 30 || index == 31) {
            long long flag = strtoll(value, NULL, 10);
            if (flag < 0 || flag > 1) { return NO; }
        } else if (index == 32) {
            if (strtoll(value, NULL, 10) != 1) { return NO; }
        } else if (index == 33 || index == 34) {
            long long lookupReason = strtoll(value, NULL, 10);
            if (lookupReason < CVLPHighlightsLookupReasonNone ||
                lookupReason > CVLPHighlightsLookupReasonAnchorNotEnumerated) { return NO; }
        } else if (index == 35 || index == 36) {
            long long classes = strtoll(value, NULL, 10);
            if (classes < 0 || classes > CVLPHighlightsMaximumClasses) { return NO; }
        } else if (index == 37) {
            if (strtoll(value, NULL, 10) != CVLPHighlightsViewingExperimentMode) { return NO; }
        } else if (index == 38) {
            long long overrideCalls = strtoll(value, NULL, 10);
            if (overrideCalls < 0 || overrideCalls > CVLPHighlightsCountMaximum ||
                (CVLPHighlightsViewingExperimentMode == 0 && overrideCalls != 0)) { return NO; }
        } else if (index == 39) {
            if (strtoll(value, NULL, 10) != CVLPHighlightsDirectViewingExperimentMode) { return NO; }
        } else if (index == 40) {
            long long status = strtoll(value, NULL, 10);
            if (status < CVLPHighlightsDirectDisabled || status > CVLPHighlightsDirectCompareExchangeFailed ||
                (CVLPHighlightsDirectViewingExperimentMode == 0 && status != CVLPHighlightsDirectDisabled) ||
                (CVLPHighlightsDirectViewingExperimentMode == 1 && status == CVLPHighlightsDirectDisabled)) { return NO; }
        } else if (index == 41 || index == 43) {
            long long count = strtoll(value, NULL, 10);
            if (count < 0 || count > CVLPHighlightsCountMaximum ||
                (CVLPHighlightsDirectViewingExperimentMode == 0 && count != 0)) { return NO; }
            long long directStatus = CVLPHighlightsIntegerField(parts[40]);
            if (directStatus != CVLPHighlightsDirectInstalled && count != 0) { return NO; }
            if (index == 43 && count > CVLPHighlightsIntegerField(parts[41])) { return NO; }
        } else if (index == 42) {
            long long last = strtoll(value, NULL, 10);
            if (last < -1 || last > 1 ||
                (CVLPHighlightsDirectViewingExperimentMode == 0 && last != -1)) { return NO; }
            long long directStatus = CVLPHighlightsIntegerField(parts[40]);
            if (directStatus != CVLPHighlightsDirectInstalled && last != -1) { return NO; }
        }
    }
    return phase != nil;
}

@implementation CVLPHighlightsDiagnostics

+ (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    @synchronized (self) {
        if (CVLPHighlightsSharedObserver != nil) { return; }
        CVLPHighlightsObserver *observer = [CVLPHighlightsObserver new];
        observer->_startedAt = CACurrentMediaTime();
        for (NSUInteger index = 0; index < CVLPHighlightsTargetCount; index++) {
            observer->_installStatuses[index] = CVLPHighlightsInstallUnknown;
        }
        for (NSUInteger index = 0; index < 2; index++) {
            observer->_classLookupReasons[index] = CVLPHighlightsLookupReasonNone;
            observer->_classLookupClasses[index] = 0;
        }
        CVLPHighlightsSharedObserver = observer;
        [observer startOnMainQueue];
    }
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
+ (BOOL)runFixtureSelfTest:(NSString **)failure {
    if (![NSThread isMainThread]) { if (failure != NULL) { *failure = @"main_thread_required"; } return NO; }
    return CVLPHighlightsRunFixtureSelfTest(failure);
}
#endif

@end

@implementation CVLPHighlightsObserver

- (void)startOnMainQueue {
    NSCAssert([NSThread isMainThread], @"Highlights diagnostics must start on the main queue.");
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    CVLPHighlightsState = (CVLPHighlightsHookState){ .lastConsumption = -1, .lastCreation = -1,
        .directLast = -1, .lastModelPresence = -1, .lastMount = -1, .lastUpdate = -1,
        .lastHeight = -1.0 };
    CVLPHighlightsStartedAt = self->_startedAt;
    CVLPHighlightsRecording = YES;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    CVLPHighlightsStoreLastTree(self, CVLPHighlightsEmptyTree());

    Class modelClass = objc_lookUpClass("TTKProfileBizDataStoryHighlightInfoModel");
    Class componentClass = objc_lookUpClass("TTKProfileStoryHighlightComponent");
    Class collectionClass = objc_lookUpClass("TTKProfileStoryHighlightCollectionComponent");
    CVLPHighlightsClassMethodSearch consumptionSearch = {0};
    CVLPHighlightsClassMethodSearch creationSearch = {0};
    self->_installStatuses[CVLPHighlightsConsumptionTarget] = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightConsumption"), CVLPHighlightsConsumptionTarget,
        modelClass, &consumptionSearch);
    self->_classLookupReasons[0] = consumptionSearch.reason;
    self->_classLookupClasses[0] = MIN(consumptionSearch.classes, CVLPHighlightsMaximumClasses);
    self->_installStatuses[CVLPHighlightsCreationTarget] = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightCreation"), CVLPHighlightsCreationTarget,
        modelClass, &creationSearch);
    self->_classLookupReasons[1] = creationSearch.reason;
    self->_classLookupClasses[1] = MIN(creationSearch.classes, CVLPHighlightsMaximumClasses);
#if CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
    CVLPHighlightsDirectInstallStatus directStatus = CVLPHighlightsDirectInstallForAnchor(modelClass);
#else
    CVLPHighlightsDirectInstallStatus directStatus = CVLPHighlightsDirectDisabled;
#endif
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    CVLPHighlightsState.directStatus = directStatus;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    self->_installStatuses[CVLPHighlightsModelTarget] = CVLPHighlightsInstallInstance(
        modelClass, sel_registerName("storyHighlightInfo"), "@", CVLPHighlightsModelTarget);
    self->_installStatuses[CVLPHighlightsMountTarget] = CVLPHighlightsInstallInstance(
        componentClass, sel_registerName("componentMount"), "v", CVLPHighlightsMountTarget);
    self->_installStatuses[CVLPHighlightsUpdateTarget] = CVLPHighlightsInstallInstance(
        collectionClass, sel_registerName("updateUI"), "v", CVLPHighlightsUpdateTarget);
    self->_installStatuses[CVLPHighlightsHeightTarget] = CVLPHighlightsInstallInstance(
        collectionClass, sel_registerName("viewHeight"), "d", CVLPHighlightsHeightTarget);

    __weak CVLPHighlightsObserver *weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    self->_backgroundObserver = [center addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            [weakSelf stopWithReason:CVLPHighlightsStopBackground];
        }];
    self->_sceneObserver = [center addObserverForName:UISceneWillDeactivateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            [weakSelf stopWithReason:CVLPHighlightsStopSceneDeactivated];
        }];

    // Startup precedes guest appMain. Do not ask UIKit for its application or
    // windows until the first scheduled sample after the guest has started.
    CVLPHighlightsTreeSummary initialTree = CVLPHighlightsEmptyTree();
    initialTree.truncated = 1;
    [self appendLineForPhase:@"start" sequence:0 reason:-1 tree:initialTree];
    [self scheduleSample:1];
}

- (void)scheduleSample:(NSUInteger)sampleNumber {
    if (self->_stopped || sampleNumber == 0 || sampleNumber > CVLPHighlightsMaximumSamples) { return; }
    CFTimeInterval targetTime = self->_startedAt + (5.0 * (CFTimeInterval)sampleNumber);
    CFTimeInterval remaining = MAX(0.0, targetTime - CACurrentMediaTime());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_stopped) { return; }
        [self takeSample:sampleNumber];
        if (!self->_stopped && sampleNumber < CVLPHighlightsMaximumSamples) {
            [self scheduleSample:sampleNumber + 1];
        }
    });
}

- (void)takeSample:(NSUInteger)sampleNumber {
    if (self->_stopped || ![NSThread isMainThread]) { return; }
    if (CACurrentMediaTime() - self->_startedAt >= CVLPHighlightsDeadline) {
        [self stopWithReason:CVLPHighlightsStopDeadline];
        return;
    }
    CVLPHighlightsTreeSummary tree = CVLPHighlightsSampleTreeSafely();
    if (CACurrentMediaTime() - self->_startedAt < CVLPHighlightsDeadline) {
        [self appendLineForPhase:@"sample" sequence:sampleNumber reason:-1 tree:tree];
    }
    if (sampleNumber >= CVLPHighlightsMaximumSamples || CACurrentMediaTime() - self->_startedAt >= CVLPHighlightsDeadline) {
        [self stopWithReason:CVLPHighlightsStopDeadline];
    }
}

- (void)stopWithReason:(CVLPHighlightsStopReason)reason {
    if (self->_stopped || ![NSThread isMainThread]) { return; }
    self->_stopped = YES;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    CVLPHighlightsRecording = NO;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self->_backgroundObserver != nil) { [center removeObserver:self->_backgroundObserver]; self->_backgroundObserver = nil; }
    if (self->_sceneObserver != nil) { [center removeObserver:self->_sceneObserver]; self->_sceneObserver = nil; }
    [self appendLineForPhase:@"stopped" sequence:self->_eventCount + 1 reason:(int)reason tree:CVLPHighlightsObserverLastTree(self)];
}

- (void)appendLineForPhase:(NSString *)phase sequence:(NSUInteger)sequence reason:(int)reason
                      tree:(CVLPHighlightsTreeSummary)tree {
    if ((self->_stopped && ![phase isEqualToString:@"stopped"]) ||
        self->_eventCount >= CVLPHighlightsMaximumEvents || ![NSThread isMainThread]) { return; }
    CVLPHighlightsHookState state;
    os_unfair_lock_lock(&CVLPHighlightsStateLock);
    state = CVLPHighlightsState;
    os_unfair_lock_unlock(&CVLPHighlightsStateLock);
    unsigned long long elapsed = (unsigned long long)MAX(0.0, floor((CACurrentMediaTime() - self->_startedAt) * 1000.0));
    NSString *line = [NSString stringWithFormat:
        @"CVLP_HIGHLIGHTS phase=%@ seq=%lu ms=%llu reason=%d st0=%d st1=%d st2=%d st3=%d st4=%d st5=%d "
         "c0=%u c1=%u c2=%u c3=%u c4=%u c5=%u l0=%d l1=%d l2=%d l3=%d l4=%d l5=%.6g "
         "n=%lu w=%lu r=%lu hidden=%d alpha=%.6g width=%.6g height=%.6g trunc=%d err=%d "
         "scope=1 why0=%d why1=%d classes0=%lu classes1=%lu mode=%d overrideCalls=%u "
         "directMode=%d directStatus=%d directCalls=%u directLast=%d directOverrideCalls=%u",
        phase, (unsigned long)sequence, elapsed, reason,
        self->_installStatuses[0], self->_installStatuses[1], self->_installStatuses[2],
        self->_installStatuses[3], self->_installStatuses[4], self->_installStatuses[5],
        (unsigned int)state.counts[0], (unsigned int)state.counts[1], (unsigned int)state.counts[2],
        (unsigned int)state.counts[3], (unsigned int)state.counts[4], (unsigned int)state.counts[5],
        state.lastConsumption, state.lastCreation, state.lastModelPresence, state.lastMount, state.lastUpdate,
        state.lastHeight, (unsigned long)tree.nodes, (unsigned long)tree.windows, (unsigned long)tree.rows,
        tree.hidden, tree.alpha, tree.width, tree.height, tree.truncated, tree.error,
        self->_classLookupReasons[0], self->_classLookupReasons[1],
        (unsigned long)self->_classLookupClasses[0], (unsigned long)self->_classLookupClasses[1],
        CVLPHighlightsViewingExperimentMode, (unsigned int)state.overrideCalls,
        CVLPHighlightsDirectViewingExperimentMode, state.directStatus,
        (unsigned int)state.directCalls, state.directLast, (unsigned int)state.directOverrideCalls];
    if (!CVLPHighlightsLineIsSanitized(line)) { return; }
    self->_eventCount++;
    CVLPHighlightsStoreLastTree(self, tree);
    [CVLPProbe recordGuestDiagnostic:line];
}

@end

static CVLPHighlightsTreeSummary CVLPHighlightsSampleTreeSafely(void) {
    CVLPHighlightsTreeSummary summary = CVLPHighlightsEmptyTree();
    @try {
        summary = CVLPHighlightsSampleViewTree();
    } @catch (__unused NSException *exception) {
        summary.error = 1;
        summary.truncated = 1;
    }
    return summary;
}

static void CVLPHighlightsStoreLastTree(CVLPHighlightsObserver *observer, CVLPHighlightsTreeSummary tree) {
    observer->_lastNodes = tree.nodes;
    observer->_lastWindows = tree.windows;
    observer->_lastRows = tree.rows;
    observer->_lastHidden = tree.hidden;
    observer->_lastAlpha = tree.alpha;
    observer->_lastWidth = tree.width;
    observer->_lastViewHeight = tree.height;
    observer->_lastTruncated = tree.truncated;
    observer->_lastError = tree.error;
}

static CVLPHighlightsTreeSummary CVLPHighlightsObserverLastTree(CVLPHighlightsObserver *observer) {
    CVLPHighlightsTreeSummary tree = {
        observer->_lastNodes, observer->_lastWindows, observer->_lastRows, observer->_lastHidden,
        observer->_lastAlpha, observer->_lastWidth, observer->_lastViewHeight,
        observer->_lastTruncated, observer->_lastError,
    };
    return tree;
}

NS_ASSUME_NONNULL_END
