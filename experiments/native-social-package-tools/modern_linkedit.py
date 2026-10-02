"""Bounded structural review for the pinned modern chained-fixup/export subset.

This module never executes or resolves guest code. It accepts only format-2
chained pointers, import format 1 and a small regular-export trie subset.
"""

from dataclasses import dataclass
import hashlib
import io
import struct

import ipa_preflight as preflight


FIXUPS = 0x80000034
EXPORTS = 0x80000033
MODERN_COMMANDS = {FIXUPS, EXPORTS}
MAX_MAIN = 32 * 1024**2
BASE = 0x100000000
PAGE = 0x4000
COMMAND_PADDING = 40
MAX_LINKEDIT_PAYLOAD = 1024 * 1024
MAX_SEGMENTS = 32
MAX_IMPORTS = 65536
MAX_PAGES_PER_SEGMENT = 8192
MAX_CHAIN_NODES = 65536
MAX_TRIE_NODES = 4096
MAX_TRIE_DEPTH = 64
MAX_TRIE_EDGE_BYTES = 1024


@dataclass(frozen=True)
class Review:
    summary: dict
    non_pagezero_geometry: tuple
    payload_ranges: tuple
    payload_digests: tuple


def need(condition, code):
    preflight.require(condition, code)


def _uleb(data, position, stop, code_prefix='probe_trie'):
    value = 0
    for shift in range(0, 64, 7):
        need(position < stop, f'{code_prefix}_uleb')
        byte = data[position]
        position += 1
        need(shift != 63 or byte <= 1, f'{code_prefix}_overflow')
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, position
    raise preflight.InspectionError(f'{code_prefix}_overflow')


def _review(data, *, hosted, base, page, command_padding, maximum_size):
    need(isinstance(data, bytes) and 32 <= len(data) <= maximum_size, 'probe_size')
    preflight.macho_slice(io.BytesIO(data), 0, len(data), len(data))
    magic, cpu, subtype, filetype, count, command_bytes, _flags, reserved = struct.unpack_from(
        '<8I', data)
    need(magic == 0xfeedfacf and cpu == 0x100000c and subtype == 0 and reserved == 0 and
         filetype in (2, 6), 'probe_header')
    command_end = 32 + command_bytes
    need(command_end <= len(data), 'probe_commands')

    commands = {}
    segments = []
    dependencies = 0
    pagezero_shapes = []
    position = 32
    for _ in range(count):
        need(position + 8 <= command_end, 'probe_commands')
        command, size = struct.unpack_from('<2I', data, position)
        need(size >= 8 and size % 8 == 0 and position + size <= command_end,
             'probe_commands')
        if command == 0x19:
            need(size >= 72, 'probe_segment')
            name = data[position + 8:position + 24].split(b'\0', 1)[0]
            vm, span, offset, amount = struct.unpack_from('<4Q', data, position + 24)
            max_protection, protection, section_count, _segment_flags = struct.unpack_from(
                '<4I', data, position + 56)
            need(size == 72 + section_count * 80 and
                 vm <= 0xffffffffffffffff - span and
                 offset <= len(data) and amount <= len(data) - offset and amount <= span,
                 'probe_segment_range')
            segment_command = data[position:position + size]
            segments.append({'name': name, 'vm': vm, 'span': span, 'offset': offset,
                             'amount': amount, 'max_protection': max_protection,
                             'protection': protection, 'sections': section_count,
                             'raw': segment_command})
            if name == b'__PAGEZERO':
                pagezero_shapes.append(struct.unpack_from('<4Q4I', data, position + 24))
        elif command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
            dependencies += 1
        if command in MODERN_COMMANDS:
            need(command not in commands and size == 16, 'probe_modern_command')
            offset, amount = struct.unpack_from('<2I', data, position + 8)
            need(offset >= command_end + command_padding and offset <= len(data) and
                 0 < amount <= len(data) - offset and amount <= MAX_LINKEDIT_PAYLOAD,
                 'probe_modern_range')
            commands[command] = (offset, amount)
        position += size
    need(position == command_end and set(commands) == MODERN_COMMANDS, 'probe_modern_pair')

    need(0 < len(segments) <= MAX_SEGMENTS, 'probe_segment_count')
    text_segments = [segment for segment in segments if segment['name'] == b'__TEXT']
    linkedit_segments = [segment for segment in segments if segment['name'] == b'__LINKEDIT']
    pagezero = [segment for segment in segments if segment['name'] == b'__PAGEZERO']
    need(len(text_segments) == len(linkedit_segments) == len(pagezero) == 1,
         'probe_segment_layout')
    text = text_segments[0]
    linkedit = linkedit_segments[0]
    expected_zero = (base - page, page, 0, 0, 0, 0, 0, 0) if hosted else \
        (0, base, 0, 0, 0, 0, 0, 0)
    need(filetype == (6 if hosted else 2) and len(pagezero_shapes) == 1 and
         pagezero_shapes[0] == expected_zero and
         pagezero[0]['vm'] + pagezero[0]['span'] == base and
         text['vm'] == base and text['offset'] == 0 and
         text['amount'] >= command_end + command_padding,
         'probe_pagezero_invariant')

    # Reject ambiguous segment mappings and overlapping file/VM ranges before
    # interpreting any chained pointers.
    for index, segment in enumerate(segments):
        need(all(segment['name'] != prior['name'] for prior in segments[:index]),
             'probe_segment_overlap')
        for prior in segments[:index]:
            if segment['span'] and prior['span']:
                need(segment['vm'] + segment['span'] <= prior['vm'] or
                     segment['vm'] >= prior['vm'] + prior['span'], 'probe_segment_overlap')
            if segment['amount'] and prior['amount']:
                need(segment['offset'] + segment['amount'] <= prior['offset'] or
                     segment['offset'] >= prior['offset'] + prior['amount'],
                     'probe_segment_overlap')

    modern_ranges = []
    payload_digests = []
    for command, (offset, amount) in commands.items():
        need(linkedit['offset'] <= offset and offset + amount <= linkedit['offset'] + linkedit['amount'],
             'probe_not_linkedit')
        modern_ranges.append((offset, offset + amount))
        payload_digests.append((command, offset, amount, hashlib.sha256(data[offset:offset + amount]).hexdigest()))
    first, second = (commands[FIXUPS], commands[EXPORTS])
    need(first[0] + first[1] <= second[0] or second[0] + second[1] <= first[0],
         'probe_payload_overlap')

    payload = data[first[0]:first[0] + first[1]]
    need(len(payload) >= 28, 'probe_fixup_header')
    version, starts, imports, symbols, import_count, import_format, symbol_format = struct.unpack_from(
        '<7I', payload)
    need(version == 0 and import_format == 1 and symbol_format == 0, 'probe_fixup_format')
    need(28 <= starts < imports <= symbols <= len(payload) and
         starts % 4 == imports % 4 == 0 and import_count <= MAX_IMPORTS and
         import_count * 4 <= symbols - imports, 'probe_fixup_offsets')
    need(starts + 4 <= imports, 'probe_start_table')
    segment_count = struct.unpack_from('<I', payload, starts)[0]
    need(segment_count == len(segments) and segment_count <= MAX_SEGMENTS and
         starts + 4 + 4 * segment_count <= imports, 'probe_segment_count')

    for index in range(import_count):
        value = struct.unpack_from('<I', payload, imports + index * 4)[0]
        raw_ordinal = value & 0xff
        ordinal = raw_ordinal - 256 if raw_ordinal & 0x80 else raw_ordinal
        name_offset = symbols + (value >> 9)
        need(-3 <= ordinal <= dependencies and symbols <= name_offset < len(payload),
             'probe_import')
        name_end = payload.find(b'\0', name_offset,
                                min(name_offset + MAX_TRIE_EDGE_BYTES, len(payload)))
        need(name_end > name_offset, 'probe_import_name')

    seen_chain_nodes = set()
    info_ranges = []
    pointer_formats = set()
    bind_count = 0
    rebase_count = 0
    total_pages = 0
    for index, segment in enumerate(segments):
        info_relative = struct.unpack_from('<I', payload, starts + 4 + index * 4)[0]
        if info_relative == 0:
            continue
        info = starts + info_relative
        need(info >= starts + 4 + 4 * segment_count and info + 22 <= imports,
             'probe_segment_info')
        info_size, page_size, pointer_format, segment_offset, max_pointer, page_count = \
            struct.unpack_from('<IHHQIH', payload, info)
        need(info_size == 22 + page_count * 2 and info + info_size <= imports and
             page_size in (4096, 16384) and pointer_format == 2 and max_pointer == 0 and
             page_count <= MAX_PAGES_PER_SEGMENT, 'probe_page_metadata')
        need(all(info + info_size <= low or info >= high for low, high in info_ranges),
             'probe_info_overlap')
        info_ranges.append((info, info + info_size))
        need(segment['name'] not in (b'__PAGEZERO', b'__LINKEDIT') and
             segment_offset == segment['vm'] - base and
             page_count == (segment['span'] + page_size - 1) // page_size,
             'probe_segment_mapping')
        pointer_formats.add(pointer_format)
        total_pages += page_count
        for page_index in range(page_count):
            start = struct.unpack_from('<H', payload, info + 22 + page_index * 2)[0]
            if start == 0xffff:
                continue
            need(start < page_size and not start & 0x8000 and start % 4 == 0,
                 'probe_page_start')
            cursor = page_index * page_size + start
            page_end = min((page_index + 1) * page_size, segment['amount'])
            while True:
                location = segment['offset'] + cursor
                need(cursor + 8 <= page_end and location not in seen_chain_nodes and
                     len(seen_chain_nodes) < MAX_CHAIN_NODES,
                     'probe_chain_range')
                seen_chain_nodes.add(location)
                value = struct.unpack_from('<Q', data, location)[0]
                next_step = (value >> 51) & 0xfff
                if value >> 63:
                    need((value & 0xffffff) < import_count and
                         ((value >> 32) & 0x7ffff) == 0, 'probe_bind')
                    bind_count += 1
                else:
                    need(((value >> 44) & 0x7f) == 0, 'probe_rebase_reserved')
                    low_target = value & ((1 << 36) - 1)
                    high8 = (value >> 36) & 0xff
                    need(high8 == 0, 'probe_tagged_rebase_unreviewed')
                    need(any(candidate['name'] != b'__PAGEZERO' and
                             candidate['vm'] <= low_target < candidate['vm'] + candidate['span']
                             for candidate in segments), 'probe_rebase_target')
                    rebase_count += 1
                if next_step == 0:
                    break
                cursor += next_step * 4

    trie_offset, trie_size = commands[EXPORTS]
    trie = data[trie_offset:trie_offset + trie_size]
    trie_nodes = set()
    node_ranges = []
    export_count = 0
    stack = [(0, frozenset(), 0)]
    while stack:
        node_offset, ancestors, depth = stack.pop()
        need(node_offset < len(trie) and node_offset not in ancestors and
             depth <= MAX_TRIE_DEPTH and len(trie_nodes) < MAX_TRIE_NODES,
             'probe_trie_graph')
        need(node_offset not in trie_nodes, 'probe_trie_shared_node_unreviewed')
        need(all(not low <= node_offset < high for low, high in node_ranges),
             'probe_trie_node_overlap')
        trie_nodes.add(node_offset)
        terminal_size, terminal = _uleb(trie, node_offset, len(trie))
        terminal_end = terminal + terminal_size
        need(terminal_end < len(trie), 'probe_trie_terminal')
        if terminal_size:
            export_flags, field_position = _uleb(trie, terminal, terminal_end)
            need(export_flags in (0, 4), 'probe_trie_flags_unreviewed')
            address, field_position = _uleb(trie, field_position, terminal_end)
            need(field_position == terminal_end and any(
                candidate['name'] != b'__PAGEZERO' and
                candidate['vm'] <= base + address < candidate['vm'] + candidate['span']
                for candidate in segments), 'probe_export_target')
            export_count += 1
        child_count = trie[terminal_end]
        child_position = terminal_end + 1
        for _ in range(child_count):
            edge_end = trie.find(b'\0', child_position,
                                 min(len(trie), child_position + MAX_TRIE_EDGE_BYTES))
            need(edge_end > child_position, 'probe_trie_edge')
            child_offset, child_position = _uleb(trie, edge_end + 1, len(trie))
            stack.append((child_offset, ancestors | {node_offset}, depth + 1))
            need(len(stack) <= MAX_TRIE_NODES, 'probe_trie_graph')
        need(all(child_position <= low or node_offset >= high for low, high in node_ranges),
             'probe_trie_node_overlap')
        node_ranges.append((node_offset, child_position))

    summary = {'status': 'modern_linkedit_subset_reviewed', 'segment_count': segment_count,
               'imports': import_count, 'pointer_formats': sorted(pointer_formats),
               'pages': total_pages, 'bind_nodes': bind_count, 'rebase_nodes': rebase_count,
               'export_nodes': len(trie_nodes), 'exports': export_count}
    non_pagezero_geometry = tuple(segment['raw'] for segment in segments
                                  if segment['name'] != b'__PAGEZERO')
    return Review(summary, non_pagezero_geometry,
                  tuple((command, offset, amount) for command, (offset, amount) in sorted(commands.items())),
                  tuple(sorted(payload_digests)))


def review(data, *, hosted=False, base=BASE, page=PAGE,
           command_padding=COMMAND_PADDING, maximum_size=MAX_MAIN):
    """Review a source or hosted executable; all failures use fixed error codes."""
    try:
        need(type(hosted) is bool and type(base) is int and type(page) is int and
             type(command_padding) is int and type(maximum_size) is int and
             base > 0 and page > 0 and command_padding >= 0 and maximum_size >= 32,
             'probe_input')
        return _review(data, hosted=hosted, base=base, page=page,
                       command_padding=command_padding, maximum_size=maximum_size)
    except preflight.InspectionError:
        raise
    except Exception:
        raise preflight.InspectionError('invalid_modern_linkedit') from None
