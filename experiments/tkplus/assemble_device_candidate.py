"""Local-only assembly of the first independent control-panel testing IPA.

Public CI supplies only the independently authored TKP.dylib. This adapter
preserves the reviewed private host and TikTok code/resources, excludes the
original add-on as a whole, and redirects its weak dependency to our module.
It does not patch licensing, sign, install, or execute either input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import tempfile
import zipfile

SOURCE_SHA256 = '79821f30ed106ed6c463691ae4aaaf87ea07955260d53182b948ec8f29d87ec0'
MAIN_SHA256 = 'a4847252c4ec720f24a26d30082124d6b15c04d23d7bb4d8770ee6c5246c5623'
ORIGINAL_ADDON_SHA256 = 'e99888d3d7e2c37839f5361ccfe2abafcfb1c20ef72c82d9062beb4ed1ab6a55'
ROOT = 'Payload/LiveContainer.app/'
GUEST = ROOT + 'Frameworks/NativeGuest.framework/'
MAIN = GUEST + 'NativeGuest'
ORIGINAL_ADDON = GUEST + 'Frameworks/TTKPlus.dylib'
ORIGINAL_RESOURCES = GUEST + 'TTKPlus.bundle/'
ORIGINAL_SUBSTRATE = GUEST + 'Frameworks/CydiaSubstrate.framework/'
# CVLP rewrites @executable_path to NativeGuest.framework/NativeGuest. Use
# its existing nested runpath; do not introduce a new runpath or loader grant.
NEW_ADDON = GUEST + 'Frameworks/TKP.dylib'
RECEIPT = ROOT + 'TKPIndependentCandidate.json'
OLD_LOAD = b'@rpath/TTKPlus.dylib'
NEW_LOAD = b'@rpath/TKP.dylib'
DEPENDENCY_COMMANDS = {0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023}
MAX_ARCHIVE = 2 * 1024**3
MAX_TOTAL = 3 * 1024**3


def need(condition, message):
    if not condition:
        raise ValueError(message)


def file_sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def member_sha(archive, name):
    with archive.open(name) as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load_commands(data):
    need(len(data) >= 32, 'truncated Mach-O')
    magic, cpu, _subtype, kind, count, amount, _flags, _reserved = struct.unpack_from('<8I', data)
    need(magic == 0xfeedfacf and cpu == 0x100000c and kind == 6, 'expected thin ARM64 dylib')
    need(0 < count <= 256 and 8 * count <= amount <= 65536 and 32 + amount <= len(data),
         'invalid command region')
    position = 32
    result = []
    for _ in range(count):
        need(position + 8 <= 32 + amount, 'truncated command')
        command, size = struct.unpack_from('<II', data, position)
        need(size >= 8 and size % 8 == 0 and position + size <= 32 + amount, 'invalid command')
        result.append((command, position, size))
        position += size
    need(position == 32 + amount, 'command region mismatch')
    return result


def dependency(data, position, size):
    need(size >= 24, 'invalid dylib command')
    offset = struct.unpack_from('<I', data, position + 8)[0]
    need(24 <= offset < size, 'invalid dylib name offset')
    raw = data[position + offset:position + size]
    need(b'\0' in raw, 'unterminated dylib name')
    return offset, raw.split(b'\0', 1)[0]


def redirect_weak_load(data):
    """Preserve ordinal/order/size and all other bytes, including linkedit."""
    matches = []
    for command, position, size in load_commands(data):
        if command in DEPENDENCY_COMMANDS:
            offset, name = dependency(data, position, size)
            if name == OLD_LOAD:
                need(command == 0x80000018, 'original add-on is not weak-linked')
                matches.append((position + offset, position + size))
            need(name != NEW_LOAD, 'independent module already linked')
    need(len(matches) == 1, 'expected exactly one original add-on dependency')
    start, end = matches[0]
    need(len(NEW_LOAD) + 1 <= end - start, 'new dependency exceeds reserved slot')
    output = bytearray(data)
    output[start:end] = NEW_LOAD + bytes(end - start - len(NEW_LOAD))
    need(output[:start] == data[:start] and output[end:] == data[end:], 'unexpected main mutation')
    need(load_commands(output) == load_commands(data), 'command layout changed')
    return bytes(output)


def verify_addon(data):
    need(32 <= len(data) <= 8 * 1024**2, 'independent module size limit')
    commands = load_commands(data)
    identities, platforms = [], []
    allowed = {b'/System/Library/Frameworks/Foundation.framework/Foundation',
               b'/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
               b'/System/Library/Frameworks/UIKit.framework/UIKit',
               b'/System/Library/Frameworks/QuartzCore.framework/QuartzCore',
               b'/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
               b'/usr/lib/libobjc.A.dylib', b'/usr/lib/libSystem.B.dylib'}
    supported_commands = DEPENDENCY_COMMANDS | {
        0x19, 0x2, 0xb, 0xd, 0x1b, 0x32, 0x2a, 0x26, 0x29, 0x1d,
        0x80000034, 0x80000033, 0x22, 0x80000022, 0x21, 0x2c}
    for command, position, size in commands:
        need(command in supported_commands, 'unsupported independent load command')
        if command == 0xd:
            identities.append(dependency(data, position, size)[1])
        elif command in DEPENDENCY_COMMANDS:
            need(dependency(data, position, size)[1] in allowed, 'unexpected independent dependency')
        elif command == 0x32:
            need(size >= 24, 'invalid platform command')
            platform, minimum, _sdk, tools = struct.unpack_from('<4I', data, position + 8)
            need(size == 24 + tools * 8, 'invalid build-tool region')
            platforms.append((platform, minimum))
        elif command in (0x21, 0x2c):
            need(size >= 20 and struct.unpack_from('<I', data, position + 16)[0] == 0,
                 'encrypted independent module')
    need(identities == [NEW_LOAD], 'unexpected independent install name')
    need(platforms == [(2, 18 << 16)], 'expected iOS18 device module')


def validate_entries(archive):
    entries = archive.infolist()
    need(0 < len(entries) <= 5000, 'archive entry limit')
    seen = set()
    total = 0
    for entry in entries:
        name = entry.filename
        path = PurePosixPath(name)
        need(name.startswith(ROOT) and '\\' not in name and '\0' not in name and
             not path.is_absolute() and
             all(part not in ('', '.', '..') for part in name.rstrip('/').split('/')) and
             all(ord(character) >= 32 and ord(character) != 127 for character in name),
             'invalid archive path')
        need(name.casefold() not in seen, 'duplicate archive path')
        seen.add(name.casefold())
        mode = (entry.external_attr >> 16) & 0xffff
        need(not mode or stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'nonordinary archive entry')
        need(not entry.flag_bits & 1 and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
             'unsupported archive entry')
        total += entry.file_size
    need(total <= MAX_TOTAL, 'archive expansion limit')
    return entries


def assemble(source, addon, output, addon_sha256):
    source, addon, output = map(Path, (source, addon, output))
    need(not output.exists(), 'output already exists; never overwrite')
    need(output.suffix == '.ipa' and output.parent.is_dir(), 'invalid output location')
    need(source.resolve() != output.resolve() and addon.resolve() != output.resolve(), 'in-place output forbidden')
    need(source.is_file() and source.stat().st_size <= MAX_ARCHIVE, 'invalid private input')
    need(file_sha(source) == SOURCE_SHA256, 'private input digest mismatch')
    need(len(addon_sha256) == 64 and all(c in '0123456789abcdef' for c in addon_sha256), 'invalid add-on digest')
    need(addon.is_file() and addon.stat().st_size <= 8 * 1024**2, 'invalid independent input')
    need(file_sha(addon) == addon_sha256, 'independent module digest mismatch')
    module = addon.read_bytes()
    need(hashlib.sha256(module).hexdigest() == addon_sha256, 'independent module changed while reading')
    verify_addon(module)
    descriptor, temporary = tempfile.mkstemp(prefix='.tkp-candidate-', suffix='.ipa', dir=output.parent)
    try:
        with zipfile.ZipFile(source) as original, os.fdopen(descriptor, 'w+b') as output_stream:
            entries = validate_entries(original)
            need(MAIN in original.namelist() and ORIGINAL_ADDON in original.namelist(), 'missing reviewed code')
            need(NEW_ADDON not in original.namelist() and RECEIPT not in original.namelist(), 'candidate already modified')
            main = original.read(MAIN)
            need(hashlib.sha256(main).hexdigest() == MAIN_SHA256, 'main digest mismatch')
            need(member_sha(original, ORIGINAL_ADDON) == ORIGINAL_ADDON_SHA256, 'original add-on digest mismatch')
            rewritten = redirect_weak_load(main)
            expected = {}
            omitted = []
            receipt = {'schema': 1, 'candidate': 'TKPlusIndependent-test1',
                       'scope': 'own control panel and opt-in local profile eligibility only',
                       'downloads_connected': False, 'provider_anonymity_verified': False,
                       'private_source_sha256': SOURCE_SHA256, 'independent_module_sha256': addon_sha256,
                       'main_before_sha256': MAIN_SHA256,
                       'main_after_sha256': hashlib.sha256(rewritten).hexdigest(),
                       'original_addon_excluded_whole': True, 'requires_sidestore_resigning': True}
            with zipfile.ZipFile(output_stream, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
                for entry in entries:
                    name = entry.filename
                    if (name == ORIGINAL_ADDON or name.startswith(ORIGINAL_RESOURCES) or
                            name.startswith(ORIGINAL_SUBSTRATE)):
                        omitted.append(name)
                        continue
                    need('/_CodeSignature/' not in name, 'unexpected signed private input')
                    if entry.is_dir():
                        target.writestr(entry, b'')
                        expected[name] = (0, hashlib.sha256(b'').hexdigest())
                        continue
                    if name == MAIN:
                        target.writestr(entry, rewritten)
                        expected[name] = (len(rewritten), hashlib.sha256(rewritten).hexdigest())
                        continue
                    digest = hashlib.sha256()
                    amount = 0
                    with original.open(entry) as reader, target.open(entry, 'w', force_zip64=True) as writer:
                        while chunk := reader.read(1024**2):
                            writer.write(chunk)
                            digest.update(chunk)
                            amount += len(chunk)
                    need(amount == entry.file_size, 'copied member size mismatch')
                    expected[name] = (amount, digest.hexdigest())
                for name, data, executable in ((NEW_ADDON, module, True),
                        (RECEIPT, json.dumps(receipt, sort_keys=True).encode('ascii'), False)):
                    entry = zipfile.ZipInfo(name)
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
                    target.writestr(entry, data)
                    expected[name] = (len(data), hashlib.sha256(data).hexdigest())
            need(len(omitted) > 1, 'original resource bundle missing')
            output_stream.flush()
            need(output_stream.tell() <= MAX_ARCHIVE, 'output archive limit')
            output_stream.seek(0)
            with zipfile.ZipFile(output_stream) as checked:
                validate_entries(checked)
                need(set(checked.namelist()) == set(expected), 'output inventory mismatch')
                need(not any('TTKPlus' in name for name in checked.namelist()), 'original add-on still present')
                for name, (size, digest) in expected.items():
                    need(checked.getinfo(name).file_size == size and member_sha(checked, name) == digest,
                         'output member readback mismatch')
                need(checked.testzip() is None, 'output CRC failure')
            os.fsync(output_stream.fileno())
        need(file_sha(source) == SOURCE_SHA256 and file_sha(addon) == addon_sha256, 'input changed during assembly')
        os.link(temporary, output)
        return dict(receipt, output_sha256=file_sha(output), output_bytes=output.stat().st_size,
                    omitted_addon_files=len(omitted), output_files=len(expected),
                    all_other_members_preserved=True, full_crc_and_hash_readback='PASS',
                    device_install_test='NOT RUN')
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('addon', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--addon-sha256', required=True)
    args = parser.parse_args()
    checksum_path = args.output.with_suffix('.ipa.sha256')
    receipt_path = args.output.with_suffix('.receipt.json')
    need(not checksum_path.exists() and not receipt_path.exists(), 'evidence output already exists')
    report = assemble(args.source, args.addon, args.output, args.addon_sha256)
    with checksum_path.open('x', encoding='ascii') as stream:
        stream.write(report['output_sha256'] + '  ' + args.output.name + '\n')
    with receipt_path.open('x', encoding='ascii') as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(json.dumps(report, indent=2, sort_keys=True))
