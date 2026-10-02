#import "TKPProfileControls.h"

#import <dlfcn.h>
#import <objc/runtime.h>

#include <limits.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static const char * const TKPProfileClassName = "TTKProfileViewsVisitor";
static const char * const TKPShouldReportSelectorName = "p_shouldReportProfileView";
static const char * const TKPShouldReportForUserSelectorName =
    "p_shouldReportHasVeiwedProfileForUser:";

static Method gShouldReportMethod = NULL;
static Method gShouldReportForUserMethod = NULL;
static _Atomic(IMP) gShouldReportOriginal = NULL;
static _Atomic(IMP) gShouldReportForUserOriginal = NULL;
static BOOL gInstalled = NO;
static BOOL gMutationAttempted = NO;
static atomic_bool gSuppressionEnabled = ATOMIC_VAR_INIT(false);

static BOOL TKPShouldReportProfileView(id receiver, SEL command) {
    if (atomic_load_explicit(&gSuppressionEnabled, memory_order_acquire)) {
        return NO;
    }

    IMP original = atomic_load_explicit(&gShouldReportOriginal, memory_order_acquire);
    if (original == NULL) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))original)(receiver, command);
}

static BOOL TKPShouldReportHasViewedProfileForUser(id receiver, SEL command, id user) {
    if (atomic_load_explicit(&gSuppressionEnabled, memory_order_acquire)) {
        return NO;
    }

    IMP original = atomic_load_explicit(&gShouldReportForUserOriginal, memory_order_acquire);
    if (original == NULL) {
        return NO;
    }
    return ((BOOL (*)(id, SEL, id))original)(receiver, command, user);
}

static Method TKPOwnInstanceMethod(Class targetClass, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    Method result = NULL;

    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }

    free(methods);
    return result;
}

static BOOL TKPTypesEqual(const char *actual, const char *expected) {
    return actual != NULL && expected != NULL && strcmp(actual, expected) == 0;
}

static BOOL TKPHasExpectedSignature(Method method, BOOL hasUserArgument) {
    if (method == NULL || method_getNumberOfArguments(method) != (hasUserArgument ? 3 : 2)) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *receiverType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    char *userType = hasUserArgument ? method_copyArgumentType(method, 2) : NULL;

    BOOL valid = TKPTypesEqual(returnType, @encode(BOOL)) &&
        TKPTypesEqual(receiverType, @encode(id)) &&
        TKPTypesEqual(selectorType, @encode(SEL)) &&
        (!hasUserArgument || TKPTypesEqual(userType, @encode(id)));

    free(returnType);
    free(receiverType);
    free(selectorType);
    free(userType);
    return valid;
}

static BOOL TKPCanonicalPath(const char *path, char output[PATH_MAX]) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    return realpath(path, output) != NULL;
}

static BOOL TKPImagePathMatches(const char *candidatePath, const char *trustedPath) {
    char candidateCanonical[PATH_MAX];
    return trustedPath != NULL && TKPCanonicalPath(candidatePath, candidateCanonical) &&
        strcmp(candidateCanonical, trustedPath) == 0;
}

static BOOL TKPImplementationImageMatches(IMP implementation, const char *trustedPath) {
    Dl_info imageInfo = {0};
    if (implementation == NULL || dladdr(implementation, &imageInfo) == 0) {
        return NO;
    }
    return TKPImagePathMatches(imageInfo.dli_fname, trustedPath);
}

static BOOL TKPWrappersAreInstalled(void) {
    return gShouldReportMethod != NULL && gShouldReportForUserMethod != NULL &&
        method_getImplementation(gShouldReportMethod) == (IMP)TKPShouldReportProfileView &&
        method_getImplementation(gShouldReportForUserMethod) ==
            (IMP)TKPShouldReportHasViewedProfileForUser;
}

TKPProfileControlsStatus TKPProfileControlsInstall(NSURL *expectedImageURL) {
    if (![NSThread isMainThread]) {
        return TKPProfileControlsStatusMainThreadRequired;
    }

    if (gInstalled) {
        if (!TKPWrappersAreInstalled()) {
            atomic_store_explicit(&gSuppressionEnabled, false, memory_order_release);
            return TKPProfileControlsStatusHookConflict;
        }
        return TKPProfileControlsStatusAlreadyInstalled;
    }
    if (gMutationAttempted) {
        return TKPProfileControlsStatusHookConflict;
    }

    if (![expectedImageURL isKindOfClass:[NSURL class]] || !expectedImageURL.isFileURL) {
        return TKPProfileControlsStatusInvalidImageURL;
    }

    char trustedPath[PATH_MAX];
    if (!TKPCanonicalPath(expectedImageURL.fileSystemRepresentation, trustedPath)) {
        return TKPProfileControlsStatusInvalidImageURL;
    }

    Class targetClass = objc_getClass(TKPProfileClassName);
    if (targetClass == Nil) {
        return TKPProfileControlsStatusClassUnavailable;
    }

    SEL shouldReportSelector = sel_registerName(TKPShouldReportSelectorName);
    SEL shouldReportForUserSelector = sel_registerName(TKPShouldReportForUserSelectorName);
    Method shouldReportMethod = TKPOwnInstanceMethod(targetClass, shouldReportSelector);
    Method shouldReportForUserMethod = TKPOwnInstanceMethod(targetClass, shouldReportForUserSelector);

    if (shouldReportMethod == NULL || shouldReportForUserMethod == NULL) {
        Class superclass = class_getSuperclass(targetClass);
        BOOL inherited = (shouldReportMethod == NULL && superclass != Nil &&
                          class_getInstanceMethod(superclass, shouldReportSelector) != NULL) ||
            (shouldReportForUserMethod == NULL && superclass != Nil &&
             class_getInstanceMethod(superclass, shouldReportForUserSelector) != NULL);
        return inherited ? TKPProfileControlsStatusInheritedGetter
                         : TKPProfileControlsStatusGetterUnavailable;
    }

    if (!TKPHasExpectedSignature(shouldReportMethod, NO) ||
        !TKPHasExpectedSignature(shouldReportForUserMethod, YES)) {
        return TKPProfileControlsStatusSignatureMismatch;
    }

    const char *classImagePath = class_getImageName(targetClass);
    IMP shouldReportOriginal = method_getImplementation(shouldReportMethod);
    IMP shouldReportForUserOriginal = method_getImplementation(shouldReportForUserMethod);
    if (!TKPImagePathMatches(classImagePath, trustedPath) ||
        !TKPImplementationImageMatches(shouldReportOriginal, trustedPath) ||
        !TKPImplementationImageMatches(shouldReportForUserOriginal, trustedPath)) {
        return TKPProfileControlsStatusImageMismatch;
    }

    // Publish originals before either runtime method can point at a wrapper.
    gShouldReportMethod = shouldReportMethod;
    gShouldReportForUserMethod = shouldReportForUserMethod;
    atomic_store_explicit(&gShouldReportOriginal, shouldReportOriginal, memory_order_release);
    atomic_store_explicit(&gShouldReportForUserOriginal, shouldReportForUserOriginal,
                          memory_order_release);
    gMutationAttempted = YES;
    atomic_store_explicit(&gSuppressionEnabled, false, memory_order_release);

    IMP previousShouldReport = method_setImplementation(
        shouldReportMethod, (IMP)TKPShouldReportProfileView);
    if (previousShouldReport != shouldReportOriginal) {
        if (method_getImplementation(shouldReportMethod) == (IMP)TKPShouldReportProfileView) {
            method_setImplementation(shouldReportMethod, previousShouldReport);
        }
        return TKPProfileControlsStatusHookConflict;
    }

    IMP previousShouldReportForUser = method_setImplementation(
        shouldReportForUserMethod, (IMP)TKPShouldReportHasViewedProfileForUser);
    if (previousShouldReportForUser != shouldReportForUserOriginal) {
        if (method_getImplementation(shouldReportForUserMethod) ==
            (IMP)TKPShouldReportHasViewedProfileForUser) {
            method_setImplementation(shouldReportForUserMethod, previousShouldReportForUser);
        }
        if (method_getImplementation(shouldReportMethod) == (IMP)TKPShouldReportProfileView) {
            method_setImplementation(shouldReportMethod, shouldReportOriginal);
        }
        return TKPProfileControlsStatusHookConflict;
    }

    gInstalled = YES;
    return TKPProfileControlsStatusInstalled;
}

TKPProfileControlsStatus TKPProfileControlsSetSuppressionEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        return TKPProfileControlsStatusMainThreadRequired;
    }

    if (!gInstalled) {
        return TKPProfileControlsStatusNotInstalled;
    }

    if (!TKPWrappersAreInstalled()) {
        atomic_store_explicit(&gSuppressionEnabled, false, memory_order_release);
        return TKPProfileControlsStatusHookConflict;
    }

    atomic_store_explicit(&gSuppressionEnabled, enabled, memory_order_release);
    return enabled ? TKPProfileControlsStatusSuppressionEnabled
                   : TKPProfileControlsStatusSuppressionDisabled;
}

BOOL TKPProfileControlsSuppressionEnabled(void) {
    return atomic_load_explicit(&gSuppressionEnabled, memory_order_acquire);
}

NSString *TKPProfileControlsDiagnostic(TKPProfileControlsStatus status) {
    switch (status) {
        case TKPProfileControlsStatusInstalled:
            return @"Profile eligibility hooks installed; suppression remains off.";
        case TKPProfileControlsStatusAlreadyInstalled:
            return @"Profile eligibility hooks were already installed.";
        case TKPProfileControlsStatusSuppressionEnabled:
            return @"Profile eligibility suppression is enabled.";
        case TKPProfileControlsStatusSuppressionDisabled:
            return @"Profile eligibility suppression is disabled.";
        case TKPProfileControlsStatusInvalidImageURL:
            return @"The trusted image URL is invalid or unavailable.";
        case TKPProfileControlsStatusMainThreadRequired:
            return @"This operation requires the main thread.";
        case TKPProfileControlsStatusClassUnavailable:
            return @"The target profile class is unavailable.";
        case TKPProfileControlsStatusGetterUnavailable:
            return @"A required own profile eligibility method is unavailable.";
        case TKPProfileControlsStatusInheritedGetter:
            return @"A required profile eligibility method is inherited.";
        case TKPProfileControlsStatusSignatureMismatch:
            return @"A profile eligibility method has an unexpected signature.";
        case TKPProfileControlsStatusImageMismatch:
            return @"The target class or original implementation is outside the trusted image.";
        case TKPProfileControlsStatusHookConflict:
            return @"A profile eligibility implementation changed outside this module.";
        case TKPProfileControlsStatusNotInstalled:
            return @"Profile eligibility hooks are not installed.";
    }
    return @"Unknown profile controls status.";
}
