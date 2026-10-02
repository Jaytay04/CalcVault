#ifndef CVLP_ADMISSION_OWNER_METADATA_H
#define CVLP_ADMISSION_OWNER_METADATA_H

#ifndef CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA
#define CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA 0
#endif

#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA != 0 && CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA != 1
#error CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA must be 0 or 1
#endif

#import "CVLPAdmissionMetadata.h"

#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA && !CVLP_HIGHLIGHTS_ADMISSION_METADATA
#error Owner metadata requires CVLP_HIGHLIGHTS_ADMISSION_METADATA
#endif

#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA || defined(CVLP_HIGHLIGHTS_TESTING)

NS_ASSUME_NONNULL_BEGIN

enum {
    CVLPAdmissionOwnerMaximumLineLength = 1024,
};

typedef struct {
    int status;
    int reason;
    uint32_t classesScanned;
    uint32_t methodsScanned;
    uint32_t skippedLists;
    uint32_t maxSkipped;
    uint32_t matches;
    char selectorName[CVLPAdmissionSelectorNameCapacity];
    char ownerName[CVLPAdmissionExampleNameCapacity];
    char kind;
    char returnCode;
    int32_t argumentCount;
} CVLPAdmissionOwnerMetadataResult;

// Testing-only injection lets native fixtures compare declarations against a
// harmless compiled IMP. Production always derives the target from the pin.
#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionOwnerScanProvidedClasses(
    const CVLPAdmissionValidatedImage *validated, Class const *classes, size_t classCount,
    const char *expectedImageName, uintptr_t targetIMP,
    const CVLPAdmissionRuntimeCallbacks *callbacks, const CVLPHighlightsDirectMemory *memory,
    CVLPAdmissionOwnerMetadataResult *result);
#endif

static BOOL CVLPAdmissionOwnerLineIsSanitized(NSString *line);
static NSString *CVLPAdmissionOwnerFormatLine(const CVLPAdmissionOwnerMetadataResult *result,
    uint32_t sequence);

// Production enumeration is scoped by the already validated Mach header.
static NSString *CVLPAdmissionOwnerMetadataLineForAnchor(Class anchor, uint32_t sequence);

typedef struct {
    const CVLPAdmissionValidatedImage *validated;
    const char *expectedImageName;
    uintptr_t targetIMP;
    const CVLPAdmissionRuntimeCallbacks *callbacks;
    const CVLPHighlightsDirectMemory *memory;
    CFTimeInterval deadlineAt;
    CVLPAdmissionOwnerMetadataResult *result;
    CVLPAdmissionStatus terminal;
    BOOL metadataIncomplete;
} CVLPAdmissionOwnerScanContext;

static CFTimeInterval CVLPAdmissionOwnerClock(const CVLPAdmissionRuntimeCallbacks *callbacks) {
    CFTimeInterval (*clockFunction)(void *) = callbacks != NULL && callbacks->clock != NULL ?
        callbacks->clock : CVLPAdmissionDefaultClock;
    return clockFunction(callbacks != NULL ? callbacks->context : NULL);
}

static BOOL CVLPAdmissionOwnerDeadlineReached(const CVLPAdmissionOwnerScanContext *context) {
    CFTimeInterval now = CVLPAdmissionOwnerClock(context != NULL ? context->callbacks : NULL);
    return context == NULL || !isfinite(now) || now >= context->deadlineAt;
}

static void CVLPAdmissionOwnerClear(CVLPAdmissionOwnerMetadataResult *result, BOOL clearSelector) {
    if (result == NULL) { return; }
    if (clearSelector) { result->selectorName[0] = '\0'; }
    result->ownerName[0] = '\0';
    result->kind = '?';
    result->returnCode = '?';
    result->argumentCount = -1;
}

static void CVLPAdmissionOwnerSetReason(CVLPAdmissionOwnerMetadataResult *result, int reason) {
    if (result != NULL && result->reason == CVLPAdmissionScanReasonNone) { result->reason = reason; }
}

static BOOL CVLPAdmissionOwnerRecordMethod(Method method, Class owner,
    CVLPAdmissionOwnerScanContext *context) {
    if (method == NULL || owner == Nil || context == NULL || context->result == NULL ||
        CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }

    IMP implementation = method_getImplementation(method);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    if ((uintptr_t)implementation != context->targetIMP) { return YES; }

    SEL selector = method_getName(method);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    const char *selectorName = selector != NULL ? sel_getName(selector) : NULL;
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    const char *className = class_getName(owner);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    const char *types = method_getTypeEncoding(method);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }
    BOOL isMetaclass = class_isMetaClass(owner);
    if (CVLPAdmissionOwnerDeadlineReached(context)) { return NO; }

    CVLPAdmissionOwnerMetadataResult *result = context->result;
    if (result->matches < CVLPAdmissionMaximumMethodTotal()) { result->matches++; }
    if (result->matches == 1) {
        BOOL selectorSafe = CVLPAdmissionSafeCopy(selectorName, result->selectorName,
            sizeof(result->selectorName), CVLPAdmissionSelectorNameIsSafe);
        BOOL ownerSafe = CVLPAdmissionSafeCopy(className, result->ownerName,
            sizeof(result->ownerName), CVLPAdmissionExampleOwnerIsSafe);
        char returnCode = CVLPAdmissionReturnCode(types);
        result->kind = isMetaclass ? '1' : '0';
        result->returnCode = returnCode;
        if (argumentCount <= CVLPAdmissionMaximumArguments) {
            result->argumentCount = (int32_t)argumentCount;
        }
        if (!selectorSafe || !ownerSafe || returnCode == '?' || result->argumentCount < 0) {
            context->metadataIncomplete = YES;
            CVLPAdmissionOwnerSetReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
        }
    } else if (result->matches == 2) {
        // Multiple declarations can use the same IMP under different selectors
        // or owners; retain only the lower-bound count.
        CVLPAdmissionOwnerClear(result, YES);
    }
    return YES;
}

static CVLPAdmissionStatus CVLPAdmissionOwnerScanMethodList(Class owner,
    CVLPAdmissionOwnerScanContext *context) {
    if (owner == Nil || context == NULL || context->result == NULL) {
        return CVLPAdmissionStatusInvalidClass;
    }
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        free(methods);
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    if (count > 0 && methods == NULL) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
        return CVLPAdmissionStatusIncomplete;
    }
    if (count > CVLPAdmissionMaximumMethodsPerList) {
        free(methods);
        if (context->result->skippedLists < CVLPAdmissionMaximumClassCount * 2U) {
            context->result->skippedLists++;
        }
        if (count > context->result->maxSkipped) { context->result->maxSkipped = count; }
        return CVLPAdmissionOwnerDeadlineReached(context) ? CVLPAdmissionStatusDeadline :
            CVLPAdmissionStatusUnknown;
    }
    for (unsigned int index = 0; index < count; index++) {
        if (CVLPAdmissionOwnerDeadlineReached(context)) {
            free(methods);
            CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
            return CVLPAdmissionStatusDeadline;
        }
        if (context->result->methodsScanned < CVLPAdmissionMaximumMethodTotal()) {
            context->result->methodsScanned++;
        }
        if (!CVLPAdmissionOwnerRecordMethod(methods[index], owner, context)) {
            free(methods);
            CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
            return CVLPAdmissionStatusDeadline;
        }
    }
    free(methods);
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    return CVLPAdmissionStatusUnknown;
}

static CVLPAdmissionStatus CVLPAdmissionOwnerScanClass(Class cls,
    CVLPAdmissionOwnerScanContext *context) {
    if (context == NULL || context->result == NULL) { return CVLPAdmissionStatusInvalidInput; }
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    if (cls == Nil) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonMissingClass);
        return CVLPAdmissionStatusInvalidClass;
    }
    const char *(*imageNameFunction)(Class, void *) = context->callbacks != NULL &&
        context->callbacks->imageName != NULL ? context->callbacks->imageName : NULL;
    const char *classImage = imageNameFunction != NULL ?
        imageNameFunction(cls, context->callbacks->context) : class_getImageName(cls);
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    if (!CVLPAdmissionBoundedCStringEquals(classImage, context->expectedImageName, PATH_MAX)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonClassImageMismatch);
        return CVLPAdmissionStatusImageMismatch;
    }
    if (context->result->classesScanned >= CVLPAdmissionMaximumClassCount) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonClassCountLimit);
        return CVLPAdmissionStatusClassLimit;
    }
    context->result->classesScanned++;

    CVLPAdmissionStatus status = CVLPAdmissionOwnerScanMethodList(cls, context);
    if (status != CVLPAdmissionStatusUnknown) { return status; }
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    Class metaclass = object_getClass(cls);
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        return CVLPAdmissionStatusDeadline;
    }
    if (metaclass == Nil) {
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
        return CVLPAdmissionStatusIncomplete;
    }
    return CVLPAdmissionOwnerScanMethodList(metaclass, context);
}

static void CVLPAdmissionOwnerInitialize(CVLPAdmissionOwnerMetadataResult *result) {
    if (result == NULL) { return; }
    memset(result, 0, sizeof(*result));
    result->status = CVLPAdmissionStatusUnknown;
    result->kind = '?';
    result->returnCode = '?';
    result->argumentCount = -1;
}

static CVLPAdmissionStatus CVLPAdmissionOwnerFinalize(CVLPAdmissionOwnerScanContext *context,
    BOOL coverageComplete) {
    if (context == NULL || context->result == NULL || context->validated == NULL || context->memory == NULL) {
        return CVLPAdmissionStatusInvalidInput;
    }
    CVLPAdmissionOwnerMetadataResult *result = context->result;
    CVLPAdmissionStatus terminal = context->terminal;
    if (terminal == CVLPAdmissionStatusUnknown && !coverageComplete) {
        terminal = CVLPAdmissionStatusIncomplete;
        CVLPAdmissionOwnerSetReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
    }
    if (terminal == CVLPAdmissionStatusUnknown) {
        if (result->skippedLists > 0) {
            terminal = CVLPAdmissionStatusMethodLimit;
            result->reason = CVLPAdmissionScanReasonMethodCountLimit;
        } else if (context->metadataIncomplete) {
            terminal = CVLPAdmissionStatusIncomplete;
            CVLPAdmissionOwnerSetReason(result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
        } else if (result->matches == 0) {
            terminal = CVLPAdmissionStatusNoMatch;
        } else if (result->matches == 1) {
            terminal = CVLPAdmissionStatusMatched;
        } else {
            terminal = CVLPAdmissionStatusAmbiguous;
        }
    }

    BOOL deadlineExpired = terminal == CVLPAdmissionStatusDeadline ||
        CVLPAdmissionOwnerDeadlineReached(context);
    CVLPAdmissionStatus referenceStatus = CVLPAdmissionStatusUnknown;
    if (!deadlineExpired) {
        referenceStatus = CVLPAdmissionRecheckReferences(context->validated, context->memory);
        deadlineExpired = CVLPAdmissionOwnerDeadlineReached(context);
    }
    if (deadlineExpired) {
        terminal = CVLPAdmissionStatusDeadline;
        result->reason = CVLPAdmissionScanReasonDeadline;
        CVLPAdmissionOwnerClear(result, YES);
    } else if (referenceStatus != CVLPAdmissionStatusMatched) {
        if (referenceStatus == CVLPAdmissionStatusSelectorChanged) {
            terminal = CVLPAdmissionStatusSelectorChanged;
            result->reason = CVLPAdmissionScanReasonSelectorChanged;
        } else {
            terminal = referenceStatus == CVLPAdmissionStatusInvalidInput ?
                CVLPAdmissionStatusInvalidInput : CVLPAdmissionStatusIncomplete;
            result->reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
        }
        CVLPAdmissionOwnerClear(result, YES);
    } else if (terminal != CVLPAdmissionStatusMatched) {
        // An observed declaration is only a lower bound unless the entire image
        // was scanned and exactly one matching Method was found.
        CVLPAdmissionOwnerClear(result, result->matches > 1);
    }
    if (terminal == CVLPAdmissionStatusAmbiguous) {
        CVLPAdmissionOwnerClear(result, YES);
    }
    result->status = terminal;
    return terminal;
}

#if defined(CVLP_HIGHLIGHTS_TESTING)
static CVLPAdmissionStatus CVLPAdmissionOwnerScanProvidedClasses(
    const CVLPAdmissionValidatedImage *validated, Class const *classes, size_t classCount,
    const char *expectedImageName, uintptr_t targetIMP,
    const CVLPAdmissionRuntimeCallbacks *callbacks, const CVLPHighlightsDirectMemory *memory,
    CVLPAdmissionOwnerMetadataResult *result) {
    if (result == NULL) { return CVLPAdmissionStatusInvalidInput; }
    CVLPAdmissionOwnerInitialize(result);
    if (validated == NULL || validated->imageBase == 0 || classes == NULL || classCount == 0 ||
        classCount > CVLPAdmissionMaximumClassCount || expectedImageName == NULL ||
        expectedImageName[0] == '\0' || !CVLPAdmissionBoundedCStringEquals(expectedImageName,
            expectedImageName, PATH_MAX) || targetIMP == 0 || memory == NULL || memory->read == NULL ||
        memory->regionAllows == NULL) {
        result->status = classCount > CVLPAdmissionMaximumClassCount ?
            CVLPAdmissionStatusClassLimit : CVLPAdmissionStatusInvalidInput;
        result->reason = classCount > CVLPAdmissionMaximumClassCount ?
            CVLPAdmissionScanReasonClassCountLimit : CVLPAdmissionScanReasonInvalidInput;
        return (CVLPAdmissionStatus)result->status;
    }
    int incomingErrno = errno;
    CFTimeInterval startedAt = CVLPAdmissionOwnerClock(callbacks);
    CFTimeInterval deadlineAt = startedAt + CVLPAdmissionScanDeadline;
    if (callbacks != NULL && callbacks->deadlineAt > 0.0 && callbacks->deadlineAt < deadlineAt) {
        deadlineAt = callbacks->deadlineAt;
    }
    if (!isfinite(startedAt) || !isfinite(deadlineAt) || deadlineAt <= startedAt) {
        result->status = CVLPAdmissionStatusDeadline;
        result->reason = CVLPAdmissionScanReasonDeadline;
        errno = incomingErrno;
        return (CVLPAdmissionStatus)result->status;
    }
    CVLPAdmissionOwnerScanContext context = {
        .validated = validated,
        .expectedImageName = expectedImageName,
        .targetIMP = targetIMP,
        .callbacks = callbacks,
        .memory = memory,
        .deadlineAt = deadlineAt,
        .result = result,
        .terminal = CVLPAdmissionStatusUnknown,
        .metadataIncomplete = NO,
    };
    BOOL complete = YES;
    for (size_t index = 0; index < classCount; index++) {
        CVLPAdmissionStatus status = CVLPAdmissionOwnerScanClass(classes[index], &context);
        if (status != CVLPAdmissionStatusUnknown) {
            context.terminal = status;
            complete = NO;
            break;
        }
    }
    CVLPAdmissionStatus status = CVLPAdmissionOwnerFinalize(&context, complete);
    errno = incomingErrno;
    return status;
}
#endif

static BOOL CVLPAdmissionOwnerParseUnsigned(const char *value, uint64_t maximum, uint64_t *parsed) {
    return CVLPAdmissionParseUnsigned(value, maximum, parsed);
}

static BOOL CVLPAdmissionOwnerLineIsSanitized(NSString *line) {
    if (![line isKindOfClass:NSString.class] || line.length == 0 ||
        line.length > CVLPAdmissionOwnerMaximumLineLength) { return NO; }
    const char *utf8 = line.UTF8String;
    if (utf8 == NULL) { return NO; }
    size_t length = 0;
    while (length <= CVLPAdmissionOwnerMaximumLineLength && utf8[length] != '\0') {
        unsigned char byte = (unsigned char)utf8[length];
        if (byte < 0x20 || byte >= 0x7f) { return NO; }
        length++;
    }
    if (length == 0 || length > CVLPAdmissionOwnerMaximumLineLength ||
        (NSUInteger)length != line.length) { return NO; }
    char buffer[CVLPAdmissionOwnerMaximumLineLength + 1];
    memcpy(buffer, utf8, length + 1);
    char *tokens[15] = {0};
    size_t tokenCount = 0;
    char *cursor = buffer;
    while (*cursor != '\0') {
        if (tokenCount >= sizeof(tokens) / sizeof(tokens[0]) || *cursor == ' ') { return NO; }
        tokens[tokenCount++] = cursor;
        while (*cursor != '\0' && *cursor != ' ') { cursor++; }
        if (*cursor == ' ') {
            *cursor++ = '\0';
            if (*cursor == '\0' || *cursor == ' ') { return NO; }
        }
    }
    if (tokenCount != 15 || strcmp(tokens[0], "CVLP_ADMISSION_OWNER") != 0 ||
        strcmp(tokens[14], "callable=0") != 0) { return NO; }
    static const char *keys[] = {"seq", "status", "reason", "classes", "methods", "skippedLists",
        "maxSkipped", "matches", "selector", "owner", "kind", "return", "args"};
    char *values[13] = {0};
    for (NSUInteger index = 0; index < 13; index++) {
        if (!CVLPAdmissionFieldValue(tokens[index + 1], keys[index], &values[index])) { return NO; }
    }
    uint64_t sequence = 0, classes = 0, methods = 0, skipped = 0, maxSkipped = 0, matches = 0;
    int64_t status = 0, reason = 0, arguments = -1;
    if (!CVLPAdmissionOwnerParseUnsigned(values[0], UINT32_MAX, &sequence) || sequence == 0 ||
        !CVLPAdmissionParseSigned(values[1], CVLPAdmissionStatusUnknown,
            CVLPAdmissionStatusIncomplete, &status) ||
        !CVLPAdmissionParseSigned(values[2], CVLPAdmissionScanReasonNone,
            CVLPAdmissionScanReasonInvalidInput, &reason) ||
        !CVLPAdmissionOwnerParseUnsigned(values[3], CVLPAdmissionMaximumClassCount, &classes) ||
        !CVLPAdmissionOwnerParseUnsigned(values[4], CVLPAdmissionMaximumMethodTotal(), &methods) ||
        !CVLPAdmissionOwnerParseUnsigned(values[5], (uint64_t)CVLPAdmissionMaximumClassCount * 2,
            &skipped) || !CVLPAdmissionOwnerParseUnsigned(values[6], UINT32_MAX, &maxSkipped) ||
        !CVLPAdmissionOwnerParseUnsigned(values[7], CVLPAdmissionMaximumMethodTotal(), &matches) ||
        !CVLPAdmissionParseSigned(values[12], -1, CVLPAdmissionMaximumArguments, &arguments)) { return NO; }
    if ((skipped == 0 && maxSkipped != 0) || (skipped > 0 &&
            (maxSkipped <= CVLPAdmissionMaximumMethodsPerList || skipped > classes * 2)) ||
        (matches > methods) ||
        (status == CVLPAdmissionStatusMethodLimit &&
            (skipped == 0 || reason != CVLPAdmissionScanReasonMethodCountLimit)) ||
        (skipped > 0 && (status == CVLPAdmissionStatusMatched || status == CVLPAdmissionStatusNoMatch ||
            status == CVLPAdmissionStatusAmbiguous))) { return NO; }

    BOOL selectorUnknown = strcmp(values[8], "unknown") == 0;
    BOOL ownerUnknown = strcmp(values[9], "unknown") == 0;
    if (!selectorUnknown && !CVLPAdmissionSelectorNameIsSafe(values[8])) { return NO; }
    if (!ownerUnknown && !CVLPAdmissionExampleOwnerIsSafe(values[9])) { return NO; }
    if ((status == CVLPAdmissionStatusDeadline || status == CVLPAdmissionStatusSelectorChanged) &&
        !selectorUnknown) { return NO; }
    BOOL kindKnown = strcmp(values[10], "0") == 0 || strcmp(values[10], "1") == 0;
    if (!kindKnown && strcmp(values[10], "?") != 0) { return NO; }
    if (strlen(values[11]) != 1 || (values[11][0] != '?' &&
        strchr("cislqCISLQfdBv@#:*", values[11][0]) == NULL)) { return NO; }

    if (matches == 0 && (!selectorUnknown || !ownerUnknown || kindKnown || values[11][0] != '?' ||
            arguments != -1)) { return NO; }
    if (matches > 1 && !selectorUnknown) { return NO; }
    if (matches == 1 && status == CVLPAdmissionStatusMatched &&
        (selectorUnknown || ownerUnknown || !kindKnown || values[11][0] == '?' || arguments < 0 ||
            skipped > 0)) { return NO; }
    if (matches > 1 && (status == CVLPAdmissionStatusAmbiguous || skipped > 0) &&
        (!selectorUnknown || !ownerUnknown || kindKnown || values[11][0] != '?' || arguments != -1)) {
        return NO;
    }
    if (status != CVLPAdmissionStatusMatched &&
        (kindKnown || values[11][0] != '?' || arguments != -1 || !ownerUnknown)) { return NO; }
    if ((status == CVLPAdmissionStatusMatched && matches != 1) ||
        (status == CVLPAdmissionStatusNoMatch && matches != 0) ||
        (status == CVLPAdmissionStatusAmbiguous && matches < 2) ||
        ((status == CVLPAdmissionStatusDeadline || status == CVLPAdmissionStatusSelectorChanged) &&
            (!selectorUnknown || !ownerUnknown))) { return NO; }
    return YES;
}

static NSString *CVLPAdmissionOwnerFormatLine(const CVLPAdmissionOwnerMetadataResult *result,
    uint32_t sequence) {
    if (result == NULL || sequence == 0) { return nil; }
    char selector[CVLPAdmissionSelectorNameCapacity] = {0};
    char owner[CVLPAdmissionExampleNameCapacity] = {0};
    (void)CVLPAdmissionSafeCopy(result->selectorName, selector, sizeof(selector),
        CVLPAdmissionSelectorNameIsSafe);
    (void)CVLPAdmissionSafeCopy(result->ownerName, owner, sizeof(owner),
        CVLPAdmissionExampleOwnerIsSafe);
    char kind = result->kind == '0' || result->kind == '1' ? result->kind : '?';
    char returnCode = result->returnCode != '\0' &&
        strchr("cislqCISLQfdBv@#:*", result->returnCode) != NULL ? result->returnCode : '?';
    int32_t arguments = result->argumentCount >= 0 &&
        result->argumentCount <= CVLPAdmissionMaximumArguments ? result->argumentCount : -1;
    if (result->matches == 0) {
        selector[0] = '\0'; owner[0] = '\0'; kind = '?'; returnCode = '?'; arguments = -1;
    }
    if (result->status != CVLPAdmissionStatusMatched || result->skippedLists > 0) {
        owner[0] = '\0'; kind = '?'; returnCode = '?'; arguments = -1;
    }
    if (result->matches > 1) { selector[0] = '\0'; owner[0] = '\0'; }
    if (result->status == CVLPAdmissionStatusDeadline ||
        result->status == CVLPAdmissionStatusSelectorChanged) {
        selector[0] = '\0'; owner[0] = '\0'; kind = '?'; returnCode = '?'; arguments = -1;
    }
    NSString *line = [NSString stringWithFormat:
        @"CVLP_ADMISSION_OWNER seq=%u status=%d reason=%d classes=%u methods=%u skippedLists=%u maxSkipped=%u "
         "matches=%u selector=%s owner=%s kind=%c return=%c args=%d callable=0",
        sequence, result->status, result->reason, result->classesScanned, result->methodsScanned,
        result->skippedLists, result->maxSkipped, result->matches,
        selector[0] != '\0' ? selector : "unknown", owner[0] != '\0' ? owner : "unknown",
        kind, returnCode, arguments];
    return CVLPAdmissionOwnerLineIsSanitized(line) ? line : nil;
}

static NSString *CVLPAdmissionOwnerBuildLine(CVLPAdmissionStatus status,
    CVLPAdmissionScanReason reason, uint32_t sequence) {
    CVLPAdmissionOwnerMetadataResult result;
    CVLPAdmissionOwnerInitialize(&result);
    result.status = status;
    result.reason = reason;
    return CVLPAdmissionOwnerFormatLine(&result, sequence);
}

typedef struct {
    CVLPAdmissionOwnerScanContext *scan;
} CVLPAdmissionOwnerEnumerationContext;

static void CVLPAdmissionOwnerEnumerateClass(Class cls, BOOL *stop,
    const CVLPAdmissionOwnerEnumerationContext *enumeration) {
    if (stop == NULL || enumeration == NULL || enumeration->scan == NULL) { return; }
    CVLPAdmissionOwnerScanContext *context = enumeration->scan;
    if (CVLPAdmissionOwnerDeadlineReached(context)) {
        context->terminal = CVLPAdmissionStatusDeadline;
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonDeadline);
        *stop = YES;
        return;
    }
    if (context->result->classesScanned >= CVLPAdmissionMaximumClassCount) {
        context->terminal = CVLPAdmissionStatusClassLimit;
        CVLPAdmissionOwnerSetReason(context->result, CVLPAdmissionScanReasonClassCountLimit);
        *stop = YES;
        return;
    }
    CVLPAdmissionStatus status = CVLPAdmissionOwnerScanClass(cls, context);
    if (status != CVLPAdmissionStatusUnknown) {
        context->terminal = status;
        *stop = YES;
    }
}

static NSString *CVLPAdmissionOwnerMetadataLineForAnchor(Class anchor, uint32_t sequence) {
    int incomingErrno = errno;
    if (sequence == 0) { errno = incomingErrno; return nil; }

    CVLPAdmissionOwnerMetadataResult result;
    CVLPAdmissionOwnerInitialize(&result);
    result.status = CVLPAdmissionStatusImageUnavailable;
    result.reason = CVLPAdmissionScanReasonAnchorUnavailable;
    NSString *line = nil;
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
                result.reason = validationStatus == CVLPAdmissionStatusInvalidInput ?
                    CVLPAdmissionScanReasonInvalidInput : CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                break;
            }

            uintptr_t targetIMP = 0;
            if (!CVLPHighlightsDirectAddress(validated.imageBase, CVLPAdmissionFunctionVM, &targetIMP)) {
                result.status = CVLPAdmissionStatusMappingRejected;
                result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
                break;
            }
            CVLPAdmissionRuntimeCallbacks callbacks = {
                .clock = CVLPAdmissionDefaultClock,
                .imageName = NULL,
                .context = NULL,
                .deadlineAt = deadlineAt,
            };
            CVLPAdmissionOwnerScanContext scan = {
                .validated = &validated,
                .expectedImageName = anchorImage,
                .targetIMP = targetIMP,
                .callbacks = &callbacks,
                .memory = &memory,
                .deadlineAt = deadlineAt,
                .result = &result,
                .terminal = CVLPAdmissionStatusUnknown,
                .metadataIncomplete = NO,
            };
            CVLPAdmissionOwnerEnumerationContext enumeration = {.scan = &scan};
            if (CACurrentMediaTime() >= deadlineAt) {
                scan.terminal = CVLPAdmissionStatusDeadline;
                CVLPAdmissionOwnerSetReason(&result, CVLPAdmissionScanReasonDeadline);
                (void)CVLPAdmissionOwnerFinalize(&scan, NO);
                break;
            }
            if (@available(iOS 16.0, *)) {
                objc_enumerateClasses((const void *)validated.imageBase, NULL, NULL, Nil,
                    ^(Class cls, BOOL *stop) {
                        CVLPAdmissionOwnerEnumerateClass(cls, stop, &enumeration);
                    });
            } else {
                scan.terminal = CVLPAdmissionStatusIncomplete;
                CVLPAdmissionOwnerSetReason(&result, CVLPAdmissionScanReasonInvalidRuntimeMetadata);
            }
            BOOL complete = scan.terminal == CVLPAdmissionStatusUnknown;
            (void)CVLPAdmissionOwnerFinalize(&scan, complete);
        } while (0);
    } @catch (__unused NSException *exception) {
        CVLPAdmissionOwnerInitialize(&result);
        result.status = CVLPAdmissionStatusIncomplete;
        result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
    }

    if (!isfinite(startedAt) || !isfinite(deadlineAt) || CACurrentMediaTime() >= deadlineAt) {
        CVLPAdmissionOwnerInitialize(&result);
        result.status = CVLPAdmissionStatusDeadline;
        result.reason = CVLPAdmissionScanReasonDeadline;
    }
    @try {
        line = CVLPAdmissionOwnerFormatLine(&result, sequence);
        if (CACurrentMediaTime() >= deadlineAt) {
            CVLPAdmissionOwnerInitialize(&result);
            result.status = CVLPAdmissionStatusDeadline;
            result.reason = CVLPAdmissionScanReasonDeadline;
            line = CVLPAdmissionOwnerBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
        if (line == nil) {
            CVLPAdmissionOwnerInitialize(&result);
            result.status = CVLPAdmissionStatusIncomplete;
            result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
            line = CVLPAdmissionOwnerBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
        if (CACurrentMediaTime() >= deadlineAt) {
            CVLPAdmissionOwnerInitialize(&result);
            result.status = CVLPAdmissionStatusDeadline;
            result.reason = CVLPAdmissionScanReasonDeadline;
            line = CVLPAdmissionOwnerBuildLine((CVLPAdmissionStatus)result.status,
                (CVLPAdmissionScanReason)result.reason, sequence);
        }
    } @catch (__unused NSException *exception) {
        CVLPAdmissionOwnerInitialize(&result);
        result.status = CVLPAdmissionStatusIncomplete;
        result.reason = CVLPAdmissionScanReasonInvalidRuntimeMetadata;
        line = nil;
    }
    errno = incomingErrno;
    return line;
}

NS_ASSUME_NONNULL_END

#endif // CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA || CVLP_HIGHLIGHTS_TESTING

#endif // CVLP_ADMISSION_OWNER_METADATA_H
