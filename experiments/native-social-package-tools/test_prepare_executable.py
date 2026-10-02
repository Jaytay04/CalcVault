"""Generated Mach-O data only; nothing in these tests is executed as native code."""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ipa_preflight
import modern_linkedit
import prepare_executable as subject


def segment(name, vm, size, offset, amount, protection, section=b''):
    return (struct.pack('<II16s4Q4I', 0x19, 72 + len(section), name, vm, size,
                        offset, amount, protection, protection, len(section) // 80, 0) + section)


def fixture(extra=b'', cryptid=0, platform=2, signature=True, entry=True):
    section = struct.pack('<16s16s2Q8I', b'__text', b'__TEXT', subject.BASE + 4096,
                          16, 4096, 2, 0, 0, 0x80000400, 0, 0, 0)
    commands = [segment(b'__PAGEZERO', 0, subject.BASE, 0, 0, 0),
                segment(b'__TEXT', subject.BASE, 16384, 0, 16384, 5, section),
                segment(b'__LINKEDIT', subject.BASE + 16384, 16384, 16384, 1024, 1),
                struct.pack('<6I', 0x32, 24, platform, 0, 0, 0),
                struct.pack('<6I', 0x2c, 24, 0, 0, cryptid, 0)]
    if entry:
        commands.append(struct.pack('<2I2Q', 0x80000028, 24, 4096, 0))
    if signature:
        commands.append(struct.pack('<4I', 0x1d, 16, 16384, 256))
    if extra:
        commands.append(extra)
    body = b''.join(commands)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands), len(body), 0x200085, 0)
    data = bytearray((header + body).ljust(17408, b'\0'))
    data[4096:4112] = b'SYNTHETIC-CODE!!!'
    data[16384:16640] = b'S' * 256  # Synthetic signature placeholder, never a valid signature.
    return bytes(data)


def _uleb(value):
    output = bytearray()
    while True:
        byte = value & 0x7f
        value >>= 7
        output.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(output)


def modern_fixture(export_address=0x1100):
    """Synthetic ARM64 image with one format-2 bind/rebase chain and trie export."""
    section = struct.pack('<16s16s2Q8I', b'__text', b'__TEXT', subject.BASE + 4096,
                          16, 4096, 2, 0, 0, 0x80000400, 0, 0, 0)
    segments = [segment(b'__PAGEZERO', 0, subject.BASE, 0, 0, 0),
                segment(b'__TEXT', subject.BASE, 0x4000, 0, 0x4000, 5, section),
                segment(b'__DATA', subject.BASE + 0x4000, 0x4000, 0x4000, 0x4000, 3),
                segment(b'__LINKEDIT', subject.BASE + 0x8000, 0x4000, 0x8000, 0x4000, 1)]

    # starts_in_image is at 28; its segment-offset array ends at 48, where the
    # sole __DATA starts_in_segment record begins. The record has one 16 KiB page.
    starts, segment_info = 28, 48
    info = struct.pack('<IHHQIH', 24, 0x4000, 2, 0x4000, 0, 1) + struct.pack('<H', 0)
    imports, symbols = segment_info + len(info), segment_info + len(info) + 4
    fixups = (struct.pack('<7I', 0, starts, imports, symbols, 1, 1, 0) +
              struct.pack('<5I', 4, 0, 0, segment_info - starts, 0) +
              info + struct.pack('<I', 1) + b'_synthetic_import\0')

    edge = b'_synthetic_export\0'
    root_prefix = b'\0\x01' + edge
    child = len(root_prefix) + 1
    terminal = _uleb(0) + _uleb(export_address)
    trie = root_prefix + _uleb(child) + bytes([len(terminal)]) + terminal + b'\0'
    fixup_offset, trie_offset = 0x8100, 0x8200
    commands = segments + [
        struct.pack('<6I', 0x32, 24, 2, 0, 0, 0),
        struct.pack('<6I', 0xc, 48, 24, 0, 0x10000, 0x10000) +
            b'libSystem.B.dylib\0'.ljust(24, b'\0'),
        struct.pack('<4I', modern_linkedit.FIXUPS, 16, fixup_offset, len(fixups)),
        struct.pack('<4I', modern_linkedit.EXPORTS, 16, trie_offset, len(trie)),
        struct.pack('<2I2Q', 0x80000028, 24, 4096, 0),
        struct.pack('<4I', 0x1d, 16, 0x9000, 256),
    ]
    body = b''.join(commands)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands), len(body), 0x200085, 0)
    data = bytearray((header + body).ljust(0xc000, b'\0'))
    data[4096:4112] = b'SYNTHETIC-CODE!!!'
    data[0x4000:0x4008] = struct.pack('<Q', (1 << 63) | (2 << 51))
    data[0x4008:0x4010] = struct.pack('<Q', subject.BASE + 0x1100)
    data[fixup_offset:fixup_offset + len(fixups)] = fixups
    data[trie_offset:trie_offset + len(trie)] = trie
    data[0x9000:0x9100] = b'S' * 256
    return bytes(data)


def offsets(data, cmd):
    result, pos = [], 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        value, size = struct.unpack_from('<2I', data, pos)
        if value == cmd:
            result.append(pos)
        pos += size
    return result


class AdapterTests(unittest.TestCase):
    def adapt(self, data):
        return subject.prepare_main(data, expected_sha256=hashlib.sha256(data).hexdigest())

    def reject(self, data, code=None):
        with self.assertRaises(ipa_preflight.InspectionError) as error:
            self.adapt(data)
        if code:
            self.assertEqual(str(error.exception), code)

    def test_prepared_structure_offsets_and_input_preserved(self):
        data = fixture()
        before = bytes(data)
        output, report = self.adapt(data)
        self.assertEqual(data, before)
        self.assertEqual(len(output), len(data))
        self.assertEqual(struct.unpack_from('<I', output, 12)[0], 6)
        self.assertEqual(struct.unpack_from('<I', output, 16)[0], struct.unpack_from('<I', data, 16)[0] + 1)
        self.assertEqual(struct.unpack_from('<I', output, 24)[0] & 0x200000, 0)
        self.assertTrue(struct.unpack_from('<I', output, 24)[0] & 0x100000)
        self.assertEqual(offsets(output, 0xd), [32])
        self.assertEqual(struct.unpack_from('<I', output, 44)[0], 2)
        zero = offsets(output, 0x19)[0]
        self.assertEqual(struct.unpack_from('<2Q', output, zero + 24), (subject.BASE - subject.PAGE, subject.PAGE))
        self.assertEqual(struct.unpack_from('<Q', output, offsets(output, 0x80000028)[0] + 8)[0], 4096)
        self.assertEqual(output[report['modified_prefix_bytes']:], data[report['modified_prefix_bytes']:])
        self.assertFalse(report['installation_authorized'])
        self.assertTrue(report['original_signature_invalidated'])
        self.assertEqual(report['output_sha256'], hashlib.sha256(output).hexdigest())

    def test_output_cannot_be_prepared_twice(self):
        output, _ = self.adapt(fixture())
        self.reject(output, 'unsupported_main_layout')

    def test_digest_and_input_bounds(self):
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^main_digest_mismatch$'):
            subject.prepare_main(fixture(), expected_sha256='0' * 64)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^invalid_main_digest$'):
            subject.prepare_main(fixture(), expected_sha256='not a digest')
        self.reject(b'', 'main_size_limit')
        with patch.object(subject, 'MAX_MAIN', 64):
            self.reject(fixture(), 'main_size_limit')

    def test_unsupported_architecture_and_fat(self):
        for offset, value in ((0, 0xcafebabe), (4, 7), (8, 2), (28, 1)):
            data = bytearray(fixture())
            struct.pack_into('<I', data, offset, value)
            self.reject(bytes(data), 'unsupported_main_layout')

    def test_encryption_and_simulator_rejected(self):
        self.reject(fixture(cryptid=1), 'encrypted_macho')
        self.reject(fixture(platform=7), 'unsupported_macho_platform')

    def test_unrecognized_and_chained_commands_rejected(self):
        for cmd in (0x80000034, 0x9999):
            self.reject(fixture(extra=struct.pack('<4I', cmd, 16, 0, 0)), 'unsupported_main_command')

    def test_modern_commands_are_gated_by_the_exact_test_pin(self):
        data = modern_fixture()
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^unsupported_main_command$'):
            self.adapt(data)
        digest = hashlib.sha256(data).hexdigest()
        with patch.object(subject, 'MODERN_MAIN_SHA256', digest):
            output, report = subject.prepare_main(data, expected_sha256=digest)
            before = modern_linkedit.review(data, hosted=False, base=subject.BASE,
                command_padding=subject.ID_SIZE, maximum_size=subject.MAX_MAIN)
            after = modern_linkedit.review(output, hosted=True, base=subject.BASE,
                command_padding=0, maximum_size=subject.MAX_MAIN)
        self.assertEqual(before.summary, after.summary)
        self.assertEqual(before.non_pagezero_geometry, after.non_pagezero_geometry)
        self.assertEqual(before.payload_ranges, after.payload_ranges)
        self.assertEqual(before.payload_digests, after.payload_digests)
        self.assertIn('modern_linkedit_runtime_compatibility', report['unverified'])
        self.assertNotIn(modern_linkedit.FIXUPS, subject.ALLOWED)
        self.assertNotIn(modern_linkedit.EXPORTS, subject.ALLOWED)
        self.assertEqual(output[report['modified_prefix_bytes']:], data[report['modified_prefix_bytes']:])

    def test_modern_pinned_digest_is_checked_before_parsing(self):
        data = modern_fixture()
        with patch.object(subject, 'MODERN_MAIN_SHA256', 'a' * 64):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^main_digest_mismatch$'):
                subject.prepare_main(data, expected_sha256=subject.MODERN_MAIN_SHA256)

    def test_nonzero_padding_rejected(self):
        data = bytearray(fixture())
        end = 32 + struct.unpack_from('<I', data, 20)[0]
        data[end] = 1
        self.reject(bytes(data), 'nonzero_command_padding')

    def test_zero_section_data_cannot_be_overwritten(self):
        data = bytearray(fixture())
        end = 32 + struct.unpack_from('<I', data, 20)[0]
        section = offsets(data, 0x19)[1] + 72
        struct.pack_into('<Q', data, section + 32, subject.BASE + end)
        struct.pack_into('<I', data, section + 48, end)
        self.reject(bytes(data), 'main_data_overlaps_new_commands')

    def test_pagezero_shape_rejected(self):
        for offset, form, value in ((24, '<Q', 1), (32, '<Q', 4096), (48, '<Q', 1), (56, '<I', 1)):
            data = bytearray(fixture())
            struct.pack_into(form, data, 32 + offset, value)
            self.reject(bytes(data), 'unsupported_pagezero')

    def test_invalid_section_and_segment_ranges(self):
        data = bytearray(fixture())
        section = offsets(data, 0x19)[1] + 72
        struct.pack_into('<Q', data, section + 40, len(data) * 2)
        self.reject(bytes(data), 'invalid_main_section')
        data = bytearray(fixture())
        linkedit = offsets(data, 0x19)[2]
        struct.pack_into('<Q', data, linkedit + 48, len(data) * 2)
        self.reject(bytes(data), 'invalid_main_segment')

    def test_overlapping_segments_rejected(self):
        data = bytearray(fixture())
        linkedit = offsets(data, 0x19)[2]
        struct.pack_into('<Q', data, linkedit + 24, subject.BASE)
        self.reject(bytes(data), 'overlapping_main_segments')

    def test_missing_or_invalid_entry_and_signature(self):
        self.reject(fixture(signature=False), 'missing_signature_slot')
        self.reject(fixture(entry=False), 'invalid_main_entrypoint')
        data = bytearray(fixture())
        struct.pack_into('<Q', data, offsets(data, 0x80000028)[0] + 8, 1)
        self.reject(bytes(data), 'invalid_main_entrypoint')
        data = bytearray(fixture())
        struct.pack_into('<I', data, offsets(data, 0x1d)[0] + 8, len(data))
        self.reject(bytes(data), 'invalid_main_data_range')

    def test_linkedit_tables_cannot_reference_new_commands(self):
        candidates = [struct.pack('<6I', 0x2, 24, 600, 1, 0, 0),
                      struct.pack('<12I', 0x80000022, 48, 600, 1, 0, 0, 0, 0, 0, 0, 0, 0)]
        for command in candidates:
            data = bytearray(fixture(extra=command))
            end = 32 + struct.unpack_from('<I', data, 20)[0]
            struct.pack_into('<I', data, offsets(data, struct.unpack_from('<I', command)[0])[0] + 8, end)
            self.reject(bytes(data), 'main_data_overlaps_new_commands')

    def test_duplicate_or_malformed_signature(self):
        self.reject(fixture(extra=struct.pack('<4I', 0x1d, 16, 16384, 256)), 'invalid_main_linkedit_command')


class PublisherTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.source = self.folder / 'Original'
        self.target = self.folder / 'NativeGuest'
        self.data = fixture()
        self.source.write_bytes(self.data)
        self.digest = hashlib.sha256(self.data).hexdigest()

    def publish(self, target=None):
        return subject.prepare_file(self.source, self.target if target is None else target,
                                    expected_sha256=self.digest)

    def test_new_output_only_and_no_temporary_left(self):
        report = self.publish()
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertEqual(hashlib.sha256(self.target.read_bytes()).hexdigest(), report['output_sha256'])
        self.assertEqual(set(self.folder.iterdir()), {self.source, self.target})

    def test_no_in_place_or_existing_output_overwrite(self):
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^in_place_preparation_forbidden$'):
            self.publish(self.source)
        self.target.write_bytes(b'existing output')
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            self.publish()
        self.assertEqual(self.target.read_bytes(), b'existing output')
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertEqual(set(self.folder.iterdir()), {self.source, self.target})

    def test_link_failure_cleans_only_own_temporary(self):
        with patch.object(os, 'link', side_effect=OSError('private error')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^preparation_io_failed$'):
                self.publish()
        self.assertEqual(list(self.folder.iterdir()), [self.source])

    def test_existing_hardlink_to_input_is_not_overwritten(self):
        os.link(self.source, self.target)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^output_already_exists$'):
            self.publish()
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertEqual(self.target.read_bytes(), self.data)

    def test_validation_failure_does_not_publish(self):
        self.digest = '0' * 64
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^main_digest_mismatch$'):
            self.publish()
        self.assertFalse(self.target.exists())

    def test_material_input_rejected_before_read(self):
        with patch.object(Path, 'open', side_effect=AssertionError('must not open')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^material_input_forbidden$'):
                subject.prepare_file(self.folder / 'synthetic.p12', self.target,
                                     expected_sha256=self.digest)

    def test_cleanup_error_is_sanitized(self):
        with patch.object(Path, 'unlink', side_effect=OSError('PRIVATE-MARKER')):
            with self.assertRaisesRegex(ipa_preflight.InspectionError, '^temporary_cleanup_failed$'):
                self.publish()
        # A published output may exist after a cleanup error. No destructive retry.
        self.assertTrue(self.target.exists())
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_cli_output_and_sanitized_error(self):
        command = [sys.executable, str(Path(subject.__file__)), str(self.source), str(self.target),
                   '--input-sha256', self.digest]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['installation_authorized'])
        command[2] = str(self.folder / 'PRIVATE-MARKER')
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('PRIVATE-MARKER', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
