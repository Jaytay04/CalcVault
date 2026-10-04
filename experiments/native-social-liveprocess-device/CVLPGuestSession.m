#import "CVLPGuestSession.h"
#import "CVLPLiveness.h"
#import "../MultitaskSupport/AppSceneViewController.h"
#import <signal.h>
#if __has_include("CVLPFrameworkGuest.h")
#import "CVLPFrameworkGuest.h"
#define CVLP_HAS_FRAMEWORK_GUEST_VALIDATOR 1
#else
#define CVLP_HAS_FRAMEWORK_GUEST_VALIDATOR 0
#endif

@interface AppSceneViewController (CVLPLifecycle)
@property(nonatomic, readonly) BOOL cvlpBeginCompleted;
@property(nonatomic, readonly) int cvlpObservedPID;
@property(nonatomic, readonly) BOOL cvlpAliveBeforeRevoke;
@property(nonatomic, readonly) CVLPLivenessSample cvlpLaunchLivenessSample;
@property(nonatomic, readonly) BOOL cvlpHasLaunchLivenessSample;
@property(nonatomic, readonly) CVLPLivenessSample cvlpFirstPreRevokeLivenessSample;
@property(nonatomic, readonly) BOOL cvlpHasFirstPreRevokeLivenessSample;
@property(nonatomic, readonly) CVLPLivenessSample cvlpLatestPreRevokeLivenessSample;
@property(nonatomic, readonly) CVLPLivenessSample cvlpProcessGroupPresenceSample;
@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;
@property(nonatomic) BOOL cvlpSyntheticTargetVerified;
- (BOOL)cvlpRequestVerificationSignal:(int)signal;
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
@property(nonatomic) BOOL processGroupShutdownLogged;
@property(nonatomic, copy) NSString *targetBundleIdentifier;
@property(nonatomic, copy) NSString *targetDataUUID;
@property(nonatomic) BOOL verificationSignalProbeUsed;
@property(nonatomic) BOOL verificationSignalStopSubmitted;
@property(nonatomic) BOOL verificationSignalContinueAttempted;
@property(nonatomic) BOOL verificationSignalContinueSubmitted;
@property(nonatomic) BOOL syntheticTargetIdentityVerified;
- (BOOL)syntheticTargetIdentityIsVerified;
- (BOOL)verificationSignalRequestIsReady;
@end

static NSString *CVLPSyntheticBundleIdentifier(void) {
    return [@"org.example.synthetic" stringByAppendingString:@"nativeguest.app"];
}

static BOOL CVLPFrameworkDescriptorTargetsSyntheticGuest(void) {
#if CVLP_HAS_FRAMEWORK_GUEST_VALIDATOR
    NSURL *guestURL = CVLPFrameworkGuestURL(NSBundle.mainBundle.bundleURL);
    if (!guestURL) return NO;
    NSString *descriptorPath = [NSBundle.mainBundle.bundleURL.path
        stringByAppendingPathComponent:@"CVLPFrameworkGuest.plist"];
    NSDictionary *descriptor = CVLPGuestPropertyList(descriptorPath, 64 * 1024);
    return [descriptor[@"bundleIdentifier"] isEqualToString:CVLPSyntheticBundleIdentifier()];
#else
    return NO;
#endif
}

static void CVLPLogLivenessSample(NSString *phase, CVLPLivenessSample sample) {
    NSLog(@"CVLP_LIVENESS phase=%@ pid=%d attempted=%d result=%d errno=%d class=%s pgid=%d pgidErrno=%d pgidClass=%s",
          phase, (int)sample.pid, sample.attempted, sample.result, sample.errorNumber,
          CVLPLivenessClassificationName(sample.classification), (int)sample.groupResult,
          sample.groupErrorNumber, CVLPLivenessClassificationName(sample.groupClassification));
}

static NSString *CVLPDescribeLivenessSample(CVLPLivenessSample sample) {
    return [NSString stringWithFormat:@"pid=%d,attempted=%d,result=%d,errno=%d,class=%s,pgid=%d,pgidErrno=%d,pgidClass=%s",
            (int)sample.pid, sample.attempted, sample.result, sample.errorNumber,
            CVLPLivenessClassificationName(sample.classification), (int)sample.groupResult,
            sample.groupErrorNumber, CVLPLivenessClassificationName(sample.groupClassification)];
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
    NSString *bundleIdentifier = @"org.example.syntheticnativeguest.app";
    NSString *dataUUID = @"synthetic-liveprocess-device";
    self.targetBundleIdentifier = bundleIdentifier;
    self.targetDataUUID = dataUUID;
    self.syntheticTargetIdentityVerified = [self syntheticTargetIdentityIsVerified];
    AppSceneViewController *scene = [[AppSceneViewController alloc]
        initWithBundleId:bundleIdentifier
               dataUUID:dataUUID
               delegate:self];
    self.sceneController = scene;
    if (!scene) {
        self.launchResult = @"scene initialization failed";
        [self deliverCompletion:NO];
        return;
    }
    scene.cvlpSyntheticTargetVerified = self.syntheticTargetIdentityVerified;
    [self.hostController addChildViewController:scene];
    scene.view.frame = self.hostController.view.bounds;
    scene.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.hostController.view addSubview:scene.view];
    [scene didMoveToParentViewController:self.hostController];
}

- (BOOL)syntheticTargetIdentityIsVerified {
    BOOL frameworkGuestMode = [NSBundle.mainBundle.infoDictionary[@"CVLPFrameworkGuestMode"] boolValue];
    if (frameworkGuestMode) {
        NSString *frameworkSelector = [@"cvlp-immutable-" stringByAppendingString:@"framework"];
        NSString *frameworkDataUUID = [@"native-framework-" stringByAppendingString:@"research"];
        return [self.targetBundleIdentifier isEqualToString:frameworkSelector] &&
            [self.targetDataUUID isEqualToString:frameworkDataUUID] &&
            CVLPFrameworkDescriptorTargetsSyntheticGuest();
    }
    NSURL *frameworkDescriptorURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"CVLPFrameworkGuest.plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:frameworkDescriptorURL.path]) return NO;
    NSString *syntheticDataUUID = [@"synthetic-liveprocess-" stringByAppendingString:@"device"];
    return [self.targetBundleIdentifier isEqualToString:CVLPSyntheticBundleIdentifier()] &&
        [self.targetDataUUID isEqualToString:syntheticDataUUID];
}

- (BOOL)verificationSignalRequestIsReady {
    NSAssert(NSThread.isMainThread, @"Verification signal probe must run on main");
    return self.started && !self.revoked && self.sceneController &&
        self.sceneController.cvlpBeginCompleted && self.sceneController.cvlpObservedPID > 0 &&
        self.sceneController.cvlpObservedPID == self.observedPID &&
        self.sceneController.cvlpSyntheticTargetVerified && [self syntheticTargetIdentityIsVerified] &&
        [self.sceneController respondsToSelector:@selector(cvlpRequestVerificationSignal:)];
}

- (BOOL)isVerificationSignalProbeAvailable {
    return [self verificationSignalRequestIsReady] && !self.verificationSignalProbeUsed;
}

- (BOOL)requestVerificationSignal:(int)signal {
    NSAssert(NSThread.isMainThread, @"Verification signal probe must run on main");
    if (signal == SIGSTOP) {
        if (!self.isVerificationSignalProbeAvailable) return NO;
        self.verificationSignalProbeUsed = YES;
        if (![self.sceneController cvlpRequestVerificationSignal:signal]) return NO;
        self.verificationSignalStopSubmitted = YES;
        return YES;
    }
    if (signal == SIGCONT) {
        if (!self.verificationSignalStopSubmitted || self.verificationSignalContinueAttempted ||
            ![self verificationSignalRequestIsReady]) return NO;
        self.verificationSignalContinueAttempted = YES;
        BOOL submitted = [self.sceneController cvlpRequestVerificationSignal:signal];
        self.verificationSignalContinueSubmitted = submitted;
        return submitted;
    }
    return NO;
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
    if (!self.revoked) return;
    if (!(self.exitObserved && self.hasPostcheckLivenessSample &&
          CVLPProcessAbsenceObserved(self.postcheckLivenessSample))) {
        int pid = self.sceneController.cvlpObservedPID;
        self.observedPID = pid;
        self.postcheckLivenessSample = CVLPSampleLiveness((pid_t)pid);
        self.hasPostcheckLivenessSample = YES;
        CVLPLogLivenessSample(@"postcheck", self.postcheckLivenessSample);
        if (!self.exitObserved && self.postcheckLivenessSample.classification == CVLPLivenessESRCH) {
            self.exitObserved = YES;
            NSLog(@"CVLP_LIFECYCLE_EXIT_OBSERVED");
        }
    }
    // A late request completion may arrive after absence was already observed.
    if (!self.processGroupShutdownLogged && self.sceneController &&
        CVLPProcessGroupShutdownObserved(self.revoked, self.sceneController.cvlpBeginCompleted,
            self.sceneController.cvlpProcessGroupPresenceSample, self.postcheckLivenessSample)) {
        self.processGroupShutdownLogged = YES;
        NSLog(@"CVLP_PROCESS_GROUP_SHUTDOWN_OBSERVED");
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
    NSString *signalProbe = self.verificationSignalStopSubmitted ?
        [NSString stringWithFormat:@"; verification signal requests: SIGSTOP submitted, SIGCONT %@; signal request submitted; suspension and media stop unproved",
            self.verificationSignalContinueSubmitted ? @"submitted" : @"not submitted"] :
        @"; verification signal probe not run";
    NSString *syntheticTarget = self.syntheticTargetIdentityVerified ?
        @"; synthetic signal target verified" : @"; signal probe unavailable: target is not the exact synthetic descriptor";
    BOOL groupShutdownObserved = self.sceneController && self.hasPostcheckLivenessSample &&
        CVLPProcessGroupShutdownObserved(self.revoked, self.sceneController.cvlpBeginCompleted,
            self.sceneController.cvlpProcessGroupPresenceSample, self.postcheckLivenessSample);
    NSString *diagnostics = [NSString stringWithFormat:
        @"; liveness launch={%@}; firstPreRevoke={%@}; latestPreRevoke={%@}; preRevokeAttempts=%lu; postcheck={%@}\nPID presence/absence observation (getpgid): %@ (separate from signal-zero settlement; not a security certification)",
        launchSample, firstSample, latestSample,
        (unsigned long)self.sceneController.cvlpPreRevokeAttemptCount, postcheck,
        groupShutdownObserved ? @"observed" : @"unproved"];
    diagnostics = [[diagnostics stringByAppendingString:syntheticTarget] stringByAppendingString:signalProbe];
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
