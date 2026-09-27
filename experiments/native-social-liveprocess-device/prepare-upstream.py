"""Apply the bounded synthetic device fixture to the pinned disposable upstream tree.

This is a build-time adapter, never a production CalcVault source transformation.
Every replacement requires an exact anchor and fails on upstream drift.
"""

import argparse
from pathlib import Path
import shutil
import subprocess

PIN = "e370a92dfc03ce109ebce00ed4a7cfc64ad1c801"


def replace(root, name, before, after):
    path = root / name
    text = path.read_text(encoding="utf-8")
    if text.count(before) != 1:
        raise SystemExit(f"Expected exactly one anchor in {name}: {before[:70]!r}")
    path.write_text(text.replace(before, after), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    root = args.source.resolve()
    fixture = Path(__file__).resolve().parent
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if head != PIN:
        raise SystemExit("Upstream revision mismatch")
    for name in ("CVLPProbe.h", "CVLPProbe.m", "CVLPKeychainIdentity.h"):
        shutil.copy2(fixture / name, root / "LiveContainer" / name)
    replace(root, "LiveContainer/LCSharedUtils.h", "@import Foundation;", '@import Foundation;\n#import "CVLPProbe.h"')
    replace(root, "LiveContainer/LCSharedUtils.m", '#import "LCSharedUtils.h"', '#import "LCSharedUtils.h"\n#import "CVLPProbe.m"')
    replace(root, "LiveContainer/LCSharedUtils.m", "+ (NSString*) teamIdentifier {", '''+ (NSString*) teamIdentifier {
#if TARGET_OS_SIMULATOR
    return @"AAAAA11111";
#endif''')
    # A dedicated synthetic App Group avoids exposing SideStore's App Group/certificate store.
    shared_path = root / "LiveContainer/LCSharedUtils.m"
    shared = shared_path.read_text(encoding="utf-8")
    start = shared.index("+ (NSString *)appGroupID {")
    end = shared.index("+ (NSURL*) appGroupPath {", start)
    shared = shared[:start] + '''+ (NSString *)appGroupID {
#if TARGET_OS_SIMULATOR
    return @"group.com.jaylintaylor.calcvault.nativeprobe";
#else
    void *task = SecTaskCreateFromSelf(NULL);
    CFTypeRef value = task ? SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL) : NULL;
    if (task) CFRelease(task);
    NSArray *groups = value ? CFBridgingRelease(value) : nil;
    return [groups isKindOfClass:NSArray.class] && groups.count == 1 ? groups.firstObject : @"MissingSyntheticAppGroup";
#endif
}

''' + shared[end:]
    shared_path.write_text(shared, encoding="utf-8")
    replace(root, "LiveContainer/LCSharedUtils.m", '''    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
    return [nud objectForKey:@"LCCertificatePassword"];''', '    return nil; // The synthetic fixture never imports a signing certificate.')
    app = root / "LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift"
    app.write_text('''import SwiftUI

@main
struct LiveContainerSwiftUIApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { CVLPHostView() }
    }
}

''' + (fixture / "CVLPHostView.swift").read_text(encoding="utf-8")
        + "\n" + (fixture / "CVLPKeychainMigrationFixture.swift").read_text(encoding="utf-8")
        + "\n" + (fixture.parent.parent / "CalcVault/Security/KeychainGroupMigration.swift").read_text(encoding="utf-8"), encoding="utf-8")

    scene = root / "MultitaskSupport/AppSceneViewController.m"
    text = scene.read_text(encoding="utf-8")
    start = text.index("    NSURL *docURL = ")
    end = text.index("    item.userInfo = userInfo;", start)
    text = text[:start] + '''    // Research policy: only this fixture bundle and its own data folder are granted.
    // The broad Documents grant and shared Tweaks grant are deliberately absent.
    if (![bundleId isEqualToString:@"org.example.syntheticnativeguest.app"] ||
        ![dataUUID isEqualToString:@"synthetic-liveprocess-device"]) {
        [delegate appSceneVC:self didInitializeWithError:[NSError errorWithDomain:@"CVLPProbe" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Unexpected synthetic guest selection."}]];
        return nil;
    }
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSArray *allowed = @[
        [docURL URLByAppendingPathComponent:@"Applications/org.example.syntheticnativeguest.app"],
        [docURL URLByAppendingPathComponent:@"Data/Application/synthetic-liveprocess-device"]
    ];
    for (NSURL *url in allowed) {
        NSError *bookmarkError = nil;
        NSData *data = [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];
        if (!data) {
            [delegate appSceneVC:self didInitializeWithError:bookmarkError ?: [NSError errorWithDomain:@"CVLPProbe" code:2 userInfo:nil]];
            return nil;
        }
        [bookmarks addObject:data];
    }
    userInfo[@"syntheticBoundaryContext"] = [CVLPProbe launchInfo];
''' + text[end:]
    scene.write_text(text, encoding="utf-8")
    replace(root, "LiveProcess/main.m", '#import "../LiveContainer/utils.h"', '#import "../LiveContainer/utils.h"\n#import "../LiveContainer/CVLPProbe.h"')
    replace(root, "LiveProcess/main.m", '    NSCAssert(appInfo, @"Failed to retrieve app info");', '''    NSCAssert(appInfo, @"Failed to retrieve app info");
    NSDictionary *probeInfo = appInfo[@"syntheticBoundaryContext"];
    if (![probeInfo isKindOfClass:NSDictionary.class]) return 90;
    [CVLPProbe acceptLaunchInfo:probeInfo];
    [CVLPProbe recordStage:@"pre-bookmark"];''')
    replace(root, "LiveProcess/main.m", '    NSLog(@"Retrieved app info: %@", appInfo);', '    NSLog(@"CVLP_DEVICE_EXTENSION_STARTED");')
    replace(root, "LiveProcess/main.m", '        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];', '''        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];
        if (!access || error) {
            NSLog(@"CVLP_DEVICE_BOOKMARK_FAILED");
            return 92;
        }''')
    replace(root, "LiveProcess/main.m", '    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {', '''    if (bookmarks.count != 2) return 93;
    [CVLPProbe recordStage:@"post-bookmark"];
    NSLog(@"CVLP_LOADER bookmarks active; entering bootstrap");
    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {''')
    replace(root, "LiveContainer/LCBootstrap.m", '    if (!LCSharedUtils.certificatePassword && !isSideStore) {', '''    BOOL syntheticPresignedGuest = NO;
    NSString *syntheticSignedPayloadPath = nil;
    if (isLiveProcess && [selectedApp isEqualToString:@"org.example.syntheticnativeguest.app"]) {
        NSURL *containingBundle = lcMainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSURL *embedded = [containingBundle URLByAppendingPathComponent:@"Frameworks/SyntheticNativeGuestPayload.dylib"];
        NSString *staged = [NSString stringWithFormat:@"%s/Documents/Applications/org.example.syntheticnativeguest.app/Frameworks/SyntheticNativeGuestPayload.dylib", getenv("LC_HOME_PATH")];
        NSData *embeddedBytes = [NSData dataWithContentsOfURL:embedded options:NSDataReadingMappedIfSafe error:nil];
        NSData *stagedBytes = [NSData dataWithContentsOfFile:staged options:NSDataReadingMappedIfSafe error:nil];
        syntheticPresignedGuest = embeddedBytes.length > 0 && [embeddedBytes isEqualToData:stagedBytes];
        if (!syntheticPresignedGuest) return @"Synthetic payload differs from the embedded signed copy.";
        syntheticSignedPayloadPath = embedded.path;
        NSLog(@"CVLP_LOADER embedded and staged payload bytes match");
    }
    // This exact embedded library was already signed by SideStore with the host.
    // OS code-signature validation at dlopen remains enabled; no JIT/signing keys are needed here.
    if (!syntheticPresignedGuest && !LCSharedUtils.certificatePassword && !isSideStore) {''')
    replace(root, "LiveContainer/LCBootstrap.m", '''    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;''', '''    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    if (!isLiveProcess || ![selectedApp isEqualToString:@"org.example.syntheticnativeguest.app"] ||
        ![guestAppInfo[@"LCSyntheticGuestExecutable"] isEqualToString:@"Frameworks/SyntheticNativeGuestPayload.dylib"] ||
        !syntheticPresignedGuest || syntheticSignedPayloadPath.length == 0) {
        return @"Only the pre-signed synthetic LiveProcess payload is permitted.";
    }
    // The Documents copy is verified as data, but the extension cannot mmap it as executable code on device.
    // Load the same prepatched, SideStore-signed library from the immutable containing app bundle.
    appExecPath = strdup(syntheticSignedPayloadPath.fileSystemRepresentation);
    NSLog(@"CVLP_LOADER selecting signed bundle payload");
    *path = appExecPath;''')
    replace(root, "LiveContainer/LCBootstrap.m", '    NUDGuestHooksInit();', '    NSLog(@"CVLP_LOADER installing guest hooks");\n    NUDGuestHooksInit();')
    replace(root, "LiveContainer/LCBootstrap.m", '        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);', '''        NSLog(@"CVLP_LOADER entering dlopen");
        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
        NSLog(@"CVLP_LOADER dlopen returned handle=%d", appHandle != NULL);''')
    replace(root, "LiveContainer/LCBootstrap.m", 'static void exceptionHandler(NSException *exception) {', 'static void exceptionHandler(NSException *exception) {\n    NSLog(@"CVLP_EXCEPTION %@", exception.reason);')
    replace(root, "LiveContainer/LCBootstrap.m", '        ![appBundle loadAndReturnError:&error]', '        NO /* The exact signed payload was already loaded by dlopen above. */')
    replace(root, "LiveContainer/LCBootstrap.m", '    bool isJitEnabled = checkJITEnabled();', '    bool isJitEnabled = false; // This fixture must prove the pre-signed route without JIT/library-validation bypass.')
    replace(root, "LiveContainer/LCBootstrap.m", '    // Go!\n', '    [CVLPProbe recordStage:@"post-loader"];\n\n    // Go!\n')
    replace(root, "LiveContainer/LCBootstrap.m", '    NSString* lastLaunchDataUUID;', '''    if (!isLiveProcess) {
        // A reused disposable install must always show the host test screen.
        selectedApp = nil;
        selectedContainer = nil;
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    }
    NSString* lastLaunchDataUUID;''')
    replace(root, "LiveContainer/LCBootstrap.m", 'int LiveContainerMain(int argc, char *argv[]) {', '''int LiveContainerMain(int argc, char *argv[]) {
#if TARGET_OS_SIMULATOR
    // Build-time prepatch helper; unavailable in the device binary.
    const char *prepatchPath = getenv("CVLP_PREPATCH_PATH");
    if (prepatchPath && prepatchPath[0]) {
        __block BOOL patched = NO;
        __block int result = -1;
        NSString *error = LCParseMachO(prepatchPath, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            if (header->cputype == CPU_TYPE_ARM64) {
                result = LCPatchExecSlice(path, header, false);
                patched = YES;
            }
        });
        NSString *status = patched && !error && result == 0 ? @"PATCHED" : @"FAILED";
        NSString *diagnostic = [NSString stringWithFormat:@"slice=%d flags=%d parseError=%d", patched, result, error != nil];
        [diagnostic writeToFile:[NSString stringWithFormat:@"%s.flags", prepatchPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [status writeToFile:[NSString stringWithFormat:@"%s.result", prepatchPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return [status isEqualToString:@"PATCHED"] ? 0 : 94;
    }
#endif''')
    replace(root, "LiveContainer/Tweaks/Dyld.m", 'void DyldHookLoadableIntoProcess(void) {', '''void DyldHookLoadableIntoProcess(void) {
#if TARGET_OS_SIMULATOR
    return; // The established simulator loader fixture needs no dyld binary patch.
#endif''')
    print("Prepared pinned synthetic LiveProcess device fixture")


if __name__ == "__main__":
    main()
