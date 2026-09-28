"""Local, read-only IPA inventory. A parsed report never authorizes installation."""

import argparse
import hashlib
import json
import plistlib
import stat
import struct
import unicodedata
import zipfile
from pathlib import Path

MAX_ARCHIVE = 2 * 1024**3
MAX_ENTRY = 512 * 1024**2
MAX_REVIEW_ENTRY = 1024**3
MAX_TOTAL = 4 * 1024**3
MAX_ENTRIES = 20000
MAX_COMMANDS = 4 * 1024**2
MATERIAL = ('.p12', '.pfx', '.pem', '.key', '.der', '.mobileprovision')


class InspectionError(ValueError):
    """Messages are fixed codes, never raw parser errors or input contents."""


def require(condition, code):
    if not condition:
        raise InspectionError(code)


def entry_limit(profile):
    require(profile in ('strict', 'extended-review'), 'unsupported_inspection_profile')
    return MAX_ENTRY if profile == 'strict' else MAX_REVIEW_ENTRY


def text(value):
    require(isinstance(value, str) and 0 < len(value) <= 1024, 'invalid_metadata')
    require(all(ord(c) >= 32 and ord(c) != 127 for c in value), 'invalid_metadata')
    return value


def key(name):
    return unicodedata.normalize('NFC', name).casefold()


def checked_name(name):
    text(name)
    require(not name.startswith('/') and '\\' not in name and ':' not in name,
            'unsafe_archive_path')
    parts = name.rstrip('/').split('/')
    require(all(p and p not in ('.', '..') and not p.endswith((' ', '.')) for p in parts),
            'unsafe_archive_path')
    return name.rstrip('/')


def bound_central_directory(source, size):
    """Reject ZIP64/multidisk and oversized central directories before ZipFile allocates."""
    require(22 <= size <= MAX_ARCHIVE, 'archive_size_limit')
    source.seek(max(0, size - 65557))
    tail = source.read(65557)
    offset = tail.rfind(b'PK\x05\x06')
    require(offset >= 0 and len(tail) - offset >= 22, 'invalid_zip_directory')
    _, disk, cd_disk, disk_count, count, cd_size, cd_offset, comment = struct.unpack_from(
        '<4s4H2IH', tail, offset)
    require(offset + 22 + comment == len(tail), 'invalid_zip_directory')
    require(disk == cd_disk == 0 and disk_count == count, 'unsupported_multidisk_zip')
    require(count < 65535 and cd_size != 0xffffffff and cd_offset != 0xffffffff,
            'unsupported_zip64')
    require(count <= MAX_ENTRIES and cd_size <= 16 * 1024**2, 'archive_directory_limit')
    require(cd_offset + cd_size == size - len(tail) + offset, 'invalid_zip_directory')
    source.seek(0)


def archive_entries(archive, profile='strict'):
    limit = entry_limit(profile)
    entries = archive.infolist()
    require(len(entries) <= MAX_ENTRIES, 'archive_directory_limit')
    seen, file_keys, total = {}, set(), 0
    for entry in entries:
        require(entry.orig_filename == entry.filename, 'unsafe_archive_path')
        name = checked_name(entry.filename)
        folded = key(name)
        require(folded not in seen, 'duplicate_archive_path')
        seen[folded] = entry
        mode = stat.S_IFMT(entry.external_attr >> 16)
        require(mode in (0, stat.S_IFREG, stat.S_IFDIR), 'unsupported_archive_entry')
        require(mode != stat.S_IFDIR or entry.is_dir(), 'invalid_directory_entry')
        require(mode != stat.S_IFREG or not entry.is_dir(), 'invalid_directory_entry')
        require(not (entry.flag_bits & 1), 'encrypted_zip_entry')
        require(entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                'unsupported_zip_compression')
        require(entry.file_size <= limit and
                entry.file_size <= max(1, entry.compress_size) * 1000, 'archive_entry_limit')
        total += entry.file_size
        require(total <= MAX_TOTAL, 'archive_total_limit')
        if not entry.is_dir():
            file_keys.add(folded)
    for name in seen:
        parts = name.split('/')
        require(not any('/'.join(parts[:i]) in file_keys for i in range(1, len(parts))),
                'archive_file_directory_conflict')
    return {e.filename: e for e in entries if not e.is_dir()}


def read_plist(archive, entries, name):
    require(name in entries and entries[name].file_size <= 1024**2, 'invalid_bundle_plist')
    data = archive.read(name)
    # Binary/XML plist only; no entity declarations or external document processing.
    require(b'<!ENTITY' not in data, 'invalid_bundle_plist')
    try:
        value = plistlib.loads(data)
    except Exception:
        raise InspectionError('invalid_bundle_plist') from None
    require(isinstance(value, dict), 'invalid_bundle_plist')
    return value


def read_exact(stream, offset, length, limit):
    require(0 <= offset <= limit and 0 <= length <= limit - offset, 'invalid_macho_range')
    stream.seek(offset)
    result = stream.read(length)
    require(len(result) == length, 'truncated_macho')
    return result


def macho_slice(stream, offset, size, total, expected=None, profile='strict'):
    entry_limit(profile)
    require(size >= (28 if profile == 'extended-review' else 32), 'truncated_macho')
    magic, cpu, subtype, kind, count, length, flags = struct.unpack(
        '<7I', read_exact(stream, offset, 28, total))
    legacy = magic == 0xfeedface and cpu == 12 and subtype & 0xffffff == 9
    arm64 = magic == 0xfeedfacf and cpu == 0x100000c and subtype & 0xffffff in (0, 1, 2)
    require(arm64 or (profile == 'extended-review' and legacy), 'unsupported_macho_architecture')
    header_size, alignment = (28, 4) if legacy else (32, 8)
    require(size >= header_size, 'truncated_macho')
    require(expected is None or expected == (cpu, subtype), 'fat_identity_mismatch')
    require(kind in (2, 6, 8), 'unsupported_macho_filetype')
    require(count <= 8192 and length <= MAX_COMMANDS and header_size + length <= size,
            'invalid_load_commands')
    commands = read_exact(stream, offset + header_size, length, total)
    pos, platforms, encryption, dependencies, rpaths = 0, [], [], [], []
    for _ in range(count):
        require(pos + 8 <= length, 'invalid_load_commands')
        cmd, command_size = struct.unpack_from('<II', commands, pos)
        require(command_size >= 8 and command_size % alignment == 0 and
                pos + command_size <= length, 'invalid_load_commands')
        if cmd in (0x21, 0x2c):
            require(command_size >= (24 if cmd == 0x2c else 20), 'invalid_encryption_command')
            start, amount, cryptid = struct.unpack_from('<3I', commands, pos + 8)
            require(start <= size and amount <= size - start, 'invalid_encryption_command')
            require(cryptid == 0, 'encrypted_macho')
            encryption.append(cryptid)
        if cmd == 0x32:
            require(command_size >= 24, 'invalid_platform_command')
            platform, _, _, tools = struct.unpack_from('<4I', commands, pos + 8)
            require(24 + tools * 8 == command_size, 'invalid_platform_command')
            platforms.append(platform)
        elif cmd in (0x24, 0x25, 0x2f, 0x30):
            require(command_size == 16, 'invalid_platform_command')
            platforms.append({0x24: 1, 0x25: 2, 0x2f: 3, 0x30: 4}[cmd])
        if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x8000001c):
            minimum = 12 if cmd == 0x8000001c else 24
            require(command_size >= minimum, 'invalid_load_path')
            start = struct.unpack_from('<I', commands, pos + 8)[0]
            require(minimum <= start < command_size, 'invalid_load_path')
            raw = commands[pos + start:pos + command_size]
            require(b'\0' in raw, 'invalid_load_path')
            try:
                path = text(raw.split(b'\0', 1)[0].decode('utf-8'))
            except (UnicodeError, InspectionError):
                raise InspectionError('invalid_load_path') from None
            require('://' not in path and '?' not in path and '#' not in path, 'invalid_load_path')
            (rpaths if cmd == 0x8000001c else dependencies).append(path)
        pos += command_size
    require(pos == length, 'invalid_load_commands')
    require(not platforms or set(platforms) == {2}, 'unsupported_macho_platform')
    return {'architecture': 'armv7' if legacy else ('arm64e' if subtype & 0xffffff == 2 else 'arm64'),
            'cpu_subtype': subtype, 'filetype': kind, 'platforms': platforms,
            'cryptids': encryption, 'dependencies': dependencies, 'rpaths': rpaths,
            'dependencies_needing_layout_review': [d for d in dependencies if not d.startswith(
                ('/usr/lib/', '/System/Library/Frameworks/'))]}


def inspect_macho(archive, entry, profile='strict'):
    entry_limit(profile)
    size = entry.file_size
    with archive.open(entry) as stream:
        magic = read_exact(stream, 0, 4, size)
        if magic == b'\xcf\xfa\xed\xfe' or (profile == 'extended-review' and magic == b'\xce\xfa\xed\xfe'):
            return [macho_slice(stream, 0, size, size, profile=profile)]
        require(magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'),
                'unsupported_macho_format')
        count = struct.unpack('>I', read_exact(stream, 4, 4, size))[0]
        require(0 < count <= 8, 'invalid_fat_header')
        wide = magic[-1] == 0xbf
        stride = 32 if wide else 20
        table_end = 8 + count * stride
        table = read_exact(stream, 8, count * stride, size)
        ranges, identities, result = [], set(), []
        for i in range(count):
            values = struct.unpack_from('>IIQQII' if wide else '>5I', table, i * stride)
            cpu, sub, offset, amount, align = values[:5]
            require(not wide or values[5] == 0, 'invalid_fat_header')
            require((cpu, sub) not in identities, 'duplicate_fat_slice')
            identities.add((cpu, sub))
            require(align <= 30 and offset % (1 << align) == 0 and offset >= table_end and
                    amount >= (28 if profile == 'extended-review' else 32) and
                    offset <= size and amount <= size - offset,
                    'invalid_fat_range')
            require(all(offset + amount <= a or offset >= b for a, b in ranges),
                    'overlapping_fat_slices')
            ranges.append((offset, offset + amount))
            result.append(macho_slice(stream, offset, amount, size, (cpu, sub), profile))
        return result


def _inspect(source, profile='strict'):
    limit = entry_limit(profile)
    source.seek(0, 2)
    size = source.tell()
    bound_central_directory(source, size)
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
    source.seek(0)
    with zipfile.ZipFile(source) as archive:
        entries = archive_entries(archive, profile)
        roots = [n[:-11] for n in entries if n.startswith('Payload/') and
                 n.endswith('.app/Info.plist') and n.count('/') == 2]
        require(len(roots) == 1, 'expected_one_payload_app')
        root = roots[0]
        code, bundles = {}, []
        bundle_dirs = {root}
        for name in entries:
            parts = name.split('/')
            for i, part in enumerate(parts[:-1]):
                if part.endswith(('.app', '.appex', '.framework')):
                    bundle_dirs.add('/'.join(parts[:i + 1]))
        for directory in sorted(bundle_dirs):
            require(directory == root or directory.startswith(root + '/'), 'code_outside_root_app')
            require(directory == root or not directory.endswith('.app'), 'nested_app_not_supported')
            info = read_plist(archive, entries, directory + '/Info.plist')
            executable = text(info.get('CFBundleExecutable'))
            require('/' not in executable and checked_name(executable) == executable and
                    not executable.lower().endswith(MATERIAL), 'invalid_bundle_executable')
            name = directory + '/' + executable
            require(name in entries, 'missing_bundle_executable')
            code[name] = inspect_macho(archive, entries[name], profile)
            bundles.append({'path': directory, 'identifier': text(info.get('CFBundleIdentifier')),
                            'version': text(info.get('CFBundleShortVersionString', 'unspecified')),
                            'build': text(info.get('CFBundleVersion', 'unspecified')),
                            'executable': executable})
        for name, entry in entries.items():
            if name.lower().endswith('.dylib'):
                require(name.startswith(root + '/'), 'code_outside_root_app')
                code[name] = inspect_macho(archive, entry, profile)
        main = next(b for b in bundles if b['path'] == root)
        require(all(s['architecture'] in ('arm64', 'arm64e') and s['filetype'] == 2 and
                    s['platforms'] and set(s['platforms']) == {2}
                    for s in code[root + '/' + main['executable']]), 'unsupported_main_executable')
        materials = sorted(n for n in entries if n.lower().endswith(MATERIAL))
        extensions = sorted(d for d in bundle_dirs if d.endswith('.appex'))
        flags = ['main_executable_requires_pre_signing_adapter', 'dependency_layout_review_required']
        if profile == 'extended-review':
            flags.append('extended_inspection_profile_selected')
        if any(s['architecture'] == 'armv7' for slices in code.values() for s in slices):
            flags.append('legacy_architecture_requires_disposition')
        if materials:
            flags.append('certificate_or_key_named_resources_uninspected')
        if extensions:
            flags.append('guest_extensions_require_disposition')
        if any(not s['platforms'] for slices in code.values() for s in slices):
            flags.append('some_embedded_platforms_unspecified')
        return {'schema': 1, 'status': 'review_required', 'checks_completed': True,
                'inspection_profile': profile, 'max_entry_bytes': limit,
                'installation_authorized': False, 'sha256': digest, 'file_size': size,
                'entry_count': len(archive.infolist()), 'main_bundle': main, 'bundles': bundles,
                'other_file_count': len(entries) - len(code),
                'framework_count': sum(d.endswith('.framework') for d in bundle_dirs),
                'extensions': extensions, 'dylib_count': sum(n.lower().endswith('.dylib') for n in entries),
                'uninspected_material_names': materials, 'code': code, 'review_flags': flags,
                'unverified': ['signatures', 'entitlements', 'publisher_provenance', 'runtime_compatibility',
                               'unlisted_executable_resources', 'full_archive_crc']}


def inspect_ipa(path, *, profile='strict'):
    try:
        entry_limit(profile)
        with Path(path).open('rb') as source:
            return _inspect(source, profile)
    except InspectionError:
        raise
    except Exception:
        raise InspectionError('unreadable_or_malformed_ipa') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--profile', choices=('strict', 'extended-review'), default='strict',
                        help='Explicit metadata review of up to 1 GiB entries and ARMv7 library slices.')
    args = parser.parse_args()
    try:
        result = inspect_ipa(args.ipa, profile=args.profile)
    except InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False, 'error': str(error)}))
        return 2
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
