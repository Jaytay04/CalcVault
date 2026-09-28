"""Synthetic-only structural tests. No proprietary or signed binary fixtures."""
import hashlib
import json
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest.mock import patch

import ipa_preflight as subject


ROOT = 'Payload/Example.app'


def thin(platform=2, cryptid=0, subtype=0, kind=2, extra=b''):
    commands = struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
    commands += struct.pack('<6I', 0x2c, 24, 0, 0, cryptid, 0)
    count = 2
    pos = 0
    while pos < len(extra):
        count += 1
        pos += struct.unpack_from('<I', extra, pos + 4)[0]
    commands += extra
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, subtype, kind,
                       count, len(commands), 0, 0) + commands


def fat(wide=False):
    first, second = thin(), thin(subtype=0x80000002)
    stride = 32 if wide else 20
    start = 8 + stride * 2
    start = (start + 7) & ~7
    offsets = [start, start + len(first)]
    table = b''
    for sub, offset, payload in zip((0, 0x80000002), offsets, (first, second)):
        values = (0x100000c, sub, offset, len(payload), 3)
        table += struct.pack('>IIQQII' if wide else '>5I', *(values + (0,) if wide else values))
    header = struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, 2) + table
    return header.ljust(start, b'\0') + first + second


def info(executable='Example'):
    return plistlib.dumps({'CFBundleIdentifier': 'org.example.synthetic',
                          'CFBundleVersion': '1', 'CFBundleExecutable': executable})


def armv7(cryptid=0, platform=2):
    commands = struct.pack('<4I', 0x25 if platform == 2 else 0x24, 16, 0, 0)
    commands += struct.pack('<5I', 0x21, 20, 0, 0, cryptid)
    return struct.pack('<7I', 0xfeedface, 12, 9, 6, 2, len(commands), 0) + commands


def mixed_fat(legacy=None, wide=False):
    first, second = armv7() if legacy is None else legacy, thin(kind=6)
    stride = 32 if wide else 20
    start = (8 + stride * 2 + 7) & ~7
    second_offset = (start + len(first) + 7) & ~7
    table = b''
    for cpu, sub, offset, payload in ((12, 9, start, first), (0x100000c, 0, second_offset, second)):
        values = (cpu, sub, offset, len(payload), 3)
        table += struct.pack('>IIQQII' if wide else '>5I', *(values + (0,) if wide else values))
    header = struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, 2) + table
    return (header.ljust(start, b'\0') + first).ljust(second_offset, b'\0') + second


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'fixture.ipa'

    def write(self, executable=None, extra=(), plist=None):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.path, 'w') as archive:
                archive.writestr(ROOT + '/Info.plist', info() if plist is None else plist)
                archive.writestr(ROOT + '/Example', thin() if executable is None else executable)
                for name, data in extra:
                    archive.writestr(name, data)

    def reject(self, code=None):
        with self.assertRaises(subject.InspectionError) as caught:
            subject.inspect_ipa(self.path)
        if code:
            self.assertEqual(str(caught.exception), code)

    def test_normal_report_not_install_authorization(self):
        self.write()
        result = subject.inspect_ipa(self.path)
        self.assertTrue(result['checks_completed'])
        self.assertNotIn('metadata_complete', result)
        self.assertEqual(result['other_file_count'], 1)
        self.assertFalse(result['installation_authorized'])
        self.assertEqual(result['status'], 'review_required')
        self.assertIn('signatures', result['unverified'])

    def test_original_unchanged(self):
        self.write()
        before = self.path.read_bytes()
        result = subject.inspect_ipa(self.path)
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(hashlib.sha256(before).hexdigest(), result['sha256'])
        self.assertEqual(list(Path(self.temp.name).iterdir()), [self.path])

    def test_missing_file_error_redacted(self):
        self.reject('unreadable_or_malformed_ipa')

    def test_invalid_zip(self):
        self.path.write_bytes(b'sensitive contents')
        self.reject('archive_size_limit')

    def test_unsafe_paths(self):
        for name in ('../escape', '/absolute', 'C:/drive',
                     'Payload//empty', 'Payload/./dot', 'Payload/name. '):
            with self.subTest(name=name):
                self.write(extra=[(name, b'')])
                self.reject('unsafe_archive_path')

    def test_backslash_and_nul_zip_names(self):
        # Windows ZipFile normalizes backslashes and truncates NUL at creation.
        for original, invalid in ((b'bad/path', b'bad\\path'), (b'bad/path', b'bad\0path')):
            self.write(extra=[(original.decode(), b'')])
            self.path.write_bytes(self.path.read_bytes().replace(original, invalid))
            self.reject('unsafe_archive_path')

    def test_casefold_and_duplicate_names(self):
        for duplicate in (ROOT + '/Example', ROOT + '/EXAMPLE'):
            with self.subTest(duplicate=duplicate):
                self.write(extra=[(duplicate, b'')])
                self.reject('duplicate_archive_path')

    def test_unicode_collision(self):
        self.write(extra=[(ROOT + '/caf\u00e9', b''), (ROOT + '/cafe\u0301', b'')])
        self.reject('duplicate_archive_path')

    def test_file_directory_conflict(self):
        self.write(extra=[(ROOT + '/x', b''), (ROOT + '/x/y', b'')])
        self.reject('archive_file_directory_conflict')

    def test_symlink_rejected(self):
        link = zipfile.ZipInfo(ROOT + '/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write(extra=[(link, b'/elsewhere')])
        self.reject('unsupported_archive_entry')

    def test_material_contents_never_opened(self):
        secret = ROOT + '/Resource.bundle/private_key.p12'
        self.write(extra=[(secret, b'not a real key')])
        original = zipfile.ZipFile.open
        def guarded(archive, name, *args, **kwargs):
            filename = name.filename if isinstance(name, zipfile.ZipInfo) else name
            self.assertNotEqual(filename, secret)
            return original(archive, name, *args, **kwargs)
        with patch.object(zipfile.ZipFile, 'open', guarded):
            result = subject.inspect_ipa(self.path)
        self.assertEqual(result['uninspected_material_names'], [secret])

    def test_extensions_frameworks_and_dylibs(self):
        extras = []
        for directory in ('PlugIns/Test.appex', 'Frameworks/Test.framework'):
            extras += [(ROOT + '/' + directory + '/Info.plist', info('Code')),
                       (ROOT + '/' + directory + '/Code', thin(kind=6))]
        extras.append((ROOT + '/Frameworks/Loose.dylib', thin(kind=6)))
        self.write(extra=extras)
        result = subject.inspect_ipa(self.path)
        self.assertEqual((result['framework_count'], result['dylib_count']), (1, 1))
        self.assertEqual(len(result['extensions']), 1)

    def test_second_app(self):
        self.write(extra=[('Payload/Other.app/Info.plist', info())])
        self.reject('expected_one_payload_app')

    def test_nested_app(self):
        self.write(extra=[(ROOT + '/Other.app/Info.plist', info())])
        self.reject('nested_app_not_supported')

    def test_bad_plist_and_executable(self):
        self.write(plist=b'invalid private text')
        self.reject('invalid_bundle_plist')
        self.write(plist=info('../outside'))
        self.reject('invalid_bundle_executable')

    def test_missing_executable(self):
        self.write(plist=info('missing'))
        self.reject('missing_bundle_executable')

    def test_encrypted_macho(self):
        self.write(executable=thin(cryptid=1))
        self.reject('encrypted_macho')

    def test_simulator_rejected(self):
        self.write(executable=thin(platform=7))
        self.reject('unsupported_macho_platform')

    def test_truncated_header(self):
        self.write(executable=b'\xcf\xfa\xed\xfe')
        self.reject('truncated_macho')

    def test_bad_command_size(self):
        payload = bytearray(thin())
        struct.pack_into('<I', payload, 36, 0)
        self.write(executable=payload)
        self.reject('invalid_load_commands')

    def test_bad_command_count(self):
        payload = bytearray(thin())
        struct.pack_into('<I', payload, 16, 0)
        self.write(executable=payload)
        self.reject('invalid_load_commands')

    def test_fat32_and_fat64(self):
        for wide in (False, True):
            with self.subTest(wide=wide):
                self.write(executable=fat(wide))
                result = subject.inspect_ipa(self.path)
                self.assertEqual(len(result['code'][ROOT + '/Example']), 2)

    def test_fat_overlap_and_identity(self):
        payload = bytearray(fat())
        first_offset = struct.unpack_from('>I', payload, 16)[0]
        struct.pack_into('>I', payload, 36, first_offset)
        self.write(executable=payload)
        self.reject('overlapping_fat_slices')
        payload = bytearray(fat())
        struct.pack_into('>I', payload, 12, 1)
        self.write(executable=payload)
        self.reject('fat_identity_mismatch')

    def test_zip_count_limit(self):
        self.write()
        with patch.object(subject, 'MAX_ENTRIES', 1):
            self.reject('archive_directory_limit')

    def test_size_limits(self):
        self.write()
        with patch.object(subject, 'MAX_ENTRY', 1):
            self.reject('archive_entry_limit')
        with patch.object(subject, 'MAX_TOTAL', 1):
            self.reject('archive_total_limit')

    def test_trailing_bytes(self):
        self.write()
        self.path.write_bytes(self.path.read_bytes() + b'garbage')
        self.reject('invalid_zip_directory')

    def test_encrypted_zip(self):
        self.write()
        data = bytearray(self.path.read_bytes())
        for magic, offset in ((b'PK\x03\x04', 6), (b'PK\x01\x02', 8)):
            pos = data.find(magic) + offset
            struct.pack_into('<H', data, pos, struct.unpack_from('<H', data, pos)[0] | 1)
        self.path.write_bytes(data)
        self.reject('encrypted_zip_entry')

    def test_bad_dependency_string_offset(self):
        command = struct.pack('<6I', 0xc, 32, 99, 0, 0, 0) + b'\0' * 8
        self.write(executable=thin(extra=command))
        self.reject('invalid_load_path')

    def test_dependency_and_rpath_inventory(self):
        def path_command(cmd, value, minimum):
            payload = value.encode() + b'\0'
            size = (minimum + len(payload) + 7) & ~7
            return (struct.pack('<3I', cmd, size, minimum).ljust(minimum, b'\0') + payload).ljust(size, b'\0')
        extra = path_command(0xc, '@rpath/Test.dylib', 24)
        extra += path_command(0x8000001c, '@executable_path/Frameworks', 12)
        self.write(executable=thin(extra=extra))
        data = subject.inspect_ipa(self.path)['code'][ROOT + '/Example'][0]
        self.assertEqual(data['dependencies'], ['@rpath/Test.dylib'])
        self.assertEqual(data['dependencies_needing_layout_review'], ['@rpath/Test.dylib'])
        self.assertEqual(data['rpaths'], ['@executable_path/Frameworks'])

    def test_encrypted_extension_not_ignored(self):
        ext = ROOT + '/PlugIns/Synthetic.appex/'
        self.write(extra=[(ext + 'Info.plist', info('Code')), (ext + 'Code', thin(cryptid=1))])
        self.reject('encrypted_macho')

    def test_unknown_cpu_subtype(self):
        self.write(executable=thin(subtype=99))
        self.reject('unsupported_macho_architecture')

    def test_cli_error_is_sanitized_json(self):
        result = subprocess.run([sys.executable, str(Path(subject.__file__)),
                                 str(self.path.parent / 'PRIVATE-MARKER')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE-MARKER', result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'rejected')

    def review(self):
        return subject.inspect_ipa(self.path, profile='extended-review')

    def review_reject(self, code):
        with self.assertRaisesRegex(subject.InspectionError, '^' + code + '$'):
            self.review()

    def test_review_requires_explicit_profile_and_remains_unapproved(self):
        self.write(extra=[(ROOT + '/Frameworks/Legacy.dylib', mixed_fat())])
        before = self.path.read_bytes()
        self.reject('unsupported_macho_architecture')
        report = self.review()
        self.assertEqual(report['inspection_profile'], 'extended-review')
        self.assertEqual(report['max_entry_bytes'], 1024**3)
        self.assertFalse(report['installation_authorized'])
        self.assertEqual(report['status'], 'review_required')
        self.assertIn('legacy_architecture_requires_disposition', report['review_flags'])
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(list(Path(self.temp.name).iterdir()), [self.path])

    def test_review_thin_and_fat32_fat64_legacy_inventory(self):
        for payload in (armv7(), mixed_fat(), mixed_fat(wide=True)):
            self.write(extra=[(ROOT + '/Legacy.dylib', payload)])
            slices = self.review()['code'][ROOT + '/Legacy.dylib']
            self.assertEqual(slices[0]['architecture'], 'armv7')
            self.assertEqual(slices[0]['cryptids'], [0])

    def test_review_still_rejects_encrypted_legacy_slice(self):
        self.write(extra=[(ROOT + '/Legacy.dylib', mixed_fat(armv7(cryptid=1)))])
        self.review_reject('encrypted_macho')

    def test_review_legacy_malformed_commands_and_platform(self):
        payload = bytearray(armv7())
        struct.pack_into('<I', payload, 32, 15)
        self.write(extra=[(ROOT + '/Legacy.dylib', mixed_fat(payload))])
        self.review_reject('invalid_load_commands')
        self.write(extra=[(ROOT + '/Legacy.dylib', mixed_fat(armv7(platform=1)))])
        self.review_reject('unsupported_macho_platform')

    def test_review_rejects_legacy_main(self):
        self.write(executable=armv7())
        self.review_reject('unsupported_main_executable')

    def test_review_fat_identity_and_alignment(self):
        payload = bytearray(mixed_fat())
        struct.pack_into('>I', payload, 12, 10)
        self.write(extra=[(ROOT + '/Legacy.dylib', payload)])
        self.review_reject('fat_identity_mismatch')
        payload = bytearray(mixed_fat())
        struct.pack_into('>I', payload, 16, 49)
        self.write(extra=[(ROOT + '/Legacy.dylib', payload)])
        self.review_reject('invalid_fat_range')

    def test_review_entry_limit_is_bounded_and_not_default(self):
        self.write()
        with patch.object(subject, 'MAX_ENTRY', 1):
            self.reject('archive_entry_limit')
            self.review()
        with patch.object(subject, 'MAX_REVIEW_ENTRY', 1):
            self.review_reject('archive_entry_limit')
        with patch.object(subject, 'MAX_TOTAL', 1):
            self.review_reject('archive_total_limit')
        with patch.object(subject, 'MAX_COMMANDS', 1):
            self.review_reject('invalid_load_commands')

    def test_review_preserves_plist_limit(self):
        self.write(plist=b'x' * (1024**2 + 1))
        self.review_reject('invalid_bundle_plist')

    def test_review_material_members_remain_unopened(self):
        secret = ROOT + '/Resource/private_key.p12'
        self.write(extra=[(secret, b'synthetic only')])
        original = zipfile.ZipFile.open
        def guarded(archive, name, *args, **kwargs):
            filename = name.filename if isinstance(name, zipfile.ZipInfo) else name
            self.assertNotEqual(filename, secret)
            return original(archive, name, *args, **kwargs)
        with patch.object(zipfile.ZipFile, 'open', guarded):
            self.assertEqual(self.review()['uninspected_material_names'], [secret])

    def test_invalid_profile_rejected_before_file_open(self):
        with self.assertRaisesRegex(subject.InspectionError, '^unsupported_inspection_profile$'):
            subject.inspect_ipa(self.path, profile='unlimited')

    def test_review_cli(self):
        self.write(extra=[(ROOT + '/Legacy.dylib', mixed_fat())])
        result = subprocess.run([sys.executable, str(Path(subject.__file__)), str(self.path),
                                 '--profile', 'extended-review'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['installation_authorized'])

    def test_strict_short_fat_header_error_unchanged(self):
        payload = bytearray(fat())
        struct.pack_into('>I', payload, 20, 28)
        self.write(executable=payload)
        self.reject('invalid_fat_range')
        self.review_reject('truncated_macho')

    def test_strict_thin_armv7_error_unchanged(self):
        self.write(extra=[(ROOT + '/Legacy.dylib', armv7())])
        self.reject('unsupported_macho_format')


if __name__ == '__main__':
    unittest.main()
