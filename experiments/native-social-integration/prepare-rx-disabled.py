"""Create a local RX-disabled comparison IPA from the exact pinned Build 23 package.

The output is a comparison candidate that requires SideStore re-signing. This
tool does not patch executable bytes, sign, install, upload, or modify its input.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import struct
import sys
import tempfile
import zipfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
TOOLS_DIR = HERE.parent / 'native-social-package-tools'
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

MERGER_SPEC = importlib.util.spec_from_file_location(
    'rx_disabled_merge_helpers', HERE / 'merge-private-guest.py')
if MERGER_SPEC is None or MERGER_SPEC.loader is None:
    raise RuntimeError('merge_helpers_unavailable')
merger = importlib.util.module_from_spec(MERGER_SPEC)
MERGER_SPEC.loader.exec_module(merger)
preflight = merger.preflight
shared = merger.shared


PINNED_INPUT_SHA256 = '8d579ed3fa6abcd701ba9209cd7d40138c905b19b5d59dffd467531fde58a6fa'
CHUNK = 64 * 1024
MAX_OUTPUT = merger.MAX_OUTPUT
APP_ROOT = merger.APP_ROOT
GUEST_ROOT = merger.GUEST_ROOT
RX_MEMBER = GUEST_ROOT + '/Frameworks/___RXTikTok.dylib'
RX_BASENAME = '___rxtiktok.dylib'
RX_DEPENDENCY = '@executable_path/Frameworks/___RXTikTok.dylib'
RX_INSTALL_NAME = '/Library/MobileSubstrate/DynamicLibraries/___RXTikTok.dylib'
NATIVE_GUEST = GUEST_ROOT + '/' + merger.GUEST_EXECUTABLE

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
MH_EXECUTE = 2
MH_DYLIB = 6
MH_BUNDLE = 8
LC_LOAD_DYLIB = 0x0000000C
LC_ID_DYLIB = 0x0000000D
LC_LAZY_LOAD_DYLIB = 0x00000020
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
DYLIB_COMMANDS = {LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LAZY_LOAD_DYLIB,
                  LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}
MACHO_MAGICS = {
    b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
    b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
    b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf',
    b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca',
}


def need(condition, code):
    preflight.require(condition, code)


def _entry_key(name):
    return preflight.key(preflight.checked_name(name))


def _read_dylib_name(stream, offset, command_size, total):
    need(command_size >= 24, 'invalid_load_path')
    command = preflight.read_exact(stream, offset, command_size, total)
    name_offset = struct.unpack_from('<I', command, 8)[0]
    need(24 <= name_offset < command_size and name_offset % 4 == 0,
         'invalid_load_path')
    raw = command[name_offset:]
    need(b'\0' in raw, 'invalid_load_path')
    try:
        name = preflight.text(raw.split(b'\0', 1)[0].decode('utf-8'))
    except (UnicodeError, preflight.InspectionError):
        raise preflight.InspectionError('invalid_load_path') from None
    need('://' not in name and '?' not in name and '#' not in name,
         'invalid_load_path')
    return name


def _parse_thin_slice(stream, offset, size, total, expected=None):
    magic = preflight.read_exact(stream, offset, 4, total)
    need(magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'),
         'unsupported_macho_format')
    is_64 = magic == b'\xcf\xfa\xed\xfe'
    header_size, alignment = (32, 8) if is_64 else (28, 4)
    need(size >= header_size, 'truncated_macho')
    header = preflight.read_exact(stream, offset, header_size, total)
    values = struct.unpack('<8I' if is_64 else '<7I', header)
    cpu_type, cpu_subtype, filetype, command_count, command_bytes = values[1:6]
    need(expected is None or expected == (cpu_type, cpu_subtype),
         'fat_identity_mismatch')

    # Reuse the shared parser's architecture, platform, encryption and range checks.
    parsed = preflight.macho_slice(stream, offset, size, total, expected,
                                   profile='extended-review')
    need(command_count <= 8192 and command_bytes <= preflight.MAX_COMMANDS and
         header_size + command_bytes <= size,
         'invalid_load_commands')

    commands_start = offset + header_size
    position = 0
    dependencies, identifiers = [], []
    for _ in range(command_count):
        need(position + 8 <= command_bytes, 'invalid_load_commands')
        prefix = preflight.read_exact(stream, commands_start + position, 8, total)
        command, command_size = struct.unpack('<II', prefix)
        need(command_size >= 8 and command_size % alignment == 0 and
             position + command_size <= command_bytes,
             'invalid_load_commands')
        if command in DYLIB_COMMANDS:
            name = _read_dylib_name(stream, commands_start + position,
                                    command_size, total)
            record = {'command': command, 'name': name}
            if command == LC_ID_DYLIB:
                identifiers.append(record)
            else:
                dependencies.append(record)
        position += command_size
    need(position == command_bytes, 'invalid_load_commands')
    need(filetype in (MH_EXECUTE, MH_DYLIB, MH_BUNDLE), 'unsupported_macho_filetype')
    return {'architecture': parsed['architecture'], 'filetype': filetype,
            'dependencies': dependencies, 'identifiers': identifiers}


def _parse_macho(stream, size):
    need(4 <= size <= preflight.MAX_REVIEW_ENTRY, 'archive_entry_limit')
    magic = preflight.read_exact(stream, 0, 4, size)
    if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        return [_parse_thin_slice(stream, 0, size, size)]

    # Universal binary headers are big-endian. Each slice is still validated by
    # the shared parser, including armv7/arm64/arm64e architecture and range checks.
    need(magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'),
         'unsupported_macho_format')
    header = preflight.read_exact(stream, 0, 8, size)
    count = struct.unpack_from('>I', header, 4)[0]
    need(0 < count <= 8, 'invalid_fat_header')
    wide = magic == b'\xca\xfe\xba\xbf'
    stride = 32 if wide else 20
    table_end = 8 + count * stride
    need(table_end <= size, 'invalid_fat_header')
    table = preflight.read_exact(stream, 8, count * stride, size)
    ranges, identities, result = [], set(), []
    for index in range(count):
        values = struct.unpack_from('>IIQQII' if wide else '>5I', table,
                                    index * stride)
        cpu_type, cpu_subtype, slice_offset, slice_size, alignment = values[:5]
        need(not wide or values[5] == 0, 'invalid_fat_header')
        need((cpu_type, cpu_subtype) not in identities, 'duplicate_fat_slice')
        identities.add((cpu_type, cpu_subtype))
        need(alignment <= 30 and slice_offset % (1 << alignment) == 0 and
             slice_offset >= table_end and slice_size >= 28 and
             slice_offset <= size and slice_size <= size - slice_offset,
             'invalid_fat_range')
        need(all(slice_offset + slice_size <= start or slice_offset >= end
                 for start, end in ranges), 'overlapping_fat_slices')
        ranges.append((slice_offset, slice_offset + slice_size))
        result.append(_parse_thin_slice(stream, slice_offset, slice_size, size,
                                        (cpu_type, cpu_subtype)))
    return result


def _macho_candidates(archive, entries, *, require_rx):
    required = {
        APP_ROOT + '/LiveContainer',
        merger.EXTENSION_ROOT + '/LiveProcess',
        merger.KIT_ROOT + '/CalcVaultKit',
        NATIVE_GUEST,
    }
    names = set(entries)
    need(required <= names, 'incomplete_build23_package')
    if require_rx:
        need(RX_MEMBER in names, 'missing_or_aliased_rx_library')
        required.add(RX_MEMBER)
    candidates = set(required)
    rx_aliases = []
    for name, entry in entries.items():
        checked = preflight.checked_name(name)
        if checked.rsplit('/', 1)[-1].casefold() == RX_BASENAME:
            rx_aliases.append(name)
        if name.lower().endswith('.dylib'):
            candidates.add(name)
        # Inspect every archive member's magic so embedded framework binaries and
        # binaries without filename extensions cannot escape dependency review.
        with archive.open(entry, 'r') as stream:
            prefix = stream.read(4)
        if prefix in MACHO_MAGICS:
            candidates.add(name)
    return candidates, rx_aliases


def _inspect_machos(archive, entries, *, require_rx):
    candidates, rx_aliases = _macho_candidates(archive, entries, require_rx=require_rx)
    if require_rx:
        need(rx_aliases == [RX_MEMBER], 'missing_or_aliased_rx_library')
    else:
        need(not rx_aliases and RX_MEMBER not in entries,
             'rx_library_still_present')

    parsed_members = {}
    for name in sorted(candidates):
        entry = entries.get(name)
        need(entry is not None and not entry.is_dir(), 'missing_macho_member')
        try:
            with archive.open(entry, 'r') as stream:
                slices = _parse_macho(stream, entry.file_size)
        except preflight.InspectionError:
            raise
        except Exception:
            raise preflight.InspectionError('malformed_macho') from None
        parsed_members[name] = slices

    rx_identifiers = []
    rx_references = []
    guest_slices = parsed_members.get(NATIVE_GUEST, [])
    for name, slices in parsed_members.items():
        for slice_index, image in enumerate(slices):
            for identifier in image['identifiers']:
                if identifier['name'] == RX_INSTALL_NAME or \
                        identifier['name'].rsplit('/', 1)[-1].casefold() == RX_BASENAME:
                    rx_identifiers.append((name, slice_index, image['filetype'], identifier))
            for dependency in image['dependencies']:
                if dependency['name'].rsplit('/', 1)[-1].casefold() == RX_BASENAME:
                    rx_references.append((name, slice_index, dependency))

    if require_rx:
        expected_ids = [(RX_MEMBER, index)
                        for index in range(len(parsed_members[RX_MEMBER]))]
        need([(name, index) for name, index, _filetype, _identifier in rx_identifiers] ==
             expected_ids and
             all(name == RX_MEMBER and filetype == MH_DYLIB and
                 identifier['name'] == RX_INSTALL_NAME
                 for name, _index, filetype, identifier in rx_identifiers),
             'unexpected_rx_install_name')
        expected_refs = [(NATIVE_GUEST, index) for index in range(len(guest_slices))]
        need(len(guest_slices) > 0 and
             [(name, index) for name, index, _dep in rx_references] == expected_refs and
             all(dep['command'] == LC_LOAD_WEAK_DYLIB and
                 dep['name'] == RX_DEPENDENCY
                 for _name, _index, dep in rx_references),
             'unexpected_rx_dependency')
    else:
        # The weak reference intentionally remains in the unchanged guest binary;
        # every slice must still mark it weak so the missing library is optional.
        need(not rx_identifiers, 'rx_library_still_present')
        expected_refs = [(NATIVE_GUEST, index) for index in range(len(guest_slices))]
        need(len(guest_slices) > 0 and
             [(name, index) for name, index, _dep in rx_references] == expected_refs and
             all(dep['command'] == LC_LOAD_WEAK_DYLIB and
                 dep['name'] == RX_DEPENDENCY
                 for _name, _index, dep in rx_references),
             'unexpected_rx_dependency')
    return parsed_members


def _drain_member(archive, entry):
    count = 0
    try:
        with archive.open(entry, 'r') as stream:
            while True:
                block = stream.read(CHUNK)
                if not block:
                    break
                count += len(block)
                need(count <= entry.file_size, 'member_size_mismatch')
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('invalid_archive_member') from None
    need(count == entry.file_size, 'member_size_mismatch')


def _copy_members(archive, members, output_stream):
    expected = {}
    try:
        with zipfile.ZipFile(output_stream, 'w', compression=zipfile.ZIP_STORED,
                             allowZip64=False) as output:
            for entry in members:
                name = entry.filename
                key = _entry_key(name)
                if key == preflight.key(RX_MEMBER):
                    continue
                info = shared.output_zip_info(
                    name, entry, executable=bool((entry.external_attr >> 16) & 0o111))
                if entry.is_dir():
                    output.writestr(info, b'')
                    expected[key] = (name, 0, hashlib.sha256(b'').hexdigest())
                else:
                    digest, count = hashlib.sha256(), 0
                    with archive.open(entry, 'r') as source, output.open(info, 'w') as dest:
                        while True:
                            block = source.read(CHUNK)
                            if not block:
                                break
                            count += len(block)
                            need(count <= entry.file_size, 'member_size_mismatch')
                            dest.write(block)
                            digest.update(block)
                            need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
                    need(count == entry.file_size, 'member_size_mismatch')
                    expected[key] = (name, count, digest.hexdigest())
                need(output_stream.tell() <= MAX_OUTPUT, 'output_size_limit')
        size = os.fstat(output_stream.fileno()).st_size
        need(22 <= size <= MAX_OUTPUT, 'output_size_limit')
        output_stream.flush()
        return expected
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_write_failed') from None


def _verify_output(output_stream, expected, original_input_info):
    try:
        size = os.fstat(output_stream.fileno()).st_size
        need(22 <= size <= MAX_OUTPUT, 'output_size_limit')
        preflight.bound_central_directory(output_stream, size)
        output_stream.seek(0)
        with zipfile.ZipFile(output_stream, 'r') as archive:
            entries = preflight.archive_entries(archive, 'extended-review')
            members = merger._archive_members(archive, entries)
            actual = {}
            for entry in members:
                key = _entry_key(entry.filename)
                need(key not in actual, 'output_inventory_mismatch')
                actual[key] = entry
            need(set(actual) == set(expected), 'output_inventory_mismatch')
            for key, entry in actual.items():
                expected_name, expected_size, expected_digest = expected[key]
                need(entry.filename == expected_name and entry.file_size == expected_size,
                     'output_member_metadata_mismatch')
                digest, count = hashlib.sha256(), 0
                if entry.is_dir():
                    need(expected_size == 0, 'output_member_size_mismatch')
                else:
                    with archive.open(entry, 'r') as stream:
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
            host_info = merger._host_bundle(
                archive, entries, members, build=merger.HOST_BUILD,
                stage=merger.PRIVATE_STAGE, kind=merger.PRIVATE_KIND,
                require_kit=True, require_calcvault_host=True)
            need(host_info == original_input_info, 'unexpected_host_info_changes')
            merger._validate_guest_source(archive, entries, members)
            _inspect_machos(archive, entries, require_rx=False)
        output_stream.seek(0)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('output_verification_failed') from None


def prepare_rx_disabled(input_path, output_path, *,
                        _expected_input_sha256=PINNED_INPUT_SHA256):
    """Copy the pinned Build 23 package while omitting its exact RX dylib member."""
    input_path, output_path = Path(input_path), Path(output_path)
    input_stream = archive = None
    temporary = None
    try:
        need(isinstance(_expected_input_sha256, str) and
             len(_expected_input_sha256) == 64 and
             all(ch in '0123456789abcdef' for ch in _expected_input_sha256),
             'invalid_input_digest')
        need(input_path.suffix.lower() == '.ipa' and output_path.suffix.lower() == '.ipa',
             'invalid_package_file_type')
        parent = output_path.parent.resolve(strict=True)
        output_target = parent / output_path.name
        need(input_path.resolve(strict=True) != output_target,
             'in_place_prepare_forbidden')
        try:
            output_target.lstat()
        except FileNotFoundError:
            pass
        else:
            raise preflight.InspectionError('output_already_exists')
        input_stream, input_digest, input_identity = shared.archive_size_and_hash(input_path)
        need(input_digest == _expected_input_sha256, 'input_digest_mismatch')
        archive, entries, _names, _total = shared.checked_archive(
            input_stream, input_identity[2], 'extended-review')
        members = merger._archive_members(archive, entries)
        host_info = merger._host_bundle(
            archive, entries, members, build=merger.HOST_BUILD,
            stage=merger.PRIVATE_STAGE, kind=merger.PRIVATE_KIND,
            require_kit=True, require_calcvault_host=True)
        guest_info, guest_names = merger._validate_guest_source(archive, entries, members)
        need(guest_info.get('CFBundleIdentifier') == merger.GUEST_ID and
             guest_info.get('CFBundleVersion') == merger.GUEST_BUILD and
             bool(guest_names), 'unexpected_guest_identity_or_version')
        _inspect_machos(archive, entries, require_rx=True)
        _drain_member(archive, entries[RX_MEMBER])

        descriptor_fd, temporary = tempfile.mkstemp(
            prefix='.rx-disabled-', suffix='.ipa', dir=parent)
        with os.fdopen(descriptor_fd, 'w+b') as output:
            expected = _copy_members(archive, members, output)
            need(preflight.key(RX_MEMBER) not in expected,
                 'rx_library_still_present')
            _verify_output(output, expected, host_info)
            output.seek(0)
            output_digest = hashlib.file_digest(output, 'sha256').hexdigest()
            os.fsync(output.fileno())

        shared.recheck_input(input_path, input_stream, _expected_input_sha256,
                             input_identity)
        os.link(temporary, output_target)
        return {
            'status': 'rx_disabled_comparison_requires_sidestore_resigning',
            'installation_authorized': False,
            'requires_sidestore_resigning': True,
            'valid_final_signature': False,
            'runtime_verified': False,
            'input_sha256': input_digest,
            'output_sha256': output_digest,
            'omitted_member': RX_MEMBER,
            'input_members': len(members),
            'output_members': len(expected),
            'is_ipa': True,
        }
    except preflight.InspectionError:
        raise
    except FileExistsError:
        raise preflight.InspectionError('output_already_exists') from None
    except Exception:
        raise preflight.InspectionError('preparation_failed') from None
    finally:
        if archive is not None:
            archive.close()
        if input_stream is not None:
            input_stream.close()
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
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args(argv)
    try:
        report = prepare_rx_disabled(args.input, args.output)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False,
                          'valid_final_signature': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
