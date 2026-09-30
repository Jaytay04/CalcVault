"""Synthetic fixture tests for the local Build 23 private guest merger."""

import hashlib
import importlib.util
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent / 'native-social-package-tools'
sys.path.insert(0, str(TOOLS))
import ipa_preflight  # noqa: E402

SPEC = importlib.util.spec_from_file_location('merge_private_guest',
                                               HERE / 'merge-private-guest.py')
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)


def plist(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def descriptor(identity, version):
    return plist({'schema': 1, 'bundleIdentifier': identity,
                  'bundleVersion': version, 'executable': 'NativeGuest'})


def host_info(*, identity=subject.HOST_ID, build='23', stage=subject.SYNTHETIC_STAGE,
              kind=subject.SYNTHETIC_KIND, mode=1):
    return {
        'CFBundleIdentifier': identity,
        'CFBundleVersion': build,
        'CFBundleExecutable': subject.HOST_EXECUTABLE,
        'CVNativeIntegrationStage': stage,
        'CVNativeGuestKind': kind,
        'CVLPFrameworkGuestMode': mode,
        'UIFileSharingEnabled': False,
        'LSSupportsOpeningDocumentsInPlace': False,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait'],
    }


def synthetic_host_files(**info_args):
    root = subject.APP_ROOT
    guest = subject.GUEST_ROOT
    kit = subject.KIT_ROOT
    return {
        root + '/Info.plist': plist(host_info(**info_args)),
        root + '/LiveContainer': b'build23-host-main-synthetic-test-bytes',
        subject.EXTENSION_ROOT + '/Info.plist': plist({
            'CFBundleIdentifier': subject.EXTENSION_ID,
            'CFBundleExecutable': 'LiveProcess', 'CFBundleVersion': '23'}),
        subject.EXTENSION_ROOT + '/LiveProcess': b'build23-liveprocess-synthetic-test-bytes',
        kit + '/Info.plist': plist({
            'CFBundleIdentifier': subject.KIT_ID, 'CFBundleExecutable': 'CalcVaultKit',
            'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1'}),
        kit + '/CalcVaultKit': b'calcvault-kit-synthetic-fixture',
        guest + '/Info.plist': plist({
            'CFBundleIdentifier': subject.SYNTHETIC_GUEST_ID,
            'CFBundleVersion': '1', 'CFBundleExecutable': 'NativeGuest',
            'CFBundlePackageType': 'FMWK'}),
        guest + '/NativeGuest': b'synthetic-placeholder-framework-bytes',
        guest + '/Resources/SyntheticFallback.dat': b'preserve-fallback-resource',
        subject.DESCRIPTOR: descriptor(subject.SYNTHETIC_GUEST_ID, '1'),
        root + '/Frameworks/SyntheticNativeGuestPayload.dylib': b'preserve-disabled-fallback',
        root + '/SyntheticGuestResources.bundle/Info.plist': b'preserve-synthetic-bundle',
        root + '/Settings.bundle/Root.plist': b'unrelated-host-member-must-stay-exact',
    }


def known_20_6_files(*, host_identity=subject.HOST_ID,
                     guest_identity=subject.GUEST_ID, guest_build=subject.GUEST_BUILD):
    root = subject.APP_ROOT
    guest = subject.GUEST_ROOT
    guest_info = {
        'CFBundleIdentifier': guest_identity,
        'CFBundleVersion': guest_build,
        'CFBundleShortVersionString': '43.9.0',
        'CFBundleExecutable': subject.GUEST_EXECUTABLE,
        'CFBundlePackageType': 'FMWK',
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': [
            'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    }
    return {
        root + '/Info.plist': plist({
            'CFBundleIdentifier': host_identity, 'CFBundleVersion': '20',
            'CFBundleExecutable': subject.HOST_EXECUTABLE}),
        root + '/LiveContainer': b'known-good20.6-host-sentinel',
        subject.EXTENSION_ROOT + '/Info.plist': plist({
            'CFBundleIdentifier': subject.EXTENSION_ID,
            'CFBundleExecutable': 'LiveProcess', 'CFBundleVersion': '20'}),
        subject.EXTENSION_ROOT + '/LiveProcess': b'known-good20.6-extension-sentinel',
        guest + '/Info.plist': plist(guest_info),
        guest + '/NativeGuest': b'known-good-build439042-nativeguest-fixture',
        guest + '/Frameworks/Social.framework/Info.plist': b'nested-framework-metadata-fixture',
        guest + '/Frameworks/Social.framework/Social': b'nested-framework-binary-fixture',
        guest + '/Resources/GuestInfo.plist': b'guest-resource-byte-sentinel',
        subject.DESCRIPTOR: descriptor(guest_identity, guest_build),
        root + '/Settings.bundle/Root.plist': b'old-host-settings-do-not-copy',
    }


def write_ipa(path, files, extras=()):
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        directories = set()
        for name in files:
            parts = name.split('/')
            for index in range(1, len(parts)):
                directories.add('/'.join(parts[:index]) + '/')
        for name in sorted(directories):
            archive.writestr(name, b'')
        for name, data in files.items():
            archive.writestr(name, data)
        for extra in extras:
            if isinstance(extra, zipfile.ZipInfo):
                archive.writestr(extra, b'synthetic-extra-entry')
            else:
                name, data = extra
                archive.writestr(name, data)


class MergePrivateGuestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.host = self.folder / 'Build23-synthetic.ipa'
        self.known = self.folder / 'known-good20.6.ipa'
        self.output = self.folder / 'Build23-private-candidate.ipa'
        self.host_files = synthetic_host_files()
        self.known_files = known_20_6_files()
        self.baseline_host_files = dict(self.host_files)
        self.baseline_known_files = dict(self.known_files)
        write_ipa(self.host, self.host_files)
        write_ipa(self.known, self.known_files)

    def invoke(self, *, host_sha=None, known_sha=None):
        return subject.merge_private_guest(
            self.host, self.known, self.output,
            expected_host_sha256=host_sha or sha(self.host.read_bytes()),
            _expected_known_guest_digest=known_sha or sha(self.known.read_bytes()))

    def reject(self, expected_code=None, *, host_sha=None, known_sha=None):
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.invoke(host_sha=host_sha, known_sha=known_sha)
        if expected_code is not None:
            self.assertEqual(str(caught.exception), expected_code)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.private-guest-merge-*')), [])

    def rewrite_host(self, *, update_info=None, extras=(), files=None):
        data = dict(files if files is not None else self.baseline_host_files)
        if update_info:
            info = plistlib.loads(data[subject.APP_ROOT + '/Info.plist'])
            info.update(update_info)
            data[subject.APP_ROOT + '/Info.plist'] = plist(info)
        write_ipa(self.host, data, extras)
        self.host_files = data

    def rewrite_known(self, *, files=None, extras=()):
        data = dict(files if files is not None else self.baseline_known_files)
        write_ipa(self.known, data, extras)
        self.known_files = data

    def test_happy_path_preserves_host_and_copies_source_framework_and_descriptor(self):
        original_host_digest = sha(self.host.read_bytes())
        original_known_digest = sha(self.known.read_bytes())
        report = self.invoke()
        self.assertEqual(report['status'], 'merged_private_guest_requires_sidestore_resigning')
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['valid_final_signature'])
        self.assertFalse(report['runtime_verified'])
        self.assertTrue(report['requires_sidestore_resigning'])
        self.assertEqual(sha(self.host.read_bytes()), original_host_digest)
        self.assertEqual(sha(self.known.read_bytes()), original_known_digest)

        with zipfile.ZipFile(self.host) as host, zipfile.ZipFile(self.known) as known, \
                zipfile.ZipFile(self.output) as output:
            host_names = set(host.namelist())
            known_names = set(known.namelist())
            output_names = set(output.namelist())
            guest_prefix = subject.GUEST_ROOT + '/'
            preserved_host = {name for name in host_names
                              if name != subject.DESCRIPTOR and
                              not name.startswith(guest_prefix)}
            copied_guest = {name for name in known_names if name.startswith(guest_prefix)}
            expected_names = preserved_host | copied_guest | {subject.DESCRIPTOR}
            self.assertEqual(output_names, expected_names)

            original_info = plistlib.loads(host.read(subject.APP_ROOT + '/Info.plist'))
            merged_info = plistlib.loads(output.read(subject.APP_ROOT + '/Info.plist'))
            expected_info = dict(original_info)
            expected_info['CVNativeIntegrationStage'] = subject.PRIVATE_STAGE
            expected_info['CVNativeGuestKind'] = subject.PRIVATE_KIND
            self.assertEqual(merged_info, expected_info)

            for name in preserved_host:
                if name == subject.APP_ROOT + '/Info.plist':
                    continue
                self.assertEqual(output.read(name), host.read(name), name)
            for name in copied_guest:
                self.assertEqual(output.read(name), known.read(name), name)
            self.assertEqual(output.read(subject.DESCRIPTOR), known.read(subject.DESCRIPTOR))
            self.assertEqual(output.testzip(), None)

        self.assertEqual(report['guest_files'],
                         sum(not name.endswith('/') for name in copied_guest))
        self.assertEqual(report['output_sha256'], sha(self.output.read_bytes()))

    def test_rejects_wrong_host_and_known_guest_digests(self):
        self.reject('host_digest_mismatch', host_sha='0' * 64)
        self.reject('known_guest_digest_mismatch', known_sha='0' * 64)

    def test_rejects_unexpected_host_identity_version_marker_kind_and_framework_mode(self):
        for change, expected in (
            ({'CFBundleIdentifier': 'org.example.other'}, 'unexpected_host_identity'),
            ({'CFBundleVersion': '22'}, 'unexpected_host_version'),
            ({'CVNativeIntegrationStage': 'synthetic-integration-22'}, 'unexpected_host_marker'),
            ({'CVNativeGuestKind': 'tiktok'}, 'unexpected_host_guest_kind'),
            ({'CVLPFrameworkGuestMode': True}, 'unexpected_host_framework_mode'),
        ):
            with self.subTest(change=change):
                self.rewrite_host(update_info=change)
                self.reject(expected)
                self.rewrite_host(files=synthetic_host_files())

    def test_rejects_synthetic_descriptor_or_framework_version_mismatch(self):
        files = dict(self.host_files)
        files[subject.DESCRIPTOR] = descriptor('org.example.other', '1')
        self.rewrite_host(files=files)
        self.reject('invalid_synthetic_descriptor')
        files = synthetic_host_files()
        framework = plistlib.loads(files[subject.GUEST_ROOT + '/Info.plist'])
        framework['CFBundleVersion'] = '2'
        files[subject.GUEST_ROOT + '/Info.plist'] = plist(framework)
        self.rewrite_host(files=files)
        self.reject('invalid_synthetic_framework_metadata')

    def test_rejects_unexpected_source_guest_identity_and_version(self):
        for identity, build in (('org.example.other', subject.GUEST_BUILD),
                                (subject.GUEST_ID, '439041')):
            with self.subTest(identity=identity, build=build):
                self.rewrite_known(files=known_20_6_files(guest_identity=identity,
                                                          guest_build=build))
                self.reject('unexpected_guest_identity_or_version')

    def test_rejects_extra_extension(self):
        self.rewrite_host(extras=[(subject.APP_ROOT + '/PlugIns/Other.appex/Info.plist',
                                   plist({'CFBundleIdentifier': 'org.example.other'}))])
        self.reject('unexpected_host_extension')

    def test_rejects_traversal_symlink_and_duplicate_casefolded_path(self):
        self.rewrite_host(extras=[('Payload/LiveContainer.app/../../outside', b'bad')])
        self.reject('unsafe_archive_path')

        symlink = zipfile.ZipInfo(subject.APP_ROOT + '/Resources/link')
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.rewrite_host(extras=[symlink])
        self.reject('unsupported_archive_entry')

        self.rewrite_host(extras=[('payload/livecontainer.app/info.plist', b'collision')])
        self.reject('duplicate_archive_path')

    def test_rejects_nested_guest_app(self):
        files = dict(self.known_files)
        files[subject.GUEST_ROOT + '/Resources/Unexpected.app/Info.plist'] = b'nested app'
        self.rewrite_known(files=files)
        with self.assertRaises(ipa_preflight.InspectionError):
            self.invoke()
        self.assertFalse(self.output.exists())

    def test_existing_or_in_place_output_is_never_replaced(self):
        self.output.write_bytes(b'preserve existing destination')
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.invoke()
        self.assertEqual(str(caught.exception), 'output_already_exists')
        self.assertEqual(self.output.read_bytes(), b'preserve existing destination')

        before = self.host.read_bytes()
        with self.assertRaises(ipa_preflight.InspectionError):
            subject.merge_private_guest(
                self.host, self.known, self.host,
                expected_host_sha256=sha(before),
                _expected_known_guest_digest=sha(self.known.read_bytes()))
        self.assertEqual(self.host.read_bytes(), before)

    def test_cli_requires_host_digest_and_keeps_source_digest_pinned(self):
        command = [sys.executable, str(HERE / 'merge-private-guest.py'),
                   str(self.host), str(self.known), str(self.output)]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid_arguments', result.stdout)
        self.assertFalse(self.output.exists())
        result = subprocess.run(command + ['--host-sha256', sha(self.host.read_bytes())],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('known_guest_digest_mismatch', result.stdout)
        self.assertFalse(self.output.exists())
        self.assertEqual(subject.PINNED_KNOWN_GUEST_DIGEST,
                         '6e6067eca211d3822763a47d874d08f49b2653a9cc7eccd03f59c2524ec1ab57')


if __name__ == '__main__':
    unittest.main()
