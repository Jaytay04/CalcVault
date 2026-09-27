#import "CVLPGuestSession.h"
#import "CVLPLiveness.h"
#import "../MultitaskSupport/AppSceneViewController.h"

@interface AppSceneViewController (CVLPLifecycle)
@property(nonatomic, readonly) BOOL cvlpBeginCompleted;
@property(nonatomic, readonly) int cvlpObservedPID;
@property(nonatomic, readonly) BOOL cvlpAliveBeforeRevoke;
@property(nonatomic, readonly) CVLPLivenessSample cvlpLaunchLivenessSample;
@property(nonatomic, readonly) BOOL cvlpHasLaunchLivenessSample;
@property(nonatomic, readonly) CVLPLivenessSample cvlpFirstPreRevokeLivenessSample;
@property(nonatomic, readonly) BOOL cvlpHasFirstPreRevokeLivenessSample;
@property(nonatomic, readonly) CVLPLivenessSample cvlpLatestPreRevokeLivenessSample;
@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;
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
@property(nonatomic) CVLPLivenessSample postcheckLivenessSample;
@property(nonatomic) BOOL hasPostcheckLivenessSample;
@end

static void CVLPLogLivenessSample(NSString *phase, CVLPLivenessSample sample) {
    NSLog(@"CVLP_LIVENESS phase=%@ pid=%d attempted=%d result=%d errno=%d class=%s",
          phase, (int)sample.pid, sample.attempted, sample.result, sample.errorNumber,
          CVLPLivenessClassificationName(sample.classification));
}

static NSString *CVLPDescribeLivenessSample(CVLPLivenessSample sample) {
    return [NSString stringWithFormat:@"pid=%d,attempted=%d,result=%d,errno=%d,class=%s",
            (int)sample.pid, sample.attempted, sample.result, sample.errorNumber,
            CVLPLivenessClassificationName(sample.classification)];
}

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
    self.observedPID = pid;
    self.postcheckLivenessSample = CVLPSampleLiveness((pid_t)pid);
    self.hasPostcheckLivenessSample = YES;
    CVLPLogLivenessSample(@"postcheck", self.postcheckLivenessSample);
    if (self.postcheckLivenessSample.classification == CVLPLivenessESRCH) {
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
    BOOL settled = self.isSettled;
    NSString *launchSample = self.sceneController.cvlpHasLaunchLivenessSample ?
        CVLPDescribeLivenessSample(self.sceneController.cvlpLaunchLivenessSample) : @"not sampled";
    NSString *firstSample = self.sceneController.cvlpHasFirstPreRevokeLivenessSample ?
        CVLPDescribeLivenessSample(self.sceneController.cvlpFirstPreRevokeLivenessSample) : @"not sampled";
    NSString *latestSample = self.sceneController.cvlpPreRevokeAttemptCount > 0 ?
        CVLPDescribeLivenessSample(self.sceneController.cvlpLatestPreRevokeLivenessSample) : @"not sampled";
    NSString *postcheck = self.hasPostcheckLivenessSample ?
        CVLPDescribeLivenessSample(self.postcheckLivenessSample) : @"not sampled";
    NSString *diagnostics = [NSString stringWithFormat:
        @"; liveness launch={%@}; firstPreRevoke={%@}; latestPreRevoke={%@}; preRevokeAttempts=%lu; postcheck={%@}",
        launchSample, firstSample, latestSample,
        (unsigned long)self.sceneController.cvlpPreRevokeAttemptCount, postcheck];
    if (!self.started) return [@"Synthetic guest: not started; settled" stringByAppendingString:diagnostics];
    NSString *request = self.sceneController.cvlpBeginCompleted ? @"completed" : @"pending";
    NSString *process = self.exitObserved ? @"exit observed (ESRCH)" :
        (self.observedPID > 0 ? @"exit unproved" : @"PID unavailable; exit unproved");
    NSString *prior = self.sceneController.cvlpAliveBeforeRevoke ?
        @"alive before revoke observed" : @"pre-revoke liveness unproved";
    return [[NSString stringWithFormat:@"Synthetic guest: %@; %@; extension %@; %@; process %@; %@",
            self.launchResult, self.revoked ? @"revoked" : @"active", request, prior, process,
            settled ? @"settled" : @"unsettled"] stringByAppendingString:diagnostics];
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
