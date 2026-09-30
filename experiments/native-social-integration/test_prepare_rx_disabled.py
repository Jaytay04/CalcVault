"""Synthetic fixtures for the pinned RX-disabled comparison packager."""

import hashlib
import importlib.util
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent / 'native-social-package-tools'
sys.path.insert(0, str(TOOLS))
import ipa_preflight  # noqa: E402

SPEC = importlib.util.spec_from_file_location('prepare_rx_disabled',
                                               HERE / 'prepare-rx-disabled.py')
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)


def plist(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def dylib_command(command, name, alignment=8):
    encoded = name.encode('utf-8') + b'\0'
    length = 24 + len(encoded)
    padded = (length + alignment - 1) & ~(alignment - 1)
    return struct.pack('<6I', command, padded, 24, 0, 0, 0) + encoded + \
        b'\0' * (padded - length)


def thin(filetype, *, dependencies=(), identifiers=(), cpu=0x0100000C, subtype=0,
         malformed=False):
    commands = b''.join(dylib_command(command, name)
                        for command, name in (*dependencies, *identifiers))
    if malformed:
        commands = struct.pack('<II', subject.LC_LOAD_WEAK_DYLIB, 7)
    header = struct.pack('<8I', subject.MH_MAGIC_64, cpu, subtype, filetype,
                         len(dependencies) + len(identifiers), len(commands), 0, 0)
    return header + commands


def thin32(filetype, *, cpu=12, subtype=9):
    commands = dylib_command(subject.LC_ID_DYLIB,
                             '/usr/lib/LegacyControl.dylib', alignment=4)
    header = struct.pack('<7I', subject.MH_MAGIC, cpu, subtype, filetype,
                         1, len(commands), 0)
    return header + commands


def fat(images):
    stride = 20
    table_end = 8 + len(images) * stride
    offsets, cursor = [], table_end
    for cpu, subtype, data in images:
        cursor = (cursor + 7) & ~7
        offsets.append(cursor)
        cursor += len(data)
    header = b'\xca\xfe\xba\xbe' + struct.pack('>I', len(images))
    records = b''.join(struct.pack('>5I', cpu, subtype, offset, len(data), 3)
                       for (cpu, subtype, data), offset in zip(images, offsets))
    body = bytearray(cursor - table_end)
    for (cpu, subtype, data), offset in zip(images, offsets):
        start = offset - table_end
        body[start:start + len(data)] = data
    return header + records + bytes(body)


def host_info(*, host_id=subject.merger.HOST_ID, version=subject.merger.HOST_BUILD,
              stage=subject.merger.PRIVATE_STAGE, kind=subject.merger.PRIVATE_KIND):
    return {
        'CFBundleIdentifier': host_id,
        'CFBundleVersion': version,
        'CFBundleExecutable': 'LiveContainer',
        'CVNativeIntegrationStage': stage,
        'CVNativeGuestKind': kind,
        'CVLPFrameworkGuestMode': 1,
        'UIFileSharingEnabled': False,
        'LSSupportsOpeningDocumentsInPlace': False,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait'],
    }


def guest_info(*, version=subject.merger.GUEST_BUILD):
    return {
        'CFBundleIdentifier': subject.merger.GUEST_ID,
        'CFBundleVersion': version,
        'CFBundleShortVersionString': '43.9.0',
        'CFBundleExecutable': subject.merger.GUEST_EXECUTABLE,
        'CFBundlePackageType': 'FMWK',
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait'],
    }


def fixture_files(*, guest_version=subject.merger.GUEST_BUILD,
                  dependency=subject.LC_LOAD_WEAK_DYLIB,
                  dependency_path=subject.RX_DEPENDENCY, duplicate_dependency=False,
                  malformed_guest=False, rx_alias=None, fat_slices=False,
                  other_rx_reference=False, mixed_fat_strong=False,
                  malformed_fat_range=False, legacy_fat_library=False):
    merger = subject.merger
    files = {
        merger.APP_ROOT + '/Info.plist': plist(host_info()),
        merger.APP_ROOT + '/LiveContainer': thin(subject.MH_EXECUTE),
        merger.EXTENSION_ROOT + '/Info.plist': plist({
            'CFBundleIdentifier': merger.EXTENSION_ID,
            'CFBundleExecutable': 'LiveProcess', 'CFBundleVersion': '23'}),
        merger.EXTENSION_ROOT + '/LiveProcess': thin(subject.MH_EXECUTE),
        merger.KIT_ROOT + '/Info.plist': plist({
            'CFBundleIdentifier': merger.KIT_ID, 'CFBundleExecutable': 'CalcVaultKit',
            'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1'}),
        merger.KIT_ROOT + '/CalcVaultKit': thin(subject.MH_DYLIB),
        merger.GUEST_ROOT + '/Info.plist': plist(guest_info(version=guest_version)),
        merger.GUEST_ROOT + '/NativeGuest': thin(
            subject.MH_EXECUTE,
            dependencies=[(dependency, dependency_path)] * (2 if duplicate_dependency else 1),
            malformed=malformed_guest),
        subject.RX_MEMBER: thin(
            subject.MH_DYLIB,
            identifiers=[(subject.LC_ID_DYLIB, subject.RX_INSTALL_NAME)]),
        merger.DESCRIPTOR: plist({
            'schema': 1, 'bundleIdentifier': merger.GUEST_ID,
            'bundleVersion': guest_version, 'executable': 'NativeGuest'}),
        merger.GUEST_ROOT + '/Resources/preserved.dat': b'fixture-resource-bytes',
        merger.APP_ROOT + '/Settings.bundle/Root.plist': b'host-member-must-remain-identical',
    }
    if fat_slices:
        second_dependency = (subject.LC_LOAD_DYLIB if mixed_fat_strong else dependency)
        files[merger.GUEST_ROOT + '/NativeGuest'] = fat([
            (0x0100000C, 0, thin(subject.MH_EXECUTE,
                                 dependencies=[(dependency, dependency_path)])),
            (0x0100000C, 0x80000002, thin(subject.MH_EXECUTE, subtype=0x80000002,
                                          dependencies=[(second_dependency, dependency_path)])),
        ])
        files[subject.RX_MEMBER] = fat([
            (0x0100000C, 0, thin(subject.MH_DYLIB,
                                 identifiers=[(subject.LC_ID_DYLIB,
                                               subject.RX_INSTALL_NAME)])),
            (0x0100000C, 0x80000002, thin(subject.MH_DYLIB, subtype=0x80000002,
                                          identifiers=[(subject.LC_ID_DYLIB,
                                                        subject.RX_INSTALL_NAME)])),
        ])
        if malformed_fat_range:
            malformed = bytearray(files[merger.GUEST_ROOT + '/NativeGuest'])
            struct.pack_into('>I', malformed, 16, len(malformed) + 100)
            files[merger.GUEST_ROOT + '/NativeGuest'] = bytes(malformed)
    if other_rx_reference:
        files[merger.APP_ROOT + '/LiveContainer'] = thin(
            subject.MH_EXECUTE,
            dependencies=[(subject.LC_LOAD_WEAK_DYLIB, subject.RX_DEPENDENCY)])
    if legacy_fat_library:
        files[merger.APP_ROOT + '/Frameworks/LegacyControl.dylib'] = fat([
            (12, 9, thin32(subject.MH_DYLIB)),
            (0x0100000C, 0, thin(subject.MH_DYLIB)),
        ])
    if rx_alias:
        files[rx_alias] = files[subject.RX_MEMBER]
    return files


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
        for name, data in extras:
            archive.writestr(name, data)


class PrepareRXDisabledTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.source = self.folder / 'Build23.ipa'
        self.output = self.folder / 'Build23-RX-disabled.ipa'
        self.files = fixture_files()
        write_ipa(self.source, self.files)

    def invoke(self, *, files=None, extras=(), expected=None):
        if files is not None or extras:
            write_ipa(self.source, files if files is not None else self.files, extras)
        digest = sha(self.source.read_bytes()) if expected is None else expected
        return subject.prepare_rx_disabled(
            self.source, self.output, _expected_input_sha256=digest)

    def reject(self, code, *, files=None, extras=()):
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.invoke(files=files, extras=extras)
        self.assertEqual(str(caught.exception), code)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.rx-disabled-*')), [])

    def test_happy_path_omits_only_rx_and_verifies_all_retained_bytes(self):
        original = self.source.read_bytes()
        report = self.invoke()
        self.assertEqual(report['status'],
                         'rx_disabled_comparison_requires_sidestore_resigning')
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['valid_final_signature'])
        self.assertFalse(report['runtime_verified'])
        self.assertTrue(report['requires_sidestore_resigning'])
        self.assertEqual(report['omitted_member'], subject.RX_MEMBER)
        self.assertEqual(self.source.read_bytes(), original)
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as output:
            expected_names = set(source.namelist()) - {subject.RX_MEMBER}
            self.assertEqual(set(output.namelist()), expected_names)
            for name in expected_names:
                self.assertEqual(output.read(name), source.read(name), name)
            self.assertIsNone(output.testzip())

    def test_fat_slices_are_checked_and_preserved(self):
        files = fixture_files(fat_slices=True)
        self.invoke(files=files)
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as output:
            self.assertEqual(output.read(subject.merger.GUEST_ROOT + '/NativeGuest'),
                             source.read(subject.merger.GUEST_ROOT + '/NativeGuest'))
            self.assertNotIn(subject.RX_MEMBER, output.namelist())

    def test_legacy_armv7_and_arm64_fat_dylib_is_retained_byte_for_byte(self):
        files = fixture_files(legacy_fat_library=True)
        self.invoke(files=files)
        retained = subject.merger.APP_ROOT + '/Frameworks/LegacyControl.dylib'
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as output:
            self.assertEqual(output.read(retained), source.read(retained))

    def test_cli_has_no_digest_override_and_pins_the_production_input(self):
        command = [sys.executable, str(HERE / 'prepare-rx-disabled.py'),
                   str(self.source), str(self.output)]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('input_digest_mismatch', result.stdout)
        self.assertFalse(self.output.exists())
        result = subprocess.run(command + ['--input-sha256', sha(self.source.read_bytes())],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid_arguments', result.stdout)

    def test_rejects_wrong_digest_or_guest_version(self):
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.invoke(expected='0' * 64)
        self.assertEqual(str(caught.exception), 'input_digest_mismatch')
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.rx-disabled-*')), [])
        files = fixture_files(guest_version='439043')
        self.reject('unexpected_guest_identity_or_version', files=files)

    def test_rejects_missing_or_aliased_rx_library(self):
        files = dict(self.files)
        del files[subject.RX_MEMBER]
        self.reject('missing_or_aliased_rx_library', files=files)
        files = fixture_files(rx_alias=subject.merger.GUEST_ROOT +
                              '/Frameworks/copy/___RXTikTok.dylib')
        self.reject('missing_or_aliased_rx_library', files=files)

    def test_rejects_strong_duplicate_and_alternate_rx_dependencies(self):
        for kwargs in (
            {'dependency': subject.LC_LOAD_DYLIB},
            {'duplicate_dependency': True},
            {'dependency_path': '@rpath/___RXTikTok.dylib'},
        ):
            with self.subTest(kwargs=kwargs):
                self.reject('unexpected_rx_dependency', files=fixture_files(**kwargs))

    def test_rejects_rx_dependency_in_another_binary(self):
        self.reject('unexpected_rx_dependency',
                    files=fixture_files(other_rx_reference=True))

    def test_rejects_strong_reference_in_one_fat_guest_slice(self):
        self.reject('unexpected_rx_dependency',
                    files=fixture_files(fat_slices=True, mixed_fat_strong=True))

    def test_rejects_malformed_fat_slice_range(self):
        self.reject('invalid_fat_range',
                    files=fixture_files(fat_slices=True, malformed_fat_range=True))

    def test_rejects_malformed_macho_and_unsafe_zip_member(self):
        self.reject('invalid_load_commands', files=fixture_files(malformed_guest=True))
        self.reject('unsafe_archive_path', extras=[('Payload/../escape', b'bad')])

    def test_existing_output_and_in_place_output_are_never_replaced(self):
        self.output.write_bytes(b'preserve existing destination')
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.invoke()
        self.assertEqual(str(caught.exception), 'output_already_exists')
        self.assertEqual(self.output.read_bytes(), b'preserve existing destination')
        before = self.source.read_bytes()
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            subject.prepare_rx_disabled(
                self.source, self.source,
                _expected_input_sha256=sha(before))
        self.assertEqual(str(caught.exception), 'in_place_prepare_forbidden')
        self.assertEqual(self.source.read_bytes(), before)

    def test_verification_failure_leaves_no_published_output(self):
        with mock.patch.object(subject, '_verify_output',
                               side_effect=ipa_preflight.InspectionError(
                                   'output_verification_failed')):
            with self.assertRaises(ipa_preflight.InspectionError) as caught:
                self.invoke()
        self.assertEqual(str(caught.exception), 'output_verification_failed')
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.rx-disabled-*')), [])


if __name__ == '__main__':
    unittest.main()
