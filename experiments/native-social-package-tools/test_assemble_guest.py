"""Synthetic private-writer tests. No proprietary code, accounts or actual keys."""
import hashlib
import io
import json
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import assemble_guest as subject
import ipa_preflight
import package_plan
from test_ipa_preflight import ROOT, info, thin
from test_prepare_executable import fixture


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.source = self.folder / 'synthetic.ipa'
        self.output = self.folder / 'guest.zip'

    def make(self, extra=()):
        with zipfile.ZipFile(self.source, 'w') as archive:
            archive.writestr(ROOT + '/Info.plist', info())
            archive.writestr(ROOT + '/Example', fixture())
            for name, data in extra:
                archive.writestr(name, data)

    def request(self, extensions=(), materials=()):
        policy = {'schema': 1, 'input_sha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
                  'excluded_extensions': list(extensions), 'excluded_materials': list(materials)}
        plan = package_plan.plan_ipa(self.source, policy=policy)
        return {'policy': policy, 'expected_plan_sha256': plan['plan_sha256'],
                'acknowledge_unverified_layout': True}

    def reject(self, code, request):
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
            subject.assemble_guest(self.source, self.output, **request)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.guest-package-*')), [])

    def test_complete_output_preserves_input_and_embedded_bytes(self):
        library = thin(kind=6)
        resource = b'large synthetic resource' * 20000
        self.make([(ROOT + '/Frameworks/Library.framework/Info.plist', info('Library')),
                   (ROOT + '/Frameworks/Library.framework/Library', library),
                   (ROOT + '/Image.bin', resource),
                   (ROOT + '/_CodeSignature/CodeResources', b'synthetic signature metadata')])
        original = self.source.read_bytes()
        report = subject.assemble_guest(self.source, self.output, **self.request())
        self.assertEqual(self.source.read_bytes(), original)
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['is_ipa'])
        self.assertEqual(report['included_files'], 5)
        self.assertEqual(report['omitted_files'], 1)
        self.assertEqual(report['output_sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        root = package_plan.DESTINATION + '/'
        with zipfile.ZipFile(self.output) as archive:
            main = archive.read(root + 'NativeGuest')
            self.assertEqual(struct.unpack_from('<I', main, 12)[0], 6)
            self.assertEqual(main[4096:4112], fixture()[4096:4112])
            metadata = plistlib.loads(archive.read(root + 'Info.plist'))
            self.assertEqual(metadata['CFBundleExecutable'], 'NativeGuest')
            self.assertEqual(metadata['CFBundlePackageType'], 'FMWK')
            self.assertEqual(archive.read(root + 'Frameworks/Library.framework/Library'), library)
            self.assertEqual(archive.read(root + 'Image.bin'), resource)
            manifest = json.loads(archive.read(subject.MANIFEST))
            self.assertFalse(manifest['runtime_manifest'])
            self.assertFalse(manifest['installation_authorized'])
            for row in manifest['files']:
                self.assertEqual(hashlib.sha256(archive.read(row['path'])).hexdigest(),
                                 row['sha256_before_signing'])
            self.assertEqual(set(archive.namelist()), {row['path'] for row in manifest['files']} |
                             {subject.MANIFEST})
        self.assertEqual(list(self.folder.glob('.guest-package-*')), [])

    def test_output_is_deterministic(self):
        self.make()
        request = self.request()
        first = subject.assemble_guest(self.source, self.output, **request)
        second = subject.assemble_guest(self.source, self.folder / 'another.zip', **request)
        self.assertEqual(first['output_sha256'], second['output_sha256'])

    def test_material_never_opened_and_extension_only_explicitly_omitted(self):
        name = ROOT + '/Resource.bundle/private_key.p12'
        ext = ROOT + '/PlugIns/Test.appex'
        self.make([(name, b'synthetic placeholder, not a key'),
                   (ext + '/Info.plist', info('Code')), (ext + '/Code', thin())])
        original_open = zipfile.ZipFile.open
        def guarded(archive, entry, *args, **kwargs):
            filename = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            self.assertNotEqual(filename, name)
            return original_open(archive, entry, *args, **kwargs)
        with patch.object(zipfile.ZipFile, 'open', guarded):
            request = self.request(extensions=[ext], materials=[name])
            report = subject.assemble_guest(self.source, self.output, **request)
        self.assertEqual(report['omitted_files'], 3)
        with zipfile.ZipFile(self.output) as archive:
            self.assertFalse(any(n.endswith('.p12') or '.appex/' in n for n in archive.namelist()))

    def test_unresolved_members_rejected_before_temp_creation(self):
        for extra in ([(ROOT + '/unopened.p12', b'placeholder')],
                      [(ROOT + '/Hidden/code.bin', thin(kind=6))],
                      [('Outside/resource', b'outside')],
                      [(ROOT + '/PlugIns/Test.appex/Info.plist', info('Code')),
                       (ROOT + '/PlugIns/Test.appex/Code', thin())]):
            self.make(extra)
            request = self.request()
            with patch.object(tempfile, 'mkstemp', side_effect=AssertionError('must not create')):
                self.reject('undisposed_package_members', request)

    def test_requires_explicit_policy_and_acknowledgement(self):
        self.make()
        request = self.request()
        request['acknowledge_unverified_layout'] = False
        self.reject('unverified_layout_acknowledgement_required', request)
        request['acknowledge_unverified_layout'] = True
        request['policy'] = None
        self.reject('explicit_exclusion_policy_required', request)

    def test_stale_plan_and_source_policy_reject(self):
        self.make()
        request = self.request()
        request['expected_plan_sha256'] = '0' * 64
        self.reject('plan_digest_mismatch', request)
        request = self.request()
        request['policy']['input_sha256'] = '0' * 64
        self.reject('policy_digest_mismatch', request)

    def test_invalid_plan_digest_rejects(self):
        self.make()
        request = self.request()
        request['expected_plan_sha256'] = 'not a digest'
        self.reject('invalid_plan_digest', request)

    def test_policy_cannot_hide_encrypted_extension(self):
        ext = ROOT + '/PlugIns/Test.appex'
        self.make([(ext + '/Info.plist', info('Code')), (ext + '/Code', thin(cryptid=1))])
        policy = {'schema': 1, 'input_sha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
                  'excluded_extensions': [ext], 'excluded_materials': []}
        self.reject('encrypted_macho', {'policy': policy, 'expected_plan_sha256': '0' * 64,
                                       'acknowledge_unverified_layout': True})

    def test_collision_is_not_written(self):
        self.make([(ROOT + '/nativeguest', b'collision')])
        self.reject('plan_destination_collision', {'policy': None, 'expected_plan_sha256': '0' * 64})

    def test_existing_output_not_overwritten(self):
        self.make()
        request = self.request()
        self.output.write_bytes(b'original output sentinel')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            subject.assemble_guest(self.source, self.output, **request)
        self.assertEqual(self.output.read_bytes(), b'original output sentinel')
        self.assertEqual(list(self.folder.glob('.guest-package-*')), [])

    def test_output_hardlink_to_input_rejected_without_input_changes(self):
        self.make()
        request = self.request()
        original = self.source.read_bytes()
        os.link(self.source, self.output)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            subject.assemble_guest(self.source, self.output, **request)
        self.assertEqual(self.source.read_bytes(), original)

    def test_output_limits_clean_up_partial_copy(self):
        self.make()
        request = self.request()
        for constant in ('MAX_OUTPUT', 'MAX_MANIFEST'):
            with patch.object(subject, constant, 100):
                self.reject('output_size_limit' if constant == 'MAX_OUTPUT' else 'manifest_size_limit', request)

    def test_corrupt_resource_crc_never_published(self):
        name = ROOT + '/LargeResource'
        self.make([(name, b'R' * (subject.CHUNK * 3))])
        # Alter a stored byte beyond the planner's bounded prefix; retain the old CRC.
        data = bytearray(self.source.read_bytes())
        with zipfile.ZipFile(self.source) as archive:
            offset = archive.getinfo(name).header_offset
        name_size, extra_size = struct.unpack_from('<HH', data, offset + 26)
        data[offset + 30 + name_size + extra_size + subject.CHUNK] ^= 1
        self.source.write_bytes(data)
        self.reject('package_assembly_failed', self.request())

    def test_output_verification_failure_is_not_published(self):
        self.make()
        request = self.request()
        with patch.object(subject, 'verify_output', side_effect=ipa_preflight.InspectionError('test_verify')):
            self.reject('test_verify', request)

    def test_source_changed_during_copy_is_not_published(self):
        self.make()
        request = self.request()
        original_write = subject.write_bundle
        def changed(*args):
            manifest = original_write(*args)
            # Synthetic input only: same-size change after copy models concurrent mutation.
            data = bytearray(self.source.read_bytes())
            data[-1] ^= 1
            self.source.write_bytes(data)
            return manifest
        with patch.object(subject, 'write_bundle', changed):
            self.reject('input_changed_during_assembly', request)

    def test_publication_failure_cleans_only_owned_temp(self):
        self.make()
        request = self.request()
        sentinel = self.folder / '.guest-package-unrelated.zip'
        sentinel.write_bytes(b'unrelated')
        with patch.object(os, 'link', side_effect=OSError('PRIVATE-MARKER')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^package_assembly_failed$'):
                subject.assemble_guest(self.source, self.output, **request)
        self.assertFalse(self.output.exists())
        self.assertEqual(sentinel.read_bytes(), b'unrelated')
        self.assertEqual(list(self.folder.glob('.guest-package-*')), [sentinel])

    def test_stream_reads_bounded_and_checks_size(self):
        reads = []
        class Guarded(io.BytesIO):
            def read(self, amount=-1):
                reads.append(amount)
                return super().read(amount)
        output = io.BytesIO()
        data = b'R' * (subject.CHUNK * 3 + 10)
        count, digest = subject.stream_member(Guarded(data), output, len(data), output)
        self.assertEqual(count, len(data))
        self.assertEqual(digest, hashlib.sha256(data).hexdigest())
        self.assertTrue(all(n == subject.CHUNK for n in reads))
        for size in (1, len(data) + 1):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^member_size_mismatch$'):
                subject.stream_member(io.BytesIO(data), io.BytesIO(), size, io.BytesIO())

    def test_cleanup_failure_after_publication_reports_existing_output(self):
        self.make()
        request = self.request()
        with patch.object(Path, 'unlink', side_effect=OSError('PRIVATE-MARKER')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^temporary_cleanup_failed$'):
                subject.assemble_guest(self.source, self.output, **request)
        self.assertTrue(self.output.exists())
        self.assertEqual(len(list(self.folder.glob('.guest-package-*'))), 1)
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
        before = self.output.read_bytes()
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            subject.assemble_guest(self.source, self.output, **request)
        self.assertEqual(self.output.read_bytes(), before)

    def test_plan_digest_binds_policy_profile_actions_and_flags(self):
        self.make()
        plan = package_plan.plan_ipa(self.source, policy=self.request()['policy'])
        self.assertEqual(plan['plan_sha256'], package_plan.plan_fingerprint(plan))
        for field, value in (('inspection_profile', 'changed'), ('policy_supplied', False),
                             ('review_flags', ['changed']), ('members', [])):
            altered = dict(plan, **{field: value})
            self.assertNotEqual(plan['plan_sha256'], package_plan.plan_fingerprint(altered))

    def test_cli_success_and_sanitized_rejection(self):
        self.make()
        request = self.request()
        policy_path = self.folder / 'policy.json'
        policy_path.write_text(json.dumps(request['policy']))
        command = [sys.executable, str(Path(subject.__file__)), str(self.source), str(self.output),
                   '--policy', str(policy_path), '--plan-sha256', request['expected_plan_sha256'],
                   '--acknowledge-unverified-layout']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)['is_ipa'])
        command[2] = str(self.folder / 'PRIVATE-MARKER.ipa')
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE-MARKER', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
