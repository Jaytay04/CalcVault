#define CVLP_HIGHLIGHTS_TESTING 1
#import "CVLPHighlightsDiagnostics.h"
#import <stdio.h>

static NSUInteger CVLPFixtureConsumptionCalls = 0;
static NSUInteger CVLPFixtureCreationCalls = 0;
static NSUInteger CVLPFixtureGetterCalls = 0;
static NSUInteger CVLPFixtureMountCalls = 0;
static NSUInteger CVLPFixtureUpdateCalls = 0;
static NSUInteger CVLPFixtureHeightCalls = 0;
static BOOL CVLPFixtureConsumptionResult = NO;
static BOOL CVLPFixtureShouldThrowConsumption = NO;
static BOOL CVLPFixtureCreationResult = NO;
static BOOL CVLPFixtureShouldThrowCreation = NO;
static BOOL CVLPFixtureAlternateResult = NO;
static NSUInteger CVLPFixtureAlternateCalls = 0;
static double CVLPFixtureHeightResult = 42.75;
static id CVLPFixtureModelResult;
static NSException *CVLPFixtureForwardedException;
static NSMutableArray<NSString *> *CVLPFixtureDiagnosticLines;
static NSUInteger CVLPFixtureDisplacedCalls;
static NSUInteger CVLPFixtureResolverCalls;

typedef struct {
    CFTimeInterval now;
    CFTimeInterval advancePerRead;
    Class mismatchedClass;
} CVLPFixtureLookupContext;

static CFTimeInterval CVLPFixtureLookupClock(void *opaque) {
    CVLPFixtureLookupContext *context = opaque;
    CFTimeInterval now = context->now;
    context->now += context->advancePerRead;
    return now;
}

static const char *CVLPFixtureLookupImageName(Class cls, void *opaque) {
    CVLPFixtureLookupContext *context = opaque;
    return cls == context->mismatchedClass ? "/fixture/other-image" : "/fixture/highlights-image";
}

@interface CVLPFixtureResolverTrap : NSObject
@end
@implementation CVLPFixtureResolverTrap
+ (BOOL)resolveClassMethod:(SEL)selector {
    (void)selector;
    CVLPFixtureResolverCalls++;
    return NO;
}
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    (void)selector;
    CVLPFixtureResolverCalls++;
    return NO;
}
@end

@interface CVLPFixtureChain : NSObject
- (BOOL)chainFlag;
@end
@implementation CVLPFixtureChain
- (BOOL)chainFlag { return NO; }
@end

static BOOL CVLPFixtureInterveningHook(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    CVLPFixtureDisplacedCalls++;
    return YES;
}

@interface CVLPFixtureFeatureOwner : NSObject
+ (BOOL)enableStoryHighlightConsumption;
+ (BOOL)enableStoryHighlightCreation;
+ (BOOL)alternateFeatureEligibility;
@end

@implementation CVLPFixtureFeatureOwner
+ (BOOL)enableStoryHighlightConsumption {
    CVLPFixtureConsumptionCalls++;
    errno = EDOM;
    if (CVLPFixtureShouldThrowConsumption) { @throw CVLPFixtureForwardedException; }
    return CVLPFixtureConsumptionResult;
}
+ (BOOL)enableStoryHighlightCreation {
    CVLPFixtureCreationCalls++;
    errno = EILSEQ;
    if (CVLPFixtureShouldThrowCreation) { @throw CVLPFixtureForwardedException; }
    return CVLPFixtureCreationResult;
}
+ (BOOL)alternateFeatureEligibility {
    CVLPFixtureAlternateCalls++;
    errno = ERANGE;
    return CVLPFixtureAlternateResult;
}
@end

@interface CVLPFixtureAmbiguousOwnerA : NSObject
+ (BOOL)ambiguousFixtureClassMethod;
@end

@implementation CVLPFixtureAmbiguousOwnerA
+ (BOOL)ambiguousFixtureClassMethod { return YES; }
@end

@interface CVLPFixtureAmbiguousOwnerB : NSObject
+ (BOOL)ambiguousFixtureClassMethod;
@end

@implementation CVLPFixtureAmbiguousOwnerB
+ (BOOL)ambiguousFixtureClassMethod { return NO; }
@end

@interface CVLPFixtureInheritedClassMethodBase : NSObject
+ (BOOL)inheritedFixtureClassMethod;
@end

@implementation CVLPFixtureInheritedClassMethodBase
+ (BOOL)inheritedFixtureClassMethod { return YES; }
@end

@interface CVLPFixtureInheritedClassMethodChild : CVLPFixtureInheritedClassMethodBase
@end

@implementation CVLPFixtureInheritedClassMethodChild
@end

@interface TTKProfileBizDataStoryHighlightInfoModel : NSObject
- (id)storyHighlightInfo;
@end

@implementation TTKProfileBizDataStoryHighlightInfoModel
- (id)storyHighlightInfo {
    CVLPFixtureGetterCalls++;
    return CVLPFixtureModelResult;
}
@end

@interface CVLPFixtureWrongModel : NSObject
- (void)storyHighlightInfo;
@end

@implementation CVLPFixtureWrongModel
- (void)storyHighlightInfo {}
@end

@interface CVLPFixtureMountBase : NSObject
- (void)componentMount;
@end

@implementation CVLPFixtureMountBase
- (void)componentMount { CVLPFixtureMountCalls++; }
@end

@interface TTKProfileStoryHighlightComponent : CVLPFixtureMountBase
@end

@implementation TTKProfileStoryHighlightComponent
@end

@interface TTKProfileStoryHighlightCollectionComponent : NSObject
- (void)updateUI;
- (double)viewHeight;
@end

@implementation TTKProfileStoryHighlightCollectionComponent
- (void)updateUI { CVLPFixtureUpdateCalls++; }
- (double)viewHeight {
    CVLPFixtureHeightCalls++;
    return CVLPFixtureHeightResult;
}
@end

@interface CVLPFixtureAbsentTarget : NSObject
@end

@implementation CVLPFixtureAbsentTarget
@end

@implementation CVLPProbe
+ (void)recordGuestDiagnostic:(NSString *)line {
    if (!CVLPHighlightsLineIsSanitized(line)) { return; }
    if (CVLPFixtureDiagnosticLines == nil) { CVLPFixtureDiagnosticLines = [NSMutableArray array]; }
    [CVLPFixtureDiagnosticLines addObject:line];
}
@end

static BOOL CVLPFixtureRequire(BOOL condition, NSString *name, NSString **failure) {
    if (condition) { return YES; }
    if (failure != NULL) { *failure = name; }
    return NO;
}

#if CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
#import "CVLPEarlyLoaderFixture.m"
#endif

// Synthetic virtual addresses exercise the production parser and installer.
// The fake original address is never executed; forwarding uses a separate real
// C function-pointer cell below. No proprietary payload or account is involved.
typedef struct {
    uint8_t header[sizeof(struct mach_header_64) + 24664];
    uintptr_t base;
    uintptr_t consumption;
    uintptr_t creation;
    uint8_t stub[12];
    uint8_t getter[28];
    BOOL rejectMapping;
    BOOL rejectRead;
    BOOL rejectCAS;
    vm_prot_t slotProtection;
    vm_prot_t codeProtection;
    NSUInteger CASCalls;
    BOOL originalPublished;
} CVLPDirectFixtureMemory;

static void CVLPDirectFixtureInitialize(CVLPDirectFixtureMemory *fixture) {
    memset(fixture, 0, sizeof(*fixture));
    fixture->base = 0x100000000ULL;
    fixture->slotProtection = VM_PROT_READ | VM_PROT_WRITE;
    fixture->codeProtection = VM_PROT_READ | VM_PROT_EXECUTE;
    fixture->consumption = fixture->base + CVLPHighlightsDirectConsumptionVM;
    fixture->creation = fixture->base + CVLPHighlightsDirectCreationVM;
    memcpy(fixture->stub, CVLPHighlightsDirectExpectedStub, sizeof(fixture->stub));
    memcpy(fixture->getter, CVLPHighlightsDirectExpectedGetter, sizeof(fixture->getter));
    struct mach_header_64 header = { .magic = MH_MAGIC_64, .cputype = CPU_TYPE_ARM64,
        .cpusubtype = CPU_SUBTYPE_ARM64_ALL, .filetype = MH_DYLIB,
        .ncmds = 182, .sizeofcmds = 24664 };
    memcpy(fixture->header, &header, sizeof(header));
    uint8_t *cursor = fixture->header + sizeof(header);
    struct uuid_command uuid = { .cmd = LC_UUID, .cmdsize = sizeof(uuid) };
    memcpy(uuid.uuid, CVLPHighlightsDirectExpectedUUID, sizeof(uuid.uuid));
    memcpy(cursor, &uuid, sizeof(uuid)); cursor += sizeof(uuid);
    struct segment_command_64 text = { .cmd = LC_SEGMENT_64, .cmdsize = sizeof(text),
        .vmaddr = 0, .vmsize = CVLPHighlightsDirectTextVMSize, .fileoff = 0,
        .filesize = CVLPHighlightsDirectTextVMSize, .maxprot = VM_PROT_READ | VM_PROT_EXECUTE,
        .initprot = VM_PROT_READ | VM_PROT_EXECUTE };
    memcpy(text.segname, "__TEXT", 7);
    memcpy(cursor, &text, sizeof(text)); cursor += sizeof(text);
    struct segment_command_64 data = { .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(data) + sizeof(struct section_64),
        .vmaddr = CVLPHighlightsDirectDataVM, .vmsize = CVLPHighlightsDirectDataVMSize,
        .filesize = CVLPHighlightsDirectDataFileSize, .maxprot = VM_PROT_READ | VM_PROT_WRITE,
        .initprot = VM_PROT_READ | VM_PROT_WRITE, .nsects = 1 };
    memcpy(data.segname, "__DATA", 7);
    memcpy(cursor, &data, sizeof(data)); cursor += sizeof(data);
    struct section_64 section = { .addr = CVLPHighlightsDirectClassRefsVM,
        .size = CVLPHighlightsDirectClassRefsSize };
    memcpy(section.sectname, "__objc_clsrefs", 15);
    memcpy(section.segname, "__DATA", 7);
    memcpy(cursor, &section, sizeof(section)); cursor += sizeof(section);
    struct segment_command_64 executable = { .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(executable), .vmaddr = CVLPHighlightsDirectExecutableVM,
        .vmsize = CVLPHighlightsDirectExecutableVMSize,
        .maxprot = VM_PROT_READ | VM_PROT_EXECUTE, .initprot = VM_PROT_READ | VM_PROT_EXECUTE };
    memcpy(executable.segname, "__BD_TEXT", 10);
    memcpy(cursor, &executable, sizeof(executable)); cursor += sizeof(executable);
    // Four meaningful commands, then bounded opaque commands with exact count.
    for (NSUInteger index = 4; index < 182; index++) {
        struct load_command filler = { .cmd = 0, .cmdsize = sizeof(filler) };
        if (index == 181) { filler.cmdsize = (uint32_t)(fixture->header + sizeof(fixture->header) - cursor); }
        memcpy(cursor, &filler, sizeof(filler)); cursor += filler.cmdsize;
    }
}

static BOOL CVLPDirectFixtureRegion(uintptr_t address, size_t length, vm_prot_t required,
    vm_prot_t forbidden, void *opaque) {
    CVLPDirectFixtureMemory *fixture = opaque;
    if (fixture->rejectMapping) { return NO; }
    vm_prot_t protection = fixture->codeProtection;
    uintptr_t page = (fixture->base + CVLPHighlightsDirectConsumptionSlotVM) & ~((uintptr_t)vm_page_size - 1);
    if (CVLPHighlightsDirectRangeContains(page, vm_page_size, address, length)) {
        protection = fixture->slotProtection;
    } else if (!CVLPHighlightsDirectRangeContains(fixture->base, sizeof(fixture->header), address, length) &&
        !CVLPHighlightsDirectRangeContains(fixture->base + CVLPHighlightsDirectStubVM, 12, address, length) &&
        !CVLPHighlightsDirectRangeContains(fixture->base + CVLPHighlightsDirectConsumptionVM, 28, address, length) &&
        !CVLPHighlightsDirectRangeContains(fixture->base + CVLPHighlightsDirectCreationVM, 1, address, length)) {
        return NO;
    }
    return (protection & required) == required && (protection & forbidden) == 0;
}

static BOOL CVLPDirectFixtureRead(uintptr_t address, void *destination, size_t length, void *opaque) {
    CVLPDirectFixtureMemory *fixture = opaque;
    if (fixture->rejectRead) { return NO; }
    if (CVLPHighlightsDirectRangeContains(fixture->base, sizeof(fixture->header), address, length)) {
        memcpy(destination, fixture->header + address - fixture->base, length);
    } else if (address == fixture->base + CVLPHighlightsDirectConsumptionSlotVM && length == sizeof(uintptr_t)) {
        memcpy(destination, &fixture->consumption, length);
    } else if (address == fixture->base + CVLPHighlightsDirectCreationSlotVM && length == sizeof(uintptr_t)) {
        memcpy(destination, &fixture->creation, length);
    } else if (address == fixture->base + CVLPHighlightsDirectStubVM && length == sizeof(fixture->stub)) {
        memcpy(destination, fixture->stub, length);
    } else if (address == fixture->base + CVLPHighlightsDirectConsumptionVM && length == sizeof(fixture->getter)) {
        memcpy(destination, fixture->getter, length);
    } else { return NO; }
    return YES;
}

static BOOL CVLPDirectFixtureCAS(uintptr_t address, uintptr_t expected, uintptr_t replacement, void *opaque) {
    CVLPDirectFixtureMemory *fixture = opaque;
    fixture->CASCalls++;
    fixture->originalPublished = atomic_load_explicit(&CVLPHighlightsDirectOriginalAddress, memory_order_acquire) == expected;
    if (fixture->rejectCAS || address != fixture->base + CVLPHighlightsDirectConsumptionSlotVM ||
        fixture->consumption != expected) { return NO; }
    fixture->consumption = replacement;
    return YES;
}

static NSUInteger CVLPDirectFixtureOriginalCalls;
static BOOL CVLPDirectFixtureNatural;
static BOOL CVLPDirectFixtureThrow;
static BOOL CVLPDirectFixtureOriginal(void) {
    CVLPDirectFixtureOriginalCalls++;
    errno = EDOM;
    if (CVLPDirectFixtureThrow) { @throw CVLPFixtureForwardedException; }
    return CVLPDirectFixtureNatural;
}

static BOOL CVLPHighlightsDirectRunFixture(NSString **failure) {
    CVLPDirectFixtureMemory fixture;
    CVLPHighlightsDirectImagePin pin;
    CVLPDirectFixtureInitialize(&fixture);
    ((struct mach_header_64 *)fixture.header)->filetype = MH_EXECUTE;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectPinMismatch, @"direct_wrong_filetype_rejected", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectInstalled, @"direct_pinned_synthetic_image_valid", failure)) { return NO; }
    // Exercise malformed metadata in every mode, independently of installation.
    struct mach_header_64 *header = (struct mach_header_64 *)fixture.header;
    header->cpusubtype = 2;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectUnsupportedArchitecture, @"direct_wrong_architecture_rejected", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    fixture.header[sizeof(struct mach_header_64) + 8] ^= 1;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectPinMismatch, @"direct_wrong_uuid_rejected", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    ((struct load_command *)(fixture.header + sizeof(struct mach_header_64)))->cmdsize = UINT32_MAX;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectMalformedImage, @"direct_command_bounds_rejected", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    struct section_64 *section = (struct section_64 *)(fixture.header + sizeof(struct mach_header_64) +
        sizeof(struct uuid_command) + 2 * sizeof(struct segment_command_64));
    section->addr++;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectParseImage(fixture.header, sizeof(fixture.header), &pin) ==
        CVLPHighlightsDirectSectionMismatch, @"direct_wrong_section_rejected", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    CVLPHighlightsDirectMemory memory = { CVLPDirectFixtureRegion, CVLPDirectFixtureRead, CVLPDirectFixtureCAS, &fixture };
#if !CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT && !CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
    if (!CVLPFixtureRequire(CVLPHighlightsDirectValidateAndInstall(fixture.base, &memory) ==
        CVLPHighlightsDirectDisabled && fixture.CASCalls == 0 &&
        fixture.consumption == fixture.base + CVLPHighlightsDirectConsumptionVM,
        @"direct_default_off_never_publishes", failure)) { return NO; }
    return YES;
#else
    // All rejection cases must leave BOTH cells untouched and perform no CAS.
    for (NSUInteger test = 0; test < 11; test++) {
        CVLPDirectFixtureInitialize(&fixture);
        CVLPHighlightsDirectInstallStatus expected;
        switch (test) {
            case 0: fixture.rejectMapping = YES; expected = CVLPHighlightsDirectMappingRejected; break;
            case 1: fixture.rejectRead = YES; expected = CVLPHighlightsDirectMappingRejected; break;
            case 2: fixture.stub[0] ^= 1; expected = CVLPHighlightsDirectCodeMismatch; break;
            case 3: fixture.getter[0] ^= 1; expected = CVLPHighlightsDirectCodeMismatch; break;
            case 4: fixture.consumption++; expected = CVLPHighlightsDirectConsumptionSlotMismatch; break;
            case 5: fixture.creation++; expected = CVLPHighlightsDirectCreationSlotMismatch; break;
            case 6: fixture.base++; expected = CVLPHighlightsDirectSectionMismatch; break;
            case 7: fixture.slotProtection = VM_PROT_READ; expected = CVLPHighlightsDirectMappingRejected; break;
            case 8: fixture.slotProtection |= VM_PROT_EXECUTE; expected = CVLPHighlightsDirectMappingRejected; break;
            case 9: fixture.codeProtection |= VM_PROT_WRITE; expected = CVLPHighlightsDirectMappingRejected; break;
            default: fixture.codeProtection = VM_PROT_READ; expected = CVLPHighlightsDirectMappingRejected; break;
        }
        uintptr_t consumptionBefore = fixture.consumption, creationBefore = fixture.creation;
        if (!CVLPFixtureRequire(CVLPHighlightsDirectValidateAndInstall(fixture.base, &memory) == expected &&
            fixture.CASCalls == 0 && fixture.consumption == consumptionBefore && fixture.creation == creationBefore,
            @"direct_preflight_failure_never_mutates", failure)) { return NO; }
    }
    CVLPDirectFixtureInitialize(&fixture);
    fixture.rejectCAS = YES;
    uintptr_t consumptionBefore = fixture.consumption, creationBefore = fixture.creation;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectValidateAndInstall(fixture.base, &memory) ==
        CVLPHighlightsDirectCompareExchangeFailed && fixture.CASCalls == 1 && fixture.originalPublished &&
        fixture.consumption == consumptionBefore && fixture.creation == creationBefore,
        @"direct_failed_cas_preserves_both_cells", failure)) { return NO; }
    CVLPDirectFixtureInitialize(&fixture);
    if (!CVLPFixtureRequire(CVLPHighlightsDirectValidateAndInstall(fixture.base, &memory) ==
        CVLPHighlightsDirectInstalled && fixture.CASCalls == 1 && fixture.originalPublished &&
        fixture.consumption == (uintptr_t)&CVLPHighlightsDirectReplacement &&
        fixture.creation == fixture.base + CVLPHighlightsDirectCreationVM,
        @"direct_installs_only_consumption_after_original_publication", failure)) { return NO; }

    // Now use the real production Mach query/read/CAS on a synthetic RW cell.
    uintptr_t cells[2] = { (uintptr_t)&CVLPDirectFixtureOriginal, (uintptr_t)&CVLPDirectFixtureOriginal };
    uintptr_t readback = 0;
    if (!CVLPFixtureRequire(CVLPHighlightsDirectMachRegionAllows((uintptr_t)cells, sizeof(cells),
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE, NULL) &&
        CVLPHighlightsDirectMachRead((uintptr_t)cells, &readback, sizeof(readback), NULL) && readback == cells[0],
        @"direct_real_mach_rw_cell_query_and_read", failure)) { return NO; }
    uintptr_t savedOriginal = atomic_load_explicit(&CVLPHighlightsDirectOriginalAddress, memory_order_acquire);
    atomic_store_explicit(&CVLPHighlightsDirectOriginalAddress, cells[0], memory_order_release);
    if (!CVLPFixtureRequire(CVLPHighlightsDirectMachCompareExchange((uintptr_t)cells, cells[0],
        (uintptr_t)&CVLPHighlightsDirectReplacement, NULL) && cells[1] == (uintptr_t)&CVLPDirectFixtureOriginal &&
        !CVLPHighlightsDirectMachCompareExchange((uintptr_t)cells, (uintptr_t)&CVLPDirectFixtureOriginal,
        0, NULL) && cells[0] == (uintptr_t)&CVLPHighlightsDirectReplacement,
        @"direct_real_cas_never_overwrites_mismatch_or_creation", failure)) { return NO; }
    CVLPHighlightsHookState savedState = CVLPHighlightsState;
    BOOL savedRecording = CVLPHighlightsRecording;
    CFTimeInterval savedStart = CVLPHighlightsStartedAt;
    CVLPHighlightsState.directStatus = CVLPHighlightsDirectInstalled;
    CVLPHighlightsState.directCalls = CVLPHighlightsState.directOverrideCalls = 0;
    CVLPHighlightsState.directLast = -1;
    CVLPHighlightsRecording = YES;
    CVLPHighlightsStartedAt = CACurrentMediaTime();
#if CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
    atomic_store_explicit(&CVLPHighlightsEarlyStatusValue, CVLPHighlightsEarlyInstallFailed, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyDirectStatus, CVLPHighlightsDirectImageUnavailable, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyMatchCount, 0, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyRetainedValue, 0, memory_order_release);
#endif
    CVLPDirectFixtureOriginalCalls = 0;
    CVLPDirectFixtureNatural = NO;
    CVLPHighlightsDirectGateFunction call = (CVLPHighlightsDirectGateFunction)cells[0];
    if (!CVLPFixtureRequire(call() && errno == EDOM && CVLPDirectFixtureOriginalCalls == 1 &&
        CVLPHighlightsState.directLast == 0 && CVLPHighlightsState.directCalls == 1 &&
        CVLPHighlightsState.directOverrideCalls == 1, @"direct_false_original_once_and_errno", failure)) { return NO; }
    CVLPDirectFixtureNatural = YES;
    if (!CVLPFixtureRequire(call() && CVLPDirectFixtureOriginalCalls == 2 && CVLPHighlightsState.directLast == 1 &&
        CVLPHighlightsState.directCalls == 2, @"direct_true_original_once", failure)) { return NO; }
    CVLPDirectFixtureThrow = YES;
    BOOL caught = NO;
    @try { (void)call(); } @catch (NSException *exception) { caught = exception == CVLPFixtureForwardedException; }
    CVLPDirectFixtureThrow = NO;
    if (!CVLPFixtureRequire(caught && CVLPDirectFixtureOriginalCalls == 3 && CVLPHighlightsState.directCalls == 3 &&
        CVLPHighlightsState.directOverrideCalls == 2, @"direct_exception_preserved_without_override", failure)) { return NO; }
    CVLPHighlightsState.directCalls = CVLPHighlightsState.directOverrideCalls = 65535;
    (void)call();
    if (!CVLPFixtureRequire(CVLPHighlightsState.directCalls == 65535 && CVLPHighlightsState.directOverrideCalls == 65535,
        @"direct_counter_saturation", failure)) { return NO; }
    CVLPHighlightsState.directCalls = CVLPHighlightsState.directOverrideCalls = 9;
    CVLPHighlightsState.directLast = 0;
    CVLPHighlightsStartedAt = CACurrentMediaTime() - CVLPHighlightsDeadline - 1;
    CVLPDirectFixtureNatural = NO;
    if (!CVLPFixtureRequire(call() && !CVLPHighlightsRecording && CVLPHighlightsState.directCalls == 9 &&
        CVLPHighlightsState.directLast == 0, @"direct_deadline_freezes_recording_not_delivery", failure)) { return NO; }
    CVLPHighlightsObserver *stopObserver = [CVLPHighlightsObserver new];
    stopObserver->_startedAt = CACurrentMediaTime();
    CVLPHighlightsRecording = YES;
    CVLPHighlightsStartedAt = CACurrentMediaTime();
    [stopObserver stopWithReason:CVLPHighlightsStopBackground];
    NSUInteger linesAfterStop = CVLPFixtureDiagnosticLines.count;
    if (!CVLPFixtureRequire(call() && !CVLPHighlightsRecording && CVLPHighlightsState.directCalls == 9 &&
        CVLPFixtureDiagnosticLines.count == linesAfterStop,
        @"direct_actual_background_stop_freezes_recording", failure)) { return NO; }
    // Fixture cleanup only: the real guest override is never removed on stop.
    atomic_store_explicit(&CVLPHighlightsDirectOriginalAddress, savedOriginal, memory_order_release);
    CVLPHighlightsState = savedState;
    CVLPHighlightsRecording = savedRecording;
    CVLPHighlightsStartedAt = savedStart;
    return YES;
#endif
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
#import "AdmissionMetadataFixtureCases.h"
#endif

BOOL CVLPHighlightsRunFixtureSelfTest(NSString **failure) {
    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE core-start\n");
    if (failure != NULL) { *failure = nil; }
    // Deterministically reproduce an intervening hook between lookup and swap.
    SEL chainSelector = @selector(chainFlag);
    Method chainMethod = class_getInstanceMethod(CVLPFixtureChain.class, chainSelector);
    __block IMP chainOriginal = method_getImplementation(chainMethod);
    IMP chainReplacement = imp_implementationWithBlock(^BOOL(id receiver) {
        IMP invocation = CVLPHighlightsReadForwarder(&chainOriginal);
        return ((BOOL (*)(id, SEL))invocation)(receiver, chainSelector);
    });
    method_setImplementation(chainMethod, (IMP)CVLPFixtureInterveningHook);
    BOOL chainPublished = CVLPHighlightsPublishForwarder(chainMethod, chainReplacement, &chainOriginal);
    if (!CVLPFixtureRequire(chainPublished && [[CVLPFixtureChain new] chainFlag] &&
        CVLPFixtureDisplacedCalls == 1, @"actual_displaced_hook_preserved", failure)) { return NO; }
    CVLPFixtureDiagnosticLines = [NSMutableArray array];
    CVLPFixtureConsumptionCalls = 0;
    CVLPFixtureCreationCalls = 0;
    CVLPFixtureGetterCalls = 0;
    CVLPFixtureMountCalls = 0;
    CVLPFixtureUpdateCalls = 0;
    CVLPFixtureHeightCalls = 0;
    CVLPFixtureConsumptionResult = NO;
    CVLPFixtureShouldThrowConsumption = NO;
    CVLPFixtureCreationResult = NO;
    CVLPFixtureShouldThrowCreation = NO;
    CVLPFixtureAlternateResult = NO;
    CVLPFixtureAlternateCalls = 0;
    CVLPFixtureHeightResult = 42.75;
    CVLPFixtureModelResult = [NSObject new];
    CVLPFixtureForwardedException = [NSException exceptionWithName:@"CVLPFixtureForwarded" reason:@"fixed" userInfo:nil];
    CVLPHighlightsState = (CVLPHighlightsHookState){ .lastConsumption = -1, .lastCreation = -1,
        .lastModelPresence = -1, .lastMount = -1, .lastUpdate = -1, .lastHeight = -1.0 };
    CVLPHighlightsRecording = YES;
    CVLPHighlightsStartedAt = CACurrentMediaTime();
#if CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
    atomic_store_explicit(&CVLPHighlightsEarlyStatusValue, CVLPHighlightsEarlyInstallFailed, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyDirectStatus, CVLPHighlightsDirectImageUnavailable, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyMatchCount, 0, memory_order_release);
    atomic_store_explicit(&CVLPHighlightsEarlyRetainedValue, 0, memory_order_release);
#endif

    // Exercise the same class-by-class core independently of the real image
    // iterator so failure causes are repeatable on a simulator and device.
    CVLPFixtureLookupContext lookupContext = { .now = 10.0 };
    Class uniqueClasses[] = { CVLPFixtureFeatureOwner.class };
    CVLPHighlightsClassMethodSearch uniqueSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", uniqueClasses, 1, lookupContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &lookupContext);
    if (!CVLPFixtureRequire(uniqueSearch.complete && uniqueSearch.matches == 1 &&
        uniqueSearch.owner == CVLPFixtureFeatureOwner.class && uniqueSearch.classes == 1,
        @"image_inventory_unique_owner", failure)) { return NO; }

    CVLPFixtureLookupContext missingAnchorContext = { .now = 10.0 };
    CVLPHighlightsClassMethodSearch missingAnchorSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), Nil, "/fixture/highlights-image",
        NULL, 0, missingAnchorContext.now, CVLPFixtureLookupClock,
        CVLPFixtureLookupImageName, &missingAnchorContext);
    if (!CVLPFixtureRequire(!missingAnchorSearch.complete &&
        missingAnchorSearch.reason == CVLPHighlightsLookupReasonMissingAnchor,
        @"missing_anchor_is_incomplete", failure)) { return NO; }

    NSUInteger incompleteMatches = 0;
    Method incompleteMethod = CVLPHighlightsDeclaredMethod(
        object_getClass(CVLPFixtureFeatureOwner.class),
        sel_registerName("enableStoryHighlightConsumption"), &incompleteMatches);
    IMP incompleteOriginal = method_getImplementation(incompleteMethod);
    CVLPHighlightsInstallStatus incompleteStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightConsumption"), CVLPHighlightsConsumptionTarget,
        Nil, NULL);
    if (!CVLPFixtureRequire(incompleteMatches == 1 && incompleteOriginal != NULL &&
        incompleteStatus == CVLPHighlightsInstallBoundedIncomplete &&
        method_getImplementation(incompleteMethod) == incompleteOriginal,
        @"incomplete_lookup_does_not_modify_implementation", failure)) { return NO; }

    CVLPFixtureLookupContext anchorNotEnumeratedContext = { .now = 10.0 };
    Class nonAnchorClasses[] = { CVLPFixtureAbsentTarget.class };
    CVLPHighlightsClassMethodSearch anchorNotEnumeratedSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", nonAnchorClasses, 1, anchorNotEnumeratedContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &anchorNotEnumeratedContext);
    if (!CVLPFixtureRequire(anchorNotEnumeratedSearch.reason ==
        CVLPHighlightsLookupReasonAnchorNotEnumerated && !anchorNotEnumeratedSearch.complete,
        @"inventory_must_contain_anchor", failure)) { return NO; }

    CVLPFixtureLookupContext missingImageContext = { .now = 10.0 };
    CVLPHighlightsClassMethodSearch missingImageSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        NULL, NULL, 0, missingImageContext.now, CVLPFixtureLookupClock,
        CVLPFixtureLookupImageName, &missingImageContext);
    if (!CVLPFixtureRequire(missingImageSearch.reason == CVLPHighlightsLookupReasonMissingImage,
        @"missing_anchor_image_is_incomplete", failure)) { return NO; }

    CVLPFixtureLookupContext capContext = { .now = 10.0 };
    CVLPHighlightsClassMethodSearch capSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", uniqueClasses, CVLPHighlightsMaximumClasses + 1,
        capContext.now, CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &capContext);
    if (!CVLPFixtureRequire(capSearch.reason == CVLPHighlightsLookupReasonClassLimit &&
        capSearch.classes == CVLPHighlightsMaximumClasses,
        @"image_inventory_limit_is_reported_and_clamped", failure)) { return NO; }

    CVLPFixtureLookupContext capAccumulatorContext = { .now = 10.0 };
    CVLPHighlightsClassMethodSearch capAccumulator = CVLPHighlightsClassSearchCreate(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", capAccumulatorContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &capAccumulatorContext);
    capAccumulator.classes = CVLPHighlightsMaximumClasses;
    if (!CVLPFixtureRequire(!CVLPHighlightsClassSearchObserve(&capAccumulator,
        CVLPFixtureFeatureOwner.class) && capAccumulator.reason == CVLPHighlightsLookupReasonClassLimit &&
        capAccumulator.classes == CVLPHighlightsMaximumClasses,
        @"runtime_class_callback_limit_is_clamped", failure)) { return NO; }

    CVLPFixtureLookupContext expiredContext = { .now = 11.0 };
    CVLPHighlightsClassMethodSearch expiredSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", uniqueClasses, 1, 10.0, CVLPFixtureLookupClock,
        CVLPFixtureLookupImageName, &expiredContext);
    if (!CVLPFixtureRequire(expiredSearch.reason == CVLPHighlightsLookupReasonDeadline &&
        expiredSearch.classes == 0, @"expired_inventory_stops_before_metadata", failure)) { return NO; }

    CVLPFixtureLookupContext metadataDeadlineContext = { .now = 10.0, .advancePerRead = 0.3 };
    CVLPHighlightsClassMethodSearch metadataDeadlineSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", uniqueClasses, 1, metadataDeadlineContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &metadataDeadlineContext);
    if (!CVLPFixtureRequire(metadataDeadlineSearch.reason == CVLPHighlightsLookupReasonDeadline &&
        metadataDeadlineSearch.classes == 1,
        @"metadata_copy_time_is_inside_deadline", failure)) { return NO; }

    CVLPFixtureLookupContext unresolvedContext = { .now = 10.0 };
    Class unresolvedClasses[] = { Nil };
    CVLPHighlightsClassMethodSearch unresolvedSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", unresolvedClasses, 1, unresolvedContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &unresolvedContext);
    if (!CVLPFixtureRequire(unresolvedSearch.reason == CVLPHighlightsLookupReasonInvalidClass,
        @"invalid_enumerated_class_fails_closed", failure)) { return NO; }

    CVLPFixtureLookupContext mismatchContext = {
        .now = 10.0, .mismatchedClass = CVLPFixtureAbsentTarget.class,
    };
    Class mismatchClasses[] = { CVLPFixtureFeatureOwner.class, CVLPFixtureAbsentTarget.class };
    CVLPHighlightsClassMethodSearch mismatchSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("enableStoryHighlightConsumption"), CVLPFixtureFeatureOwner.class,
        "/fixture/highlights-image", mismatchClasses, 2, mismatchContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &mismatchContext);
    if (!CVLPFixtureRequire(mismatchSearch.reason == CVLPHighlightsLookupReasonClassImageMismatch &&
        mismatchSearch.classes == 2, @"class_from_other_image_fails_closed", failure)) { return NO; }

    CVLPFixtureLookupContext inheritedContext = { .now = 10.0 };
    Class inheritedClasses[] = { CVLPFixtureInheritedClassMethodChild.class };
    CVLPHighlightsClassMethodSearch inheritedSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("inheritedFixtureClassMethod"), CVLPFixtureInheritedClassMethodChild.class,
        "/fixture/highlights-image", inheritedClasses, 1, inheritedContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &inheritedContext);
    if (!CVLPFixtureRequire(inheritedSearch.complete && inheritedSearch.matches == 0 &&
        inheritedSearch.owner == Nil, @"inherited_class_method_is_not_a_declaration", failure)) { return NO; }

    Class ambiguousClasses[] = { CVLPFixtureAmbiguousOwnerA.class, CVLPFixtureAmbiguousOwnerB.class };
    CVLPFixtureLookupContext ambiguousContext = { .now = 10.0 };
    CVLPHighlightsClassMethodSearch ambiguousSearch = CVLPHighlightsSearchProvidedClasses(
        sel_registerName("ambiguousFixtureClassMethod"), CVLPFixtureAmbiguousOwnerA.class,
        "/fixture/highlights-image", ambiguousClasses, 2, ambiguousContext.now,
        CVLPFixtureLookupClock, CVLPFixtureLookupImageName, &ambiguousContext);
    if (!CVLPFixtureRequire(ambiguousSearch.reason == CVLPHighlightsLookupReasonAmbiguous &&
        ambiguousSearch.matches == 2 && !ambiguousSearch.complete,
        @"same_image_duplicate_declarations_are_ambiguous", failure)) { return NO; }

    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE runtime-image-start\n");
    CVLPHighlightsClassMethodSearch consumptionSearch = {0};
    CVLPHighlightsInstallStatus consumptionStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightConsumption"), CVLPHighlightsConsumptionTarget,
        TTKProfileBizDataStoryHighlightInfoModel.class, &consumptionSearch);
    if (consumptionStatus != CVLPHighlightsInstallInstalled) {
        CVLPHighlightsClassMethodSearch retry = CVLPHighlightsFindClassMethod(
            sel_registerName("enableStoryHighlightConsumption"), TTKProfileBizDataStoryHighlightInfoModel.class);
        Method known = class_getClassMethod(CVLPFixtureFeatureOwner.class,
            @selector(enableStoryHighlightConsumption));
        fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_LOOKUP status=%d reason=%d classes=%lu retryComplete=%d retryMatches=%lu retryReason=%d retryClasses=%lu knownABI=%d\n",
            consumptionStatus, consumptionSearch.reason, (unsigned long)consumptionSearch.classes,
            retry.complete, (unsigned long)retry.matches, retry.reason, (unsigned long)retry.classes,
            CVLPHighlightsMethodHasExactSignature(known, "B"));
    }
    if (!CVLPFixtureRequire(consumptionStatus == CVLPHighlightsInstallInstalled, @"feature_owner_unique_hook", failure)) { return NO; }
    CVLPHighlightsInstallStatus creationStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightCreation"), CVLPHighlightsCreationTarget,
        TTKProfileBizDataStoryHighlightInfoModel.class, NULL);
    if (!CVLPFixtureRequire(creationStatus == CVLPHighlightsInstallInstalled, @"creation_hook", failure)) { return NO; }
    CVLPHighlightsInstallStatus alternateStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("alternateFeatureEligibility"), CVLPHighlightsConsumptionTarget,
        TTKProfileBizDataStoryHighlightInfoModel.class, NULL);
    if (!CVLPFixtureRequire(alternateStatus == CVLPHighlightsInstallInstalled,
        @"alternate_boolean_hook", failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE runtime-image-complete\n");

    SEL consumptionSelector = sel_registerName("enableStoryHighlightConsumption");
    SEL alternateSelector = sel_registerName("alternateFeatureEligibility");
    if (!CVLPFixtureRequire(
        CVLPHighlightsShouldOverrideConsumption(CVLPHighlightsConsumptionTarget, consumptionSelector) ==
            (CVLPHighlightsViewingExperimentMode == 1) &&
        !CVLPHighlightsShouldOverrideConsumption(CVLPHighlightsConsumptionTarget, alternateSelector) &&
        !CVLPHighlightsShouldOverrideConsumption(CVLPHighlightsCreationTarget, consumptionSelector),
        @"override_requires_exact_selector_and_target", failure)) { return NO; }

    errno = 0;
    BOOL alternateResult = [CVLPFixtureFeatureOwner alternateFeatureEligibility];
    if (!CVLPFixtureRequire(!alternateResult && CVLPFixtureAlternateCalls == 1 && errno == ERANGE &&
        CVLPHighlightsState.overrideCalls == 0, @"other_selector_remains_natural", failure)) { return NO; }
    CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] = 0;
    CVLPHighlightsState.lastConsumption = -1;

    if (!CVLPFixtureRequire(CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 0 &&
        CVLPHighlightsState.lastConsumption == -1, @"boolean_unknown_before_call", failure)) { return NO; }
    errno = 0;
    BOOL consumptionResult = [CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    if (!CVLPFixtureRequire(consumptionResult == (CVLPHighlightsViewingExperimentMode == 1) &&
        CVLPFixtureConsumptionCalls == 1 && errno == EDOM,
        @"boolean_false_natural_value_and_errno_forwarded_once", failure)) { return NO; }
    if (!CVLPFixtureRequire(CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 1 &&
        CVLPHighlightsState.lastConsumption == 0 &&
        CVLPHighlightsState.overrideCalls == (CVLPHighlightsViewingExperimentMode == 1 ? 1 : 0),
        @"boolean_false_natural_observation_distinct_from_delivery", failure)) { return NO; }

    CVLPFixtureConsumptionResult = YES;
    errno = 0;
    BOOL naturalTrueResult = [CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    if (!CVLPFixtureRequire(naturalTrueResult && CVLPFixtureConsumptionCalls == 2 && errno == EDOM &&
        CVLPHighlightsState.lastConsumption == 1 && CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 2 &&
        CVLPHighlightsState.overrideCalls == (CVLPHighlightsViewingExperimentMode == 1 ? 2 : 0),
        @"boolean_true_natural_value_and_observation_preserved", failure)) { return NO; }

    CVLPFixtureShouldThrowConsumption = YES;
    BOOL caughtConsumptionException = NO;
    @try {
        (void)[CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    } @catch (NSException *exception) {
        caughtConsumptionException = exception == CVLPFixtureForwardedException;
    }
    if (!CVLPFixtureRequire(caughtConsumptionException && CVLPFixtureConsumptionCalls == 3 &&
        CVLPHighlightsState.overrideCalls == (CVLPHighlightsViewingExperimentMode == 1 ? 2 : 0),
        @"consumption_original_exception_forwarded_without_override", failure)) { return NO; }
    CVLPFixtureShouldThrowConsumption = NO;
    CVLPFixtureConsumptionResult = NO;

    CVLPFixtureCreationResult = NO;
    errno = 0;
    BOOL creationFalse = [CVLPFixtureFeatureOwner enableStoryHighlightCreation];
    if (!CVLPFixtureRequire(!creationFalse && CVLPFixtureCreationCalls == 1 && errno == EILSEQ &&
        CVLPHighlightsState.lastCreation == 0 && CVLPHighlightsState.overrideCalls ==
            (CVLPHighlightsViewingExperimentMode == 1 ? 2 : 0),
        @"creation_false_unchanged_by_experiment", failure)) { return NO; }
    CVLPFixtureCreationResult = YES;
    errno = 0;
    BOOL creationTrue = [CVLPFixtureFeatureOwner enableStoryHighlightCreation];
    if (!CVLPFixtureRequire(creationTrue && CVLPFixtureCreationCalls == 2 && errno == EILSEQ &&
        CVLPHighlightsState.lastCreation == 1 && CVLPHighlightsState.overrideCalls ==
            (CVLPHighlightsViewingExperimentMode == 1 ? 2 : 0),
        @"creation_true_unchanged_by_experiment", failure)) { return NO; }
    CVLPFixtureShouldThrowCreation = YES;
    BOOL caughtOriginalException = NO;
    @try {
        (void)[CVLPFixtureFeatureOwner enableStoryHighlightCreation];
    } @catch (NSException *exception) {
        caughtOriginalException = exception == CVLPFixtureForwardedException;
    }
    if (!CVLPFixtureRequire(caughtOriginalException && CVLPFixtureCreationCalls == 3 &&
        CVLPHighlightsState.counts[CVLPHighlightsCreationTarget] == 2 &&
        CVLPHighlightsState.overrideCalls == (CVLPHighlightsViewingExperimentMode == 1 ? 2 : 0),
        @"original_exception_forwarded", failure)) { return NO; }
    CVLPFixtureShouldThrowCreation = NO;

    Class modelClass = objc_getClass("TTKProfileBizDataStoryHighlightInfoModel");
    CVLPHighlightsInstallStatus modelStatus = CVLPHighlightsInstallInstance(
        modelClass, sel_registerName("storyHighlightInfo"), "@", CVLPHighlightsModelTarget);
    if (!CVLPFixtureRequire(modelStatus == CVLPHighlightsInstallInstalled, @"model_object_hook", failure)) { return NO; }
    id expected = CVLPFixtureModelResult;
    id presentInfo = [(TTKProfileBizDataStoryHighlightInfoModel *)[modelClass new] storyHighlightInfo];
    if (!CVLPFixtureRequire(presentInfo == expected && CVLPFixtureGetterCalls == 1 &&
        CVLPHighlightsState.counts[CVLPHighlightsModelTarget] == 1 &&
        CVLPHighlightsState.lastModelPresence == 1, @"model_presence_without_extra_getter", failure)) { return NO; }
    CVLPFixtureModelResult = nil;
    id absentInfo = [(TTKProfileBizDataStoryHighlightInfoModel *)[modelClass new] storyHighlightInfo];
    if (!CVLPFixtureRequire(absentInfo == nil && CVLPFixtureGetterCalls == 2 &&
        CVLPHighlightsState.counts[CVLPHighlightsModelTarget] == 2 &&
        CVLPHighlightsState.lastModelPresence == 0, @"model_nil_distinct_from_unknown", failure)) { return NO; }

    Class wrongClass = CVLPFixtureWrongModel.class;
    Method wrongMethod = class_getInstanceMethod(wrongClass, sel_registerName("storyHighlightInfo"));
    IMP wrongOriginal = method_getImplementation(wrongMethod);
    CVLPHighlightsInstallStatus wrongStatus = CVLPHighlightsInstallInstance(
        wrongClass, sel_registerName("storyHighlightInfo"), "@", CVLPHighlightsModelTarget);
    if (!CVLPFixtureRequire(wrongStatus == CVLPHighlightsInstallWrongABI &&
        method_getImplementation(wrongMethod) == wrongOriginal, @"wrong_abi_not_modified", failure)) { return NO; }
    CVLPHighlightsInstallStatus absentInstanceStatus = CVLPHighlightsInstallInstance(
        CVLPFixtureResolverTrap.class, sel_registerName("missingFixtureMethod"), "v", CVLPHighlightsMountTarget);
    CVLPHighlightsInstallStatus absentClassStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("missingFixtureClassMethod"), CVLPHighlightsConsumptionTarget,
        CVLPFixtureResolverTrap.class, NULL);
    if (!CVLPFixtureRequire(absentInstanceStatus == CVLPHighlightsInstallNotFound &&
        absentClassStatus == CVLPHighlightsInstallNotFound, @"absent_targets_report_not_found", failure)) { return NO; }
    NSUInteger absentDeclarations = 0;
    (void)CVLPHighlightsDeclaredMethod(CVLPFixtureResolverTrap.class,
        sel_registerName("missingFixtureMethod"), &absentDeclarations);
    if (!CVLPFixtureRequire(CVLPFixtureResolverCalls == 0 && absentDeclarations == 0,
        @"discovery_never_invokes_resolvers", failure)) { return NO; }

    Class inheritedClass = objc_getClass("TTKProfileStoryHighlightComponent");
    Method inheritedOriginal = class_getInstanceMethod(CVLPFixtureMountBase.class, sel_registerName("componentMount"));
    IMP inheritedIMP = method_getImplementation(inheritedOriginal);
    CVLPHighlightsInstallStatus inheritedStatus = CVLPHighlightsInstallInstance(
        inheritedClass, sel_registerName("componentMount"), "v", CVLPHighlightsMountTarget);
    if (!CVLPFixtureRequire(inheritedStatus == CVLPHighlightsInstallInherited &&
        method_getImplementation(inheritedOriginal) == inheritedIMP, @"inherited_method_not_modified", failure)) { return NO; }
    [(TTKProfileStoryHighlightComponent *)[inheritedClass new] componentMount];
    if (!CVLPFixtureRequire(CVLPFixtureMountCalls == 1 &&
        CVLPHighlightsState.counts[CVLPHighlightsMountTarget] == 0, @"inherited_call_unobserved", failure)) { return NO; }

    Class collectionClass = objc_getClass("TTKProfileStoryHighlightCollectionComponent");
    CVLPHighlightsInstallStatus updateStatus = CVLPHighlightsInstallInstance(
        collectionClass, sel_registerName("updateUI"), "v", CVLPHighlightsUpdateTarget);
    CVLPHighlightsInstallStatus heightStatus = CVLPHighlightsInstallInstance(
        collectionClass, sel_registerName("viewHeight"), "d", CVLPHighlightsHeightTarget);
    if (!CVLPFixtureRequire(updateStatus == CVLPHighlightsInstallInstalled &&
        heightStatus == CVLPHighlightsInstallInstalled, @"collection_hooks", failure)) { return NO; }
    TTKProfileStoryHighlightCollectionComponent *collection = [collectionClass new];
    [collection updateUI];
    double firstHeight = [collection viewHeight];
    if (!CVLPFixtureRequire(CVLPFixtureUpdateCalls == 1 && CVLPFixtureHeightCalls == 1 &&
        firstHeight == 42.75 && CVLPHighlightsState.counts[CVLPHighlightsUpdateTarget] == 1 &&
        CVLPHighlightsState.counts[CVLPHighlightsHeightTarget] == 1 &&
        CVLPHighlightsState.lastHeight == 42.75, @"collection_forwarded_once_and_height_recorded", failure)) { return NO; }
    CVLPFixtureHeightResult = NAN;
    double nanHeight = [collection viewHeight];
    if (!CVLPFixtureRequire(isnan(nanHeight) && CVLPFixtureHeightCalls == 2 &&
        CVLPHighlightsState.counts[CVLPHighlightsHeightTarget] == 2 &&
        CVLPHighlightsState.lastHeight == 42.75, @"nonfinite_height_return_preserved_and_not_recorded", failure)) { return NO; }

    SEL ambiguousSelector = sel_registerName("ambiguousFixtureClassMethod");
    NSUInteger ambiguousMatchesA = 0;
    NSUInteger ambiguousMatchesB = 0;
    Method ambiguousMethodA = CVLPHighlightsDeclaredMethod(
        object_getClass(CVLPFixtureAmbiguousOwnerA.class), ambiguousSelector, &ambiguousMatchesA);
    Method ambiguousMethodB = CVLPHighlightsDeclaredMethod(
        object_getClass(CVLPFixtureAmbiguousOwnerB.class), ambiguousSelector, &ambiguousMatchesB);
    IMP ambiguousOriginalA = method_getImplementation(ambiguousMethodA);
    IMP ambiguousOriginalB = method_getImplementation(ambiguousMethodB);
    CVLPHighlightsClassMethodSearch runtimeAmbiguousSearch = {0};
    CVLPHighlightsInstallStatus ambiguousStatus = CVLPHighlightsInstallClassBoolean(
        ambiguousSelector, CVLPHighlightsConsumptionTarget, CVLPFixtureFeatureOwner.class,
        &runtimeAmbiguousSearch);
    if (!CVLPFixtureRequire(ambiguousStatus == CVLPHighlightsInstallAmbiguous &&
        runtimeAmbiguousSearch.reason == CVLPHighlightsLookupReasonAmbiguous &&
        runtimeAmbiguousSearch.matches > 1 &&
        method_getImplementation(ambiguousMethodA) == ambiguousOriginalA &&
        method_getImplementation(ambiguousMethodB) == ambiguousOriginalB,
        @"runtime_image_ambiguity_does_not_modify_either_owner", failure)) { return NO; }

    CVLPHighlightsRecording = YES;
    CVLPHighlightsStartedAt = CACurrentMediaTime();
    CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] = CVLPHighlightsCountMaximum;
    (void)[CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    if (!CVLPFixtureRequire(CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] ==
        CVLPHighlightsCountMaximum, @"counter_saturates", failure)) { return NO; }
    CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] = 9;
    CVLPHighlightsStartedAt = CACurrentMediaTime() - CVLPHighlightsDeadline - 1.0;
    (void)[CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    if (!CVLPFixtureRequire(!CVLPHighlightsRecording &&
        CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 9,
        @"late_hook_disables_recording", failure)) { return NO; }

    CVLPHighlightsRecording = NO;
    uint16_t beforeStoppedCount = CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget];
    uint16_t beforeStoppedOverrideCalls = CVLPHighlightsState.overrideCalls;
    BOOL stoppedConsumptionResult = [CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    [(TTKProfileBizDataStoryHighlightInfoModel *)[modelClass new] storyHighlightInfo];
    [collection updateUI];
    (void)[collection viewHeight];
    if (!CVLPFixtureRequire(stoppedConsumptionResult == (CVLPHighlightsViewingExperimentMode == 1) &&
        CVLPHighlightsState.overrideCalls == beforeStoppedOverrideCalls &&
        CVLPFixtureConsumptionCalls == 6 && CVLPFixtureGetterCalls == 3 &&
        CVLPFixtureUpdateCalls == 2 && CVLPFixtureHeightCalls == 3 &&
        CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == beforeStoppedCount,
        @"stopped_recording_freezes_count_but_experiment_delivery_continues", failure)) { return NO; }

    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE forwarding-complete\n");
    if (!CVLPHighlightsDirectRunFixture(failure)) { return NO; }
    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE direct-complete\n");
#if defined(CVLP_HIGHLIGHTS_TESTING)
    if (!CVLPAdmissionRunFixtureCases(failure)) { return NO; }
    fprintf(stderr, "CV_ADMISSION_METADATA_FIXTURE_PASS\n");
#endif
    [CVLPFixtureDiagnosticLines removeAllObjects];
    CVLPHighlightsState.directLast = -1;
    CVLPHighlightsState.directCalls = CVLPHighlightsState.directOverrideCalls = 0;
    CVLPHighlightsState.directStatus = CVLPHighlightsDirectViewingExperimentMode ?
        CVLPHighlightsDirectImageUnavailable : CVLPHighlightsDirectDisabled;
    CVLPHighlightsObserver *lineObserver = [CVLPHighlightsObserver new];
    lineObserver->_startedAt = CACurrentMediaTime();
    lineObserver->_installStatuses[0] = CVLPHighlightsInstallInstalled;
    CVLPHighlightsTreeSummary tree = CVLPHighlightsEmptyTree();
    [lineObserver appendLineForPhase:@"start" sequence:0 reason:-1 tree:tree];
    for (NSUInteger sample = 1; sample <= CVLPHighlightsMaximumSamples; sample++) {
        [lineObserver appendLineForPhase:@"sample" sequence:sample reason:-1 tree:tree];
    }
    if (!CVLPFixtureRequire(lineObserver->_eventCount == 25 && CVLPFixtureDiagnosticLines.count == 25,
        @"bounded_samples_before_terminal", failure)) { return NO; }
    [lineObserver stopWithReason:CVLPHighlightsStopDeadline];
    [lineObserver stopWithReason:CVLPHighlightsStopBackground];
    [lineObserver appendLineForPhase:@"sample" sequence:25 reason:-1 tree:tree];
    if (!CVLPFixtureRequire(lineObserver->_eventCount == CVLPHighlightsMaximumEvents &&
        CVLPFixtureDiagnosticLines.count == CVLPHighlightsMaximumEvents &&
        [CVLPFixtureDiagnosticLines.lastObject containsString:@"phase=stopped"],
        @"terminal_line_bound_and_no_post_stop_emit", failure)) { return NO; }
    for (NSString *line in CVLPFixtureDiagnosticLines) {
        if (!CVLPFixtureRequire(CVLPHighlightsLineIsSanitized(line), @"diagnostic_schema", failure)) { return NO; }
    }
    NSString *validLine = CVLPFixtureDiagnosticLines.firstObject;
    NSString *lastConsumptionField = [NSString stringWithFormat:@"l0=%d", CVLPHighlightsState.lastConsumption];
    NSString *arbitraryText = [validLine stringByReplacingOccurrencesOfString:lastConsumptionField withString:@"l0=secret"];
    NSString *extraField = [validLine stringByAppendingString:@" private=1"];
    NSString *nonfiniteFloat = [validLine stringByReplacingOccurrencesOfString:@"l5=42.75" withString:@"l5=nan"];
    NSString *overflowFloat = [validLine stringByReplacingOccurrencesOfString:@"alpha=-1" withString:@"alpha=1e999"];
    NSString *missingField = [validLine stringByReplacingOccurrencesOfString:@" classes1=0" withString:@""];
    NSString *reorderedFields = [validLine stringByReplacingOccurrencesOfString:
        @"scope=1 why0=0" withString:@"why0=0 scope=1"];
    NSString *wrongScope = [validLine stringByReplacingOccurrencesOfString:@"scope=1" withString:@"scope=2"];
    NSString *largeReason = [validLine stringByReplacingOccurrencesOfString:@"why0=0" withString:@"why0=10"];
    NSString *negativeReason = [validLine stringByReplacingOccurrencesOfString:@"why0=0" withString:@"why0=-1"];
    NSString *largeClassCount = [validLine stringByReplacingOccurrencesOfString:@"classes0=0" withString:@"classes0=100001"];
    NSString *negativeClassCount = [validLine stringByReplacingOccurrencesOfString:@"classes0=0" withString:@"classes0=-1"];
    NSString *maximumClassCount = [validLine stringByReplacingOccurrencesOfString:@"classes0=0" withString:@"classes0=100000"];
    NSString *expectedMode = [NSString stringWithFormat:@"mode=%d", CVLPHighlightsViewingExperimentMode];
    NSString *wrongMode = [validLine stringByReplacingOccurrencesOfString:expectedMode
        withString:[NSString stringWithFormat:@"mode=%d", CVLPHighlightsViewingExperimentMode == 0 ? 1 : 0]];
    NSString *overrideCallsField = [NSString stringWithFormat:@"overrideCalls=%u", (unsigned int)CVLPHighlightsState.overrideCalls];
    NSString *negativeOverrideCalls = [validLine stringByReplacingOccurrencesOfString:overrideCallsField
        withString:@"overrideCalls=-1"];
    NSString *largeOverrideCalls = [validLine stringByReplacingOccurrencesOfString:overrideCallsField
        withString:@"overrideCalls=65536"];
    NSString *maximumOverrideCalls = [validLine stringByReplacingOccurrencesOfString:overrideCallsField
        withString:@"overrideCalls=65535"];
    NSString *disabledModeOverrideCalls = [validLine stringByReplacingOccurrencesOfString:expectedMode
        withString:@"mode=0"];
    disabledModeOverrideCalls = [disabledModeOverrideCalls stringByReplacingOccurrencesOfString:overrideCallsField
        withString:@"overrideCalls=1"];
    if (!CVLPFixtureRequire(!CVLPHighlightsLineIsSanitized(arbitraryText) &&
        !CVLPHighlightsLineIsSanitized(extraField) && !CVLPHighlightsLineIsSanitized(nonfiniteFloat) &&
        !CVLPHighlightsLineIsSanitized(overflowFloat) && !CVLPHighlightsLineIsSanitized(missingField) &&
        !CVLPHighlightsLineIsSanitized(reorderedFields) && !CVLPHighlightsLineIsSanitized(wrongScope) &&
        !CVLPHighlightsLineIsSanitized(largeReason) && !CVLPHighlightsLineIsSanitized(negativeReason) &&
        !CVLPHighlightsLineIsSanitized(largeClassCount) && !CVLPHighlightsLineIsSanitized(negativeClassCount) &&
        !CVLPHighlightsLineIsSanitized(wrongMode) &&
        !CVLPHighlightsLineIsSanitized(negativeOverrideCalls) &&
        !CVLPHighlightsLineIsSanitized(largeOverrideCalls) &&
        !CVLPHighlightsLineIsSanitized(disabledModeOverrideCalls) &&
        CVLPHighlightsLineIsSanitized(maximumClassCount) &&
        CVLPHighlightsLineIsSanitized(maximumOverrideCalls) == (CVLPHighlightsViewingExperimentMode == 1),
        @"sanitizer_enforces_scope_mode_and_numeric_bounds", failure)) { return NO; }
    NSString *directModeField = [NSString stringWithFormat:@"directMode=%d", CVLPHighlightsDirectViewingExperimentMode];
    NSString *wrongDirectMode = [validLine stringByReplacingOccurrencesOfString:directModeField
        withString:[NSString stringWithFormat:@"directMode=%d", !CVLPHighlightsDirectViewingExperimentMode]];
    NSString *directStatusField = [NSString stringWithFormat:@"directStatus=%d", CVLPHighlightsState.directStatus];
    NSArray<NSString *> *badDirectLines = @[
        wrongDirectMode,
        [validLine stringByReplacingOccurrencesOfString:directStatusField withString:@"directStatus=12"],
        [validLine stringByReplacingOccurrencesOfString:@"directCalls=0" withString:@"directCalls=-1"],
        [validLine stringByReplacingOccurrencesOfString:@"directCalls=0" withString:@"directCalls=65536"],
        [validLine stringByReplacingOccurrencesOfString:@"directLast=-1" withString:@"directLast=2"],
        [validLine stringByReplacingOccurrencesOfString:@"directLast=-1" withString:@"directLast=0"],
        [validLine stringByReplacingOccurrencesOfString:@"directOverrideCalls=0" withString:@"directOverrideCalls=1"],
    ];
    for (NSString *badLine in badDirectLines) {
        if (!CVLPFixtureRequire(!CVLPHighlightsLineIsSanitized(badLine),
            @"direct_schema_rejects_mode_status_counts_and_unknown_mismatch", failure)) { return NO; }
    }
#if CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT
    CVLPHighlightsState.directStatus = CVLPHighlightsDirectInstalled;
    CVLPHighlightsState.directCalls = CVLPHighlightsState.directOverrideCalls = 2;
    CVLPHighlightsState.directLast = 0;
    CVLPHighlightsObserver *directLineObserver = [CVLPHighlightsObserver new];
    directLineObserver->_startedAt = CACurrentMediaTime();
    [directLineObserver appendLineForPhase:@"sample" sequence:1 reason:-1 tree:tree];
    NSString *directLine = CVLPFixtureDiagnosticLines.lastObject;
    if (!CVLPFixtureRequire(directLineObserver->_eventCount == 1 && CVLPHighlightsLineIsSanitized(directLine) &&
        [directLine containsString:@"directMode=1 directStatus=1 directCalls=2 directLast=0 directOverrideCalls=2"],
        @"direct_emitted_line_retains_original_false_distinct_from_delivery", failure)) { return NO; }
#endif
#if CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT
    if (!CVLPEarlyLoaderRunFixture(failure)) { return NO; }
#endif
    return YES;
}

int main(void) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE main\n");
    @autoreleasepool {
        // A short-lived simulator process can finish before console capture is
        // attached. Persist only a fixed test result, never application content.
        const char *resultNameBytes = getenv("CV_HIGHLIGHTS_RESULT_NAME");
        NSString *resultName = resultNameBytes ? [NSString stringWithUTF8String:resultNameBytes] : nil;
        NSCharacterSet *nameCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."];
        if (resultName.length == 0 || resultName.length > 100 ||
            ![resultName hasPrefix:@"cv-highlights-"] ||
            [resultName rangeOfCharacterFromSet:nameCharacters.invertedSet].location != NSNotFound) {
            fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_FAIL result_name\n");
            return 1;
        }
        NSString *resultPath = [NSTemporaryDirectory() stringByAppendingPathComponent:resultName];
        NSString *failure = nil;
        if (![CVLPHighlightsDiagnostics runFixtureSelfTest:&failure]) {
            fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_FAIL %s\n", failure.UTF8String ?: "unknown");
            [@"CV_HIGHLIGHTS_FIXTURE_FAIL\n" writeToFile:resultPath atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
            return 1;
        }
        NSString *result = [NSString stringWithFormat:@"CV_HIGHLIGHTS_FIXTURE_PASS viewing=%d direct=%d early=%d admission=%d\n",
            CVLPHighlightsViewingExperimentMode, CVLPHighlightsDirectViewingExperimentMode,
            CVLPHighlightsEarlyViewingExperimentMode, CVLP_HIGHLIGHTS_ADMISSION_METADATA];
        if (![result writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_FAIL result_write\n");
            return 1;
        }
        printf("CV_HIGHLIGHTS_FIXTURE_PASS\n");
        return 0;
    }
}
