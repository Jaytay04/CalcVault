#import <UIKit/UIKit.h>

#import <dispatch/dispatch.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>

#import "TKPProfileControls.h"

@interface TTKProfileViewsVisitor : NSObject
@property (nonatomic) NSUInteger profileGetterCalls;
@property (nonatomic) NSUInteger userGetterCalls;
- (BOOL)p_shouldReportProfileView;
- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user;
@end

@implementation TTKProfileViewsVisitor
- (BOOL)p_shouldReportProfileView {
    self.profileGetterCalls += 1;
    return YES;
}

- (BOOL)p_shouldReportHasVeiwedProfileForUser:(id)user {
    self.userGetterCalls += 1;
    return user != nil;
}
@end

@interface TTKProfileTabBaseButton : UIButton
@end
@implementation TTKProfileTabBaseButton
@end

@interface TTKProfileTabButton : TTKProfileTabBaseButton
@end
@implementation TTKProfileTabButton
@end

@interface TTKProfileFollowTabButton : TTKProfileTabBaseButton
@end
@implementation TTKProfileFollowTabButton
@end

@interface TTKHiddenProfileTabButton : TTKProfileTabBaseButton
@end
@implementation TTKHiddenProfileTabButton
@end

@interface TTKDisabledProfileTabButton : TTKProfileTabBaseButton
@end
@implementation TTKDisabledProfileTabButton
@end

@interface TKPDevicePanelController : NSObject
+ (instancetype)sharedController;
@property (nonatomic, weak, nullable, readonly) UIWindow *hostWindow;
@property (nonatomic, weak, nullable, readonly) UIView *profileTabView;
@property (nonatomic, strong, nullable, readonly) UILongPressGestureRecognizer *profilePressRecognizer;
@property (nonatomic, strong, nullable, readonly) UIView *ownedScreenView;
@property (nonatomic, strong, nullable, readonly) UIView *gearScreenView;
@property (nonatomic, strong, nullable, readonly) UIView *settingsScreenView;
@property (nonatomic, weak, nullable, readonly) UIButton *gearButton;
@property (nonatomic, weak, nullable, readonly) UIButton *closeButton;
@property (nonatomic, weak, nullable, readonly) UISwitch *suppressionSwitch;
@property (nonatomic, weak, nullable, readonly) UILabel *statusLabel;
- (BOOL)reconcileVisibleGuestTab;
- (void)showGearScreen;
- (void)applicationWillResignActive:(NSNotification * _Nullable)notification;
@end

extern void TKPDevicePanelStart(void);

static NSUInteger gFailures = 0;

static Class TKPCreateForeignImageProfileButtonClass(void) {
    Class foreignClass = objc_allocateClassPair(
        TTKProfileTabBaseButton.class, "TKPFixtureForeignImageProfileButton", 0);
    if (foreignClass != Nil) {
        objc_registerClassPair(foreignClass);
    }
    return foreignClass;
}

static void TKPCheck(BOOL condition, const char *description) {
    if (!condition) {
        gFailures += 1;
        fprintf(stderr, "FAIL: %s\n", description);
        return;
    }
    fprintf(stdout, "PASS: %s\n", description);
}

static UIView *TKPFindViewWithIdentifier(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) {
        return root;
    }
    for (UIView *child in root.subviews) {
        UIView *match = TKPFindViewWithIdentifier(child, identifier);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

static NSUInteger TKPCountViewsWithIdentifier(UIView *root, NSString *identifier) {
    NSUInteger count = [root.accessibilityIdentifier isEqualToString:identifier] ? 1 : 0;
    for (UIView *child in root.subviews) {
        count += TKPCountViewsWithIdentifier(child, identifier);
    }
    return count;
}

static BOOL TKPViewTreeContainsText(UIView *root, NSString *text) {
    if ([root isKindOfClass:[UILabel class]] &&
        [((UILabel *)root).text containsString:text]) {
        return YES;
    }
    for (UIView *child in root.subviews) {
        if (TKPViewTreeContainsText(child, text)) {
            return YES;
        }
    }
    return NO;
}

static NSUInteger TKPLongPressCount(UIView *view) {
    NSUInteger count = 0;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if ([recognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
            count += 1;
        }
    }
    return count;
}

static BOOL TKPViewCoversWindow(UIView *view, UIWindow *window) {
    CGRect frame = view.frame;
    CGRect bounds = window.bounds;
    return view.window == window &&
        CGRectGetMinX(frame) <= CGRectGetMinX(bounds) &&
        CGRectGetMinY(frame) <= CGRectGetMinY(bounds) &&
        CGRectGetMaxX(frame) >= CGRectGetMaxX(bounds) &&
        CGRectGetMaxY(frame) >= CGRectGetMaxY(bounds);
}

static void TKPCheckNoOwnedScreen(TKPDevicePanelController *controller,
                                  UIWindow *window,
                                  const char *description) {
    TKPCheck(controller.ownedScreenView == nil || controller.ownedScreenView.window == nil,
             description);
    TKPCheck(TKPCountViewsWithIdentifier(window, @"tkp.guest.profile-controls.overlay") == 0,
             "no owned profile-controls overlay remains in the guest window");
}

@interface TKPProfileSettingsFixtureRootController : UIViewController
@property (nonatomic, strong) UIView *profileContainer;
@property (nonatomic, strong) TTKProfileTabButton *primaryProfileButton;
@property (nonatomic, strong) TTKProfileFollowTabButton *ambiguousProfileButton;
@property (nonatomic, strong) TTKHiddenProfileTabButton *hiddenProfileButton;
@property (nonatomic, strong) TTKDisabledProfileTabButton *disabledProfileButton;
@property (nonatomic, strong) UIButton *sameTitleDecoyButton;
@end

@implementation TKPProfileSettingsFixtureRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    self.profileContainer = [[UIView alloc] initWithFrame:CGRectMake(0, height - 96, width, 96)];
    self.profileContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.profileContainer.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:self.profileContainer];

    self.primaryProfileButton = [[TTKProfileTabButton alloc]
        initWithFrame:CGRectMake(width - 92, 16, 80, 64)];
    self.primaryProfileButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.primaryProfileButton setTitle:@"Profile" forState:UIControlStateNormal];
    [self.profileContainer addSubview:self.primaryProfileButton];

    self.ambiguousProfileButton = [[TTKProfileFollowTabButton alloc]
        initWithFrame:CGRectMake(width - 184, 16, 80, 64)];
    self.ambiguousProfileButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.ambiguousProfileButton setTitle:@"Other" forState:UIControlStateNormal];
    [self.profileContainer addSubview:self.ambiguousProfileButton];

    self.hiddenProfileButton = [[TTKHiddenProfileTabButton alloc]
        initWithFrame:CGRectMake(width - 276, 16, 80, 64)];
    self.hiddenProfileButton.hidden = YES;
    [self.profileContainer addSubview:self.hiddenProfileButton];

    self.disabledProfileButton = [[TTKDisabledProfileTabButton alloc]
        initWithFrame:CGRectMake(width - 368, 16, 80, 64)];
    self.disabledProfileButton.userInteractionEnabled = NO;
    [self.profileContainer addSubview:self.disabledProfileButton];

    self.sameTitleDecoyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sameTitleDecoyButton.frame = CGRectMake(12, height - 80, 88, 56);
    self.sameTitleDecoyButton.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.sameTitleDecoyButton setTitle:@"Profile" forState:UIControlStateNormal];
    [self.view addSubview:self.sameTitleDecoyButton];
}
@end

@interface TKPProfileSettingsFixtureSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *unrelatedWindow;
@property (nonatomic, strong) TKPProfileSettingsFixtureRootController *rootController;
@property (nonatomic, strong) UIViewController *unrelatedRootController;
@property (nonatomic, strong) UIView *wrongImageProfileButton;
@end

static void TKPFinishFixture(void) {
    if (gFailures == 0) {
        fprintf(stdout, "PASS: synthetic profile settings UI fixture\n");
        fflush(stdout);
        exit(EXIT_SUCCESS);
    }
    fprintf(stderr, "FAIL: synthetic profile settings UI fixture (%lu failed checks)\n",
            (unsigned long)gFailures);
    fflush(stderr);
    exit(EXIT_FAILURE);
}

static void TKPRunFixtureSuite(TKPProfileSettingsFixtureSceneDelegate *sceneDelegate) {
    TKPDevicePanelController *controller = [TKPDevicePanelController sharedController];
    UIWindow *hostWindow = sceneDelegate.window;
    UIWindowScene *scene = hostWindow.windowScene;

    TKPCheck(UIApplication.sharedApplication.applicationState == UIApplicationStateActive,
             "fixture process is active before exercising the profile entry");
    TKPCheck(scene.activationState == UISceneActivationStateForegroundActive,
             "fixture scene is foreground active");
    TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:hostWindow] &&
             [scene.windows containsObject:sceneDelegate.unrelatedWindow],
             "synthetic host has two existing visible normal-level windows");
    TKPCheck(NSClassFromString(@"TTKTabBar") == Nil,
             "fixture intentionally has no TTKTabBar runtime class");
    TKPCheck(sceneDelegate.wrongImageProfileButton.window == sceneDelegate.unrelatedWindow &&
             !sceneDelegate.wrongImageProfileButton.hidden &&
             sceneDelegate.wrongImageProfileButton.userInteractionEnabled &&
             class_getImageName(object_getClass(sceneDelegate.wrongImageProfileButton)) == NULL,
             "wrong-image dynamic subclass is visible and has no canonical image");
    TKPCheck(controller.hostWindow == nil,
             "ambiguous target is not assigned to either visible window");
    TKPCheck(controller.ownedScreenView == nil &&
             TKPFindViewWithIdentifier(hostWindow, @"tkp.guest.profile-controls.gear-button") == nil &&
             TKPFindViewWithIdentifier(sceneDelegate.unrelatedWindow,
                 @"tkp.guest.profile-controls.gear-button") == nil,
             "launch shows no floating profile-settings control");

    TKPCheck(![controller reconcileVisibleGuestTab] && controller.profileTabView == nil &&
             controller.profilePressRecognizer == nil,
             "two valid profile-subclass targets fail closed as ambiguous");
    TKPCheck(TKPLongPressCount(sceneDelegate.rootController.primaryProfileButton) == 0 &&
             TKPLongPressCount(sceneDelegate.rootController.ambiguousProfileButton) == 0,
             "ambiguous subclass profile controls receive no long-press recognizer");
    TKPCheck(TKPLongPressCount(sceneDelegate.rootController.hiddenProfileButton) == 0 &&
             TKPLongPressCount(sceneDelegate.rootController.disabledProfileButton) == 0,
             "hidden and noninteractive profile subclasses receive no gesture");
    TKPCheck(TKPLongPressCount(sceneDelegate.rootController.sameTitleDecoyButton) == 0,
             "a same-title plain button is not treated as the Profile control");

    [sceneDelegate.rootController.ambiguousProfileButton removeFromSuperview];
    sceneDelegate.rootController.ambiguousProfileButton = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        TKPCheck([controller reconcileVisibleGuestTab],
                 "unique profile target resolves despite a second visible window without a target");
        TKPCheck(controller.hostWindow == hostWindow && controller.profileTabView ==
                 sceneDelegate.rootController.primaryProfileButton,
                 "unique subclass Profile control is rediscovered in its existing window");
        TKPCheck(object_getClass(sceneDelegate.rootController.primaryProfileButton) !=
                     TTKProfileTabBaseButton.class &&
                 [sceneDelegate.rootController.primaryProfileButton
                     isKindOfClass:TTKProfileTabBaseButton.class],
                 "resolved control is a concrete subclass of the verified Profile base");
        TKPCheck(controller.profilePressRecognizer != nil &&
                 [controller.profilePressRecognizer isKindOfClass:[UILongPressGestureRecognizer class]] &&
                 [sceneDelegate.rootController.primaryProfileButton.gestureRecognizers
                     containsObject:controller.profilePressRecognizer] &&
                 TKPLongPressCount(sceneDelegate.rootController.primaryProfileButton) == 1,
                 "one long-press recognizer is bound to the exact Profile button");
        TKPCheck(fabs(controller.profilePressRecognizer.minimumPressDuration - 0.78) < 0.001 &&
                 controller.profilePressRecognizer.cancelsTouchesInView &&
                 !controller.profilePressRecognizer.delaysTouchesBegan &&
                 !controller.profilePressRecognizer.delaysTouchesEnded,
                 "recognizer uses its hold duration, cancels on recognition, and adds no touch delays");
        TKPCheck(TKPLongPressCount(sceneDelegate.rootController.sameTitleDecoyButton) == 0,
                 "text-matching decoy remains unbound after discovery");
        TKPCheck(TKPLongPressCount(sceneDelegate.rootController.hiddenProfileButton) == 0 &&
                 TKPLongPressCount(sceneDelegate.rootController.disabledProfileButton) == 0 &&
                 TKPLongPressCount(sceneDelegate.wrongImageProfileButton) == 0,
                 "hidden, disabled, and wrong-image subclasses remain unbound");

        [controller showGearScreen];
        [hostWindow layoutIfNeeded];
        TKPCheck(controller.ownedScreenView != nil &&
                 TKPViewCoversWindow(controller.ownedScreenView, hostWindow),
                 "direct synthetic entry opens a full-screen owned view inside the host window");
        TKPCheck(controller.gearScreenView.window == hostWindow &&
                 [controller.gearScreenView.accessibilityIdentifier
                     isEqualToString:@"tkp.guest.profile-controls.gear-screen"],
                 "gear screen is attached to the existing guest window");
        TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:hostWindow] &&
                 [scene.windows containsObject:sceneDelegate.unrelatedWindow],
                 "opening the gear screen creates no additional UIWindow");

        UIButton *gearButton = controller.gearButton;
        TKPCheck(gearButton != nil, "gear control exists before activation");
        [gearButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        [hostWindow layoutIfNeeded];
        TKPCheck(controller.settingsScreenView.window == hostWindow &&
                 [controller.settingsScreenView.accessibilityIdentifier
                     isEqualToString:@"tkp.guest.profile-controls.settings-screen"],
                 "gear button opens settings within the same window");
        TKPCheck(controller.suppressionSwitch != nil &&
                 [controller.suppressionSwitch.accessibilityIdentifier
                     isEqualToString:@"tkp.guest.profile-controls.suppression-switch"],
                 "settings exposes the functional suppression switch");
        TKPCheck([controller.statusLabel.text containsString:@"Profile eligibility"] &&
                 TKPViewTreeContainsText(controller.settingsScreenView, @"Local only") &&
                 TKPViewTreeContainsText(controller.settingsScreenView,
                                         @"does not guarantee anonymous viewing"),
                 "settings keeps the local-only limitation visible");
        TKPCheck(TKPCountViewsWithIdentifier(hostWindow,
                     @"tkp.guest.profile-controls.close-button") == 1,
                 "settings retains exactly one close control above the screen");

        TTKProfileViewsVisitor *visitor = [[TTKProfileViewsVisitor alloc] init];
        NSObject *syntheticUser = [[NSObject alloc] init];
        TKPCheck([visitor p_shouldReportProfileView] &&
                 [visitor p_shouldReportHasVeiwedProfileForUser:syntheticUser],
                 "synthetic getters return their native behavior before opt-in");
        controller.suppressionSwitch.on = YES;
        [controller.suppressionSwitch sendActionsForControlEvents:UIControlEventValueChanged];
        TKPCheck(TKPProfileControlsSuppressionEnabled(),
                 "turning the switch on enables profile eligibility suppression");
        TKPCheck(![visitor p_shouldReportProfileView] &&
                 ![visitor p_shouldReportHasVeiwedProfileForUser:syntheticUser],
                 "enabled setting suppresses both synthetic eligibility results");

        controller.suppressionSwitch.on = NO;
        [controller.suppressionSwitch sendActionsForControlEvents:UIControlEventValueChanged];
        TKPCheck(!TKPProfileControlsSuppressionEnabled(),
                 "turning the switch off disables profile eligibility suppression");
        TKPCheck([visitor p_shouldReportProfileView] &&
                 [visitor p_shouldReportHasVeiwedProfileForUser:syntheticUser] &&
                 visitor.profileGetterCalls == 2 && visitor.userGetterCalls == 2,
                 "disabled setting forwards to both original synthetic getters");

        [controller.closeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        TKPCheckNoOwnedScreen(controller, hostWindow,
                              "close removes the fixture-owned view from the host window");
        TKPCheck(hostWindow.rootViewController == sceneDelegate.rootController &&
                 sceneDelegate.rootController.view.window == hostWindow &&
                 !sceneDelegate.rootController.view.hidden,
                 "close leaves the native guest root visible");
        TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:hostWindow] &&
                 [scene.windows containsObject:sceneDelegate.unrelatedWindow],
                 "close preserves the original window count");

        for (NSUInteger cycle = 0; cycle < 3; cycle++) {
            [controller showGearScreen];
            UIButton *cycleGearButton = controller.gearButton;
            [cycleGearButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            [controller.closeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            TKPCheckNoOwnedScreen(controller, hostWindow,
                                  "repeated open-close cycle leaves no duplicate owned view");
        }
        TKPCheck(TKPLongPressCount(sceneDelegate.rootController.primaryProfileButton) == 1,
                 "repeated screen cycles do not duplicate the profile gesture");

        [controller showGearScreen];
        TKPCheck(controller.ownedScreenView.window == hostWindow,
                 "owned settings view is present before inactive-state cleanup");
        [controller applicationWillResignActive:nil];
        TKPCheckNoOwnedScreen(controller, hostWindow,
                              "inactive cleanup immediately removes the owned settings view");

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TKPCheckNoOwnedScreen(controller, hostWindow,
                                  "activation does not asynchronously restore a private settings view");
            TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:hostWindow] &&
                     [scene.windows containsObject:sceneDelegate.unrelatedWindow] &&
                     hostWindow.rootViewController == sceneDelegate.rootController,
                     "activation leaves both native windows and the root intact");
            TKPFinishFixture();
        });
    });
}

@implementation TKPProfileSettingsFixtureSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        TKPCheck(NO, "UIKit connected a window scene");
        TKPFinishFixture();
        return;
    }

    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.rootController = [[TKPProfileSettingsFixtureRootController alloc] init];
    self.window.rootViewController = self.rootController;
    [self.window makeKeyAndVisible];

    self.unrelatedRootController = [[UIViewController alloc] init];
    self.unrelatedRootController.view.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    Class wrongImageClass = TKPCreateForeignImageProfileButtonClass();
    TKPCheck(wrongImageClass != Nil,
             "fixture can allocate a dynamic foreign-image Profile subclass");
    if (wrongImageClass != Nil) {
        UIButton *wrongImageButton = [[wrongImageClass alloc]
            initWithFrame:CGRectMake(16, 16, 120, 64)];
        [wrongImageButton setTitle:@"Profile" forState:UIControlStateNormal];
        self.wrongImageProfileButton = wrongImageButton;
        [self.unrelatedRootController.view addSubview:wrongImageButton];
    }
    self.unrelatedWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.unrelatedWindow.rootViewController = self.unrelatedRootController;
    self.unrelatedWindow.windowLevel = UIWindowLevelNormal;
    self.unrelatedWindow.hidden = NO;

    fprintf(stdout,
            "FIXTURE SCOPE: generated UIKit host and synthetic classes only; no proprietary guest, IPA, network, account, or personal data.\n");
    fflush(stdout);
    TKPDevicePanelStart();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TKPRunFixtureSuite(self);
    });
}
@end

@interface TKPProfileSettingsFixtureAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation TKPProfileSettingsFixtureAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
        initWithName:@"Default Configuration"
        sessionRole:connectingSceneSession.role];
    configuration.delegateClass = [TKPProfileSettingsFixtureSceneDelegate class];
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([TKPProfileSettingsFixtureAppDelegate class]));
    }
}
