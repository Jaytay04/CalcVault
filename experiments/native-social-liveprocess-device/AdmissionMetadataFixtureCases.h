#ifndef CVLP_ADMISSION_METADATA_FIXTURE_CASES_H
#define CVLP_ADMISSION_METADATA_FIXTURE_CASES_H

#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

// These classes are disposable runtime fixtures. Their methods only increment
// a counter; discovery must inspect metadata without invoking any implementation.
static NSUInteger CVLPAdmissionFixtureMethodCalls;

@interface CVLPAdmissionFixtureInstanceOwner : NSObject
- (int32_t)cvlpAdmissionFixtureInstanceMethod;
@end

@implementation CVLPAdmissionFixtureInstanceOwner
- (int32_t)cvlpAdmissionFixtureInstanceMethod {
    CVLPAdmissionFixtureMethodCalls++;
    return 7;
}
@end

@interface CVLPAdmissionFixtureMetaclassOwner : NSObject
+ (double)cvlpAdmissionFixtureMetaclassMethod;
@end

@implementation CVLPAdmissionFixtureMetaclassOwner
+ (double)cvlpAdmissionFixtureMetaclassMethod {
    CVLPAdmissionFixtureMethodCalls++;
    return 9.0;
}
@end

typedef struct { uint32_t value; } CVLPAdmissionFixtureOpaqueValue;

@interface CVLPAdmissionFixtureUnknownABI : NSObject
- (CVLPAdmissionFixtureOpaqueValue)cvlpAdmissionFixtureUnknownABI;
@end

@implementation CVLPAdmissionFixtureUnknownABI
- (CVLPAdmissionFixtureOpaqueValue)cvlpAdmissionFixtureUnknownABI {
    CVLPAdmissionFixtureMethodCalls++;
    return (CVLPAdmissionFixtureOpaqueValue){ .value = 17 };
}
@end

@interface CVLPAdmissionFixtureInheritedBase : NSObject
- (int32_t)cvlpAdmissionFixtureInheritedMethod;
@end

@implementation CVLPAdmissionFixtureInheritedBase
- (int32_t)cvlpAdmissionFixtureInheritedMethod {
    CVLPAdmissionFixtureMethodCalls++;
    return 11;
}
@end

@interface CVLPAdmissionFixtureInheritedChild : CVLPAdmissionFixtureInheritedBase
@end

@implementation CVLPAdmissionFixtureInheritedChild
@end

@interface CVLPAdmissionFixtureDuplicateA : NSObject
- (int32_t)cvlpAdmissionFixtureDuplicateMethod;
@end

@implementation CVLPAdmissionFixtureDuplicateA
- (int32_t)cvlpAdmissionFixtureDuplicateMethod {
    CVLPAdmissionFixtureMethodCalls++;
    return 13;
}
@end

@interface CVLPAdmissionFixtureDuplicateB : NSObject
+ (void)cvlpAdmissionFixtureDuplicateMethod;
@end

@implementation CVLPAdmissionFixtureDuplicateB
+ (void)cvlpAdmissionFixtureDuplicateMethod {
    CVLPAdmissionFixtureMethodCalls++;
}
@end

typedef struct {
    uint8_t imageBytes[sizeof(struct mach_header_64) + CVLPHighlightsDirectExpectedCommandBytes];
    uint8_t functionBytes[CVLPAdmissionFunctionLength];
    uintptr_t base;
    uintptr_t classReference;
    uintptr_t selectorReferences[CVLPAdmissionSelectorCount];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    vm_prot_t headerProtection;
    vm_prot_t dataProtection;
    vm_prot_t codeProtection;
    BOOL rejectMapping;
    BOOL rejectRead;
    BOOL mutateSelectorOnRead;
    NSUInteger selectorReadCount[CVLPAdmissionSelectorCount];
    NSUInteger mutateSelectorAtRead;
    NSUInteger CASCalls;
} CVLPAdmissionFixtureMemory;

typedef struct {
    CFTimeInterval now;
    CFTimeInterval advancePerClock;
    Class mismatchedClass;
} CVLPAdmissionFixtureRuntimeContext;

static struct section_64 *CVLPAdmissionFixtureSection(CVLPAdmissionFixtureMemory *fixture,
    NSUInteger sectionIndex) {
    uint8_t *cursor = fixture->imageBytes + sizeof(struct mach_header_64) +
        sizeof(struct uuid_command) + sizeof(struct segment_command_64) + sizeof(struct segment_command_64);
    return (struct section_64 *)(cursor + (sectionIndex * sizeof(struct section_64)));
}

static void CVLPAdmissionFixtureInitialize(CVLPAdmissionFixtureMemory *fixture) {
    memset(fixture, 0, sizeof(*fixture));
    fixture->base = 0x100000000ULL;
    fixture->headerProtection = VM_PROT_READ;
    fixture->dataProtection = VM_PROT_READ | VM_PROT_WRITE;
    fixture->codeProtection = VM_PROT_READ | VM_PROT_EXECUTE;
    fixture->classReference = fixture->base + CVLPAdmissionFunctionVM;
    fixture->selectorReferences[0] = (uintptr_t)@selector(cvlpAdmissionFixtureInstanceMethod);
    fixture->selectorReferences[1] = (uintptr_t)@selector(cvlpAdmissionFixtureMetaclassMethod);
    fixture->selectorReferences[2] = (uintptr_t)@selector(cvlpAdmissionFixtureDuplicateMethod);
    for (NSUInteger index = 0; index < sizeof(fixture->functionBytes); index++) {
        fixture->functionBytes[index] = (uint8_t)((index * 37U) + 19U);
    }
    CC_SHA256(fixture->functionBytes, (CC_LONG)sizeof(fixture->functionBytes), fixture->digest);

    struct mach_header_64 header = {
        .magic = MH_MAGIC_64,
        .cputype = CPU_TYPE_ARM64,
        .cpusubtype = CPU_SUBTYPE_ARM64_ALL,
        .filetype = MH_DYLIB,
        .ncmds = CVLPHighlightsDirectExpectedCommandCount,
        .sizeofcmds = CVLPHighlightsDirectExpectedCommandBytes,
    };
    memcpy(fixture->imageBytes, &header, sizeof(header));
    uint8_t *cursor = fixture->imageBytes + sizeof(header);

    struct uuid_command uuid = { .cmd = LC_UUID, .cmdsize = sizeof(uuid) };
    memcpy(uuid.uuid, CVLPHighlightsDirectExpectedUUID, sizeof(uuid.uuid));
    memcpy(cursor, &uuid, sizeof(uuid)); cursor += sizeof(uuid);

    struct segment_command_64 text = {
        .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(text),
        .vmaddr = 0,
        .vmsize = CVLPHighlightsDirectTextVMSize,
        .fileoff = 0,
        .filesize = sizeof(fixture->imageBytes),
        .maxprot = VM_PROT_READ | VM_PROT_EXECUTE,
        .initprot = VM_PROT_READ | VM_PROT_EXECUTE,
    };
    memcpy(text.segname, "__TEXT", 7);
    memcpy(cursor, &text, sizeof(text)); cursor += sizeof(text);

    struct segment_command_64 data = {
        .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(data) + (2 * sizeof(struct section_64)),
        .vmaddr = CVLPHighlightsDirectDataVM,
        .vmsize = CVLPHighlightsDirectDataVMSize,
        .filesize = CVLPHighlightsDirectDataFileSize,
        .maxprot = VM_PROT_READ | VM_PROT_WRITE,
        .initprot = VM_PROT_READ | VM_PROT_WRITE,
        .nsects = 2,
    };
    memcpy(data.segname, "__DATA", 7);
    memcpy(cursor, &data, sizeof(data)); cursor += sizeof(data);

    struct section_64 classRefs = {
        .addr = CVLPHighlightsDirectClassRefsVM,
        .size = CVLPHighlightsDirectClassRefsSize,
    };
    memcpy(classRefs.sectname, "__objc_clsrefs", 15);
    memcpy(classRefs.segname, "__DATA", 7);
    memcpy(cursor, &classRefs, sizeof(classRefs)); cursor += sizeof(classRefs);

    struct section_64 selectorRefs = {
        .addr = CVLPAdmissionSelectorSectionVM,
        .size = CVLPAdmissionSelectorSectionSize,
        .offset = 0,
        .align = 3,
        .flags = S_ZEROFILL,
    };
    memcpy(selectorRefs.sectname, "_D_objc_selrefs", 16);
    memcpy(selectorRefs.segname, "__DATA", 7);
    memcpy(cursor, &selectorRefs, sizeof(selectorRefs)); cursor += sizeof(selectorRefs);

    struct segment_command_64 executable = {
        .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(executable),
        .vmaddr = CVLPHighlightsDirectExecutableVM,
        .vmsize = CVLPHighlightsDirectExecutableVMSize,
        .maxprot = VM_PROT_READ | VM_PROT_EXECUTE,
        .initprot = VM_PROT_READ | VM_PROT_EXECUTE,
    };
    memcpy(executable.segname, "__BD_TEXT", 10);
    memcpy(cursor, &executable, sizeof(executable)); cursor += sizeof(executable);

    for (NSUInteger index = 4; index < CVLPHighlightsDirectExpectedCommandCount; index++) {
        struct load_command filler = { .cmd = 0, .cmdsize = sizeof(filler) };
        if (index == CVLPHighlightsDirectExpectedCommandCount - 1) {
            filler.cmdsize = (uint32_t)(fixture->imageBytes + sizeof(fixture->imageBytes) - cursor);
        }
        memcpy(cursor, &filler, sizeof(filler));
        cursor += filler.cmdsize;
    }
}

static BOOL CVLPAdmissionFixtureAddress(uintptr_t base, uint64_t vmAddress, uintptr_t *address) {
    return CVLPHighlightsDirectAddress(base, vmAddress, address);
}

static BOOL CVLPAdmissionFixtureRegionAllows(uintptr_t address, size_t length,
    vm_prot_t required, vm_prot_t forbidden, void *opaque) {
    CVLPAdmissionFixtureMemory *fixture = opaque;
    if (fixture == NULL || fixture->rejectMapping) { return NO; }
    vm_prot_t protection = 0;
    if (CVLPHighlightsDirectRangeContains(fixture->base, sizeof(fixture->imageBytes), address, length)) {
        protection = fixture->headerProtection;
    } else {
        uintptr_t functionAddress = 0;
        uintptr_t classSlot = 0;
        if (CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionFunctionVM, &functionAddress) &&
            CVLPHighlightsDirectRangeContains(functionAddress, sizeof(fixture->functionBytes), address, length)) {
            protection = fixture->codeProtection;
        } else if (CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionClassRefSlotVM, &classSlot) &&
            CVLPHighlightsDirectRangeContains(classSlot, sizeof(uintptr_t), address, length)) {
            protection = fixture->dataProtection;
        } else {
            for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
                uintptr_t selectorSlot = 0;
                if (CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionSelectorRefVM[index], &selectorSlot) &&
                    CVLPHighlightsDirectRangeContains(selectorSlot, sizeof(uintptr_t), address, length)) {
                    protection = fixture->dataProtection;
                    break;
                }
            }
        }
    }
    return (protection & required) == required && (protection & forbidden) == 0;
}

static BOOL CVLPAdmissionFixtureRead(uintptr_t address, void *destination, size_t length, void *opaque) {
    CVLPAdmissionFixtureMemory *fixture = opaque;
    if (fixture == NULL || destination == NULL || fixture->rejectRead) { return NO; }
    if (CVLPHighlightsDirectRangeContains(fixture->base, sizeof(fixture->imageBytes), address, length)) {
        memcpy(destination, fixture->imageBytes + (address - fixture->base), length);
        return YES;
    }
    uintptr_t location = 0;
    if (CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionClassRefSlotVM, &location) &&
        address == location && length == sizeof(uintptr_t)) {
        memcpy(destination, &fixture->classReference, length);
        return YES;
    }
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        if (!CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionSelectorRefVM[index], &location) ||
            address != location || length != sizeof(uintptr_t)) { continue; }
        fixture->selectorReadCount[index]++;
        if (fixture->mutateSelectorOnRead &&
            fixture->selectorReadCount[index] == fixture->mutateSelectorAtRead) {
            fixture->selectorReferences[index] += 0x100;
        }
        memcpy(destination, &fixture->selectorReferences[index], length);
        return YES;
    }
    if (CVLPAdmissionFixtureAddress(fixture->base, CVLPAdmissionFunctionVM, &location) &&
        address == location && length == sizeof(fixture->functionBytes)) {
        memcpy(destination, fixture->functionBytes, length);
        return YES;
    }
    return NO;
}

static BOOL CVLPAdmissionFixtureCompareExchange(uintptr_t address, uintptr_t expected,
    uintptr_t replacement, void *opaque) {
    (void)address; (void)expected; (void)replacement;
    CVLPAdmissionFixtureMemory *fixture = opaque;
    if (fixture != NULL) { fixture->CASCalls++; }
    return NO;
}

static CVLPHighlightsDirectMemory CVLPAdmissionFixtureMemoryInterface(CVLPAdmissionFixtureMemory *fixture) {
    return (CVLPHighlightsDirectMemory){
        .regionAllows = CVLPAdmissionFixtureRegionAllows,
        .read = CVLPAdmissionFixtureRead,
        .compareExchange = CVLPAdmissionFixtureCompareExchange,
        .context = fixture,
    };
}

static CFTimeInterval CVLPAdmissionFixtureClock(void *opaque) {
    CVLPAdmissionFixtureRuntimeContext *context = opaque;
    CFTimeInterval value = context->now;
    context->now += context->advancePerClock;
    return value;
}

static const char *CVLPAdmissionFixtureImageName(Class cls, void *opaque) {
    CVLPAdmissionFixtureRuntimeContext *context = opaque;
    if (context != NULL && cls == context->mismatchedClass) { return "/fixture/other-image"; }
    return "/fixture/admission-image";
}

static CVLPAdmissionRuntimeCallbacks CVLPAdmissionFixtureCallbacks(
    CVLPAdmissionFixtureRuntimeContext *context) {
    return (CVLPAdmissionRuntimeCallbacks){
        .clock = CVLPAdmissionFixtureClock,
        .imageName = CVLPAdmissionFixtureImageName,
        .context = context,
        .deadlineAt = 0.0,
    };
}

static void CVLPAdmissionFixtureSnapshotSlots(CVLPAdmissionFixtureMemory *fixture, uintptr_t slots[4]) {
    slots[0] = fixture->classReference;
    memcpy(&slots[1], fixture->selectorReferences, sizeof(fixture->selectorReferences));
}

static BOOL CVLPAdmissionRunImageValidationCases(NSString **failure) {
    CVLPAdmissionFixtureMemory fixture;
    CVLPAdmissionValidatedImage validated = {0};
    CVLPAdmissionFixtureInitialize(&fixture);
    CVLPHighlightsDirectMemory memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
    CVLPAdmissionStatus status = CVLPAdmissionValidateImageWithExpectedDigest(
        fixture.base, &memory, fixture.digest, &validated);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && validated.imageBase == fixture.base &&
        validated.selectors[0] == fixture.selectorReferences[0] && fixture.CASCalls == 0,
        @"admission_pinned_synthetic_image_valid", failure)) { return NO; }

    // Each malformed pin is rejected without altering any synthetic reference slot.
    for (NSUInteger test = 0; test < 12; test++) {
        CVLPAdmissionFixtureInitialize(&fixture);
        memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
        const char *caseName = "admission_wrong_header_rejected";
        CVLPAdmissionStatus expected = CVLPAdmissionStatusPinMismatch;
        switch (test) {
            case 0: {
                struct uuid_command *uuid = (struct uuid_command *)(fixture.imageBytes + sizeof(struct mach_header_64));
                uuid->uuid[0] ^= 1; caseName = "admission_wrong_uuid_rejected"; break;
            }
            case 1: ((struct mach_header_64 *)fixture.imageBytes)->cputype = CPU_TYPE_X86_64;
                caseName = "admission_wrong_architecture_rejected"; break;
            case 2: ((struct mach_header_64 *)fixture.imageBytes)->filetype = MH_EXECUTE;
                caseName = "admission_wrong_header_rejected"; break;
            case 3: CVLPAdmissionFixtureSection(&fixture, 1)->addr++;
                caseName = "admission_wrong_section_rejected"; break;
            case 4: fixture.functionBytes[0] ^= 1;
                caseName = "admission_wrong_code_rejected"; break;
            case 5: fixture.classReference++;
                caseName = "admission_wrong_class_slot_rejected"; break;
            case 6: fixture.selectorReferences[0] = 0;
                caseName = "admission_wrong_selector_slot_rejected"; break;
            case 7: fixture.dataProtection = VM_PROT_WRITE;
                expected = CVLPAdmissionStatusMappingRejected; caseName = "admission_nonreadable_metadata_rejected"; break;
            case 8: fixture.dataProtection = VM_PROT_READ | VM_PROT_EXECUTE;
                expected = CVLPAdmissionStatusMappingRejected; caseName = "admission_executable_metadata_rejected"; break;
            case 9: fixture.base = UINTPTR_MAX & ~((uintptr_t)sizeof(uintptr_t) - 1);
                expected = CVLPAdmissionStatusMappingRejected; caseName = "admission_address_overflow_rejected"; break;
            case 10: fixture.rejectRead = YES;
                expected = CVLPAdmissionStatusMappingRejected; caseName = "admission_read_failure_rejected"; break;
            default: fixture.rejectMapping = YES;
                expected = CVLPAdmissionStatusInvalidInput; caseName = "admission_null_input_rejected"; break;
        }
        uintptr_t slotsBefore[4], slotsAfter[4];
        CVLPAdmissionFixtureSnapshotSlots(&fixture, slotsBefore);
        CVLPAdmissionValidatedImage rejected = { .imageBase = 9, .selectors = { 1, 2, 3 } };
        status = test == 11 ? CVLPAdmissionValidateImageWithExpectedDigest(0, &memory, fixture.digest, &rejected) :
            CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory, fixture.digest, &rejected);
        CVLPAdmissionFixtureSnapshotSlots(&fixture, slotsAfter);
        if (!CVLPFixtureRequire(status == expected && rejected.imageBase == 0 &&
            rejected.selectors[0] == 0 && memcmp(slotsBefore, slotsAfter, sizeof(slotsBefore)) == 0 &&
            fixture.CASCalls == 0, [NSString stringWithUTF8String:caseName], failure)) { return NO; }
    }

    CVLPAdmissionFixtureInitialize(&fixture);
    memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
    CVLPAdmissionFixtureRuntimeContext clock = { .now = 30.0 };
    CVLPAdmissionRuntimeCallbacks callbacks = CVLPAdmissionFixtureCallbacks(&clock);
    Class classes[] = { CVLPAdmissionFixtureInstanceOwner.class, CVLPAdmissionFixtureMetaclassOwner.class,
        CVLPAdmissionFixtureDuplicateA.class, CVLPAdmissionFixtureDuplicateB.class };
    CVLPAdmissionMetadataResult result;
    fixture.mutateSelectorOnRead = YES;
    fixture.mutateSelectorAtRead = 2;
    result.status = CVLPAdmissionStatusUnknown;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        (void)snprintf(result.selectorNames[index], sizeof(result.selectorNames[index]), "staleSelector");
        (void)snprintf(result.exampleOwners[index], sizeof(result.exampleOwners[index]), "StaleOwner");
    }
    status = CVLPAdmissionAnalyzeImageWithExpectedDigest(fixture.base, &memory, fixture.digest,
        classes, sizeof(classes) / sizeof(classes[0]), "/fixture/admission-image", &callbacks, &result);
    BOOL allNamesCleared = YES;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        allNamesCleared = allNamesCleared && result.selectorNames[index][0] == '\0' &&
            result.exampleOwners[index][0] == '\0' && result.returnCodes[index] == '?' &&
            result.argumentCounts[index] == -1;
    }
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusSelectorChanged && allNamesCleared &&
        fixture.CASCalls == 0, @"admission_selector_second_read_change_clears_result", failure)) { return NO; }
    return YES;
}

static NSUInteger CVLPAdmissionFixtureMethodCapCalls;
static void CVLPAdmissionFixtureMethodCapImplementation(id receiver, SEL selector) {
    (void)receiver; (void)selector;
    CVLPAdmissionFixtureMethodCapCalls++;
}

static Class CVLPAdmissionFixtureCreateMethodCapClass(void) {
    static Class fixtureClass;
    if (fixtureClass != Nil) { return fixtureClass; }
    Class candidate = objc_allocateClassPair(NSObject.class, "CVLPAdmissionFixtureMethodCap", 0);
    if (candidate == Nil) { return Nil; }
    for (NSUInteger index = 0; index <= CVLPAdmissionMaximumMethodsPerList; index++) {
        char selectorName[64];
        int written = snprintf(selectorName, sizeof(selectorName), "cvlpAdmissionFixtureBulk%04lu", (unsigned long)index);
        if (written <= 0 || (size_t)written >= sizeof(selectorName) ||
            !class_addMethod(candidate, sel_registerName(selectorName),
                (IMP)CVLPAdmissionFixtureMethodCapImplementation, "v@:")) {
            objc_disposeClassPair(candidate);
            return Nil;
        }
    }
    objc_registerClassPair(candidate);
    fixtureClass = candidate;
    return fixtureClass;
}

static BOOL CVLPAdmissionRunDiscoveryCases(NSString **failure) {
    CVLPAdmissionFixtureMemory fixture;
    CVLPAdmissionFixtureInitialize(&fixture);
    CVLPHighlightsDirectMemory memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
    CVLPAdmissionValidatedImage validated = {0};
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched, @"admission_discovery_image_valid", failure)) {
        return NO;
    }
    CVLPAdmissionFixtureMethodCalls = 0;
    CVLPFixtureResolverCalls = 0;
    CVLPAdmissionFixtureRuntimeContext clock = { .now = 100.0 };
    CVLPAdmissionRuntimeCallbacks callbacks = CVLPAdmissionFixtureCallbacks(&clock);
    CVLPAdmissionMetadataResult result;

    Class instanceClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    CVLPAdmissionStatus status = CVLPAdmissionScanProvidedClasses(&validated, instanceClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matchCounts[0] == 1 &&
        strcmp(result.selectorNames[0], "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        strcmp(result.exampleOwners[0], "CVLPAdmissionFixtureInstanceOwner") == 0 &&
        result.returnCodes[0] == 'i' && result.argumentCounts[0] == 2,
        @"admission_instance_declared_method_matched", failure)) { return NO; }
    NSString *partialMatchLine = CVLPAdmissionFormatLine(&result, 1);
    if (!CVLPFixtureRequire(partialMatchLine != nil && CVLPAdmissionLineIsSanitized(partialMatchLine),
        @"admission_partial_match_line_is_valid", failure)) { return NO; }

    uintptr_t metaclassSelector = fixture.selectorReferences[1];
    fixture.selectorReferences[1] = fixture.selectorReferences[0];
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_same_selector_slots_image_valid", failure)) { return NO; }
    status = CVLPAdmissionScanProvidedClasses(&validated, instanceClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matchCounts[0] == 1 &&
        result.matchCounts[1] == 1 &&
        strcmp(result.selectorNames[0], "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        strcmp(result.selectorNames[1], "cvlpAdmissionFixtureInstanceMethod") == 0,
        @"admission_same_selector_multiple_slots_counted", failure)) { return NO; }
    fixture.selectorReferences[1] = metaclassSelector;
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_same_selector_slot_restore", failure)) { return NO; }

    Class metaclassClasses[] = { CVLPAdmissionFixtureMetaclassOwner.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, metaclassClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matchCounts[1] == 1 &&
        strcmp(result.selectorNames[1], "cvlpAdmissionFixtureMetaclassMethod") == 0 &&
        strcmp(result.exampleOwners[1], "CVLPAdmissionFixtureMetaclassOwner") == 0 &&
        result.returnCodes[1] == 'd' && result.argumentCounts[1] == 2,
        @"admission_metaclass_declared_method_matched", failure)) { return NO; }

    fixture.selectorReferences[0] = (uintptr_t)@selector(cvlpAdmissionFixtureInheritedMethod);
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_inherited_fixture_image_valid", failure)) { return NO; }
    Class inheritedClasses[] = { CVLPAdmissionFixtureInheritedChild.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, inheritedClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusNoMatch && result.matchCounts[0] == 0,
        @"admission_inherited_method_not_counted", failure)) { return NO; }
    NSString *noMatchLine = CVLPAdmissionFormatLine(&result, 1);
    if (!CVLPFixtureRequire(noMatchLine != nil && CVLPAdmissionLineIsSanitized(noMatchLine),
        @"admission_no_match_line_is_valid", failure)) { return NO; }

    fixture.selectorReferences[0] = (uintptr_t)@selector(cvlpAdmissionFixtureInstanceMethod);
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_discovery_reference_restore", failure)) { return NO; }

    fixture.selectorReferences[0] = (uintptr_t)@selector(cvlpAdmissionFixtureUnknownABI);
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_unknown_abi_fixture_image_valid", failure)) { return NO; }
    Class unknownABIClasses[] = { CVLPAdmissionFixtureUnknownABI.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, unknownABIClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusIncomplete &&
        result.reason == CVLPAdmissionScanReasonInvalidRuntimeMetadata && result.matchCounts[0] == 1 &&
        result.returnCodes[0] == '?' && CVLPAdmissionLineIsSanitized(CVLPAdmissionFormatLine(&result, 1)),
        @"admission_unsupported_return_abi_is_unknown_and_incomplete", failure)) { return NO; }
    fixture.selectorReferences[0] = (uintptr_t)@selector(cvlpAdmissionFixtureInstanceMethod);
    if (!CVLPFixtureRequire(CVLPAdmissionValidateImageWithExpectedDigest(fixture.base, &memory,
        fixture.digest, &validated) == CVLPAdmissionStatusMatched,
        @"admission_unknown_abi_reference_restore", failure)) { return NO; }

    Class duplicateClasses[] = { CVLPAdmissionFixtureDuplicateA.class, CVLPAdmissionFixtureDuplicateB.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, duplicateClasses, 2,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusAmbiguous && result.matchCounts[2] == 2 &&
        strcmp(result.exampleOwners[2], "CVLPAdmissionFixtureDuplicateA") == 0 &&
        result.returnCodes[2] == '?' && result.argumentCounts[2] == -1,
        @"admission_duplicate_matches_are_ambiguous_examples_not_callers", failure)) { return NO; }
    NSString *ambiguousLine = CVLPAdmissionFormatLine(&result, 2);
    if (!CVLPFixtureRequire(ambiguousLine != nil && CVLPAdmissionLineIsSanitized(ambiguousLine),
        @"admission_ambiguous_line_has_unknown_abi", failure)) { return NO; }

    clock.mismatchedClass = CVLPAdmissionFixtureInstanceOwner.class;
    Class mismatchedClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, mismatchedClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusImageMismatch &&
        result.reason == CVLPAdmissionScanReasonClassImageMismatch && result.classesScanned == 0,
        @"admission_image_mismatch_is_incomplete", failure)) { return NO; }
    clock.mismatchedClass = Nil;

    clock.now = 10.0;
    clock.advancePerClock = 1.0;
    callbacks = CVLPAdmissionFixtureCallbacks(&clock);
    callbacks.deadlineAt = 11.5;
    status = CVLPAdmissionScanProvidedClasses(&validated, instanceClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusDeadline && result.classesScanned == 0,
        @"admission_deadline_stops_scan", failure)) { return NO; }

    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 20.0 };
    callbacks = CVLPAdmissionFixtureCallbacks(&clock);
    Class boundedClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, boundedClasses,
        (size_t)CVLPAdmissionMaximumClassCount + 1, "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusClassLimit &&
        result.reason == CVLPAdmissionScanReasonClassCountLimit,
        @"admission_class_cap_stops_scan", failure)) { return NO; }

    Class methodCap = CVLPAdmissionFixtureCreateMethodCapClass();
    if (!CVLPFixtureRequire(methodCap != Nil, @"admission_method_cap_fixture_creation", failure)) { return NO; }
    Class methodCapClasses[] = { methodCap };
    status = CVLPAdmissionScanProvidedClasses(&validated, methodCapClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMethodLimit &&
        result.reason == CVLPAdmissionScanReasonMethodCountLimit && CVLPAdmissionFixtureMethodCapCalls == 0,
        @"admission_method_cap_stops_scan", failure)) { return NO; }

    Class resolverClasses[] = { CVLPFixtureResolverTrap.class };
    status = CVLPAdmissionScanProvidedClasses(&validated, resolverClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusNoMatch && CVLPFixtureResolverCalls == 0,
        @"admission_runtime_resolvers_not_called", failure)) { return NO; }
    if (!CVLPFixtureRequire(CVLPAdmissionFixtureMethodCalls == 0,
        @"admission_original_methods_not_invoked", failure)) { return NO; }

    if (!CVLPFixtureRequire(CVLPAdmissionSelectorNameIsSafe("cvlpAdmissionFixtureInstanceMethod") &&
        CVLPAdmissionSelectorNameIsSafe("cvlpAdmissionFixtureTrailing:") &&
        CVLPAdmissionExampleOwnerIsSafe("CVLPAdmissionFixtureInstanceOwner") &&
        !CVLPAdmissionSelectorNameIsSafe("secret caption") &&
        !CVLPAdmissionSelectorNameIsSafe("/private/path") &&
        !CVLPAdmissionSelectorNameIsSafe("https://example.invalid") &&
        !CVLPAdmissionExampleOwnerIsSafe("CVLP Admission Owner"),
        @"admission_safe_identifier_names_only", failure)) { return NO; }
    uint64_t parsedUnsigned = 0;
    if (!CVLPFixtureRequire(!CVLPAdmissionParseUnsigned("9", 1, &parsedUnsigned),
        @"admission_small_numeric_bound_does_not_underflow", failure)) { return NO; }

    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 30.0 };
    callbacks = CVLPAdmissionFixtureCallbacks(&clock);
    status = CVLPAdmissionScanProvidedClasses(&validated, instanceClasses, 1,
        "/fixture/admission-image", &callbacks, &memory, &result);
    NSString *line = CVLPAdmissionFormatLine(&result, 1);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && line != nil &&
        CVLPAdmissionLineIsSanitized(line), @"admission_line_schema_valid", failure)) { return NO; }
    CVLPAdmissionMetadataResult nulReturnResult = result;
    nulReturnResult.status = CVLPAdmissionStatusIncomplete;
    nulReturnResult.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
    nulReturnResult.returnCodes[0] = '\0';
    NSString *nulReturnLine = CVLPAdmissionFormatLine(&nulReturnResult, 1);
    if (!CVLPFixtureRequire(nulReturnLine != nil && [nulReturnLine containsString:@"return0=?"] &&
        CVLPAdmissionLineIsSanitized(nulReturnLine), @"admission_nul_return_encoding_is_unknown", failure)) { return NO; }

    NSString *badContent = [line stringByReplacingOccurrencesOfString:
        @"selector0=cvlpAdmissionFixtureInstanceMethod" withString:@"selector0=private caption"];
    NSString *badPath = [line stringByReplacingOccurrencesOfString:
        @"selector0=cvlpAdmissionFixtureInstanceMethod" withString:@"selector0=/private/path"];
    NSString *badURL = [line stringByReplacingOccurrencesOfString:
        @"selector0=cvlpAdmissionFixtureInstanceMethod" withString:@"selector0=https://example.invalid"];
    NSString *badEmbeddedNUL = [line stringByAppendingFormat:@"%C%@", (unichar)0, @"hiddenpayload"];
    NSString *badDEL = [line stringByAppendingFormat:@"%C", (unichar)0x7f];
    NSString *spoofedText = [line stringByAppendingString:@" text=private"];
    NSString *longName = [@"A" stringByPaddingToLength:CVLPAdmissionExampleNameCapacity + 1
        withString:@"A" startingAtIndex:0];
    NSString *badLongName = [line stringByReplacingOccurrencesOfString:
        @"example0=CVLPAdmissionFixtureInstanceOwner" withString:[@"example0=" stringByAppendingString:longName]];
    NSString *badSequence = [line stringByReplacingOccurrencesOfString:@"seq=1" withString:@"seq=0"];
    NSString *badStatus = [line stringByReplacingOccurrencesOfString:@"status=1" withString:@"status=99"];
    NSString *badClasses = [line stringByReplacingOccurrencesOfString:@"classes=1" withString:@"classes=100001"];
    NSString *badMatches = [line stringByReplacingOccurrencesOfString:@"matches0=1" withString:@"matches0=-1"];
    NSString *badArguments = [line stringByReplacingOccurrencesOfString:@"args0=2" withString:@"args0=99999"];
    NSString *spoofedField = [line stringByAppendingString:@" profile=private"];
    NSString *spoofedPath = [line stringByAppendingString:@" path=/private/path"];
    NSString *badLength = [line stringByAppendingString:[@"x" stringByPaddingToLength:
        CVLPAdmissionMaximumLineLength + 1 withString:@"x" startingAtIndex:0]];
    if (!CVLPFixtureRequire(!CVLPAdmissionLineIsSanitized(badContent) &&
        !CVLPAdmissionLineIsSanitized(badPath) && !CVLPAdmissionLineIsSanitized(badURL) &&
        !CVLPAdmissionLineIsSanitized(badEmbeddedNUL) && !CVLPAdmissionLineIsSanitized(badDEL),
        @"admission_line_schema_rejects_content_path_url", failure)) { return NO; }
    if (!CVLPFixtureRequire(!CVLPAdmissionLineIsSanitized(badLongName) &&
        !CVLPAdmissionLineIsSanitized(badLength),
        @"admission_line_schema_rejects_unbounded_names_and_line", failure)) { return NO; }
    if (!CVLPFixtureRequire(!CVLPAdmissionLineIsSanitized(badSequence) &&
        !CVLPAdmissionLineIsSanitized(badStatus) && !CVLPAdmissionLineIsSanitized(badClasses) &&
        !CVLPAdmissionLineIsSanitized(badMatches) && !CVLPAdmissionLineIsSanitized(badArguments),
        @"admission_line_schema_rejects_bad_numeric_fields", failure)) { return NO; }
    if (!CVLPFixtureRequire(!CVLPAdmissionLineIsSanitized(spoofedField) &&
        !CVLPAdmissionLineIsSanitized(spoofedText) && !CVLPAdmissionLineIsSanitized(spoofedPath),
        @"admission_line_schema_rejects_spoofed_extra_fields", failure)) { return NO; }
    return YES;
}

static BOOL CVLPAdmissionRunFixtureCases(NSString **failure) {
    if (!CVLPAdmissionRunImageValidationCases(failure) || !CVLPAdmissionRunDiscoveryCases(failure)) { return NO; }
    return YES;
}

#endif // CVLP_ADMISSION_METADATA_FIXTURE_CASES_H
