"""Private, unsigned guest-framework ZIP writer. Not an IPA or a phone importer."""

import argparse
import hashlib
import io
import json
import os
import plistlib
import re
import stat
import tempfile
import zipfile
from pathlib import Path

import ipa_preflight as preflight
import package_plan
import prepare_executable
import bundled_resource_policy as bundled

CHUNK = 64 * 1024
MAX_OUTPUT = 2 * 1024**3
MAX_MANIFEST = 16 * 1024**2
MANIFEST = 'GuestPackage.json'
OMIT = {'exclude_extension', 'exclude_material', 'omit_obsolete_signature'}
COPY = {'review_embedded_code', 'review_bundle_metadata', 'review_resource'}


def validate_request(plan, expected_plan_sha256, acknowledge_unverified_layout,
                     acknowledge_private_bundled_resources=False):
    need = preflight.require
    need(type(acknowledge_unverified_layout) is bool and acknowledge_unverified_layout,
         'unverified_layout_acknowledgement_required')
    need(plan['policy_supplied'], 'explicit_exclusion_policy_required')
    need(isinstance(expected_plan_sha256, str) and
         re.fullmatch('[0-9a-f]{64}', expected_plan_sha256), 'invalid_plan_digest')
    need(expected_plan_sha256 == plan['plan_sha256'], 'plan_digest_mismatch')
    counts = plan['action_counts']
    need(counts.get('prepare_main_executable') == 1 and
         counts.get('prepare_framework_metadata') == 1, 'invalid_preparation_plan')
    retained = [m for m in plan['members'] if m['action'] == bundled.ACTION]
    if retained:
        need(plan.get('private_test_only') is True
             and type(acknowledge_private_bundled_resources) is bool
             and acknowledge_private_bundled_resources, 'private_resource_acknowledgement_required')
        need(len(retained) == 1, 'unapproved_bundled_resource')
        bundled.verify_row(retained[0], plan['input_sha256'])
    allowed = OMIT | COPY | {'prepare_main_executable', 'prepare_framework_metadata', bundled.ACTION}
    need(all(m['action'] in allowed for m in plan['members']), 'undisposed_package_members')
    package_plan.validate_destinations(plan['members'])
    for member in plan['members']:
        if member['action'] in OMIT:
            need(member['proposed_destination'] is None, 'invalid_exclusion_destination')
        else:
            target = member['proposed_destination']
            need(target is not None and (not target.lower().endswith(preflight.MATERIAL)
                 or member['action'] == bundled.ACTION),
                 'material_output_forbidden')
            need(not any(p.lower().endswith(('.app', '.appex')) for p in target.split('/')),
                 'nested_product_output_forbidden')


def zip_info(name, executable):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    info.compress_type = zipfile.ZIP_STORED
    return info


def stream_member(source, destination, expected_size, output_stream):
    digest, count = hashlib.sha256(), 0
    while True:
        block = source.read(CHUNK)
        if not block:
            break
        count += len(block)
        preflight.require(count <= expected_size, 'member_size_mismatch')
        destination.write(block)
        digest.update(block)
        preflight.require(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
    preflight.require(count == expected_size, 'member_size_mismatch')
    return count, digest.hexdigest()


def write_bundle(source, output_stream, plan, profile):
    source.seek(0)
    files, omissions, adaptation = [], [], None
    with zipfile.ZipFile(source) as archive, zipfile.ZipFile(
            output_stream, 'w', compression=zipfile.ZIP_STORED, allowZip64=False) as output:
        entries = preflight.archive_entries(archive, profile)
        for member in plan['members']:
            name, action, target = member['source'], member['action'], member['proposed_destination']
            if action in OMIT:
                omissions.append({'source': name, 'action': action})
                continue
            entry = entries[name]
            if action == bundled.ACTION:
                preflight.require(plan.get('private_test_only') is True, 'private_resource_scope_required')
                bundled.verify_row(member, plan['input_sha256'])
                bundled.verify_member(archive, entry, plan['input_sha256'])
            code = action in ('prepare_main_executable', 'review_embedded_code')
            if action == 'prepare_main_executable':
                preflight.require(entry.file_size <= prepare_executable.MAX_MAIN, 'main_size_limit')
                with archive.open(entry) as incoming:
                    data = incoming.read(prepare_executable.MAX_MAIN + 1)
                preflight.require(len(data) == entry.file_size, 'member_size_mismatch')
                prepared, adaptation = prepare_executable.prepare_main(
                    data, expected_sha256=hashlib.sha256(data).hexdigest())
                incoming, size = io.BytesIO(prepared), len(prepared)
            elif action == 'prepare_framework_metadata':
                info = preflight.read_plist(archive, entries, name)
                info['CFBundleExecutable'] = 'NativeGuest'
                info['CFBundlePackageType'] = 'FMWK'
                prepared = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=True)
                preflight.require(len(prepared) <= 1024**2, 'output_plist_size_limit')
                incoming, size = io.BytesIO(prepared), len(prepared)
            else:
                incoming, size = archive.open(entry), entry.file_size
            with incoming, output.open(zip_info(target, code), 'w') as outgoing:
                count, digest = stream_member(incoming, outgoing, size, output_stream)
            if action == bundled.ACTION:
                preflight.require(bundled.matches(plan['input_sha256'], name, target, count, digest),
                                  'bundled_resource_digest_mismatch')
            files.append({'source': name, 'path': target, 'size': count,
                          'sha256_before_signing': digest, 'action': action})
        manifest = {'schema': 1, 'status': 'unsigned_guest_requires_host_integration',
                    'installation_authorized': False, 'runtime_manifest': False,
                    'input_sha256': plan['input_sha256'], 'plan_sha256': plan['plan_sha256'],
                    'original_main_bundle': plan['main_bundle'], 'main_adaptation': adaptation,
                    'files': files, 'omissions': omissions,
                    'unverified': plan['unverified'] + ['host_integration', 'post_signing_hashes'],
                    'layout_review_flags': plan['review_flags']}
        if plan.get('private_test_only') is True:
            manifest['schema'], manifest['private_test_only'] = 2, True
        encoded = json.dumps(manifest, sort_keys=True, ensure_ascii=True).encode('ascii')
        preflight.require(len(encoded) <= MAX_MANIFEST, 'manifest_size_limit')
        output.writestr(zip_info(MANIFEST, False), encoded)
    preflight.require(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
    return manifest


def verify_output(stream, manifest):
    """Read every included output member back, checking names, size, CRC and SHA-256."""
    stream.seek(0)
    expected = {f['path']: f for f in manifest['files']}
    with zipfile.ZipFile(stream) as archive:
        names = archive.namelist()
        preflight.require(len(names) == len(set(names)) and set(names) == set(expected) | {MANIFEST},
                          'output_inventory_mismatch')
        for name, record in expected.items():
            if name.lower().endswith(preflight.MATERIAL) or record['action'] == bundled.ACTION:
                preflight.require(manifest.get('private_test_only') is True and manifest['schema'] == 2,
                                  'private_resource_scope_required')
                bundled.verify_row(record, manifest['input_sha256'], copied=True)
            entry = archive.getinfo(name)
            preflight.require(entry.file_size == record['size'], 'output_member_mismatch')
            with archive.open(entry) as member:
                digest = hashlib.file_digest(member, 'sha256').hexdigest()
            preflight.require(digest == record['sha256_before_signing'], 'output_member_mismatch')
        preflight.require(archive.getinfo(MANIFEST).file_size <= MAX_MANIFEST, 'manifest_size_limit')
        preflight.require(json.loads(archive.read(MANIFEST)) == manifest, 'output_manifest_mismatch')


def assemble_guest(source_path, output_path, *, policy, expected_plan_sha256,
                   profile='strict', acknowledge_unverified_layout=False,
                   acknowledge_private_bundled_resources=False):
    """Create a new research ZIP only after recomputing its reviewed proposal."""
    source_path, output_path = Path(source_path), Path(output_path)
    temporary = None
    try:
        preflight.require(source_path.suffix.lower() == '.ipa' and output_path.suffix.lower() == '.zip',
                          'invalid_package_file_type')
        preflight.require(source_path.resolve() != output_path.resolve(), 'in_place_assembly_forbidden')
        # Fresh preflight/plan on the same open source; never trust an imported plan's rows.
        with source_path.open('rb') as source:
            plan = package_plan._plan(source, profile, policy)
            validate_request(plan, expected_plan_sha256, acknowledge_unverified_layout,
                             acknowledge_private_bundled_resources)
            parent = output_path.parent.resolve(strict=True)
            descriptor, temporary = tempfile.mkstemp(prefix='.guest-package-', suffix='.zip', dir=parent)
            with os.fdopen(descriptor, 'w+b') as output:
                manifest = write_bundle(source, output, plan, profile)
                output.flush()
                verify_output(output, manifest)
                source.seek(0)
                preflight.require(hashlib.file_digest(source, 'sha256').hexdigest() == plan['input_sha256'],
                                  'input_changed_during_assembly')
                output.seek(0)
                output_digest = hashlib.file_digest(output, 'sha256').hexdigest()
                os.fsync(output.fileno())
            os.link(temporary, parent / output_path.name)
        return {'status': manifest['status'], 'installation_authorized': False,
                'input_sha256': plan['input_sha256'], 'plan_sha256': plan['plan_sha256'],
                    'output_sha256': output_digest, 'included_files': len(manifest['files']),
                    'omitted_files': len(manifest['omissions']), 'is_ipa': False,
                    'private_test_only': manifest.get('private_test_only', False)}
    except preflight.InspectionError:
        raise
    except FileExistsError:
        raise preflight.InspectionError('output_already_exists') from None
    except Exception:
        raise preflight.InspectionError('package_assembly_failed') from None
    finally:
        if temporary is not None:
            try:
                Path(temporary).unlink(missing_ok=True)
            except OSError:
                raise preflight.InspectionError('temporary_cleanup_failed') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--policy', type=Path, required=True)
    parser.add_argument('--plan-sha256', required=True)
    parser.add_argument('--profile', choices=('strict', 'extended-review'), default='strict')
    parser.add_argument('--acknowledge-unverified-layout', action='store_true')
    parser.add_argument('--acknowledge-private-bundled-resources', action='store_true')
    args = parser.parse_args()
    try:
        report = assemble_guest(args.input, args.output, policy=package_plan.read_policy(args.policy),
                                expected_plan_sha256=args.plan_sha256, profile=args.profile,
                                acknowledge_unverified_layout=args.acknowledge_unverified_layout,
                                acknowledge_private_bundled_resources=args.acknowledge_private_bundled_resources)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
