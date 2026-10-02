"""Merge the pinned TikTok 47 research framework into a synthetic Build 24 IPA.

The output is an unsigned SideStore re-signing candidate. This tool does not
sign, install, upload, or modify either input.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import stat
import sys
import tempfile
import zipfile
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1] / 'native-social-package-tools'
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import ipa_preflight as preflight  # noqa: E402
import merge_host as shared  # noqa: E402


def _load_source_helpers():
    helper_path = Path(__file__).with_name('merge-private-guest.py')
    spec = importlib.util.spec_from_file_location('_calc_vault_private_guest_helpers', helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError('source_helpers_unavailable')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


source_helpers = _load_source_helpers()

CHUNK = shared.CHUNK
MAX_OUTPUT = shared.MAX_OUTPUT
APP_ROOT = source_helpers.APP_ROOT
HOST_BUILD = '24'
SYNTHETIC_STAGE = 'synthetic-integration-24'
SYNTHETIC_KIND = 'synthetic'
PRIVATE_STAGE = 'private-tiktok47-integration-24'
PRIVATE_KIND = 'tiktok47'
PROFILE = 'newer47'

need = shared.need


def _plist(archive, entries, path, code='invalid_bundle_plist'):
    return source_helpers._plist(archive, entries, path, code)


def _host_preflight(archive, entries, members, host_info):
    names = {member.filename for member in members if not member.is_dir()}
    keys = {preflight.key(name) for name in names}
    member_keys = {preflight.key(member.filename.rstrip('/')) for member in members}
    need(preflight.key(shared.PRIVATE_SCOPE) not in keys and
         preflight.key(shared.PRIVATE_SCOPE) not in member_keys,
         'reserved_private_scope_marker')
    need(preflight.key(shared.LEGACY_PAYLOAD) in keys, 'missing_synthetic_legacy_payload')

    framework_root = APP_ROOT + '/' + shared.GUEST_ROOT
    framework_prefix = preflight.key(framework_root + '/')
    framework_files = {name for name in names
                       if preflight.key(name).startswith(framework_prefix)}
    expected_framework_files = {
        framework_root + '/NativeGuest', framework_root + '/Info.plist',
        framework_root + '/_CodeSignature/CodeResources',
    }
    framework_dirs = {member.filename for member in members if member.is_dir() and
                      preflight.key(member.filename.rstrip('/')).startswith(
                          preflight.key(framework_root + '/'))}
    allowed_framework_dirs = {framework_root + '/', framework_root + '/_CodeSignature/'}
    need(framework_files == expected_framework_files and
         framework_dirs <= allowed_framework_dirs,
         'unexpected_synthetic_framework_layout')

    for name in names:
        if preflight.key(name).find('/_codesignature/') >= 0:
            need(shared.is_signature_metadata(name), 'unexpected_host_signature_metadata')

    resource_prefix = preflight.key(shared.RESOURCE_BUNDLE + '/')
    resource_files = {name for name in names
                      if preflight.key(name).startswith(resource_prefix)}
    expected_resources = {shared.RESOURCE_BUNDLE + '/Info.plist',
                          shared.RESOURCE_BUNDLE + '/GuestInfo.plist'}
    need(resource_files == expected_resources, 'unexpected_synthetic_resource_layout')
    resource_info = _plist(archive, entries, shared.RESOURCE_BUNDLE + '/Info.plist',
                           'invalid_synthetic_resource_metadata')
    need(resource_info.get('CFBundleIdentifier') == shared.SYNTHETIC_RESOURCE_ID and
         resource_info.get('CFBundleName') == 'SyntheticGuestResources' and
         resource_info.get('CFBundlePackageType') == 'BNDL',
         'invalid_synthetic_resource_metadata')
    old_guest_info = _plist(archive, entries, shared.RESOURCE_BUNDLE + '/GuestInfo.plist',
                            'invalid_synthetic_resource_metadata')
    need(old_guest_info.get('CFBundleIdentifier') == shared.SYNTHETIC_GUEST_ID,
         'invalid_synthetic_resource_metadata')
    need(host_info.get('CFBundleVersion') == HOST_BUILD and
         host_info.get('CVNativeIntegrationStage') == SYNTHETIC_STAGE and
         host_info.get('CVNativeGuestKind') == SYNTHETIC_KIND,
         'unexpected_host_marker')


def _host_info_after_merge(host_info):
    result = dict(host_info)
    result['CVNativeIntegrationStage'] = PRIVATE_STAGE
    result['CVNativeGuestKind'] = PRIVATE_KIND
    return plistlib.dumps(result, fmt=plistlib.FMT_XML, sort_keys=True)


def _output_plan(host_archive, guest_records, guest_info, host_info):
    plan = shared._build_entries(host_archive, guest_records, guest_info,
                                 private_test_only=True)
    info_key = preflight.key(APP_ROOT + '/Info.plist')
    found = 0
    replaced = []
    for kind, name, source_info, data, size in plan:
        if preflight.key(name) == info_key:
            need(kind == 'host_file', 'invalid_host_info_plan')
            encoded = _host_info_after_merge(host_info)
            replaced.append(('generated', name, None, encoded, len(encoded)))
            found += 1
        else:
            replaced.append((kind, name, source_info, data, size))
    need(found == 1, 'invalid_host_info_plan')
    return replaced


def _verify_tiktok47_metadata(archive, entries, guest_info, original_host_info,
                              expected_scope):
    host_info = _plist(archive, entries, APP_ROOT + '/Info.plist')
    expected_host_info = dict(original_host_info)
    expected_host_info['CVNativeIntegrationStage'] = PRIVATE_STAGE
    expected_host_info['CVNativeGuestKind'] = PRIVATE_KIND
    need(host_info == expected_host_info, 'unexpected_host_info_changes')

    guest_path = APP_ROOT + '/' + shared.GUEST_ROOT + '/Info.plist'
    merged_guest_info = _plist(archive, entries, guest_path,
                               'invalid_guest_framework_metadata')
    need(merged_guest_info == guest_info and
         merged_guest_info.get('CFBundleIdentifier') == shared.GUEST_ID and
         merged_guest_info.get('CFBundleVersion') == '470044' and
         merged_guest_info.get('CFBundleShortVersionString') == '47.0.0' and
         merged_guest_info.get('CFBundleExecutable') == 'NativeGuest' and
         merged_guest_info.get('CFBundlePackageType') == 'FMWK',
         'unexpected_guest_framework_metadata')

    descriptor = _plist(archive, entries, shared.DESCRIPTOR, 'invalid_guest_descriptor')
    need(descriptor == {'schema': 1, 'bundleIdentifier': shared.GUEST_ID,
                        'bundleVersion': '470044', 'executable': 'NativeGuest'},
         'invalid_guest_descriptor')
    scope_path = shared.PRIVATE_SCOPE
    need(scope_path in entries and archive.read(entries[scope_path]) == expected_scope,
         'invalid_private_scope_marker')


def _verify_output(output_stream, expected, guest_info, host_info, expected_scope):
    shared.verify_output(output_stream, expected)
    output_stream.seek(0)
    try:
        with zipfile.ZipFile(output_stream, 'r') as archive:
            entries = preflight.archive_entries(archive, 'extended-review')
            members = source_helpers._archive_members(archive, entries)
            names = [member.filename for member in members]
            need(not any(shared.is_signature_metadata(name) for name in names),
                 'output_signature_metadata_present')
            need(not any(preflight.key(name).startswith(
                preflight.key(shared.RESOURCE_BUNDLE + '/')) for name in entries) and
                 preflight.key(shared.LEGACY_PAYLOAD) not in
                 {preflight.key(name) for name in entries},
                 'synthetic_host_payload_present')
            _verify_tiktok47_metadata(archive, entries, guest_info, host_info, expected_scope)
            source_helpers._host_bundle(
                archive, entries, members, build=HOST_BUILD,
                stage=PRIVATE_STAGE, kind=PRIVATE_KIND,
                require_calcvault_host=True, require_kit=True)
            scope = json.loads(archive.read(shared.PRIVATE_SCOPE).decode('ascii'))
            expected_scope_value = json.loads(expected_scope.decode('ascii'))
            need(scope == expected_scope_value, 'invalid_private_scope_marker')
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_verification_failed') from None
    output_stream.seek(0)


def merge_tiktok47(host_path, guest_path, output_path, *, expected_host_sha256,
                   expected_guest_sha256, acknowledge_unverified_runtime=False,
                   acknowledge_private_bundled_resources=False):
    """Merge the pinned TikTok 47 framework into a synthetic Build 24 host."""
    host_path, guest_path, output_path = map(Path, (host_path, guest_path, output_path))
    host_stream = guest_stream = None
    host_archive = guest_archive = None
    temporary = None
    try:
        need(type(acknowledge_unverified_runtime) is bool and
             acknowledge_unverified_runtime,
             'unverified_runtime_acknowledgement_required')
        need(type(acknowledge_private_bundled_resources) is bool and
             acknowledge_private_bundled_resources,
             'private_resource_acknowledgement_required')
        expected_host_sha256 = shared.digest_text(expected_host_sha256, 'invalid_host_digest')
        expected_guest_sha256 = shared.digest_text(expected_guest_sha256, 'invalid_guest_digest')
        need(host_path.suffix.lower() == '.ipa' and guest_path.suffix.lower() == '.zip' and
             output_path.suffix.lower() == '.ipa', 'invalid_package_file_type')
        parent = output_path.parent.resolve(strict=True)
        output_target = parent / output_path.name
        need(host_path.resolve(strict=True) != output_target and
             guest_path.resolve(strict=True) != output_target,
             'in_place_merge_forbidden')
        try:
            output_target.lstat()
        except FileNotFoundError:
            pass
        else:
            raise preflight.InspectionError('output_already_exists')

        host_stream, host_digest, host_identity = shared.archive_size_and_hash(host_path)
        guest_stream, guest_digest, guest_identity = shared.archive_size_and_hash(guest_path)
        need(host_digest == expected_host_sha256, 'host_digest_mismatch')
        need(guest_digest == expected_guest_sha256, 'guest_digest_mismatch')

        host_archive, host_entries, _host_names, _host_total = shared.checked_archive(
            host_stream, host_identity[2], 'extended-review')
        host_members = source_helpers._archive_members(host_archive, host_entries)
        host_info = source_helpers._host_bundle(
            host_archive, host_entries, host_members, build=HOST_BUILD,
            stage=SYNTHETIC_STAGE, kind=SYNTHETIC_KIND,
            require_synthetic=True, require_calcvault_host=True, require_kit=True)
        _host_preflight(host_archive, host_entries, host_members, host_info)

        guest_input_sha256 = shared.TIKTOK47_PROFILE['input_sha256']
        guest_archive, guest_entries, guest_names, _guest_total = shared.checked_archive(
            guest_stream, guest_identity[2], 'extended-review',
            approved_resource_input_sha256=guest_input_sha256)
        source_helpers._archive_members(guest_archive, guest_entries)
        manifest, guest_files, guest_records, guest_info = shared._verify_guest(
            guest_archive, guest_entries, guest_names, guest_input_sha256,
            acknowledge_private_bundled_resources=True, guest_profile=PROFILE)
        need(manifest.get('private_test_only') is True and manifest.get('schema') == 2,
             'private_resource_acknowledgement_required')
        output_plan = _output_plan(host_archive, guest_records, guest_info, host_info)
        scope_entry = next((row for row in output_plan
                            if row[0] == 'generated' and
                            preflight.key(row[1]) == preflight.key(shared.PRIVATE_SCOPE)), None)
        need(scope_entry is not None, 'invalid_private_scope_marker')
        expected_scope = scope_entry[3]

        descriptor_fd, temporary = tempfile.mkstemp(
            prefix='.tiktok47-merge-', suffix='.ipa', dir=parent)
        with os.fdopen(descriptor_fd, 'w+b') as output:
            expected_output = shared._write_output(host_archive, guest_archive,
                                                   output_plan, output)
            output.flush()
            need(output.tell() <= MAX_OUTPUT, 'output_size_limit')
            _verify_output(output, expected_output, guest_info, host_info, expected_scope)
            output.seek(0)
            output_digest = hashlib.file_digest(output, 'sha256').hexdigest()
            os.fsync(output.fileno())

        shared.recheck_input(host_path, host_stream, expected_host_sha256, host_identity)
        shared.recheck_input(guest_path, guest_stream, expected_guest_sha256, guest_identity)
        os.link(temporary, output_target)
        return {
            'status': 'merged_tiktok47_research_host_requires_sidestore_resigning',
            'installation_authorized': False,
            'requires_sidestore_resigning': True,
            'valid_final_signature': False,
            'runtime_verified': False,
            'host_sha256': host_digest,
            'guest_sha256': guest_digest,
            'guest_input_sha256': guest_input_sha256,
            'output_sha256': output_digest,
            'guest_files': len(guest_files),
            'output_files': len(expected_output),
            'removed_signature_files': sum(1 for name in host_entries
                                           if shared.is_signature_metadata(name)),
            'is_ipa': True,
        }
    except preflight.InspectionError:
        raise
    except FileExistsError:
        raise preflight.InspectionError('output_already_exists') from None
    except Exception:
        raise preflight.InspectionError('merge_failed') from None
    finally:
        if host_archive is not None:
            host_archive.close()
        if guest_archive is not None:
            guest_archive.close()
        if host_stream is not None:
            host_stream.close()
        if guest_stream is not None:
            guest_stream.close()
        if temporary is not None:
            try:
                Path(temporary).unlink(missing_ok=True)
            except OSError:
                raise preflight.InspectionError('temporary_cleanup_failed') from None


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'valid_final_signature': False, 'error': 'invalid_arguments'}))
        raise SystemExit(2)


def main(argv=None):
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path)
    parser.add_argument('guest', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--host-sha256', required=True)
    parser.add_argument('--guest-sha256', required=True)
    parser.add_argument('--acknowledge-unverified-runtime', action='store_true')
    parser.add_argument('--acknowledge-private-bundled-resources', action='store_true')
    args = parser.parse_args(argv)
    try:
        report = merge_tiktok47(
            args.host, args.guest, args.output,
            expected_host_sha256=args.host_sha256,
            expected_guest_sha256=args.guest_sha256,
            acknowledge_unverified_runtime=args.acknowledge_unverified_runtime,
            acknowledge_private_bundled_resources=args.acknowledge_private_bundled_resources)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'valid_final_signature': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
