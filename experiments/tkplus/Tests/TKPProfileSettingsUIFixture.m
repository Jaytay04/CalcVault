#import <UIKit/UIKit.h>

#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <limits.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>

#import "TKPProfileControls.h"

extern uint32_t TKPTestClassImageStatus(Class candidate, NSURL *trustedImageURL);
extern uint32_t TKPTestClassImagePathStatus(const char *imagePath, NSURL *trustedImageURL);
extern uint32_t TKPTestTabBarClassChainStatus(Class actualClass,
                                               Class tabBarBaseClass,
                                               NSURL *trustedImageURL,
                                               uint32_t *failureStatusOut,
                                               uint32_t *failureDepthOut);

typedef NS_ENUM(uint32_t, TKPFixtureClassImageStatus) {
    TKPFixtureClassImageStatusNotEvaluated = 0,
    TKPFixtureClassImageStatusClassAbsent = 1,
    TKPFixtureClassImageStatusMetaClass = 2,
    TKPFixtureClassImageStatusExpectedImageMissing = 3,
    TKPFixtureClassImageStatusNotUIView = 4,
    TKPFixtureClassImageStatusClassImageMissing = 5,
    TKPFixtureClassImageStatusClassImageCanonicalizationFailed = 6,
    TKPFixtureClassImageStatusExpectedImageCanonicalizationFailed = 7,
    TKPFixtureClassImageStatusImageMismatch = 8,
    TKPFixtureClassImageStatusExactImageMatch = 9,
};

static NSMutableArray<NSString *> *gEntryDiagnosticLines = nil;

// The fixture owns this stand-in; it never writes files or calls the host.
@interface CVLPProbe : NSObject
+ (void)recordGuestDiagnostic:(NSString *)line;
@end
@implementation CVLPProbe
+ (void)recordGuestDiagnostic:(NSString *)line {
    if (gEntryDiagnosticLines == nil) {
        gEntryDiagnosticLines = [NSMutableArray array];
    }
    [gEntryDiagnosticLines addObject:[line copy]];
}
@end

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

@interface TTKVideoPlayerView : UIView
@end
@implementation TTKVideoPlayerView
@end

@interface TTKTabBar : UIView
@property (nonatomic, copy) NSArray<UIView *> *buttons;
@end
@implementation TTKTabBar
@end

static char gTKPFixtureKVOContextStorage;
static void *TKPFixtureKVOContext = &gTKPFixtureKVOContextStorage;
static NSUInteger gKVOClassReporterSpoofCalls = 0;

@interface TKPFixtureKVOObserver : NSObject
@end
@implementation TKPFixtureKVOObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)object;
    (void)change;
    if (context == TKPFixtureKVOContext && [keyPath isEqualToString:@"buttons"]) {
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
@end

static Class TKPFixtureSpoofedKVOClassReporter(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    gKVOClassReporterSpoofCalls += 1;
    return NSObject.class;
}

@interface TKPDevicePanelController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedController;
@property (nonatomic, strong, nullable, readonly) NSTimer *discoveryTimer;
@property (nonatomic, weak, nullable, readonly) UIWindow *hostWindow;
@property (nonatomic, weak, nullable, readonly) UIView *tabBarView;
@property (nonatomic, weak, nullable, readonly) UIView *profileTabView;
@property (nonatomic, strong, nullable) UILongPressGestureRecognizer *profilePressRecognizer;
@property (nonatomic, strong, nullable, readonly) UIView *ownedScreenView;
@property (nonatomic, strong, nullable, readonly) UIView *gearScreenView;
@property (nonatomic, strong, nullable, readonly) UIView *settingsScreenView;
@property (nonatomic, weak, nullable, readonly) UIButton *gearButton;
@property (nonatomic, weak, nullable, readonly) UIButton *closeButton;
@property (nonatomic, weak, nullable, readonly) UISwitch *suppressionSwitch;
@property (nonatomic, weak, nullable, readonly) UILabel *statusLabel;
@property (nonatomic, readonly) uint64_t lifecycleEpoch;
- (BOOL)reconcileVisibleGuestTab;
- (void)discoveryTick:(NSTimer *)timer;
- (void)showGearScreen;
- (void)profileTabLongPressed:(UILongPressGestureRecognizer *)recognizer;
- (void)applicationWillResignActive:(NSNotification * _Nullable)notification;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch;
@end

extern void TKPDevicePanelStart(void);

static NSUInteger gFailures = 0;

static void TKPCheckEntryDiagnostics(void);

static void TKPCheck(BOOL condition, const char *description) {
    if (!condition) {
        gFailures += 1;
        fprintf(stderr, "FAIL: %s\n", description);
        return;
    }
    fprintf(stdout, "PASS: %s\n", description);
}

static void TKPCheckEntryDiagnostics(void) {
    TKPCheck(gEntryDiagnosticLines.count > 0 && gEntryDiagnosticLines.count <= 24,
             "entry diagnostics reach the fixture sink within the 24-record limit");
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-=.,:;[]|"];
    BOOL sanitized = YES;
    for (NSString *line in gEntryDiagnosticLines) {
        if (![line hasPrefix:@"CVLP_GUEST_GEOMETRY phase=tkp-entry version=7 "] ||
            line.length >= 320 ||
            [line rangeOfString:@" cls_status="].location == NSNotFound ||
            [line rangeOfString:@" cs="].location == NSNotFound ||
            [line rangeOfString:@" cd="].location == NSNotFound ||
            [line rangeOfString:@" wf="].location == NSNotFound ||
            [line rangeOfString:@"NSKVONotifying"].location != NSNotFound ||
            [line rangeOfString:@"/System/Library"].location != NSNotFound ||
            [line rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
            sanitized = NO;
        }
    }
    TKPCheck(sanitized, "entry diagnostics contain only the fixed marker and sanitized status fields");
}

static void TKPCheckClassImageStatusClassifier(void) {
    NSURL *mainExecutableURL = [NSURL fileURLWithPath:NSBundle.mainBundle.executablePath];
    NSString *temporaryDirectory = NSTemporaryDirectory();
    NSString *missingName = [NSString stringWithFormat:
        @"TKP-missing-image-%@", [[NSUUID UUID] UUIDString]];
    NSString *missingImagePath = [temporaryDirectory stringByAppendingPathComponent:missingName];
    NSURL *missingImageURL = [NSURL fileURLWithPath:missingImagePath];

    TKPCheck(TKPTestClassImageStatus(Nil, mainExecutableURL) ==
                 TKPFixtureClassImageStatusClassAbsent,
             "class image classifier distinguishes an absent class");
    TKPCheck(TKPTestClassImageStatus(object_getClass(TTKTabBar.class), mainExecutableURL) ==
                 TKPFixtureClassImageStatusMetaClass,
             "class image classifier rejects a metaclass before image lookup");
    TKPCheck(TKPTestClassImageStatus(TTKTabBar.class, nil) ==
                 TKPFixtureClassImageStatusExpectedImageMissing,
             "class image classifier distinguishes a missing expected image URL");
    TKPCheck(TKPTestClassImageStatus(NSObject.class, mainExecutableURL) ==
                 TKPFixtureClassImageStatusNotUIView,
             "class image classifier rejects a non-UIView class");

    Class dynamicUIViewClass = NSClassFromString(@"TKPFixtureForeignImageTabBar");
    TKPCheck(dynamicUIViewClass != Nil &&
             class_getImageName(dynamicUIViewClass) == NULL &&
             TKPTestClassImageStatus(dynamicUIViewClass, mainExecutableURL) ==
                 TKPFixtureClassImageStatusClassImageMissing,
             "class image classifier reports a runtime UIView class without an image name");

    TKPCheck(![[NSFileManager defaultManager] fileExistsAtPath:missingImagePath] &&
             TKPTestClassImageStatus(TTKTabBar.class, missingImageURL) ==
                 TKPFixtureClassImageStatusExpectedImageCanonicalizationFailed,
             "class image classifier distinguishes an expected image path that cannot be canonicalized");
    TKPCheck(TKPTestClassImagePathStatus(missingImagePath.fileSystemRepresentation,
                                         mainExecutableURL) ==
                 TKPFixtureClassImageStatusClassImageCanonicalizationFailed,
             "class image classifier distinguishes an actual image path that cannot be canonicalized");
    TKPCheck(TKPTestClassImageStatus(TTKTabBar.class, mainExecutableURL) ==
                 TKPFixtureClassImageStatusExactImageMatch,
             "class image classifier accepts the exact canonical fixture executable image");

    NSURL *existingDifferentImageURL = [NSBundle.mainBundle.bundleURL
        URLByAppendingPathComponent:@"Info.plist" isDirectory:NO];
    TKPCheck([[NSFileManager defaultManager]
                 fileExistsAtPath:existingDifferentImageURL.path] &&
             TKPTestClassImageStatus(TTKTabBar.class, existingDifferentImageURL) ==
                 TKPFixtureClassImageStatusImageMismatch,
             "class image classifier rejects a different existing canonical image path");

    uint32_t chainFailureStatus = UINT32_MAX;
    uint32_t chainFailureDepth = UINT32_MAX;
    TKPCheck(TKPTestTabBarClassChainStatus(TTKTabBar.class, TTKTabBar.class,
                 mainExecutableURL, &chainFailureStatus, &chainFailureDepth) == 1 &&
             chainFailureStatus == TKPFixtureClassImageStatusNotEvaluated &&
             chainFailureDepth == 0,
             "the trusted static tab-bar base remains accepted with no chain failure");

    Class inheritedGetterClass = objc_allocateClassPair(TTKTabBar.class,
        "TKPFixtureDynamicInheritedGetterTabBar", 0);
    if (inheritedGetterClass != Nil) {
        objc_registerClassPair(inheritedGetterClass);
    }
    unsigned int inheritedGetterMethodCount = 0;
    Method *inheritedGetterMethods = inheritedGetterClass == Nil ? NULL
        : class_copyMethodList(inheritedGetterClass, &inheritedGetterMethodCount);
    BOOL ownsButtonsGetter = NO;
    for (unsigned int index = 0; index < inheritedGetterMethodCount; index += 1) {
        if (method_getName(inheritedGetterMethods[index]) == @selector(buttons)) {
            ownsButtonsGetter = YES;
            break;
        }
    }
    free(inheritedGetterMethods);
    chainFailureStatus = UINT32_MAX;
    chainFailureDepth = UINT32_MAX;
    TKPCheck(inheritedGetterClass != Nil &&
             class_getImageName(inheritedGetterClass) == NULL && !ownsButtonsGetter &&
             TKPTestClassImageStatus(inheritedGetterClass, mainExecutableURL) ==
                 TKPFixtureClassImageStatusClassImageMissing &&
             TKPTestTabBarClassChainStatus(inheritedGetterClass, TTKTabBar.class,
                 mainExecutableURL, &chainFailureStatus, &chainFailureDepth) == 0 &&
             chainFailureStatus == TKPFixtureClassImageStatusClassImageMissing &&
             chainFailureDepth == 0,
             "a runtime subclass with only the inherited buttons getter fails at chain depth zero");
}

static NSArray<UIView *> *gForeignBarButtons = nil;

static id TKPForeignBarButtonsGetter(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return gForeignBarButtons;
}

static Class TKPCreateForeignImageTabBarClass(void) {
    Class foreignClass = objc_allocateClassPair(TTKTabBar.class,
        "TKPFixtureForeignImageTabBar", 0);
    if (foreignClass == Nil) {
        return Nil;
    }
    if (!class_addMethod(foreignClass, @selector(buttons),
                         (IMP)TKPForeignBarButtonsGetter, "@@:")) {
        objc_disposeClassPair(foreignClass);
        return Nil;
    }
    objc_registerClassPair(foreignClass);
    return foreignClass;
}

static BOOL TKPPathMatchesMainExecutable(const char *path) {
    const char *mainPath = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    char canonicalCandidate[PATH_MAX];
    char canonicalMain[PATH_MAX];
    return path != NULL && mainPath != NULL &&
        realpath(path, canonicalCandidate) != NULL &&
        realpath(mainPath, canonicalMain) != NULL &&
        strcmp(canonicalCandidate, canonicalMain) == 0;
}

static BOOL TKPTabBarGetterHasExpectedContract(void) {
    Class barClass = TTKTabBar.class;
    SEL selector = @selector(buttons);
    Method ownGetter = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(barClass, &count);
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            ownGetter = methods[index];
            break;
        }
    }
    free(methods);
    if (ownGetter == NULL || method_getNumberOfArguments(ownGetter) != 2) {
        return NO;
    }

    char *returnType = method_copyReturnType(ownGetter);
    char *receiverType = method_copyArgumentType(ownGetter, 0);
    char *selectorType = method_copyArgumentType(ownGetter, 1);
    BOOL valid = returnType != NULL && receiverType != NULL && selectorType != NULL &&
        strcmp(returnType, @encode(id)) == 0 &&
        strcmp(receiverType, @encode(id)) == 0 &&
        strcmp(selectorType, @encode(SEL)) == 0 &&
        TKPPathMatchesMainExecutable(class_getImageName(barClass));

    Dl_info imageInfo = {0};
    IMP implementation = method_getImplementation(ownGetter);
    valid = valid && dladdr((const void *)(uintptr_t)implementation, &imageInfo) != 0 &&
        TKPPathMatchesMainExecutable(imageInfo.dli_fname);
    free(returnType);
    free(receiverType);
    free(selectorType);
    return valid;
}

static BOOL TKPForeignTabBarGetterHasFixtureImplementation(TTKTabBar *bar) {
    if (bar == nil) {
        return NO;
    }
    Class barClass = object_getClass(bar);
    SEL selector = @selector(buttons);
    Method ownGetter = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(barClass, &count);
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            ownGetter = methods[index];
            break;
        }
    }
    free(methods);
    if (ownGetter == NULL || method_getNumberOfArguments(ownGetter) != 2) {
        return NO;
    }
    char *returnType = method_copyReturnType(ownGetter);
    char *receiverType = method_copyArgumentType(ownGetter, 0);
    char *selectorType = method_copyArgumentType(ownGetter, 1);
    Dl_info imageInfo = {0};
    IMP implementation = method_getImplementation(ownGetter);
    BOOL valid = returnType != NULL && receiverType != NULL && selectorType != NULL &&
        strcmp(returnType, @encode(id)) == 0 &&
        strcmp(receiverType, @encode(id)) == 0 &&
        strcmp(selectorType, @encode(SEL)) == 0 &&
        dladdr((const void *)(uintptr_t)implementation, &imageInfo) != 0 &&
        TKPPathMatchesMainExecutable(imageInfo.dli_fname);
    free(returnType);
    free(receiverType);
    free(selectorType);
    return valid;
}

static BOOL TKPFixtureViewIsVisible(UIView *view, UIWindow *window);

static BOOL TKPButtonsAreVisibleChildren(NSArray<UIView *> *buttons,
                                         TTKTabBar *bar,
                                         UIWindow *window) {
    if (buttons.count != 5) {
        return NO;
    }
    for (UIView *button in buttons) {
        if (button.superview != bar || !TKPFixtureViewIsVisible(button, window)) {
            return NO;
        }
    }
    return YES;
}

static BOOL TKPFixtureViewIsVisible(UIView *view, UIWindow *window) {
    if (view == nil || window == nil || view.window != window || window.hidden ||
        window.alpha <= 0.01 || CGRectIsEmpty(view.bounds) || CGRectIsEmpty(window.bounds)) {
        return NO;
    }
    BOOL reachedWindow = NO;
    for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) {
            return NO;
        }
        if (ancestor == window) {
            reachedWindow = YES;
            break;
        }
    }
    CGRect visibleRect = [view convertRect:view.bounds toView:window];
    return reachedWindow && CGRectIntersectsRect(visibleRect, window.bounds);
}

static NSArray<UIView *> *TKPCreateButtonsForBar(TTKTabBar *bar,
                                                   UIView **targetDescendantOut) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray arrayWithCapacity:5];
    CGFloat itemWidth = CGRectGetWidth(bar.bounds) / 5.0;
    for (NSUInteger index = 0; index < 5; index++) {
        UIButton *button = [[UIButton alloc] initWithFrame:CGRectZero];
        button.frame = CGRectMake((CGFloat)index * itemWidth, 4.0,
                                  itemWidth, CGRectGetHeight(bar.bounds) - 8.0);
        [button setTitle:[NSString stringWithFormat:@"Tab %lu", (unsigned long)index]
                forState:UIControlStateNormal];
        [bar addSubview:button];
        [buttons addObject:button];
        if (index == 4) {
            [button setTitle:@"Profile" forState:UIControlStateNormal];
            UIView *descendant = [[UIView alloc] initWithFrame:CGRectMake(4.0, 4.0, 12.0, 12.0)];
            [button addSubview:descendant];
            if (targetDescendantOut != NULL) {
                *targetDescendantOut = descendant;
            }
        }
    }
    return [buttons copy];
}

static TTKTabBar *TKPCreateForeignImageTabBar(CGRect frame,
                                               NSArray<UIView *> **buttonsOut) {
    Class foreignClass = TKPCreateForeignImageTabBarClass();
    if (foreignClass == Nil) {
        return nil;
    }
    TTKTabBar *bar = [[foreignClass alloc] initWithFrame:frame];
    bar.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    gForeignBarButtons = TKPCreateButtonsForBar(bar, NULL);
    if (buttonsOut != NULL) {
        *buttonsOut = gForeignBarButtons;
    }
    return bar;
}

@interface TKPSyntheticTouch : NSObject
@property (nonatomic, weak) UIView *view;
@end
@implementation TKPSyntheticTouch
@end

@interface TKPSyntheticLongPressRecognizer : UILongPressGestureRecognizer
@property (nonatomic) UIGestureRecognizerState fixtureState;
@end
@implementation TKPSyntheticLongPressRecognizer
- (UIGestureRecognizerState)state {
    return self.fixtureState;
}
@end

static BOOL TKPDelegateAllowsView(TKPDevicePanelController *controller, UIView *view) {
    if (controller.profilePressRecognizer == nil) {
        return NO;
    }
    TKPSyntheticTouch *touch = [[TKPSyntheticTouch alloc] init];
    touch.view = view;
    return [controller gestureRecognizer:controller.profilePressRecognizer
                        shouldReceiveTouch:(UITouch *)(id)touch];
}

static NSUInteger TKPLongPressCount(UIView *view);

static void TKPAssertNoGestureBinding(TKPDevicePanelController *controller,
                                      TTKTabBar *bar,
                                      const char *description) {
    BOOL unresolved = ![controller reconcileVisibleGuestTab];
    TKPCheck(unresolved && controller.hostWindow == nil && controller.tabBarView == nil &&
             controller.profileTabView == nil && controller.profilePressRecognizer == nil &&
             TKPLongPressCount(bar) == 0,
             description);
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
@property (nonatomic, strong) TTKTabBar *tabBar;
@property (nonatomic, copy) NSArray<UIView *> *buttons;
@property (nonatomic, strong) UIView *targetDescendant;
@property (nonatomic, strong) TTKProfileTabBaseButton *innerProfileDecoy;
@property (nonatomic, strong) UIButton *externalCandidate;
@end

@implementation TKPProfileSettingsFixtureRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGRect barFrame = CGRectMake(0.0, height - 88.0, width, 72.0);
    self.tabBar = [[TTKTabBar alloc] initWithFrame:barFrame];
    self.tabBar.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleTopMargin;
    self.tabBar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:self.tabBar];
    UIView *targetDescendant = nil;
    self.buttons = TKPCreateButtonsForBar(self.tabBar, &targetDescendant);
    self.targetDescendant = targetDescendant;
    self.tabBar.buttons = self.buttons;

    TTKVideoPlayerView *videoContainer = [[TTKVideoPlayerView alloc]
        initWithFrame:CGRectMake(8.0, 8.0, 80.0, 48.0)];
    videoContainer.backgroundColor = UIColor.systemGrayColor;
    [self.tabBar addSubview:videoContainer];
    self.innerProfileDecoy = [[TTKProfileTabBaseButton alloc]
        initWithFrame:CGRectMake(2.0, 2.0, 72.0, 40.0)];
    [self.innerProfileDecoy setTitle:@"Profile" forState:UIControlStateNormal];
    [videoContainer addSubview:self.innerProfileDecoy];

    self.externalCandidate = [[UIButton alloc]
        initWithFrame:CGRectMake(16.0, height - 164.0, 100.0, 48.0)];
    [self.externalCandidate setTitle:@"External candidate" forState:UIControlStateNormal];
    [self.view addSubview:self.externalCandidate];

}
@end

@interface TKPProfileSettingsFixtureSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *unrelatedWindow;
@property (nonatomic, strong) TKPProfileSettingsFixtureRootController *rootController;
@property (nonatomic, strong) TKPProfileSettingsFixtureRootController *unrelatedRootController;
@property (nonatomic, strong) TTKTabBar *foreignImageTabBar;
@end

static void TKPFinishFixture(void) {
    int exitStatus = gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    if (gFailures == 0) {
        fprintf(stdout, "PASS: synthetic profile settings UI fixture\n");
    } else {
        fprintf(stderr, "FAIL: synthetic profile settings UI fixture (%lu failed checks)\n",
                (unsigned long)gFailures);
    }
    fflush(stdout);
    fflush(stderr);
    // Let simctl's console relay drain before this synthetic process exits.
    // Both success and failure retain their actual assertion-derived status.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(exitStatus);
    });
}

static void TKPRunFixtureSuite(TKPProfileSettingsFixtureSceneDelegate *sceneDelegate) {
    TKPCheckClassImageStatusClassifier();

    TKPDevicePanelController *controller = [TKPDevicePanelController sharedController];
    UIWindow *firstWindow = sceneDelegate.window;
    UIWindow *selectedWindow = sceneDelegate.unrelatedWindow;
    UIWindowScene *scene = firstWindow.windowScene;
    TKPProfileSettingsFixtureRootController *firstRoot = sceneDelegate.rootController;
    TKPProfileSettingsFixtureRootController *selectedRoot = sceneDelegate.unrelatedRootController;
    TTKTabBar *firstBar = firstRoot.tabBar;
    TTKTabBar *selectedBar = selectedRoot.tabBar;
    NSArray<UIView *> *firstButtons = firstRoot.buttons;
    NSArray<UIView *> *originalButtons = selectedRoot.buttons;
    TKPFixtureKVOObserver *kvoObserver = [[TKPFixtureKVOObserver alloc] init];
    BOOL kvoObservationInstalled = NO;
    @try {
        [selectedBar addObserver:kvoObserver forKeyPath:@"buttons"
                         options:NSKeyValueObservingOptionNew
                         context:TKPFixtureKVOContext];
        kvoObservationInstalled = YES;
    } @catch (NSException *exception) {
        (void)exception;
    }
    Class observedKVOClass = object_getClass(selectedBar);
    const char *observedKVOClassName = class_getName(observedKVOClass);
    TKPCheck(kvoObservationInstalled && observedKVOClass != Nil &&
             observedKVOClassName != NULL &&
             strcmp(observedKVOClassName, "NSKVONotifying_TTKTabBar") == 0 &&
             class_getImageName(observedKVOClass) == NULL &&
             class_getSuperclass(observedKVOClass) == TTKTabBar.class,
             "a real Foundation observer creates the exact image-less KVO tab-bar wrapper");
    NSTimer *staleDiscoveryTimer = controller.discoveryTimer;
    uint64_t staleDiscoveryEpoch = [staleDiscoveryTimer.userInfo unsignedLongLongValue];

    TKPCheck(UIApplication.sharedApplication.applicationState == UIApplicationStateActive,
             "fixture process is active before exercising the profile entry");
    TKPCheck(scene.activationState == UISceneActivationStateForegroundActive,
             "fixture scene is foreground active");
    TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:firstWindow] &&
             [scene.windows containsObject:selectedWindow] && !firstWindow.hidden &&
             !selectedWindow.hidden,
             "synthetic host has two existing visible normal-level windows");
    TKPCheck(NSClassFromString(@"TTKTabBar") == TTKTabBar.class &&
             TKPTabBarGetterHasExpectedContract(),
             "synthetic TTKTabBar and its own buttons getter have the expected trusted-image ABI");
    TKPCheck(firstBar.window == firstWindow && selectedBar.window == selectedWindow &&
             TKPButtonsAreVisibleChildren(firstButtons, firstBar, firstWindow) &&
             TKPButtonsAreVisibleChildren(originalButtons, selectedBar, selectedWindow),
             "both visible windows contain five visible child buttons in each synthetic tab bar");
    TKPCheck([originalButtons[4] isKindOfClass:UIButton.class] &&
             ![originalButtons[4] isKindOfClass:TTKProfileTabBaseButton.class] &&
             originalButtons[4].window == selectedWindow &&
             TKPFixtureViewIsVisible(originalButtons[4], selectedWindow),
             "index 4 is a visible plain button rather than a Profile subclass");
    TKPCheck(sceneDelegate.foreignImageTabBar.window == selectedWindow &&
             sceneDelegate.foreignImageTabBar.buttons.count == 5 &&
             TKPButtonsAreVisibleChildren(sceneDelegate.foreignImageTabBar.buttons,
                 sceneDelegate.foreignImageTabBar, selectedWindow) &&
             TKPForeignTabBarGetterHasFixtureImplementation(sceneDelegate.foreignImageTabBar) &&
             class_getImageName(object_getClass(sceneDelegate.foreignImageTabBar)) == NULL,
             "foreign dynamic bar has a valid local getter and visible items but no canonical class image");
    TKPCheck(controller.hostWindow == nil && controller.ownedScreenView == nil &&
             TKPFindViewWithIdentifier(firstWindow,
                 @"tkp.guest.profile-controls.gear-button") == nil &&
             TKPFindViewWithIdentifier(selectedWindow,
                 @"tkp.guest.profile-controls.gear-button") == nil,
             "launch shows no floating profile-settings control");

    NSUInteger kvoDiagnosticStart = gEntryDiagnosticLines.count;
    BOOL kvoAmbiguousResolution = ![controller reconcileVisibleGuestTab];
    BOOL kvoAdmissionReported = NO;
    for (NSUInteger index = kvoDiagnosticStart;
         index < gEntryDiagnosticLines.count; index += 1) {
        if ([gEntryDiagnosticLines[index] rangeOfString:@" wf=511"].location !=
            NSNotFound) {
            kvoAdmissionReported = YES;
            break;
        }
    }
    TKPCheck(kvoAmbiguousResolution && kvoAdmissionReported,
             "the genuine KVO wrapper passes every bounded compatibility gate and reports wf 511");
    TKPCheck(controller.hostWindow == nil &&
             controller.tabBarView == nil && controller.profileTabView == nil &&
             controller.profilePressRecognizer == nil,
             "two valid bars across visible windows fail closed as ambiguous");
    TKPCheck(TKPLongPressCount(firstBar) == 0 && TKPLongPressCount(selectedBar) == 0,
             "ambiguous tab bars receive no long-press recognizer");

    firstBar.buttons = nil;
    TKPCheck([controller reconcileVisibleGuestTab] && controller.hostWindow == selectedWindow &&
             controller.tabBarView == selectedBar && controller.profileTabView == originalButtons[4],
             "one valid bar resolves in the second window while an untrusted dynamic bar is ignored");
    TKPCheck(controller.profilePressRecognizer.view == selectedBar &&
             [selectedBar.gestureRecognizers containsObject:controller.profilePressRecognizer] &&
             TKPLongPressCount(selectedBar) == 1 &&
             fabs(controller.profilePressRecognizer.minimumPressDuration - 0.4) < 0.001 &&
             controller.profilePressRecognizer.cancelsTouchesInView &&
             !controller.profilePressRecognizer.delaysTouchesBegan &&
             !controller.profilePressRecognizer.delaysTouchesEnded,
             "one recognizer is attached to the bar at 0.4 seconds with only recognized-touch cancellation");

    Class kvoClass = object_getClass(selectedBar);
    Method classReporter = NULL;
    unsigned int kvoMethodCount = 0;
    Method *kvoMethods = class_copyMethodList(kvoClass, &kvoMethodCount);
    for (unsigned int index = 0; index < kvoMethodCount; index += 1) {
        if (method_getName(kvoMethods[index]) == @selector(class)) {
            classReporter = kvoMethods[index];
            break;
        }
    }
    free(kvoMethods);
    IMP trustedClassReporter = classReporter == NULL ? NULL
        : method_getImplementation(classReporter);
    BOOL spoofRejectedWithoutCalling = NO;
    if (classReporter != NULL && trustedClassReporter != NULL) {
        gKVOClassReporterSpoofCalls = 0;
        IMP previousImplementation = method_setImplementation(
            classReporter, (IMP)TKPFixtureSpoofedKVOClassReporter);
        NSUInteger spoofDiagnosticStart = gEntryDiagnosticLines.count;
        BOOL spoofResolved = YES;
        BOOL spoofFlagsReported = NO;
        @try {
            spoofResolved = [controller reconcileVisibleGuestTab];
            for (NSUInteger index = spoofDiagnosticStart;
                 index < gEntryDiagnosticLines.count; index += 1) {
                NSString *line = gEntryDiagnosticLines[index];
                if ([line rangeOfString:@" wf=95"].location != NSNotFound) {
                    spoofFlagsReported = YES;
                    break;
                }
            }
        } @finally {
            (void)method_setImplementation(classReporter, previousImplementation);
        }
        spoofRejectedWithoutCalling = !spoofResolved &&
            gKVOClassReporterSpoofCalls == 0 &&
            controller.profilePressRecognizer == nil &&
            (!kvoAdmissionReported || spoofFlagsReported);
    }
    TKPCheck(classReporter != NULL && trustedClassReporter != NULL &&
             spoofRejectedWithoutCalling,
             "an exact-name KVO wrapper with a replaced class reporter is rejected without invoking it");
    TKPCheck([controller reconcileVisibleGuestTab] &&
             controller.tabBarView == selectedBar &&
             classReporter != NULL &&
             method_getImplementation(classReporter) == trustedClassReporter,
             "restoring the Foundation class reporter restores trusted tab-bar discovery");

    Class inheritedGetterClass = NSClassFromString(@"TKPFixtureDynamicInheritedGetterTabBar");
    TTKTabBar *inheritedGetterBar = inheritedGetterClass == Nil ? nil
        : [[inheritedGetterClass alloc] initWithFrame:selectedBar.frame];
    inheritedGetterBar.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    NSArray<UIView *> *inheritedGetterButtons =
        TKPCreateButtonsForBar(inheritedGetterBar, NULL);
    inheritedGetterBar.buttons = inheritedGetterButtons;
    if (inheritedGetterBar != nil) {
        [selectedRoot.view addSubview:inheritedGetterBar];
    }
    [selectedRoot.view layoutIfNeeded];
    firstBar.hidden = YES;
    selectedBar.hidden = YES;
    sceneDelegate.foreignImageTabBar.hidden = YES;
    NSUInteger diagnosticLineStart = gEntryDiagnosticLines.count;
    BOOL inheritedGetterResolved = [controller reconcileVisibleGuestTab];
    BOOL inheritedGetterRejectionReported = NO;
    for (NSUInteger index = diagnosticLineStart;
         index < gEntryDiagnosticLines.count; index += 1) {
        NSString *line = gEntryDiagnosticLines[index];
        if ([line rangeOfString:@" event=5 reason=6 "].location != NSNotFound &&
            [line rangeOfString:@" cs=5 cd=0 wf="].location != NSNotFound) {
            inheritedGetterRejectionReported = YES;
            break;
        }
    }
    TKPCheck(inheritedGetterBar.window == selectedWindow &&
             inheritedGetterButtons.count == 5 &&
             TKPButtonsAreVisibleChildren(inheritedGetterButtons,
                 inheritedGetterBar, selectedWindow) &&
             inheritedGetterBar.buttons == inheritedGetterButtons,
             "the visible runtime tab-bar subclass exposes five items through its inherited getter");
    TKPCheck(!inheritedGetterResolved && controller.hostWindow == nil &&
             controller.tabBarView == nil && controller.profileTabView == nil &&
             controller.profilePressRecognizer == nil &&
             TKPLongPressCount(inheritedGetterBar) == 0 &&
             inheritedGetterRejectionReported,
             "the visible inherited-getter subclass stays unbound and reports class rejection status 5 at depth 0");
    [inheritedGetterBar removeFromSuperview];
    firstBar.hidden = NO;
    selectedBar.hidden = NO;
    sceneDelegate.foreignImageTabBar.hidden = NO;
    TKPCheck([controller reconcileVisibleGuestTab] &&
             controller.tabBarView == selectedBar &&
             controller.profileTabView == originalButtons[4],
             "the trusted visible tab bar is rediscovered after the runtime subclass case");

    TKPCheck(TKPLongPressCount(firstBar) == 0 &&
             TKPLongPressCount(sceneDelegate.foreignImageTabBar) == 0,
             "no gesture is attached to the empty or foreign-image tab bar");

    selectedBar.buttons = nil;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "a foreign-image tab bar alone cannot authorize the entry");
    TKPCheck(TKPLongPressCount(firstBar) == 0 &&
             TKPLongPressCount(sceneDelegate.foreignImageTabBar) == 0,
             "untrusted bar alone remains unbound in both windows");
    selectedBar.buttons = originalButtons;
    TKPCheck([controller reconcileVisibleGuestTab],
             "valid canonical tab bar can be rediscovered after untrusted-only state");

    selectedBar.buttons = nil;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "nil buttons getter result fails closed");
    selectedBar.buttons = [originalButtons subarrayWithRange:NSMakeRange(0, 4)];
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "button arrays shorter than index 4 fail closed");

    NSMutableArray<UIView *> *maximumButtons = [originalButtons mutableCopy];
    while (maximumButtons.count < 16) {
        [maximumButtons addObject:originalButtons[0]];
    }
    selectedBar.buttons = maximumButtons;
    TKPCheck([controller reconcileVisibleGuestTab] &&
             controller.profileTabView == originalButtons[4],
             "the 16-item upper boundary remains eligible at index 4");

    NSMutableArray<UIView *> *oversizedButtons = [originalButtons mutableCopy];
    while (oversizedButtons.count <= 16) {
        [oversizedButtons addObject:originalButtons[0]];
    }
    selectedBar.buttons = oversizedButtons;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "button arrays beyond the 16-item limit fail closed");

    NSMutableArray *invalidItemButtons = [originalButtons mutableCopy];
    invalidItemButtons[4] = [NSNull null];
    selectedBar.buttons = (NSArray<UIView *> *)(id)invalidItemButtons;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "a non-view index-4 item fails closed");

    NSMutableArray<UIView *> *externalButtons = [originalButtons mutableCopy];
    externalButtons[4] = selectedRoot.externalCandidate;
    selectedBar.buttons = externalButtons;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "an index-4 view outside its tab bar fails closed");

    UIView *originalTarget = originalButtons[4];
    originalTarget.hidden = YES;
    selectedBar.buttons = originalButtons;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "a hidden index-4 target fails closed");
    originalTarget.hidden = NO;
    originalTarget.userInteractionEnabled = NO;
    TKPAssertNoGestureBinding(controller, selectedBar,
                              "a noninteractive index-4 target fails closed");
    originalTarget.userInteractionEnabled = YES;
    selectedBar.buttons = originalButtons;
    TKPCheck([controller reconcileVisibleGuestTab],
             "valid target restores its binding after invalid array and view cases");

    TKPCheck(TKPDelegateAllowsView(controller, originalTarget) &&
             TKPDelegateAllowsView(controller, selectedRoot.targetDescendant),
             "synthetic delegate accepts only the current Profile item and its descendants");
    TKPCheck(!TKPDelegateAllowsView(controller, originalButtons[3]) &&
             !TKPDelegateAllowsView(controller, firstRoot.innerProfileDecoy) &&
             !TKPDelegateAllowsView(controller, selectedRoot.innerProfileDecoy) &&
             !TKPDelegateAllowsView(controller, selectedRoot.externalCandidate),
             "other tabs, nested Profile decoys, and outside views are rejected");

    NSMutableArray<UIView *> *replacementButtons = [originalButtons mutableCopy];
    UIButton *replacementTarget = [[UIButton alloc] initWithFrame:originalTarget.frame];
    [replacementTarget setTitle:@"Replacement Profile" forState:UIControlStateNormal];
    [selectedBar addSubview:replacementTarget];
    UIView *replacementDescendant = [[UIView alloc] initWithFrame:CGRectMake(3.0, 3.0, 12.0, 12.0)];
    [replacementTarget addSubview:replacementDescendant];
    replacementButtons[4] = replacementTarget;
    selectedRoot.buttons = replacementButtons;
    selectedBar.buttons = replacementButtons;
    TKPCheck(!TKPDelegateAllowsView(controller, originalTarget),
             "a stale index-4 target is rejected immediately after target replacement");
    TKPCheck([controller reconcileVisibleGuestTab] && controller.profileTabView == replacementTarget &&
             TKPLongPressCount(selectedBar) == 1,
             "reconciliation tracks the replacement target without duplicating the recognizer");
    TKPCheck(TKPDelegateAllowsView(controller, replacementTarget) &&
             TKPDelegateAllowsView(controller, replacementDescendant) &&
             !TKPDelegateAllowsView(controller, originalTarget),
             "delegate authorization follows the replacement target, not the stale old item");

    selectedRoot.buttons = originalButtons;
    selectedBar.buttons = originalButtons;
    TKPCheck([controller reconcileVisibleGuestTab] && controller.profileTabView == originalTarget,
             "original target is restored to prepare a mid-hold replacement case");

    UILongPressGestureRecognizer *productionRecognizer = controller.profilePressRecognizer;
    [selectedBar removeGestureRecognizer:productionRecognizer];
    TKPSyntheticLongPressRecognizer *syntheticRecognizer =
        [[TKPSyntheticLongPressRecognizer alloc] initWithTarget:controller
                                                        action:@selector(profileTabLongPressed:)];
    syntheticRecognizer.delegate = controller;
    syntheticRecognizer.fixtureState = UIGestureRecognizerStatePossible;
    controller.profilePressRecognizer = syntheticRecognizer;
    [selectedBar addGestureRecognizer:syntheticRecognizer];
    TKPCheck(TKPDelegateAllowsView(controller, originalTarget),
             "synthetic delegate captures target A before a recognized hold");
    selectedRoot.buttons = replacementButtons;
    selectedBar.buttons = replacementButtons;
    syntheticRecognizer.fixtureState = UIGestureRecognizerStateBegan;
    [controller profileTabLongPressed:syntheticRecognizer];
    TKPCheck(controller.ownedScreenView == nil && controller.profileTabView == replacementTarget,
             "a synthetic Began callback cannot open after the accepted target changes from A to B");
    syntheticRecognizer.fixtureState = UIGestureRecognizerStateEnded;
    [controller profileTabLongPressed:syntheticRecognizer];
    TKPCheck(TKPDelegateAllowsView(controller, replacementTarget),
             "a fresh synthetic hold accepts the current replacement target B");
    syntheticRecognizer.fixtureState = UIGestureRecognizerStateBegan;
    [controller profileTabLongPressed:syntheticRecognizer];
    [selectedWindow layoutIfNeeded];
    TKPCheck(controller.ownedScreenView != nil &&
             TKPViewCoversWindow(controller.ownedScreenView, selectedWindow),
             "a matching synthetic Began callback opens the owned full-screen view");

    TKPCheck(controller.gearScreenView.window == selectedWindow &&
             [controller.gearScreenView.accessibilityIdentifier
                 isEqualToString:@"tkp.guest.profile-controls.gear-screen"],
             "gear screen is attached to the existing selected window");
    TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:firstWindow] &&
             [scene.windows containsObject:selectedWindow],
             "opening the gear screen creates no additional UIWindow");

    UIButton *gearButton = controller.gearButton;
    TKPCheck(gearButton != nil, "gear control exists before activation");
    [gearButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    [selectedWindow layoutIfNeeded];
    TKPCheck(controller.settingsScreenView.window == selectedWindow &&
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
    TKPCheck(TKPCountViewsWithIdentifier(selectedWindow,
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
    TKPCheck(TKPCountViewsWithIdentifier(selectedWindow,
                 @"tkp.guest.profile-controls.close-button") == 1,
             "gear-to-settings transition does not duplicate the close control");

    [controller.closeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    TKPCheckNoOwnedScreen(controller, selectedWindow,
                          "close removes the fixture-owned view from the selected window");
    TKPCheck(selectedWindow.rootViewController == selectedRoot &&
             selectedRoot.view.window == selectedWindow && !selectedRoot.view.hidden &&
             firstWindow.rootViewController == firstRoot && firstRoot.view.window == firstWindow,
             "close leaves both native root views visible");
    TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:firstWindow] &&
             [scene.windows containsObject:selectedWindow],
             "close preserves the original window count");

    [selectedBar removeGestureRecognizer:syntheticRecognizer];
    controller.profilePressRecognizer = nil;
    TKPCheck([controller reconcileVisibleGuestTab] &&
             controller.profilePressRecognizer != nil &&
             controller.profilePressRecognizer != syntheticRecognizer &&
             controller.profilePressRecognizer.view == selectedBar,
             "production recognizer can be rebound after synthetic state testing");
    for (NSUInteger cycle = 0; cycle < 3; cycle++) {
        [controller showGearScreen];
        UIButton *cycleGearButton = controller.gearButton;
        [cycleGearButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        TKPCheck(TKPCountViewsWithIdentifier(selectedWindow,
                     @"tkp.guest.profile-controls.close-button") == 1,
                 "repeat gear-to-settings cycle retains a single close control");
        [controller.closeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        TKPCheckNoOwnedScreen(controller, selectedWindow,
                              "repeated open-close cycle leaves no duplicate owned view");
        TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:firstWindow] &&
                 [scene.windows containsObject:selectedWindow],
                 "repeated open-close cycle preserves the original windows");
    }
    TKPCheck(TKPLongPressCount(selectedBar) == 1,
             "repeated screen cycles do not duplicate the tab-bar gesture");

    [controller showGearScreen];
    TKPCheck(controller.ownedScreenView.window == selectedWindow,
             "owned view is present before inactive-state cleanup");
    uint64_t activeEpoch = controller.lifecycleEpoch;
    [controller applicationWillResignActive:nil];
    TKPCheck(controller.lifecycleEpoch > activeEpoch &&
             controller.profilePressRecognizer == nil,
             "inactive cleanup advances the lifecycle epoch and clears the recognizer");
    TKPCheck(staleDiscoveryTimer != nil && staleDiscoveryEpoch < controller.lifecycleEpoch,
             "the retained startup discovery callback belongs to an older lifecycle epoch");
    uint64_t inactiveEpoch = controller.lifecycleEpoch;
    [controller discoveryTick:staleDiscoveryTimer];
    TKPCheck(controller.lifecycleEpoch == inactiveEpoch && controller.ownedScreenView == nil,
             "a stale discovery callback cannot restore state after lifecycle cleanup");
    TKPCheckNoOwnedScreen(controller, selectedWindow,
                          "inactive cleanup immediately removes the owned view");

    [[NSNotificationCenter defaultCenter]
        postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TKPCheckNoOwnedScreen(controller, selectedWindow,
                              "activation does not asynchronously restore a private settings view");
        TKPCheck(scene.windows.count == 2 && [scene.windows containsObject:firstWindow] &&
                 [scene.windows containsObject:selectedWindow] &&
                 selectedWindow.rootViewController == selectedRoot &&
                 firstWindow.rootViewController == firstRoot,
                 "activation leaves both native windows and roots intact");
        for (NSUInteger attempt = 0; attempt < 40; attempt++) {
            [controller applicationWillResignActive:nil];
        }
        BOOL kvoObserverRemoved = !kvoObservationInstalled;
        if (kvoObservationInstalled) {
            @try {
                [selectedBar removeObserver:kvoObserver forKeyPath:@"buttons"
                                    context:TKPFixtureKVOContext];
                kvoObserverRemoved = YES;
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        TKPCheck(kvoObserverRemoved && object_getClass(selectedBar) == TTKTabBar.class,
                 "balanced observer removal restores the original tab-bar class");
        TKPCheckEntryDiagnostics();
        NSUInteger diagnosticCount = gEntryDiagnosticLines.count;
        TKPCheck(diagnosticCount == 24,
                 "repeated synthetic lifecycle events exhaust the 24-record diagnostic budget");
        for (NSUInteger attempt = 0; attempt < 40; attempt++) {
            [controller applicationWillResignActive:nil];
        }
        TKPCheck(gEntryDiagnosticLines.count == diagnosticCount,
                 "entry diagnostic delivery stops at its process budget without delaying cleanup");
        TKPCheck(controller.ownedScreenView == nil && controller.profilePressRecognizer == nil,
                 "diagnostic budget exhaustion does not prevent lifecycle cleanup");
        TKPFinishFixture();
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

    self.unrelatedWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.unrelatedRootController = [[TKPProfileSettingsFixtureRootController alloc] init];
    self.unrelatedWindow.rootViewController = self.unrelatedRootController;
    self.unrelatedWindow.windowLevel = UIWindowLevelNormal;
    self.unrelatedWindow.hidden = NO;
    [self.unrelatedWindow layoutIfNeeded];
    self.foreignImageTabBar = TKPCreateForeignImageTabBar(
        CGRectMake(0.0, 12.0, CGRectGetWidth(self.unrelatedRootController.view.bounds), 56.0),
        NULL);
    if (self.foreignImageTabBar != nil) {
        [self.unrelatedRootController.view addSubview:self.foreignImageTabBar];
    }

    fprintf(stdout,
            "FIXTURE SCOPE: synthetic UIKit/delegate and recognizer-state checks only; no physical touches, proprietary guest, IPA, network, account, or personal data.\n");
    fflush(stdout);
    TKPDevicePanelStart();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TKPDevicePanelStart();
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
    if (setvbuf(stdout, NULL, _IONBF, 0) != 0 ||
        setvbuf(stderr, NULL, _IONBF, 0) != 0) {
        fprintf(stderr, "FAIL: synthetic fixture console buffering setup\n");
        return EXIT_FAILURE;
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([TKPProfileSettingsFixtureAppDelegate class]));
    }
}
