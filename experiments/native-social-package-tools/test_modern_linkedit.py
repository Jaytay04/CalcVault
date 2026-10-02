"""Synthetic chained-fixup/export-trie bounds; no guest code is executed."""
import struct
import unittest

import ipa_preflight
import modern_linkedit as subject
from test_prepare_executable import modern_fixture


class ModernLinkeditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = modern_fixture()
        cls.commands = {}
        cls.segments = []
        count, command_bytes = struct.unpack_from('<2I', cls.data, 16)
        cls.command_end = 32 + command_bytes
        position = 32
        for _ in range(count):
            command, size = struct.unpack_from('<2I', cls.data, position)
            cls.commands[command] = position
            if command == 0x19:
                cls.segments.append(position)
            position += size
        cls.fixup = struct.unpack_from('<I', cls.data, cls.commands[subject.FIXUPS] + 8)[0]
        cls.trie = struct.unpack_from('<I', cls.data, cls.commands[subject.EXPORTS] + 8)[0]
        cls.starts, cls.imports, cls.symbols = struct.unpack_from('<3I', cls.data, cls.fixup + 4)
        cls.info = cls.fixup + cls.starts + struct.unpack_from(
            '<I', cls.data, cls.fixup + cls.starts + 12)[0]
        cls.data_segment_offset = struct.unpack_from('<Q', cls.data, cls.segments[2] + 40)[0]
        cls.node = cls.data_segment_offset + struct.unpack_from('<H', cls.data, cls.info + 22)[0]
        cls.child_ref = cls.data.index(b'\0', cls.trie + 2) + 1
        cls.leaf = cls.trie + cls.data[cls.child_ref]

    def reject(self, changes, expected):
        data = bytearray(self.data)
        for offset, fmt, value in changes:
            struct.pack_into(fmt, data, offset, value)
        with self.assertRaises(ipa_preflight.InspectionError) as caught:
            subject.review(bytes(data))
        self.assertEqual(str(caught.exception), expected)

    def test_synthetic_subset_and_hosted_geometry(self):
        before = subject.review(self.data)
        self.assertEqual(before.summary['status'], 'modern_linkedit_subset_reviewed')
        self.assertEqual(before.summary['pointer_formats'], [2])
        self.assertEqual((before.summary['bind_nodes'], before.summary['rebase_nodes']), (1, 1))
        self.assertEqual(before.summary['exports'], 1)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^probe_pagezero_invariant$'):
            subject.review(self.data, hosted=True)

    def test_modern_command_rejections(self):
        fixup_command = self.commands[subject.FIXUPS]
        for changes, expected in [
            ([(fixup_command + 8, '<I', 0)], 'probe_modern_range'),
            ([(fixup_command + 12, '<I', len(self.data))], 'probe_modern_range'),
            ([(fixup_command + 12, '<I', 0)], 'probe_modern_range'),
            ([(fixup_command + 8, '<I', struct.unpack_from(
                '<I', self.data, self.commands[subject.EXPORTS] + 8)[0])], 'probe_payload_overlap'),
            ([(self.commands[subject.EXPORTS], '<I', subject.FIXUPS)], 'probe_modern_command'),
        ]:
            with self.subTest(expected=expected, changes=changes):
                self.reject(changes, expected)

    def test_header_start_table_import_and_ordinal_bounds(self):
        fixup = self.fixup
        for changes, expected in [
            ([(fixup, '<I', 1)], 'probe_fixup_format'),
            ([(fixup + 20, '<I', 2)], 'probe_fixup_format'),
            ([(fixup + 24, '<I', 1)], 'probe_fixup_format'),
            ([(fixup + 4, '<I', 0)], 'probe_fixup_offsets'),
            ([(fixup + 8, '<I', len(self.data))], 'probe_fixup_offsets'),
            ([(fixup + 16, '<I', subject.MAX_IMPORTS + 1)], 'probe_fixup_offsets'),
            ([(fixup + self.starts, '<I', 3)], 'probe_segment_count'),
            ([(fixup + self.imports, '<I', 2)], 'probe_import'),
            ([(fixup + self.imports, '<I', 0xfffffe00)], 'probe_import'),
        ]:
            with self.subTest(expected=expected, changes=changes):
                self.reject(changes, expected)

    def test_segment_page_and_chain_rejections(self):
        info, node = self.info, self.node
        original_bind = struct.unpack_from('<Q', self.data, node)[0]
        original_rebase = struct.unpack_from('<Q', self.data, node + 8)[0]
        for changes, expected in [
            ([(info, '<I', 22)], 'probe_page_metadata'),
            ([(info + 4, '<H', 8192)], 'probe_page_metadata'),
            ([(info + 6, '<H', 1)], 'probe_page_metadata'),
            ([(info + 6, '<H', 6)], 'probe_page_metadata'),
            ([(info + 8, '<Q', 0)], 'probe_segment_mapping'),
            ([(info + 16, '<I', 1)], 'probe_page_metadata'),
            ([(info + 22, '<H', 0x8000)], 'probe_page_start'),
            ([(info + 22, '<H', 0x3ffc)], 'probe_chain_range'),
            ([(node, '<Q', (original_bind & ~0xffffff) | 2)], 'probe_bind'),
            ([(node, '<Q', original_bind | (1 << 32))], 'probe_bind'),
            ([(node + 8, '<Q', original_rebase | (1 << 44))], 'probe_rebase_reserved'),
            ([(node + 8, '<Q', original_rebase | (1 << 36))], 'probe_tagged_rebase_unreviewed'),
            ([(node + 8, '<Q', 0)], 'probe_rebase_target'),
        ]:
            with self.subTest(expected=expected, changes=changes):
                self.reject(changes, expected)

    def test_segment_file_vm_ranges_and_export_trie_rejections(self):
        data_segment = self.segments[2]
        self.reject([(data_segment + 24, '<Q', subject.BASE + 0x1000)],
                    'probe_segment_overlap')
        self.reject([(data_segment + 40, '<Q', 0x2000)], 'probe_segment_overlap')
        self.reject([(self.trie, '<B', 0xff)], 'probe_trie_terminal')
        self.reject([(self.trie + 2, '<B', 0)], 'probe_trie_edge')
        self.reject([(self.child_ref, '<B', 0)], 'probe_trie_graph')
        self.reject([(self.child_ref, '<B', 1)], 'probe_trie_node_overlap')
        self.reject([(self.child_ref, '<B', 255)], 'probe_trie_graph')
        self.reject([(self.leaf + 1, '<B', 8)], 'probe_trie_flags_unreviewed')

    def test_export_target_bounds(self):
        invalid = modern_fixture(export_address=0x90000000)
        with self.assertRaisesRegex(ipa_preflight.InspectionError, '^probe_export_target$'):
            subject.review(invalid)

    def test_pagezero_shape_is_explicit(self):
        zero = self.segments[0]
        for offset, fmt, value in ((zero + 24, '<Q', 1),
                                   (zero + 32, '<Q', subject.BASE - 1),
                                   (zero + 48, '<Q', 1),
                                   (zero + 56, '<I', 1)):
            with self.subTest(offset=offset):
                self.reject([(offset, fmt, value)], 'probe_pagezero_invariant')


if __name__ == '__main__':
    unittest.main()
