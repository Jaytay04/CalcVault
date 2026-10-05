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
@property(nonatomic, readonly) NSString *cvlpLifecycleTraceSummary;
@property(nonatomic) BOOL cvlpSyntheticTargetVerified;
- (BOOL)cvlpRequestVerificationSignal:(int)signal;
@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;
- (BOOL)cvlpRequestNativeSignalDiagnostic:(int)signal;
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
@property(nonatomic) BOOL sceneEnded;
@property(nonatomic) BOOL unexpectedSceneExitObserved;
@property(nonatomic) BOOL terminationCallbackDelivered;
@property(nonatomic, copy, nullable) void (^storedTerminationHandler)(void);
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
@property(nonatomic) BOOL nativeSignalDiagnosticStopAttempted;
@property(nonatomic) BOOL nativeSignalDiagnosticStopSubmitted;
@property(nonatomic) BOOL nativeSignalDiagnosticContinueAttempted;
@property(nonatomic) BOOL nativeSignalDiagnosticContinueSubmitted;
@property(nonatomic, strong) NSMutableArray<NSString *> *diagnosticEvents;
@property(nonatomic, strong) NSMutableArray *hostLifecycleObservers;
@property(nonatomic) NSTimeInterval diagnosticStartUptime;
- (BOOL)syntheticTargetIdentityIsVerified;
- (BOOL)verificationSignalRequestIsReady;
- (BOOL)nativeSignalDiagnosticIdentityIsVerified;
- (BOOL)nativeSignalDiagnosticRequestIsReady;
- (void)recordDiagnosticPhase:(NSString *)phase reason:(NSString *)reason
                       sample:(CVLPLivenessSample)sample hasSample:(BOOL)hasSample;
- (void)installHostLifecycleObservers;
- (void)removeHostLifecycleObservers;
- (void)deliverUnexpectedTerminationIfReady;
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

static NSString *CVLPDiagnosticSampleClass(CVLPLivenessSample sample, BOOL hasSample) {
    if (!hasSample) return @"not-sampled";
    if (CVLPProcessPresenceObserved(sample)) return @"present";
    if (CVLPProcessAbsenceObserved(sample)) return @"absent";
    return @"unproved";
}

static NSString *CVLPDiagnosticAllowlistedReason(NSString *phase, NSString *reason) {
    NSDictionary<NSString *, NSArray<NSString *> *> *allowlist = @{
        @"STOP": @[@"before", @"before-unproved", @"after-submitted", @"after-rejected"],
        @"CONT": @[@"before", @"before-unproved", @"after-submitted", @"after-rejected"],
        @"host": @[@"inactive", @"background", @"active"],
        @"scene": @[@"unexpected-exit"],
        @"revoke": @[@"explicit"],
        @"reject": @[@"invalid-signal", @"stop-not-ready", @"stop-unproved",
                      @"cont-not-paused", @"cont-repeated", @"cont-not-ready",
                      @"cont-unproved", @"scene-gate"]
    };
    NSArray<NSString *> *reasons = allowlist[phase];
    if (!reasons) return @"other";
    return [reasons containsObject:reason] ? reason : @"other";
}

@implementation CVLPGuestSession

- (instancetype)init {
    self = [super init];
    if (self) {
        _hostController = [UIViewController new];
        _launchResult = @"not started";
        _diagnosticEvents = [NSMutableArray arrayWithCapacity:48];
        _hostLifecycleObservers = [NSMutableArray arrayWithCapacity:3];
        _diagnosticStartUptime = NSProcessInfo.processInfo.systemUptime;
    }
    return self;
}

- (UIViewController *)viewController {
    return self.hostController;
}

- (void (^ _Nullable)(void))terminationHandler {
    return self.storedTerminationHandler;
}

- (void)setTerminationHandler:(void (^ _Nullable)(void))terminationHandler {
    NSAssert(NSThread.isMainThread, @"Guest termination handler must be set on main");
    if (self.revoked || self.terminationCallbackDelivered) {
        self.storedTerminationHandler = nil;
        return;
    }
    self.storedTerminationHandler = [terminationHandler copy];
    [self deliverUnexpectedTerminationIfReady];
}

- (void)deliverUnexpectedTerminationIfReady {
    NSAssert(NSThread.isMainThread, @"Guest termination callback must run on main");
    if (!self.unexpectedSceneExitObserved || self.terminationCallbackDelivered || !self.storedTerminationHandler) return;
    self.terminationCallbackDelivered = YES;
    void (^callback)(void) = self.storedTerminationHandler;
    self.storedTerminationHandler = nil;
    callback();
}

- (void)recordDiagnosticPhase:(NSString *)phase reason:(NSString *)reason
                       sample:(CVLPLivenessSample)sample hasSample:(BOOL)hasSample {
    NSAssert(NSThread.isMainThread, @"Guest diagnostics must be recorded on main");
    NSArray<NSString *> *phases = @[@"STOP", @"CONT", @"host", @"scene", @"revoke", @"reject"];
    NSString *safePhase = [phases containsObject:phase] ? phase : @"reject";
    NSString *safeReason = CVLPDiagnosticAllowlistedReason(safePhase, reason);
    NSTimeInterval elapsed = MAX(0, NSProcessInfo.processInfo.systemUptime - self.diagnosticStartUptime);
    unsigned long long elapsedMilliseconds = (unsigned long long)(elapsed * 1000.0);
    pid_t pid = hasSample ? sample.pid : (pid_t)self.observedPID;
    NSString *entry = [NSString stringWithFormat:@"t=%llums phase=%@ reason=%@ pid=%d sample=%@",
                       elapsedMilliseconds, safePhase, safeReason, (int)pid,
                       CVLPDiagnosticSampleClass(sample, hasSample)];
    [self.diagnosticEvents addObject:entry];
    if (self.diagnosticEvents.count > 48) [self.diagnosticEvents removeObjectAtIndex:0];
}

- (void)installHostLifecycleObservers {
    NSAssert(NSThread.isMainThread, @"Host lifecycle observers must be installed on main");
    if (self.hostLifecycleObservers.count > 0) return;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray<NSString *> *> *notifications = @[
        @[UIApplicationWillResignActiveNotification, @"inactive"],
        @[UIApplicationDidEnterBackgroundNotification, @"background"],
        @[UIApplicationDidBecomeActiveNotification, @"active"]
    ];
    for (NSArray<NSString *> *entry in notifications) {
        id observer = [center addObserverForName:entry[0]
                                         object:UIApplication.sharedApplication
                                          queue:NSOperationQueue.mainQueue
                                     usingBlock:^(NSNotification *notification) {
            CVLPGuestSession *session = weakSelf;
            if (!session) return;
            CVLPLivenessSample sample = {0};
            [session recordDiagnosticPhase:@"host" reason:entry[1] sample:sample hasSample:NO];
        }];
        [self.hostLifecycleObservers addObject:observer];
    }
}

- (void)removeHostLifecycleObservers {
    NSAssert(NSThread.isMainThread, @"Host lifecycle observers must be removed on main");
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id observer in self.hostLifecycleObservers.copy) [center removeObserver:observer];
    [self.hostLifecycleObservers removeAllObjects];
}

- (void)dealloc {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id observer in self.hostLifecycleObservers.copy) [center removeObserver:observer];
}

- (void)startWithCompletion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Guest session must run on main");
    if (self.started || self.revoked) {
        if (completion) completion(NO);
        return;
    }
    self.started = YES;
    self.completion = completion;
    [self installHostLifecycleObservers];
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
    scene.cvlpNativeSignalDiagnosticTargetVerified = [self nativeSignalDiagnosticIdentityIsVerified];
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
    return self.started && !self.revoked && !self.sceneEnded && self.sceneController &&
        self.sceneController.cvlpBeginCompleted && self.sceneController.cvlpObservedPID > 0 &&
        self.sceneController.cvlpObservedPID == self.observedPID &&
        self.sceneController.cvlpSyntheticTargetVerified && [self syntheticTargetIdentityIsVerified] &&
        [self.sceneController respondsToSelector:@selector(cvlpRequestVerificationSignal:)];
}

- (BOOL)isVerificationSignalProbeAvailable {
    return [self verificationSignalRequestIsReady] && !self.verificationSignalProbeUsed;
}

- (BOOL)nativeSignalDiagnosticIdentityIsVerified {
#if CVLP_HAS_FRAMEWORK_GUEST_VALIDATOR
    NSDictionary *host = NSBundle.mainBundle.infoDictionary;
    id enabled = host[@"CVNativeSignalDiagnosticEnabled"];
    if (!enabled || CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID() ||
        ![enabled boolValue] || ![host[@"CVLPFrameworkGuestMode"] boolValue] ||
        ![host[@"CFBundleVersion"] isEqual:@"24"] ||
        ![host[@"CVNativeIntegrationStage"] isEqual:@"private-tiktok47-integration-24"] ||
        ![host[@"CVNativeGuestKind"] isEqual:@"tiktok47"] ||
        ![self.targetBundleIdentifier isEqualToString:@"cvlp-immutable-framework"] ||
        ![self.targetDataUUID isEqualToString:@"integration-native-24"]) return NO;
    NSURL *guest = CVLPFrameworkGuestURL(NSBundle.mainBundle.bundleURL);
    if (!guest) return NO;
    NSDictionary *descriptor = CVLPGuestPropertyList(
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"CVLPFrameworkGuest.plist"], 64 * 1024);
    NSDictionary *info = CVLPGuestPropertyList([guest.path stringByAppendingPathComponent:@"Info.plist"], 1024 * 1024);
    return [descriptor[@"bundleIdentifier"] isEqual:@"com.zhiliaoapp.musically"] &&
        [descriptor[@"bundleVersion"] isEqual:@"470044"] &&
        [descriptor[@"executable"] isEqual:@"NativeGuest"] &&
        [info[@"CFBundleShortVersionString"] isEqual:@"47.0.0"];
#else
    return NO;
#endif
}

- (BOOL)nativeSignalDiagnosticRequestIsReady {
    NSAssert(NSThread.isMainThread, @"Native signal diagnostic must run on main");
    return self.started && !self.revoked && !self.sceneEnded && self.sceneController &&
        self.sceneController.cvlpBeginCompleted && self.sceneController.cvlpObservedPID > 0 &&
        self.sceneController.cvlpObservedPID == self.observedPID &&
        self.sceneController.cvlpNativeSignalDiagnosticTargetVerified &&
        [self nativeSignalDiagnosticIdentityIsVerified] &&
        [self.sceneController respondsToSelector:@selector(cvlpRequestNativeSignalDiagnostic:)];
}

- (BOOL)isNativeSignalDiagnosticAvailable {
    return [self nativeSignalDiagnosticRequestIsReady] && !self.nativeSignalDiagnosticStopAttempted;
}

- (BOOL)requestNativeSignalDiagnostic:(int)signal {
    NSAssert(NSThread.isMainThread, @"Native signal diagnostic must run on main");
    if (signal == SIGSTOP) {
        if (!self.isNativeSignalDiagnosticAvailable) {
            CVLPLivenessSample unavailable = {0};
            [self recordDiagnosticPhase:@"reject" reason:@"stop-not-ready" sample:unavailable hasSample:NO];
            return NO;
        }
        self.nativeSignalDiagnosticStopAttempted = YES;
        CVLPLivenessSample before = CVLPSampleLiveness((pid_t)self.sceneController.cvlpObservedPID);
        [self recordDiagnosticPhase:@"STOP" reason:@"before" sample:before hasSample:YES];
        if (!CVLPProcessPresenceObserved(before)) {
            [self recordDiagnosticPhase:@"STOP" reason:@"before-unproved" sample:before hasSample:YES];
            [self recordDiagnosticPhase:@"reject" reason:@"stop-unproved" sample:before hasSample:YES];
            [self recordDiagnosticPhase:@"STOP" reason:@"after-rejected" sample:before hasSample:YES];
            return NO;
        }
        BOOL submitted = [self.sceneController cvlpRequestNativeSignalDiagnostic:signal];
        self.nativeSignalDiagnosticStopSubmitted = submitted;
        CVLPLivenessSample after = CVLPSampleLiveness((pid_t)self.sceneController.cvlpObservedPID);
        [self recordDiagnosticPhase:@"STOP" reason:(submitted ? @"after-submitted" : @"after-rejected")
                             sample:after hasSample:YES];
        if (!submitted) [self recordDiagnosticPhase:@"reject" reason:@"scene-gate" sample:after hasSample:YES];
        return submitted;
    }
    if (signal == SIGCONT) {
        if (!self.nativeSignalDiagnosticStopSubmitted) {
            CVLPLivenessSample unavailable = {0};
            [self recordDiagnosticPhase:@"reject" reason:@"cont-not-paused" sample:unavailable hasSample:NO];
            return NO;
        }
        if (self.nativeSignalDiagnosticContinueAttempted) {
            CVLPLivenessSample unavailable = {0};
            [self recordDiagnosticPhase:@"reject" reason:@"cont-repeated" sample:unavailable hasSample:NO];
            return NO;
        }
        if (![self nativeSignalDiagnosticRequestIsReady]) {
            CVLPLivenessSample unavailable = {0};
            [self recordDiagnosticPhase:@"reject" reason:@"cont-not-ready" sample:unavailable hasSample:NO];
            return NO;
        }
        self.nativeSignalDiagnosticContinueAttempted = YES;
        CVLPLivenessSample before = CVLPSampleLiveness((pid_t)self.sceneController.cvlpObservedPID);
        [self recordDiagnosticPhase:@"CONT" reason:@"before" sample:before hasSample:YES];
        if (!CVLPProcessPresenceObserved(before)) {
            [self recordDiagnosticPhase:@"CONT" reason:@"before-unproved" sample:before hasSample:YES];
            [self recordDiagnosticPhase:@"reject" reason:@"cont-unproved" sample:before hasSample:YES];
            [self recordDiagnosticPhase:@"CONT" reason:@"after-rejected" sample:before hasSample:YES];
            return NO;
        }
        BOOL submitted = [self.sceneController cvlpRequestNativeSignalDiagnostic:signal];
        self.nativeSignalDiagnosticContinueSubmitted = submitted;
        CVLPLivenessSample after = CVLPSampleLiveness((pid_t)self.sceneController.cvlpObservedPID);
        [self recordDiagnosticPhase:@"CONT" reason:(submitted ? @"after-submitted" : @"after-rejected")
                             sample:after hasSample:YES];
        if (!submitted) [self recordDiagnosticPhase:@"reject" reason:@"scene-gate" sample:after hasSample:YES];
        return submitted;
    }
    CVLPLivenessSample unavailable = {0};
    [self recordDiagnosticPhase:@"reject" reason:@"invalid-signal" sample:unavailable hasSample:NO];
    return NO;
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
    CVLPLivenessSample unavailable = {0};
    [self recordDiagnosticPhase:@"revoke" reason:@"explicit" sample:unavailable hasSample:NO];
    [self removeHostLifecycleObservers];
    self.terminationHandler = nil;
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
    diagnostics = [diagnostics stringByAppendingFormat:
        @"\nNative pause diagnostic v2: STOP attempted=%d submitted=%d; CONT attempted=%d submitted=%d; sceneEnded=%d unexpected=%d; suspension/media stop/resumption unproved; real verification hold disabled",
        self.nativeSignalDiagnosticStopAttempted, self.nativeSignalDiagnosticStopSubmitted,
        self.nativeSignalDiagnosticContinueAttempted, self.nativeSignalDiagnosticContinueSubmitted,
        self.sceneEnded, self.unexpectedSceneExitObserved];
    NSString *eventRing = self.diagnosticEvents.count > 0 ?
        [self.diagnosticEvents componentsJoinedByString:@"\n"] : @"empty";
    diagnostics = [diagnostics stringByAppendingFormat:
        @"\nNative diagnostic event ring (newest 48; %@):\n%@", @(self.diagnosticEvents.count), eventRing];
    NSString *sceneTrace = self.sceneController.cvlpLifecycleTraceSummary ?: @"unavailable";
    diagnostics = [diagnostics stringByAppendingFormat:@"\nExtension lifecycle trace (bounded):\n%@", sceneTrace];
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
    if (self.revoked || self.sceneEnded) return;
    if (error) {
        self.launchResult = @"launch failed";
        [self deliverCompletion:NO];
        return;
    }
    self.observedPID = vc.pid;
    self.launchResult = vc.pid > 0 ? @"extension launched" : @"launch PID unavailable";
    [self deliverCompletion:vc.pid > 0];
}

- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    NSAssert(NSThread.isMainThread, @"Scene delegate must run on main");
    if (self.sceneEnded) return;
    self.sceneEnded = YES;
    if (!self.revoked) {
        self.unexpectedSceneExitObserved = YES;
        CVLPLivenessSample sample = CVLPSampleLiveness((pid_t)vc.cvlpObservedPID);
        [self recordDiagnosticPhase:@"scene" reason:@"unexpected-exit" sample:sample hasSample:YES];
        self.launchResult = @"scene ended";
        [self deliverUnexpectedTerminationIfReady];
        [self deliverCompletion:NO];
    }
    [self observeExit];
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    if (self.revoked || self.sceneEnded) return;
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
    if (self.revoked || self.sceneEnded || !vc.presenter) return;
    settings.interruptionPolicy = 0;
    [vc.presenter.scene updateSettings:settings withTransitionContext:context completion:nil];
}

@end
