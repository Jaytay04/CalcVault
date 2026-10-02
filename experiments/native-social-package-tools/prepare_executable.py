"""Narrow pre-signing ARM64 adapter. No signing, decryption, installation or execution."""

import argparse
import hashlib
import io
import json
import os
import re
import struct
import tempfile
from pathlib import Path

import ipa_preflight as preflight
import modern_linkedit

MAX_MAIN = 32 * 1024**2
BASE = 0x100000000
PAGE = 0x4000
INSTALL_NAME = b'NativeGuest\0'
ID_SIZE = (24 + len(INSTALL_NAME) + 7) & ~7
MODERN_MAIN_SHA256 = '3daefde434d4c6bdd9e21ea44ad5fd3801a485a8e3c40bf7989421e97eaba40c'
ALLOWED = {0x19, 0x80000022, 0x2, 0xb, 0xe, 0x1b, 0x32, 0x25,
           0x2a, 0x80000028, 0x2c, 0xc, 0x80000018, 0x8000001c,
           0x26, 0x29, 0x1d}


def prepare_main(data, *, expected_sha256):
    """Return new bytes and evidence; the caller must obtain separate signing/launch review."""
    need = preflight.require
    need(isinstance(data, bytes) and 32 <= len(data) <= MAX_MAIN, 'main_size_limit')
    need(isinstance(expected_sha256, str) and re.fullmatch('[0-9a-f]{64}', expected_sha256),
         'invalid_main_digest')
    need(hashlib.sha256(data).hexdigest() == expected_sha256, 'main_digest_mismatch')
    modern_before = None
    modern_input = expected_sha256 == MODERN_MAIN_SHA256
    if modern_input:
        # This is intentionally gated by the exact immutable main-image digest.
        # The validator accepts only the reviewed format-2 fixup/export subset.
        modern_before = modern_linkedit.review(data, hosted=False, base=BASE,
            command_padding=ID_SIZE, maximum_size=MAX_MAIN)
    header = list(struct.unpack_from('<8I', data))
    magic, cpu, subtype, kind, count, length, flags, reserved = header
    need(magic == 0xfeedfacf and cpu == 0x100000c and subtype == 0 and kind == 2 and
         reserved == 0, 'unsupported_main_layout')
    parsed = preflight.macho_slice(io.BytesIO(data), 0, len(data), len(data))
    need(parsed['platforms'] and set(parsed['platforms']) == {2}, 'unsupported_main_platform')
    need(len(parsed['dependencies']) == len(set(parsed['dependencies'])), 'duplicate_main_dependency')
    old_end, new_end = 32 + length, 32 + length + ID_SIZE
    need(count < 8192 and length + ID_SIZE <= preflight.MAX_COMMANDS, 'main_command_limit')
    need(new_end <= len(data), 'no_command_padding')
    need(not any(data[old_end:new_end]), 'nonzero_command_padding')
    commands, segments, sections, counts = [], [], [], {}
    pagezero_index = None
    entrypoint, signature_present = None, False

    def occupied(offset, amount):
        need(0 <= offset <= len(data) and 0 <= amount <= len(data) - offset,
             'invalid_main_data_range')
        if amount:
            need(offset >= new_end, 'main_data_overlaps_new_commands')

    pos = 32
    allowed_commands = ALLOWED | modern_linkedit.MODERN_COMMANDS if modern_input else ALLOWED
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, pos)
        need(cmd in allowed_commands, 'unsupported_main_command')
        counts[cmd] = counts.get(cmd, 0) + 1
        command = data[pos:pos + size]
        if cmd == 0x19:
            need(size >= 72, 'invalid_main_segment')
            segname = command[8:24].split(b'\0')[0]
            vm, vmsize, off, amount, maxprot, prot, nsects, segflags = struct.unpack_from('<4Q4I', command, 24)
            need(size == 72 + 80 * nsects and vm + vmsize <= 2**64 and
                 off <= len(data) and amount <= len(data) - off and amount <= vmsize,
                 'invalid_main_segment')
            if segname == b'__PAGEZERO':
                need(pagezero_index is None and not segments and vm == 0 and vmsize == BASE and
                     off == amount == maxprot == prot == nsects == segflags == 0,
                     'unsupported_pagezero')
                pagezero_index = len(commands)
            else:
                need(vm >= BASE, 'unsupported_main_segment_address')
            segment = {'name': segname, 'vm': vm, 'vmsize': vmsize, 'offset': off,
                       'size': amount, 'protection': prot}
            need(not any(segname == s['name'] for s in segments), 'duplicate_main_segment')
            for other in segments:
                need(not (vmsize and other['vmsize']) or
                     vm + vmsize <= other['vm'] or vm >= other['vm'] + other['vmsize'],
                     'overlapping_main_segments')
                need(not (amount and other['size']) or
                     off + amount <= other['offset'] or off >= other['offset'] + other['size'],
                     'overlapping_main_file_segments')
            segments.append(segment)
            for i in range(nsects):
                section = command[72 + i * 80:152 + i * 80]
                name, parent = section[:16].split(b'\0')[0], section[16:32].split(b'\0')[0]
                address, section_size, fileoff, align, reloff, nreloc, attributes = struct.unpack_from('<2Q5I', section, 32)
                need(parent == segname and vm <= address <= vm + vmsize and
                     section_size <= vm + vmsize - address and align <= 31, 'invalid_main_section')
                if attributes & 0xff not in (1, 0xc, 0x12):
                    occupied(fileoff, section_size)
                    need(off <= fileoff <= off + amount and section_size <= off + amount - fileoff,
                         'invalid_main_section')
                    need(address - vm == fileoff - off, 'unsupported_main_section_mapping')
                    sections.append((name, segname, fileoff, section_size))
                occupied(reloff, nreloc * 8)
        elif cmd == 0x80000028:
            need(size == 24 and counts[cmd] == 1, 'invalid_main_entrypoint')
            entrypoint = struct.unpack_from('<Q', command, 8)[0]
        elif cmd in (0x26, 0x29, 0x1d):
            need(size == 16 and counts[cmd] == 1, 'invalid_main_linkedit_command')
            off, amount = struct.unpack_from('<2I', command, 8)
            occupied(off, amount)
            if cmd == 0x1d:
                need(amount > 0, 'missing_signature_slot')
                signature_present = True
        elif cmd == 0x80000022:
            need(size == 48 and counts[cmd] == 1, 'invalid_main_dyld_info')
            values = struct.unpack_from('<10I', command, 8)
            for i in range(0, 10, 2):
                occupied(values[i], values[i + 1])
        elif cmd == 0x2:
            need(size == 24 and counts[cmd] == 1, 'invalid_main_symtab')
            symoff, nsyms, stroff, strsize = struct.unpack_from('<4I', command, 8)
            occupied(symoff, nsyms * 16)
            occupied(stroff, strsize)
        elif cmd == 0xb:
            need(size == 80 and counts[cmd] == 1, 'invalid_main_dysymtab')
            values = struct.unpack_from('<18I', command, 8)
            for index, stride in ((6, 8), (8, 56), (10, 4), (12, 4), (14, 8), (16, 8)):
                occupied(values[index], values[index + 1] * stride)
        elif cmd == 0x2c:
            need(size == 24 and counts[cmd] == 1, 'invalid_encryption_command')
            off, amount = struct.unpack_from('<2I', command, 8)
            occupied(off, amount)
        elif cmd in modern_linkedit.MODERN_COMMANDS:
            need(modern_input and size == 16 and counts[cmd] == 1,
                 'invalid_modern_linkedit_command')
            off, amount = struct.unpack_from('<2I', command, 8)
            occupied(off, amount)
        elif cmd == 0xe:
            need(size >= 16 and counts[cmd] == 1, 'invalid_main_dylinker')
            start = struct.unpack_from('<I', command, 8)[0]
            need(12 <= start < size and command[start:].split(b'\0')[0] == b'/usr/lib/dyld'
                 and b'\0' in command[start:], 'invalid_main_dylinker')
        elif cmd in (0x1b, 0x2a):
            need(size == (24 if cmd == 0x1b else 16) and counts[cmd] == 1,
                 'invalid_main_fixed_command')
        commands.append(command)
        pos += size
    text = next((s for s in segments if s['name'] == b'__TEXT'), None)
    need(pagezero_index is not None and text is not None and text['vm'] == BASE and
         text['offset'] == 0 and text['size'] >= new_end and text['protection'] & 4,
         'unsupported_main_text_layout')
    need(signature_present, 'missing_signature_slot')
    need(entrypoint is not None and any(name == b'__text' and parent == b'__TEXT' and
         off <= entrypoint < off + amount for name, parent, off, amount in sections),
         'invalid_main_entrypoint')

    # Insert only into verified zero padding. No section or link-edit offset moves.
    zero = bytearray(commands[pagezero_index])
    struct.pack_into('<2Q', zero, 24, BASE - PAGE, PAGE)
    commands[pagezero_index] = bytes(zero)
    identity = (struct.pack('<6I', 0xd, ID_SIZE, 24, 2, 0x10000, 0x10000) + INSTALL_NAME).ljust(ID_SIZE, b'\0')
    header[3], header[4], header[5], header[6] = 6, count + 1, length + ID_SIZE, (flags & ~0x200000) | 0x100000
    output = bytearray(data)
    output[:32] = struct.pack('<8I', *header)
    output[32:new_end] = identity + b''.join(commands)
    output = bytes(output)
    need(output[new_end:] == data[new_end:] and len(output) == len(data), 'adapter_invariant_failed')
    preflight.macho_slice(io.BytesIO(output), 0, len(output), len(output))
    if modern_input:
        modern_after = modern_linkedit.review(output, hosted=True, base=BASE,
            command_padding=0, maximum_size=MAX_MAIN)
        need(modern_before.summary == modern_after.summary and
             modern_before.non_pagezero_geometry == modern_after.non_pagezero_geometry and
             modern_before.payload_ranges == modern_after.payload_ranges and
             modern_before.payload_digests == modern_after.payload_digests,
             'modern_linkedit_invariant_failed')
        # The generic prefix invariant already proves this byte-for-byte; keep
        # the explicit check adjacent to the scoped modern review as well.
        need(output[new_end:] == data[new_end:], 'modern_linkedit_payload_changed')
    unverified = ['signature_validity', 'runtime_loading', 'dependency_layout',
                  'guest_isolation', 'native_features']
    if modern_input:
        unverified.append('modern_linkedit_runtime_compatibility')
    return output, {'status': 'prepared_requires_signing_and_review', 'installation_authorized': False,
                    'input_sha256': expected_sha256, 'output_sha256': hashlib.sha256(output).hexdigest(),
                    'size': len(output), 'entrypoint_offset': entrypoint, 'install_name': 'NativeGuest',
                    'modified_prefix_bytes': new_end, 'original_signature_invalidated': True,
                    'unverified': unverified}


def prepare_file(source_path, output_path, *, expected_sha256):
    """Publish a new file without replacing an existing destination, including symlinks."""
    source_path, output_path = Path(source_path), Path(output_path)
    temporary = None
    try:
        preflight.require(not source_path.name.lower().endswith(preflight.MATERIAL),
                          'material_input_forbidden')
        preflight.require(source_path.resolve() != output_path.resolve(), 'in_place_preparation_forbidden')
        with source_path.open('rb') as stream:
            data = stream.read(MAX_MAIN + 1)
        output, report = prepare_main(data, expected_sha256=expected_sha256)
        parent = output_path.parent.resolve(strict=True)
        descriptor, temporary = tempfile.mkstemp(prefix='.native-prepare-', dir=parent)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(output)
            stream.flush()
            os.fsync(stream.fileno())
        # Hard-link publication is atomic/no-replace. Unsupported filesystems fail visibly.
        os.link(temporary, parent / output_path.name)
        return report
    except preflight.InspectionError:
        raise
    except FileExistsError:
        raise preflight.InspectionError('output_already_exists') from None
    except Exception:
        raise preflight.InspectionError('preparation_io_failed') from None
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
    parser.add_argument('--input-sha256', required=True)
    args = parser.parse_args()
    try:
        report = prepare_file(args.input, args.output, expected_sha256=args.input_sha256)
    except preflight.InspectionError as error:
        print(json.dumps({'status': 'rejected', 'installation_authorized': False, 'error': str(error)}))
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
