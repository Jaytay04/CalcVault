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
#import <stdint.h>
#import "CVLPProbe.h"

#ifndef CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT
#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 0
#endif

#if CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT != 0 && CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT != 1
#error CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT must be 0 or 1
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
    int lastConsumption;
    int lastCreation;
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
    .lastModelPresence = -1,
    .lastMount = -1,
    .lastUpdate = -1,
    .lastHeight = -1.0,
};
static BOOL CVLPHighlightsRecording = NO;
static CFTimeInterval CVLPHighlightsStartedAt = 0.0;
static __strong id CVLPHighlightsSharedObserver;

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
};

static BOOL CVLPHighlightsParseInteger(const char *value) {
    if (value == NULL || *value == '\0') { return NO; }
    errno = 0;
    char *end = NULL;
    (void)strtoll(value, &end, 10);
    return errno != ERANGE && end != value && end != NULL && *end == '\0';
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
    if (parts.count != 39 || ![parts[0] isEqualToString:@"CVLP_HIGHLIGHTS"]) { return NO; }
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
        .lastModelPresence = -1, .lastMount = -1, .lastUpdate = -1, .lastHeight = -1.0 };
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
         "scope=1 why0=%d why1=%d classes0=%lu classes1=%lu mode=%d overrideCalls=%u",
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
        CVLPHighlightsViewingExperimentMode, (unsigned int)state.overrideCalls];
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
