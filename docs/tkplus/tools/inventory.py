"""Read-only, bounded static feature metadata; does not execute guest code."""
import argparse
import bisect
import collections
import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path

def require(condition):
    if not condition:
        raise ValueError('Static inventory rejected unsupported or corrupt input')

parser = argparse.ArgumentParser(description='Read-only static TTKillerPlus 2.2 metadata inventory; prints JSON only.')
parser.add_argument('ipa', type=Path, help='Unchanged publisher package with the pinned digest')
parser.add_argument('--part', choices=('all', 'header', 'component'), default='all')
parser.add_argument('--owner', help='Exact component name when selecting component output')
parser.add_argument('--dylib', type=Path, help='Optional unchanged extracted dylib for LLVM registration cross-check')
parser.add_argument('--llvm', default='llvm-objdump', help='Path to LLVM objdump')
args = parser.parse_args()
IPA = args.ipa
with IPA.open('rb') as stream:
    require(hashlib.file_digest(stream, 'sha256').hexdigest() == '8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198')
with zipfile.ZipFile(IPA) as archive:
    members = [m for m in archive.infolist() if m.filename.endswith('/TTKPlus.dylib')]
    require(len(members) == 1 and members[0].file_size <= 2 * 1024 * 1024)
    data = archive.read(members[0])

def u32(offset):
    require(0 <= offset <= len(data)-4)
    return struct.unpack_from('<I', data, offset)[0]

def i32(offset):
    require(0 <= offset <= len(data)-4)
    return struct.unpack_from('<i', data, offset)[0]

def raw64(offset):
    require(0 <= offset <= len(data)-8)
    return struct.unpack_from('<Q', data, offset)[0]

require(u32(0) == 0xfeedfacf)
offset = 32
sections = {}
segments = []
for _ in range(u32(16)):
    command, length = struct.unpack_from('<II', data, offset)
    require(length >= 8 and offset+length <= len(data))
    if command == 0x19:
        vm, size, file_offset, file_size = struct.unpack_from('<QQQQ', data, offset+24)
        segments.append((vm, size, file_offset, file_size))
        for index in range(u32(offset+64)):
            entry = offset+72+80*index
            name = data[entry:entry+16].split(b'\0')[0].decode('ascii')
            address, size, file_offset = struct.unpack_from('<QQI', data, entry+32)
            sections[name] = (address, size, file_offset)
    offset += length

def at(address):
    for vm, size, file_offset, file_size in segments:
        if vm <= address < vm+file_size:
            return address-vm+file_offset
    raise ValueError('non-file-backed address')

def pointer(address):
    value = raw64(at(address))
    if value == 0:
        return 0
    # This input's chained pointer words: low36-bit local target; binds aren't
    # followed. No runtime/PAC assumptions and no pointer modification.
    require(not value >> 63)
    return value & ((1 << 36)-1)

def string(address):
    start = at(address)
    end = data.find(b'\0', start, min(len(data), start+512))
    require(end >= start)
    return data[start:end].decode('utf-8')

methods = []
def method_list(owner, kind, address):
    if not address:
        return
    file_offset = at(address)
    flags, count = struct.unpack_from('<II', data, file_offset)
    require(count <= 4096)
    stride = flags & 0xffff
    for index in range(count):
        entry = address+8+index*stride
        if flags & 0x80000000:
            require(stride == 12)
            reference = entry+i32(at(entry))
            name = string(reference if flags & 0x40000000 else pointer(reference))
            types = string(entry+4+i32(at(entry+4)))
            implementation = entry+8+i32(at(entry+8))
        else:
            require(stride >= 24)
            name = string(pointer(entry))
            types = string(pointer(entry+8))
            implementation = pointer(entry+16)
        methods.append({'owner':owner, 'kind':kind, 'selector':name, 'types':types, 'imp':hex(implementation)})

base, size, _ = sections['__objc_classlist']
for slot in range(base, base+size, 8):
    cls = pointer(slot)
    ro = pointer(cls+32) & ~7
    owner = string(pointer(ro+24))
    method_list(owner, '-', pointer(ro+32))
    meta = pointer(cls)
    meta_ro = pointer(meta+32) & ~7
    method_list(owner, '+', pointer(meta_ro+32))

for section in ('__objc_catlist',):
    if section not in sections:
        continue
    base, size, _ = sections[section]
    for slot in range(base, base+size, 8):
        cat = pointer(slot)
        owner = 'category:' + string(pointer(cat))
        method_list(owner, '-', pointer(cat+16))
        method_list(owner, '+', pointer(cat+24))


# Selector-stub decoding and function boundaries are specific to this ARM64 input.
def signed(value, bits):
    return value-(1 << bits) if value & (1 << (bits-1)) else value

stub_base, stub_size, _ = sections['__objc_stubs']
stubs = {}
require(stub_size % 32 == 0)
for address in range(stub_base, stub_base+stub_size, 32):
    word = u32(at(address))
    require(word & 0x9f00001f == 0x90000001)
    page = (address & ~4095) + (signed(((word >> 5 & 0x7ffff) << 2) | (word >> 29 & 3),21) << 12)
    load = u32(at(address+4))
    require(load & 0xffc003ff == 0xf9400021)
    stubs[address] = string(pointer(page+(load >> 10 & 0xfff)*8))

offset = 32
starts = []
libraries = []
for _ in range(u32(16)):
    command, length = u32(offset), u32(offset+4)
    if command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
        begin = offset+u32(offset+8)
        end = data.index(b'\0', begin, offset+length)
        libraries.append(data[begin:end].decode('utf-8'))
    if command == 0x26:
        position, size = u32(offset+8), u32(offset+12)
        end = position+size
        current = 0
        while position < end:
            delta = shift = 0
            while True:
                require(position < end)
                value = data[position]; position += 1
                delta |= (value & 127) << shift
                shift += 7
                require(shift <= 63)
                if not value & 128: break
            if not delta: break
            current += delta
            starts.append(current)
    offset += length
require(starts == sorted(set(starts)) and starts)
text_base, text_size, _ = sections['__text']
require(all(text_base <= x < text_base+text_size for x in starts))
require(all(int(m['imp'],16) in starts for m in methods))
calls = collections.defaultdict(collections.Counter)
direct_calls = 0
for address in range(text_base, text_base+text_size, 4):
    word = u32(at(address))
    if word & 0xfc000000 not in (0x94000000, 0x14000000): continue
    target = address+(signed(word & 0x3ffffff,26) << 2)
    selector = stubs.get(target)
    if selector is None: continue
    idx = bisect.bisect_right(starts,address)-1
    require(idx >= 0)
    calls[starts[idx]][selector] += 1
    direct_calls += 1

components = []
for owner in sorted(set(m['owner'] for m in methods)):
    rows = []
    for m in methods:
        if m['owner'] != owner: continue
        begin = int(m['imp'],16)
        idx = bisect.bisect_left(starts,begin)
        end = starts[idx+1] if idx+1 < len(starts) else text_base+text_size
        rows.append({
            'kind':m['kind'], 'selector':m['selector'], 'types':m['types'],
            'functionBytes':end-begin,
            'directSelectorCalls':dict(sorted(calls[begin].items())),
        })
    components.append({'owner':owner, 'declaredMethodCount':len(rows), 'methods':rows})
preferences = sorted(set(x.decode('ascii') for x in re.findall(rb'TTKPlus_[A-Za-z0-9_]+',data)))
inventory = {
    'schemaVersion':1,
    'target':{'member':members[0].filename, 'dylibBytes':len(data),
              'dylibSHA256':hashlib.sha256(data).hexdigest(),
              'ipaSHA256':'8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198'},
    'limitations':[
        'Static metadata and direct branch-to-selector stub calls only; no target execution.',
        'Method direct calls exclude nested blocks/helpers, indirect dispatch, C imports and superclass calls.',
        'Function starts are compiler boundaries, not recovered source functions or semantic coverage.',
        'Selector presence does not establish a feature or caller receiver type.',
        'No endpoints, credential values, keys, local auth state or resource payloads are exported.',
    ],
    'counts':{'classes':sections['__objc_classlist'][1]//8,
              'categories':sections.get('__objc_catlist',(0,0,0))[1]//8,
              'declaredMethods':len(methods), 'selectorStubs':len(stubs),
              'functionStarts':len(starts), 'directSelectorCallSites':direct_calls,
              'functionsWithDirectSelectorCalls':len(calls)},
    'linkedLibraries':libraries,
    'preferenceNames':preferences,
    'components':components,
    'selectorStubNames':list(stubs.values()),
}
require(inventory['counts']['classes'] == 18)
require(len(methods) == 578 and len(stubs) == 978 and len(starts) == 1732)
# Optional independent disassembler check. The binary is read, never loaded.
registration_candidates = []
if args.dylib:
    import subprocess
    with args.dylib.open('rb') as stream:
        require(hashlib.file_digest(stream,'sha256').hexdigest() == inventory['target']['dylibSHA256'])
    result = subprocess.run([args.llvm, '--macho', '--disassemble',
                             '--no-show-raw-insn', str(args.dylib)],
                            capture_output=True,text=True,check=True,timeout=60)
    require(len(result.stdout) < 12 * 1024 * 1024)
    disassembly = result.stdout
    registers = {}
    records = []
    for line in disassembly.splitlines():
        parsed = re.match(r'\s*([0-9a-f]+):\s+(\w+)\s+(.*)',line)
        if not parsed: continue
        address = int(parsed[1],16)
        operation, operands = parsed[2], parsed[3]
        # Feature registration only; omit authentication method bodies.
        if not (0x4400 <= address < 0x585c or 0x12000 <= address < 0x14e00): continue
        if operation == 'adrp':
            match = re.match(r'(x\d+),.*; (0x[0-9a-f]+)',operands)
            if match: registers[match[1]] = int(match[2],16)
        elif operation == 'add':
            match = re.match(r'(x\d+), (x\d+), #(0x[0-9a-f]+|\d+)',operands)
            if match:
                value = registers.get(match[2])
                registers[match[1]] = value+int(match[3],0) if isinstance(value,int) else None
        elif operation == 'ldr':
            match = re.match(r'(x\d+), \[(x\d+)(?:, #(0x[0-9a-f]+|\d+))?\]',operands)
            if match:
                value = registers.get(match[2])
                try: value = pointer(value+int(match[3] or '0',0)) if isinstance(value,int) else None
                except (AssertionError,ValueError): value = None
                registers[match[1]] = value
        elif operation == 'mov':
            match = re.match(r'(x\d+), (x\d+)',operands)
            if match: registers[match[1]] = registers.get(match[2])
        elif operation == 'bl':
            if 'symbol stub for: _objc_getClass' in operands:
                value = registers.get('x0')
                try: owner = string(value) if isinstance(value,int) else None
                except (AssertionError,ValueError,UnicodeError): owner = None
                registers['x0'] = 'class:'+owner if owner else None
                for i in range(1,19): registers['x'+str(i)] = None
            elif 'symbol stub for: _object_getClass' in operands:
                value = registers.get('x0')
                registers['x0'] = 'metaclass:'+value if isinstance(value,str) else None
                for i in range(1,19): registers['x'+str(i)] = None
            elif 'symbol stub for: _MSHookMessageEx' in operands or 'symbol stub for: _class_addMethod' in operands:
                value = registers.get('x1')
                try: selector = string(value) if isinstance(value,int) else None
                except (AssertionError,ValueError,UnicodeError): selector = None
                replacement = registers.get('x2')
                records.append({'site':hex(address),'operation':'add' if '_class_addMethod' in operands else 'hook','owner':registers.get('x0'),'selector':selector,'replacement':hex(replacement) if isinstance(replacement,int) else None})
                for i in range(19): registers['x'+str(i)] = None
            else:
                for i in range(19): registers['x'+str(i)] = None
        elif operation in ('ret','br'):
            registers.clear()

    registration_candidates = [
        {'operation':x['operation'],
         'owner':x['owner'] if isinstance(x['owner'],str) else None,
         'selector':x['selector']} for x in records]
    llvm_counts = collections.Counter(
        line.split('symbol stub for: ')[1].split()[0]
        for line in disassembly.splitlines()
        if 'symbol stub for: _MSHook' in line or 'symbol stub for: _class_addMethod' in line)
    require(len(records) == llvm_counts['_MSHookMessageEx']+llvm_counts['_class_addMethod'])
    inventory['counts']['methodRegistrationSites'] = len(records)
    inventory['counts']['hookFunctionCallSites'] = llvm_counts['_MSHookFunction']
    inventory['methodRegistrationCandidates'] = registration_candidates
    inventory['limitations'].append(
        'Registration candidates follow bounded straight-line register values in two startup regions; not a CFG/receiver/ABI proof.')
if args.part == 'header':
    inventory = {k:v for k,v in inventory.items() if k != 'components'}
elif args.part == 'component':
    inventory = next(c for c in components if c['owner'] == args.owner)
print(json.dumps(inventory,indent=2,ensure_ascii=True))
