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
