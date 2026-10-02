"""Synthetic opaque placeholders only: no keys, identities or real package bytes."""
import copy
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import assemble_guest
import bundled_resource_policy as subject
import ipa_preflight
import merge_host
import package_plan
import test_merge_host as merge_fixtures
from test_ipa_preflight import info
from test_prepare_executable import fixture
from test_merge_host import guest_manifest


class BundledResourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.source = self.folder / 'synthetic.ipa'
        self.output = self.folder / 'guest.zip'
        self.root = 'Payload/TikTok.app'
        self.name = self.root + '/SessionCheck.bundle/private_key.p12'
        self.target = subject.DESTINATION_ROOT + '/SessionCheck.bundle/private_key.p12'
        self.placeholder = b'opaque synthetic placeholder; NOT A KEY'
        self.make()
        self.input_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.resource_digest = hashlib.sha256(self.placeholder).hexdigest()
        # Only this test process substitutes synthetic metadata for the fixed real pins.
        patcher = patch.object(subject, 'REVIEWED_RESOURCE', (
            self.input_digest, self.name, self.target, len(self.placeholder), self.resource_digest))
        patcher.start()
        self.addCleanup(patcher.stop)

    def make(self, extra=(), resource=None):
        with zipfile.ZipFile(self.source, 'w') as archive:
            archive.writestr(self.root + '/Info.plist', info('TikTok'))
            archive.writestr(self.root + '/TikTok', fixture())
            archive.writestr(self.name, self.placeholder if resource is None else resource)
            for name, data in extra:
                archive.writestr(name, data)

    def policy(self):
        return {'schema': 2, 'input_sha256': self.input_digest,
                'excluded_extensions': [], 'excluded_materials': [],
                'private_test_only': True, 'retained_bundled_resources': [self.name]}

    def plan(self):
        return package_plan.plan_ipa(self.source, policy=self.policy())

    def request(self):
        return {'policy': self.policy(), 'expected_plan_sha256': self.plan()['plan_sha256'],
                'acknowledge_unverified_layout': True,
                'acknowledge_private_bundled_resources': True}

    def rejection(self, code, call):
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
            call()

    def test_no_exception_without_exact_registry(self):
        real_pins = (
            '8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198',
            self.name, self.target, 1525,
            'c7078a0830fad2691e26ccc92bd428f02254561f16aad78574d29922bd840dca')
        with patch.object(subject, 'REVIEWED_RESOURCE', real_pins):
            self.rejection('unapproved_bundled_resource', self.plan)

    def test_plan_and_copy_preserve_opaque_bytes_private_only(self):
        before = self.source.read_bytes()
        plan = self.plan()
        self.assertTrue(plan['private_test_only'])
        self.assertFalse(plan['assembly_authorized'])
        self.assertEqual(plan['action_counts'][subject.ACTION], 1)
        report = assemble_guest.assemble_guest(self.source, self.output, **self.request())
        self.assertFalse(report['is_ipa'])
        self.assertFalse(report['installation_authorized'])
        self.assertEqual(self.source.read_bytes(), before)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(self.target), self.placeholder)
            manifest = json.loads(archive.read(assemble_guest.MANIFEST))
            self.assertEqual(manifest['schema'], 2)
            self.assertTrue(manifest['private_test_only'])
            row = next(r for r in manifest['files'] if r['path'] == self.target)
            self.assertEqual(row['sha256_before_signing'], self.resource_digest)
        self.assertFalse(list(self.folder.glob('.guest-package-*')))

    def test_v1_default_material_stays_unopened(self):
        policy = self.policy()
        policy['schema'] = 1
        del policy['private_test_only'], policy['retained_bundled_resources']
        original = zipfile.ZipFile.open
        def guarded(archive, entry, *args, **kwargs):
            name = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            self.assertNotEqual(name, self.name)
            return original(archive, entry, *args, **kwargs)
        with patch.object(zipfile.ZipFile, 'open', guarded):
            plan = package_plan.plan_ipa(self.source, policy=policy)
        self.assertNotIn('private_test_only', plan)
        self.assertEqual(plan['action_counts']['review_material'], 1)

    def test_policy_rejections_before_material_open(self):
        cases = [
            ('private_test_only', False, 'private_resource_scope_required'),
            ('private_test_only', 1, 'private_resource_scope_required'),
            ('retained_bundled_resources', [], 'unapproved_bundled_resource'),
            ('retained_bundled_resources', [self.name, self.name], 'unapproved_bundled_resource'),
            ('retained_bundled_resources', [self.name.upper()], 'unapproved_bundled_resource'),
            ('retained_bundled_resources', [self.root + '/other.p12'], 'unapproved_bundled_resource'),
            ('retained_bundled_resources', [self.root + '/other.pem'], 'unapproved_bundled_resource'),
            ('excluded_materials', [self.name], 'conflicting_material_policy'),
        ]
        for field, value, code in cases:
            policy = self.policy()
            policy[field] = value
            with self.subTest(field=field, value=value):
                self.rejection(code, lambda: package_plan.plan_ipa(self.source, policy=policy))

    def test_changed_input_or_member_size_rejected(self):
        self.make(resource=b'X' * len(self.placeholder))
        self.rejection('unapproved_bundled_resource', self.plan)
        digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with patch.object(subject, 'REVIEWED_RESOURCE', (
                digest, self.name, self.target, len(self.placeholder), self.resource_digest)):
            self.input_digest = digest
            self.rejection('bundled_resource_digest_mismatch', self.plan)
        self.make(resource=b'longer synthetic placeholder, still not key bytes' * 3)
        self.input_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with patch.object(subject, 'REVIEWED_RESOURCE', (
                self.input_digest, self.name, self.target, len(self.placeholder), self.resource_digest)):
            self.rejection('unapproved_bundled_resource', self.plan)

    def test_other_material_remains_blocked_and_unopened(self):
        other = self.root + '/unrelated.p12'
        self.make(extra=[(other, b'other synthetic placeholder')])
        self.input_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with patch.object(subject, 'REVIEWED_RESOURCE', (
                self.input_digest, self.name, self.target, len(self.placeholder), self.resource_digest)):
            original = zipfile.ZipFile.open
            def guarded(archive, entry, *args, **kwargs):
                name = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
                self.assertNotEqual(name, other)
                return original(archive, entry, *args, **kwargs)
            with patch.object(zipfile.ZipFile, 'open', guarded):
                request = self.request()
                self.rejection('undisposed_package_members', lambda: assemble_guest.assemble_guest(
                    self.source, self.output, **request))
        self.assertFalse(self.output.exists())

    def test_assembly_requires_fresh_explicit_acknowledgement(self):
        for value in (False, 1, 'yes'):
            request = self.request()
            request['acknowledge_private_bundled_resources'] = value
            self.rejection('private_resource_acknowledgement_required', lambda: assemble_guest.assemble_guest(
                self.source, self.output, **request))
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.folder.glob('.guest-package-*')))

    def manifest(self):
        files = {subject.DESTINATION_ROOT + '/NativeGuest': b'synthetic main' * 20,
                 subject.DESTINATION_ROOT + '/Info.plist': b'synthetic metadata',
                 self.target: self.placeholder}
        manifest = guest_manifest(files, self.input_digest)
        manifest['schema'], manifest['private_test_only'] = 2, True
        row = next(r for r in manifest['files'] if r['path'] == self.target)
        row['action'] = subject.ACTION
        return manifest

    def test_merger_rechecks_exact_resource_and_private_scope(self):
        manifest = self.manifest()
        merge_host._validate_manifest(manifest, self.input_digest, True)
        self.rejection('private_resource_acknowledgement_required',
                       lambda: merge_host._validate_manifest(manifest, self.input_digest))
        for field, value in [('source', self.root + '/other.p12'), ('path', self.target.upper()),
                             ('size', True), ('size', len(self.placeholder) + 1),
                             ('sha256_before_signing', '0' * 64), ('sha256_before_signing', None)]:
            altered = copy.deepcopy(manifest)
            row = next(r for r in altered['files'] if r['path'] == self.target)
            row[field] = value
            self.rejection('unapproved_bundled_resource', lambda: merge_host._validate_manifest(
                altered, self.input_digest, True))
        altered = copy.deepcopy(manifest)
        altered['schema'] = 1
        del altered['private_test_only']
        self.rejection('private_resource_scope_required', lambda: merge_host._validate_manifest(
            altered, self.input_digest, True))

    def test_merger_does_not_relax_guest_build_pin(self):
        manifest = self.manifest()
        manifest['original_main_bundle']['build'] = '470044'
        self.rejection('unexpected_guest_identity', lambda: merge_host._validate_manifest(
            manifest, self.input_digest, True))

    def test_forged_normal_resource_or_empty_private_manifest_rejected(self):
        manifest = self.manifest()
        row = next(r for r in manifest['files'] if r['path'] == self.target)
        row['action'] = 'review_resource'
        self.rejection('invalid_guest_manifest', lambda: merge_host._validate_manifest(
            manifest, self.input_digest, True))
        manifest['files'].remove(row)
        self.rejection('unapproved_bundled_resource', lambda: merge_host._validate_manifest(
            manifest, self.input_digest, True))

    def test_output_readback_rechecks_fixed_metadata(self):
        assemble_guest.assemble_guest(self.source, self.output, **self.request())
        with zipfile.ZipFile(self.output) as archive:
            manifest = json.loads(archive.read(assemble_guest.MANIFEST))
        row = next(r for r in manifest['files'] if r['path'] == self.target)
        row['sha256_before_signing'] = '0' * 64
        with self.output.open('rb') as stream:
            self.rejection('unapproved_bundled_resource', lambda: assemble_guest.verify_output(stream, manifest))

    def merge_fixture(self, *, resource=None, pinned_manifest_digest=False):
        helper = merge_fixtures.MergeHostTests(
            'test_success_replaces_only_reviewed_placeholder_and_preserves_host_bytes')
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        helper.original_guest_digest = self.input_digest
        def private_manifest(manifest):
            manifest['schema'], manifest['private_test_only'] = 2, True
            row = next(r for r in manifest['files'] if r['path'] == self.target)
            row['action'] = subject.ACTION
            if pinned_manifest_digest:
                row['sha256_before_signing'] = self.resource_digest
        helper.write_guest(extra=[(self.target, self.placeholder if resource is None else resource)],
                           manifest_mutator=private_manifest)
        return helper

    def test_full_synthetic_merge_is_marked_private_and_preserves_placeholder(self):
        helper = self.merge_fixture()
        before = helper.host.read_bytes(), helper.guest.read_bytes()
        report = helper.request(acknowledge_private_bundled_resources=True)
        self.assertTrue(report['private_test_only'])
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['runtime_verified'])
        with zipfile.ZipFile(helper.output) as archive:
            self.assertEqual(archive.read(merge_host.HOST_ROOT + '/' + self.target), self.placeholder)
            scope = json.loads(archive.read(merge_host.PRIVATE_SCOPE))
            self.assertTrue(scope['private_test_only'])
            self.assertEqual(scope['guest_input_sha256'], self.input_digest)
            self.assertEqual(scope['resource_sha256'], self.resource_digest)
            self.assertEqual(scope['resource_path'], self.target)
        self.assertEqual((helper.host.read_bytes(), helper.guest.read_bytes()), before)

    def test_full_merge_denies_missing_acknowledgement_and_host_material(self):
        helper = self.merge_fixture()
        helper.reject('signing_material_forbidden')
        helper.write_host(extra=[(merge_host.HOST_ROOT + '/SessionCheck.bundle/private_key.p12',
                                  self.placeholder)])
        helper.reject('signing_material_forbidden', acknowledge_private_bundled_resources=True)

    def test_full_merge_rejects_actual_content_substitution(self):
        helper = self.merge_fixture(resource=b'X' * len(self.placeholder), pinned_manifest_digest=True)
        helper.reject('guest_member_digest_mismatch', acknowledge_private_bundled_resources=True)

    def test_merger_cli_passes_private_acknowledgement(self):
        args = ['host.ipa', 'guest.zip', 'output.ipa', '--host-sha256', 'a' * 64,
                '--guest-sha256', 'b' * 64, '--guest-input-sha256', 'c' * 64,
                '--acknowledge-unverified-runtime', '--acknowledge-private-bundled-resources']
        with (patch.object(merge_host, 'merge_host', return_value={'private_test_only': True}) as mock,
              patch('sys.stdout', new_callable=io.StringIO)):
            self.assertEqual(merge_host.main(args), 0)
        self.assertIs(mock.call_args.kwargs['acknowledge_private_bundled_resources'], True)

    def test_stale_private_marker_in_host_cannot_be_replayed(self):
        helper = self.merge_fixture()
        for marker_path in (merge_host.PRIVATE_SCOPE, merge_host.PRIVATE_SCOPE.upper().replace('PAYLOAD/', 'Payload/')):
            helper.write_host(extra=[(marker_path, b'synthetic stale scope marker')])
            helper.reject('reserved_private_scope_marker', acknowledge_private_bundled_resources=True)
        # A normal schema1 guest must not inherit a private marker from its host.
        helper.write_guest()
        helper.write_host(extra=[(merge_host.PRIVATE_SCOPE, b'synthetic stale scope marker')])
        helper.reject('reserved_private_scope_marker')


if __name__ == '__main__':
    unittest.main()
