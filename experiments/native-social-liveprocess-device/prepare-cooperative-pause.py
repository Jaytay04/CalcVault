"""Opt-in cooperative media control on the prepared Build 24 disposable tree.

No new app, extension, entitlement, background mode, or guest data directory.
All changes are planned before writes; upstream anchor drift fails visibly.
"""
import argparse
from pathlib import Path
import shutil


def once(source, before, after):
    if source.count(before) != 1:
        raise ValueError('cooperative_anchor_drift')
    return source.replace(before, after)


def transform(scene, extension):
    if 'CVLPCooperativePause.m' in scene or 'CVLPCooperativePause.m' in extension:
        raise ValueError('cooperative_already_prepared')
    if 'integration-native-24' not in scene or 'integration-native-24' not in extension:
        raise ValueError('cooperative_requires_build24')
    scene = once(scene, '#import "../LiveContainer/CVLPLiveness.h"',
                 '#import "../LiveContainer/CVLPLiveness.h"\n#import "../LiveContainer/CVLPCooperativePause.m"')
    scene = once(scene, '@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;',
                 '''@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;
@property(nonatomic) BOOL cvlpCooperativePauseTargetVerified;
@property(nonatomic, strong) CVLPCooperativePauseClient *cvlpMediaControl;
- (BOOL)cvlpCooperativePauseAvailable;
- (void)cvlpPauseMediaWithReply:(void (^)(BOOL))reply;
- (void)cvlpResumeMediaWithReply:(void (^)(BOOL))reply;''')
    scene = once(scene, '    item.userInfo = userInfo;', '''    id cooperative = NSBundle.mainBundle.infoDictionary[@"CVNativeCooperativePauseEnabled"];
    BOOL cooperativeEnabled = cooperative && CFGetTypeID((__bridge CFTypeRef)cooperative) == CFBooleanGetTypeID() &&
        [cooperative boolValue];
    if (cooperativeEnabled) {
        NSDictionary *host = NSBundle.mainBundle.infoDictionary;
        if (![host[@"CFBundleVersion"] isEqual:@"24"] ||
            ![host[@"CVNativeIntegrationStage"] isEqual:@"private-tiktok47-integration-24"] ||
            ![host[@"CVNativeGuestKind"] isEqual:@"tiktok47"] ||
            [host[@"CVNativeSignalDiagnosticEnabled"] boolValue]) return nil;
        self.cvlpMediaControl = [CVLPCooperativePauseClient new];
        __weak typeof(self) mediaWeakSelf = self;
        self.cvlpMediaControl.failureHandler = ^{
            typeof(self) owner = mediaWeakSelf;
            if (!owner || owner.cvlpRevoked || owner.cvlpSceneEnded) return;
            [owner appTerminationCleanUp];
        };
        userInfo[@"cvlpMediaHoldEndpoint"] = self.cvlpMediaControl.endpoint;
        userInfo[@"cvlpMediaHoldLaunch"] = self.cvlpMediaControl.launchToken;
    }
    item.userInfo = userInfo;''')
    scene = once(scene, '- (void)cvlpRevoke {', '''- (BOOL)cvlpCooperativePauseAvailable {
    return !self.cvlpRevoked && !self.cvlpSceneEnded && self.cvlpBeginCompleted &&
        self.cvlpCooperativePauseTargetVerified && self.pid == self.cvlpObservedPID &&
        [self.cvlpMediaControl isAvailableForPID:self.cvlpObservedPID];
}

- (void)cvlpPauseMediaWithReply:(void (^)(BOOL))reply {
    NSAssert(NSThread.isMainThread, @"Cooperative media hold must run on main");
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        ![self cvlpCooperativePauseAvailable]) { reply(NO); return; }
    [self.cvlpMediaControl pauseForPID:self.cvlpObservedPID reply:reply];
}

- (void)cvlpResumeMediaWithReply:(void (^)(BOOL))reply {
    NSAssert(NSThread.isMainThread, @"Cooperative media release must run on main");
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        self.cvlpRevoked || self.cvlpSceneEnded || !self.cvlpBeginCompleted ||
        !self.cvlpCooperativePauseTargetVerified || self.pid != self.cvlpObservedPID ||
        !self.cvlpMediaControl) { reply(NO); return; }
    [self.cvlpMediaControl resumeForPID:self.cvlpObservedPID reply:reply];
}

- (void)cvlpRevoke {
    [self.cvlpMediaControl invalidate];''')
    scene = once(scene, '- (void)appTerminationCleanUp {',
                 '- (void)appTerminationCleanUp {\n    [self.cvlpMediaControl invalidate];')
    extension = once(extension, '#import "../LiveContainer/CVLPProbe.h"',
                     '#import "../LiveContainer/CVLPProbe.h"\n#define CVLP_COOPERATIVE_GUEST 1\n#import "../LiveContainer/CVLPCooperativePause.m"')
    extension = once(extension, '    NSCAssert(appInfo, @"Failed to retrieve app info");',
                     '    NSCAssert(appInfo, @"Failed to retrieve app info");\n    if (!CVLPInstallGuestMediaHoldControl(appInfo)) return 104;')
    return scene, extension


def prepare(root):
    root = Path(root).resolve(strict=True)
    scene = root / 'MultitaskSupport/AppSceneViewController.m'
    extension = root / 'LiveProcess/main.m'
    transformed = transform(scene.read_text(encoding='utf-8'), extension.read_text(encoding='utf-8'))
    fixture = Path(__file__).resolve().parent
    names = ('CVLPCooperativePause.h', 'CVLPCooperativePause.m',
             'CVLPCooperativeMediaGate.h', 'CVLPCooperativeMediaGate.m')
    if any(not (fixture / name).is_file() for name in names):
        raise ValueError('cooperative_helper_missing')
    for name in names:
        shutil.copy2(fixture / name, root / 'LiveContainer' / name)
    scene.write_text(transformed[0], encoding='utf-8')
    extension.write_text(transformed[1], encoding='utf-8')
    print('Prepared opt-in cooperative known-media control; physical media proof NOT RUN')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    prepare(parser.parse_args().source)
