"""Synthetic-only tests for the private Build 20 host merger."""

import hashlib
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import ipa_preflight
import merge_host as subject


def plist(value):
    return plistlib.dumps(value, sort_keys=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def guest_manifest(files, input_digest, *, original_id=subject.GUEST_ID,
                   original_build=subject.GUEST_BUILD, status=None, flags=None):
    executable = files[subject.GUEST_ROOT + '/NativeGuest']
    return {
        'schema': 1,
        'status': status or 'unsigned_guest_requires_host_integration',
        'installation_authorized': False,
        'runtime_manifest': False,
        'input_sha256': input_digest,
        'plan_sha256': 'b' * 64,
        'original_main_bundle': {
            'path': 'Payload/TikTok.app', 'identifier': original_id,
            'version': '43.9.0', 'build': original_build, 'executable': 'TikTok',
        },
        'main_adaptation': {
            'status': 'prepared_requires_signing_and_review',
            'installation_authorized': False,
            'input_sha256': 'a' * 64,
            'output_sha256': sha(executable),
            'size': len(executable),
            'entrypoint_offset': 64,
            'install_name': 'NativeGuest',
            'modified_prefix_bytes': 128,
            'original_signature_invalidated': True,
            'unverified': ['signature_validity', 'runtime_loading'],
        },
        'files': [
            {'source': ('Payload/TikTok.app/Info.plist' if path == subject.GUEST_ROOT + '/Info.plist'
                        else 'Payload/TikTok.app/TikTok' if path == subject.GUEST_ROOT + '/NativeGuest'
                        else 'Payload/TikTok.app/' + path[len(subject.GUEST_ROOT) + 1:]),
             'path': path, 'size': len(data), 'sha256_before_signing': sha(data),
             'action': ('prepare_framework_metadata' if path == subject.GUEST_ROOT + '/Info.plist'
                        else 'prepare_main_executable' if path == subject.GUEST_ROOT + '/NativeGuest'
                        else 'review_embedded_code' if path.endswith('/Social')
                        else 'review_resource')}
            for path, data in files.items()
        ],
        'omissions': [
            {'source': 'Payload/TikTok.app/PlugIns/Share.appex/Info.plist',
             'action': 'exclude_extension'},
            {'source': 'Payload/TikTok.app/Resources/private.pem', 'action': 'exclude_material'},
            {'source': 'Payload/TikTok.app/_CodeSignature/CodeResources',
             'action': 'omit_obsolete_signature'},
        ],
        'unverified': flags or ['signature_validity', 'host_integration', 'post_signing_hashes'],
        'layout_review_flags': ['dependency_layout_review_required'],
    }


class MergeHostTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.host = self.folder / 'Build20.ipa'
        self.guest = self.folder / 'GuestPackage.zip'
        self.output = self.folder / 'Merged.ipa'
        self.original_guest_digest = 'c' * 64
        self.write_host()
        self.write_guest()

    def host_entries(self, *, host_id=subject.HOST_ID, host_version='20', mode=1,
                     extra=(), extension_id=subject.EXTENSION_ID,
                     framework_extra=(), resource_extra=()):
        root = subject.HOST_ROOT
        framework = root + '/' + subject.GUEST_ROOT
        resource = subject.RESOURCE_BUNDLE
        host_info = {'CFBundleIdentifier': host_id, 'CFBundleVersion': host_version,
                     'CFBundleExecutable': subject.HOST_EXECUTABLE,
                     'CVLPFrameworkGuestMode': mode}
        extension_info = {'CFBundleIdentifier': extension_id,
                          'CFBundleVersion': '20', 'CFBundleExecutable': 'LiveProcess'}
        framework_info = {'CFBundleIdentifier': subject.SYNTHETIC_GUEST_ID,
                          'CFBundleVersion': '1', 'CFBundleExecutable': 'NativeGuest',
                          'CFBundlePackageType': 'FMWK'}
        descriptor = {'schema': 1, 'bundleIdentifier': subject.SYNTHETIC_GUEST_ID,
                      'bundleVersion': '1', 'executable': 'NativeGuest'}
        resource_info = {'CFBundleIdentifier': subject.SYNTHETIC_RESOURCE_ID,
                         'CFBundleName': 'SyntheticGuestResources',
                         'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '19'}
        old_guest = {'CFBundleIdentifier': subject.SYNTHETIC_GUEST_ID,
                     'CFBundleVersion': '1', 'CFBundleExecutable': 'SyntheticGuest'}
        return [
            (root + '/Info.plist', plist(host_info)),
            (root + '/LiveContainer', b'host-main-binary-with-signature-sentinel'),
            (root + '/_CodeSignature/CodeResources', b'obsolete-host-code-resources'),
            (root + '/PlugIns/LiveProcess.appex/Info.plist', plist(extension_info)),
            (root + '/PlugIns/LiveProcess.appex/LiveProcess',
             b'extension-binary-with-entitlement-signature-sentinel'),
            (root + '/PlugIns/LiveProcess.appex/_CodeSignature/CodeResources', b'extension-resource-seal'),
            (framework + '/Info.plist', plist(framework_info)),
            (framework + '/NativeGuest', b'synthetic-placeholder-payload'),
            (framework + '/_CodeSignature/CodeResources', b'old-framework-seal'),
            (subject.DESCRIPTOR, plist(descriptor)),
            (subject.LEGACY_PAYLOAD, b'legacy synthetic dylib'),
            (resource + '/Info.plist', plist(resource_info)),
            (resource + '/GuestInfo.plist', plist(old_guest)),
            (root + '/Settings.bundle/Settings.plist', b'host-settings-sentinel'),
            *framework_extra, *resource_extra, *extra,
        ]

    def write_host(self, **kwargs):
        with zipfile.ZipFile(self.host, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('Payload/', b'')
            archive.writestr(subject.HOST_ROOT + '/', b'')
            archive.writestr(subject.HOST_ROOT + '/Frameworks/', b'')
            archive.writestr(subject.HOST_ROOT + '/Frameworks/NativeGuest.framework/', b'')
            archive.writestr(subject.HOST_ROOT + '/Frameworks/NativeGuest.framework/_CodeSignature/', b'')
            archive.writestr(subject.RESOURCE_BUNDLE + '/', b'')
            for name, data in self.host_entries(**kwargs):
                archive.writestr(name, data)
        return self.host_entries(**kwargs)

    def guest_files(self, *, guest_id=subject.GUEST_ID, build=subject.GUEST_BUILD,
                    extra=(), add_metadata=None):
        info = {'CFBundleIdentifier': guest_id, 'CFBundleVersion': build,
                'CFBundleShortVersionString': '43.9.0', 'CFBundleExecutable': 'NativeGuest',
                'CFBundlePackageType': 'FMWK'}
        if add_metadata:
            info.update(add_metadata)
        return {
            subject.GUEST_ROOT + '/Info.plist': plist(info),
            subject.GUEST_ROOT + '/NativeGuest': b'prepared synthetic guest executable' * 12,
            subject.GUEST_ROOT + '/Frameworks/Social.framework/Social': b'synthetic nested framework code',
            **dict(extra),
        }

    def write_guest(self, *, guest_id=subject.GUEST_ID, build=subject.GUEST_BUILD,
                    extra=(), add_metadata=None, manifest_mutator=None,
                    extra_zip=(), manifest_raw=None, original_id=None,
                    original_build=None):
        files = self.guest_files(guest_id=guest_id, build=build, extra=extra,
                                 add_metadata=add_metadata)
        manifest = guest_manifest(files, self.original_guest_digest,
                                  original_id=original_id or guest_id,
                                  original_build=original_build or build)
        if manifest_mutator:
            manifest_mutator(manifest)
        with zipfile.ZipFile(self.guest, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, data in files.items():
                archive.writestr(name, data)
            for name, data in extra_zip:
                archive.writestr(name, data)
            encoded = manifest_raw if manifest_raw is not None else json.dumps(
                manifest, sort_keys=True, ensure_ascii=True).encode('ascii')
            archive.writestr(subject.MANIFEST, encoded)
        return files, manifest

    def request(self, **kwargs):
        request = {'expected_host_sha256': sha(self.host.read_bytes()),
                   'expected_guest_sha256': sha(self.guest.read_bytes()),
                   'expected_guest_input_sha256': self.original_guest_digest,
                   'acknowledge_unverified_runtime': True}
        request.update(kwargs)
        return subject.merge_host(self.host, self.guest, self.output, **request)

    def reject(self, code, **kwargs):
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            self.request(**kwargs)
        self.assertEqual(str(caught.exception), code)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.folder.glob('.host-merge-*')), [])

    def test_success_replaces_only_reviewed_placeholder_and_preserves_host_bytes(self):
        original_host = self.host.read_bytes()
        host = {name: data for name, data in self.host_entries()}
        guest, _ = self.write_guest()
        # Snapshot the final input, not the earlier setup ZIP: recreating it can
        # legitimately change ZIP timestamps before the merger runs.
        original_guest = self.guest.read_bytes()
        report = self.request()
        self.assertEqual(self.host.read_bytes(), original_host)
        self.assertEqual(self.guest.read_bytes(), original_guest)
        self.assertFalse(report['installation_authorized'])
        self.assertFalse(report['runtime_verified'])
        self.assertTrue(report['requires_fresh_signing'])
        self.assertEqual(report['output_sha256'], sha(self.output.read_bytes()))
        self.assertEqual(report['guest_files'], len(guest))
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            names = set(archive.namelist())
            self.assertNotIn(subject.MANIFEST, names)
            self.assertFalse(any(subject.RESOURCE_BUNDLE in n for n in names))
            self.assertNotIn(subject.LEGACY_PAYLOAD, names)
            self.assertFalse(any(subject.HOST_ROOT + '/_CodeSignature/' in n for n in names))
            self.assertFalse(any('/_CodeSignature/CodeResources' in n for n in names))
            self.assertEqual(archive.read(subject.HOST_ROOT + '/Info.plist'),
                             host[subject.HOST_ROOT + '/Info.plist'])
            self.assertEqual(archive.read(subject.HOST_ROOT + '/LiveContainer'),
                             host[subject.HOST_ROOT + '/LiveContainer'])
            self.assertEqual(archive.read(subject.EXTENSION_ROOT + '/LiveProcess'),
                             host[subject.EXTENSION_ROOT + '/LiveProcess'])
            self.assertEqual(archive.read(subject.HOST_ROOT + '/Settings.bundle/Settings.plist'),
                             host[subject.HOST_ROOT + '/Settings.bundle/Settings.plist'])
            for path, data in guest.items():
                self.assertEqual(archive.read(subject.HOST_ROOT + '/' + path), data)
            descriptor = plistlib.loads(archive.read(subject.DESCRIPTOR))
            self.assertEqual(descriptor, {'schema': 1, 'bundleIdentifier': subject.GUEST_ID,
                                          'bundleVersion': subject.GUEST_BUILD,
                                          'executable': 'NativeGuest'})

    def test_acknowledgement_and_three_digest_bindings_are_required(self):
        self.reject('unverified_runtime_acknowledgement_required',
                    acknowledge_unverified_runtime=False)
        cases = [
            ('host_digest_mismatch', {'expected_host_sha256': '0' * 64}),
            ('guest_digest_mismatch', {'expected_guest_sha256': '0' * 64}),
            ('guest_original_digest_mismatch', {'expected_guest_input_sha256': 'd' * 64}),
        ]
        for code, changed in cases:
            with self.subTest(code=code):
                with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
                    subject.merge_host(self.host, self.guest, self.output,
                                       expected_host_sha256=changed.get('expected_host_sha256', sha(self.host.read_bytes())),
                                       expected_guest_sha256=changed.get('expected_guest_sha256', sha(self.guest.read_bytes())),
                                       expected_guest_input_sha256=changed.get('expected_guest_input_sha256', self.original_guest_digest),
                                       acknowledge_unverified_runtime=True)
                self.assertFalse(self.output.exists())

    def test_rejects_wrong_host_identity_build_mode_and_extension_inventory(self):
        for kwargs, code in (({'host_id': 'other.example.app'}, 'unexpected_host_identity'),
                             ({'host_version': '19'}, 'unexpected_host_version'),
                             ({'mode': True}, 'unexpected_host_framework_mode'),
                             ({'extension_id': 'other.example.extension'}, 'invalid_extension_metadata')):
            with self.subTest(code=code):
                self.write_host(**kwargs)
                with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
                    self.request()
                self.output.unlink(missing_ok=True)
                self.write_host()

        self.write_host(extra=[(subject.HOST_ROOT + '/PlugIns/Other.appex/Info.plist',
                                plist({'CFBundleIdentifier': 'other', 'CFBundleExecutable': 'Other'})),
                               (subject.HOST_ROOT + '/PlugIns/Other.appex/Other', b'x')])
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^unexpected_host_extension$'):
            self.request()
        self.output.unlink(missing_ok=True)
        self.write_host(extra=[('Payload/Other.app/Info.plist', plist({}))])
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^unexpected_host_app$'):
            self.request()

    def test_material_names_are_rejected_before_member_open(self):
        material = subject.HOST_ROOT + '/Resources/secrets.p12'
        self.write_host(extra=[(material, b'opaque placeholder bytes')])
        original_open = zipfile.ZipFile.open

        def guarded(archive, entry, *args, **kwargs):
            name = entry.filename if isinstance(entry, zipfile.ZipInfo) else entry
            self.assertNotEqual(name, material)
            return original_open(archive, entry, *args, **kwargs)

        with patch.object(zipfile.ZipFile, 'open', guarded):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^signing_material_forbidden$'):
                self.request()

    def test_rejects_wrong_guest_identity_build_and_root_metadata(self):
        for options in ({'guest_id': 'other.example.app'}, {'build': '439041'}):
            with self.subTest(options=options):
                self.write_guest(**options, original_id=subject.GUEST_ID,
                                 original_build=subject.GUEST_BUILD)
                with self.assertRaisesRegex(ipa_preflight.InspectionError,
                                            '^unexpected_guest_framework_metadata$'):
                    self.request()
                self.output.unlink(missing_ok=True)
                self.write_guest()
        for field, value in (('identifier', 'other.example.app'), ('build', '439041')):
            with self.subTest(original_field=field):
                self.write_guest(manifest_mutator=lambda m, f=field, v=value:
                                 m['original_main_bundle'].__setitem__(f, v))
                with self.assertRaisesRegex(ipa_preflight.InspectionError,
                                            '^unexpected_guest_identity$'):
                    self.request()
                self.output.unlink(missing_ok=True)
                self.write_guest()

    def test_rejects_malformed_manifest_flags_duplicates_and_stale_member_hashes(self):
        self.write_guest(manifest_mutator=lambda m: m.__setitem__('runtime_manifest', True))
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^invalid_guest_manifest$'):
            self.request()
        self.output.unlink(missing_ok=True)

        files, manifest = self.write_guest()
        raw = json.dumps(manifest).encode('ascii')[:-1] + b',"schema":1}'
        self.write_guest(manifest_raw=raw)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^duplicate_manifest_field$'):
            self.request()
        self.output.unlink(missing_ok=True)

        self.write_guest(extra_zip=[(subject.GUEST_ROOT + '/Extra', b'unlisted')])
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^guest_inventory_mismatch$'):
            self.request()
        self.output.unlink(missing_ok=True)

        changed = dict(files)
        executable_name = subject.GUEST_ROOT + '/NativeGuest'
        changed[executable_name] = b'X' + files[executable_name][1:]
        # Keep the original manifest rows, but bind the changed archive digest externally.
        with zipfile.ZipFile(self.guest, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, data in changed.items():
                archive.writestr(name, data)
            archive.writestr(subject.MANIFEST, json.dumps(manifest).encode('ascii'))
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^guest_member_digest_mismatch$'):
            self.request()

    def test_rejects_guest_paths_material_and_product_metadata(self):
        for path, code in ((subject.GUEST_ROOT + '/Nested.app/Info.plist', 'forbidden_guest_member'),
                           (subject.GUEST_ROOT + '/Nested.appex/Info.plist', 'forbidden_guest_member'),
                           (subject.GUEST_ROOT + '/nested/LCAppInfo.plist', 'forbidden_guest_member'),
                           (subject.GUEST_ROOT + '/nested/key.pem', 'signing_material_forbidden'),
                           (subject.GUEST_ROOT + '/_CodeSignature/CodeResources', 'forbidden_guest_member')):
            with self.subTest(path=path):
                extra = [(path, b'synthetic forbidden metadata')]
                self.write_guest(extra=extra)
                with self.assertRaisesRegex(ipa_preflight.InspectionError, '^' + code + '$'):
                    self.request()
                self.output.unlink(missing_ok=True)
                self.write_guest()

        self.write_guest(extra_zip=[(subject.GUEST_ROOT + '/../../escape', b'x')])
        with self.assertRaises(ipa_preflight.InspectionError):
            self.request()

    def test_rejects_unreviewed_host_placeholder_layouts(self):
        self.write_host(framework_extra=[(subject.HOST_ROOT + '/' + subject.GUEST_ROOT + '/Extra', b'x')])
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^unexpected_synthetic_framework_layout$'):
            self.request()
        self.output.unlink(missing_ok=True)
        self.write_host(resource_extra=[(subject.RESOURCE_BUNDLE + '/Unexpected', b'x')])
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^unexpected_synthetic_resource_layout$'):
            self.request()

    def test_no_overwrite_in_place_and_failed_verification_or_publish(self):
        self.output.write_bytes(b'output sentinel')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            self.request()
        self.assertEqual(self.output.read_bytes(), b'output sentinel')
        self.output.unlink()
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^in_place_merge_forbidden$'):
            subject.merge_host(self.host, self.guest, self.host,
                               expected_host_sha256=sha(self.host.read_bytes()),
                               expected_guest_sha256=sha(self.guest.read_bytes()),
                               expected_guest_input_sha256=self.original_guest_digest,
                               acknowledge_unverified_runtime=True)
        with patch.object(subject, 'verify_output', side_effect=ipa_preflight.InspectionError('test_readback')):
            self.reject('test_readback')
        with patch.object(os, 'link', side_effect=OSError('PRIVATE-MARKER')):
            self.reject('merge_failed')

    def test_source_change_check_blocks_publication(self):
        original_write = subject._write_output

        def mutate_source(*args):
            result = original_write(*args)
            with self.guest.open('ab') as source:
                source.write(b'concurrent source mutation')
            return result

        with patch.object(subject, '_write_output', side_effect=mutate_source):
            self.reject('input_changed_during_merge')

    def test_guest_extended_review_limit_and_host_strict_limit(self):
        resource_name = subject.GUEST_ROOT + '/Resources/LargeSyntheticAsset'
        payload = b'R' * 9000
        self.write_guest(extra=[(resource_name, payload)])
        with patch.object(ipa_preflight, 'MAX_ENTRY', 8192), \
                patch.object(ipa_preflight, 'MAX_REVIEW_ENTRY', 16384):
            report = self.request()
            self.assertTrue(report['requires_fresh_signing'])
            with zipfile.ZipFile(self.output) as archive:
                self.assertEqual(archive.read(subject.HOST_ROOT + '/' + resource_name), payload)
            self.output.unlink()

            self.write_host(extra=[(subject.HOST_ROOT + '/Resources/LargeHostAsset', payload)])
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^archive_entry_limit$'):
                self.request()
            self.assertFalse(self.output.exists())

    def test_cleanup_failure_after_publication_is_reported(self):
        with patch.object(Path, 'unlink', side_effect=OSError('PRIVATE-MARKER')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError,
                                        '^temporary_cleanup_failed$'):
                self.request()
        self.assertTrue(self.output.exists())
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
        leftovers = list(self.folder.glob('.host-merge-*'))
        self.assertEqual(len(leftovers), 1)
        leftovers[0].unlink()

    def test_cli_emits_only_sanitized_json(self):
        command = [sys.executable, str(Path(subject.__file__)), str(self.host),
                   str(self.guest), str(self.output), '--host-sha256', sha(self.host.read_bytes()),
                   '--guest-sha256', sha(self.guest.read_bytes()), '--guest-input-sha256',
                   self.original_guest_digest, '--acknowledge-unverified-runtime']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['runtime_verified'])
        self.assertFalse(report['installation_authorized'])
        self.assertTrue(report['requires_fresh_signing'])
        self.assertNotIn(str(self.host), result.stdout)

        command[1] = str(Path(subject.__file__))
        self.output.unlink()
        command[2] = str(self.folder / 'PRIVATE-MARKER.ipa')
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE-MARKER', result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['error'], 'unreadable_input')


if __name__ == '__main__':
    unittest.main()
