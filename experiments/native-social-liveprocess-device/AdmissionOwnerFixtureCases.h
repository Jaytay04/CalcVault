#ifndef CVLP_ADMISSION_OWNER_FIXTURE_CASES_H
#define CVLP_ADMISSION_OWNER_FIXTURE_CASES_H

#import <objc/runtime.h>
#import <dlfcn.h>
#import "AdmissionMetadataFixtureCases.h"
#import "CVLPAdmissionOwnerMetadata.h"

// Every implementation below is a disposable sentinel. Discovery may inspect
// its IMP and type metadata, but calling it changes a counter and fails cases.
static NSUInteger CVLPAdmissionOwnerFixtureMethodCalls;
static NSUInteger CVLPAdmissionOwnerFixtureGetterCalls;

@interface CVLPAdmissionOwnerFixtureEnumerationProbe : NSObject
- (int32_t)cvlpAdmissionOwnerFixtureGetter;
@end

@implementation CVLPAdmissionOwnerFixtureEnumerationProbe
- (int32_t)cvlpAdmissionOwnerFixtureGetter {
    CVLPAdmissionOwnerFixtureGetterCalls++;
    return 47;
}
@end

@interface CVLPAdmissionFixtureDuplicateB (CVLPAdmissionOwnerCategoryFixture)
- (int32_t)cvlpAdmissionOwnerCategoryCollision;
@end

@implementation CVLPAdmissionFixtureDuplicateB (CVLPAdmissionOwnerCategoryFixture)
- (int32_t)cvlpAdmissionOwnerCategoryCollision {
    CVLPAdmissionOwnerFixtureMethodCalls++;
    return 31;
}
@end

typedef struct {
    CFTimeInterval now;
    Class expireOnImageLookup;
    Class rejectReadOnImageLookup;
    CVLPAdmissionFixtureMemory *memory;
    BOOL expired;
} CVLPAdmissionOwnerFixtureDeadlineContext;

static CFTimeInterval CVLPAdmissionOwnerFixtureDeadlineClock(void *opaque) {
    CVLPAdmissionOwnerFixtureDeadlineContext *context = opaque;
    return context->now;
}

static const char *CVLPAdmissionOwnerFixtureDeadlineImageName(Class cls, void *opaque) {
    CVLPAdmissionOwnerFixtureDeadlineContext *context = opaque;
    if (cls == context->expireOnImageLookup) {
        context->expired = YES;
        context->now = 102.0;
    }
    if (cls == context->rejectReadOnImageLookup && context->memory != NULL) {
        context->memory->rejectRead = YES;
    }
    return "/fixture/admission-image";
}

static BOOL CVLPAdmissionOwnerFixturePrepare(CVLPAdmissionFixtureMemory *fixture,
    CVLPHighlightsDirectMemory *memory, CVLPAdmissionValidatedImage *validated, SEL selector,
    NSString **failure) {
    CVLPAdmissionFixtureInitialize(fixture);
    fixture->selectorReferences[0] = CVLPAdmissionFixtureSelectorAddress(selector);
    *memory = CVLPAdmissionFixtureMemoryInterface(fixture);
    CVLPAdmissionStatus status = CVLPAdmissionValidateImageWithExpectedDigest(
        fixture->base, memory, fixture->digest, validated);
    return CVLPFixtureRequire(status == CVLPAdmissionStatusMatched &&
        validated->imageBase == fixture->base &&
        validated->selectors[0] == CVLPAdmissionFixtureSelectorAddress(selector) &&
        fixture->CASCalls == 0, @"admission_owner_synthetic_pin_valid", failure);
}

static CVLPAdmissionStatus CVLPAdmissionOwnerFixtureScan(
    const CVLPAdmissionValidatedImage *validated, Class const *classes, size_t classCount,
    uintptr_t targetIMP, CVLPAdmissionFixtureMemory *fixture, CVLPAdmissionFixtureRuntimeContext *clock,
    CVLPHighlightsDirectMemory *memory, CVLPAdmissionOwnerMetadataResult *result) {
    CVLPAdmissionRuntimeCallbacks callbacks = CVLPAdmissionFixtureCallbacks(clock);
    return CVLPAdmissionOwnerScanProvidedClasses(validated, classes, classCount,
        "/fixture/admission-image", targetIMP, &callbacks, memory, result);
}

static uintptr_t CVLPAdmissionOwnerFixtureMethodIMP(Class cls, SEL selector, BOOL classMethod) {
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    return method == NULL ? 0 : (uintptr_t)method_getImplementation(method);
}

static BOOL CVLPAdmissionOwnerFixtureLineIsExactAndSafe(
    const CVLPAdmissionOwnerMetadataResult *result, uint32_t sequence, NSString **failure,
    NSString **lineOut) {
    NSString *line = CVLPAdmissionOwnerFormatLine(result, sequence);
    NSArray<NSString *> *tokens = [line componentsSeparatedByString:@" "];
    NSArray<NSString *> *keys = @[@"seq=", @"status=", @"reason=", @"classes=", @"methods=",
        @"skippedLists=", @"maxSkipped=", @"matches=", @"selector=", @"owner=", @"kind=",
        @"return=", @"args="];
    BOOL valid = line != nil && tokens.count == 15 &&
        [tokens[0] isEqualToString:@"CVLP_ADMISSION_OWNER"] &&
        [tokens[14] isEqualToString:@"callable=0"];
    for (NSUInteger index = 0; valid && index < keys.count; index++) {
        valid = [tokens[index + 1] hasPrefix:keys[index]];
    }
    valid = valid && CVLPAdmissionOwnerLineIsSanitized(line);
    if (lineOut != NULL) { *lineOut = line; }
    return CVLPFixtureRequire(valid, @"admission_owner_exact_15_token_sanitized_line", failure);
}

static Class CVLPAdmissionOwnerFixtureLongNameClass(void) {
    static Class fixtureClass;
    if (fixtureClass != Nil) { return fixtureClass; }
    char name[CVLPAdmissionExampleNameCapacity + 24];
    const char prefix[] = "CVLPAdmissionOwnerFixtureLong";
    size_t prefixLength = sizeof(prefix) - 1;
    memcpy(name, prefix, prefixLength);
    memset(name + prefixLength, 'A', sizeof(name) - prefixLength - 1);
    name[sizeof(name) - 1] = '\0';
    fixtureClass = objc_allocateClassPair(NSObject.class, name, 0);
    if (fixtureClass != Nil) { objc_registerClassPair(fixtureClass); }
    return fixtureClass;
}

static Class CVLPAdmissionOwnerFixtureMalformedSelectorClass(void) {
    static Class fixtureClass;
    if (fixtureClass != Nil) { return fixtureClass; }
    fixtureClass = objc_allocateClassPair(NSObject.class,
        "CVLPAdmissionOwnerFixtureMalformedSelector", 0);
    if (fixtureClass != Nil) { objc_registerClassPair(fixtureClass); }
    return fixtureClass;
}

static BOOL CVLPAdmissionOwnerRunFixtureCases(NSString **failure) {
    CVLPAdmissionFixtureMemory fixture;
    CVLPHighlightsDirectMemory memory = {0};
    CVLPAdmissionValidatedImage validated = {0};
    CVLPAdmissionOwnerMetadataResult result;
    CVLPAdmissionFixtureRuntimeContext clock = { .now = 10.0 };
    CVLPAdmissionOwnerFixtureMethodCalls = 0;

    // Match by the actual Method IMP address; the implementation is not called.
    SEL instanceSelector = @selector(cvlpAdmissionFixtureInstanceMethod);
    uintptr_t instanceIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionFixtureInstanceOwner.class, instanceSelector, NO);
    if (!CVLPFixtureRequire(instanceIMP != 0 &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure),
        @"admission_owner_instance_fixture_ready", failure)) { return NO; }
    Class instanceClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    CVLPAdmissionStatus status = CVLPAdmissionOwnerFixtureScan(&validated, instanceClasses, 1,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        strcmp(result.ownerName, "CVLPAdmissionFixtureInstanceOwner") == 0 &&
        result.kind == '0' && result.returnCode == 'i' && result.argumentCount == 2 &&
        CVLPAdmissionOwnerFixtureMethodCalls == 0 && fixture.CASCalls == 0,
        @"admission_owner_instance_imp_matched_without_invocation", failure)) { return NO; }
    NSString *matchedLine = nil;
    if (!CVLPAdmissionOwnerFixtureLineIsExactAndSafe(&result, 1, failure, &matchedLine)) { return NO; }

    // The same scan reads a class's metaclass list and reports that kind.
    SEL classSelector = @selector(cvlpAdmissionFixtureMetaclassMethod);
    uintptr_t classIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionFixtureMetaclassOwner.class, classSelector, YES);
    if (!CVLPFixtureRequire(classIMP != 0 &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, classSelector, failure),
        @"admission_owner_metaclass_fixture_ready", failure)) { return NO; }
    Class classMethodClasses[] = { CVLPAdmissionFixtureMetaclassOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 20.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, classMethodClasses, 1,
        classIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureMetaclassMethod") == 0 &&
        strcmp(result.ownerName, "CVLPAdmissionFixtureMetaclassOwner") == 0 &&
        result.kind == '1' && result.returnCode == 'd' && result.argumentCount == 2 &&
        CVLPAdmissionOwnerFixtureMethodCalls == 0 && fixture.CASCalls == 0,
        @"admission_owner_metaclass_imp_matched_without_invocation", failure)) { return NO; }

    // Inherited methods do not appear in a child's declared instance list.
    SEL inheritedSelector = @selector(cvlpAdmissionFixtureInheritedMethod);
    uintptr_t inheritedIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionFixtureInheritedBase.class, inheritedSelector, NO);
    if (!CVLPFixtureRequire(inheritedIMP != 0 &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, inheritedSelector, failure),
        @"admission_owner_inherited_fixture_ready", failure)) { return NO; }
    Class inheritedClasses[] = { CVLPAdmissionFixtureInheritedChild.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 30.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, inheritedClasses, 1,
        inheritedIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusNoMatch && result.matches == 0 &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0' && result.kind == '?' &&
        result.returnCode == '?' && result.argumentCount == -1 &&
        CVLPAdmissionFixtureMethodCalls == 0,
        @"admission_owner_inherited_method_not_counted", failure)) { return NO; }

    // A distinct implementation with the same selector is not an IMP match.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class wrongIMPClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 40.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, wrongIMPClasses, 1,
        CVLPAdmissionOwnerFixtureMethodIMP(CVLPAdmissionFixtureMetaclassOwner.class,
            @selector(cvlpAdmissionFixtureMetaclassMethod), YES), &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusNoMatch && result.matches == 0 &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0',
        @"admission_owner_same_selector_different_imp_not_matched", failure)) { return NO; }

    // A category method copied onto a second class has one IMP and two owners;
    // the output is ambiguous and cannot claim the category's declaring owner.
    SEL categorySelector = @selector(cvlpAdmissionOwnerCategoryCollision);
    uintptr_t categoryIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionFixtureDuplicateB.class, categorySelector, NO);
    if (!CVLPFixtureRequire(categoryIMP != 0 &&
        class_addMethod(CVLPAdmissionFixtureDuplicateA.class, categorySelector,
            (IMP)categoryIMP, "i@:") &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, categorySelector, failure),
        @"admission_owner_category_collision_fixture_ready", failure)) { return NO; }
    Class categoryClasses[] = { CVLPAdmissionFixtureDuplicateA.class,
        CVLPAdmissionFixtureDuplicateB.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 50.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, categoryClasses, 2,
        categoryIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusAmbiguous && result.matches == 2 &&
        result.selectorName[0] == '\0' &&
        result.ownerName[0] == '\0' && result.kind == '?' && result.returnCode == '?' &&
        result.argumentCount == -1 && CVLPAdmissionOwnerFixtureMethodCalls == 0 &&
        CVLPAdmissionFixtureMethodCalls == 0,
        @"admission_owner_same_imp_category_ambiguity_has_no_owner_or_abi", failure)) { return NO; }

    // A declared method with an unsupported return encoding is visible by safe
    // name but cannot be reported as a known ABI.
    SEL unknownABISelector = @selector(cvlpAdmissionFixtureUnknownABI);
    uintptr_t unknownABIIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionFixtureUnknownABI.class, unknownABISelector, NO);
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, unknownABISelector, failure)) {
        return NO;
    }
    Class unknownABIClasses[] = { CVLPAdmissionFixtureUnknownABI.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 60.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, unknownABIClasses, 1,
        unknownABIIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusIncomplete && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureUnknownABI") == 0 &&
        result.ownerName[0] == '\0' &&
        result.kind == '?' && result.returnCode == '?' && result.argumentCount == -1 &&
        CVLPAdmissionOwnerFixtureMethodCalls == 0,
        @"admission_owner_unsupported_signature_withdraws_abi", failure)) { return NO; }

    // A selector outside the identifier grammar and an overlong class name are
    // never copied into the diagnostic, even though their IMPs match.
    char longSelectorName[CVLPAdmissionSelectorNameCapacity + 8];
    memset(longSelectorName, 'A', sizeof(longSelectorName) - 1);
    longSelectorName[sizeof(longSelectorName) - 1] = '\0';
    SEL malformedSelector = sel_registerName(longSelectorName);
    Class malformedSelectorOwner = CVLPAdmissionOwnerFixtureMalformedSelectorClass();
    if (!CVLPFixtureRequire(malformedSelectorOwner != Nil && class_addMethod(malformedSelectorOwner,
        malformedSelector, (IMP)instanceIMP, "i@:") &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, malformedSelector, failure),
        @"admission_owner_malformed_selector_fixture_ready", failure)) { return NO; }
    Class malformedSelectorClasses[] = { malformedSelectorOwner };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 70.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, malformedSelectorClasses, 1,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusIncomplete && result.matches == 1 &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0' &&
        result.kind == '?' && result.returnCode == '?' && result.argumentCount == -1 &&
        CVLPAdmissionFixtureMethodCalls == 0,
        @"admission_owner_malformed_selector_is_not_emitted", failure)) { return NO; }

    Class longOwner = CVLPAdmissionOwnerFixtureLongNameClass();
    if (!CVLPFixtureRequire(longOwner != Nil && class_addMethod(longOwner, instanceSelector,
        (IMP)instanceIMP, "i@:") &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure),
        @"admission_owner_long_class_fixture_ready", failure)) { return NO; }
    Class malformedOwnerClasses[] = { longOwner };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 80.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, malformedOwnerClasses, 1,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusIncomplete && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        result.ownerName[0] == '\0' && result.kind == '?' && result.returnCode == '?' &&
        result.argumentCount == -1 && CVLPAdmissionFixtureMethodCalls == 0,
        @"admission_owner_malformed_class_name_is_not_emitted", failure)) { return NO; }

    // An oversized 4,097-entry instance list is skipped without inspecting its
    // methods; scanning continues into that class's metaclass and later classes.
    Class methodCap = CVLPAdmissionFixtureCreateMethodCapClass();
    if (!CVLPFixtureRequire(methodCap != Nil &&
        CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure),
        @"admission_owner_method_cap_fixture_ready", failure)) { return NO; }
    CVLPAdmissionFixtureMethodCapCalls = 0;
    Class capThenMatch[] = { methodCap, CVLPAdmissionFixtureInstanceOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 90.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, capThenMatch, 2,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMethodLimit && result.skippedLists == 1 &&
        result.maxSkipped == CVLPAdmissionMaximumMethodsPerList + 1 && result.classesScanned == 2 &&
        result.matches == 1 && strcmp(result.selectorName, "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        result.ownerName[0] == '\0' &&
        result.kind == '?' && result.returnCode == '?' && result.argumentCount == -1 &&
        CVLPAdmissionFixtureMethodCapCalls == 0 && CVLPAdmissionOwnerFixtureMethodCalls == 0 &&
        fixture.CASCalls == 0,
        @"admission_owner_method_cap_before_later_match_keeps_lower_bound_only", failure)) { return NO; }
    NSString *partialLine = nil;
    if (!CVLPAdmissionOwnerFixtureLineIsExactAndSafe(&result, 2, failure, &partialLine)) { return NO; }

    // Reverse ordering proves a match observed before the cap also remains a
    // lower bound, with ABI and kind withdrawn once coverage is incomplete.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class matchThenCap[] = { CVLPAdmissionFixtureInstanceOwner.class, methodCap };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 100.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, matchThenCap, 2,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMethodLimit && result.skippedLists == 1 &&
        result.maxSkipped == CVLPAdmissionMaximumMethodsPerList + 1 && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        result.ownerName[0] == '\0' && result.kind == '?' && result.returnCode == '?' &&
        result.argumentCount == -1 &&
        CVLPAdmissionFixtureMethodCapCalls == 0,
        @"admission_owner_method_cap_after_match_is_lower_bound", failure)) { return NO; }

    // The class-count guard rejects before reading the supplied class array.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class __unsafe_unretained *tooManyClasses = (Class __unsafe_unretained *)calloc(
        (size_t)CVLPAdmissionMaximumClassCount + 1, sizeof(Class));
    if (!CVLPFixtureRequire(tooManyClasses != NULL,
        @"admission_owner_class_cap_fixture_allocation", failure)) { return NO; }
    tooManyClasses[0] = CVLPAdmissionFixtureInstanceOwner.class;
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 110.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, tooManyClasses,
        (size_t)CVLPAdmissionMaximumClassCount + 1, instanceIMP, &fixture, &clock, &memory, &result);
    free(tooManyClasses);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusClassLimit && result.classesScanned == 0 &&
        result.matches == 0 && result.selectorName[0] == '\0' && result.ownerName[0] == '\0' &&
        result.kind == '?' && result.returnCode == '?' && result.argumentCount == -1 &&
        fixture.CASCalls == 0,
        @"admission_owner_class_cap_rejects_without_scanning", failure)) { return NO; }

    // Once one safe match has been seen, an image-guard failure may retain the
    // selector as an observation but withdraw owner and ABI claims.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class imageMismatchClasses[] = { CVLPAdmissionFixtureInstanceOwner.class,
        CVLPAdmissionFixtureMetaclassOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){
        .now = 120.0, .mismatchedClass = CVLPAdmissionFixtureMetaclassOwner.class,
    };
    status = CVLPAdmissionOwnerFixtureScan(&validated, imageMismatchClasses, 2,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusImageMismatch &&
        result.reason == CVLPAdmissionScanReasonClassImageMismatch && result.matches == 1 &&
        strcmp(result.selectorName, "cvlpAdmissionFixtureInstanceMethod") == 0 &&
        result.ownerName[0] == '\0' && result.kind == '?' && result.returnCode == '?' &&
        result.argumentCount == -1,
        @"admission_owner_image_guard_withdraws_owner_and_abi", failure)) { return NO; }

    // A later image-guard failure must take precedence over an earlier skipped
    // list; the skip remains a count, never a fabricated no-match/completion.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class skipThenMismatch[] = { methodCap, CVLPAdmissionFixtureMetaclassOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){
        .now = 125.0, .mismatchedClass = CVLPAdmissionFixtureMetaclassOwner.class,
    };
    status = CVLPAdmissionOwnerFixtureScan(&validated, skipThenMismatch, 2,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusImageMismatch &&
        result.reason == CVLPAdmissionScanReasonClassImageMismatch && result.skippedLists == 1 &&
        result.maxSkipped == CVLPAdmissionMaximumMethodsPerList + 1 && result.classesScanned == 1 &&
        result.matches == 0 && result.selectorName[0] == '\0' && result.ownerName[0] == '\0' &&
        result.kind == '?' && result.returnCode == '?' && result.argumentCount == -1 &&
        fixture.CASCalls == 0,
        @"admission_owner_image_mismatch_after_skip_preserves_terminal_reason", failure)) { return NO; }

    // Move the clock past the common deadline only after one match has been
    // recorded. Terminal cleanup must clear every identity and ABI field.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class deadlineClasses[] = { CVLPAdmissionFixtureInstanceOwner.class,
        CVLPAdmissionFixtureMetaclassOwner.class };
    CVLPAdmissionOwnerFixtureDeadlineContext deadlineContext = {
        .now = 100.0, .expireOnImageLookup = CVLPAdmissionFixtureMetaclassOwner.class,
    };
    CVLPAdmissionRuntimeCallbacks deadlineCallbacks = {
        .clock = CVLPAdmissionOwnerFixtureDeadlineClock,
        .imageName = CVLPAdmissionOwnerFixtureDeadlineImageName,
        .context = &deadlineContext,
        .deadlineAt = 101.5,
    };
    status = CVLPAdmissionOwnerScanProvidedClasses(&validated, deadlineClasses, 2,
        "/fixture/admission-image", instanceIMP, &deadlineCallbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusDeadline && deadlineContext.expired &&
        result.matches == 1 && result.reason == CVLPAdmissionScanReasonDeadline &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0' && result.kind == '?' &&
        result.returnCode == '?' && result.argumentCount == -1 && fixture.CASCalls == 0,
        @"admission_owner_deadline_after_match_clears_names_and_signature", failure)) { return NO; }

    // Recheck mapping failure after a skip cannot restore stale selector/owner
    // data or downgrade the terminal result back to MethodLimit.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    CVLPAdmissionOwnerFixtureDeadlineContext mappingContext = {
        .now = 150.0,
        .rejectReadOnImageLookup = CVLPAdmissionFixtureMetaclassOwner.class,
        .memory = &fixture,
    };
    CVLPAdmissionRuntimeCallbacks mappingCallbacks = {
        .clock = CVLPAdmissionOwnerFixtureDeadlineClock,
        .imageName = CVLPAdmissionOwnerFixtureDeadlineImageName,
        .context = &mappingContext,
        .deadlineAt = 0.0,
    };
    Class skipThenMappingFailure[] = { methodCap, CVLPAdmissionFixtureInstanceOwner.class,
        CVLPAdmissionFixtureMetaclassOwner.class };
    status = CVLPAdmissionOwnerScanProvidedClasses(&validated, skipThenMappingFailure, 3,
        "/fixture/admission-image", instanceIMP, &mappingCallbacks, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusIncomplete && result.skippedLists == 1 &&
        result.maxSkipped == CVLPAdmissionMaximumMethodsPerList + 1 && result.matches == 1 &&
        result.reason == CVLPAdmissionScanReasonInvalidRuntimeMetadata &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0' && result.kind == '?' &&
        result.returnCode == '?' && result.argumentCount == -1 && fixture.rejectRead &&
        fixture.CASCalls == 0,
        @"admission_owner_reference_mapping_failure_after_skip_clears_stale_identifiers", failure)) {
        return NO;
    }

    // Reference mutation on the end-of-scan recheck invalidates prior metadata.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    fixture.mutateSelectorOnRead = YES;
    fixture.mutateSelectorAtRead = 2;
    Class referenceChangeClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 130.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, referenceChangeClasses, 1,
        instanceIMP, &fixture, &clock, &memory, &result);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusSelectorChanged &&
        result.reason == CVLPAdmissionScanReasonSelectorChanged && result.matches == 1 &&
        result.selectorName[0] == '\0' && result.ownerName[0] == '\0' && result.kind == '?' &&
        result.returnCode == '?' && result.argumentCount == -1 && fixture.CASCalls == 0,
        @"admission_owner_reference_change_clears_names_and_signature", failure)) { return NO; }

    // Invalid pins produce no validated address; no owner scan may proceed.
    CVLPAdmissionFixtureInitialize(&fixture);
    memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
    uint8_t wrongDigest[CC_SHA256_DIGEST_LENGTH] = {0};
    memset(&validated, 0x7f, sizeof(validated));
    CVLPAdmissionStatus pinStatus = CVLPAdmissionValidateImageWithExpectedDigest(
        fixture.base, &memory, wrongDigest, &validated);
    BOOL validatedWasCleared = validated.imageBase == 0;
    for (NSUInteger index = 0; index < CVLPAdmissionSelectorCount; index++) {
        validatedWasCleared = validatedWasCleared && validated.selectors[index] == 0;
    }
    if (!CVLPFixtureRequire(pinStatus == CVLPAdmissionStatusPinMismatch && validatedWasCleared &&
        fixture.CASCalls == 0,
        @"admission_owner_wrong_digest_clears_validated_image_before_scan", failure)) { return NO; }

    // Exercise Apple's image-bound class enumerator on this synthetic fixture
    // executable. The local memory interface supplies an inert synthetic pin
    // at the real header address; no image bytes or method IMPs are changed.
    SEL getterSelector = @selector(cvlpAdmissionOwnerFixtureGetter);
    uintptr_t getterIMP = CVLPAdmissionOwnerFixtureMethodIMP(
        CVLPAdmissionOwnerFixtureEnumerationProbe.class, getterSelector, NO);
    Dl_info executableInfo = {0};
    if (!CVLPFixtureRequire(getterIMP != 0 &&
        dladdr((const void *)getterIMP, &executableInfo) != 0 && executableInfo.dli_fbase != NULL &&
        executableInfo.dli_fname != NULL,
        @"admission_owner_image_bound_enumerator_executable_resolved", failure)) { return NO; }
    const char *executableImageName = class_getImageName(
        CVLPAdmissionOwnerFixtureEnumerationProbe.class);
    if (!CVLPFixtureRequire(executableImageName != NULL &&
        strcmp(executableImageName, executableInfo.dli_fname) == 0,
        @"admission_owner_image_bound_enumerator_image_name_matches", failure)) { return NO; }
    CVLPAdmissionFixtureInitialize(&fixture);
    fixture.base = (uintptr_t)executableInfo.dli_fbase;
    fixture.classReference = fixture.base + CVLPAdmissionFunctionVM;
    fixture.selectorReferences[0] = CVLPAdmissionFixtureSelectorAddress(getterSelector);
    memory = CVLPAdmissionFixtureMemoryInterface(&fixture);
    memset(&validated, 0, sizeof(validated));
    pinStatus = CVLPAdmissionValidateImageWithExpectedDigest(
        fixture.base, &memory, fixture.digest, &validated);
    if (!CVLPFixtureRequire(pinStatus == CVLPAdmissionStatusMatched &&
        validated.imageBase == (uintptr_t)executableInfo.dli_fbase && fixture.CASCalls == 0,
        @"admission_owner_image_bound_enumerator_synthetic_pin_valid", failure)) { return NO; }
    CVLPAdmissionOwnerInitialize(&result);
    CVLPAdmissionRuntimeCallbacks enumerationCallbacks = {
        .clock = CVLPAdmissionDefaultClock,
        .imageName = NULL,
        .context = NULL,
        .deadlineAt = CACurrentMediaTime() + CVLPAdmissionScanDeadline,
    };
    CVLPAdmissionOwnerScanContext enumerationScan = {
        .validated = &validated,
        .expectedImageName = executableImageName,
        .targetIMP = getterIMP,
        .callbacks = &enumerationCallbacks,
        .memory = &memory,
        .deadlineAt = enumerationCallbacks.deadlineAt,
        .result = &result,
        .terminal = CVLPAdmissionStatusUnknown,
        .metadataIncomplete = NO,
    };
    CVLPAdmissionOwnerEnumerationContext enumeration = {.scan = &enumerationScan};
    if (@available(iOS 16.0, *)) {
        objc_enumerateClasses((const void *)validated.imageBase, NULL, NULL, Nil,
            ^(Class cls, BOOL *stop) {
                CVLPAdmissionOwnerEnumerateClass(cls, stop, &enumeration);
            });
    } else {
        if (failure != NULL) { *failure = @"admission_owner_image_bound_enumerator_requires_iOS16"; }
        return NO;
    }
    BOOL enumerationComplete = enumerationScan.terminal == CVLPAdmissionStatusUnknown;
    status = CVLPAdmissionOwnerFinalize(&enumerationScan, enumerationComplete);
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched && result.matches == 1 &&
        result.classesScanned > 0 &&
        strcmp(result.selectorName, "cvlpAdmissionOwnerFixtureGetter") == 0 &&
        strcmp(result.ownerName, "CVLPAdmissionOwnerFixtureEnumerationProbe") == 0 &&
        result.kind == '0' && result.returnCode == 'i' && result.argumentCount == 2 &&
        CVLPAdmissionOwnerFixtureGetterCalls == 0 && fixture.CASCalls == 0,
        @"admission_owner_objc_enumerate_classes_image_bound_unique_getter_imp_no_call", failure)) {
        return NO;
    }
    if (!CVLPAdmissionOwnerFixtureLineIsExactAndSafe(&result, 4, failure, NULL)) { return NO; }

    // Formatter rejects controls, NUL, paths, URLs, query strings, secrets,
    // malformed numbers, and extra tokens while every accepted line says callable=0.
    if (!CVLPAdmissionOwnerFixturePrepare(&fixture, &memory, &validated, instanceSelector, failure)) {
        return NO;
    }
    Class lineClasses[] = { CVLPAdmissionFixtureInstanceOwner.class };
    clock = (CVLPAdmissionFixtureRuntimeContext){ .now = 140.0 };
    status = CVLPAdmissionOwnerFixtureScan(&validated, lineClasses, 1,
        instanceIMP, &fixture, &clock, &memory, &result);
    NSString *safeLine = nil;
    if (!CVLPFixtureRequire(status == CVLPAdmissionStatusMatched &&
        CVLPAdmissionOwnerFixtureLineIsExactAndSafe(&result, 3, failure, &safeLine),
        @"admission_owner_safe_schema_control_line_ready", failure)) { return NO; }

    CVLPAdmissionOwnerMetadataResult staleTerminal = result;
    staleTerminal.status = CVLPAdmissionStatusDeadline;
    staleTerminal.reason = CVLPAdmissionScanReasonDeadline;
    NSString *deadlineLine = CVLPAdmissionOwnerFormatLine(&staleTerminal, 5);
    staleTerminal.status = CVLPAdmissionStatusSelectorChanged;
    staleTerminal.reason = CVLPAdmissionScanReasonSelectorChanged;
    NSString *changedLine = CVLPAdmissionOwnerFormatLine(&staleTerminal, 6);
    if (!CVLPFixtureRequire(CVLPAdmissionOwnerLineIsSanitized(deadlineLine) &&
        CVLPAdmissionOwnerLineIsSanitized(changedLine) &&
        [deadlineLine containsString:@"selector=unknown owner=unknown kind=? return=? args=-1"] &&
        [changedLine containsString:@"selector=unknown owner=unknown kind=? return=? args=-1"],
        @"admission_owner_terminal_formatter_clears_stale_identifiers", failure)) { return NO; }

    unichar nulValue = 0;
    NSString *nul = [NSString stringWithCharacters:&nulValue length:1];
    NSString *badSelector = [safeLine stringByReplacingOccurrencesOfString:
        @"selector=cvlpAdmissionFixtureInstanceMethod" withString:@"selector=synthetic-secret"];
    NSString *badPath = [safeLine stringByReplacingOccurrencesOfString:
        @"owner=CVLPAdmissionFixtureInstanceOwner" withString:@"owner=/private/fixture/path"];
    NSString *badURL = [safeLine stringByReplacingOccurrencesOfString:
        @"owner=CVLPAdmissionFixtureInstanceOwner" withString:@"owner=https://example.invalid"];
    NSString *badQuery = [safeLine stringByReplacingOccurrencesOfString:
        @"selector=cvlpAdmissionFixtureInstanceMethod" withString:@"selector=cvlp?token=synthetic"];
    NSString *badNumber = [safeLine stringByReplacingOccurrencesOfString:@"seq=3" withString:@"seq=-1"];
    NSString *badExtra = [safeLine stringByAppendingString:@" extra=synthetic"];
    NSString *badCallable = [safeLine stringByReplacingOccurrencesOfString:@"callable=0"
        withString:@"callable=1"];
    NSString *badNUL = [safeLine stringByAppendingString:nul];
    unichar delValue = 0x7f;
    NSString *del = [NSString stringWithCharacters:&delValue length:1];
    NSString *badControl = [safeLine stringByAppendingString:del];
    if (!CVLPFixtureRequire(!CVLPAdmissionOwnerLineIsSanitized(badSelector) &&
        !CVLPAdmissionOwnerLineIsSanitized(badPath) && !CVLPAdmissionOwnerLineIsSanitized(badURL) &&
        !CVLPAdmissionOwnerLineIsSanitized(badQuery) && !CVLPAdmissionOwnerLineIsSanitized(badNumber) &&
        !CVLPAdmissionOwnerLineIsSanitized(badExtra) &&
        !CVLPAdmissionOwnerLineIsSanitized(badCallable) && !CVLPAdmissionOwnerLineIsSanitized(badNUL) &&
        !CVLPAdmissionOwnerLineIsSanitized(badControl) && CVLPAdmissionOwnerFixtureMethodCalls == 0 &&
        CVLPAdmissionFixtureMethodCalls == 0 && CVLPAdmissionFixtureMethodCapCalls == 0 &&
        fixture.CASCalls == 0,
        @"admission_owner_schema_rejects_content_path_url_query_control_nul_and_spoofed_fields", failure)) {
        return NO;
    }
    return YES;
}

#endif // CVLP_ADMISSION_OWNER_FIXTURE_CASES_H
