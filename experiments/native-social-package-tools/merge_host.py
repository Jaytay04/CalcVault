"""Private, digest-bound Build 20 research host merger; never signs or installs."""

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

import assemble_guest
import ipa_preflight as preflight
import bundled_resource_policy as bundled

CHUNK = 64 * 1024
MAX_OUTPUT = 2 * 1024**3
MAX_MANIFEST = assemble_guest.MAX_MANIFEST
MANIFEST = assemble_guest.MANIFEST
HOST_ROOT = 'Payload/LiveContainer.app'
GUEST_ROOT = 'Frameworks/NativeGuest.framework'
HOST_ID = 'com.jaylintaylor.calcvault'
GUEST_ID = 'com.zhiliaoapp.musically'
GUEST_BUILD = '439042'
TIKTOK47_PROFILE = {
    'input_sha256': '8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198',
    'original_main_bundle': {
        'path': 'Payload/TikTok.app',
        'identifier': 'com.zhiliaoapp.musically',
        'version': '47.0.0',
        'build': '470044',
        'executable': 'TikTok',
    },
    'main_adaptation': {
        'input_sha256': '3daefde434d4c6bdd9e21ea44ad5fd3801a485a8e3c40bf7989421e97eaba40c',
        'output_sha256': 'a4847252c4ec720f24a26d30082124d6b15c04d23d7bb4d8770ee6c5246c5623',
        'size': 73392,
    },
}
SYNTHETIC_GUEST_ID = 'org.example.syntheticnativeguest.app'
SYNTHETIC_RESOURCE_ID = 'org.example.cvlp.resources'
HOST_EXECUTABLE = 'LiveContainer'
EXTENSION_ROOT = HOST_ROOT + '/PlugIns/LiveProcess.appex'
EXTENSION_ID = 'com.jaylintaylor.calcvault.LiveProcess'
LEGACY_PAYLOAD = HOST_ROOT + '/Frameworks/SyntheticNativeGuestPayload.dylib'
RESOURCE_BUNDLE = HOST_ROOT + '/SyntheticGuestResources.bundle'
DESCRIPTOR = HOST_ROOT + '/CVLPFrameworkGuest.plist'
PRIVATE_SCOPE = HOST_ROOT + '/CVLPPrivatePackageScope.json'
HEX_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
OMISSIONS = {'exclude_extension', 'exclude_material', 'omit_obsolete_signature'}
FILE_ACTIONS = {'prepare_main_executable', 'prepare_framework_metadata',
                'review_embedded_code', 'review_bundle_metadata', 'review_resource'}


def need(condition, code):
    preflight.require(condition, code)


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        need(name not in result, 'duplicate_manifest_field')
        result[name] = value
    return result


def digest_text(value, code):
    need(isinstance(value, str) and HEX_DIGEST.fullmatch(value) is not None, code)
    return value


def plist_value(archive, entries, name, code='invalid_bundle_plist'):
    need(name in entries and entries[name].file_size <= 1024**2, code)
    try:
        raw = archive.read(name)
        need(b'<!ENTITY' not in raw, code)
        result = plistlib.loads(raw)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError(code) from None
    need(isinstance(result, dict), code)
    return result


def type_text(value, code='invalid_metadata'):
    need(isinstance(value, str) and 0 < len(value) <= 1024 and
         all(ord(ch) >= 32 and ord(ch) != 127 for ch in value), code)
    return value


def check_archive_size(path):
    path = Path(path)
    try:
        info = path.lstat()
    except OSError:
        raise preflight.InspectionError('unreadable_input') from None
    need(stat.S_ISREG(info.st_mode), 'input_not_regular_file')
    need(22 <= info.st_size <= preflight.MAX_ARCHIVE, 'archive_size_limit')
    return info.st_size


def archive_size_and_hash(path):
    """Check a regular-file size before reading bytes or parsing its ZIP directory."""
    path = Path(path)
    try:
        before = path.lstat()
    except OSError:
        raise preflight.InspectionError('unreadable_input') from None
    need(stat.S_ISREG(before.st_mode), 'input_not_regular_file')
    need(22 <= before.st_size <= preflight.MAX_ARCHIVE, 'archive_size_limit')
    try:
        stream = path.open('rb')
    except OSError:
        raise preflight.InspectionError('unreadable_input') from None
    try:
        opened = os.fstat(stream.fileno())
        need(stat.S_ISREG(opened.st_mode) and opened.st_size == before.st_size and
             opened.st_dev == before.st_dev and opened.st_ino == before.st_ino,
             'input_changed_during_merge')
        need(22 <= opened.st_size <= preflight.MAX_ARCHIVE, 'archive_size_limit')
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        stream.seek(0)
        return stream, digest, (opened.st_dev, opened.st_ino, opened.st_size)
    except Exception:
        stream.close()
        raise


def recheck_input(path, stream, expected_digest, identity):
    stream.seek(0)
    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    need(actual == expected_digest, 'input_changed_during_merge')
    try:
        current = Path(path).lstat()
        opened = os.fstat(stream.fileno())
    except OSError:
        raise preflight.InspectionError('input_changed_during_merge') from None
    need(stat.S_ISREG(current.st_mode) and
         (current.st_dev, current.st_ino, current.st_size) == identity and
         (opened.st_dev, opened.st_ino, opened.st_size) == identity,
         'input_changed_during_merge')
    stream.seek(0)


def checked_archive(stream, archive_size, profile='strict', *, approved_resource_input_sha256=None):
    preflight.bound_central_directory(stream, archive_size)
    stream.seek(0)
    try:
        archive = zipfile.ZipFile(stream, 'r')
    except Exception:
        raise preflight.InspectionError('invalid_zip_archive') from None
    try:
        entries = preflight.archive_entries(archive, profile)
        total = sum(entry.file_size for entry in entries.values())
        need(total <= MAX_OUTPUT, 'archive_total_limit')
        all_names = [entry.filename for entry in archive.infolist()]
        need(all(not name.lower().endswith(preflight.MATERIAL)
                 or bundled.matches(approved_resource_input_sha256, bundled.REVIEWED_RESOURCE[1],
                                    name, entry.file_size)
                 for name, entry in entries.items()),
             'signing_material_forbidden')
        return archive, entries, all_names, total
    except Exception:
        archive.close()
        raise


def is_signature_metadata(name):
    parts = preflight.checked_name(name).split('/')
    return (len(parts) >= 2 and preflight.key(parts[-2]) == '_codesignature' and
            preflight.key(parts[-1]) == 'coderesources')


def under_bundle(name, bundle):
    return preflight.key(name).startswith(preflight.key(bundle + '/'))


def _host_layout(archive, entries, all_names):
    files = set(entries)
    need(not any(preflight.key(name) == preflight.key(PRIVATE_SCOPE) for name in files),
         'reserved_private_scope_marker')
    need(HOST_ROOT + '/Info.plist' in files, 'unexpected_host_root')
    app_roots = set()
    extension_roots = set()
    for name in all_names:
        name = preflight.checked_name(name)
        parts = name.split('/')
        for index, component in enumerate(parts):
            if component.lower().endswith('.app'):
                app_roots.add('/'.join(parts[:index + 1]))
            if component.lower().endswith('.appex'):
                extension_roots.add('/'.join(parts[:index + 1]))
    need(app_roots == {HOST_ROOT}, 'unexpected_host_app')
    need(extension_roots == {HOST_ROOT + '/PlugIns/LiveProcess.appex'},
         'unexpected_host_extension')
    for name in files:
        need(name.startswith(HOST_ROOT + '/'), 'host_path_outside_app')
        need(not any(part.lower() == 'lcappinfo.plist' for part in name.split('/')),
             'forbidden_host_metadata')
    host_info = plist_value(archive, entries, HOST_ROOT + '/Info.plist')
    need(host_info.get('CFBundleIdentifier') == HOST_ID, 'unexpected_host_identity')
    need(host_info.get('CFBundleVersion') == '20', 'unexpected_host_version')
    mode = host_info.get('CVLPFrameworkGuestMode')
    need(type(mode) is int and mode == 1, 'unexpected_host_framework_mode')
    executable = type_text(host_info.get('CFBundleExecutable'), 'invalid_host_executable')
    need(executable == HOST_EXECUTABLE and HOST_ROOT + '/' + executable in files,
         'invalid_host_executable')

    extension = EXTENSION_ROOT
    ext_info = plist_value(archive, entries, extension + '/Info.plist')
    ext_executable = type_text(ext_info.get('CFBundleExecutable'), 'invalid_extension_metadata')
    need(ext_info.get('CFBundleIdentifier') == EXTENSION_ID and
         ext_executable == 'LiveProcess' and extension + '/' + ext_executable in files,
         'invalid_extension_metadata')

    framework = HOST_ROOT + '/' + GUEST_ROOT
    framework_files = {name for name in files if under_bundle(name, framework)}
    expected_framework_files = {
        framework + '/NativeGuest', framework + '/Info.plist',
        framework + '/_CodeSignature/CodeResources'}
    need(framework_files == expected_framework_files, 'unexpected_synthetic_framework_layout')
    framework_info = plist_value(archive, entries, framework + '/Info.plist')
    need(framework_info.get('CFBundleIdentifier') == SYNTHETIC_GUEST_ID and
         framework_info.get('CFBundleExecutable') == 'NativeGuest' and
         framework_info.get('CFBundlePackageType') == 'FMWK',
         'invalid_synthetic_framework_metadata')
    synthetic_version = type_text(framework_info.get('CFBundleVersion'),
                                  'invalid_synthetic_framework_metadata')
    descriptor = plist_value(archive, entries, DESCRIPTOR, 'invalid_synthetic_descriptor')
    need(set(descriptor) == {'schema', 'bundleIdentifier', 'bundleVersion', 'executable'} and
         type(descriptor.get('schema')) is int and descriptor['schema'] == 1 and
         descriptor.get('bundleIdentifier') == SYNTHETIC_GUEST_ID and
         descriptor.get('bundleVersion') == synthetic_version and
         descriptor.get('executable') == 'NativeGuest', 'invalid_synthetic_descriptor')

    resource_files = {name for name in files if under_bundle(name, RESOURCE_BUNDLE)}
    need(resource_files == {RESOURCE_BUNDLE + '/Info.plist', RESOURCE_BUNDLE + '/GuestInfo.plist'},
         'unexpected_synthetic_resource_layout')
    resource_info = plist_value(archive, entries, RESOURCE_BUNDLE + '/Info.plist')
    need(resource_info.get('CFBundleIdentifier') == SYNTHETIC_RESOURCE_ID and
         resource_info.get('CFBundleName') == 'SyntheticGuestResources' and
         resource_info.get('CFBundlePackageType') == 'BNDL',
         'invalid_synthetic_resource_metadata')
    old_guest_info = plist_value(archive, entries, RESOURCE_BUNDLE + '/GuestInfo.plist')
    old_guest_id = type_text(old_guest_info.get('CFBundleIdentifier'),
                             'invalid_synthetic_resource_metadata')
    need(old_guest_id == SYNTHETIC_GUEST_ID,
         'invalid_synthetic_resource_metadata')
    need(LEGACY_PAYLOAD in files, 'missing_synthetic_legacy_payload')

    allowed_dirs = {'Payload', HOST_ROOT}
    for name in all_names:
        if name.endswith('/'):
            normalized = preflight.checked_name(name)
            need(normalized in allowed_dirs or normalized.startswith(HOST_ROOT + '/'),
                 'host_path_outside_app')
    for name in files:
        if preflight.key(name).find('/_codesignature/') >= 0:
            need(is_signature_metadata(name), 'unexpected_host_signature_metadata')
    return host_info


def _manifest_json(archive, entries):
    need(MANIFEST in entries and entries[MANIFEST].file_size <= MAX_MANIFEST,
         'invalid_guest_manifest')
    try:
        raw = archive.read(MANIFEST)
        manifest = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('invalid_guest_manifest') from None
    need(isinstance(manifest, dict), 'invalid_guest_manifest')
    return manifest


def _validate_manifest(manifest, expected_guest_input_sha256,
                       acknowledge_private_bundled_resources=False, *,
                       guest_profile='rx439'):
    need(type(guest_profile) is str and guest_profile in ('rx439', 'newer47'),
         'invalid_guest_profile')
    if guest_profile == 'newer47':
        need(expected_guest_input_sha256 == TIKTOK47_PROFILE['input_sha256'],
             'invalid_guest_profile')
    expected_keys = {'schema', 'status', 'installation_authorized', 'runtime_manifest',
                     'input_sha256', 'plan_sha256', 'original_main_bundle',
                     'main_adaptation', 'files', 'omissions', 'unverified',
                     'layout_review_flags'}
    private_scope = manifest.get('schema') == 2
    if guest_profile == 'newer47':
        need(type(manifest.get('schema')) is int and manifest['schema'] == 2 and
             manifest.get('private_test_only') is True and
             type(acknowledge_private_bundled_resources) is bool and
             acknowledge_private_bundled_resources,
             'private_resource_acknowledgement_required')
    if private_scope:
        expected_keys.add('private_test_only')
        need(manifest.get('private_test_only') is True
             and type(acknowledge_private_bundled_resources) is bool
             and acknowledge_private_bundled_resources, 'private_resource_acknowledgement_required')
    need(set(manifest) == expected_keys, 'invalid_guest_manifest')
    need(type(manifest['schema']) is int and manifest['schema'] in (1, 2) and
         manifest['status'] == 'unsigned_guest_requires_host_integration' and
         manifest['installation_authorized'] is False and manifest['runtime_manifest'] is False,
         'invalid_guest_manifest')
    need(digest_text(manifest['input_sha256'], 'invalid_guest_manifest') ==
         expected_guest_input_sha256, 'guest_original_digest_mismatch')
    digest_text(manifest['plan_sha256'], 'invalid_guest_manifest')

    original = manifest['original_main_bundle']
    need(isinstance(original, dict) and set(original) == {
        'path', 'identifier', 'version', 'build', 'executable'}, 'invalid_guest_identity')
    expected_original = (TIKTOK47_PROFILE['original_main_bundle']
                         if guest_profile == 'newer47' else None)
    path = type_text(original.get('path'), 'invalid_guest_identity')
    preflight.checked_name(path)
    need(path.lower().endswith('.app') and original.get('identifier') == GUEST_ID and
         original.get('build') == (expected_original['build'] if expected_original
                                   else GUEST_BUILD) and
         type_text(original.get('version'), 'invalid_guest_identity') and
         type_text(original.get('executable'), 'invalid_guest_identity'),
         'unexpected_guest_identity')
    if expected_original:
        need(all(original.get(field) == value for field, value in expected_original.items()),
             'unexpected_guest_identity')

    adaptation = manifest['main_adaptation']
    adaptation_keys = {'status', 'installation_authorized', 'input_sha256', 'output_sha256',
                       'size', 'entrypoint_offset', 'install_name', 'modified_prefix_bytes',
                       'original_signature_invalidated', 'unverified'}
    need(isinstance(adaptation, dict) and set(adaptation) == adaptation_keys and
         adaptation.get('status') == 'prepared_requires_signing_and_review' and
         adaptation.get('installation_authorized') is False and
         adaptation.get('install_name') == 'NativeGuest' and
         adaptation.get('original_signature_invalidated') is True and
         isinstance(adaptation.get('unverified'), list) and
         all(isinstance(flag, str) for flag in adaptation['unverified']),
         'invalid_guest_adaptation')
    digest_text(adaptation.get('input_sha256'), 'invalid_guest_adaptation')
    digest_text(adaptation.get('output_sha256'), 'invalid_guest_adaptation')
    for field in ('size', 'entrypoint_offset', 'modified_prefix_bytes'):
        need(type(adaptation.get(field)) is int and adaptation[field] >= 0,
             'invalid_guest_adaptation')
    need(adaptation['size'] > 0 and adaptation['modified_prefix_bytes'] <= adaptation['size'],
         'invalid_guest_adaptation')
    if guest_profile == 'newer47':
        expected_adaptation = TIKTOK47_PROFILE['main_adaptation']
        need(adaptation['input_sha256'] == expected_adaptation['input_sha256'] and
             adaptation['output_sha256'] == expected_adaptation['output_sha256'] and
             type(adaptation['size']) is int and
             adaptation['size'] == expected_adaptation['size'],
             'unexpected_guest_main_pins')

    files = manifest['files']
    need(isinstance(files, list) and 0 < len(files) <= preflight.MAX_ENTRIES,
         'invalid_guest_manifest')
    expected_files, source_keys, retained_count = {}, set(), 0
    row_keys = {'source', 'path', 'size', 'sha256_before_signing', 'action'}
    for row in files:
        need(isinstance(row, dict) and set(row) == row_keys, 'invalid_guest_manifest')
        source = type_text(row['source'], 'invalid_guest_manifest')
        normalized_source = preflight.checked_name(source)
        need(source == normalized_source, 'invalid_guest_manifest')
        source = normalized_source
        retained = row['action'] == bundled.ACTION
        if retained:
            need(private_scope, 'private_resource_scope_required')
            bundled.verify_row(row, manifest['input_sha256'], copied=True)
            retained_count += 1
        source_key = preflight.key(source)
        need(source_key not in source_keys and
             (not source.lower().endswith(preflight.MATERIAL) or retained), 'invalid_guest_manifest')
        source_keys.add(source_key)
        path = type_text(row['path'], 'invalid_guest_manifest')
        normalized = preflight.checked_name(path)
        need(path == normalized, 'invalid_guest_manifest')
        key = preflight.key(normalized)
        need(key not in expected_files and normalized.startswith(GUEST_ROOT + '/'),
             'duplicate_guest_member')
        parts = normalized.split('/')
        need(not any(part.lower().endswith(('.app', '.appex')) for part in parts) and
             not any(preflight.key(part) in ('_codesignature', 'lcappinfo.plist', 'coderesources')
                     for part in parts) and
             (not normalized.lower().endswith(preflight.MATERIAL) or retained),
             'forbidden_guest_member')
        need(isinstance(row['action'], str) and (row['action'] in FILE_ACTIONS or retained),
             'invalid_guest_manifest')
        need(type(row['size']) is int and 0 <= row['size'] <= preflight.MAX_REVIEW_ENTRY,
             'invalid_guest_manifest')
        digest_text(row['sha256_before_signing'], 'invalid_guest_manifest')
        expected_files[key] = row
    need(retained_count == (1 if private_scope else 0), 'unapproved_bundled_resource')
    need(GUEST_ROOT + '/Info.plist' in {row['path'] for row in files} and
         GUEST_ROOT + '/NativeGuest' in {row['path'] for row in files},
         'incomplete_guest_framework')
    root_rows = {row['path']: row for row in files}
    need(root_rows[GUEST_ROOT + '/Info.plist']['action'] == 'prepare_framework_metadata' and
         root_rows[GUEST_ROOT + '/NativeGuest']['action'] == 'prepare_main_executable' and
         root_rows[GUEST_ROOT + '/NativeGuest']['sha256_before_signing'] == adaptation['output_sha256'] and
         root_rows[GUEST_ROOT + '/NativeGuest']['size'] == adaptation['size'],
         'invalid_guest_adaptation')
    if guest_profile == 'newer47':
        need(root_rows[GUEST_ROOT + '/NativeGuest']['source'] ==
             expected_original['path'] + '/' + expected_original['executable'] and
             root_rows[GUEST_ROOT + '/Info.plist']['source'] ==
             expected_original['path'] + '/Info.plist',
             'unexpected_guest_main_pins')

    omissions = manifest['omissions']
    need(isinstance(omissions, list) and len(omissions) <= preflight.MAX_ENTRIES,
         'invalid_guest_manifest')
    omitted = set()
    for row in omissions:
        need(isinstance(row, dict) and set(row) == {'source', 'action'} and
             isinstance(row['action'], str) and row['action'] in OMISSIONS,
             'invalid_guest_manifest')
        name = preflight.checked_name(type_text(row['source'], 'invalid_guest_manifest'))
        key = preflight.key(name)
        need(key not in omitted and key not in source_keys, 'duplicate_guest_member')
        omitted.add(key)
        if row['action'] == 'exclude_material':
            need(name.lower().endswith(preflight.MATERIAL), 'invalid_guest_manifest')

    for field in ('unverified', 'layout_review_flags'):
        need(isinstance(manifest[field], list) and all(isinstance(value, str)
             and 0 < len(value) <= 128 for value in manifest[field]), 'invalid_guest_manifest')
    need('host_integration' in manifest['unverified'] and
         'post_signing_hashes' in manifest['unverified'], 'invalid_guest_manifest')
    return files, expected_files


def _verify_guest(archive, entries, all_names, expected_original_digest,
                  acknowledge_private_bundled_resources=False, *,
                  guest_profile='rx439'):
    need(all(not name.endswith('/') for name in all_names), 'invalid_guest_inventory')
    manifest = _manifest_json(archive, entries)
    files, records = _validate_manifest(manifest, expected_original_digest,
                                        acknowledge_private_bundled_resources,
                                        guest_profile=guest_profile)
    actual = {preflight.key(name): name for name in entries}
    need(len(actual) == len(entries) and set(actual) == set(records) | {preflight.key(MANIFEST)},
         'guest_inventory_mismatch')
    for key, row in records.items():
        entry = entries[actual[key]]
        need(entry.filename == row['path'], 'guest_inventory_mismatch')
        need(entry.file_size == row['size'], 'guest_member_size_mismatch')
        digest, count = hashlib.sha256(), 0
        try:
            with archive.open(entry, 'r') as stream:
                while True:
                    block = stream.read(CHUNK)
                    if not block:
                        break
                    count += len(block)
                    need(count <= row['size'], 'guest_member_size_mismatch')
                    digest.update(block)
        except preflight.InspectionError:
            raise
        except Exception:
            raise preflight.InspectionError('invalid_guest_member') from None
        need(count == row['size'] and digest.hexdigest() == row['sha256_before_signing'],
             'guest_member_digest_mismatch')
    info = plist_value(archive, entries, GUEST_ROOT + '/Info.plist')
    expected_framework = (TIKTOK47_PROFILE['original_main_bundle']
                          if guest_profile == 'newer47' else None)
    need(info.get('CFBundleIdentifier') == GUEST_ID and
         info.get('CFBundleVersion') == (expected_framework['build'] if expected_framework
                                         else GUEST_BUILD) and
         info.get('CFBundleExecutable') == 'NativeGuest' and
         info.get('CFBundlePackageType') == 'FMWK', 'unexpected_guest_framework_metadata')
    short_version = type_text(info.get('CFBundleShortVersionString'),
                              'unexpected_guest_framework_metadata')
    if expected_framework:
        need(short_version == expected_framework['version'],
             'unexpected_guest_framework_metadata')
    return manifest, files, records, info


def output_zip_info(name, source_info=None, executable=False):
    result = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    result.compress_type = zipfile.ZIP_STORED
    if source_info is not None:
        result.create_system = source_info.create_system
        result.external_attr = source_info.external_attr
        result.internal_attr = source_info.internal_attr
    else:
        result.create_system = 3
        result.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    return result


def stream_copy(source, destination, output_stream, expected_size=None):
    digest, count = hashlib.sha256(), 0
    while True:
        block = source.read(CHUNK)
        if not block:
            break
        count += len(block)
        need(expected_size is None or count <= expected_size, 'member_size_mismatch')
        destination.write(block)
        digest.update(block)
        need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
    need(expected_size is None or count == expected_size, 'member_size_mismatch')
    return count, digest.hexdigest()


def _guest_descriptor(info):
    descriptor = {'schema': 1, 'bundleIdentifier': info['CFBundleIdentifier'],
                  'bundleVersion': info['CFBundleVersion'], 'executable': 'NativeGuest'}
    return plistlib.dumps(descriptor, fmt=plistlib.FMT_XML, sort_keys=True)


def _build_entries(host_archive, guest_records, guest_info, private_test_only=False):
    output = []
    replaced_framework = {HOST_ROOT + '/' + GUEST_ROOT + '/NativeGuest',
                          HOST_ROOT + '/' + GUEST_ROOT + '/Info.plist'}
    resource_prefix = preflight.key(RESOURCE_BUNDLE + '/')
    for source_info in host_archive.infolist():
        name = source_info.filename
        canonical = preflight.key(preflight.checked_name(name))
        if source_info.is_dir():
            # ZIP directory records carry no host file bytes and are recreated
            # implicitly by extractors from the retained file paths.
            continue
        if (canonical.startswith(resource_prefix) or canonical == preflight.key(LEGACY_PAYLOAD) or
                canonical in {preflight.key(path) for path in replaced_framework} or
                canonical == preflight.key(DESCRIPTOR) or is_signature_metadata(name)):
            continue
        output.append(('host_file', name, source_info, None, source_info.file_size))

    descriptor_data = _guest_descriptor(guest_info)
    output.append(('generated', DESCRIPTOR, None, descriptor_data, len(descriptor_data)))
    for key, row in guest_records.items():
        path = HOST_ROOT + '/' + row['path']
        output.append(('guest_file', path, None, (key, row), row['size']))

    if private_test_only:
        scope = json.dumps({'schema': 1, 'private_test_only': True,
                            'purpose': 'bundled-resource-compatibility-test',
                            'guest_input_sha256': bundled.REVIEWED_RESOURCE[0],
                            'resource_path': bundled.REVIEWED_RESOURCE[2],
                            'resource_sha256': bundled.REVIEWED_RESOURCE[4]},
                           sort_keys=True).encode('ascii')
        output.append(('generated', PRIVATE_SCOPE, None, scope, len(scope)))
    # Guest placeholder replacements are excluded above; validate every merged name
    # as one file/directory namespace before creating a temporary output.
    folded = {}
    file_keys = set()
    for kind, name, _info, _data, _size in output:
        canonical = preflight.key(preflight.checked_name(name))
        need(canonical not in folded, 'merged_path_collision')
        folded[canonical] = name
        file_keys.add(canonical)
    for canonical in folded:
        parts = canonical.split('/')
        need(not any('/'.join(parts[:index]) in file_keys
                     for index in range(1, len(parts))), 'merged_path_conflict')
    return output


def _write_output(host_archive, guest_archive, plan, output_stream):
    written = {}
    with zipfile.ZipFile(output_stream, 'w', compression=zipfile.ZIP_STORED,
                         allowZip64=False) as output_archive:
        for kind, name, source_info, data, expected_size in plan:
            executable = False
            if kind == 'generated':
                content = data
                with output_archive.open(output_zip_info(name), 'w') as destination:
                    destination.write(content)
                written[preflight.key(name)] = (name, len(content), hashlib.sha256(content).hexdigest())
            elif kind == 'host_file':
                executable = bool((source_info.external_attr >> 16) & 0o111)
                with host_archive.open(source_info, 'r') as source, \
                        output_archive.open(output_zip_info(name, source_info), 'w') as destination:
                    count, digest = stream_copy(source, destination, output_stream, expected_size)
                written[preflight.key(name)] = (name, count, digest)
            elif kind == 'guest_file':
                key, row = data
                source_info = guest_archive.getinfo(row['path'])
                executable = bool((source_info.external_attr >> 16) & 0o111)
                with guest_archive.open(source_info, 'r') as source, \
                        output_archive.open(output_zip_info(name, source_info), 'w') as destination:
                    count, digest = stream_copy(source, destination, output_stream, expected_size)
                need(count == row['size'] and digest == row['sha256_before_signing'],
                     'guest_member_digest_mismatch')
                written[preflight.key(name)] = (name, count, digest)
            need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
    return written


def verify_output(stream, expected):
    try:
        size = os.fstat(stream.fileno()).st_size
        need(22 <= size <= MAX_OUTPUT, 'output_size_limit')
        preflight.bound_central_directory(stream, size)
        stream.seek(0)
        with zipfile.ZipFile(stream, 'r') as archive:
            preflight.archive_entries(archive, 'extended-review')
            names = [item.filename for item in archive.infolist()]
            need(all(not name.endswith('/') for name in names) and
                 len(names) == len(expected) and
                 {preflight.key(name) for name in names} == set(expected),
                 'output_inventory_mismatch')
            for name in names:
                entry = archive.getinfo(name)
                record = expected[preflight.key(name)]
                need(entry.filename == record[0], 'output_inventory_mismatch')
                need(entry.file_size == record[1], 'output_member_size_mismatch')
                digest = hashlib.sha256()
                count = 0
                with archive.open(entry, 'r') as member:
                    while True:
                        block = member.read(CHUNK)
                        if not block:
                            break
                        count += len(block)
                        digest.update(block)
                need(count == record[1] and digest.hexdigest() == record[2],
                     'output_member_digest_mismatch')
            need(archive.testzip() is None, 'output_crc_mismatch')
        stream.seek(0)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_verification_failed') from None


def merge_host(host_path, guest_path, output_path, *, expected_host_sha256,
               expected_guest_sha256, expected_guest_input_sha256,
               acknowledge_unverified_runtime=False,
               acknowledge_private_bundled_resources=False):
    """Merge reviewed inputs into a new unsigned research IPA, never in place."""
    host_path, guest_path, output_path = Path(host_path), Path(guest_path), Path(output_path)
    host_stream = guest_stream = None
    temporary = None
    try:
        need(type(acknowledge_unverified_runtime) is bool and acknowledge_unverified_runtime,
             'unverified_runtime_acknowledgement_required')
        expected_host_sha256 = digest_text(expected_host_sha256, 'invalid_host_digest')
        expected_guest_sha256 = digest_text(expected_guest_sha256, 'invalid_guest_digest')
        expected_guest_input_sha256 = digest_text(expected_guest_input_sha256,
                                                  'invalid_guest_input_digest')
        need(host_path.suffix.lower() == '.ipa' and guest_path.suffix.lower() == '.zip' and
             output_path.suffix.lower() == '.ipa', 'invalid_package_file_type')
        need(host_path.resolve() != output_path.resolve() and
             guest_path.resolve() != output_path.resolve(), 'in_place_merge_forbidden')
        parent = output_path.parent.resolve(strict=True)
        output_target = parent / output_path.name
        try:
            output_target.lstat()
        except FileNotFoundError:
            pass
        else:
            raise preflight.InspectionError('output_already_exists')

        host_size = check_archive_size(host_path)
        guest_size = check_archive_size(guest_path)
        host_stream, host_digest, host_identity = archive_size_and_hash(host_path)
        guest_stream, guest_digest, guest_identity = archive_size_and_hash(guest_path)
        need(host_identity[2] == host_size and guest_identity[2] == guest_size,
             'input_changed_during_merge')
        need(host_digest == expected_host_sha256, 'host_digest_mismatch')
        need(guest_digest == expected_guest_sha256, 'guest_digest_mismatch')

        host_archive, host_entries, host_names, _ = checked_archive(
            host_stream, host_identity[2])
        try:
            guest_archive, guest_entries, guest_names, _ = checked_archive(
                guest_stream, guest_identity[2], 'extended-review',
                approved_resource_input_sha256=(expected_guest_input_sha256
                    if type(acknowledge_private_bundled_resources) is bool
                    and acknowledge_private_bundled_resources else None))
            try:
                _host_layout(host_archive, host_entries, host_names)
                _manifest, guest_files, guest_records, guest_info = _verify_guest(
                    guest_archive, guest_entries, guest_names, expected_guest_input_sha256,
                    acknowledge_private_bundled_resources)
                output_plan = _build_entries(host_archive, guest_records, guest_info,
                                             _manifest.get('private_test_only', False))
                descriptor = next((row for row in output_plan
                                   if row[0] == 'generated' and row[1] == DESCRIPTOR), None)
                need(descriptor is not None, 'invalid_generated_descriptor')

                descriptor_fd, temporary = tempfile.mkstemp(
                    prefix='.host-merge-', suffix='.ipa', dir=parent)
                with os.fdopen(descriptor_fd, 'w+b') as output:
                    expected_output = _write_output(host_archive, guest_archive,
                                                    output_plan, output)
                    output.flush()
                    need(output.tell() <= MAX_OUTPUT, 'output_size_limit')
                    verify_output(output, expected_output)
                    output.seek(0)
                    output_digest = hashlib.file_digest(output, 'sha256').hexdigest()
                    os.fsync(output.fileno())

                recheck_input(host_path, host_stream, expected_host_sha256, host_identity)
                recheck_input(guest_path, guest_stream, expected_guest_sha256, guest_identity)
                os.link(temporary, output_target)
                return {'status': 'merged_research_host_requires_fresh_signing',
                        'installation_authorized': False, 'requires_fresh_signing': True,
                        'runtime_verified': False, 'host_sha256': host_digest,
                        'guest_sha256': guest_digest,
                        'guest_input_sha256': expected_guest_input_sha256,
                        'private_test_only': _manifest.get('private_test_only', False),
                        'output_sha256': output_digest, 'host_files': len(host_entries),
                        'guest_files': len(guest_files),
                        'output_files': len(expected_output),
                        'removed_signature_files': sum(1 for name in host_entries
                                                       if is_signature_metadata(name)),
                        'is_ipa': True}
            finally:
                guest_archive.close()
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
                          'error': 'invalid_arguments'}))
        raise SystemExit(2)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if '--help' in argv:
        print(json.dumps({'status': 'usage', 'required_inputs': 3,
                          'required_digests': ['host_sha256', 'guest_sha256',
                                               'guest_input_sha256'],
                          'requires_acknowledgement': 'acknowledge_unverified_runtime'}))
        return 0
    parser = JsonArgumentParser(description=__doc__, add_help=False)
    parser.add_argument('host', type=Path)
    parser.add_argument('guest', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--host-sha256', required=True)
    parser.add_argument('--guest-sha256', required=True)
    parser.add_argument('--guest-input-sha256', required=True)
    parser.add_argument('--acknowledge-unverified-runtime', action='store_true')
    parser.add_argument('--acknowledge-private-bundled-resources', action='store_true')
    args = parser.parse_args(argv)
    try:
        report = merge_host(args.host, args.guest, args.output,
                            expected_host_sha256=args.host_sha256,
                            expected_guest_sha256=args.guest_sha256,
                            expected_guest_input_sha256=args.guest_input_sha256,
                            acknowledge_unverified_runtime=args.acknowledge_unverified_runtime,
                            acknowledge_private_bundled_resources=args.acknowledge_private_bundled_resources)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'runtime_verified': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
