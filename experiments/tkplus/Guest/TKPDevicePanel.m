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
static const NSTimeInterval TKPProfilePressDuration = 0.78;
static const NSUInteger TKPViewDepthLimit = 32;
static const NSUInteger TKPViewCountLimit = 4096;
static const char * const TKPProfileTabClassName = "TTKProfileTabBaseButton";
static const char * const TKPTabBarClassName = "TTKTabBar";
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
    for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview) {
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

static BOOL TKPClassIsUIViewSubclass(Class candidate) {
    for (Class current = candidate; current != Nil; current = class_getSuperclass(current)) {
        if (current == UIView.class) {
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
        !TKPClassIsUIViewSubclass(candidate)) {
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

typedef struct {
    __unsafe_unretained UIWindow *window;
    Class profileTabClass;
    Class tabBarClass;
    __unsafe_unretained NSMutableArray<UIView *> *candidates;
    NSUInteger visitedViewCount;
    BOOL boundsExceeded;
} TKPProfileTargetScan;

static void TKPScanProfileTabViews(UIView *view,
                                  UIView *nearestTabBar,
                                  NSUInteger depth,
                                  TKPProfileTargetScan *scan) {
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

    if (object_getClass(view) == scan->tabBarClass) {
        nearestTabBar = view;
    }
    if (nearestTabBar != nil && object_getClass(view) == scan->profileTabClass &&
        [view isKindOfClass:scan->profileTabClass] && view.isUserInteractionEnabled) {
        [scan->candidates addObject:view];
        if (scan->candidates.count > 1) {
            return;
        }
    }

    NSArray<UIView *> *subviews = view.subviews;
    for (UIView *subview in subviews) {
        TKPScanProfileTabViews(subview, nearestTabBar, depth + 1, scan);
        if (scan->boundsExceeded || scan->candidates.count > 1) {
            return;
        }
    }
}

static BOOL TKPWindowIsVisibleGuestCandidate(UIWindow *window, UIWindowScene *scene) {
    if (window == nil || scene == nil || window.windowScene != scene || window.hidden ||
        window.alpha <= 0.01 || window.windowLevel > UIWindowLevelNormal ||
        window.rootViewController == nil || !TKPRectHasArea(window.bounds)) {
        return NO;
    }
    UIView *rootView = window.rootViewController.viewIfLoaded;
    return rootView != nil && TKPViewHasVisibleGeometry(rootView, window);
}

static TKPProfileTargetResolution
TKPResolveUniqueProfileTab(UIView **candidateOut, UIWindow **windowOut) {
    if (candidateOut != NULL) {
        *candidateOut = nil;
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

    Class profileTabClass = NSClassFromString(
        [NSString stringWithUTF8String:TKPProfileTabClassName]);
    Class tabBarClass = NSClassFromString(
        [NSString stringWithUTF8String:TKPTabBarClassName]);
    if (!TKPClassImageMatchesTrustedGuest(profileTabClass, trustedImageURL) ||
        !TKPClassImageMatchesTrustedGuest(tabBarClass, trustedImageURL)) {
        return TKPProfileTargetResolutionUnavailable;
    }

    NSMutableArray<UIView *> *candidates = [NSMutableArray arrayWithCapacity:2];
    UIWindow *candidateWindow = nil;
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
            NSUInteger candidateCountBeforeWindow = candidates.count;
            TKPProfileTargetScan scan = {
                .window = window,
                .profileTabClass = profileTabClass,
                .tabBarClass = tabBarClass,
                .candidates = candidates,
                .visitedViewCount = visitedViewCount,
                .boundsExceeded = NO,
            };
            TKPScanProfileTabViews(rootView, nil, 0, &scan);
            visitedViewCount = scan.visitedViewCount;
            if (scan.boundsExceeded) {
                return TKPProfileTargetResolutionBoundsExceeded;
            }
            if (candidates.count > 1) {
                return TKPProfileTargetResolutionAmbiguous;
            }
            if (candidates.count == candidateCountBeforeWindow + 1) {
                candidateWindow = window;
            }
        }
    }

    if (candidates.count != 1 || candidateWindow == nil) {
        return TKPProfileTargetResolutionNotFound;
    }
    if (candidateOut != NULL) {
        *candidateOut = candidates.firstObject;
    }
    if (windowOut != NULL) {
        *windowOut = candidateWindow;
    }
    return TKPProfileTargetResolutionUnique;
}

@interface TKPDevicePanelController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong, nullable) NSTimer *discoveryTimer;
@property (nonatomic, weak, nullable) UIWindow *hostWindow;
@property (nonatomic, weak, nullable) UIWindowScene *hostScene;
@property (nonatomic, weak, nullable) UIView *profileTabView;
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

    UIView *candidate = nil;
    UIWindow *window = nil;
    TKPProfileTargetResolution resolution = TKPResolveUniqueProfileTab(&candidate, &window);
    if (resolution != TKPProfileTargetResolutionUnique || candidate == nil || window == nil) {
        [self detachProfileGestureAndOverlay];
        return NO;
    }

    if (self.profileTabView == candidate && self.hostWindow == window &&
        self.profilePressRecognizer.view == candidate) {
        self.hostScene = window.windowScene;
        return YES;
    }

    [self detachProfileGestureAndOverlay];
    self.hostWindow = window;
    self.hostScene = window.windowScene;
    self.profileTabView = candidate;

    UILongPressGestureRecognizer *recognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(profileTabLongPressed:)];
    recognizer.minimumPressDuration = TKPProfilePressDuration;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = self;
    self.profilePressRecognizer = recognizer;
    [candidate addGestureRecognizer:recognizer];
    return YES;
}

- (BOOL)hasCurrentInteractionContext {
    UIWindow *window = self.hostWindow;
    UIWindowScene *scene = self.hostScene;
    UIView *candidate = self.profileTabView;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        window == nil || scene == nil || window.windowScene != scene ||
        scene.activationState != UISceneActivationStateForegroundActive ||
        !TKPWindowIsVisibleGuestCandidate(window, scene) ||
        !TKPViewHasVisibleGeometry(candidate, window) ||
        self.profilePressRecognizer.view != candidate) {
        return NO;
    }

    UIView *resolvedCandidate = nil;
    UIWindow *resolvedWindow = nil;
    return TKPResolveUniqueProfileTab(&resolvedCandidate, &resolvedWindow) ==
            TKPProfileTargetResolutionUnique &&
        resolvedCandidate == candidate && resolvedWindow == window;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return gestureRecognizer == self.profilePressRecognizer;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.profilePressRecognizer ||
        ![self hasCurrentInteractionContext]) {
        return NO;
    }
    UIView *target = self.profileTabView;
    UIView *touchedView = touch.view;
    return touchedView != nil && target != nil &&
        (touchedView == target || [touchedView isDescendantOfView:target]) &&
        TKPViewHasVisibleGeometry(touchedView, self.hostWindow);
}

- (void)profileTabLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer != self.profilePressRecognizer ||
        recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (![self hasCurrentInteractionContext]) {
        [self detachProfileGestureAndOverlay];
        return;
    }
    [self showGearScreen];
}

- (void)showGearScreen {
    if (![self hasCurrentInteractionContext]) {
        [self detachProfileGestureAndOverlay];
        return;
    }
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
    UIView *candidate = self.profileTabView;
    UILongPressGestureRecognizer *recognizer = self.profilePressRecognizer;
    if (candidate != nil && recognizer != nil && recognizer.view == candidate) {
        [candidate removeGestureRecognizer:recognizer];
    }
    self.profilePressRecognizer = nil;
    self.profileTabView = nil;
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
