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
static double CVLPFixtureHeightResult = 42.75;
static id CVLPFixtureModelResult;
static NSException *CVLPFixtureForwardedException;
static NSMutableArray<NSString *> *CVLPFixtureDiagnosticLines;
static NSUInteger CVLPFixtureDisplacedCalls;

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
@end

@implementation CVLPFixtureFeatureOwner
+ (BOOL)enableStoryHighlightConsumption {
    CVLPFixtureConsumptionCalls++;
    errno = EDOM;
    return CVLPFixtureConsumptionResult;
}
+ (BOOL)enableStoryHighlightCreation {
    CVLPFixtureCreationCalls++;
    @throw CVLPFixtureForwardedException;
}
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

static BOOL CVLPFixtureDuplicateConsumption(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YES;
}

BOOL CVLPHighlightsRunFixtureSelfTest(NSString **failure) {
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
    CVLPFixtureHeightResult = 42.75;
    CVLPFixtureModelResult = [NSObject new];
    CVLPFixtureForwardedException = [NSException exceptionWithName:@"CVLPFixtureForwarded" reason:@"fixed" userInfo:nil];
    CVLPHighlightsState = (CVLPHighlightsHookState){ .lastConsumption = -1, .lastCreation = -1,
        .lastModelPresence = -1, .lastMount = -1, .lastUpdate = -1, .lastHeight = -1.0 };
    CVLPHighlightsRecording = YES;
    CVLPHighlightsStartedAt = CACurrentMediaTime();

    CVLPHighlightsInstallStatus consumptionStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightConsumption"), CVLPHighlightsConsumptionTarget);
    if (consumptionStatus != CVLPHighlightsInstallInstalled) {
        CVLPHighlightsClassMethodSearch retry = CVLPHighlightsFindClassMethod(
            sel_registerName("enableStoryHighlightConsumption"));
        Method known = class_getClassMethod(CVLPFixtureFeatureOwner.class,
            @selector(enableStoryHighlightConsumption));
        fprintf(stderr, "CV_HIGHLIGHTS_FIXTURE_LOOKUP status=%d classes=%d retryComplete=%d retryMatches=%lu knownABI=%d\n",
            consumptionStatus, objc_getClassList(NULL, 0), retry.complete,
            (unsigned long)retry.matches, CVLPHighlightsMethodHasExactSignature(known, "B"));
    }
    if (!CVLPFixtureRequire(consumptionStatus == CVLPHighlightsInstallInstalled, @"feature_owner_unique_hook", failure)) { return NO; }
    CVLPHighlightsInstallStatus creationStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("enableStoryHighlightCreation"), CVLPHighlightsCreationTarget);
    if (!CVLPFixtureRequire(creationStatus == CVLPHighlightsInstallInstalled, @"creation_hook", failure)) { return NO; }

    if (!CVLPFixtureRequire(CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 0 &&
        CVLPHighlightsState.lastConsumption == -1, @"boolean_unknown_before_call", failure)) { return NO; }
    errno = 0;
    BOOL consumptionResult = [CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    if (!CVLPFixtureRequire(!consumptionResult && CVLPFixtureConsumptionCalls == 1 && errno == EDOM,
        @"boolean_false_and_errno_forwarded_once", failure)) { return NO; }
    if (!CVLPFixtureRequire(CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == 1 &&
        CVLPHighlightsState.lastConsumption == 0, @"boolean_false_distinct_from_unknown", failure)) { return NO; }

    BOOL caughtOriginalException = NO;
    @try {
        (void)[CVLPFixtureFeatureOwner enableStoryHighlightCreation];
    } @catch (NSException *exception) {
        caughtOriginalException = exception == CVLPFixtureForwardedException;
    }
    if (!CVLPFixtureRequire(caughtOriginalException && CVLPFixtureCreationCalls == 1 &&
        CVLPHighlightsState.counts[CVLPHighlightsCreationTarget] == 0, @"original_exception_forwarded", failure)) { return NO; }

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
        CVLPFixtureAbsentTarget.class, sel_registerName("missingFixtureMethod"), "v", CVLPHighlightsMountTarget);
    CVLPHighlightsInstallStatus absentClassStatus = CVLPHighlightsInstallClassBoolean(
        sel_registerName("missingFixtureClassMethod"), CVLPHighlightsConsumptionTarget);
    if (!CVLPFixtureRequire(absentInstanceStatus == CVLPHighlightsInstallNotFound &&
        absentClassStatus == CVLPHighlightsInstallNotFound, @"absent_targets_report_not_found", failure)) { return NO; }

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

    Class duplicateClass = objc_allocateClassPair(NSObject.class, "CVLPFixtureDuplicateFeatureOwner", 0);
    if (!CVLPFixtureRequire(duplicateClass != Nil, @"duplicate_class_allocate", failure)) { return NO; }
    Class duplicateMeta = object_getClass(duplicateClass);
    SEL consumptionSelector = sel_registerName("enableStoryHighlightConsumption");
    const char *booleanTypes = "B16@0:8";
    if (!CVLPFixtureRequire(class_addMethod(duplicateMeta, consumptionSelector,
        (IMP)CVLPFixtureDuplicateConsumption, booleanTypes), @"duplicate_method_add", failure)) { return NO; }
    objc_registerClassPair(duplicateClass);
    Method duplicateMethod = class_getClassMethod(duplicateClass, consumptionSelector);
    IMP duplicateOriginal = method_getImplementation(duplicateMethod);
    CVLPHighlightsInstallStatus ambiguousStatus = CVLPHighlightsInstallClassBoolean(
        consumptionSelector, CVLPHighlightsConsumptionTarget);
    if (!CVLPFixtureRequire(ambiguousStatus == CVLPHighlightsInstallAmbiguous &&
        method_getImplementation(duplicateMethod) == duplicateOriginal, @"ambiguous_owner_not_modified", failure)) { return NO; }

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
    (void)[CVLPFixtureFeatureOwner enableStoryHighlightConsumption];
    [(TTKProfileBizDataStoryHighlightInfoModel *)[modelClass new] storyHighlightInfo];
    [collection updateUI];
    (void)[collection viewHeight];
    if (!CVLPFixtureRequire(CVLPFixtureConsumptionCalls == 4 && CVLPFixtureGetterCalls == 3 &&
        CVLPFixtureUpdateCalls == 2 && CVLPFixtureHeightCalls == 3 &&
        CVLPHighlightsState.counts[CVLPHighlightsConsumptionTarget] == beforeStoppedCount,
        @"stopped_wrappers_forward_without_recording", failure)) { return NO; }

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
    NSString *arbitraryText = [validLine stringByReplacingOccurrencesOfString:@"l0=0" withString:@"l0=secret"];
    NSString *extraField = [validLine stringByAppendingString:@" private=1"];
    NSString *nonfiniteFloat = [validLine stringByReplacingOccurrencesOfString:@"l5=42.75" withString:@"l5=nan"];
    NSString *overflowFloat = [validLine stringByReplacingOccurrencesOfString:@"alpha=-1" withString:@"alpha=1e999"];
    if (!CVLPFixtureRequire(!CVLPHighlightsLineIsSanitized(arbitraryText) &&
        !CVLPHighlightsLineIsSanitized(extraField) && !CVLPHighlightsLineIsSanitized(nonfiniteFloat) &&
        !CVLPHighlightsLineIsSanitized(overflowFloat), @"sanitizer_rejects_text_extra_and_nonfinite", failure)) { return NO; }
    return YES;
}

int main(void) {
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
