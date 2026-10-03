"""Synthetic-only behavioral tests for local device-candidate assembly.

Every Mach-O and archive fixture here is generated in memory or in a temporary
directory. These tests never open a publisher IPA or execute a guest module.
"""

from contextlib import contextmanager
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import struct
import tempfile
import unittest
import zipfile
from unittest.mock import patch


ASSEMBLER_PATH = Path(__file__).resolve().parents[1] / "assemble_device_candidate.py"
SPEC = importlib.util.spec_from_file_location("tkplus_device_candidate", ASSEMBLER_PATH)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


def _aligned(value, alignment=8):
    return (value + alignment - 1) & ~(alignment - 1)


def dylib_command(command, name=b"", *, name_offset=24, slot_size=None, terminate=True):
    """Build a load/id-dylib command, with knobs for malformed name fields."""
    name = name.encode("ascii") if isinstance(name, str) else name
    name_bytes = name + (b"\0" if terminate else b"")
    minimum_size = max(24, name_offset + len(name_bytes))
    size = _aligned(max(minimum_size, 24 + (slot_size or 0)))
    data = bytearray(size)
    struct.pack_into("<6I", data, 0, command, size, name_offset, 0, 0, 0)
    if name_offset < size:
        end = min(size, name_offset + len(name_bytes))
        data[name_offset:end] = name_bytes[: end - name_offset]
    return bytes(data)


def platform_command(platform=2, minimum=18 << 16, *, tools=0, declared_tools=None, size=None):
    count = tools if declared_tools is None else declared_tools
    command_size = 24 + tools * 8 if size is None else size
    data = bytearray(command_size)
    if command_size >= 24:
        struct.pack_into("<6I", data, 0, 0x32, command_size, platform, minimum, 18 << 16, count)
    return bytes(data)


def mach_o(commands, *, magic=0xFEEDFACF, cpu=0x0100000C, filetype=6,
           command_count=None, command_bytes=None, trailing=b""):
    body = b"".join(commands)
    header_count = len(commands) if command_count is None else command_count
    header_bytes = len(body) if command_bytes is None else command_bytes
    return struct.pack("<8I", magic, cpu, 0, filetype, header_count, header_bytes, 0, 0) + body + trailing


def valid_main():
    return mach_o([
        dylib_command(0xC, b"/usr/lib/libSystem.B.dylib"),
        dylib_command(0x80000018, candidate.OLD_LOAD),
        dylib_command(0xC, b"/System/Library/Frameworks/Foundation.framework/Foundation"),
    ], trailing=b"synthetic linkedit payload")


def valid_addon():
    return mach_o([
        dylib_command(0xD, candidate.NEW_LOAD),
        dylib_command(0x20, b"/System/Library/Frameworks/Foundation.framework/Foundation"),
        platform_command(),
    ])


def zip_info(name, *, mode=stat.S_IFREG | 0o644, flags=0, compression=zipfile.ZIP_STORED,
             file_size=1):
    entry = zipfile.ZipInfo(name)
    # ZipInfo normalizes backslashes on Windows; model raw central-directory
    # metadata so validate_entries receives the hostile spelling under test.
    entry.filename = name
    entry.external_attr = mode << 16
    entry.flag_bits = flags
    entry.compress_type = compression
    entry.file_size = file_size
    return entry


class InfoArchive:
    """Minimal archive view for metadata rejected before any member read."""

    def __init__(self, entries):
        self.entries = entries

    def infolist(self):
        return self.entries


@contextmanager
def expected_private_hashes(source, main, original_addon):
    source_sha = hashlib.sha256(Path(source).read_bytes()).hexdigest()
    with patch.object(candidate, "SOURCE_SHA256", source_sha), \
         patch.object(candidate, "MAIN_SHA256", hashlib.sha256(main).hexdigest()), \
         patch.object(candidate, "ORIGINAL_ADDON_SHA256", hashlib.sha256(original_addon).hexdigest()):
        yield


class MachOLoadCommandTests(unittest.TestCase):
    def test_redirect_changes_only_reserved_name_slot_and_preserves_command_layout(self):
        original = valid_main()
        before_commands = candidate.load_commands(original)

        redirected = candidate.redirect_weak_load(original)

        weak_index = next(i for i, item in enumerate(before_commands) if item[0] == 0x80000018)
        _, position, size = before_commands[weak_index]
        offset = struct.unpack_from("<I", original, position + 8)[0]
        start, end = position + offset, position + size
        self.assertEqual(redirected[start:end], candidate.NEW_LOAD + bytes(end - start - len(candidate.NEW_LOAD)))
        self.assertEqual(redirected[:start], original[:start])
        self.assertEqual(redirected[end:], original[end:])
        self.assertEqual(candidate.load_commands(redirected), before_commands)
        self.assertEqual(
            [command for command, _, _ in candidate.load_commands(redirected)],
            [command for command, _, _ in before_commands],
        )

    def test_redirect_rejects_missing_duplicate_nonweak_and_preexisting_independent_loads(self):
        prefix = dylib_command(0xC, b"/usr/lib/libSystem.B.dylib")
        suffix = dylib_command(0xC, b"/System/Library/Frameworks/Foundation.framework/Foundation")
        cases = {
            "missing": mach_o([prefix, suffix]),
            "duplicate": mach_o([dylib_command(0x80000018, candidate.OLD_LOAD),
                                  dylib_command(0x80000018, candidate.OLD_LOAD)]),
            "nonweak": mach_o([dylib_command(0xC, candidate.OLD_LOAD)]),
            "already linked": mach_o([dylib_command(0x80000018, candidate.OLD_LOAD),
                                       dylib_command(0xC, candidate.NEW_LOAD)]),
        }
        for label, data in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                candidate.redirect_weak_load(data)

    def test_load_commands_rejects_bad_header_and_command_regions(self):
        valid = valid_main()
        header_cases = {
            "truncated header": valid[:31],
            "wrong magic": mach_o([], magic=0xFEEDFACE),
            "wrong cpu": mach_o([], cpu=0x01000007),
            "wrong file type": mach_o([], filetype=2),
            "zero commands": mach_o([]),
            "too many commands": mach_o([dylib_command(0xC, b"x")], command_count=257),
            "empty region": mach_o([dylib_command(0xC, b"x")], command_bytes=0),
            "region exceeds file": mach_o([dylib_command(0xC, b"x")], command_bytes=65536),
            "region count mismatch": mach_o([dylib_command(0xC, b"x")], command_count=2),
            "truncated command": struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 6, 1, 8, 0, 0)
                                  + b"\x0c\x00\x00",
        }
        for label, data in header_cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                candidate.load_commands(data)

        base = bytearray(valid)
        _command, position, _size = candidate.load_commands(valid)[0]
        bad_size = bytearray(base)
        struct.pack_into("<I", bad_size, position + 4, 7)
        with self.subTest(label="unaligned undersized command"), self.assertRaises(ValueError):
            candidate.load_commands(bytes(bad_size))
        overrun = bytearray(base)
        struct.pack_into("<I", overrun, position + 4, len(valid))
        with self.subTest(label="command exceeds command region"), self.assertRaises(ValueError):
            candidate.load_commands(bytes(overrun))
        trailing_region = mach_o([dylib_command(0xC, b"x")], command_bytes=40)
        with self.subTest(label="command region has unconsumed bytes"), self.assertRaises(ValueError):
            candidate.load_commands(trailing_region)

    def test_dependency_rejects_bad_name_offsets_and_missing_terminator(self):
        invalid_offset = bytearray(dylib_command(0xC, b"x"))
        struct.pack_into("<I", invalid_offset, 8, 4096)
        unterminated = bytearray(dylib_command(0xC, b"x"))
        unterminated[24:] = b"A" * (len(unterminated) - 24)
        malformed = [
            dylib_command(0xC, b"x", name_offset=23),
            bytes(invalid_offset),
            bytes(unterminated),
        ]
        for command in malformed:
            with self.subTest(command=command[:16]), self.assertRaises(ValueError):
                candidate.dependency(command, 0, len(command))


class AddonValidationTests(unittest.TestCase):
    def test_accepts_only_synthetic_arm64_ios18_module_with_expected_identity_and_system_dependency(self):
        candidate.verify_addon(valid_addon())
        candidate.verify_addon(mach_o([
            dylib_command(0xD, candidate.NEW_LOAD),
            dylib_command(0xC, b"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"),
            platform_command(),
        ]))

    def test_rejects_bad_header_size_install_name_dependency_platform_and_encryption(self):
        valid = valid_addon()
        id_command = dylib_command(0xD, candidate.NEW_LOAD)
        foundation = dylib_command(0xC, b"/System/Library/Frameworks/Foundation.framework/Foundation")
        bad_cases = {
            "too short": b"short",
            "size over module limit": b"\0" * (8 * 1024**2 + 1),
            "wrong install name": mach_o([dylib_command(0xD, b"@rpath/Other.dylib"), foundation, platform_command()]),
            "duplicate identity": mach_o([id_command, id_command, foundation, platform_command()]),
            "missing identity": mach_o([foundation, platform_command()]),
            "unexpected dependency": mach_o([id_command, dylib_command(0xC, b"@rpath/Other.dylib"), platform_command()]),
            "unexpected lazy-load dependency": mach_o([id_command, foundation,
                                                        dylib_command(0x20, b"@rpath/Other.dylib"),
                                                        platform_command()]),
            "unknown required-bit dependency command": mach_o([id_command, foundation,
                                                                dylib_command(0x80000020, b"@rpath/Other.dylib"),
                                                                platform_command()]),
            "wrong device platform": mach_o([id_command, foundation, platform_command(platform=7)]),
            "wrong minimum iOS": mach_o([id_command, foundation, platform_command(minimum=17 << 16)]),
            "duplicate platform": mach_o([id_command, foundation, platform_command(), platform_command()]),
            "missing platform": mach_o([id_command, foundation]),
            "invalid platform tool count": mach_o([id_command, foundation, platform_command(tools=0, declared_tools=1)]),
            "encrypted module": mach_o([id_command, foundation, platform_command(),
                                         struct.pack("<6I", 0x21, 24, 0, 0, 1, 0)]),
            "malformed dependency offset": mach_o([dylib_command(0xD, candidate.NEW_LOAD, name_offset=16),
                                                   foundation, platform_command()]),
        }
        self.assertTrue(valid)
        for label, data in bad_cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                candidate.verify_addon(data)


class ArchiveValidationTests(unittest.TestCase):
    def test_accepts_ordinary_files_and_directories_under_the_exact_app_root(self):
        entries = [
            zip_info(candidate.ROOT, mode=stat.S_IFDIR | 0o755, file_size=0),
            zip_info(candidate.MAIN),
        ]
        self.assertEqual(candidate.validate_entries(InfoArchive(entries)), entries)

    def test_rejects_path_escape_wrong_root_backslash_and_case_collisions(self):
        cases = {
            "outside app root": [zip_info("Payload/Other.app/file")],
            "prefix lookalike": [zip_info("Payload/LiveContainer.app-evil/file")],
            "parent segment": [zip_info(candidate.ROOT + "../Other/file")],
            "dot segment": [zip_info(candidate.ROOT + "./file")],
            "backslash": [zip_info(candidate.ROOT + "Frameworks\\bad")],
            "absolute path": [zip_info("/" + candidate.ROOT + "file")],
            "case collision": [zip_info(candidate.ROOT + "Frameworks/A"),
                               zip_info(candidate.ROOT + "frameworks/a")],
            "duplicate exact path": [zip_info(candidate.ROOT + "file"),
                                      zip_info(candidate.ROOT + "file")],
        }
        for label, entries in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                candidate.validate_entries(InfoArchive(entries))

    def test_rejects_nonordinary_encrypted_unsupported_compression_and_size_limit(self):
        cases = {
            "symbolic link": [zip_info(candidate.ROOT + "link", mode=stat.S_IFLNK | 0o777)],
            "device node": [zip_info(candidate.ROOT + "device", mode=stat.S_IFCHR | 0o600)],
            "encrypted": [zip_info(candidate.ROOT + "encrypted", flags=1)],
            "unsupported compression": [zip_info(candidate.ROOT + "compressed", compression=99)],
            "expansion limit": [zip_info(candidate.ROOT + "large", file_size=candidate.MAX_TOTAL + 1)],
            "entry count limit": [zip_info(candidate.ROOT + f"{index}")
                                  for index in range(5001)],
        }
        for label, entries in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                candidate.validate_entries(InfoArchive(entries))


class FullAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tkplus-device-candidate-")
        self.root = Path(self.directory.name)
        self.source = self.root / "synthetic-source.ipa"
        self.addon = self.root / "synthetic-addon.dylib"
        self.output = self.root / "synthetic-candidate.ipa"
        self.main = valid_main()
        self.original_addon = b"synthetic original add-on fixture"
        self.module = valid_addon()
        self.addon.write_bytes(self.module)
        self._write_source()

    def tearDown(self):
        self.directory.cleanup()

    def _write_source(self, extra_entries=()):
        with zipfile.ZipFile(self.source, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr(candidate.MAIN, self.main)
            archive.writestr(candidate.ORIGINAL_ADDON, self.original_addon)
            archive.writestr(candidate.ORIGINAL_RESOURCES + "Info.plist", b"synthetic resources")
            archive.writestr(candidate.ORIGINAL_SUBSTRATE + "marker", b"synthetic nested dependency")
            archive.writestr(candidate.ROOT + "Info.plist", b"synthetic app metadata")
            archive.writestr(candidate.ROOT + "Frameworks/Keep.framework/marker", b"keep this member")
            archive.writestr(candidate.ROOT + "Frameworks/CydiaSubstrate.framework/host-marker",
                             b"preserve host framework")
            for name, data in extra_entries:
                archive.writestr(name, data)

    def _assemble(self, *, output=None, digest=None):
        output = self.output if output is None else output
        digest = hashlib.sha256(self.module).hexdigest() if digest is None else digest
        with expected_private_hashes(self.source, self.main, self.original_addon):
            return candidate.assemble(self.source, self.addon, output, digest)

    def test_assembles_fully_synthetic_candidate_and_verifies_all_preserved_members(self):
        self.assertEqual(candidate.NEW_ADDON, candidate.GUEST + "Frameworks/TKP.dylib")
        self.assertEqual(candidate.NEW_LOAD, b"@rpath/TKP.dylib")
        report = self._assemble()

        self.assertTrue(self.output.is_file())
        self.assertEqual(report["candidate"], "TKPlusIndependent-profile-settings-test2")
        self.assertEqual(report["settings_entry"], "bottom Profile tab long press, then gear")
        self.assertEqual(report["device_install_test"], "NOT RUN")
        self.assertTrue(report["all_other_members_preserved"])
        self.assertEqual(report["omitted_addon_files"], 3)
        self.assertEqual(report["output_files"], 6)
        with zipfile.ZipFile(self.output) as assembled:
            names = set(assembled.namelist())
            self.assertEqual(len(names), 6)
            self.assertNotIn(candidate.ORIGINAL_ADDON, names)
            self.assertNotIn(candidate.ORIGINAL_RESOURCES + "Info.plist", names)
            self.assertNotIn(candidate.ORIGINAL_SUBSTRATE + "marker", names)
            self.assertIn(candidate.NEW_ADDON, names)
            self.assertNotIn(candidate.ROOT + "Frameworks/TKP.dylib", names)
            self.assertIn(candidate.RECEIPT, names)
            self.assertFalse(any("TTKPlus" in name for name in names))
            self.assertEqual(assembled.read(candidate.MAIN), candidate.redirect_weak_load(self.main))
            self.assertEqual(assembled.read(candidate.NEW_ADDON), self.module)
            self.assertEqual(assembled.read(candidate.ROOT + "Info.plist"), b"synthetic app metadata")
            self.assertEqual(assembled.read(candidate.ROOT + "Frameworks/Keep.framework/marker"),
                             b"keep this member")
            self.assertEqual(assembled.read(candidate.ROOT + "Frameworks/CydiaSubstrate.framework/host-marker"),
                             b"preserve host framework")
            receipt = json.loads(assembled.read(candidate.RECEIPT))
            self.assertFalse(receipt["downloads_connected"])
            self.assertFalse(receipt["provider_anonymity_verified"])
            self.assertTrue(receipt["original_addon_excluded_whole"])
        self.assertEqual(report["output_sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertFalse(list(self.root.glob(".tkp-candidate-*.ipa")))

    def test_rejects_source_and_module_digest_mismatches_without_creating_output(self):
        bad_output = self.root / "bad-digest.ipa"
        with patch.object(candidate, "SOURCE_SHA256", "0" * 64), \
             patch.object(candidate, "MAIN_SHA256", hashlib.sha256(self.main).hexdigest()), \
             patch.object(candidate, "ORIGINAL_ADDON_SHA256", hashlib.sha256(self.original_addon).hexdigest()):
            with self.assertRaisesRegex(ValueError, "private input digest mismatch"):
                candidate.assemble(self.source, self.addon, bad_output, hashlib.sha256(self.module).hexdigest())
        self.assertFalse(bad_output.exists())

        with expected_private_hashes(self.source, self.main, self.original_addon):
            with self.assertRaisesRegex(ValueError, "independent module digest mismatch"):
                candidate.assemble(self.source, self.addon, bad_output, "0" * 64)
        self.assertFalse(bad_output.exists())
        self.assertFalse(list(self.root.glob(".tkp-candidate-*.ipa")))

    def test_never_overwrites_existing_output(self):
        self.output.write_bytes(b"preserve existing output")
        with expected_private_hashes(self.source, self.main, self.original_addon):
            with self.assertRaisesRegex(ValueError, "output already exists"):
                candidate.assemble(self.source, self.addon, self.output, hashlib.sha256(self.module).hexdigest())
        self.assertEqual(self.output.read_bytes(), b"preserve existing output")

    def test_rejects_signed_source_and_leaves_no_candidate_file(self):
        self._write_source([(candidate.ROOT + "_CodeSignature/CodeResources", b"synthetic signature")])
        bad_output = self.root / "signed.ipa"
        with expected_private_hashes(self.source, self.main, self.original_addon):
            with self.assertRaisesRegex(ValueError, "unexpected signed private input"):
                candidate.assemble(self.source, self.addon, bad_output, hashlib.sha256(self.module).hexdigest())
        self.assertFalse(bad_output.exists())
        self.assertFalse(list(self.root.glob(".tkp-candidate-*.ipa")))


if __name__ == "__main__":
    unittest.main()
