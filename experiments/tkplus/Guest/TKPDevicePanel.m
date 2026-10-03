#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <limits.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#import "TKPProfileControls.h"

__attribute__((visibility("default"))) void TKPDevicePanelStart(void);

static const NSTimeInterval TKPDiscoveryInterval = 0.25;
static const NSTimeInterval TKPDiscoveryLimit = 30.0;
static const NSTimeInterval TKPProfilePressDuration = 0.4;
static const NSUInteger TKPViewDepthLimit = 32;
static const NSUInteger TKPViewCountLimit = 4096;
static const NSUInteger TKPClassChainDepthLimit = 32;
static const NSUInteger TKPClassMethodCountLimit = 4096;
static const NSUInteger TKPTabBarCandidateCountLimit = 32;
static const NSUInteger TKPTabButtonsMinimumCount = 5;
static const NSUInteger TKPTabButtonsMaximumCount = 16;
static const NSUInteger TKPProfileButtonIndex = 4;
static const char * const TKPTabBarClassName = "TTKTabBar";
static const char * const TKPTabButtonsGetterName = "buttons";
static const char * const TKPLocalOnlyCaveat =
    "Local only: this suppresses two profile-view eligibility checks in this guest. "
    "Other reporting paths may still operate. This does not guarantee anonymous viewing.";

static _Atomic(uint64_t) gDevicePanelStartEpoch = 0;
static TKPProfileControlsStatus gLastProfileControlsStatus =
    TKPProfileControlsStatusNotInstalled;

static NSURL *TKPTrustedGuestImageURL(void);

typedef NS_ENUM(NSUInteger, TKPProfileTargetResolution) {
    TKPProfileTargetResolutionUnavailable = 0,
    TKPProfileTargetResolutionNotFound,
    TKPProfileTargetResolutionUnique,
    TKPProfileTargetResolutionAmbiguous,
    TKPProfileTargetResolutionBoundsExceeded,
};

static BOOL TKPRectHasArea(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsEmpty(rect) && !CGRectIsInfinite(rect) &&
        CGRectGetWidth(rect) > 0.0 && CGRectGetHeight(rect) > 0.0;
}

static BOOL TKPViewHasVisibleGeometry(UIView *view, UIWindow *window) {
    if (view == nil || window == nil || view.window != window || window.hidden ||
        window.alpha <= 0.01 || !TKPRectHasArea(window.bounds)) {
        return NO;
    }

    BOOL reachedWindow = NO;
    NSUInteger ancestorDepth = 0;
    for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestorDepth++ >= TKPViewDepthLimit) {
            return NO;
        }
        if (ancestor.hidden || ancestor.alpha <= 0.01) {
            return NO;
        }
        if (ancestor != window && ancestor.window != window) {
            return NO;
        }
        if (ancestor.clipsToBounds) {
            CGRect descendantRect = [view convertRect:view.bounds toView:ancestor];
            if (!TKPRectHasArea(CGRectIntersection(descendantRect, ancestor.bounds))) {
                return NO;
            }
        }
        if (ancestor == window) {
            reachedWindow = YES;
            break;
        }
    }
    if (!reachedWindow || !TKPRectHasArea(view.bounds)) {
        return NO;
    }

    CGRect windowRect = [view convertRect:view.bounds toView:window];
    return TKPRectHasArea(CGRectIntersection(windowRect, window.bounds));
}

static BOOL TKPClassIsSubclassOfClass(Class candidate, Class ancestorClass) {
    if (candidate == Nil || ancestorClass == Nil) {
        return NO;
    }
    NSUInteger depth = 0;
    for (Class current = candidate; current != Nil; current = class_getSuperclass(current)) {
        if (depth >= TKPClassChainDepthLimit) {
            return NO;
        }
        depth += 1;
        if (current == ancestorClass) {
            return YES;
        }
    }
    return NO;
}

static BOOL TKPCanonicalPath(const char *path, char output[PATH_MAX]) {
    return path != NULL && path[0] != '\0' && realpath(path, output) != NULL;
}

static BOOL TKPClassImageMatchesTrustedGuest(Class candidate, NSURL *trustedImageURL) {
    if (candidate == Nil || class_isMetaClass(candidate) || trustedImageURL == nil ||
        !TKPClassIsSubclassOfClass(candidate, UIView.class)) {
        return NO;
    }

    const char *imagePath = class_getImageName(candidate);
    const char *trustedPath = trustedImageURL.fileSystemRepresentation;
    char canonicalImagePath[PATH_MAX];
    char canonicalTrustedPath[PATH_MAX];
    return TKPCanonicalPath(imagePath, canonicalImagePath) &&
        TKPCanonicalPath(trustedPath, canonicalTrustedPath) &&
        strcmp(canonicalImagePath, canonicalTrustedPath) == 0;
}

static BOOL TKPTabBarClassChainMatchesTrustedGuest(Class actualClass,
                                                   Class tabBarBaseClass,
                                                   NSURL *trustedImageURL) {
    if (actualClass == Nil || tabBarBaseClass == Nil ||
        !TKPClassImageMatchesTrustedGuest(tabBarBaseClass, trustedImageURL) ||
        !TKPClassIsSubclassOfClass(actualClass, tabBarBaseClass)) {
        return NO;
    }

    NSUInteger depth = 0;
    for (Class current = actualClass; current != Nil; current = class_getSuperclass(current)) {
        if (depth >= TKPClassChainDepthLimit ||
            !TKPClassImageMatchesTrustedGuest(current, trustedImageURL)) {
            return NO;
        }
        depth += 1;
        if (current == tabBarBaseClass) {
            return YES;
        }
    }
    return NO;
}

static BOOL TKPIMPImageMatchesTrustedGuest(IMP implementation, NSURL *trustedImageURL) {
    if (implementation == NULL || trustedImageURL == nil) {
        return NO;
    }

    Dl_info implementationImage = {0};
    if (dladdr((const void *)(uintptr_t)implementation, &implementationImage) == 0 ||
        implementationImage.dli_fname == NULL) {
        return NO;
    }

    const char *trustedPath = trustedImageURL.fileSystemRepresentation;
    char canonicalImplementationPath[PATH_MAX];
    char canonicalTrustedPath[PATH_MAX];
    return TKPCanonicalPath(implementationImage.dli_fname, canonicalImplementationPath) &&
        TKPCanonicalPath(trustedPath, canonicalTrustedPath) &&
        strcmp(canonicalImplementationPath, canonicalTrustedPath) == 0;
}

static BOOL TKPMethodHasExactNoArgumentObjectSignature(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *selfType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    BOOL matches = returnType != NULL && strcmp(returnType, "@") == 0 &&
        selfType != NULL && strcmp(selfType, "@") == 0 &&
        selectorType != NULL && strcmp(selectorType, ":") == 0;
    free(returnType);
    free(selfType);
    free(selectorType);
    return matches;
}

static BOOL TKPFindTrustedTabButtonsGetter(Class actualClass,
                                           Class tabBarBaseClass,
                                           NSURL *trustedImageURL,
                                           IMP *implementationOut) {
    if (implementationOut != NULL) {
        *implementationOut = NULL;
    }
    if (!TKPTabBarClassChainMatchesTrustedGuest(actualClass, tabBarBaseClass,
                                                trustedImageURL)) {
        return NO;
    }

    SEL getterSelector = sel_registerName(TKPTabButtonsGetterName);
    NSUInteger depth = 0;
    for (Class current = actualClass; current != Nil; current = class_getSuperclass(current)) {
        if (depth++ >= TKPClassChainDepthLimit) {
            return NO;
        }

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(current, &methodCount);
        if ((methods == NULL && methodCount != 0) ||
            methodCount > TKPClassMethodCountLimit) {
            free(methods);
            return NO;
        }
        Method getterMethod = NULL;
        BOOL duplicateGetter = NO;
        for (unsigned int index = 0; index < methodCount; index += 1) {
            if (method_getName(methods[index]) == getterSelector) {
                if (getterMethod != NULL) {
                    duplicateGetter = YES;
                    break;
                }
                getterMethod = methods[index];
            }
        }
        free(methods);

        if (duplicateGetter) {
            return NO;
        }
        if (getterMethod != NULL) {
            if (!TKPMethodHasExactNoArgumentObjectSignature(getterMethod)) {
                return NO;
            }
            IMP implementation = method_getImplementation(getterMethod);
            if (!TKPIMPImageMatchesTrustedGuest(implementation, trustedImageURL)) {
                return NO;
            }
            if (implementationOut != NULL) {
                *implementationOut = implementation;
            }
            return YES;
        }
        if (current == tabBarBaseClass) {
            break;
        }
    }
    return NO;
}

static BOOL TKPViewIsDescendantOfView(UIView *view, UIView *ancestor) {
    if (view == nil || ancestor == nil || view == ancestor) {
        return NO;
    }

    NSUInteger depth = 0;
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if (depth++ >= TKPViewDepthLimit) {
            return NO;
        }
        if (current == ancestor) {
            return YES;
        }
    }
    return NO;
}

static BOOL TKPResolveButtonsProfileTarget(UIView *tabBar,
                                          Class tabBarBaseClass,
                                          NSURL *trustedImageURL,
                                          UIWindow *window,
                                          UIView **targetOut) {
    if (targetOut != NULL) {
        *targetOut = nil;
    }
    // Do not change disabled native views to make the gesture available.
    if (tabBar == nil || window == nil || !tabBar.isUserInteractionEnabled ||
        !TKPViewHasVisibleGeometry(tabBar, window)) {
        return NO;
    }

    IMP getterImplementation = NULL;
    Class actualClass = object_getClass(tabBar);
    if (!TKPFindTrustedTabButtonsGetter(actualClass, tabBarBaseClass,
                                        trustedImageURL, &getterImplementation)) {
        return NO;
    }

    typedef id (*TKPTabButtonsGetter)(id, SEL);
    id buttonsObject = nil;
    NSUInteger buttonCount = 0;
    id selectedButton = nil;
    @try {
        buttonsObject = ((TKPTabButtonsGetter)getterImplementation)(tabBar,
            sel_registerName(TKPTabButtonsGetterName));
        Class buttonsClass = object_getClass(buttonsObject);
        if (!TKPClassIsSubclassOfClass(buttonsClass, NSArray.class)) {
            return NO;
        }

        NSArray *buttons = (NSArray *)buttonsObject;
        buttonCount = buttons.count;
        if (buttonCount < TKPTabButtonsMinimumCount ||
            buttonCount > TKPTabButtonsMaximumCount) {
            return NO;
        }
        selectedButton = [buttons objectAtIndex:TKPProfileButtonIndex];
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }

    Class selectedButtonClass = object_getClass(selectedButton);
    if (!TKPClassIsSubclassOfClass(selectedButtonClass, UIView.class)) {
        return NO;
    }

    UIView *target = (UIView *)selectedButton;
    if (!target.isUserInteractionEnabled || target.window != window ||
        !TKPViewIsDescendantOfView(target, tabBar) ||
        !TKPViewHasVisibleGeometry(target, window)) {
        return NO;
    }
    if (targetOut != NULL) {
        *targetOut = target;
    }
    return YES;
}

typedef struct {
    __unsafe_unretained UIWindow *window;
    Class tabBarBaseClass;
    __unsafe_unretained NSURL *trustedImageURL;
    __unsafe_unretained NSMutableArray<UIView *> *tabBars;
    NSUInteger *discoveredTabBarCount;
    NSUInteger visitedViewCount;
    BOOL boundsExceeded;
} TKPTabBarScan;

static void TKPScanTabBars(UIView *view, NSUInteger depth, TKPTabBarScan *scan) {
    if (scan->boundsExceeded || view == nil) {
        return;
    }
    if (depth > TKPViewDepthLimit || ++scan->visitedViewCount > TKPViewCountLimit) {
        scan->boundsExceeded = YES;
        return;
    }
    if (!TKPViewHasVisibleGeometry(view, scan->window)) {
        return;
    }

    Class actualClass = object_getClass(view);
    if (TKPTabBarClassChainMatchesTrustedGuest(actualClass, scan->tabBarBaseClass,
                                               scan->trustedImageURL)) {
        if (++*scan->discoveredTabBarCount > TKPTabBarCandidateCountLimit) {
            scan->boundsExceeded = YES;
            return;
        }
        UIView *profileTarget = nil;
        if (TKPResolveButtonsProfileTarget(view, scan->tabBarBaseClass,
                                           scan->trustedImageURL, scan->window,
                                           &profileTarget)) {
            [scan->tabBars addObject:view];
            if (scan->tabBars.count > 1) {
                return;
            }
        }
    }

    NSArray<UIView *> *subviews = view.subviews;
    for (UIView *subview in subviews) {
        TKPScanTabBars(subview, depth + 1, scan);
        if (scan->boundsExceeded || scan->tabBars.count > 1) {
            return;
        }
    }
}

static BOOL TKPWindowIsVisibleGuestCandidate(UIWindow *window, UIWindowScene *scene) {
    if (window == nil || scene == nil || window.windowScene != scene || window.hidden ||
        window.alpha <= 0.01 || window.windowLevel != UIWindowLevelNormal ||
        window.rootViewController == nil || !TKPRectHasArea(window.bounds)) {
        return NO;
    }
    UIView *rootView = window.rootViewController.viewIfLoaded;
    return rootView != nil && TKPViewHasVisibleGeometry(rootView, window);
}

static TKPProfileTargetResolution
TKPResolveUniqueProfileTarget(UIView **tabBarOut, UIView **targetOut, UIWindow **windowOut) {
    if (tabBarOut != NULL) {
        *tabBarOut = nil;
    }
    if (targetOut != NULL) {
        *targetOut = nil;
    }
    if (windowOut != NULL) {
        *windowOut = nil;
    }

    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) {
        return TKPProfileTargetResolutionUnavailable;
    }

    NSURL *trustedImageURL = TKPTrustedGuestImageURL();
    if (trustedImageURL == nil) {
        return TKPProfileTargetResolutionUnavailable;
    }

    Class tabBarBaseClass = objc_getClass(TKPTabBarClassName);
    if (!TKPClassImageMatchesTrustedGuest(tabBarBaseClass, trustedImageURL)) {
        return TKPProfileTargetResolutionUnavailable;
    }

    NSMutableArray<UIView *> *tabBars = [NSMutableArray arrayWithCapacity:2];
    UIWindow *tabBarWindow = nil;
    NSUInteger discoveredTabBarCount = 0;
    NSUInteger visitedViewCount = 0;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!TKPWindowIsVisibleGuestCandidate(window, windowScene)) {
                continue;
            }

            UIView *rootView = window.rootViewController.viewIfLoaded;
            NSUInteger tabBarCountBeforeWindow = tabBars.count;
            TKPTabBarScan scan = {
                .window = window,
                .tabBarBaseClass = tabBarBaseClass,
                .trustedImageURL = trustedImageURL,
                .tabBars = tabBars,
                .discoveredTabBarCount = &discoveredTabBarCount,
                .visitedViewCount = visitedViewCount,
                .boundsExceeded = NO,
            };
            TKPScanTabBars(rootView, 0, &scan);
            visitedViewCount = scan.visitedViewCount;
            if (scan.boundsExceeded) {
                return TKPProfileTargetResolutionBoundsExceeded;
            }
            if (tabBars.count > 1) {
                return TKPProfileTargetResolutionAmbiguous;
            }
            if (tabBars.count == tabBarCountBeforeWindow + 1) {
                tabBarWindow = window;
            }
        }
    }

    if (tabBars.count != 1 || tabBarWindow == nil) {
        return TKPProfileTargetResolutionNotFound;
    }

    UIView *tabBar = tabBars.firstObject;
    UIView *target = nil;
    if (!TKPResolveButtonsProfileTarget(tabBar, tabBarBaseClass, trustedImageURL,
                                        tabBarWindow, &target)) {
        return TKPProfileTargetResolutionNotFound;
    }
    if (tabBarOut != NULL) {
        *tabBarOut = tabBar;
    }
    if (targetOut != NULL) {
        *targetOut = target;
    }
    if (windowOut != NULL) {
        *windowOut = tabBarWindow;
    }
    return TKPProfileTargetResolutionUnique;
}

@interface TKPDevicePanelController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong, nullable) NSTimer *discoveryTimer;
@property (nonatomic, weak, nullable) UIWindow *hostWindow;
@property (nonatomic, weak, nullable) UIWindowScene *hostScene;
@property (nonatomic, weak, nullable) UIView *tabBarView;
@property (nonatomic, weak, nullable) UIView *profileTabView;
@property (nonatomic, weak, nullable) UIView *acceptedProfilePressTarget;
@property (nonatomic, strong, nullable) UILongPressGestureRecognizer *profilePressRecognizer;
@property (nonatomic, strong, nullable) UIView *ownedScreenView;
@property (nonatomic, strong, nullable) UIView *gearScreenView;
@property (nonatomic, strong, nullable) UIView *settingsScreenView;
@property (nonatomic, weak, nullable) UIButton *gearButton;
@property (nonatomic, weak, nullable) UIButton *closeButton;
@property (nonatomic, weak, nullable) UISwitch *suppressionSwitch;
@property (nonatomic, weak, nullable) UILabel *statusLabel;
@property (nonatomic) NSTimeInterval discoveryDeadline;
@property (nonatomic) uint64_t lifecycleEpoch;
@property (nonatomic) BOOL observersInstalled;

- (void)profileTabLongPressed:(UILongPressGestureRecognizer *)recognizer;
- (void)showGearScreen;
- (void)gearButtonTapped:(UIButton *)sender;
- (void)closeButtonTapped:(UIButton *)sender;
- (void)suppressionSwitchChanged:(UISwitch *)sender;
- (BOOL)reconcileVisibleGuestTab;
- (BOOL)acceptProfilePressTouchInView:(nullable UIView *)touchedView;
- (void)applicationWillResignActive:(NSNotification *)notification;
@end

@implementation TKPDevicePanelController

+ (instancetype)sharedController {
    static TKPDevicePanelController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (void)start {
    NSAssert([NSThread isMainThread], @"Device panel startup must run on the main thread.");
    if (!self.observersInstalled) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationWillResignActive:)
                       name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidEnterBackground:)
                       name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(sceneWillDeactivate:)
                       name:UISceneWillDeactivateNotification object:nil];
        [center addObserver:self selector:@selector(sceneDidActivate:)
                       name:UISceneDidActivateNotification object:nil];
        [center addObserver:self selector:@selector(sceneDidDisconnect:)
                       name:UISceneDidDisconnectNotification object:nil];
        self.observersInstalled = YES;
    }
    [self beginBoundedDiscovery];
}

- (void)beginBoundedDiscovery {
    if (![NSThread isMainThread] || self.discoveryTimer != nil ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    if (self.profilePressRecognizer != nil && [self hasCurrentInteractionContext]) {
        return;
    }
    [self detachProfileGestureAndOverlay];

    self.lifecycleEpoch += 1;
    if (self.lifecycleEpoch == 0) {
        self.lifecycleEpoch = 1;
    }
    self.discoveryDeadline = NSProcessInfo.processInfo.systemUptime + TKPDiscoveryLimit;
    NSTimer *timer = [NSTimer timerWithTimeInterval:TKPDiscoveryInterval
                                            target:self
                                          selector:@selector(discoveryTick:)
                                          userInfo:@(self.lifecycleEpoch)
                                           repeats:YES];
    self.discoveryTimer = timer;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [self discoveryTick:timer];
}

- (void)stopDiscovery {
    [self.discoveryTimer invalidate];
    self.discoveryTimer = nil;
}

- (void)discoveryTick:(NSTimer *)timer {
    if (timer != self.discoveryTimer ||
        [timer.userInfo unsignedLongLongValue] != self.lifecycleEpoch) {
        return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self cleanupForLifecycleTransition];
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.discoveryDeadline) {
        [self stopDiscovery];
        return;
    }
    if ([self reconcileVisibleGuestTab]) {
        [self stopDiscovery];
    }
}

- (BOOL)reconcileVisibleGuestTab {
    NSAssert([NSThread isMainThread], @"Guest tab discovery must run on the main thread.");
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self detachProfileGestureAndOverlay];
        return NO;
    }

    UIView *tabBar = nil;
    UIView *candidate = nil;
    UIWindow *window = nil;
    TKPProfileTargetResolution resolution =
        TKPResolveUniqueProfileTarget(&tabBar, &candidate, &window);
    if (resolution != TKPProfileTargetResolutionUnique || tabBar == nil ||
        candidate == nil || window == nil) {
        [self detachProfileGestureAndOverlay];
        return NO;
    }

    if (self.tabBarView == tabBar && self.hostWindow == window &&
        self.profilePressRecognizer.view == tabBar) {
        self.profileTabView = candidate;
        self.hostScene = window.windowScene;
        return YES;
    }

    [self detachProfileGestureAndOverlay];
    self.hostWindow = window;
    self.hostScene = window.windowScene;
    self.tabBarView = tabBar;
    self.profileTabView = candidate;

    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(profileTabLongPressed:)];
    recognizer.minimumPressDuration = TKPProfilePressDuration;
    // Match the observed 0.4-second hold; actual native tap delivery remains device-unverified.
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = self;
    self.profilePressRecognizer = recognizer;
    [tabBar addGestureRecognizer:recognizer];
    return YES;
}

- (BOOL)hasCurrentInteractionContext {
    UIWindow *window = self.hostWindow;
    UIWindowScene *scene = self.hostScene;
    UIView *tabBar = self.tabBarView;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        window == nil || scene == nil || window.windowScene != scene ||
        scene.activationState != UISceneActivationStateForegroundActive ||
        !TKPWindowIsVisibleGuestCandidate(window, scene) ||
        tabBar == nil || !tabBar.isUserInteractionEnabled ||
        !TKPViewHasVisibleGeometry(tabBar, window) ||
        self.profilePressRecognizer.view != tabBar) {
        return NO;
    }

    UIView *resolvedTabBar = nil;
    UIView *resolvedCandidate = nil;
    UIWindow *resolvedWindow = nil;
    if (TKPResolveUniqueProfileTarget(&resolvedTabBar, &resolvedCandidate, &resolvedWindow) !=
            TKPProfileTargetResolutionUnique ||
        resolvedTabBar != tabBar || resolvedWindow != window || resolvedCandidate == nil) {
        return NO;
    }

    // The native button array can be rebuilt while the tab bar instance remains stable.
    // Refresh the authorized hit target from the validated getter on every interaction.
    self.profileTabView = resolvedCandidate;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return gestureRecognizer == self.profilePressRecognizer;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.profilePressRecognizer) {
        return NO;
    }

    return [self acceptProfilePressTouchInView:touch.view];
}

- (BOOL)acceptProfilePressTouchInView:(UIView *)touchedView {
    self.acceptedProfilePressTarget = nil;
    if (![self hasCurrentInteractionContext]) {
        return NO;
    }

    UIView *target = self.profileTabView;
    BOOL acceptsTouch = touchedView != nil && target != nil &&
        (touchedView == target || TKPViewIsDescendantOfView(touchedView, target)) &&
        TKPViewHasVisibleGeometry(touchedView, self.hostWindow);
    if (acceptsTouch) {
        self.acceptedProfilePressTarget = target;
    }
    return acceptsTouch;
}

- (void)profileTabLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer != self.profilePressRecognizer) {
        return;
    }

    if (recognizer.view != self.tabBarView) {
        self.acceptedProfilePressTarget = nil;
        return;
    }
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        if (recognizer.state == UIGestureRecognizerStateEnded ||
            recognizer.state == UIGestureRecognizerStateCancelled ||
            recognizer.state == UIGestureRecognizerStateFailed) {
            self.acceptedProfilePressTarget = nil;
        }
        return;
    }

    UIView *acceptedTarget = self.acceptedProfilePressTarget;
    BOOL hasCurrentContext = [self hasCurrentInteractionContext];
    if (!hasCurrentContext || acceptedTarget == nil ||
        acceptedTarget != self.profileTabView) {
        self.acceptedProfilePressTarget = nil;
        if (!hasCurrentContext) {
            [self detachProfileGestureAndOverlay];
        }
        return;
    }
    [self showGearScreen];
}

- (void)showGearScreen {
    UIView *acceptedTarget = self.acceptedProfilePressTarget;
    BOOL hasCurrentContext = [self hasCurrentInteractionContext];
    if (!hasCurrentContext ||
        (acceptedTarget != nil && acceptedTarget != self.profileTabView)) {
        self.acceptedProfilePressTarget = nil;
        if (!hasCurrentContext) {
            [self detachProfileGestureAndOverlay];
        }
        return;
    }
    self.acceptedProfilePressTarget = nil;
    if (self.ownedScreenView != nil) {
        return;
    }

    UIWindow *window = self.hostWindow;
    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    overlay.opaque = YES;
    overlay.accessibilityIdentifier = @"tkp.guest.profile-controls.overlay";
    [window addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor],
    ]];
    self.ownedScreenView = overlay;

    UIView *gearScreen = [[UIView alloc] initWithFrame:CGRectZero];
    gearScreen.translatesAutoresizingMaskIntoConstraints = NO;
    gearScreen.backgroundColor = UIColor.systemBackgroundColor;
    gearScreen.accessibilityIdentifier = @"tkp.guest.profile-controls.gear-screen";
    [overlay addSubview:gearScreen];
    [NSLayoutConstraint activateConstraints:@[
        [gearScreen.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [gearScreen.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [gearScreen.topAnchor constraintEqualToAnchor:overlay.topAnchor],
        [gearScreen.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
    ]];
    self.gearScreenView = gearScreen;

    UIButton *gearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [gearButton setImage:[UIImage systemImageNamed:@"gearshape.fill"]
                forState:UIControlStateNormal];
    gearButton.tintColor = UIColor.labelColor;
    gearButton.accessibilityLabel = @"Open profile settings";
    gearButton.accessibilityHint = @"Open local profile-view eligibility settings.";
    gearButton.accessibilityIdentifier = @"tkp.guest.profile-controls.gear-button";
    [gearButton addTarget:self action:@selector(gearButtonTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [gearScreen addSubview:gearButton];
    [NSLayoutConstraint activateConstraints:@[
        [gearButton.centerXAnchor constraintEqualToAnchor:gearScreen.centerXAnchor],
        [gearButton.centerYAnchor constraintEqualToAnchor:gearScreen.centerYAnchor],
        [gearButton.widthAnchor constraintEqualToConstant:96.0],
        [gearButton.heightAnchor constraintEqualToConstant:96.0],
    ]];
    self.gearButton = gearButton;
    [self addCloseButtonToOverlay:overlay];
}

- (void)addCloseButtonToOverlay:(UIView *)overlay {
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton setImage:[UIImage systemImageNamed:@"xmark"]
                 forState:UIControlStateNormal];
    closeButton.tintColor = UIColor.secondaryLabelColor;
    closeButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
    closeButton.layer.cornerRadius = 18.0;
    closeButton.accessibilityLabel = @"Close profile settings";
    closeButton.accessibilityIdentifier = @"tkp.guest.profile-controls.close-button";
    [closeButton addTarget:self action:@selector(closeButtonTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:closeButton];
    UILayoutGuide *safeArea = overlay.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
        [closeButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16.0],
        [closeButton.widthAnchor constraintEqualToConstant:44.0],
        [closeButton.heightAnchor constraintEqualToConstant:44.0],
    ]];
    self.closeButton = closeButton;
}

- (void)gearButtonTapped:(UIButton *)sender {
    (void)sender;
    if (![self hasCurrentInteractionContext] || self.ownedScreenView == nil ||
        self.gearScreenView.superview != self.ownedScreenView) {
        [self detachProfileGestureAndOverlay];
        return;
    }
    [self showSettingsScreen];
}

- (void)showSettingsScreen {
    if (![self hasCurrentInteractionContext] || self.ownedScreenView == nil) {
        [self detachProfileGestureAndOverlay];
        return;
    }
    [self.gearScreenView removeFromSuperview];
    self.gearScreenView = nil;
    self.gearButton = nil;

    UIView *settingsScreen = [[UIView alloc] initWithFrame:CGRectZero];
    settingsScreen.translatesAutoresizingMaskIntoConstraints = NO;
    settingsScreen.backgroundColor = UIColor.systemBackgroundColor;
    settingsScreen.accessibilityIdentifier = @"tkp.guest.profile-controls.settings-screen";
    [self.ownedScreenView insertSubview:settingsScreen atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [settingsScreen.leadingAnchor constraintEqualToAnchor:self.ownedScreenView.leadingAnchor],
        [settingsScreen.trailingAnchor constraintEqualToAnchor:self.ownedScreenView.trailingAnchor],
        [settingsScreen.topAnchor constraintEqualToAnchor:self.ownedScreenView.topAnchor],
        [settingsScreen.bottomAnchor constraintEqualToAnchor:self.ownedScreenView.bottomAnchor],
    ]];
    self.settingsScreenView = settingsScreen;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [settingsScreen addSubview:scrollView];
    UILayoutGuide *safeArea = settingsScreen.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:24.0],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-24.0],
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:72.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-16.0],
    ]];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.text = @"Profile settings";

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    subtitleLabel.adjustsFontForContentSizeCategory = YES;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = UIColor.secondaryLabelColor;
    subtitleLabel.text = @"Local controls for profile-view eligibility.";

    UILabel *switchTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    switchTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    switchTitleLabel.adjustsFontForContentSizeCategory = YES;
    switchTitleLabel.numberOfLines = 0;
    switchTitleLabel.text = @"Suppress profile-view eligibility checks";

    UISwitch *suppressionSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    suppressionSwitch.on = TKPProfileControlsSuppressionEnabled();
    suppressionSwitch.accessibilityLabel = @"Suppress profile-view eligibility checks";
    suppressionSwitch.accessibilityIdentifier = @"tkp.guest.profile-controls.suppression-switch";
    [suppressionSwitch addTarget:self action:@selector(suppressionSwitchChanged:)
                forControlEvents:UIControlEventValueChanged];
    self.suppressionSwitch = suppressionSwitch;

    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        switchTitleLabel, suppressionSwitch
    ]];
    switchRow.axis = UILayoutConstraintAxisHorizontal;
    switchRow.alignment = UIStackViewAlignmentCenter;
    switchRow.distribution = UIStackViewDistributionFill;
    switchRow.spacing = 16.0;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    statusLabel.adjustsFontForContentSizeCategory = YES;
    statusLabel.numberOfLines = 0;
    statusLabel.textColor = UIColor.secondaryLabelColor;
    statusLabel.accessibilityIdentifier = @"tkp.guest.profile-controls.status";
    statusLabel.text = TKPProfileControlsDiagnostic(gLastProfileControlsStatus);
    self.statusLabel = statusLabel;

    UILabel *caveatLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    caveatLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    caveatLabel.adjustsFontForContentSizeCategory = YES;
    caveatLabel.numberOfLines = 0;
    caveatLabel.textColor = UIColor.secondaryLabelColor;
    caveatLabel.text = [NSString stringWithUTF8String:TKPLocalOnlyCaveat];

    UIStackView *contentStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, subtitleLabel, switchRow, statusLabel, caveatLabel
    ]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.alignment = UIStackViewAlignmentFill;
    contentStack.distribution = UIStackViewDistributionFill;
    contentStack.spacing = 22.0;
    [scrollView addSubview:contentStack];
    UILayoutGuide *contentGuide = scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [contentStack.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor],
        [contentStack.topAnchor constraintEqualToAnchor:contentGuide.topAnchor],
        [contentStack.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor],
        [contentStack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor],
    ]];
}

- (void)closeButtonTapped:(UIButton *)sender {
    (void)sender;
    if (![self hasCurrentInteractionContext] || self.ownedScreenView == nil) {
        [self detachProfileGestureAndOverlay];
        return;
    }
    [self removeOwnedOverlay];
}

- (void)suppressionSwitchChanged:(UISwitch *)sender {
    if (sender != self.suppressionSwitch ||
        ![self hasCurrentInteractionContext] ||
        self.settingsScreenView.superview != self.ownedScreenView) {
        [self detachProfileGestureAndOverlay];
        return;
    }

    if (sender.isOn) {
        NSURL *trustedImageURL = TKPTrustedGuestImageURL();
        if (trustedImageURL == nil) {
            gLastProfileControlsStatus = TKPProfileControlsStatusInvalidImageURL;
        } else {
            TKPProfileControlsStatus status = TKPProfileControlsInstall(trustedImageURL);
            if (status == TKPProfileControlsStatusInstalled ||
                status == TKPProfileControlsStatusAlreadyInstalled) {
                status = TKPProfileControlsSetSuppressionEnabled(YES);
            }
            gLastProfileControlsStatus = status;
        }
    } else {
        gLastProfileControlsStatus = TKPProfileControlsSetSuppressionEnabled(NO);
    }

    sender.on = TKPProfileControlsSuppressionEnabled();
    self.statusLabel.text = TKPProfileControlsDiagnostic(gLastProfileControlsStatus);
}

- (void)removeOwnedOverlay {
    [self.ownedScreenView removeFromSuperview];
    self.ownedScreenView = nil;
    self.gearScreenView = nil;
    self.settingsScreenView = nil;
    self.gearButton = nil;
    self.closeButton = nil;
    self.suppressionSwitch = nil;
    self.statusLabel = nil;
}

- (void)detachProfileGestureAndOverlay {
    [self removeOwnedOverlay];
    UIView *tabBar = self.tabBarView;
    UILongPressGestureRecognizer *recognizer = self.profilePressRecognizer;
    if (tabBar != nil && recognizer != nil && recognizer.view == tabBar) {
        [tabBar removeGestureRecognizer:recognizer];
    }
    self.profilePressRecognizer = nil;
    self.tabBarView = nil;
    self.profileTabView = nil;
    self.acceptedProfilePressTarget = nil;
    self.hostWindow = nil;
    self.hostScene = nil;
}

- (void)cleanupForLifecycleTransition {
    self.lifecycleEpoch += 1;
    if (self.lifecycleEpoch == 0) {
        self.lifecycleEpoch = 1;
    }
    self.discoveryDeadline = 0.0;
    [self stopDiscovery];
    [self detachProfileGestureAndOverlay];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self cleanupForLifecycleTransition];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self cleanupForLifecycleTransition];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    uint64_t callbackEpoch = self.lifecycleEpoch;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.lifecycleEpoch == callbackEpoch &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            [self beginBoundedDiscovery];
        }
    });
}

- (void)sceneWillDeactivate:(NSNotification *)notification {
    UIScene *scene = [notification.object isKindOfClass:UIScene.class]
        ? (UIScene *)notification.object : nil;
    if (scene == nil || self.hostScene == nil || scene == self.hostScene) {
        [self cleanupForLifecycleTransition];
    }
}

- (void)sceneDidActivate:(NSNotification *)notification {
    (void)notification;
    uint64_t callbackEpoch = self.lifecycleEpoch;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.lifecycleEpoch == callbackEpoch &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            [self beginBoundedDiscovery];
        }
    });
}

- (void)sceneDidDisconnect:(NSNotification *)notification {
    UIScene *scene = [notification.object isKindOfClass:UIScene.class]
        ? (UIScene *)notification.object : nil;
    if (scene == nil || self.hostScene == nil || scene == self.hostScene) {
        [self cleanupForLifecycleTransition];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.discoveryTimer invalidate];
}

@end

static NSURL *TKPTrustedGuestImageURL(void) {
#if defined(TKP_DEVICE_PANEL_TESTING)
    NSString *testExecutablePath = NSBundle.mainBundle.executablePath;
    const char *testExecutableFilePath = testExecutablePath.fileSystemRepresentation;
    char canonicalTestExecutablePath[PATH_MAX];
    if (!TKPCanonicalPath(testExecutableFilePath, canonicalTestExecutablePath)) {
        return nil;
    }
    NSString *canonicalPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:canonicalTestExecutablePath
                                   length:strlen(canonicalTestExecutablePath)];
    return canonicalPath == nil ? nil : [NSURL fileURLWithPath:canonicalPath isDirectory:NO];
#else
    Dl_info panelImage = {0};
    if (dladdr((const void *)(uintptr_t)TKPDevicePanelStart, &panelImage) == 0 ||
        panelImage.dli_fname == NULL) {
        return nil;
    }

    char canonicalPanelPath[PATH_MAX];
    if (!TKPCanonicalPath(panelImage.dli_fname, canonicalPanelPath)) {
        return nil;
    }
    NSString *panelPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:canonicalPanelPath
                                   length:strlen(canonicalPanelPath)];
    if (panelPath == nil) {
        return nil;
    }
    NSString *frameworksPath = panelPath.stringByDeletingLastPathComponent;
    if (![panelPath.lastPathComponent isEqualToString:@"TKP.dylib"] ||
        ![frameworksPath.lastPathComponent isEqualToString:@"Frameworks"]) {
        return nil;
    }
    NSString *fixedGuestPath = [frameworksPath
        stringByAppendingPathComponent:@"MusicallyCore.framework/MusicallyCore"];
    char canonicalGuestPath[PATH_MAX];
    const char *guestFileSystemPath = fixedGuestPath.fileSystemRepresentation;
    if (!TKPCanonicalPath(guestFileSystemPath, canonicalGuestPath)) {
        return nil;
    }
    NSString *trustedPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:canonicalGuestPath
                                   length:strlen(canonicalGuestPath)];
    return trustedPath == nil ? nil : [NSURL fileURLWithPath:trustedPath isDirectory:NO];
#endif
}

void TKPDevicePanelStart(void) {
    uint64_t startEpoch = atomic_fetch_add_explicit(&gDevicePanelStartEpoch, 1,
                                                    memory_order_relaxed) + 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&gDevicePanelStartEpoch, memory_order_relaxed) != startEpoch) {
            return;
        }
        [[TKPDevicePanelController sharedController] start];
    });
}

__attribute__((constructor)) static void TKPDevicePanelConstructor(void) {
    TKPDevicePanelStart();
}
