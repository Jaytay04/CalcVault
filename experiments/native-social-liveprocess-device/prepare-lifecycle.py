"""Patch the disposable pinned LiveContainer tree for synthetic lifecycle testing."""

import argparse
from pathlib import Path


def replace_once(path: Path, before: str, after: str) -> None:
    source = path.read_text(encoding="utf-8")
    if source.count(before) != 1:
        raise SystemExit(f"Lifecycle anchor drift in {path.name}: {before[:75]!r}")
    path.write_text(source.replace(before, after), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    root = parser.parse_args().source.resolve()
    scene = root / "MultitaskSupport/AppSceneViewController.m"
    host_utils = root / "LiveContainerSwiftUI/Utilities/LCUtils.m"
    shared = root / "LiveContainer/LCSharedUtils.m"
    for required in (scene, host_utils, shared, root / "LiveContainer/CVLPGuestSession.m", root / "LiveContainer/CVLPLiveness.h"):
        if not required.is_file():
            raise SystemExit(f"Prepared source missing: {required}")
    if '#import "CVLPGuestSession.m"' in shared.read_text(encoding="utf-8"):
        raise SystemExit("Guest session implementation must not compile in LCSharedUtils.m")
    if 'CVLPGuestSession.m' in host_utils.read_text(encoding="utf-8"):
        raise SystemExit("Guest session implementation is already imported in LCUtils.m")
    if 'cvlpRevoked' in scene.read_text(encoding="utf-8"):
        raise SystemExit("Scene lifecycle guard is already present")
    replace_once(host_utils, '#import "LCUtils.h"',
                 '#import "LCUtils.h"\n#import "../../LiveContainer/CVLPGuestSession.m"')
    replace_once(scene, '@interface AppSceneViewController()\n@property int resizeDebounceToken;',
                 '''@interface NSExtension (CVLPCancellation)
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
@end

@interface NSExtension (CVLPVerificationSignal)
- (void)_kill:(int)signal;
@end

@interface AppSceneViewController()
- (BOOL)cvlpRequestVerificationSignal:(int)signal;
@property(nonatomic) BOOL cvlpRevoked;
@property(atomic) BOOL cvlpSceneEnded;
@property(nonatomic) BOOL cvlpSyntheticTargetVerified;
@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;
- (BOOL)cvlpRequestNativeSignalDiagnostic:(int)signal;
@property(nonatomic) BOOL cvlpBeginCompleted;
@property(nonatomic) int cvlpObservedPID;
@property(nonatomic) BOOL cvlpAliveBeforeRevoke;
@property(nonatomic) CVLPLivenessSample cvlpLaunchLivenessSample;
@property(nonatomic) BOOL cvlpHasLaunchLivenessSample;
@property(nonatomic) CVLPLivenessSample cvlpFirstPreRevokeLivenessSample;
@property(nonatomic) BOOL cvlpHasFirstPreRevokeLivenessSample;
@property(nonatomic) CVLPLivenessSample cvlpLatestPreRevokeLivenessSample;
@property(nonatomic) CVLPLivenessSample cvlpProcessGroupPresenceSample;
@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;
- (void)cvlpRevoke;
@property int resizeDebounceToken;
@property(nonatomic, strong) NSMutableArray<NSString *> *cvlpLifecycleTrace;
@property(nonatomic) NSTimeInterval cvlpTraceStartUptime;
- (void)cvlpTracePhase:(NSString *)phase reason:(NSString *)reason;
- (NSString *)cvlpLifecycleTraceSummary;''')
    replace_once(scene, '#import "UIKitPrivate+MultitaskSupport.h"',
                 '''#import "UIKitPrivate+MultitaskSupport.h"
#import "../LiveContainer/CVLPLiveness.h"
#import <signal.h>

static void CVLPLogLivenessSample(NSString *phase, CVLPLivenessSample sample) {
    NSLog(@"CVLP_LIVENESS phase=%@ pid=%d attempted=%d result=%d errno=%d class=%s pgid=%d pgidErrno=%d pgidClass=%s",
        phase, (int)sample.pid, sample.attempted, sample.result, sample.errorNumber,
        CVLPLivenessClassificationName(sample.classification), (int)sample.groupResult,
        sample.groupErrorNumber, CVLPLivenessClassificationName(sample.groupClassification));
}''')
    replace_once(scene, '''    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];''', '''    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cvlpTracePhase:@"extension" reason:@"cancellation"];
            [weakSelf appTerminationCleanUp];
            [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
        });
    }];
    [self cvlpTracePhase:@"extension" reason:@"interruption-initial-registration"];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cvlpTracePhase:@"extension" reason:@"interruption-initial-callback"];
            [weakSelf appTerminationCleanUp];
        });
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (identifier) {
                self.identifier = identifier;
                self.pid = [self.extension pidForRequestIdentifier:identifier];
                self.cvlpObservedPID = self.pid;
                if (self.pid <= 0) [self cvlpTracePhase:@"process" reason:@"pid-unavailable"];
                if (!self.cvlpHasLaunchLivenessSample) {
                    self.cvlpLaunchLivenessSample = CVLPSampleLiveness((pid_t)self.pid);
                    self.cvlpHasLaunchLivenessSample = YES;
                    CVLPLogLivenessSample(@"launch", self.cvlpLaunchLivenessSample);
                }
            }
            dispatch_block_t handleCompletion = ^{
                self.cvlpBeginCompleted = YES;
                if (self.cvlpRevoked || self.cvlpSceneEnded) {
                    NSLog(@"CVLP_LIFECYCLE_LATE_COMPLETION_REJECTED");
                    [self cvlpRevoke];
                    return;
                }
                if (identifier) {
                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
                    [delegate appSceneVC:self didInitializeWithError:nil];
                    if (!self.cvlpRevoked) [self setUpAppPresenter];
                } else {
                    [self cvlpTracePhase:@"process" reason:@"missing-process-callback"];
                    NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
                    [delegate appSceneVC:self didInitializeWithError:error];
                }
            };
#if TARGET_OS_SIMULATOR
            if ([NSProcessInfo.processInfo.environment[@"CVLP_DELAY_EXTENSION_COMPLETION"] isEqualToString:@"1"]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), handleCompletion);
                return;
            }
#endif
            handleCompletion();
        });
    }];''')
    replace_once(scene, '''    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];''', '''    [self cvlpTracePhase:@"extension" reason:@"interruption-presenter-registration"];
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cvlpTracePhase:@"extension" reason:@"interruption-presenter-callback"];
            [weakSelf appTerminationCleanUp];
        });
    }];''')
    replace_once(scene, '- (void)setUpAppPresenter {', '''- (void)cvlpTracePhase:(NSString *)phase reason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cvlpTracePhase:phase reason:reason]; });
        return;
    }
    NSDictionary<NSString *, NSArray<NSString *> *> *allowlist = @{
        @"extension": @[@"cancellation", @"interruption-initial-registration",
                         @"interruption-initial-callback", @"interruption-presenter-registration",
                         @"interruption-presenter-callback"],
        @"cleanup": @[@"trigger", @"process-not-running"],
        @"process": @[@"pid-unavailable", @"missing-process-callback"]
    };
    NSArray<NSString *> *reasons = allowlist[phase];
    NSString *safePhase = reasons ? phase : @"other";
    NSString *safeReason = reasons && [reasons containsObject:reason] ? reason : @"other";
    if (!self.cvlpLifecycleTrace) {
        self.cvlpLifecycleTrace = [NSMutableArray arrayWithCapacity:32];
        self.cvlpTraceStartUptime = NSProcessInfo.processInfo.systemUptime;
    }
    NSTimeInterval elapsed = MAX(0, NSProcessInfo.processInfo.systemUptime - self.cvlpTraceStartUptime);
    unsigned long long elapsedMilliseconds = (unsigned long long)(elapsed * 1000.0);
    NSString *entry = [NSString stringWithFormat:@"t=%llums phase=%@ reason=%@ pid=%d",
                       elapsedMilliseconds, safePhase, safeReason, self.cvlpObservedPID];
    [self.cvlpLifecycleTrace addObject:entry];
    if (self.cvlpLifecycleTrace.count > 32) [self.cvlpLifecycleTrace removeObjectAtIndex:0];
    NSLog(@"CVLP_EXTENSION_TRACE %@", entry);
}

- (NSString *)cvlpLifecycleTraceSummary {
    return [self.cvlpLifecycleTrace componentsJoinedByString:@"\\n"] ?: @"empty";
}

- (BOOL)cvlpRequestVerificationSignal:(int)signal {
    NSAssert(NSThread.isMainThread, @"Verification signal probe must run on main");
    if (signal != SIGSTOP && signal != SIGCONT) return NO;
    if (self.cvlpRevoked || self.cvlpSceneEnded || !self.cvlpSyntheticTargetVerified || !self.cvlpBeginCompleted ||
        self.cvlpObservedPID <= 0 || !self.identifier || !self.extension || !self.presenter ||
        !self.viewIfLoaded || !self.view.window) return NO;
    if (![self.extension respondsToSelector:@selector(_kill:)]) return NO;
    [self.extension _kill:signal];
    NSLog(@"CVLP_VERIFICATION_SIGNAL_REQUEST_SUBMITTED signal=%d; suspension and media stop unproved", signal);
    return YES;
}

- (BOOL)cvlpRequestNativeSignalDiagnostic:(int)signal {
    NSAssert(NSThread.isMainThread, @"Native signal diagnostic must run on main");
    if (signal != SIGSTOP && signal != SIGCONT) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    if (self.cvlpRevoked || self.cvlpSceneEnded || !self.cvlpNativeSignalDiagnosticTargetVerified || !self.cvlpBeginCompleted ||
        self.cvlpObservedPID <= 0 || self.pid != self.cvlpObservedPID ||
        !self.identifier || !self.extension || !self.presenter ||
        !self.viewIfLoaded || !self.view.window) return NO;
    if (![self.extension respondsToSelector:@selector(_kill:)]) return NO;
    CVLPLivenessSample bridgeSample = CVLPSampleLiveness((pid_t)self.cvlpObservedPID);
    if (!CVLPProcessPresenceObserved(bridgeSample)) {
        NSLog(@"CVLP_NATIVE_PAUSE_REQUEST_REJECTED reason=process-presence-unproved class=%s",
              CVLPLivenessClassificationName(bridgeSample.groupClassification));
        return NO;
    }
    @try { [self.extension _kill:signal]; }
    @catch (NSException *exception) {
        NSLog(@"CVLP_NATIVE_PAUSE_REQUEST_REJECTED reason=selector-exception");
        return NO;
    }
    NSLog(@"CVLP_NATIVE_PAUSE_REQUEST_SUBMITTED signal=%d; suspension/media stop/resumption unproved", signal);
    return YES;
}

- (void)cvlpRevoke {
    NSAssert(NSThread.isMainThread, @"Guest revocation must run on main");
    self.cvlpRevoked = YES;
    self.cvlpSceneEnded = YES;
    self.view.hidden = YES;
    self.contentView.hidden = YES;
    self.shouldIgnoreSceneUpdates = YES;
    CVLPLivenessSample livenessSample = CVLPSampleLiveness((pid_t)self.cvlpObservedPID);
    BOOL firstAttempt = self.cvlpPreRevokeAttemptCount == 0;
    if (firstAttempt) {
        self.cvlpFirstPreRevokeLivenessSample = livenessSample;
        self.cvlpHasFirstPreRevokeLivenessSample = YES;
    }
    self.cvlpLatestPreRevokeLivenessSample = livenessSample;
    self.cvlpPreRevokeAttemptCount += 1;
    if (livenessSample.classification == CVLPLivenessSuccess) {
        self.cvlpAliveBeforeRevoke = YES;
        NSLog(@"CVLP_LIFECYCLE_ALIVE_BEFORE_REVOKE");
    }
    if (CVLPProcessPresenceObserved(livenessSample)) {
        self.cvlpProcessGroupPresenceSample = livenessSample;
        NSLog(@"CVLP_PROCESS_GROUP_PRESENT_BEFORE_REVOKE");
    }
    if (firstAttempt) CVLPLogLivenessSample(@"pre-revoke-first", livenessSample);
    CVLPLogLivenessSample(@"pre-revoke-latest", livenessSample);
    // Both observations precede the extension-scoped kill. EPERM alone is never
    // positive proof; the separate PID-presence check requires positive getpgid.
    NSLog(@"CVLP_LIFECYCLE_KILL_REQUESTED");
    [self.extension _kill:SIGKILL];
    if (self.identifier && [self.extension respondsToSelector:@selector(cancelExtensionRequestWithIdentifier:)]) {
        [self.extension cancelExtensionRequestWithIdentifier:self.identifier];
    }
    if (self.sceneID) {
        [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
    }
    if (@available(iOS 17.0, *)) [self.hostingController invalidate];
    [self.presenter deactivate];
    [self.presenter invalidate];
    self.presenter = nil;
}

- (void)setUpAppPresenter {
    if (self.cvlpRevoked || self.cvlpSceneEnded) return;''')
    replace_once(scene, '''    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }''', '''    if(!self.isAppRunning) {
        [self cvlpTracePhase:@"cleanup" reason:@"process-not-running"];
        [self appTerminationCleanUp];
    }''')
    replace_once(scene, '''- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {''', '''- (void)appTerminationCleanUp {
    self.cvlpSceneEnded = YES;
    [self cvlpTracePhase:@"cleanup" reason:@"trigger"];
    if(_isAppTerminationCleanUpCalled) {''')
    for anchor in (
        '- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {',
        '- (void)viewWillLayoutSubviews {',
        '- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {',
        '- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {',
    ):
        replace_once(scene, anchor, anchor + '\n    if (self.cvlpRevoked || self.cvlpSceneEnded) return;')
    replace_once(scene, '''    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {''', '''    dispatch_block_t queueBlock = ^{
        if (self.cvlpRevoked || self.cvlpSceneEnded) return;
        if(currentDebounceToken != self.resizeDebounceToken) {''')
    print("Prepared synthetic guest lifecycle guard")


if __name__ == "__main__":
    main()
