"""Synthetic source-anchor and fixture packaging tests; no native execution."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


adapter = module('prepare-framework-guest')
packager = module('package-framework-fixture')


def sources():
    # Only synthetic anchor text; a separate pinned-source replay checks actual upstream anchors.
    return dict(zip(adapter.FILES, [
        '''#import "LCSharedUtils.h"
    BOOL syntheticPresignedGuest = NO;
    old certificate fallback and staged byte comparison
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bundlePath = 0;
    old mutable metadata fallback
    NSBundle *appBundle = [[NSBundle alloc] initWithPathForMainBundle:bundlePath];
    if (!isLiveProcess || ![selectedApp isEqualToString:@"org.example.syntheticnativeguest.app"] ||
    old executable selection
    *path = appExecPath;
    NSLog(@"CVLP_LOADER dlopen returned handle=%d", appHandle != NULL);
    NSLog(@"CVLP_EXCEPTION %@", exception.reason);
    // Setup tweak loader
    old global tweak symlink
    // If JIT is enabled, bypass library validation so we can load arbitrary binaries
    bool isJitEnabled = false;
    [CVLPProbe recordStage:@"post-loader"];
''',
        '''#import "CVLPProbe.h"
Build marker: build19.
    NSURL *guestParent = [documentsURL URLByAppendingPathComponent:@"Applications" isDirectory:YES];
    old code copy
    NSDictionary<NSString *, id> *entitlements = CVLPReadKeychainIdentityEntitlements();
Guest staging: allowlisted bundle metadata and signed payload copied to the synthetic guest folder.
''',
        '#import "CVLPProbe.h"',
        '@"org.example.syntheticnativeguest.app"\n@"synthetic-liveprocess-device"\nunchanged lifecycle sentinel',
        '''@"org.example.syntheticnativeguest.app"
@"synthetic-liveprocess-device"
    NSArray *allowed = @[
        [docURL URLByAppendingPathComponent:@"Applications/org.example.syntheticnativeguest.app"],
        [docURL URLByAppendingPathComponent:@"Data/Application/synthetic-liveprocess-device"]
    ];
unchanged revocation sentinel''',
        '''Build 19
Native lifecycle test · 19
Synthetic data only. Restart the app for each new launch test. The test tone starts only when tapped inside the guest.
unchanged gate sentinel''',
        '''#import "../LiveContainer/CVLPProbe.h"
    NSArray* bookmarks = appInfo[@"bookmarks"];
        access = [bookmarkedUrls[i] startAccessingSecurityScopedResource];
unchanged extension lifecycle sentinel'''
    ]))


class AdapterTests(unittest.TestCase):
    def test_opt_in_transform_preserves_inputs_and_lifecycle(self):
        before = sources()
        copy = dict(before)
        after = adapter.transform(before)
        self.assertEqual(before, copy)
        self.assertEqual(set(after), set(adapter.FILES))
        self.assertIn('unchanged lifecycle sentinel', after[adapter.FILES[3]])
        self.assertIn('unchanged revocation sentinel', after[adapter.FILES[4]])
        self.assertIn('unchanged gate sentinel', after[adapter.FILES[5]])
        self.assertIn('unchanged extension lifecycle sentinel', after[adapter.FILES[6]])

    def test_immutable_selection_no_mutable_metadata_or_code_copy(self):
        after = adapter.transform(sources())
        bootstrap = after[adapter.FILES[0]]
        self.assertIn('!isLiveProcess', bootstrap)
        self.assertIn('bundlePath = frameworkGuestURL.path', bootstrap)
        self.assertIn('bool isJitEnabled = false', bootstrap)
        self.assertIn('dontLoadTweakLoader', bootstrap)
        self.assertNotIn('old certificate fallback', bootstrap)
        self.assertNotIn('old mutable metadata', bootstrap)
        self.assertNotIn('old global tweak symlink', bootstrap)
        self.assertNotIn('old code copy', after[adapter.FILES[1]])
        self.assertIn('S_ISLNK', after[adapter.FILES[1]])
        self.assertNotIn('Applications/org.example', after[adapter.FILES[4]])
        self.assertIn('Data/Application/native-framework-research', after[adapter.FILES[4]])
        extension = after[adapter.FILES[6]]
        self.assertIn('bookmarks.count != 2', extension)
        self.assertIn('isStale || error', extension)
        self.assertLess(extension.index('isEqualToString:expectedBookmarkPaths[i]'),
                        extension.index('startAccessingSecurityScopedResource'))

    def test_drift_fails_without_mutating_inputs(self):
        for index, old in ((0, '#import "LCSharedUtils.h"'), (1, '#import "CVLPProbe.h"'),
                           (4, '    NSArray *allowed = @[')):
            before = sources()
            before[adapter.FILES[index]] = before[adapter.FILES[index]].replace(old, 'drift')
            copy = dict(before)
            with self.assertRaises(ValueError):
                adapter.transform(before)
            self.assertEqual(before, copy)

    def test_repeated_application_and_duplicate_anchors_reject(self):
        with self.assertRaises(ValueError):
            adapter.transform(adapter.transform(sources()))
        before = sources()
        before[adapter.FILES[0]] += '\n#import "LCSharedUtils.h"'
        with self.assertRaises(ValueError):
            adapter.transform(before)


class FrameworkFixtureTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.host = self.root / 'Build/Products/Debug-iphoneos/LiveContainer.app'
        (self.host / 'Frameworks').mkdir(parents=True)
        (self.host / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.jaylintaylor.calcvault'}))
        self.guest = self.root / 'Synthetic.app'
        self.guest.mkdir()
        self.info = {'CFBundleIdentifier': 'org.example.syntheticnativeguest.app', 'CFBundleVersion': '19',
                     'CFBundleExecutable': 'CVLPGuest', 'LCSyntheticGuestExecutable': 'old'}
        (self.guest / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        self.payload = self.root / 'synthetic.dylib'
        self.payload.write_bytes(struct.pack('<4I', 0xfeedfacf, 0x100000c, 0, 6) + b'synthetic')

    def stage(self):
        packager.stage(self.host, self.guest, self.payload)

    def test_framework_descriptor_and_original_payload(self):
        self.stage()
        framework = self.host / 'Frameworks/NativeGuest.framework'
        info = plistlib.loads((framework / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleExecutable'], 'NativeGuest')
        self.assertEqual(info['CFBundlePackageType'], 'FMWK')
        self.assertNotIn('LCSyntheticGuestExecutable', info)
        self.assertEqual((framework / 'NativeGuest').read_bytes(), self.payload.read_bytes())
        self.assertEqual(plistlib.loads((self.guest / 'Info.plist').read_bytes()), self.info)
        contract = plistlib.loads((self.host / 'CVLPFrameworkGuest.plist').read_bytes())
        self.assertEqual(contract['bundleIdentifier'], self.info['CFBundleIdentifier'])
        self.assertEqual(contract['executable'], 'NativeGuest')

    def test_does_not_overwrite_existing_framework(self):
        self.stage()
        with self.assertRaisesRegex(ValueError, 'already_exists'):
            self.stage()

    def test_refuses_real_social_guest(self):
        (self.guest / 'Info.plist').write_bytes(plistlib.dumps(dict(self.info, CFBundleIdentifier='com.zhiliaoapp.musically')))
        with self.assertRaisesRegex(ValueError, 'synthetic_guest_only'):
            self.stage()
        self.assertFalse((self.host / 'CVLPFrameworkGuest.plist').exists())

    def test_requires_prepared_dylib(self):
        self.payload.write_bytes(struct.pack('<4I', 0xfeedfacf, 0x100000c, 0, 2))
        with self.assertRaisesRegex(ValueError, 'expected_prepared_arm64_dylib'):
            self.stage()


if __name__ == '__main__':
    unittest.main()
