#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

#include <stdio.h>

#import "../Guest/TKPProfileControls.h"

#ifndef TKP_PROFILE_FIXTURE_MODE
#define TKP_PROFILE_FIXTURE_MODE 0
#endif

static NSUInteger gFirstGetterCalls = 0;
static NSUInteger gSecondGetterCalls = 0;
static id gFirstReceiver = nil;
static SEL gFirstSelector = NULL;
static id gSecondReceiver = nil;
static SEL gSecondSelector = NULL;
static id gLastUserArgument = nil;
static NSURL *gExpectedImageURL = nil;
static TKPProfileControlsStatus gBackgroundStatus = TKPProfileControlsStatusInstalled;
static BOOL gBackgroundSuppressionRequest = NO;
static BOOL gFixtureFailed = NO;

#if TKP_PROFILE_FIXTURE_MODE == 3
@interface TKPFixtureProfileBase : NSObject
- (BOOL)p_shouldReportProfileView;
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user;
@end

@implementation TKPFixtureProfileBase
- (BOOL)p_shouldReportProfileView {
    gFirstGetterCalls++;
    gFirstReceiver = self;
    gFirstSelector = _cmd;
    return YES;
}

- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user {
    gSecondGetterCalls++;
    gSecondReceiver = self;
    gSecondSelector = _cmd;
    gLastUserArgument = user;
    return NO;
}
@end

@interface TTKProfileViewsVisitor : TKPFixtureProfileBase
@end
@implementation TTKProfileViewsVisitor
@end
#elif TKP_PROFILE_FIXTURE_MODE != 1
@interface TTKProfileViewsVisitor : NSObject
#if TKP_PROFILE_FIXTURE_MODE != 2
#if TKP_PROFILE_FIXTURE_MODE == 4
- (id)p_shouldReportProfileView;
#else
- (BOOL)p_shouldReportProfileView;
#endif
#if TKP_PROFILE_FIXTURE_MODE == 8
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(int)user;
#else
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user;
#endif
#else
- (BOOL)p_shouldReportProfileView;
#endif
@end

@implementation TTKProfileViewsVisitor
#if TKP_PROFILE_FIXTURE_MODE != 2
#if TKP_PROFILE_FIXTURE_MODE == 4
- (id)p_shouldReportProfileView {
    gFirstGetterCalls++;
    gFirstReceiver = self;
    gFirstSelector = _cmd;
    return @"unexpected return type";
}
#else
- (BOOL)p_shouldReportProfileView {
    gFirstGetterCalls++;
    gFirstReceiver = self;
    gFirstSelector = _cmd;
    return YES;
}
#endif

#if TKP_PROFILE_FIXTURE_MODE == 8
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(int)user {
    (void)user;
#else
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user {
#endif
    gSecondGetterCalls++;
    gSecondReceiver = self;
    gSecondSelector = _cmd;
#if TKP_PROFILE_FIXTURE_MODE != 8
    gLastUserArgument = user;
#endif
    return NO;
}
#else
- (BOOL)p_shouldReportProfileView {
    gFirstGetterCalls++;
    gFirstReceiver = self;
    gFirstSelector = _cmd;
    return YES;
}
#endif
@end
#endif

static void Check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        gFixtureFailed = YES;
    }
}

static NSURL *FixtureImageURL(void) {
    Class targetClass = objc_getClass("TTKProfileViewsVisitor");
    const char *imagePath = targetClass == Nil ? NULL : class_getImageName(targetClass);
    if (imagePath == NULL) {
        return NSBundle.mainBundle.executableURL;
    }
    return [NSURL fileURLWithFileSystemRepresentation:imagePath
                                          isDirectory:NO
                                        relativeToURL:nil];
}

static Method TargetMethod(SEL selector) {
    Class targetClass = objc_getClass("TTKProfileViewsVisitor");
    return targetClass == Nil ? NULL : class_getInstanceMethod(targetClass, selector);
}

static IMP TargetImplementation(SEL selector) {
    Method method = TargetMethod(selector);
    return method == NULL ? NULL : method_getImplementation(method);
}

static void *InstallFromWorker(void *unused) {
    (void)unused;
    gBackgroundStatus = TKPProfileControlsInstall(gExpectedImageURL);
    return NULL;
}

static void *SetSuppressionFromWorker(void *unused) {
    (void)unused;
    gBackgroundStatus = TKPProfileControlsSetSuppressionEnabled(gBackgroundSuppressionRequest);
    return NULL;
}

static BOOL TestNormalBehavior(void) {
    Class targetClass = objc_getClass("TTKProfileViewsVisitor");
    Check(targetClass != Nil, "fixture target class exists");
    if (targetClass == Nil) {
        return NO;
    }

    id visitor = [[targetClass alloc] init];
    id sentinelUser = [[NSObject alloc] init];
    Check(!TKPProfileControlsSuppressionEnabled(), "suppression defaults off");
    Check(TKPProfileControlsInstall(gExpectedImageURL) == TKPProfileControlsStatusInstalled,
          "installation succeeds for the exact synthetic image");
    Check(TKPProfileControlsInstall(gExpectedImageURL) == TKPProfileControlsStatusAlreadyInstalled,
          "repeat installation does not re-hook");

    BOOL firstResult = ((BOOL (*)(id, SEL))objc_msgSend)(
        visitor, sel_registerName("p_shouldReportProfileView"));
    BOOL secondResult = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        visitor, sel_registerName("p_shouldReportHasVeiwedProfileForUser:"), sentinelUser);
    Check(firstResult, "disabled wrapper returns the original first result");
    Check(!secondResult, "disabled wrapper returns the original second result");
    Check(gFirstGetterCalls == 1 && gSecondGetterCalls == 1,
          "pass-through invokes each original exactly once");
    Check(gFirstReceiver == visitor && gSecondReceiver == visitor,
          "pass-through preserves both receivers");
    Check(gFirstSelector == sel_registerName("p_shouldReportProfileView"),
          "pass-through preserves the first selector");
    Check(gSecondSelector == sel_registerName("p_shouldReportHasVeiwedProfileForUser:"),
          "pass-through preserves the second selector");
    Check(gLastUserArgument == sentinelUser, "pass-through preserves the object argument");

    Check(TKPProfileControlsSetSuppressionEnabled(YES) ==
              TKPProfileControlsStatusSuppressionEnabled,
          "explicit opt-in enables suppression");
    Check(TKPProfileControlsSuppressionEnabled(), "suppression status reports enabled");
    Check(!((BOOL (*)(id, SEL))objc_msgSend)(
              visitor, sel_registerName("p_shouldReportProfileView")),
          "suppressed first eligibility getter returns NO");
    Check(!((BOOL (*)(id, SEL, id))objc_msgSend)(
              visitor, sel_registerName("p_shouldReportHasVeiwedProfileForUser:"), sentinelUser),
          "suppressed second eligibility getter returns NO");
    Check(gFirstGetterCalls == 1 && gSecondGetterCalls == 1,
          "suppression does not call either original");

    Check(TKPProfileControlsSetSuppressionEnabled(NO) ==
              TKPProfileControlsStatusSuppressionDisabled,
          "explicit opt-out disables suppression");
    Check(!TKPProfileControlsSuppressionEnabled(), "suppression status reports disabled");
    Check(((BOOL (*)(id, SEL))objc_msgSend)(
              visitor, sel_registerName("p_shouldReportProfileView")),
          "disabled first getter resumes original behavior");
    Check(!((BOOL (*)(id, SEL, id))objc_msgSend)(
              visitor, sel_registerName("p_shouldReportHasVeiwedProfileForUser:"), sentinelUser),
          "disabled second getter resumes original behavior");
    Check(gFirstGetterCalls == 2 && gSecondGetterCalls == 2,
          "resumed pass-through invokes each original exactly once");
    return !gFixtureFailed;
}

static BOOL TestRejection(TKPProfileControlsStatus expectedStatus, NSURL *imageURL) {
    SEL firstSelector = sel_registerName("p_shouldReportProfileView");
    SEL secondSelector = sel_registerName("p_shouldReportHasVeiwedProfileForUser:");
    IMP firstBefore = TargetImplementation(firstSelector);
    IMP secondBefore = TargetImplementation(secondSelector);

    TKPProfileControlsStatus status = TKPProfileControlsInstall(imageURL);
    Check(status == expectedStatus, "installation rejects the synthetic invalid case");
    Check(!TKPProfileControlsSuppressionEnabled(), "rejected installation leaves suppression off");
    Check(TargetImplementation(firstSelector) == firstBefore,
          "rejected installation leaves the first implementation unchanged");
    Check(TargetImplementation(secondSelector) == secondBefore,
          "rejected installation leaves the second implementation unchanged");
    return !gFixtureFailed;
}

static BOOL TKPFixtureConflictingGetter(id receiver, SEL command) {
    (void)receiver;
    (void)command;
    return YES;
}

static BOOL TestConflictDisablesWithoutReclaiming(void) {
    Class targetClass = objc_getClass("TTKProfileViewsVisitor");
    id visitor = [[targetClass alloc] init];
    SEL firstSelector = sel_registerName("p_shouldReportProfileView");
    SEL secondSelector = sel_registerName("p_shouldReportHasVeiwedProfileForUser:");
    Method firstMethod = class_getInstanceMethod(targetClass, firstSelector);
    id sentinelUser = [[NSObject alloc] init];
    Check(TKPProfileControlsInstall(gExpectedImageURL) == TKPProfileControlsStatusInstalled,
          "conflict fixture installs both hooks");
    Check(TKPProfileControlsSetSuppressionEnabled(YES) ==
              TKPProfileControlsStatusSuppressionEnabled,
          "conflict fixture opts in before the external change");

    IMP externalImplementation = (IMP)TKPFixtureConflictingGetter;
    IMP previous = method_setImplementation(firstMethod, externalImplementation);
    Check(previous != NULL, "external implementation replaces the first wrapper");
    Check(TKPProfileControlsSetSuppressionEnabled(YES) ==
              TKPProfileControlsStatusHookConflict,
          "enabling detects an implementation conflict");
    Check(!TKPProfileControlsSuppressionEnabled(), "conflict forces suppression off");
    Check(method_getImplementation(firstMethod) == externalImplementation,
          "conflict handling preserves the external implementation");
    Check(((BOOL (*)(id, SEL))objc_msgSend)(visitor, firstSelector),
          "external replacement remains callable");
    Check(!((BOOL (*)(id, SEL, id))objc_msgSend)(visitor, secondSelector, sentinelUser),
          "the saved second wrapper passes through after suppression is disabled");
    Check(gSecondGetterCalls == 1 && gSecondReceiver == visitor &&
              gSecondSelector == secondSelector && gLastUserArgument == sentinelUser,
          "the saved wrapper invokes its original once with unchanged arguments");
    return !gFixtureFailed;
}

int main(void) {
    @autoreleasepool {
        gExpectedImageURL = FixtureImageURL();

#if TKP_PROFILE_FIXTURE_MODE == 0
        TestNormalBehavior();
#elif TKP_PROFILE_FIXTURE_MODE == 1
        Check(objc_getClass("TTKProfileViewsVisitor") == Nil, "target class is absent");
        Check(TKPProfileControlsInstall(gExpectedImageURL) ==
                  TKPProfileControlsStatusClassUnavailable,
              "missing target class is rejected");
#elif TKP_PROFILE_FIXTURE_MODE == 2
        TestRejection(TKPProfileControlsStatusGetterUnavailable, gExpectedImageURL);
#elif TKP_PROFILE_FIXTURE_MODE == 3
        TestRejection(TKPProfileControlsStatusInheritedGetter, gExpectedImageURL);
#elif TKP_PROFILE_FIXTURE_MODE == 4
        TestRejection(TKPProfileControlsStatusSignatureMismatch, gExpectedImageURL);
#elif TKP_PROFILE_FIXTURE_MODE == 5
        TestRejection(TKPProfileControlsStatusImageMismatch,
                      [NSURL fileURLWithPath:@"/usr/bin/true"]);
#elif TKP_PROFILE_FIXTURE_MODE == 6
        pthread_t worker;
        if (pthread_create(&worker, NULL, InstallFromWorker, NULL) != 0) {
            Check(NO, "worker thread starts");
            return 1;
        }
        if (pthread_join(worker, NULL) != 0) {
            Check(NO, "worker thread joins");
            return 1;
        }
        Check(gBackgroundStatus == TKPProfileControlsStatusMainThreadRequired,
              "off-main-thread installation is rejected");
        Check(TKPProfileControlsInstall(gExpectedImageURL) == TKPProfileControlsStatusInstalled,
              "rejected worker installation leaves main-thread install available");
        gBackgroundSuppressionRequest = YES;
        if (pthread_create(&worker, NULL, SetSuppressionFromWorker, NULL) != 0) {
            Check(NO, "enable worker thread starts");
            return 1;
        }
        if (pthread_join(worker, NULL) != 0) {
            Check(NO, "enable worker thread joins");
            return 1;
        }
        Check(gBackgroundStatus == TKPProfileControlsStatusMainThreadRequired &&
                  !TKPProfileControlsSuppressionEnabled(),
              "off-main-thread enabling is rejected without changing suppression");
        Check(TKPProfileControlsSetSuppressionEnabled(YES) ==
                  TKPProfileControlsStatusSuppressionEnabled,
              "main thread enables suppression");
        gBackgroundSuppressionRequest = NO;
        if (pthread_create(&worker, NULL, SetSuppressionFromWorker, NULL) != 0) {
            Check(NO, "disable worker thread starts");
            return 1;
        }
        if (pthread_join(worker, NULL) != 0) {
            Check(NO, "disable worker thread joins");
            return 1;
        }
        Check(gBackgroundStatus == TKPProfileControlsStatusMainThreadRequired &&
                  TKPProfileControlsSuppressionEnabled(),
              "off-main-thread disabling is rejected without changing suppression");
        Check(TKPProfileControlsSetSuppressionEnabled(NO) ==
                  TKPProfileControlsStatusSuppressionDisabled,
              "main thread disables suppression");
#elif TKP_PROFILE_FIXTURE_MODE == 7
        TestConflictDisablesWithoutReclaiming();
#elif TKP_PROFILE_FIXTURE_MODE == 8
        TestRejection(TKPProfileControlsStatusSignatureMismatch, gExpectedImageURL);
#elif TKP_PROFILE_FIXTURE_MODE == 9
        // Keep the fixture's class image and method metadata unchanged, but use
        // an IMP from the system runtime. Installation must reject it without
        // calling that incompatible implementation or changing either getter.
        Method fixtureMethod = TargetMethod(sel_registerName("p_shouldReportProfileView"));
        Method foreignMethod = class_getInstanceMethod([NSObject class], @selector(isKindOfClass:));
        if (fixtureMethod == NULL || foreignMethod == NULL) {
            Check(NO, "image rejection methods are available");
            return 1;
        }
        IMP foreignImplementation = method_getImplementation(foreignMethod);
        if (foreignImplementation == NULL) {
            Check(NO, "foreign implementation is available");
            return 1;
        }
        method_setImplementation(fixtureMethod, foreignImplementation);
        TestRejection(TKPProfileControlsStatusImageMismatch, gExpectedImageURL);
#endif

        if (gFixtureFailed) {
            return 1;
        }
        puts("PASS: synthetic profile controls fixture");
        return 0;
    }
}
