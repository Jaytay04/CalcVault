"""Read-only, digest-bound draft layout. Never an accepted loader manifest."""

import argparse
import hashlib
import json
import zipfile
from collections import Counter
from pathlib import Path

import ipa_preflight as preflight

DESTINATION = 'Frameworks/NativeGuest.framework'
POLICY_LIMIT = 1024**2
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
          b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf',
          b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca'}


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        preflight.require(name not in result, 'duplicate_policy_field')
        result[name] = value
    return result


def read_policy(path):
    """Only the explicit JSON policy is read; no profile/key material is opened."""
    try:
        preflight.require(Path(path).suffix.lower() == '.json', 'invalid_policy_file_type')
        with Path(path).open('rb') as stream:
            data = stream.read(POLICY_LIMIT + 1)
        preflight.require(len(data) <= POLICY_LIMIT, 'policy_size_limit')
        value = json.loads(data, object_pairs_hook=unique_object)
        preflight.require(isinstance(value, dict), 'invalid_policy')
        return value
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('invalid_policy') from None


def exclusions(policy, report):
    if policy is None:
        return set(), set()
    preflight.require(isinstance(policy, dict) and set(policy) == {
        'schema', 'input_sha256', 'excluded_extensions', 'excluded_materials'}, 'invalid_policy')
    preflight.require(type(policy['schema']) is int and policy['schema'] == 1, 'invalid_policy')
    preflight.require(policy['input_sha256'] == report['sha256'], 'policy_digest_mismatch')
    selected = []
    for field, known in (('excluded_extensions', report['extensions']),
                         ('excluded_materials', report['uninspected_material_names'])):
        values = policy[field]
        preflight.require(isinstance(values, list) and len(values) <= preflight.MAX_ENTRIES,
                          'invalid_policy')
        names = set()
        for name in values:
            preflight.require(isinstance(name, str) and name in known, 'unknown_policy_target')
            preflight.require(name not in names, 'duplicate_policy_target')
            names.add(name)
        selected.append(names)
    return tuple(selected)


def validate_destinations(members):
    names = set()
    for member in members:
        target = member['proposed_destination']
        if target is None:
            continue
        preflight.require(target.startswith(DESTINATION + '/'), 'unsafe_plan_destination')
        canonical = preflight.key(preflight.checked_name(target))
        preflight.require(canonical not in names, 'plan_destination_collision')
        names.add(canonical)
    for name in names:
        parts = name.split('/')
        preflight.require(not any('/'.join(parts[:i]) in names for i in range(1, len(parts))),
                          'plan_destination_conflict')


def plan_fingerprint(plan):
    value = {k: v for k, v in plan.items() if k != 'plan_sha256'}
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True).encode('ascii')).hexdigest()


def _plan(source, profile, policy):
    report = preflight._inspect(source, profile)
    excluded_extensions, excluded_materials = exclusions(policy, report)
    root = report['main_bundle']['path']
    main = root + '/' + report['main_bundle']['executable']
    materials = set(report['uninspected_material_names'])
    extension_roots = set(report['extensions'])
    bundle_plists = {b['path'] + '/Info.plist' for b in report['bundles']}
    members, blockers = [], set()
    source.seek(0)
    with zipfile.ZipFile(source) as archive:
        entries = preflight.archive_entries(archive, profile)
        for name, entry in sorted(entries.items()):
            target = None
            parts = name.split('/')
            parents = ('/'.join(parts[:i]) for i in range(1, len(parts)))
            ancestors = [p for p in parents if p in extension_roots]
            # An excluded outer extension excludes its entire subtree; an explicitly
            # excluded inner extension must also work when its outer bundle is held.
            extension = next((p for p in ancestors if p in excluded_extensions),
                             ancestors[-1] if ancestors else None)
            if extension is not None:
                action = 'exclude_extension' if extension in excluded_extensions else 'review_extension'
            elif name in materials:
                action = 'exclude_material' if name in excluded_materials else 'review_material'
            elif not name.startswith(root + '/'):
                action = 'review_outside_payload'
            else:
                relative = name[len(root) + 1:]
                if '_CodeSignature' in relative.split('/'):
                    action = 'omit_obsolete_signature'
                elif name == main:
                    action = 'prepare_main_executable'
                    target = DESTINATION + '/NativeGuest'
                elif name in report['code']:
                    action = 'review_embedded_code'
                    target = DESTINATION + '/' + relative
                elif name == root + '/Info.plist':
                    action = 'prepare_framework_metadata'
                    target = DESTINATION + '/Info.plist'
                elif name in bundle_plists:
                    action = 'review_bundle_metadata'
                    target = DESTINATION + '/' + relative
                else:
                    # Sniff only four bytes; no extraction or resource-content logging.
                    # Never reach this path for known material names or extension members.
                    with archive.open(entry) as stream:
                        prefix = stream.read(4)
                    if prefix in MAGICS:
                        action = 'review_unclassified_executable'
                    else:
                        action = 'review_resource'
                        target = DESTINATION + '/' + relative
            if action.startswith('review_'):
                blockers.add(action)
            members.append({'source': name, 'declared_size': entry.file_size,
                            'action': action, 'proposed_destination': target})
    validate_destinations(members)
    source.seek(0)
    preflight.require(hashlib.file_digest(source, 'sha256').hexdigest() == report['sha256'],
                      'input_changed_during_planning')
    # This is a proposed layout, not an extraction allowlist or trust decision.
    result = {'schema': 1, 'status': 'draft_review_required', 'assembly_authorized': False,
            'installation_authorized': False, 'input_sha256': report['sha256'],
            'input_size': report['file_size'], 'inspection_profile': profile,
            'policy_supplied': policy is not None, 'main_bundle': report['main_bundle'],
            'destination_root': DESTINATION, 'members': members,
            'action_counts': dict(sorted(Counter(m['action'] for m in members).items())),
            'code': report['code'], 'review_flags': report['review_flags'],
            'blockers': sorted(blockers | {'main_adapter_not_applied',
                'dependency_layout_not_verified', 'resource_bundle_layout_not_verified',
                'signing_and_guest_boundary_not_verified'}),
            'unverified': report['unverified'] + ['resource_semantics',
                'non_macho_executable_resources', 'immutable_guest_framework_loading']}
    result['plan_sha256'] = plan_fingerprint(result)
    return result


def plan_ipa(path, *, profile='strict', policy=None):
    try:
        with Path(path).open('rb') as source:
            return _plan(source, profile, policy)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('unreadable_or_malformed_plan_input') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--profile', choices=('strict', 'extended-review'), default='strict')
    parser.add_argument('--policy', type=Path, help='Optional digest-bound exclusion proposal JSON.')
    args = parser.parse_args()
    try:
        policy = read_policy(args.policy) if args.policy else None
        result = plan_ipa(args.ipa, profile=args.profile, policy=policy)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'assembly_authorized': False,
                          'installation_authorized': False, 'error': str(error)}))
        return 2
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
