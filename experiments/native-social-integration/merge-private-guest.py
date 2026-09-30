"""Merge the pinned Build 20.6 guest into a synthetic Build 23 IPA locally.

The output is a SideStore re-sign candidate, not a valid final signature. This
tool does not sign, install, upload, or modify either input.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
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


PINNED_KNOWN_GUEST_DIGEST = '6e6067eca211d3822763a47d874d08f49b2653a9cc7eccd03f59c2524ec1ab57'
CHUNK = 64 * 1024
MAX_OUTPUT = 2 * 1024**3

APP_ROOT = 'Payload/LiveContainer.app'
HOST_ID = 'com.jaylintaylor.calcvault'
HOST_BUILD = '23'
SYNTHETIC_STAGE = 'synthetic-integration-23'
PRIVATE_STAGE = 'private-tiktok-integration-23'
SYNTHETIC_KIND = 'synthetic'
PRIVATE_KIND = 'tiktok'

EXTENSION_ROOT = APP_ROOT + '/PlugIns/LiveProcess.appex'
EXTENSION_ID = HOST_ID + '.LiveProcess'
HOST_EXECUTABLE = 'LiveContainer'
KIT_ROOT = APP_ROOT + '/Frameworks/CalcVaultKit.framework'
KIT_ID = HOST_ID + '.kit'

GUEST_ROOT = APP_ROOT + '/Frameworks/NativeGuest.framework'
GUEST_ID = 'com.zhiliaoapp.musically'
GUEST_BUILD = '439042'
GUEST_EXECUTABLE = 'NativeGuest'
DESCRIPTOR = APP_ROOT + '/CVLPFrameworkGuest.plist'
SYNTHETIC_GUEST_ID = 'org.example.syntheticnativeguest.app'

HEX_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
ALLOWED_ORIENTATIONS = ['UIInterfaceOrientationPortrait']


def need(condition, code):
    preflight.require(condition, code)


def _digest(value, code):
    need(isinstance(value, str) and HEX_DIGEST.fullmatch(value) is not None, code)
    return value


def _plist(archive, entries, path, code='invalid_bundle_plist'):
    need(path in entries and entries[path].file_size <= 1024**2, code)
    try:
        raw = archive.read(entries[path])
        need(b'<!ENTITY' not in raw, code)
        value = plistlib.loads(raw)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError(code) from None
    need(isinstance(value, dict), code)
    return value


def _archive_members(archive, file_entries):
    """Return every ZIP member and reject ambiguous spelling or directory forms."""
    members = []
    for info in archive.infolist():
        normalized = preflight.checked_name(info.filename)
        expected_name = normalized + '/' if info.is_dir() else normalized
        need(info.filename == expected_name, 'unsafe_archive_path')
        if info.is_dir():
            need(info.file_size == 0, 'invalid_directory_entry')
        else:
            need(info.filename in file_entries, 'invalid_archive_inventory')
        members.append(info)
    return members


def _bundle_roots(names, suffix):
    roots = set()
    for raw_name in names:
        name = preflight.checked_name(raw_name)
        parts = name.split('/')
        for index, part in enumerate(parts):
            if part.lower().endswith(suffix):
                roots.add('/'.join(parts[:index + 1]))
    return roots


def _archive_layout(archive, entries, members):
    names = [member.filename for member in members]
    need(_bundle_roots(names, '.app') == {APP_ROOT}, 'unexpected_host_app')
    need(_bundle_roots(names, '.appex') == {EXTENSION_ROOT}, 'unexpected_host_extension')
    need(all(name == 'Payload/' or name.startswith(APP_ROOT + '/') or name == APP_ROOT + '/'
             for name in names), 'host_path_outside_app')
    need(not any(part.lower() == 'lcappinfo.plist'
                 for name in names for part in preflight.checked_name(name).split('/')),
         'forbidden_host_metadata')
    return names


def _descriptor(archive, entries, expected_identity, expected_version, code):
    value = _plist(archive, entries, DESCRIPTOR, code)
    need(set(value) == {'schema', 'bundleIdentifier', 'bundleVersion', 'executable'} and
         type(value.get('schema')) is int and value['schema'] == 1 and
         value.get('bundleIdentifier') == expected_identity and
         value.get('bundleVersion') == expected_version and
         value.get('executable') == GUEST_EXECUTABLE,
         code)
    return value


def _host_bundle(archive, entries, members, *, build, stage=None, kind=None,
                 require_synthetic=False, require_calcvault_host=False, require_kit=False):
    names = _archive_layout(archive, entries, members)
    need(APP_ROOT + '/Info.plist' in entries, 'unexpected_host_root')
    info = _plist(archive, entries, APP_ROOT + '/Info.plist')
    need(info.get('CFBundleIdentifier') == HOST_ID, 'unexpected_host_identity')
    host_build = info.get('CFBundleVersion')
    need(isinstance(host_build, str) and 0 < len(host_build) <= 64,
         'invalid_host_version')
    if build is not None:
        need(host_build == build, 'unexpected_host_version')
    executable = info.get('CFBundleExecutable')
    need(executable == HOST_EXECUTABLE and APP_ROOT + '/' + executable in entries,
         'invalid_host_executable')
    extension_info = _plist(archive, entries, EXTENSION_ROOT + '/Info.plist',
                            'invalid_extension_metadata')
    need(extension_info.get('CFBundleIdentifier') == EXTENSION_ID and
         extension_info.get('CFBundleExecutable') == 'LiveProcess' and
         EXTENSION_ROOT + '/LiveProcess' in entries,
         'invalid_extension_metadata')

    if stage is not None:
        need(info.get('CVNativeIntegrationStage') == stage, 'unexpected_host_marker')
    if kind is not None:
        need(info.get('CVNativeGuestKind') == kind, 'unexpected_host_guest_kind')

    if require_synthetic or require_calcvault_host:
        need(type(info.get('CVLPFrameworkGuestMode')) is int and
             info.get('CVLPFrameworkGuestMode') == 1, 'unexpected_host_framework_mode')
        need(info.get('UIFileSharingEnabled') is False and
             info.get('LSSupportsOpeningDocumentsInPlace') is False,
             'host_file_sharing_enabled')
        need('NSAppTransportSecurity' not in info and 'UIBackgroundModes' not in info,
             'host_network_or_background_override')
        for key in ('UISupportedInterfaceOrientations',
                    'UISupportedInterfaceOrientations~iphone',
                    'UISupportedInterfaceOrientations~ipad'):
            need(info.get(key) == ALLOWED_ORIENTATIONS, 'host_not_portrait_only')
        if require_synthetic:
            guest_framework = _plist(archive, entries, GUEST_ROOT + '/Info.plist',
                                     'invalid_synthetic_framework_metadata')
            need(guest_framework.get('CFBundleIdentifier') == SYNTHETIC_GUEST_ID and
                 guest_framework.get('CFBundleExecutable') == GUEST_EXECUTABLE and
                 guest_framework.get('CFBundlePackageType') == 'FMWK',
                 'invalid_synthetic_framework_metadata')
            version = guest_framework.get('CFBundleVersion')
            need(version == '1', 'invalid_synthetic_framework_metadata')
            _descriptor(archive, entries, SYNTHETIC_GUEST_ID, version,
                        'invalid_synthetic_descriptor')

    if require_kit:
        kit_info = _plist(archive, entries, KIT_ROOT + '/Info.plist',
                          'missing_calcvault_kit')
        need(kit_info.get('CFBundleIdentifier') == KIT_ID and
             kit_info.get('CFBundleExecutable') == 'CalcVaultKit' and
             kit_info.get('CFBundlePackageType') == 'FMWK' and
             KIT_ROOT + '/CalcVaultKit' in entries,
             'invalid_calcvault_kit')

    # Reject nested app/extension bundle markers even when they are empty directory records.
    for name in names:
        normalized = preflight.checked_name(name)
        guest_prefix = GUEST_ROOT + '/'
        if preflight.key(normalized).startswith(preflight.key(guest_prefix)):
            need(normalized.startswith(guest_prefix), 'unexpected_guest_framework_path')
            parts = normalized[len(guest_prefix):].split('/')
            need(not any(part.lower().endswith(('.app', '.appex')) for part in parts),
                 'nested_guest_app_or_extension')
    return info


def _validate_guest_source(archive, entries, members):
    _archive_layout(archive, entries, members)
    info = _plist(archive, entries, GUEST_ROOT + '/Info.plist',
                  'invalid_guest_framework_metadata')
    need(info.get('CFBundleIdentifier') == GUEST_ID and
         info.get('CFBundleVersion') == GUEST_BUILD and
         info.get('CFBundleExecutable') == GUEST_EXECUTABLE and
         info.get('CFBundlePackageType') == 'FMWK',
         'unexpected_guest_identity_or_version')
    version = info.get('CFBundleVersion')
    _descriptor(archive, entries, GUEST_ID, version, 'invalid_guest_descriptor')
    need(info.get('UISupportedInterfaceOrientations') == ALLOWED_ORIENTATIONS,
         'guest_not_portrait_only')
    if 'UISupportedInterfaceOrientations~iphone' in info:
        need(info['UISupportedInterfaceOrientations~iphone'] == ALLOWED_ORIENTATIONS,
             'guest_not_portrait_only')
    guest_member_names = []
    for member in members:
        normalized = preflight.checked_name(member.filename)
        guest_prefix = GUEST_ROOT + '/'
        if preflight.key(normalized).startswith(preflight.key(guest_prefix)):
            need(normalized.startswith(guest_prefix), 'unexpected_guest_framework_path')
            parts = normalized[len(guest_prefix):].split('/')
            need(not any(part.lower().endswith(('.app', '.appex')) for part in parts),
                 'nested_guest_app_or_extension')
            need(member.filename.startswith(GUEST_ROOT + '/'), 'unexpected_guest_framework_path')
            guest_member_names.append(member.filename)
    need(GUEST_ROOT + '/Info.plist' in guest_member_names and
         GUEST_ROOT + '/' + GUEST_EXECUTABLE in guest_member_names,
         'incomplete_guest_framework')
    return info, guest_member_names


def _host_info_after_merge(host_info):
    result = dict(host_info)
    result['CVNativeIntegrationStage'] = PRIVATE_STAGE
    result['CVNativeGuestKind'] = PRIVATE_KIND
    return plistlib.dumps(result, fmt=plistlib.FMT_XML, sort_keys=True)


def _entry_key(name):
    return preflight.key(preflight.checked_name(name))


def _build_plan(host_members, source_members):
    plan = []
    guest_prefix = preflight.key(GUEST_ROOT + '/')
    descriptor_key = preflight.key(DESCRIPTOR)
    info_key = preflight.key(APP_ROOT + '/Info.plist')

    for member in host_members:
        key = _entry_key(member.filename)
        if key.startswith(guest_prefix) or key == descriptor_key:
            continue
        if key == info_key:
            plan.append(('host_info', member.filename, member, None))
        else:
            plan.append(('host', member.filename, member, None))

    for member in source_members:
        normalized = preflight.checked_name(member.filename)
        key = preflight.key(normalized)
        if key.startswith(guest_prefix):
            need(member.filename.startswith(GUEST_ROOT + '/'), 'unexpected_guest_framework_path')
            plan.append(('guest', member.filename, member, None))
        elif key == descriptor_key:
            plan.append(('descriptor', DESCRIPTOR, member, None))

    seen = set()
    for _kind, name, _source_info, _data in plan:
        key = _entry_key(name)
        need(key not in seen, 'merged_path_collision')
        seen.add(key)
    need(any(kind == 'host_info' for kind, *_ in plan) and
         any(kind == 'descriptor' for kind, *_ in plan), 'incomplete_output_plan')
    return plan


def _copy_member(source_archive, source_info, output_archive, target_name, output_stream):
    info = shared.output_zip_info(target_name, source_info,
                                  executable=bool((source_info.external_attr >> 16) & 0o111))
    digest, count = hashlib.sha256(), 0
    with source_archive.open(source_info, 'r') as source, output_archive.open(info, 'w') as dest:
        while True:
            block = source.read(CHUNK)
            if not block:
                break
            count += len(block)
            need(count <= source_info.file_size, 'member_size_mismatch')
            dest.write(block)
            digest.update(block)
            need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
    need(count == source_info.file_size, 'member_size_mismatch')
    return count, digest.hexdigest()


def _write_output(host_archive, source_archive, plan, host_info, output_stream):
    expected = {}
    try:
        with zipfile.ZipFile(output_stream, 'w', compression=zipfile.ZIP_STORED,
                             allowZip64=False) as output_archive:
            for kind, name, source_info, _data in plan:
                key = _entry_key(name)
                if kind == 'host_info':
                    content = _host_info_after_merge(host_info)
                    output_archive.writestr(shared.output_zip_info(name), content)
                    expected[key] = (name, len(content), hashlib.sha256(content).hexdigest())
                else:
                    input_archive = source_archive if kind in ('guest', 'descriptor') else host_archive
                    size, digest = _copy_member(input_archive, source_info, output_archive,
                                                name, output_stream)
                    expected[key] = (name, size, digest)
                need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
        need(22 <= os.fstat(output_stream.fileno()).st_size <= MAX_OUTPUT,
             'output_size_limit')
        output_stream.flush()
        return expected
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_write_failed') from None


def _verify_output(output_stream, expected, original_host_info):
    try:
        size = os.fstat(output_stream.fileno()).st_size
        need(22 <= size <= MAX_OUTPUT, 'output_size_limit')
        preflight.bound_central_directory(output_stream, size)
        output_stream.seek(0)
        with zipfile.ZipFile(output_stream, 'r') as archive:
            entries = preflight.archive_entries(archive, 'extended-review')
            members = _archive_members(archive, entries)
            names = [member.filename for member in members]
            actual = {}
            for member in members:
                key = _entry_key(member.filename)
                need(key not in actual, 'output_inventory_mismatch')
                actual[key] = member
            need(set(actual) == set(expected), 'output_inventory_mismatch')
            for key, member in actual.items():
                expected_name, expected_size, expected_digest = expected[key]
                need(member.filename == expected_name and member.file_size == expected_size,
                     'output_member_metadata_mismatch')
                digest, count = hashlib.sha256(), 0
                with archive.open(member, 'r') as stream:
                    while True:
                        block = stream.read(CHUNK)
                        if not block:
                            break
                        count += len(block)
                        need(count <= expected_size, 'output_member_size_mismatch')
                        digest.update(block)
                need(count == expected_size and digest.hexdigest() == expected_digest,
                     'output_member_digest_mismatch')
            need(archive.testzip() is None, 'output_crc_mismatch')
            output_info = _plist(archive, entries, APP_ROOT + '/Info.plist')
            expected_info = dict(original_host_info)
            expected_info['CVNativeIntegrationStage'] = PRIVATE_STAGE
            expected_info['CVNativeGuestKind'] = PRIVATE_KIND
            need(output_info == expected_info, 'unexpected_host_info_changes')
            _host_bundle(archive, entries, members, build=HOST_BUILD,
                         stage=PRIVATE_STAGE, kind=PRIVATE_KIND,
                         require_kit=True, require_calcvault_host=True)
            _validate_guest_source(archive, entries, members)
        output_stream.seek(0)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_verification_failed') from None


def merge_private_guest(host_path, known_good_path, output_path, *,
                        expected_host_sha256, _expected_known_guest_digest=PINNED_KNOWN_GUEST_DIGEST):
    """Merge the pinned 20.6 framework and descriptor into a new Build 23 IPA.

    `_expected_known_guest_digest` is an internal test seam. The CLI does not
    expose it and always enforces the fixed known-good input digest.
    """
    host_path, known_good_path, output_path = map(Path, (host_path, known_good_path, output_path))
    host_stream = source_stream = None
    temporary = None
    try:
        expected_host_sha256 = _digest(expected_host_sha256, 'invalid_host_digest')
        expected_known_guest_digest = _digest(_expected_known_guest_digest,
                                              'invalid_known_guest_digest')
        need(host_path.suffix.lower() == '.ipa' and known_good_path.suffix.lower() == '.ipa' and
             output_path.suffix.lower() == '.ipa', 'invalid_package_file_type')

        parent = output_path.parent.resolve(strict=True)
        output_target = parent / output_path.name
        try:
            output_target.lstat()
        except FileNotFoundError:
            pass
        else:
            raise preflight.InspectionError('output_already_exists')
        need(host_path.resolve(strict=True) != output_target and
             known_good_path.resolve(strict=True) != output_target,
             'in_place_merge_forbidden')

        host_stream, host_digest, host_identity = shared.archive_size_and_hash(host_path)
        source_stream, source_digest, source_identity = shared.archive_size_and_hash(known_good_path)
        need(host_digest == expected_host_sha256, 'host_digest_mismatch')
        need(source_digest == expected_known_guest_digest, 'known_guest_digest_mismatch')

        host_archive, host_entries, _host_names, _host_total = shared.checked_archive(
            host_stream, host_identity[2], 'extended-review')
        try:
            source_archive, source_entries, _source_names, _source_total = shared.checked_archive(
                source_stream, source_identity[2], 'extended-review')
            try:
                host_members = _archive_members(host_archive, host_entries)
                source_members = _archive_members(source_archive, source_entries)
                host_info = _host_bundle(host_archive, host_entries, host_members,
                                         build=HOST_BUILD, stage=SYNTHETIC_STAGE,
                                         kind=SYNTHETIC_KIND, require_synthetic=True,
                                         require_calcvault_host=True, require_kit=True)
                source_host = _host_bundle(source_archive, source_entries, source_members,
                                           build='20')
                need(source_host.get('CFBundleIdentifier') == HOST_ID,
                     'unexpected_known_host_identity')
                guest_info, guest_names = _validate_guest_source(
                    source_archive, source_entries, source_members)
                need(guest_info.get('CFBundleIdentifier') == GUEST_ID and
                     guest_info.get('CFBundleVersion') == GUEST_BUILD and
                     len(guest_names) > 0, 'unexpected_guest_identity_or_version')

                plan = _build_plan(host_members, source_members)
                descriptor_source = next((entry for entry in source_members
                                          if _entry_key(entry.filename) == preflight.key(DESCRIPTOR)), None)
                need(descriptor_source is not None, 'invalid_guest_descriptor')

                descriptor_fd, temporary = tempfile.mkstemp(
                    prefix='.private-guest-merge-', suffix='.ipa', dir=parent)
                with os.fdopen(descriptor_fd, 'w+b') as output:
                    expected_output = _write_output(host_archive, source_archive, plan,
                                                    host_info, output)
                    _verify_output(output, expected_output, host_info)
                    output.seek(0)
                    output_digest = hashlib.file_digest(output, 'sha256').hexdigest()
                    os.fsync(output.fileno())

                shared.recheck_input(host_path, host_stream, expected_host_sha256, host_identity)
                shared.recheck_input(known_good_path, source_stream,
                                     expected_known_guest_digest, source_identity)
                os.link(temporary, output_target)
                return {
                    'status': 'merged_private_guest_requires_sidestore_resigning',
                    'installation_authorized': False,
                    'requires_sidestore_resigning': True,
                    'valid_final_signature': False,
                    'runtime_verified': False,
                    'host_sha256': host_digest,
                    'known_guest_input_sha256': source_digest,
                    'output_sha256': output_digest,
                    'guest_files': sum(not name.endswith('/') for name in guest_names),
                    'output_files': len(expected_output),
                    'is_ipa': True,
                }
            finally:
                source_archive.close()
        finally:
            host_archive.close()
    except preflight.InspectionError:
        raise
    except FileExistsError:
        raise preflight.InspectionError('output_already_exists') from None
    except Exception:
        raise preflight.InspectionError('merge_failed') from None
    finally:
        if host_stream is not None:
            host_stream.close()
        if source_stream is not None:
            source_stream.close()
        if temporary is not None:
            try:
                Path(temporary).unlink(missing_ok=True)
            except OSError:
                raise preflight.InspectionError('temporary_cleanup_failed') from None


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'error': 'invalid_arguments'}))
        raise SystemExit(2)


def main(argv=None):
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path)
    parser.add_argument('known_good_20_6', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--host-sha256', required=True)
    args = parser.parse_args(argv)
    try:
        report = merge_private_guest(args.host, args.known_good_20_6, args.output,
                                     expected_host_sha256=args.host_sha256)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'valid_final_signature': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
