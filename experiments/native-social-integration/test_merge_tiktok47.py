"""Synthetic-only tests for the pinned TikTok 47 Build 24 merger."""

import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent / 'native-social-package-tools'
for candidate in (str(HERE), str(TOOLS)):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

import ipa_preflight
import merge_host
spec = importlib.util.spec_from_file_location('merge_tiktok47', HERE / 'merge-tiktok47.py')
subject = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = subject
spec.loader.exec_module(subject)


def plist(value):
    return plistlib.dumps(value, sort_keys=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class MergeTikTok47Tests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.host = self.folder / 'Build24-synthetic.ipa'
        self.guest = self.folder / 'TikTok47-synthetic.zip'
        self.output = self.folder / 'Merged-tiktok47.ipa'

        self.resource_bytes = b'SYNTHETIC-ONLY-RESOURCE-FIXTURE'
        self.resource_input_sha = 'd' * 64
        self.main_bytes = b'SYNTHETIC-ONLY-ADAPTED-EXECUTABLE'
        self.main_input_sha = 'a' * 64
        self.profile = {
            'input_sha256': self.resource_input_sha,
            'original_main_bundle': {
                'path': 'Payload/TikTok.app',
                'identifier': 'com.zhiliaoapp.musically',
                'version': '47.0.0',
                'build': '470044',
                'executable': 'TikTok',
            },
            'main_adaptation': {
                'input_sha256': self.main_input_sha,
                'output_sha256': sha(self.main_bytes),
                'size': len(self.main_bytes),
            },
        }
        self.resource_policy = (
            self.resource_input_sha,
            'Payload/TikTok.app/SessionCheck.bundle/private_key.p12',
            'Frameworks/NativeGuest.framework/SessionCheck.bundle/private_key.p12',
            len(self.resource_bytes),
            sha(self.resource_bytes),
        )
        self.profile_patch = patch.object(merge_host, 'TIKTOK47_PROFILE', self.profile)
        self.resource_patch = patch.object(merge_host.bundled, 'REVIEWED_RESOURCE',
                                           self.resource_policy)
        self.profile_patch.start()
        self.resource_patch.start()
        self.addCleanup(self.profile_patch.stop)
        self.addCleanup(self.resource_patch.stop)
        self.write_host()
        self.write_guest()

    def host_entries(self, *, extra=(), framework_extra=(), framework_dirs=(),
                     resource_extra=(), host_info_extra=None, include_kit=True):
        root = subject.APP_ROOT
        framework = root + '/' + merge_host.GUEST_ROOT
        kit = subject.source_helpers.KIT_ROOT
        extension = root + '/PlugIns/LiveProcess.appex'
        resource = merge_host.RESOURCE_BUNDLE

        host_info = {
            'CFBundleIdentifier': subject.source_helpers.HOST_ID,
            'CFBundleVersion': subject.HOST_BUILD,
            'CFBundleExecutable': subject.source_helpers.HOST_EXECUTABLE,
            'CVNativeIntegrationStage': subject.SYNTHETIC_STAGE,
            'CVNativeGuestKind': subject.SYNTHETIC_KIND,
            'CVLPFrameworkGuestMode': 1,
            'UIFileSharingEnabled': False,
            'LSSupportsOpeningDocumentsInPlace': False,
            'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
            'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationPortrait'],
            'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait'],
        }
        if host_info_extra:
            host_info.update(host_info_extra)
        extension_info = {
            'CFBundleIdentifier': subject.source_helpers.EXTENSION_ID,
            'CFBundleVersion': subject.HOST_BUILD,
            'CFBundleExecutable': 'LiveProcess',
        }
        framework_info = {
            'CFBundleIdentifier': merge_host.SYNTHETIC_GUEST_ID,
            'CFBundleVersion': '1',
            'CFBundleExecutable': 'NativeGuest',
            'CFBundlePackageType': 'FMWK',
        }
        descriptor = {
            'schema': 1,
            'bundleIdentifier': merge_host.SYNTHETIC_GUEST_ID,
            'bundleVersion': '1',
            'executable': 'NativeGuest',
        }
        resource_info = {
            'CFBundleIdentifier': merge_host.SYNTHETIC_RESOURCE_ID,
            'CFBundleName': 'SyntheticGuestResources',
            'CFBundlePackageType': 'BNDL',
            'CFBundleVersion': '24',
        }
        old_guest_info = {
            'CFBundleIdentifier': merge_host.SYNTHETIC_GUEST_ID,
            'CFBundleVersion': '1',
            'CFBundleExecutable': 'SyntheticGuest',
        }
        kit_info = {
            'CFBundleIdentifier': subject.source_helpers.KIT_ID,
            'CFBundleExecutable': 'CalcVaultKit',
            'CFBundlePackageType': 'FMWK',
        }
        rows = [
            (root + '/Info.plist', plist(host_info)),
            (root + '/LiveContainer', b'host-main-binary-synthetic'),
            (root + '/_CodeSignature/CodeResources', b'obsolete-host-signature'),
            (extension + '/Info.plist', plist(extension_info)),
            (extension + '/LiveProcess', b'host-extension-synthetic'),
            (extension + '/_CodeSignature/CodeResources', b'obsolete-extension-signature'),
            (framework + '/Info.plist', plist(framework_info)),
            (framework + '/NativeGuest', b'synthetic-placeholder-only'),
            (framework + '/_CodeSignature/CodeResources', b'obsolete-framework-signature'),
            (merge_host.DESCRIPTOR, plist(descriptor)),
            (merge_host.LEGACY_PAYLOAD, b'synthetic legacy payload'),
            (resource + '/Info.plist', plist(resource_info)),
            (resource + '/GuestInfo.plist', plist(old_guest_info)),
            (root + '/Settings.bundle/Settings.plist', b'host-ui-sentinel'),
            *framework_extra, *resource_extra, *extra,
        ]
        if include_kit:
            rows.extend(((kit + '/Info.plist', plist(kit_info)),
                         (kit + '/CalcVaultKit', b'host-calcvault-kit-synthetic')))
        return rows, framework, resource, extension

    def write_host(self, **kwargs):
        rows, framework, resource, extension = self.host_entries(**kwargs)
        with zipfile.ZipFile(self.host, 'w', compression=zipfile.ZIP_STORED) as archive:
            for directory in ('Payload/', subject.APP_ROOT + '/', framework + '/',
                              framework + '/_CodeSignature/', resource + '/',
                              extension + '/', subject.source_helpers.KIT_ROOT + '/'):
                archive.writestr(directory, b'')
            for directory in kwargs.get('framework_dirs', ()):
                archive.writestr(directory, b'')
            for name, data in rows:
                archive.writestr(name, data)
        return rows

    def guest_files(self, *, extra=()):
        info = {
            'CFBundleIdentifier': merge_host.GUEST_ID,
            'CFBundleVersion': '470044',
            'CFBundleShortVersionString': '47.0.0',
            'CFBundleExecutable': 'NativeGuest',
            'CFBundlePackageType': 'FMWK',
            'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        }
        return {
            merge_host.GUEST_ROOT + '/Info.plist': plist(info),
            merge_host.GUEST_ROOT + '/NativeGuest': self.main_bytes,
            merge_host.GUEST_ROOT + '/Frameworks/Fixture.framework/Fixture':
                b'synthetic nested framework only',
            merge_host.GUEST_ROOT + '/Resources/fixture.dat': b'synthetic resource only',
            self.resource_policy[2]: self.resource_bytes,
            **dict(extra),
        }

    def guest_manifest(self, files):
        original = self.profile['original_main_bundle']
        adaptation = self.profile['main_adaptation']
        file_rows = []
        for path, data in files.items():
            if path == merge_host.GUEST_ROOT + '/Info.plist':
                source = original['path'] + '/Info.plist'
                action = 'prepare_framework_metadata'
            elif path == merge_host.GUEST_ROOT + '/NativeGuest':
                source = original['path'] + '/' + original['executable']
                action = 'prepare_main_executable'
            elif path == self.resource_policy[2]:
                source = self.resource_policy[1]
                action = merge_host.bundled.ACTION
            elif path.endswith('/Fixture'):
                source = original['path'] + '/Frameworks/Fixture.framework/Fixture'
                action = 'review_embedded_code'
            else:
                source = original['path'] + '/Resources/fixture.dat'
                action = 'review_resource'
            file_rows.append({
                'source': source,
                'path': path,
                'size': len(data),
                'sha256_before_signing': sha(data),
                'action': action,
            })
        return {
            'schema': 2,
            'private_test_only': True,
            'status': 'unsigned_guest_requires_host_integration',
            'installation_authorized': False,
            'runtime_manifest': False,
            'input_sha256': self.profile['input_sha256'],
            'plan_sha256': 'b' * 64,
            'original_main_bundle': dict(original),
            'main_adaptation': {
                'status': 'prepared_requires_signing_and_review',
                'installation_authorized': False,
                'input_sha256': adaptation['input_sha256'],
                'output_sha256': adaptation['output_sha256'],
                'size': adaptation['size'],
                'entrypoint_offset': 1,
                'install_name': 'NativeGuest',
                'modified_prefix_bytes': 2,
                'original_signature_invalidated': True,
                'unverified': ['runtime_loading'],
            },
            'files': file_rows,
            'omissions': [
                {'source': original['path'] + '/PlugIns/Share.appex/Info.plist',
                 'action': 'exclude_extension'},
                {'source': original['path'] + '/_CodeSignature/CodeResources',
                 'action': 'omit_obsolete_signature'},
            ],
            'unverified': ['host_integration', 'post_signing_hashes'],
            'layout_review_flags': ['synthetic_fixture_only'],
        }

    def write_guest(self, *, extra=(), manifest_mutator=None, extra_zip=(),
                    directory_entries=(), raw_manifest=None):
        files = self.guest_files(extra=extra)
        manifest = self.guest_manifest(files)
        if manifest_mutator:
            manifest_mutator(manifest)
        with zipfile.ZipFile(self.guest, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, data in files.items():
                archive.writestr(name, data)
            for directory in directory_entries:
                archive.writestr(directory, b'')
            for name, data in extra_zip:
                archive.writestr(name, data)
            encoded = (raw_manifest if raw_manifest is not None else
                       json.dumps(manifest, sort_keys=True, ensure_ascii=True).encode('ascii'))
            archive.writestr(merge_host.MANIFEST, encoded)
        return files, manifest

    def request(self, **kwargs):
        options = {
            'expected_host_sha256': sha(self.host.read_bytes()),
            'expected_guest_sha256': sha(self.guest.read_bytes()),
            'acknowledge_unverified_runtime': True,
            'acknowledge_private_bundled_resources': True,
        }
        options.update(kwargs)
        return subject.merge_tiktok47(self.host, self.guest, self.output, **options)

    def reject(self, code, **kwargs):
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.request(**kwargs)
        self.assertEqual(str(caught.exception), code)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.tiktok47-merge-*')), [])

    def test_success_copies_only_reviewed_framework_and_preserves_host_bytes(self):
        original_host = self.host.read_bytes()
        original_guest = self.guest.read_bytes()
        host_rows = {name: data for name, data in self.host_entries()[0]}
        guest_rows, _ = self.write_guest()
        original_guest = self.guest.read_bytes()

        report = self.request()
        self.assertEqual(self.host.read_bytes(), original_host)
        self.assertEqual(self.guest.read_bytes(), original_guest)
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['valid_final_signature'])
        self.assertFalse(report['runtime_verified'])
        self.assertTrue(report['requires_sidestore_resigning'])
        self.assertEqual(report['output_sha256'], sha(self.output.read_bytes()))
        self.assertTrue(report['is_ipa'])

        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            names = set(archive.namelist())
            self.assertNotIn(merge_host.MANIFEST, names)
            self.assertNotIn(merge_host.LEGACY_PAYLOAD, names)
            self.assertFalse(any(name.startswith(merge_host.RESOURCE_BUNDLE + '/')
                                 for name in names))
            self.assertFalse(any(shared_name.lower().endswith('/_codesignature/coderesources')
                                 for shared_name in names))
            self.assertIn(subject.APP_ROOT + '/PlugIns/LiveProcess.appex/LiveProcess', names)
            self.assertIn(subject.APP_ROOT + '/Frameworks/CalcVaultKit.framework/CalcVaultKit', names)
            self.assertIn(subject.APP_ROOT + '/Settings.bundle/Settings.plist', names)
            self.assertEqual(archive.read(subject.APP_ROOT + '/Settings.bundle/Settings.plist'),
                             host_rows[subject.APP_ROOT + '/Settings.bundle/Settings.plist'])
            for guest_path, data in guest_rows.items():
                self.assertEqual(archive.read(subject.APP_ROOT + '/' + guest_path), data)
            descriptor = plistlib.loads(archive.read(merge_host.DESCRIPTOR))
            self.assertEqual(descriptor, {'schema': 1, 'bundleIdentifier': merge_host.GUEST_ID,
                                          'bundleVersion': '470044',
                                          'executable': 'NativeGuest'})
            host_info = plistlib.loads(archive.read(subject.APP_ROOT + '/Info.plist'))
            self.assertEqual(host_info['CVNativeIntegrationStage'], subject.PRIVATE_STAGE)
            self.assertEqual(host_info['CVNativeGuestKind'], subject.PRIVATE_KIND)
            scope = json.loads(archive.read(merge_host.PRIVATE_SCOPE))
            self.assertTrue(scope['private_test_only'])
            self.assertEqual(scope['guest_input_sha256'], self.resource_input_sha)

    def test_requires_both_explicit_strict_acknowledgements(self):
        self.reject('unverified_runtime_acknowledgement_required',
                    acknowledge_unverified_runtime=False)
        self.reject('unverified_runtime_acknowledgement_required',
                    acknowledge_unverified_runtime=1)
        self.reject('private_resource_acknowledgement_required',
                    acknowledge_private_bundled_resources=False)
        self.reject('private_resource_acknowledgement_required',
                    acknowledge_private_bundled_resources=1)

    def test_requires_digest_bound_inputs_and_correct_path_types(self):
        self.reject('host_digest_mismatch', expected_host_sha256='0' * 64)
        self.reject('guest_digest_mismatch', expected_guest_sha256='0' * 64)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^invalid_package_file_type$'):
            subject.merge_tiktok47(self.guest, self.host, self.output,
                                   expected_host_sha256=sha(self.host.read_bytes()),
                                   expected_guest_sha256=sha(self.guest.read_bytes()),
                                   acknowledge_unverified_runtime=True,
                                   acknowledge_private_bundled_resources=True)
        self.assertFalse(self.output.exists())

    def test_requires_schema2_private_test_manifest_and_exact_profile(self):
        for value in (False, 1, 'true'):
            self.write_guest(manifest_mutator=lambda manifest, value=value:
                             manifest.__setitem__('private_test_only', value))
            self.reject('private_resource_acknowledgement_required')

        self.write_guest(manifest_mutator=lambda manifest: manifest.update(schema=1))
        self.reject('private_resource_acknowledgement_required')

        mutations = (
            ('original_main_bundle', 'path', 'Payload/Other.app', 'unexpected_guest_identity'),
            ('original_main_bundle', 'identifier', 'org.example.fake', 'unexpected_guest_identity'),
            ('original_main_bundle', 'version', '47.0.1', 'unexpected_guest_identity'),
            ('original_main_bundle', 'build', '470045', 'unexpected_guest_identity'),
            ('original_main_bundle', 'executable', 'Other', 'unexpected_guest_identity'),
            ('main_adaptation', 'input_sha256', 'e' * 64, 'unexpected_guest_main_pins'),
            ('main_adaptation', 'output_sha256', 'f' * 64, 'unexpected_guest_main_pins'),
            ('main_adaptation', 'size', 73393, 'unexpected_guest_main_pins'),
        )
        for group, key, value, code in mutations:
            with self.subTest(group=group, key=key):
                self.write_guest(manifest_mutator=lambda manifest, group=group, key=key, value=value:
                                 manifest[group].__setitem__(key, value))
                self.reject(code)

        self.write_guest(manifest_mutator=lambda manifest:
                         manifest.__setitem__('input_sha256', 'e' * 64))
        self.reject('guest_original_digest_mismatch')

    def test_rejects_nonmatching_resource_rows_and_member_bytes(self):
        mutations = (
            ('source', 'Payload/TikTok.app/SessionCheck.bundle/other.p12',
             'unapproved_bundled_resource'),
            ('path', 'Frameworks/NativeGuest.framework/Elsewhere/private_key.p12',
             'unapproved_bundled_resource'),
            ('size', len(self.resource_bytes) + 1, 'unapproved_bundled_resource'),
            ('sha256_before_signing', 'e' * 64, 'unapproved_bundled_resource'),
            ('action', 'review_resource', 'invalid_guest_manifest'),
        )
        for field, value, code in mutations:
            with self.subTest(field=field):
                def mutate(manifest, field=field, value=value):
                    row = next(row for row in manifest['files']
                               if row['action'] == merge_host.bundled.ACTION)
                    row[field] = value
                self.write_guest(manifest_mutator=mutate)
                self.reject(code)

        self.write_guest(extra_zip=[(merge_host.GUEST_ROOT + '/Unexpected', b'not manifested')])
        self.reject('guest_inventory_mismatch')
        self.write_guest(directory_entries=[merge_host.GUEST_ROOT + '/EmptyDirectory/'])
        self.reject('invalid_guest_inventory')

    def test_hashes_all_guest_members_and_checks_crc(self):
        files, _ = self.write_guest()
        corrupt_files = dict(files)
        resource_path = merge_host.GUEST_ROOT + '/Resources/fixture.dat'
        corrupt_files[resource_path] = b'x' * len(files[resource_path])
        # The manifest stays bound to the original bytes, while the ZIP itself is
        # rehashed by request() so the member-level digest check is reached.
        with zipfile.ZipFile(self.guest, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, data in corrupt_files.items():
                archive.writestr(name, data)
            archive.writestr(merge_host.MANIFEST,
                             json.dumps(self.guest_manifest(files), sort_keys=True).encode('ascii'))
        self.reject('guest_member_digest_mismatch')

        self.write_guest()
        raw = bytearray(self.guest.read_bytes())
        needle = self.main_bytes
        offset = raw.find(needle)
        self.assertGreaterEqual(offset, 0)
        raw[offset] ^= 1
        self.guest.write_bytes(raw)
        self.reject('invalid_guest_member')

    def test_rejects_host_marker_material_framework_extras_and_signature_spellings(self):
        rows, _framework, _resource, _extension = self.host_entries()
        self.write_host(extra=((merge_host.PRIVATE_SCOPE, b'replayed private marker'),))
        self.reject('reserved_private_scope_marker')

        self.write_host(extra=(('Payload/LiveContainer.app/Unexpected.p12', b'not a key'),))
        self.reject('signing_material_forbidden')

        self.write_host(framework_extra=(
            ('Payload/LiveContainer.app/Frameworks/NativeGuest.framework/Extra',
             b'unapproved synthetic descendant'),))
        self.reject('unexpected_synthetic_framework_layout')

        self.write_host(framework_dirs=(
            'Payload/LiveContainer.app/Frameworks/NativeGuest.framework/Empty/',))
        self.reject('unexpected_synthetic_framework_layout')

        self.write_host(extra=(('Payload/LiveContainer.app/_CodeSignature/Unexpected', b'x'),))
        self.reject('unexpected_host_signature_metadata')

    def test_rejects_bad_host_stage_and_missing_kit(self):
        self.write_host(host_info_extra={'CVNativeIntegrationStage': 'synthetic-integration-23'})
        self.reject('unexpected_host_marker')
        self.write_host(include_kit=False)
        self.reject('missing_calcvault_kit')

    def test_no_overwrite_in_place_verification_failure_and_source_recheck(self):
        self.output.write_bytes(b'output sentinel')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            self.request()
        self.assertEqual(self.output.read_bytes(), b'output sentinel')
        self.output.unlink()

        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^in_place_merge_forbidden$'):
            subject.merge_tiktok47(
                self.host, self.guest, self.host,
                expected_host_sha256=sha(self.host.read_bytes()),
                expected_guest_sha256=sha(self.guest.read_bytes()),
                acknowledge_unverified_runtime=True,
                acknowledge_private_bundled_resources=True)
        self.assertFalse(self.output.exists())

        with patch.object(subject.shared, 'verify_output',
                          side_effect=ipa_preflight.InspectionError('test_readback')):
            self.reject('test_readback')

        original_write = subject.shared._write_output

        def mutate_input(*args):
            result = original_write(*args)
            with self.guest.open('ab') as incoming:
                incoming.write(b'concurrent synthetic change')
            return result

        with patch.object(subject.shared, '_write_output', side_effect=mutate_input):
            self.reject('input_changed_during_merge')

        self.write_guest()
        with patch.object(subject.os, 'link', side_effect=OSError('SYNTHETIC-MARKER')):
            self.reject('merge_failed')

    def test_cli_uses_explicit_acknowledgements_and_sanitized_json(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = subject.main([
                str(self.host), str(self.guest), str(self.output),
                '--host-sha256', sha(self.host.read_bytes()),
                '--guest-sha256', sha(self.guest.read_bytes()),
            ])
        self.assertEqual(result, 2)
        self.assertEqual(json.loads(stdout.getvalue())['error'],
                         'unverified_runtime_acknowledgement_required')
        self.assertFalse(self.output.exists())

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = subject.main([
                str(self.host), str(self.guest), str(self.output),
                '--host-sha256', sha(self.host.read_bytes()),
                '--guest-sha256', sha(self.guest.read_bytes()),
                '--acknowledge-unverified-runtime',
                '--acknowledge-private-bundled-resources',
            ])
        self.assertEqual(result, 0)
        report = json.loads(stdout.getvalue())
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['valid_final_signature'])
        self.assertNotIn(str(self.host), stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
