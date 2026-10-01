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
    return YES;
}

int main(void) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_STAGE main\n");
    @autoreleasepool {
        NSString *failure = nil;
        if (![CVLPHighlightsDiagnostics runFixtureSelfTest:&failure]) {
            fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_FAIL %s\n", failure.UTF8String ?: "unknown");
            return 1;
        }
        printf("CV_HIGHLIGHTS_FIXTURE_PASS\n");
        return 0;
    }
}
