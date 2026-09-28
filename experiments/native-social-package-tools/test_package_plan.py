"""Synthetic draft-layout tests; no actual social packages or key material."""
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import ipa_preflight
import package_plan as subject
from test_ipa_preflight import ROOT, info, thin


class PackagePlanTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.path = self.folder / 'synthetic.ipa'

    def make(self, extra=()):
        with zipfile.ZipFile(self.path, 'w') as archive:
            archive.writestr(ROOT + '/Info.plist', info())
            archive.writestr(ROOT + '/Example', thin())
            for name, data in extra:
                archive.writestr(name, data)

    def policy(self, extensions=(), materials=()):
        return {'schema': 1, 'input_sha256': hashlib.sha256(self.path.read_bytes()).hexdigest(),
                'excluded_extensions': list(extensions), 'excluded_materials': list(materials)}

    def reject(self, code, **kwargs):
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
            subject.plan_ipa(self.path, **kwargs)

    def test_all_members_accounted_draft_only(self):
        self.make([(ROOT + '/image.png', b'fake png'),
                   (ROOT + '/Frameworks/Example.dylib', thin(kind=6))])
        before = self.path.read_bytes()
        result = subject.plan_ipa(self.path)
        self.assertEqual(result['status'], 'draft_review_required')
        self.assertFalse(result['assembly_authorized'])
        self.assertFalse(result['installation_authorized'])
        self.assertEqual(len(result['members']), 4)
        self.assertEqual(sum(result['action_counts'].values()), 4)
        self.assertIn('main_adapter_not_applied', result['blockers'])
        targets = {m['source']: m['proposed_destination'] for m in result['members']}
        self.assertEqual(targets[ROOT + '/Example'], subject.DESTINATION + '/NativeGuest')
        self.assertEqual(targets[ROOT + '/Frameworks/Example.dylib'],
                         subject.DESTINATION + '/Frameworks/Example.dylib')
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(list(self.folder.iterdir()), [self.path])

    def test_explicit_extension_exclusion_no_default(self):
        ext = ROOT + '/PlugIns/Test.appex'
        self.make([(ext + '/Info.plist', info('Code')), (ext + '/Code', thin())])
        result = subject.plan_ipa(self.path)
        self.assertEqual(result['action_counts']['review_extension'], 2)
        result = subject.plan_ipa(self.path, policy=self.policy(extensions=[ext]))
        self.assertEqual(result['action_counts']['exclude_extension'], 2)
        for member in result['members']:
            if member['source'].startswith(ext + '/'):
                self.assertIsNone(member['proposed_destination'])
        self.assertFalse(result['assembly_authorized'])

    def test_material_never_opened_even_with_policy(self):
        name = ROOT + '/Session.bundle/private_key.p12'
        self.make([(name, b'synthetic only')])
        policy = self.policy(materials=[name])
        original = zipfile.ZipFile.open
        def guarded(archive, entry, *args, **kwargs):
            filename = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            self.assertNotEqual(filename, name)
            return original(archive, entry, *args, **kwargs)
        with patch.object(zipfile.ZipFile, 'open', guarded):
            self.assertEqual(subject.plan_ipa(self.path)['action_counts']['review_material'], 1)
            self.assertEqual(subject.plan_ipa(self.path, policy=policy)['action_counts']['exclude_material'], 1)

    def test_nested_extension_exclusion_respects_selected_subtree(self):
        outer = ROOT + '/PlugIns/Outer.appex'
        inner = outer + '/PlugIns/Inner.appex'
        self.make([(outer + '/Info.plist', info('Outer')), (outer + '/Outer', thin()),
                   (inner + '/Info.plist', info('Inner')), (inner + '/Inner', thin())])
        result = subject.plan_ipa(self.path, policy=self.policy(extensions=[inner]))
        self.assertEqual(result['action_counts']['exclude_extension'], 2)
        self.assertEqual(result['action_counts']['review_extension'], 2)
        result = subject.plan_ipa(self.path, policy=self.policy(extensions=[outer]))
        self.assertEqual(result['action_counts']['exclude_extension'], 4)
        self.assertNotIn('review_extension', result['action_counts'])

    def test_hidden_executable_has_no_copy_destination(self):
        name = ROOT + '/Images/surprise.bin'
        self.make([(name, thin(kind=6))])
        result = subject.plan_ipa(self.path)
        row = next(m for m in result['members'] if m['source'] == name)
        self.assertEqual(row['action'], 'review_unclassified_executable')
        self.assertIsNone(row['proposed_destination'])

    def test_resource_prefix_read_is_bounded(self):
        name = ROOT + '/Data/resource'
        self.make([(name, b'synthetic resource bytes')])
        original = zipfile.ZipFile.open
        reads = []
        class Guarded:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): return self
            def __exit__(self, *args): self.stream.close()
            def read(self, amount=-1):
                reads.append(amount)
                self_outer.assertEqual(amount, 4)
                return self.stream.read(amount)
        self_outer = self
        def guarded(archive, entry, *args, **kwargs):
            filename = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            stream = original(archive, entry, *args, **kwargs)
            return Guarded(stream) if filename == name else stream
        with patch.object(zipfile.ZipFile, 'open', guarded):
            subject.plan_ipa(self.path)
        self.assertEqual(reads, [4])

    def test_signature_and_outside_root_not_copied(self):
        self.make([(ROOT + '/_CodeSignature/CodeResources', b'old synthetic signature'),
                   ('Metadata/item', b'outside')])
        result = subject.plan_ipa(self.path)
        self.assertEqual(result['action_counts']['omit_obsolete_signature'], 1)
        self.assertEqual(result['action_counts']['review_outside_payload'], 1)
        self.assertTrue(all(m['proposed_destination'] is None for m in result['members']
                            if m['action'] in ('omit_obsolete_signature', 'review_outside_payload')))

    def test_policy_binds_exact_input(self):
        self.make()
        policy = self.policy()
        policy['input_sha256'] = '0' * 64
        self.reject('policy_digest_mismatch', policy=policy)

    def test_unknown_or_duplicate_exclusion_rejected(self):
        name = ROOT + '/private_key.p12'
        self.make([(name, b'synthetic only')])
        self.reject('unknown_policy_target', policy=self.policy(materials=[ROOT + '/missing.p12']))
        self.reject('duplicate_policy_target', policy=self.policy(materials=[name, name]))
        self.reject('unknown_policy_target', policy=self.policy(extensions=['../other.appex']))

    def test_invalid_policy_shapes(self):
        self.make()
        for value in ([], {}, True):
            self.reject('invalid_policy', policy=value)
        for field, value in (('schema', True), ('schema', 2), ('excluded_extensions', 'all')):
            policy = self.policy()
            policy[field] = value
            self.reject('invalid_policy', policy=policy)
        policy = self.policy()
        policy['approved'] = True
        self.reject('invalid_policy', policy=policy)

    def test_relocation_collisions_rejected(self):
        self.make([(ROOT + '/nativeguest', b'collision')])
        self.reject('plan_destination_collision')
        self.make([(ROOT + '/NativeGuest/asset', b'prefix conflict')])
        self.reject('plan_destination_conflict')

    def test_changed_input_detected_after_inspection(self):
        self.make()
        digest = self.policy()['input_sha256']
        with patch.object(hashlib, 'file_digest', side_effect=[
                SimpleNamespace(hexdigest=lambda: digest),
                SimpleNamespace(hexdigest=lambda: '0' * 64)]):
            self.reject('input_changed_during_planning')

    def test_unsafe_archive_still_rejected(self):
        self.make([('../escape', b'')])
        self.reject('unsafe_archive_path')

    def test_policy_cannot_hide_encrypted_extension(self):
        ext = ROOT + '/PlugIns/Test.appex'
        self.make([(ext + '/Info.plist', info('Code')), (ext + '/Code', thin(cryptid=1))])
        self.reject('encrypted_macho', policy=self.policy(extensions=[ext]))

    def test_policy_file_bounds_and_duplicates(self):
        path = self.folder / 'policy.json'
        path.write_text('{"schema":1,"schema":1}')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, 'duplicate_policy_field'):
            subject.read_policy(path)
        path.write_bytes(b'x' * (subject.POLICY_LIMIT + 1))
        with self.assertRaisesRegex(ipa_preflight.InspectionError, 'policy_size_limit'):
            subject.read_policy(path)

    def test_null_policy_not_silently_absent(self):
        path = self.folder / 'policy.json'
        path.write_text('null')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^invalid_policy$'):
            subject.read_policy(path)

    def test_material_cannot_be_opened_as_policy(self):
        with patch.object(Path, 'open', side_effect=AssertionError('must not open')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^invalid_policy_file_type$'):
                subject.read_policy(self.folder / 'synthetic.p12')

    def test_cli_reports_draft_and_sanitized_error(self):
        self.make()
        command = [sys.executable, str(Path(subject.__file__)), str(self.path)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['assembly_authorized'])
        command[-1] = str(self.folder / 'PRIVATE-MARKER')
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE-MARKER', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
