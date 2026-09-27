#import "CVLPGuestSession.h"
#import "../MultitaskSupport/AppSceneViewController.h"

#import <errno.h>
#import <signal.h>

@interface AppSceneViewController (CVLPLifecycle)
@property(nonatomic, readonly) BOOL cvlpBeginCompleted;
@property(nonatomic, readonly) int cvlpObservedPID;
@property(nonatomic, readonly) BOOL cvlpAliveBeforeRevoke;
- (void)cvlpRevoke;
@end

@interface CVLPGuestSession () <AppSceneViewControllerDelegate>
@property(nonatomic, strong) UIViewController *hostController;
@property(nonatomic, strong) AppSceneViewController *sceneController;
@property(nonatomic, copy) void (^completion)(BOOL);
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL revoked;
@property(nonatomic) BOOL callbackDelivered;
@property(nonatomic) BOOL exitObserved;
@property(nonatomic) int observedPID;
@property(nonatomic, copy) NSString *launchResult;
@end

@implementation CVLPGuestSession

- (instancetype)init {
    self = [super init];
    if (self) {
        _hostController = [UIViewController new];
        _launchResult = @"not started";
    }
    return self;
}

- (UIViewController *)viewController {
    return self.hostController;
}

- (void)startWithCompletion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Guest session must run on main");
    if (self.started || self.revoked) {
        if (completion) completion(NO);
        return;
    }
    self.started = YES;
    self.completion = completion;
    self.launchResult = @"extension request pending";
    AppSceneViewController *scene = [[AppSceneViewController alloc]
        initWithBundleId:@"org.example.syntheticnativeguest.app"
               dataUUID:@"synthetic-liveprocess-device"
               delegate:self];
    self.sceneController = scene;
    if (!scene) {
        self.launchResult = @"scene initialization failed";
        [self deliverCompletion:NO];
        return;
    }
    [self.hostController addChildViewController:scene];
    scene.view.frame = self.hostController.view.bounds;
    scene.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.hostController.view addSubview:scene.view];
    [scene didMoveToParentViewController:self.hostController];
}

- (void)deliverCompletion:(BOOL)success {
    if (self.callbackDelivered) return;
    self.callbackDelivered = YES;
    void (^callback)(BOOL) = self.completion;
    self.completion = nil;
    if (callback) callback(success);
}

- (void)revoke {
    NSAssert(NSThread.isMainThread, @"Guest revocation must run on main");
    if (self.revoked) return;
    self.revoked = YES;
    self.hostController.view.hidden = YES;
    self.sceneController.view.hidden = YES;
    [self.sceneController cvlpRevoke];
    [self deliverCompletion:NO];
    [self observeExit];
}

- (void)observeExit {
    if (!self.revoked || self.exitObserved) return;
    int pid = self.sceneController.cvlpObservedPID;
    if (pid <= 0) return;
    self.observedPID = pid;
    if (kill(pid, 0) == -1 && errno == ESRCH) {
        self.exitObserved = YES;
        NSLog(@"CVLP_LIFECYCLE_EXIT_OBSERVED");
    }
}

- (BOOL)isSettled {
    NSAssert(NSThread.isMainThread, @"Guest session state must be read on main");
    if (!self.started) return YES;
    [self observeExit];
    return self.revoked && self.sceneController.cvlpBeginCompleted &&
        self.sceneController.cvlpAliveBeforeRevoke && self.exitObserved;
}

- (NSString *)summary {
    NSAssert(NSThread.isMainThread, @"Guest session state must be read on main");
    [self observeExit];
    if (!self.started) return @"Synthetic guest: not started; settled";
    NSString *request = self.sceneController.cvlpBeginCompleted ? @"completed" : @"pending";
    NSString *process = self.exitObserved ? @"exit observed (ESRCH)" :
        (self.observedPID > 0 ? @"exit unproved" : @"PID unavailable; exit unproved");
    NSString *prior = self.sceneController.cvlpAliveBeforeRevoke ?
        @"alive before revoke observed" : @"pre-revoke liveness unproved";
    return [NSString stringWithFormat:@"Synthetic guest: %@; %@; extension %@; %@; process %@; %@",
            self.launchResult, self.revoked ? @"revoked" : @"active", request, prior, process,
            self.isSettled ? @"settled" : @"unsettled"];
}

- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"Scene delegate must run on main");
    if (error) {
        self.launchResult = @"launch failed";
        [self deliverCompletion:NO];
        return;
    }
    if (self.revoked) return;
    self.observedPID = vc.pid;
    self.launchResult = vc.pid > 0 ? @"extension launched" : @"launch PID unavailable";
    [self deliverCompletion:vc.pid > 0];
}

- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    NSAssert(NSThread.isMainThread, @"Scene delegate must run on main");
    if (!self.revoked) {
        self.launchResult = @"scene ended";
        [self deliverCompletion:NO];
    }
    [self observeExit];
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    if (self.revoked) return;
    [vc updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        UIEdgeInsets insets = vc.view.safeAreaInsets;
        settings.peripheryInsets = insets;
        settings.safeAreaInsetsPortrait = insets;
        settings.deviceOrientation = UIDevice.currentDevice.orientation;
        UIInterfaceOrientation orientation = vc.view.window.windowScene.interfaceOrientation;
        [settings setInterfaceOrientation:orientation ?: UIInterfaceOrientationPortrait];
        [settings setFrame:vc.view.bounds];
    }];
    vc.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)appSceneVC:(AppSceneViewController *)vc
didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings
 transitionContext:(id)context
lifecycleActionType:(uint32_t)actionType {
    if (self.revoked || !vc.presenter) return;
    settings.interruptionPolicy = 0;
    [vc.presenter.scene updateSettings:settings withTransitionContext:context completion:nil];
}

@end
