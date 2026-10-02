#import <UIKit/UIKit.h>

#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#import "TKPProfileControls.h"

__attribute__((visibility("default"))) void TKPDevicePanelStart(void);

static const NSTimeInterval TKPDiscoveryInterval = 0.25;
static const NSTimeInterval TKPDiscoveryLimit = 30.0;
static const NSTimeInterval TKPSheetDismissalFallback = 0.5;
static const NSUInteger TKPViewControllerDepthLimit = 32;
static const char * const TKPLocalOnlyCaveat =
    "Local only: this suppresses two profile-view eligibility checks in this guest. "
    "Other reporting paths may still operate. This does not guarantee anonymous viewing.";

static NSURL *TKPTrustedGuestImageURL(void);

static TKPProfileControlsStatus gLastProfileControlsStatus =
    TKPProfileControlsStatusNotInstalled;

@interface TKPPassthroughWindow : UIWindow
@property (nonatomic, weak) UIButton *controlButton;
@end

@implementation TKPPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    UIButton *button = self.controlButton;
    if (button != nil && (hitView == button || [hitView isDescendantOfView:button])) {
        return hitView;
    }
    return nil;
}

@end

static BOOL TKPViewIsVisibleInWindow(UIView *view, UIWindow *window) {
    return view != nil && view.window == window && !view.hidden && view.alpha > 0.01;
}

static BOOL TKPHasForegroundActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return YES;
        }
    }
    return NO;
}

static UIViewController *TKPVisibleController(UIViewController *controller,
                                               UIWindow *window,
                                               NSUInteger depth) {
    if (controller == nil || depth >= TKPViewControllerDepthLimit ||
        controller.isBeingDismissed) {
        return nil;
    }

    UIViewController *presented = controller.presentedViewController;
    if (presented != nil && !presented.isBeingDismissed) {
        UIViewController *visible = TKPVisibleController(presented, window, depth + 1);
        if (visible != nil) {
            return visible;
        }
    }

    for (UIViewController *child in controller.childViewControllers) {
        UIView *childView = child.viewIfLoaded;
        if (!TKPViewIsVisibleInWindow(childView, window)) {
            continue;
        }
        UIViewController *visible = TKPVisibleController(child, window, depth + 1);
        if (visible != nil) {
            return visible;
        }
    }

    return TKPViewIsVisibleInWindow(controller.viewIfLoaded, window) ? controller : nil;
}

static UIWindow *TKPFindForegroundGuestWindow(UIWindowScene **sceneOut,
                                               UIViewController **presenterOut) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) {
        return nil;
    }

    UIWindow *fallbackWindow = nil;
    UIWindowScene *fallbackScene = nil;
    UIViewController *fallbackPresenter = nil;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.hidden || window.alpha <= 0.01 ||
                window.windowLevel > UIWindowLevelNormal || window.rootViewController == nil) {
                continue;
            }

            UIViewController *presenter =
                TKPVisibleController(window.rootViewController, window, 0);
            if (presenter == nil) {
                continue;
            }
            if (window.isKeyWindow) {
                if (sceneOut != NULL) {
                    *sceneOut = windowScene;
                }
                if (presenterOut != NULL) {
                    *presenterOut = presenter;
                }
                return window;
            }
            if (fallbackWindow == nil) {
                fallbackWindow = window;
                fallbackScene = windowScene;
                fallbackPresenter = presenter;
            }
        }
    }

    if (fallbackWindow != nil) {
        if (sceneOut != NULL) {
            *sceneOut = fallbackScene;
        }
        if (presenterOut != NULL) {
            *presenterOut = fallbackPresenter;
        }
    }
    return fallbackWindow;
}

@interface TKPDevicePanelController : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) NSTimer *discoveryTimer;
@property (nonatomic, strong) TKPPassthroughWindow *panelWindow;
@property (nonatomic, weak) UIAlertController *activeSheet;
@property (nonatomic) NSTimeInterval discoveryDeadline;
@property (nonatomic) BOOL observersInstalled;
@property (nonatomic) BOOL startupRetryPending;
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
        [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(sceneWillDeactivate:)
                       name:UISceneWillDeactivateNotification object:nil];
        [center addObserver:self selector:@selector(sceneDidDisconnect:)
                       name:UISceneDidDisconnectNotification object:nil];
        self.observersInstalled = YES;
    }
    [self beginBoundedDiscovery];
}

- (void)beginBoundedDiscovery {
    if (![NSThread isMainThread] || self.discoveryTimer != nil) {
        return;
    }

    UIWindowScene *panelScene = self.panelWindow.windowScene;
    if (self.panelWindow != nil && panelScene != nil &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        panelScene.activationState == UISceneActivationStateForegroundActive) {
        self.panelWindow.hidden = NO;
        return;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.discoveryDeadline <= now) {
        self.discoveryDeadline = now + TKPDiscoveryLimit;
    }
    [self startDiscoveryTimerBeforeDeadline];
}

- (void)startDiscoveryTimerBeforeDeadline {
    if (self.discoveryTimer != nil ||
        NSProcessInfo.processInfo.systemUptime >= self.discoveryDeadline) {
        return;
    }
    NSTimer *timer = [NSTimer timerWithTimeInterval:TKPDiscoveryInterval
                                            target:self
                                          selector:@selector(discoveryTick:)
                                          userInfo:nil
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
    if (timer != self.discoveryTimer) {
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.discoveryDeadline) {
        [self stopDiscovery];
        return;
    }

    UIWindowScene *scene = nil;
    UIViewController *presenter = nil;
    UIWindow *hostWindow = TKPFindForegroundGuestWindow(&scene, &presenter);
    if (hostWindow == nil || scene == nil || presenter == nil) {
        return;
    }

    if (self.panelWindow != nil) {
        if (self.panelWindow.windowScene == scene) {
            self.panelWindow.hidden = NO;
        }
        [self stopDiscovery];
        return;
    }

    if ([self createPanelInScene:scene]) {
        [self stopDiscovery];
    }
}

- (BOOL)createPanelInScene:(UIWindowScene *)scene {
    CGRect sceneBounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(sceneBounds)) {
        return NO;
    }

    TKPPassthroughWindow *window = [[TKPPassthroughWindow alloc] initWithWindowScene:scene];
    window.frame = sceneBounds;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.windowLevel = UIWindowLevelNormal + 1.0;

    UIViewController *rootController = [[UIViewController alloc] init];
    rootController.view.backgroundColor = UIColor.clearColor;
    rootController.view.opaque = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"TK+" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    button.layer.cornerRadius = 22.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    button.accessibilityLabel = @"TK+ controls";
    button.accessibilityHint = @"Open local profile-view suppression controls.";
    [button addTarget:self action:@selector(controlButtonTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    button.translatesAutoresizingMaskIntoConstraints = NO;
    [rootController.view addSubview:button];
    UILayoutGuide *safeArea = rootController.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:52.0],
        [button.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        [button.widthAnchor constraintEqualToConstant:48.0],
        [button.heightAnchor constraintEqualToConstant:44.0],
    ]];

    window.rootViewController = rootController;
    window.controlButton = button;
    self.panelWindow = window;
    window.hidden = NO;
    return YES;
}

- (void)controlButtonTapped:(UIButton *)sender {
    (void)sender;
    if (self.panelWindow == nil ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        self.panelWindow.windowScene.activationState != UISceneActivationStateForegroundActive) {
        self.panelWindow.hidden = YES;
        return;
    }

    UIViewController *presenter = nil;
    UIWindow *hostWindow = TKPFindForegroundGuestWindow(NULL, &presenter);
    if (hostWindow == nil || presenter == nil || !presenter.isViewLoaded ||
        presenter.viewIfLoaded.window != hostWindow) {
        return;
    }

    self.panelWindow.hidden = YES;
    NSString *diagnostic = TKPProfileControlsDiagnostic(gLastProfileControlsStatus);
    NSString *message = [NSString stringWithFormat:@"%@\n\n%s", diagnostic,
                         TKPLocalOnlyCaveat];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"TK+ Profile Controls"
                         message:message
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak __typeof__(self) weakSelf = self;
    __weak UIAlertController *weakSheet = sheet;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Enable local suppression"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf enableProfileSuppression];
        [weakSelf restorePanelAfterSheet:weakSheet];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Disable local suppression"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        gLastProfileControlsStatus = TKPProfileControlsSetSuppressionEnabled(NO);
        [weakSelf restorePanelAfterSheet:weakSheet];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf restorePanelAfterSheet:weakSheet];
    }]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = presenter.viewIfLoaded;
        popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.viewIfLoaded.bounds),
                                        CGRectGetMidY(presenter.viewIfLoaded.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    self.activeSheet = sheet;
    sheet.presentationController.delegate = self;
    [presenter presentViewController:sheet animated:YES completion:^{
        sheet.presentationController.delegate = weakSelf;
    }];
}

- (void)enableProfileSuppression {
    NSURL *trustedImageURL = TKPTrustedGuestImageURL();
    if (trustedImageURL == nil) {
        gLastProfileControlsStatus = TKPProfileControlsStatusInvalidImageURL;
        return;
    }

    TKPProfileControlsStatus status = TKPProfileControlsInstall(trustedImageURL);
    if (status == TKPProfileControlsStatusInstalled ||
        status == TKPProfileControlsStatusAlreadyInstalled) {
        status = TKPProfileControlsSetSuppressionEnabled(YES);
    }
    gLastProfileControlsStatus = status;
}

- (void)restorePanelAfterSheet:(UIAlertController *)sheet {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(TKPSheetDismissalFallback * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.activeSheet == sheet) {
            self.activeSheet = nil;
        }
        [self showPanelIfForeground];
    });
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController == self.activeSheet) {
        self.activeSheet = nil;
        [self showPanelIfForeground];
    }
}

- (void)showPanelIfForeground {
    UIWindowScene *scene = self.panelWindow.windowScene;
    if (self.panelWindow != nil && scene != nil &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        scene.activationState == UISceneActivationStateForegroundActive) {
        self.panelWindow.hidden = NO;
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    BOOL canRetryStartup = self.panelWindow == nil &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        TKPHasForegroundActiveScene() &&
        NSProcessInfo.processInfo.systemUptime < self.discoveryDeadline;
    [self stopDiscovery];
    self.panelWindow.hidden = YES;
    UIAlertController *sheet = self.activeSheet;
    if (sheet.presentingViewController != nil) {
        [sheet dismissViewControllerAnimated:NO completion:nil];
    }
    self.activeSheet = nil;
    if (canRetryStartup) {
        [self scheduleBoundedStartupRetry];
    }
}

- (void)scheduleBoundedStartupRetry {
    if (self.startupRetryPending || self.discoveryDeadline <= 0.0) {
        return;
    }
    self.startupRetryPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.startupRetryPending = NO;
        if (self.panelWindow != nil ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !TKPHasForegroundActiveScene() ||
            NSProcessInfo.processInfo.systemUptime >= self.discoveryDeadline) {
            return;
        }
        [self startDiscoveryTimerBeforeDeadline];
    });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
            self.panelWindow != nil && self.panelWindow.windowScene.activationState ==
            UISceneActivationStateForegroundActive) {
            self.panelWindow.hidden = NO;
        } else {
            [self beginBoundedDiscovery];
        }
    });
}

- (void)sceneWillDeactivate:(NSNotification *)notification {
    if (self.panelWindow != nil && notification.object == self.panelWindow.windowScene) {
        [self applicationWillResignActive:notification];
    }
}

- (void)sceneDidDisconnect:(NSNotification *)notification {
    if (self.panelWindow != nil && notification.object == self.panelWindow.windowScene) {
        [self stopDiscovery];
        self.panelWindow.hidden = YES;
        self.panelWindow = nil;
        [self beginBoundedDiscovery];
    }
}

@end

static NSURL *TKPTrustedGuestImageURL(void) {
    Dl_info panelImage = {0};
    if (dladdr((const void *)(uintptr_t)TKPDevicePanelStart, &panelImage) == 0 ||
        panelImage.dli_fname == NULL) {
        return nil;
    }

    char canonicalPanelPath[PATH_MAX];
    if (realpath(panelImage.dli_fname, canonicalPanelPath) == NULL) {
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
    if (guestFileSystemPath == NULL || realpath(guestFileSystemPath, canonicalGuestPath) == NULL) {
        return nil;
    }

    NSString *trustedPath = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:canonicalGuestPath
                                   length:strlen(canonicalGuestPath)];
    if (trustedPath == nil) {
        return nil;
    }
    return [NSURL fileURLWithPath:trustedPath isDirectory:NO];
}

void TKPDevicePanelStart(void) {
    if ([NSThread isMainThread]) {
        [[TKPDevicePanelController sharedController] start];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TKPDevicePanelController sharedController] start];
        });
    }
}

__attribute__((constructor)) static void TKPDevicePanelConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TKPDevicePanelStart();
    });
}
