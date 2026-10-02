#ifndef CVLP_ADMISSION_METADATA_H
#define CVLP_ADMISSION_METADATA_H

#ifndef CVLP_HIGHLIGHTS_ADMISSION_METADATA
#define CVLP_HIGHLIGHTS_ADMISSION_METADATA 0
#endif

#if CVLP_HIGHLIGHTS_ADMISSION_METADATA || defined(CVLP_HIGHLIGHTS_TESTING)

#import <CommonCrypto/CommonDigest.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, CVLPAdmissionStatus) {
    CVLPAdmissionStatusUnknown = 0,
    CVLPAdmissionStatusMatched = 1,
    CVLPAdmissionStatusNoMatch = 2,
    CVLPAdmissionStatusAmbiguous = 3,
    CVLPAdmissionStatusInvalidInput = 4,
    CVLPAdmissionStatusImageUnavailable = 5,
    CVLPAdmissionStatusPinMismatch = 6,
    CVLPAdmissionStatusMappingRejected = 7,
    CVLPAdmissionStatusClassLimit = 8,
    CVLPAdmissionStatusMethodLimit = 9,
    CVLPAdmissionStatusDeadline = 10,
    CVLPAdmissionStatusInvalidClass = 11,
    CVLPAdmissionStatusImageMismatch = 12,
    CVLPAdmissionStatusSelectorChanged = 13,
    CVLPAdmissionStatusIncomplete = 14,
};

typedef NS_ENUM(int, CVLPAdmissionScanReason) {
    CVLPAdmissionScanReasonNone = 0,
    CVLPAdmissionScanReasonAnchorUnavailable = 1,
    CVLPAdmissionScanReasonAnchorImageMismatch = 2,
    CVLPAdmissionScanReasonClassCountLimit = 3,
    CVLPAdmissionScanReasonDeadline = 4,
    CVLPAdmissionScanReasonMissingClass = 5,
    CVLPAdmissionScanReasonClassImageMismatch = 6,
    CVLPAdmissionScanReasonMethodCountLimit = 7,
    CVLPAdmissionScanReasonSelectorChanged = 8,
    CVLPAdmissionScanReasonInvalidRuntimeMetadata = 9,
    CVLPAdmissionScanReasonInvalidInput = 10,
};

enum {
    CVLPAdmissionSelectorCount = 3,
    CVLPAdmissionSelectorNameCapacity = 129,
    CVLPAdmissionExampleNameCapacity = 193,
    CVLPAdmissionMaximumClassCount = 100000,
    CVLPAdmissionMaximumMethodsPerList = 4096,
    CVLPAdmissionMaximumArguments = 4096,
    CVLPAdmissionMaximumLineLength = 2048,
};

static const uint64_t CVLPAdmissionSelectorSectionVM = 0x0a35c238ULL;
static const uint64_t CVLPAdmissionSelectorSectionSize = 0x003b9e98ULL;
static const uint64_t CVLPAdmissionFunctionVM = 0x1bac4d60ULL;
static const size_t CVLPAdmissionFunctionLength = 188;
static const uint64_t CVLPAdmissionClassRefSlotVM = 0x03c401a0ULL;
static const uint64_t CVLPAdmissionSelectorRefVM[CVLPAdmissionSelectorCount] = {
    0x0a35cee8ULL, 0x0a35eeb8ULL, 0x0a3d8570ULL,
};
static const CFTimeInterval CVLPAdmissionScanDeadline = 1.5;
static const uint8_t CVLPAdmissionExpectedFunctionSHA256[CC_SHA256_DIGEST_LENGTH] = {
    0xf2, 0x49, 0xf7, 0x76, 0x6c, 0x40, 0x7a, 0xf9,
    0xe7, 0x48, 0x0b, 0x3c, 0x20, 0xf9, 0xd1, 0x85,
    0xda, 0x34, 0xc9, 0x9b, 0x23, 0x41, 0x19, 0xa0,
    0x45, 0x4a, 0x80, 0x5c, 0x2d, 0xdf, 0x1c, 0x50,
};

typedef struct {
    uintptr_t imageBase;
    uintptr_t selectors[CVLPAdmissionSelectorCount];
} CVLPAdmissionValidatedImage;

typedef struct {
    int status;
    int reason;
    uint32_t classesScanned;
    uint32_t methodsScanned;
    uint32_t skippedLists;
    uint32_t maxSkipped;
    uint32_t matchCounts[CVLPAdmissionSelectorCount];
    int32_t argumentCounts[CVLPAdmissionSelectorCount];
    char selectorNames[CVLPAdmissionSelectorCount][CVLPAdmissionSelectorNameCapacity];
    // First runtime class example, not a caller class; category/IMP origin is unverified.
    char exampleOwners[CVLPAdmissionSelectorCount][CVLPAdmissionExampleNameCapacity];
    char returnCodes[CVLPAdmissionSelectorCount];
} CVLPAdmissionMetadataResult;

typedef struct {
    CFTimeInterval (*clock)(void *context);
    const char *(*imageName)(Class cls, void *context);
    void *context;
    // An absolute monotonic deadline. Zero requests a fresh 1.5 second budget.
    CFTimeInterval deadlineAt;
} CVLPAdmissionRuntimeCallbacks;

// Validation only reads the pinned Mach-O metadata, selector references and
// admission function body. compareExchange is deliberately never consulted.
static CVLPAdmissionStatus CVLPAdmissionValidateImage(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, CVLPAdmissionValidatedImage *validated);

// Test-only digest injection accepts synthetic function bytes; production has
// no code path to substitute its immutable digest.
#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionValidateImageWithExpectedDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    CVLPAdmissionValidatedImage *validated);
#endif

// Scans provided classes' declared instance and metaclass method lists only.
// Callback injection keeps fixtures deterministic and avoids image discovery.
static CVLPAdmissionStatus CVLPAdmissionScanProvidedClasses(
    const CVLPAdmissionValidatedImage *validated, Class const *classes, size_t classCount,
    const char *expectedImageName, const CVLPAdmissionRuntimeCallbacks *callbacks,
    const CVLPHighlightsDirectMemory *memory, CVLPAdmissionMetadataResult *result);

static CVLPAdmissionStatus CVLPAdmissionAnalyzeImage(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, Class const *classes, size_t classCount,
    const char *expectedImageName, const CVLPAdmissionRuntimeCallbacks *callbacks,
    CVLPAdmissionMetadataResult *result);

#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionAnalyzeImageWithExpectedDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    Class const *classes, size_t classCount, const char *expectedImageName,
    const CVLPAdmissionRuntimeCallbacks *callbacks, CVLPAdmissionMetadataResult *result);
#endif

static BOOL CVLPAdmissionSelectorNameIsSafe(const char *name);
static BOOL CVLPAdmissionExampleOwnerIsSafe(const char *name);
static BOOL CVLPAdmissionLineIsSanitized(NSString *line);
static NSString *CVLPAdmissionFormatLine(const CVLPAdmissionMetadataResult *result, uint32_t sequence);

// Production discovery is read-only: anchor image lookup, exact pinned image
// validation, bounded class-name lookup, declared method enumeration, then
// fixed-reference recheck. The returned line never contains paths or pointers.
static NSString *CVLPAdmissionMetadataLineForAnchor(Class anchor, uint32_t sequence);

static uint32_t CVLPAdmissionMaximumMethodTotal(void) {
    return (uint32_t)(CVLPAdmissionMaximumClassCount * 2ULL * CVLPAdmissionMaximumMethodsPerList);
}

static BOOL CVLPAdmissionASCIIIdentifier(const char *name, size_t maximumLength,
    BOOL allowDot, BOOL allowColon) {
    if (name == NULL || maximumLength == 0) { return NO; }
    BOOL componentStart = YES;
    size_t length = 0;
    for (; length <= maximumLength; length++) {
        unsigned char byte = (unsigned char)name[length];
        if (byte == 0) {
            return length > 0 && (!componentStart || (allowColon && name[length - 1] == ':'));
        }
        BOOL separator = (byte == '.' && allowDot) || (byte == ':' && allowColon);
        if (separator) {
            if (componentStart) { return NO; }
            componentStart = YES;
            continue;
        }
        BOOL alpha = (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || byte == '_';
        BOOL digit = byte >= '0' && byte <= '9';
        if (componentStart ? !alpha : (!alpha && !digit)) { return NO; }
        componentStart = NO;
    }
    return NO;
}

static BOOL CVLPAdmissionSelectorNameIsSafe(const char *name) {
    return CVLPAdmissionASCIIIdentifier(name, CVLPAdmissionSelectorNameCapacity - 1, NO, YES);
}

static BOOL CVLPAdmissionExampleOwnerIsSafe(const char *name) {
    return CVLPAdmissionASCIIIdentifier(name, CVLPAdmissionExampleNameCapacity - 1, YES, NO);
}

static BOOL CVLPAdmissionBoundedCStringEquals(const char *left, const char *right, size_t maximumLength) {
    if (left == NULL || right == NULL || maximumLength == 0) { return NO; }
    for (size_t index = 0; index < maximumLength; index++) {
        if (left[index] != right[index]) { return NO; }
        if (left[index] == '\0') { return YES; }
    }
    return NO;
}

static BOOL CVLPAdmissionCopyIdentifier(char *destination, size_t capacity, const char *source,
    BOOL (*validator)(const char *)) {
    if (destination == NULL || capacity == 0 || source == NULL || validator == NULL) { return NO; }
    size_t length = 0;
    while (length < capacity && source[length] != '\0') { length++; }
    if (length == 0 || length >= capacity || !validator(source)) { return NO; }
    memcpy(destination, source, length);
    destination[length] = '\0';
    return YES;
}

static BOOL CVLPAdmissionReadFixedReferences(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const CVLPHighlightsDirectImagePin *pin,
    uintptr_t selectors[CVLPAdmissionSelectorCount], uintptr_t *classReference) {
    if (imageBase == 0 || memory == NULL || memory->regionAllows == NULL || memory->read == NULL ||
        pin == NULL || selectors == NULL || classReference == NULL) { return NO; }
    uintptr_t slot = 0;
    if (!CVLPHighlightsDirectRangeContains(pin->classRefsAddress, pin->classRefsSize,
            CVLPAdmissionClassRefSlotVM, sizeof(uintptr_t)) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPAdmissionClassRefSlotVM, &slot) ||
        !memory->regionAllows(slot, sizeof(uintptr_t), VM_PROT_READ, VM_PROT_EXECUTE, memory->context) ||
        !memory->read(slot, classReference, sizeof(*classReference), memory->context)) { return NO; }

    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        if (!CVLPHighlightsDirectRangeContains(CVLPAdmissionSelectorSectionVM,
                CVLPAdmissionSelectorSectionSize, CVLPAdmissionSelectorRefVM[index], sizeof(uintptr_t)) ||
            !CVLPHighlightsDirectAddress(imageBase, CVLPAdmissionSelectorRefVM[index], &slot) ||
            !memory->regionAllows(slot, sizeof(uintptr_t), VM_PROT_READ, VM_PROT_EXECUTE, memory->context) ||
            !memory->read(slot, &selectors[index], sizeof(selectors[index]), memory->context)) { return NO; }
    }
    return YES;
}

static BOOL CVLPAdmissionParseSelectorSection(const uint8_t *imageBytes, size_t imageBytesLength,
    const CVLPHighlightsDirectImagePin *pin) {
    if (imageBytes == NULL || pin == NULL || imageBytesLength < sizeof(struct mach_header_64)) { return NO; }
    struct mach_header_64 header;
    memcpy(&header, imageBytes, sizeof(header));
    size_t commandBytes = (size_t)header.sizeofcmds;
    if (commandBytes > imageBytesLength - sizeof(header)) { return NO; }
    const uint8_t *cursor = imageBytes + sizeof(header);
    size_t remaining = commandBytes;
    BOOL found = NO;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (remaining < sizeof(struct load_command)) { return NO; }
        struct load_command command;
        memcpy(&command, cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) { return NO; }
        if (command.cmd == LC_SEGMENT_64) {
            if (command.cmdsize < sizeof(struct segment_command_64)) { return NO; }
            struct segment_command_64 segment;
            memcpy(&segment, cursor, sizeof(segment));
            size_t sectionBytes = (size_t)segment.nsects * sizeof(struct section_64);
            if (sectionBytes > command.cmdsize - sizeof(segment)) { return NO; }
            if (CVLPHighlightsDirectNameEquals(segment.segname, "__DATA")) {
                const uint8_t *sectionCursor = cursor + sizeof(segment);
                for (uint32_t sectionIndex = 0; sectionIndex < segment.nsects; sectionIndex++) {
                    struct section_64 section;
                    memcpy(&section, sectionCursor + ((size_t)sectionIndex * sizeof(section)), sizeof(section));
                    if (!CVLPHighlightsDirectNameEquals(section.sectname, "_D_objc_selrefs")) { continue; }
                    if (found || !CVLPHighlightsDirectNameEquals(section.segname, "__DATA") ||
                        section.offset != 0 || section.align != 3 || section.reloff != 0 ||
                        section.nreloc != 0 || section.flags != S_ZEROFILL ||
                        section.reserved1 != 0 || section.reserved2 != 0 || section.reserved3 != 0 ||
                        section.addr != CVLPAdmissionSelectorSectionVM ||
                        section.size != CVLPAdmissionSelectorSectionSize ||
                        !CVLPHighlightsDirectRangeContains(pin->dataVMAddress, pin->dataVMSize,
                            section.addr, section.size)) { return NO; }
                    found = YES;
                }
            }
        }
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
    return remaining == 0 && found;
}

static CVLPAdmissionStatus CVLPAdmissionValidateImageUsingDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    CVLPAdmissionValidatedImage *validated) {
    if (validated != NULL) { memset(validated, 0, sizeof(*validated)); }
    if (imageBase == 0 || memory == NULL || memory->regionAllows == NULL || memory->read == NULL ||
        expectedDigest == NULL || validated == NULL || (imageBase & (sizeof(uintptr_t) - 1)) != 0) {
        return CVLPAdmissionStatusInvalidInput;
    }
    int incomingErrno = errno;
    struct mach_header_64 header;
    if (!memory->regionAllows(imageBase, sizeof(header), VM_PROT_READ, VM_PROT_WRITE, memory->context) ||
        !memory->read(imageBase, &header, sizeof(header), memory->context)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    if (header.magic != MH_MAGIC_64 || header.ncmds != CVLPHighlightsDirectExpectedCommandCount ||
        header.sizeofcmds != CVLPHighlightsDirectExpectedCommandBytes) {
        errno = incomingErrno;
        return CVLPAdmissionStatusPinMismatch;
    }
    size_t imageBytesLength = sizeof(header) + (size_t)header.sizeofcmds;
    uint8_t imageBytes[sizeof(struct mach_header_64) + CVLPHighlightsDirectExpectedCommandBytes];
    if (imageBytesLength > sizeof(imageBytes) ||
        !memory->regionAllows(imageBase, imageBytesLength, VM_PROT_READ, VM_PROT_WRITE, memory->context) ||
        !memory->read(imageBase, imageBytes, imageBytesLength, memory->context)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    CVLPHighlightsDirectImagePin pin;
    CVLPHighlightsDirectInstallStatus parsed = CVLPHighlightsDirectParseImage(imageBytes, imageBytesLength, &pin);
    if (parsed != CVLPHighlightsDirectInstalled) {
        errno = incomingErrno;
        return parsed == CVLPHighlightsDirectMappingRejected ? CVLPAdmissionStatusMappingRejected :
            CVLPAdmissionStatusPinMismatch;
    }
    if (!CVLPAdmissionParseSelectorSection(imageBytes, imageBytesLength, &pin)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusPinMismatch;
    }

    uintptr_t classSlot = 0;
    uintptr_t functionAddress = 0;
    if (!CVLPHighlightsDirectAddress(imageBase, CVLPAdmissionClassRefSlotVM, &classSlot) ||
        !CVLPHighlightsDirectAddress(imageBase, CVLPAdmissionFunctionVM, &functionAddress) ||
        !CVLPHighlightsDirectRangeContains(pin.executableVMAddress, pin.executableVMSize,
            CVLPAdmissionFunctionVM, CVLPAdmissionFunctionLength) ||
        !memory->regionAllows(classSlot, sizeof(uintptr_t), VM_PROT_READ, VM_PROT_EXECUTE, memory->context) ||
        !memory->regionAllows(functionAddress, CVLPAdmissionFunctionLength,
            VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE, memory->context)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    uintptr_t classReference = 0;
    if (!memory->read(classSlot, &classReference, sizeof(classReference), memory->context)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    if (classReference != functionAddress) {
        errno = incomingErrno;
        return CVLPAdmissionStatusPinMismatch;
    }
    uint8_t functionBytes[CVLPAdmissionFunctionLength];
    if (!memory->read(functionAddress, functionBytes, sizeof(functionBytes), memory->context)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256(functionBytes, (CC_LONG)sizeof(functionBytes), digest) == NULL ||
        memcmp(digest, expectedDigest, sizeof(digest)) != 0) {
        errno = incomingErrno;
        return CVLPAdmissionStatusPinMismatch;
    }

    uintptr_t classReferenceAfter = 0;
    uintptr_t selectors[CVLPAdmissionSelectorCount] = {0};
    if (!CVLPAdmissionReadFixedReferences(imageBase, memory, &pin, selectors, &classReferenceAfter)) {
        errno = incomingErrno;
        return CVLPAdmissionStatusMappingRejected;
    }
    if (classReferenceAfter != functionAddress) {
        errno = incomingErrno;
        return CVLPAdmissionStatusPinMismatch;
    }
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        if (selectors[index] == 0) {
            errno = incomingErrno;
            return CVLPAdmissionStatusPinMismatch;
        }
    }
    validated->imageBase = imageBase;
    memcpy(validated->selectors, selectors, sizeof(selectors));
    errno = incomingErrno;
    return CVLPAdmissionStatusMatched;
}

static CVLPAdmissionStatus CVLPAdmissionValidateImage(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, CVLPAdmissionValidatedImage *validated) {
    return CVLPAdmissionValidateImageUsingDigest(imageBase, memory,
        CVLPAdmissionExpectedFunctionSHA256, validated);
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionValidateImageWithExpectedDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    CVLPAdmissionValidatedImage *validated) {
    return CVLPAdmissionValidateImageUsingDigest(imageBase, memory, expectedDigest, validated);
}
#endif

static CFTimeInterval CVLPAdmissionDefaultClock(void *context) {
    (void)context;
    return CACurrentMediaTime();
}

static const char *CVLPAdmissionDefaultImageName(Class cls, void *context) {
    (void)context;
    return cls == Nil ? NULL : class_getImageName(cls);
}

static BOOL CVLPAdmissionDeadlineReached(const CVLPAdmissionRuntimeCallbacks *callbacks,
    CFTimeInterval deadlineAt) {
    CFTimeInterval (*clockFunction)(void *) = callbacks != NULL && callbacks->clock != NULL ?
        callbacks->clock : CVLPAdmissionDefaultClock;
    CFTimeInterval now = clockFunction(callbacks != NULL ? callbacks->context : NULL);
    return !isfinite(now) || now >= deadlineAt;
}

static BOOL CVLPAdmissionSafeCopy(const char *source, char *destination, size_t capacity,
    BOOL (*validator)(const char *)) {
    if (destination != NULL && capacity > 0) { destination[0] = '\0'; }
    return CVLPAdmissionCopyIdentifier(destination, capacity, source, validator);
}

static char CVLPAdmissionReturnCode(const char *encoding) {
    if (encoding == NULL) { return '?'; }
    for (size_t index = 0; index < 32; index++) {
        unsigned char byte = (unsigned char)encoding[index];
        if (byte == 0) { return '?'; }
        if (strchr("rnNoORV", byte) != NULL) { continue; }
        return strchr("cislqCISLQfdBv@#:?*", byte) != NULL ? (char)byte : '?';
    }
    return '?';
}

static void CVLPAdmissionSetFirstReason(CVLPAdmissionMetadataResult *result, int reason) {
    if (result->reason == CVLPAdmissionScanReasonNone) { result->reason = reason; }
}

static BOOL CVLPAdmissionRecordMethod(Method method, Class owner,
    const CVLPAdmissionValidatedImage *validated, const CVLPAdmissionRuntimeCallbacks *callbacks,
    CFTimeInterval deadlineAt, CVLPAdmissionMetadataResult *result, BOOL *metadataIncomplete) {
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }
    SEL name = method_getName(method);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }
    if (name == NULL) { return YES; }
    uintptr_t rawName = (uintptr_t)name;
    BOOL targets[CVLPAdmissionSelectorCount] = {NO, NO, NO};
    BOOL anyTarget = NO;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        targets[index] = rawName == validated->selectors[index];
        anyTarget = anyTarget || targets[index];
    }
    if (!anyTarget) { return YES; }

    const char *selector = sel_getName(name);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }
    const char *ownerName = class_getName(owner);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }
    const char *types = method_getTypeEncoding(method);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) { return NO; }

    for (NSUInteger target = 0; target < CVLPAdmissionSelectorCount; target++) {
        if (!targets[target]) { continue; }
        if (result->matchCounts[target] < CVLPAdmissionMaximumMethodTotal()) {
            result->matchCounts[target]++;
        }
        if (result->matchCounts[target] == 1) {
            BOOL selectorSafe = CVLPAdmissionSafeCopy(selector, result->selectorNames[target],
                sizeof(result->selectorNames[target]), CVLPAdmissionSelectorNameIsSafe);
            BOOL ownerSafe = CVLPAdmissionSafeCopy(ownerName, result->exampleOwners[target],
                sizeof(result->exampleOwners[target]), CVLPAdmissionExampleOwnerIsSafe);
            char returnCode = CVLPAdmissionReturnCode(types);
            result->returnCodes[target] = returnCode;
            if (argumentCount <= CVLPAdmissionMaximumArguments) {
                result->argumentCounts[target] = (int32_t)argumentCount;
            }
            if (!selectorSafe || !ownerSafe || returnCode == '?' ||
                result->argumentCounts[target] < 0) {
                CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
                if (metadataIncomplete != NULL) { *metadataIncomplete = YES; }
            }
        } else if (result->matchCounts[target] == 2) {
            // Different class/instance declarations can reuse a selector with
            // different encodings. Preserve the first example owner, but withdraw
            // ABI metadata because it no longer describes every matching Method.
            result->returnCodes[target] = '?';
            result->argumentCounts[target] = -1;
        }
    }
    return YES;
}

static CVLPAdmissionStatus CVLPAdmissionScanMethodList(Class owner,
    const CVLPAdmissionValidatedImage *validated, const CVLPAdmissionRuntimeCallbacks *callbacks,
    CFTimeInterval deadlineAt, CVLPAdmissionMetadataResult *result, BOOL *metadataIncomplete) {
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
        CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
        free(methods);
        CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    if (count > 0 && methods == NULL) {
        CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
        return CVLPAdmissionStatusIncomplete;
    }
    if (count > CVLPAdmissionMaximumMethodsPerList) {
        free(methods);
        const uint32_t maximumSkippedLists = CVLPAdmissionMaximumClassCount * 2U;
        if (result->skippedLists < maximumSkippedLists) { result->skippedLists++; }
        if (count > result->maxSkipped) { result->maxSkipped = count; }
        return CVLPAdmissionDeadlineReached(callbacks, deadlineAt) ?
            CVLPAdmissionStatusDeadline : CVLPAdmissionStatusUnknown;
    }
    for (unsigned int index = 0; index < count; index++) {
        if (!CVLPAdmissionRecordMethod(methods[index], owner, validated, callbacks,
                deadlineAt, result, metadataIncomplete)) {
            free(methods);
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
            return CVLPAdmissionStatusDeadline;
        }
        if (result->methodsScanned < CVLPAdmissionMaximumMethodTotal()) { result->methodsScanned++; }
    }
    free(methods);
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
        CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    return CVLPAdmissionStatusUnknown;
}

static CVLPAdmissionStatus CVLPAdmissionRecheckReferences(
    const CVLPAdmissionValidatedImage *validated, const CVLPHighlightsDirectMemory *memory) {
    if (validated == NULL || memory == NULL) { return CVLPAdmissionStatusInvalidInput; }
    struct mach_header_64 header;
    if (memory->regionAllows == NULL || memory->read == NULL ||
        !memory->regionAllows(validated->imageBase, sizeof(header), VM_PROT_READ,
            VM_PROT_WRITE, memory->context) ||
        !memory->read(validated->imageBase, &header, sizeof(header), memory->context)) {
        return CVLPAdmissionStatusMappingRejected;
    }
    size_t imageBytesLength = sizeof(header) + (size_t)header.sizeofcmds;
    if (imageBytesLength > sizeof(struct mach_header_64) + CVLPHighlightsDirectExpectedCommandBytes) {
        return CVLPAdmissionStatusMappingRejected;
    }
    uint8_t imageBytes[sizeof(struct mach_header_64) + CVLPHighlightsDirectExpectedCommandBytes];
    if (!memory->regionAllows(validated->imageBase, imageBytesLength, VM_PROT_READ,
            VM_PROT_WRITE, memory->context) ||
        !memory->read(validated->imageBase, imageBytes, imageBytesLength, memory->context)) {
        return CVLPAdmissionStatusMappingRejected;
    }
    CVLPHighlightsDirectImagePin pin;
    if (CVLPHighlightsDirectParseImage(imageBytes, imageBytesLength, &pin) != CVLPHighlightsDirectInstalled ||
        !CVLPAdmissionParseSelectorSection(imageBytes, imageBytesLength, &pin)) {
        return CVLPAdmissionStatusMappingRejected;
    }
    uintptr_t classReference = 0;
    uintptr_t selectors[CVLPAdmissionSelectorCount] = {0};
    if (!CVLPAdmissionReadFixedReferences(validated->imageBase, memory, &pin, selectors, &classReference)) {
        return CVLPAdmissionStatusMappingRejected;
    }
    uintptr_t expectedFunction = 0;
    if (!CVLPHighlightsDirectAddress(validated->imageBase, CVLPAdmissionFunctionVM, &expectedFunction) ||
        classReference != expectedFunction) { return CVLPAdmissionStatusSelectorChanged; }
    if (memcmp(selectors, validated->selectors, sizeof(selectors)) != 0) {
        return CVLPAdmissionStatusSelectorChanged;
    }
    return CVLPAdmissionStatusMatched;
}

static CVLPAdmissionStatus CVLPAdmissionScanProvidedClasses(
    const CVLPAdmissionValidatedImage *validated, Class const *classes, size_t classCount,
    const char *expectedImageName, const CVLPAdmissionRuntimeCallbacks *callbacks,
    const CVLPHighlightsDirectMemory *memory, CVLPAdmissionMetadataResult *result) {
    if (result == NULL) { return CVLPAdmissionStatusInvalidInput; }
    memset(result, 0, sizeof(*result));
    result->status = CVLPAdmissionStatusUnknown;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        result->argumentCounts[index] = -1;
        result->returnCodes[index] = '?';
    }
    if (validated == NULL || classes == NULL || classCount == 0 || expectedImageName == NULL ||
        expectedImageName[0] == '\0' || memory == NULL || memory->read == NULL ||
        memory->regionAllows == NULL) {
        result->status = CVLPAdmissionStatusInvalidInput;
        result->reason = CVLPAdmissionScanReasonInvalidInput;
        return (CVLPAdmissionStatus)result->status;
    }
    if (classCount > CVLPAdmissionMaximumClassCount) {
        result->status = CVLPAdmissionStatusClassLimit;
        result->reason = CVLPAdmissionScanReasonClassCountLimit;
        return (CVLPAdmissionStatus)result->status;
    }
    int incomingErrno = errno;
    CFTimeInterval (*clockFunction)(void *) = callbacks != NULL && callbacks->clock != NULL ?
        callbacks->clock : CVLPAdmissionDefaultClock;
    CFTimeInterval startedAt = clockFunction(callbacks != NULL ? callbacks->context : NULL);
    CFTimeInterval deadlineAt = callbacks != NULL && callbacks->deadlineAt > 0.0 ? callbacks->deadlineAt :
        startedAt + 1.5;
    if (!isfinite(startedAt) || !isfinite(deadlineAt) || deadlineAt <= startedAt) {
        result->status = CVLPAdmissionStatusDeadline;
        result->reason = CVLPAdmissionScanReasonDeadline;
        errno = incomingErrno;
        return (CVLPAdmissionStatus)result->status;
    }
    const char *(*imageNameFunction)(Class, void *) = callbacks != NULL && callbacks->imageName != NULL ?
        callbacks->imageName : CVLPAdmissionDefaultImageName;
    BOOL metadataIncomplete = NO;
    CVLPAdmissionStatus terminal = CVLPAdmissionStatusUnknown;
    for (size_t classIndex = 0; classIndex < classCount; classIndex++) {
        if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
            terminal = CVLPAdmissionStatusDeadline;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
            break;
        }
        Class cls = classes[classIndex];
        if (cls == Nil) {
            terminal = CVLPAdmissionStatusInvalidClass;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonMissingClass);
            break;
        }
        const char *classImage = imageNameFunction(cls, callbacks != NULL ? callbacks->context : NULL);
        if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
            terminal = CVLPAdmissionStatusDeadline;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
            break;
        }
        if (!CVLPAdmissionBoundedCStringEquals(classImage, expectedImageName, PATH_MAX)) {
            terminal = CVLPAdmissionStatusImageMismatch;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonClassImageMismatch);
            break;
        }
        result->classesScanned++;

        CVLPAdmissionStatus listStatus = CVLPAdmissionScanMethodList(cls, validated, callbacks,
            deadlineAt, result, &metadataIncomplete);
        if (listStatus != CVLPAdmissionStatusUnknown) { terminal = listStatus; break; }
        if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
            terminal = CVLPAdmissionStatusDeadline;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
            break;
        }
        Class metaclass = object_getClass(cls);
        if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
            terminal = CVLPAdmissionStatusDeadline;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonDeadline);
            break;
        }
        if (metaclass == Nil) {
            terminal = CVLPAdmissionStatusInvalidClass;
            CVLPAdmissionSetFirstReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
            break;
        }
        listStatus = CVLPAdmissionScanMethodList(metaclass, validated, callbacks,
            deadlineAt, result, &metadataIncomplete);
        if (listStatus != CVLPAdmissionStatusUnknown) { terminal = listStatus; break; }
    }
    if (terminal == CVLPAdmissionStatusUnknown && result->classesScanned == classCount) {
        BOOL anyMatch = NO;
        BOOL ambiguous = NO;
        for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
            anyMatch = anyMatch || result->matchCounts[index] > 0;
            ambiguous = ambiguous || result->matchCounts[index] > 1;
        }
        if (result->skippedLists > 0) {
            terminal = CVLPAdmissionStatusMethodLimit;
            result->reason = CVLPAdmissionScanReasonMethodCountLimit;
        } else {
            terminal = metadataIncomplete ? CVLPAdmissionStatusIncomplete :
                (ambiguous ? CVLPAdmissionStatusAmbiguous : (anyMatch ? CVLPAdmissionStatusMatched :
                    CVLPAdmissionStatusNoMatch));
        }
    }
    if (result->skippedLists > 0) {
        for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
            result->returnCodes[index] = '?';
            result->argumentCounts[index] = -1;
        }
    }
    BOOL deadlineExpired = terminal == CVLPAdmissionStatusDeadline ||
        CVLPAdmissionDeadlineReached(callbacks, deadlineAt);
    CVLPAdmissionStatus referenceStatus = CVLPAdmissionStatusUnknown;
    if (!deadlineExpired) {
        referenceStatus = CVLPAdmissionRecheckReferences(validated, memory);
        deadlineExpired = CVLPAdmissionDeadlineReached(callbacks, deadlineAt);
    }
    if (deadlineExpired || referenceStatus != CVLPAdmissionStatusMatched) {
        for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
            result->selectorNames[index][0] = '\0';
            result->exampleOwners[index][0] = '\0';
            result->returnCodes[index] = '?';
            result->argumentCounts[index] = -1;
        }
        if (deadlineExpired) {
            terminal = CVLPAdmissionStatusDeadline;
            result->reason = CVLPAdmissionScanReasonDeadline;
        } else if (referenceStatus == CVLPAdmissionStatusSelectorChanged) {
            terminal = CVLPAdmissionStatusSelectorChanged;
            result->reason = CVLPAdmissionScanReasonSelectorChanged;
        } else {
            terminal = referenceStatus;
            result->reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
        }
    }
    result->status = terminal;
    errno = incomingErrno;
    return terminal;
}

static void CVLPAdmissionInitializeResult(CVLPAdmissionMetadataResult *result) {
    memset(result, 0, sizeof(*result));
    result->status = CVLPAdmissionStatusUnknown;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        result->argumentCounts[index] = -1;
        result->returnCodes[index] = '?';
    }
}

static CVLPAdmissionStatus CVLPAdmissionAnalyzeImageUsingDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    Class const *classes, size_t classCount, const char *expectedImageName,
    const CVLPAdmissionRuntimeCallbacks *callbacks, CVLPAdmissionMetadataResult *result) {
    if (result == NULL) { return CVLPAdmissionStatusInvalidInput; }
    CVLPAdmissionInitializeResult(result);
    int incomingErrno = errno;
    if (expectedDigest == NULL || memory == NULL || classes == NULL || classCount == 0 ||
        expectedImageName == NULL || expectedImageName[0] == '\0' ||
        !CVLPAdmissionBoundedCStringEquals(expectedImageName, expectedImageName, PATH_MAX)) {
        result->status = CVLPAdmissionStatusInvalidInput;
        result->reason = CVLPAdmissionScanReasonInvalidInput;
        errno = incomingErrno;
        return (CVLPAdmissionStatus)result->status;
    }
    CFTimeInterval (*clockFunction)(void *) = callbacks != NULL && callbacks->clock != NULL ?
        callbacks->clock : CVLPAdmissionDefaultClock;
    CFTimeInterval startedAt = clockFunction(callbacks != NULL ? callbacks->context : NULL);
    CFTimeInterval deadlineAt = callbacks != NULL && callbacks->deadlineAt > 0.0 ?
        callbacks->deadlineAt : startedAt + CVLPAdmissionScanDeadline;
    if (!isfinite(startedAt) || !isfinite(deadlineAt) || deadlineAt <= startedAt) {
        result->status = CVLPAdmissionStatusDeadline;
        result->reason = CVLPAdmissionScanReasonDeadline;
        errno = incomingErrno;
        return (CVLPAdmissionStatus)result->status;
    }
    CVLPAdmissionValidatedImage validated = {0};
    CVLPAdmissionStatus status = CVLPAdmissionValidateImageUsingDigest(imageBase, memory,
        expectedDigest, &validated);
    if (status != CVLPAdmissionStatusMatched) {
        result->status = status;
        if (status == CVLPAdmissionStatusInvalidInput) {
            result->reason = CVLPAdmissionScanReasonInvalidInput;
        }
        errno = incomingErrno;
        return status;
    }
    if (CVLPAdmissionDeadlineReached(callbacks, deadlineAt)) {
        result->status = CVLPAdmissionStatusDeadline;
        result->reason = CVLPAdmissionScanReasonDeadline;
        errno = incomingErrno;
        return (CVLPAdmissionStatus)result->status;
    }
    CVLPAdmissionRuntimeCallbacks boundedCallbacks = callbacks != NULL ? *callbacks :
        (CVLPAdmissionRuntimeCallbacks){0};
    boundedCallbacks.deadlineAt = deadlineAt;
    status = CVLPAdmissionScanProvidedClasses(&validated, classes, classCount, expectedImageName,
        &boundedCallbacks, memory, result);
    errno = incomingErrno;
    return status;
}

static CVLPAdmissionStatus CVLPAdmissionAnalyzeImage(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, Class const *classes, size_t classCount,
    const char *expectedImageName, const CVLPAdmissionRuntimeCallbacks *callbacks,
    CVLPAdmissionMetadataResult *result) {
    return CVLPAdmissionAnalyzeImageUsingDigest(imageBase, memory,
        CVLPAdmissionExpectedFunctionSHA256, classes, classCount, expectedImageName, callbacks, result);
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionAnalyzeImageWithExpectedDigest(uintptr_t imageBase,
    const CVLPHighlightsDirectMemory *memory, const uint8_t expectedDigest[CC_SHA256_DIGEST_LENGTH],
    Class const *classes, size_t classCount, const char *expectedImageName,
    const CVLPAdmissionRuntimeCallbacks *callbacks, CVLPAdmissionMetadataResult *result) {
    return CVLPAdmissionAnalyzeImageUsingDigest(imageBase, memory, expectedDigest,
        classes, classCount, expectedImageName, callbacks, result);
}
#endif

static BOOL CVLPAdmissionParseUnsigned(const char *value, uint64_t maximum, uint64_t *parsed) {
    if (value == NULL || value[0] == '\0' || parsed == NULL) { return NO; }
    uint64_t number = 0;
    for (size_t index = 0; value[index] != '\0'; index++) {
        if (value[index] < '0' || value[index] > '9') { return NO; }
        uint8_t digit = (uint8_t)(value[index] - '0');
        if (digit > maximum || number > (maximum - digit) / 10) { return NO; }
        number = number * 10 + digit;
    }
    *parsed = number;
    return YES;
}

static BOOL CVLPAdmissionParseSigned(const char *value, int64_t minimum, int64_t maximum, int64_t *parsed) {
    if (value == NULL || parsed == NULL || value[0] == '\0') { return NO; }
    BOOL negative = value[0] == '-';
    const char *digits = negative ? value + 1 : value;
    uint64_t absoluteMaximum = negative ? (uint64_t)(-(minimum + 1)) + 1 : (uint64_t)maximum;
    uint64_t absolute = 0;
    if (!CVLPAdmissionParseUnsigned(digits, absoluteMaximum, &absolute)) { return NO; }
    int64_t number = negative ? (absolute == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)absolute) :
        (int64_t)absolute;
    if (number < minimum || number > maximum) { return NO; }
    *parsed = number;
    return YES;
}

static BOOL CVLPAdmissionFieldValue(char *token, const char *key, char **value) {
    size_t keyLength = strlen(key);
    if (token == NULL || value == NULL || strncmp(token, key, keyLength) != 0 || token[keyLength] != '=') {
        return NO;
    }
    *value = token + keyLength + 1;
    return **value != '\0';
}

static BOOL CVLPAdmissionUnknownOrValid(const char *value, BOOL (*validator)(const char *)) {
    return strcmp(value, "unknown") == 0 || validator(value);
}

static BOOL CVLPAdmissionLineIsSanitized(NSString *line) {
    if (![line isKindOfClass:NSString.class] || line.length == 0 ||
        line.length > CVLPAdmissionMaximumLineLength) { return NO; }
    const char *utf8 = line.UTF8String;
    if (utf8 == NULL) { return NO; }
    size_t length = 0;
    while (length <= CVLPAdmissionMaximumLineLength && utf8[length] != '\0') {
        if ((unsigned char)utf8[length] < 0x20 || (unsigned char)utf8[length] >= 0x7f) { return NO; }
        length++;
    }
    if (length == 0 || length > CVLPAdmissionMaximumLineLength ||
        (NSUInteger)length != line.length) { return NO; }
    char buffer[CVLPAdmissionMaximumLineLength + 1];
    memcpy(buffer, utf8, length + 1);
    char *tokens[23] = {0};
    size_t tokenCount = 0;
    char *cursor = buffer;
    while (*cursor != '\0') {
        if (tokenCount >= sizeof(tokens) / sizeof(tokens[0]) || *cursor == ' ') { return NO; }
        tokens[tokenCount++] = cursor;
        while (*cursor != '\0' && *cursor != ' ') { cursor++; }
        if (*cursor == ' ') { *cursor++ = '\0'; if (*cursor == '\0' || *cursor == ' ') { return NO; } }
    }
    if (tokenCount != 23 || strcmp(tokens[0], "CVLP_ADMISSION") != 0) { return NO; }
    static const char *globalKeys[] = {
        "seq", "status", "reason", "classes", "methods", "skippedLists", "maxSkipped"
    };
    char *values[23] = {0};
    for (NSUInteger index = 0; index < 7; index++) {
        if (!CVLPAdmissionFieldValue(tokens[index + 1], globalKeys[index], &values[index])) { return NO; }
    }
    uint64_t sequence = 0, classes = 0, methods = 0, skippedLists = 0, maxSkipped = 0;
    int64_t status = 0, reason = 0;
    if (!CVLPAdmissionParseUnsigned(values[0], UINT32_MAX, &sequence) || sequence == 0 ||
        !CVLPAdmissionParseSigned(values[1], CVLPAdmissionStatusUnknown,
            CVLPAdmissionStatusIncomplete, &status) ||
        !CVLPAdmissionParseSigned(values[2], CVLPAdmissionScanReasonNone,
            CVLPAdmissionScanReasonInvalidInput, &reason) ||
        !CVLPAdmissionParseUnsigned(values[3], CVLPAdmissionMaximumClassCount, &classes) ||
        !CVLPAdmissionParseUnsigned(values[4], CVLPAdmissionMaximumMethodTotal(), &methods) ||
        !CVLPAdmissionParseUnsigned(values[5], (uint64_t)CVLPAdmissionMaximumClassCount * 2,
            &skippedLists) ||
        !CVLPAdmissionParseUnsigned(values[6], UINT32_MAX, &maxSkipped)) { return NO; }
    if ((skippedLists == 0 && maxSkipped != 0) ||
        skippedLists > classes * 2 ||
        (skippedLists > 0 && maxSkipped <= CVLPAdmissionMaximumMethodsPerList) ||
        (skippedLists > 0 && (status == CVLPAdmissionStatusMatched ||
            status == CVLPAdmissionStatusNoMatch || status == CVLPAdmissionStatusAmbiguous)) ||
        (status == CVLPAdmissionStatusMethodLimit &&
            (skippedLists == 0 || maxSkipped <= CVLPAdmissionMaximumMethodsPerList ||
                reason != CVLPAdmissionScanReasonMethodCountLimit))) { return NO; }

    static const char *groupKeys[CVLPAdmissionSelectorCount][5] = {
        {"matches0", "selector0", "example0", "return0", "args0"},
        {"matches1", "selector1", "example1", "return1", "args1"},
        {"matches2", "selector2", "example2", "return2", "args2"},
    };
    uint64_t matches[CVLPAdmissionSelectorCount] = {0};
    for (NSUInteger group = 0; group < CVLPAdmissionSelectorCount; group++) {
        char *groupValues[5] = {0};
        for (NSUInteger field = 0; field < 5; field++) {
            NSUInteger tokenIndex = 8 + (group * 5) + field;
            if (!CVLPAdmissionFieldValue(tokens[tokenIndex], groupKeys[group][field], &groupValues[field])) {
                return NO;
            }
        }
        int64_t args = -1;
        if (!CVLPAdmissionParseUnsigned(groupValues[0], CVLPAdmissionMaximumMethodTotal(), &matches[group]) ||
            !CVLPAdmissionUnknownOrValid(groupValues[1], CVLPAdmissionSelectorNameIsSafe) ||
            !CVLPAdmissionUnknownOrValid(groupValues[2], CVLPAdmissionExampleOwnerIsSafe) ||
            strlen(groupValues[3]) != 1 ||
            (groupValues[3][0] != '?' && strchr("cislqCISLQfdBv@#:*", groupValues[3][0]) == NULL) ||
            !CVLPAdmissionParseSigned(groupValues[4], -1, CVLPAdmissionMaximumArguments, &args)) { return NO; }
        if (matches[group] == 0 && (strcmp(groupValues[1], "unknown") != 0 ||
                strcmp(groupValues[2], "unknown") != 0 || groupValues[3][0] != '?' || args != -1)) { return NO; }
        if (matches[group] > 0 && status <= CVLPAdmissionStatusAmbiguous &&
            (strcmp(groupValues[1], "unknown") == 0 || strcmp(groupValues[2], "unknown") == 0)) { return NO; }
        if (matches[group] == 1 && status <= CVLPAdmissionStatusAmbiguous &&
            (groupValues[3][0] == '?' || args < 0)) { return NO; }
        if (matches[group] > 1 && status == CVLPAdmissionStatusAmbiguous &&
            (groupValues[3][0] != '?' || args != -1)) { return NO; }
        if (skippedLists > 0 &&
            (groupValues[3][0] != '?' || args != -1)) { return NO; }
    }
    BOOL anyMatch = matches[0] > 0 || matches[1] > 0 || matches[2] > 0;
    BOOL anyAmbiguous = matches[0] > 1 || matches[1] > 1 || matches[2] > 1;
    if ((status == CVLPAdmissionStatusMatched && (!anyMatch || anyAmbiguous)) ||
        (status == CVLPAdmissionStatusNoMatch && anyMatch) ||
        (status == CVLPAdmissionStatusAmbiguous && !anyAmbiguous)) { return NO; }
    return YES;
}

static NSString *CVLPAdmissionFormatLine(const CVLPAdmissionMetadataResult *result, uint32_t sequence) {
    if (result == NULL || sequence == 0) { return nil; }
    char selector[CVLPAdmissionSelectorCount][CVLPAdmissionSelectorNameCapacity] = {{0}};
    char owner[CVLPAdmissionSelectorCount][CVLPAdmissionExampleNameCapacity] = {{0}};
    char returns[CVLPAdmissionSelectorCount] = {'?', '?', '?'};
    int32_t arguments[CVLPAdmissionSelectorCount] = {-1, -1, -1};
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        (void)CVLPAdmissionSafeCopy(result->selectorNames[index], selector[index], sizeof(selector[index]),
            CVLPAdmissionSelectorNameIsSafe);
        (void)CVLPAdmissionSafeCopy(result->exampleOwners[index], owner[index], sizeof(owner[index]),
            CVLPAdmissionExampleOwnerIsSafe);
        if (result->returnCodes[index] != '\0' &&
            strchr("cislqCISLQfdBv@#:*", result->returnCodes[index]) != NULL) {
            returns[index] = result->returnCodes[index];
        }
        if (result->argumentCounts[index] >= 0 &&
            result->argumentCounts[index] <= CVLPAdmissionMaximumArguments) {
            arguments[index] = result->argumentCounts[index];
        }
        if (result->matchCounts[index] == 0) {
            selector[index][0] = '\0'; owner[index][0] = '\0'; returns[index] = '?'; arguments[index] = -1;
        }
    }
    if (result->skippedLists > 0 || result->status == CVLPAdmissionStatusMethodLimit) {
        for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
            returns[index] = '?';
            arguments[index] = -1;
        }
    }
    NSString *line = [NSString stringWithFormat:
        @"CVLP_ADMISSION seq=%u status=%d reason=%d classes=%u methods=%u skippedLists=%u maxSkipped=%u "
         "matches0=%u selector0=%s example0=%s return0=%c args0=%d "
         "matches1=%u selector1=%s example1=%s return1=%c args1=%d "
         "matches2=%u selector2=%s example2=%s return2=%c args2=%d",
        sequence, result->status, result->reason, result->classesScanned, result->methodsScanned,
        result->skippedLists, result->maxSkipped,
        result->matchCounts[0], selector[0][0] != '\0' ? selector[0] : "unknown",
        owner[0][0] != '\0' ? owner[0] : "unknown", returns[0], arguments[0],
        result->matchCounts[1], selector[1][0] != '\0' ? selector[1] : "unknown",
        owner[1][0] != '\0' ? owner[1] : "unknown", returns[1], arguments[1],
        result->matchCounts[2], selector[2][0] != '\0' ? selector[2] : "unknown",
        owner[2][0] != '\0' ? owner[2] : "unknown", returns[2], arguments[2]];
    return CVLPAdmissionLineIsSanitized(line) ? line : nil;
}

static NSString *CVLPAdmissionBuildLine(CVLPAdmissionStatus status, CVLPAdmissionScanReason reason,
    uint32_t sequence) {
    CVLPAdmissionMetadataResult result = {0};
    result.status = status;
    result.reason = reason;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        result.argumentCounts[index] = -1;
        result.returnCodes[index] = '?';
    }
    return CVLPAdmissionFormatLine(&result, sequence);
}

static NSString *CVLPAdmissionMetadataLineForAnchor(Class anchor, uint32_t sequence) {
    int incomingErrno = errno;
    if (sequence == 0) {
        errno = incomingErrno;
        return nil;
    }

    CVLPAdmissionMetadataResult result;
    CVLPAdmissionInitializeResult(&result);
    result.status = CVLPAdmissionStatusImageUnavailable;
    result.reason = CVLPAdmissionScanReasonAnchorUnavailable;
    NSString *line = nil;
    const char **classNames = NULL;
    Class __unsafe_unretained *classes = NULL;
    unsigned int classNameCount = 0;
    CFTimeInterval startedAt = CACurrentMediaTime();
    CFTimeInterval deadlineAt = startedAt + CVLPAdmissionScanDeadline;

    @try {
        do {
            if (!isfinite(startedAt) || !isfinite(deadlineAt) || anchor == Nil) { break; }
            const char *anchorImage = class_getImageName(anchor);
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            if (anchorImage == NULL || anchorImage[0] == '\0' ||
                !CVLPAdmissionBoundedCStringEquals(anchorImage, anchorImage, PATH_MAX)) { break; }

            Dl_info imageInfo = {0};
            int resolved = dladdr((__bridge const void *)anchor, &imageInfo);
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            if (!resolved || imageInfo.dli_fbase == NULL || imageInfo.dli_fname == NULL ||
                !CVLPAdmissionBoundedCStringEquals(anchorImage, imageInfo.dli_fname, PATH_MAX)) {
                result.reason = CVLPAdmissionScanReasonAnchorImageMismatch;
                break;
            }

            CVLPHighlightsDirectMemory memory = {
                .regionAllows = CVLPHighlightsDirectMachRegionAllows,
                .read = CVLPHighlightsDirectMachRead,
                .compareExchange = NULL,
                .context = NULL,
            };
            CVLPAdmissionValidatedImage validated = {0};
            CVLPAdmissionStatus validationStatus = CVLPAdmissionValidateImage(
                (uintptr_t)imageInfo.dli_fbase, &memory, &validated);
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            if (validationStatus != CVLPAdmissionStatusMatched) {
                result.status = validationStatus;
                if (validationStatus == CVLPAdmissionStatusInvalidInput) {
                    result.reason = CVLPAdmissionScanReasonInvalidInput;
                } else {
                    result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                }
                break;
            }

            classNames = objc_copyClassNamesForImage(anchorImage, &classNameCount);
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            if (classNames == NULL || classNameCount == 0) {
                result.status = CVLPAdmissionStatusIncomplete;
                result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                break;
            }
            if (classNameCount > CVLPAdmissionMaximumClassCount) {
                result.status = CVLPAdmissionStatusClassLimit;
                result.reason = CVLPAdmissionScanReasonClassCountLimit;
                break;
            }
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            classes = (Class __unsafe_unretained *)calloc(classNameCount, sizeof(*classes));
            if (CACurrentMediaTime() >= deadlineAt) {
                result.status = CVLPAdmissionStatusDeadline;
                result.reason = CVLPAdmissionScanReasonDeadline;
                break;
            }
            if (classes == NULL) {
                result.status = CVLPAdmissionStatusIncomplete;
                result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                break;
            }

            BOOL namesComplete = YES;
            for (unsigned int index = 0; index < classNameCount; index++) {
                if (CACurrentMediaTime() >= deadlineAt) {
                    result.status = CVLPAdmissionStatusDeadline;
                    result.reason = CVLPAdmissionScanReasonDeadline;
                    namesComplete = NO;
                    break;
                }
                const char *name = classNames[index];
                if (name == NULL || strnlen(name, 513) >= 513) {
                    result.status = CVLPAdmissionStatusIncomplete;
                    result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                    namesComplete = NO;
                    break;
                }
                classes[index] = objc_lookUpClass(name);
                if (CACurrentMediaTime() >= deadlineAt) {
                    result.status = CVLPAdmissionStatusDeadline;
                    result.reason = CVLPAdmissionScanReasonDeadline;
                    namesComplete = NO;
                    break;
                }
                if (classes[index] == Nil) {
                    result.status = CVLPAdmissionStatusIncomplete;
                    result.reason = CVLPAdmissionScanReasonMissingClass;
                    namesComplete = NO;
                    break;
                }
            }
            if (!namesComplete) { break; }

            CVLPAdmissionRuntimeCallbacks callbacks = {
                .clock = CVLPAdmissionDefaultClock,
                .imageName = CVLPAdmissionDefaultImageName,
                .context = NULL,
                .deadlineAt = deadlineAt,
            };
            (void)CVLPAdmissionAnalyzeImage((uintptr_t)imageInfo.dli_fbase, &memory,
                classes, classNameCount, anchorImage, &callbacks, &result);
        } while (0);
    } @catch (__unused NSException *exception) {
        CVLPAdmissionInitializeResult(&result);
        result.status = CVLPAdmissionStatusIncomplete;
        result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
    }
    free(classes);
    free(classNames);

    if (!isfinite(startedAt) || !isfinite(deadlineAt) || CACurrentMediaTime() >= deadlineAt) {
        CVLPAdmissionInitializeResult(&result);
        result.status = CVLPAdmissionStatusDeadline;
        result.reason = CVLPAdmissionScanReasonDeadline;
    }
    @try {
        line = CVLPAdmissionFormatLine(&result, sequence);
        if (CACurrentMediaTime() >= deadlineAt) {
            CVLPAdmissionInitializeResult(&result);
            result.status = CVLPAdmissionStatusDeadline;
            result.reason = CVLPAdmissionScanReasonDeadline;
            line = CVLPAdmissionBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
        if (line == nil) {
            CVLPAdmissionInitializeResult(&result);
            result.status = CVLPAdmissionStatusIncomplete;
            result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
            line = CVLPAdmissionBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
        if (CACurrentMediaTime() >= deadlineAt) {
            CVLPAdmissionInitializeResult(&result);
            result.status = CVLPAdmissionStatusDeadline;
            result.reason = CVLPAdmissionScanReasonDeadline;
            line = CVLPAdmissionBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
    } @catch (__unused NSException *exception) {
        CVLPAdmissionInitializeResult(&result);
        result.status = CVLPAdmissionStatusIncomplete;
        result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
        line = nil;
    }
    errno = incomingErrno;
    return line;
}

NS_ASSUME_NONNULL_END

#endif // CVLP_HIGHLIGHTS_ADMISSION_METADATA

#endif // CVLP_ADMISSION_METADATA_H
