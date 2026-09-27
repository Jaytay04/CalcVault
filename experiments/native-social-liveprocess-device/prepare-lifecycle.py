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

@interface AppSceneViewController()
@property(nonatomic) BOOL cvlpRevoked;
@property(nonatomic) BOOL cvlpBeginCompleted;
@property(nonatomic) int cvlpObservedPID;
@property(nonatomic) BOOL cvlpAliveBeforeRevoke;
@property(nonatomic) CVLPLivenessSample cvlpLaunchLivenessSample;
@property(nonatomic) BOOL cvlpHasLaunchLivenessSample;
@property(nonatomic) CVLPLivenessSample cvlpFirstPreRevokeLivenessSample;
@property(nonatomic) BOOL cvlpHasFirstPreRevokeLivenessSample;
@property(nonatomic) CVLPLivenessSample cvlpLatestPreRevokeLivenessSample;
@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;
- (void)cvlpRevoke;
@property int resizeDebounceToken;''')
    replace_once(scene, '#import "UIKitPrivate+MultitaskSupport.h"',
                 '#import "UIKitPrivate+MultitaskSupport.h"\n#import "../LiveContainer/CVLPLiveness.h"\n\nstatic void CVLPLogLivenessSample(NSString *phase, CVLPLivenessSample sample) {\n    NSLog(@"CVLP_LIVENESS phase=%@ pid=%d attempted=%d result=%d errno=%d class=%s", phase, (int)sample.pid, sample.attempted, sample.result, sample.errorNumber, CVLPLivenessClassificationName(sample.classification));\n}')
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
            [weakSelf appTerminationCleanUp];
            if (!weakSelf.cvlpRevoked) [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
        });
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appTerminationCleanUp]; });
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (identifier) {
                self.identifier = identifier;
                self.pid = [self.extension pidForRequestIdentifier:identifier];
                self.cvlpObservedPID = self.pid;
                if (!self.cvlpHasLaunchLivenessSample) {
                    self.cvlpLaunchLivenessSample = CVLPSampleLiveness((pid_t)self.pid);
                    self.cvlpHasLaunchLivenessSample = YES;
                    CVLPLogLivenessSample(@"launch", self.cvlpLaunchLivenessSample);
                }
            }
            dispatch_block_t handleCompletion = ^{
                self.cvlpBeginCompleted = YES;
                if (self.cvlpRevoked) {
                    NSLog(@"CVLP_LIFECYCLE_LATE_COMPLETION_REJECTED");
                    [self cvlpRevoke];
                    return;
                }
                if (identifier) {
                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
                    [delegate appSceneVC:self didInitializeWithError:nil];
                    if (!self.cvlpRevoked) [self setUpAppPresenter];
                } else {
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
    replace_once(scene, '- (void)setUpAppPresenter {', '''- (void)cvlpRevoke {
    NSAssert(NSThread.isMainThread, @"Guest revocation must run on main");
    self.cvlpRevoked = YES;
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
    if (firstAttempt) CVLPLogLivenessSample(@"pre-revoke-first", livenessSample);
    CVLPLogLivenessSample(@"pre-revoke-latest", livenessSample);
    // Liveness uses signal zero and precedes each extension-scoped kill attempt.
    // Missing PID, ESRCH, and EPERM never establish positive pre-revoke liveness.
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
    if (self.cvlpRevoked) return;''')
    for anchor in (
        '- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {',
        '- (void)viewWillLayoutSubviews {',
        '- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {',
        '- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {',
    ):
        replace_once(scene, anchor, anchor + '\n    if (self.cvlpRevoked) return;')
    replace_once(scene, '''    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {''', '''    dispatch_block_t queueBlock = ^{
        if (self.cvlpRevoked) return;
        if(currentDebounceToken != self.resizeDebounceToken) {''')
    print("Prepared synthetic guest lifecycle guard")


if __name__ == "__main__":
    main()
