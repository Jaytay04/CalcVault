"""Opt-in adapter for an immutable framework guest in a disposable research host.

Run AFTER prepare-upstream.py, never on production CalcVault. This only prepares
source; it neither embeds a proprietary guest nor signs/installs/executes one.
"""
import argparse
from pathlib import Path
import subprocess
import framework_geometry
import guest_diagnostics

PIN = 'e370a92dfc03ce109ebce00ed4a7cfc64ad1c801'
FILES = (
    'LiveContainer/LCBootstrap.m', 'LiveContainer/CVLPProbe.m',
    'LiveContainer/LCSharedUtils.h', 'LiveContainer/CVLPGuestSession.m',
    'MultitaskSupport/AppSceneViewController.m',
    'LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift',
    'LiveProcess/main.m',
)
SELECTOR = 'cvlp-immutable-framework'
DATA = 'native-framework-research'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('framework_anchor_drift')
    return text.replace(old, new)


def between(text, first, last, replacement):
    if text.count(first) != 1 or text.count(last) != 1:
        raise ValueError('framework_anchor_drift')
    start, end = text.index(first), text.index(last)
    if end <= start:
        raise ValueError('framework_anchor_order')
    return text[:start] + replacement + text[end:]


def transform(sources):
    """Validate all anchors before writing anything to the disposable tree."""
    result = dict(sources)
    bootstrap = result[FILES[0]]
    bootstrap = once(bootstrap, '#import "LCSharedUtils.h"',
                     '#import "LCSharedUtils.h"\n#import "CVLPFrameworkGuest.h"')
    bootstrap = between(bootstrap, '    BOOL syntheticPresignedGuest = NO;',
                        '    NSFileManager *fm = NSFileManager.defaultManager;', '''    // This variant never falls back to certificates, JIT or a mutable guest app.
    if (!isLiveProcess || ![selectedApp isEqualToString:@"cvlp-immutable-framework"] ||
        ![selectedContainer isEqualToString:@"native-framework-research"]) {
        return @"Only the fixed isolated framework research guest is permitted.";
    }
    NSURL *containingBundle = lcMainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *frameworkGuestURL = CVLPFrameworkGuestURL(containingBundle);
    if (!frameworkGuestURL) return @"Immutable framework guest contract is missing or invalid.";
    // OS validation of every signed image at dlopen remains enabled.
    NSString *frameworkSignedPayloadPath = [frameworkGuestURL URLByAppendingPathComponent:@"NativeGuest"].path;

''')
    bootstrap = between(bootstrap, '    NSString *bundlePath = 0;',
                        '    NSBundle *appBundle = [[NSBundle alloc] initWithPathForMainBundle:bundlePath];', '''    // Main bundle resources and executable-relative dependencies share this root.
    // Do not read Documents/LCAppInfo, fall back to an App Group, or rewrite Info.plist.
    NSString *bundlePath = frameworkGuestURL.path;
    guestAppInfo = @{
        @"LCDataUUID": @"native-framework-research",
        @"dontInjectTweakLoader": @YES,
        @"dontLoadTweakLoader": @YES
    };
    isSharedBundle = false;

''')
    bootstrap = between(bootstrap, '    if (!isLiveProcess || ![selectedApp isEqualToString:@"org.example.syntheticnativeguest.app"] ||',
                        '    *path = appExecPath;', '''    appExecPath = strdup(frameworkSignedPayloadPath.fileSystemRepresentation);
    NSLog(@"CVLP_FRAMEWORK selecting immutable bundle payload");
''')
    bootstrap = between(bootstrap, '    // Setup tweak loader',
                        '    // If JIT is enabled, bypass library validation so we can load arbitrary binaries', '''    // No host-wide Tweaks path, symlink creation or external tweak loader in this route.
    NSString *disabledTweaks = [docPath stringByAppendingPathComponent:@"Data/Application/native-framework-research/Library/DisabledTweaks"];
    setenv("LC_GLOBAL_TWEAKS_FOLDER", disabledTweaks.UTF8String, 1);

''')
    bootstrap = once(bootstrap, '    NSLog(@"CVLP_LOADER dlopen returned handle=%d", appHandle != NULL);',
                     '    NSLog(@"CVLP_LOADER dlopen returned handle=%d", appHandle != NULL);')
    # No raw third-party exception strings in probe logs.
    bootstrap = once(bootstrap, '    NSLog(@"CVLP_EXCEPTION %@", exception.reason);',
                     '    NSLog(@"CVLP_EXCEPTION guest exception observed");')
    result[FILES[0]] = bootstrap

    probe = result[FILES[1]]
    probe = once(probe, '#import "CVLPProbe.h"', '#import "CVLPProbe.h"\n#import "CVLPFrameworkGuest.h"')
    probe = between(probe, '    NSURL *guestParent = [documentsURL URLByAppendingPathComponent:@"Applications" isDirectory:YES];',
                    '    NSDictionary<NSString *, id> *entitlements = CVLPReadKeychainIdentityEntitlements();', '''    NSURL *guestBundleURL = CVLPFrameworkGuestURL(NSBundle.mainBundle.bundleURL);
    if (!guestBundleURL) return @"Immutable framework guest contract is missing or invalid.";
    // Create only the dedicated data path, checking every existing component first.
    NSURL *guestDataURL = documentsURL.URLByResolvingSymlinksInPath;
    for (NSString *part in @[@"Data", @"Application", @"native-framework-research"]) {
        guestDataURL = [guestDataURL URLByAppendingPathComponent:part isDirectory:YES];
        struct stat attributes;
        if (lstat(guestDataURL.fileSystemRepresentation, &attributes) == 0) {
            if (!S_ISDIR(attributes.st_mode) || S_ISLNK(attributes.st_mode)) {
                return @"Guest data path is not an ordinary private directory.";
            }
        } else if (errno != ENOENT || ![fileManager createDirectoryAtURL:guestDataURL
                     withIntermediateDirectories:NO attributes:nil error:&fileError]) {
            return @"Guest data directory could not be prepared.";
        }
    }

''')
    probe = once(probe, 'Guest staging: allowlisted bundle metadata and signed payload copied to the synthetic guest folder.',
                 'Guest selection: fixed immutable framework; no guest code or resources copied into Documents.')
    probe = probe.replace('Build marker: build19.', 'Build marker: build20-framework-diagnostics2.')
    result[FILES[1]] = probe
    result[FILES[2]] = once(result[FILES[2]], '#import "CVLPProbe.h"',
                           '#import "CVLPProbe.h"\n#import "CVLPFrameworkGuest.h"')
    result[FILES[3]] = once(result[FILES[3]], '@"org.example.syntheticnativeguest.app"', '@"' + SELECTOR + '"')
    result[FILES[3]] = once(result[FILES[3]], '@"synthetic-liveprocess-device"', '@"' + DATA + '"')

    scene = result[FILES[4]]
    scene = once(scene, '@"org.example.syntheticnativeguest.app"', '@"' + SELECTOR + '"')
    scene = once(scene, '@"synthetic-liveprocess-device"', '@"' + DATA + '"')
    scene = once(scene, '''    NSArray *allowed = @[
        [docURL URLByAppendingPathComponent:@"Applications/org.example.syntheticnativeguest.app"],
        [docURL URLByAppendingPathComponent:@"Data/Application/synthetic-liveprocess-device"]
    ];''', '''    NSURL *frameworkGuestURL = CVLPFrameworkGuestURL(NSBundle.mainBundle.bundleURL);
    if (!frameworkGuestURL) {
        [delegate appSceneVC:self didInitializeWithError:[NSError errorWithDomain:@"CVLPProbe" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Immutable framework guest contract is missing or invalid."}]];
        return nil;
    }
    NSArray *allowed = @[
        frameworkGuestURL,
        [docURL URLByAppendingPathComponent:@"Data/Application/native-framework-research"]
    ];''')
    result[FILES[4]] = scene
    app = result[FILES[5]]
    app = app.replace('Build 19', 'Build 20 framework startup diagnostics 2').replace('Native lifecycle test · 19', 'Guest startup test · 20.3')
    app = once(app, 'Synthetic data only. Restart the app for each new launch test. The test tone starts only when tapped inside the guest.',
               'Research only. Do not sign in or enter personal data. Restart the app for each new launch test. Boundary fixtures are synthetic; guest behavior is unverified.')
    result[FILES[5]] = app
    extension = result[FILES[6]]
    extension = once(extension, '#import "../LiveContainer/CVLPProbe.h"',
                     '#import "../LiveContainer/CVLPProbe.h"\n#import "../LiveContainer/CVLPFrameworkGuest.h"')
    extension = once(extension, '    NSArray* bookmarks = appInfo[@"bookmarks"];', '''    NSArray* bookmarks = appInfo[@"bookmarks"];
    if (![bookmarks isKindOfClass:NSArray.class] || bookmarks.count != 2 ||
        ![appInfo[@"selected"] isEqual:@"cvlp-immutable-framework"] ||
        ![appInfo[@"selectedContainer"] isEqual:@"native-framework-research"]) return 93;
    NSURL *hostBundle = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *expectedFramework = CVLPFrameworkGuestURL(hostBundle);
    NSString *hostHome = appInfo[@"lcHomePath"];
    if (!expectedFramework || ![hostHome isKindOfClass:NSString.class] || !hostHome.isAbsolutePath) return 93;
    NSString *expectedData = [[hostHome stringByResolvingSymlinksInPath]
        stringByAppendingPathComponent:@"Documents/Data/Application/native-framework-research"];
    NSArray<NSString *> *expectedBookmarkPaths = @[expectedFramework.path, expectedData];''')
    extension = once(extension, '        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];', '''        // Validate each resolved identity before activating its capability.
        if (isStale || error || ![bookmarkedUrls[i].URLByResolvingSymlinksInPath.path
                                  isEqualToString:expectedBookmarkPaths[i]]) return 92;
        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];''')
    result[FILES[6]] = extension
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    root = parser.parse_args().source.resolve(strict=True)
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if head != PIN:
        raise SystemExit('upstream_revision_mismatch')
    sources = {name: (root / name).read_text(encoding='utf-8') for name in FILES + ('LiveContainer/CVLPProbe.h',)}
    changed = guest_diagnostics.transform(framework_geometry.transform(transform(sources)))
    helper = Path(__file__).with_name('CVLPFrameworkGuest.h').read_text(encoding='utf-8')
    if (root / 'LiveContainer/CVLPFrameworkGuest.h').exists():
        raise SystemExit('framework_adapter_already_present')
    diagnostics_header = Path(__file__).with_name('CVLPGuestDiagnostics.h').read_text(encoding='utf-8')
    if (root / 'LiveContainer/CVLPGuestDiagnostics.h').exists():
        raise SystemExit('guest_diagnostics_already_present')
    for name, text in changed.items():
        (root / name).write_text(text, encoding='utf-8')
    (root / 'LiveContainer/CVLPFrameworkGuest.h').write_text(helper, encoding='utf-8')
    (root / 'LiveContainer/CVLPGuestDiagnostics.h').write_text(diagnostics_header, encoding='utf-8')
    print('Prepared opt-in immutable framework research loader; guest package and fresh signing still required')


if __name__ == '__main__':
    main()
