# Local native IPA preflight

Read-only research tooling, separate from the vault, social browser and Build 19 loader. It does not extract, patch, decrypt, sign, install, execute or upload a package. It does not create a manifest accepted by the loader.

Requires Python 3.11+; standard library only. Run locally, never with a real social IPA in public CI:

```powershell
python experiments/native-social-package-tools/ipa_preflight.py 'C:\path\candidate.ipa'
python -m unittest discover -s experiments/native-social-package-tools -p 'test_*.py'
```

Reports go to stdout only. Keep real packages and their reports private. The caller must choose where to save output, if anywhere; the tool never writes files. The IPA is opened read-only. `inspect_ipa(path)` is the importable interface; malformed/unsupported inputs raise `InspectionError` with a fixed code rather than raw exception contents. The CLI emits JSON and returns 2 for rejection. Exit 0 means only that the implemented metadata checks completed, with `status=review_required` and `installation_authorized=false` in every successful report.

## Checked scope

- Non-ZIP64 single-disk ZIP; central directory bounded before `ZipFile` parses it. Reject trailing data, duplicate/casefold/NFC-colliding paths, traversal, absolute/backslash/drive paths, file/directory prefix conflicts, symlinks/special entries and encrypted ZIP entries.
- Exactly one root `Payload/*.app`, no nested apps. Read bounded `Info.plist` metadata for discovered app, framework and extension bundles and require declared executables. Inspect these executables plus loose `.dylib` files.
- Thin little-endian Mach-O64 ARM64, and big-endian FAT32/FAT64 containers holding supported ARM64 slices. Check FAT slice bounds, nonoverlap, alignment and table/header identity, load-command bounds/counts, platform and encryption commands, dependency/rpath strings. The main must be an iOS executable. Nonzero cryptid is rejected, including in guest extensions; no decryption is attempted.
- Report SHA-256, selected bundle metadata, code inventory, load paths and review flags. `checks_completed` refers only to these checks, not completeness of metadata. Missing optional versions appear as `unspecified`. `other_file_count` counts non-directory members not classified as inspected code, including metadata/resources; it does not prove they are all nonexecutable. Dependencies outside `/usr/lib/` and public system frameworks are separately listed for layout review; all rpaths require review, with no automatic resolution. Certificate/key/provisioning-named files are listed but their member contents are never opened; whole-archive SHA-256 reads the archive as opaque bytes. A filename is not proof of private-key material or its purpose.

Limits: 2 GiB archive, 16 MiB central directory, 20,000 entries, 512 MiB per uncompressed entry, 4 GiB total declared uncompressed data, 1000:1 per-entry ratio, 1 MiB per plist, eight FAT slices, 8192 commands and 4 MiB load commands per slice, 1024 characters per reported metadata/path string. Unsupported input fails visibly rather than widening limits silently.

## Explicitly not verified

No signature validation, entitlement inspection, vendor provenance, dependency resolution, native loading, security certification or runtime feature checks. Executable files hidden in unrecognized resource locations are not exhaustively discovered. Most Mach-O section contents and command types are not semantically validated. No full archive CRC/integrity pass is performed for untouched resources. Unknown platforms in embedded libraries remain a review flag; unsupported declared platforms are rejected. This is not a safe-extraction library, a malware scanner, a decryption tool or installation approval.

Do not bypass rejection by silently deleting encrypted extensions or key-named resources. A future assembler needs an explicit reviewed inclusion/exclusion policy, its own path validation and immutable manifest enforcement. The owner's original must remain untouched. No additional app products or entitlements are authorized here.

Current observed package blockers and boundaries are in `docs/NATIVE_GUEST_PACKAGING.md`. Tests generate synthetic archives and Mach-O headers inside temporary directories; no real social binaries, certificates, profiles or credentials are fixtures.
