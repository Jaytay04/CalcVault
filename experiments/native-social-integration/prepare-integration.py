"""Adapt only a disposable, pinned, framework-mode research source tree.

The CalcVaultKit framework is linked by the UI framework only, never LiveProcess.
No proprietary guest, credential, installation or signing operation occurs here.
"""
import argparse
from pathlib import Path
import subprocess

PIN = 'e370a92dfc03ce109ebce00ed4a7cfc64ad1c801'
APP = 'LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift'
BOOT = 'LiveContainer/LCBootstrap.m'
PROBE = 'LiveContainer/CVLPProbe.m'
PROJECT = 'LiveContainer.xcodeproj/project.pbxproj'
SESSION = 'LiveContainer/CVLPGuestSession.m'
SCENE = 'MultitaskSupport/AppSceneViewController.m'
EXTENSION = 'LiveProcess/main.m'
NAMES = (APP, BOOT, PROBE, PROJECT, SESSION, SCENE, EXTENSION)


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('integration_anchor_drift')
    return text.replace(old, new)


def transform(sources, app):
    result = dict(sources)
    if 'Build 20 framework portrait test 1' not in sources[APP]:
        raise ValueError('expected_portrait_framework_source')
    result[APP] = app
    bootstrap = sources[BOOT]
    start = bootstrap.index('    NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];',
                            bootstrap.index('int LiveContainerMain('))
    finish = bootstrap.index('\n#ifdef DEBUG\nint callAppMain', start)
    # Retain common process initialization and the simulator-only prepatch helper.
    # Remove legacy host restore, cookie copying, self-tweaks, embedded SideStore,
    # shared launch tasks and external URL redirects from this entry path.
    bootstrap = bootstrap[:start] + '''    if (isLiveProcess) {
        NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];
        NSString *selectedContainer = [lcUserDefaults stringForKey:@"selectedContainer"];
        if (![selectedApp isEqualToString:@"cvlp-immutable-framework"] ||
            ![selectedContainer isEqualToString:@"native-framework-research"]) return 96;
        NSSetUncaughtExceptionHandler(&exceptionHandler);
        NSString *error = invokeAppMain(selectedApp, selectedContainer, argc, argv);
        if (error) {
            NSLog(@"CV_INTEGRATION_GUEST_LAUNCH_FAILED");
            NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
            [context cancelRequestWithError:[NSError errorWithDomain:@"CVIntegration" code:1 userInfo:nil]];
            return 97;
        }
        return 0;
    }
    // No guest can run in the host process, regardless of persisted selections.
    void *ui = dlopen("@executable_path/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI", RTLD_LAZY);
    if (!ui) return 98;
    int (*entry)(void) = dlsym(ui, "main");
    if (!entry) return 99;
    return entry();
}
''' + bootstrap[finish:]
    result[BOOT] = bootstrap
    result[PROBE] = once(sources[PROBE], '''#if !TARGET_OS_SIMULATOR
    if (![CVLPMigrationFixture[@"ready"] boolValue]) {
        return @"Synthetic migration did not finish; guest launch blocked.";
    }
#endif''', '''    // The integration controller already checked production credential metadata
    // and the current authenticated session. Do not rerun the historical
    // biometric migration experiment or invent a successful fixture result.
    // Retain the independent synthetic file and Keychain controls below.
    CVLPAppendHostObservation(@"Integration 22: migration fixture not repeated; guest boundary controls remain synthetic.");
    struct stat signingExport;
    NSString *exportPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ALTCertificate.p12"];
    if (lstat(exportPath.fileSystemRepresentation, &signingExport) == 0 || errno != ENOENT) {
        return @"Signing export absence could not be verified; guest launch blocked.";
    }''')
    result[PROBE] = once(result[PROBE], 'Build marker: build20-framework-portrait1.',
                         'Build marker: synthetic-integration-22-authcheck1.')
    # Preserve the original device-only failure condition. Classify which
    # synthetic positive control failed without publishing identities or errors.
    result[PROBE] = once(result[PROBE],
        'return @"Synthetic Keychain fixture setup is inconclusive; device probe stopped before guest launch. See the host report for each control\'s identity status and setup result.";',
        '''return !appIDFixtureReady && !hostOnlyFixtureReady ? @"CV_INTEGRATION_PREP_BOTH_CONTROLS"
            : (!appIDFixtureReady ? @"CV_INTEGRATION_PREP_APP_ID_CONTROL" : @"CV_INTEGRATION_PREP_HOST_ONLY_CONTROL");''')
    linker = '\t\t\t\tOTHER_LDFLAGS = "-Wl,-U,_OBJC_CLASS_$_RBSTarget";'
    project = sources[PROJECT]
    if project.count(linker) != 2:
        raise ValueError('expected_two_ui_framework_configurations')
    result[PROJECT] = project.replace(linker, linker.replace('";', ' -framework CalcVaultKit";') +
        '\n\t\t\t\tFRAMEWORK_SEARCH_PATHS = ("$(inherited)", "$(CV_INTEGRATION_KIT_DIR)", "$(CV_INTEGRATION_KIT_DIR)/PackageFrameworks");' +
        '\n\t\t\t\tSWIFT_INCLUDE_PATHS = ("$(inherited)", "$(CV_INTEGRATION_KIT_DIR)");' +
        '\n\t\t\t\tHEADER_SEARCH_PATHS = ("$(inherited)", "$(CV_INTEGRATION_KIT_DIR)/include");')
    # Do not reuse or mutate the existing private TikTok research data folder.
    # Preserve every exact-path allowlist/bookmark check, changing only its fixed
    # synthetic integration directory consistently across both processes.
    for name, count in ((BOOT, 4), (PROBE, 1), (SESSION, 1), (SCENE, 2), (EXTENSION, 2)):
        if result[name].count('native-framework-research') != count:
            raise ValueError('guest_data_path_anchor_drift')
        result[name] = result[name].replace('native-framework-research', 'integration-synthetic-22')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise SystemExit('upstream_revision_mismatch')
    sources = {name: (root / name).read_text(encoding='utf-8') for name in NAMES}
    prepared = transform(sources, Path(__file__).with_name('IntegrationApp.swift').read_text(encoding='utf-8'))
    for name, data in prepared.items():
        (root / name).write_text(data, encoding='utf-8')
    print('Integration source prepared; synthetic guest only; signing and device tests still required')


if __name__ == '__main__':
    main()
