# Local native package research tools

Research tooling, separate from the vault and social browser. The preflight and planner are read-only; the adapter, writer and host merger create new private outputs only. None decrypts, signs, installs, executes or uploads a package. Only the host merger creates the fixed Build 20 selection descriptor; this descriptor is not a signature, trust verdict or installation approval.

Requires Python 3.11+; standard library only. Run locally, never with a real social IPA in public CI:

```powershell
python experiments/native-social-package-tools/ipa_preflight.py 'C:\path\candidate.ipa'
python experiments/native-social-package-tools/ipa_preflight.py 'C:\path\candidate.ipa' --profile extended-review
python -m unittest discover -s experiments/native-social-package-tools -p 'test_*.py'
```

Preflight reports go to stdout only. Keep real packages and their reports private. The preflight never writes files; the IPA is opened read-only. `inspect_ipa(path, profile='strict')` is the importable interface; malformed/unsupported inputs raise `InspectionError` with a fixed code rather than raw exception contents. The CLI emits JSON and returns 2 for rejection. Exit 0 means only that the implemented metadata checks completed, with `status=review_required` and `installation_authorized=false` in every successful report.

The default `strict` profile keeps the original 512 MiB entry cap and ARM64-only scope. Explicit `extended-review` raises only the per-entry cap to 1 GiB and additionally parses ARMv7 library slices, including their encryption/platform/load commands; it does not silently skip them or thin the input. The main must still contain only ARM64/ARM64e iOS executable slices. Reports name the selected profile and effective entry cap, and flag legacy slices for disposition. All other bounds, path checks and secret-member exclusions remain unchanged. This is an inventory extension, not a relaxed installation gate.

## Checked scope

- Non-ZIP64 single-disk ZIP; central directory bounded before `ZipFile` parses it. Reject trailing data, duplicate/casefold/NFC-colliding paths, traversal, absolute/backslash/drive paths, file/directory prefix conflicts, symlinks/special entries and encrypted ZIP entries.
- Exactly one root `Payload/*.app`, no nested apps. Read bounded `Info.plist` metadata for discovered app, framework and extension bundles and require declared executables. Inspect these executables plus loose `.dylib` files.
- Thin little-endian Mach-O64 ARM64, and big-endian FAT32/FAT64 containers holding supported ARM64 slices. Check FAT slice bounds, nonoverlap, alignment and table/header identity, load-command bounds/counts, platform and encryption commands, dependency/rpath strings. The main must be an iOS executable. Nonzero cryptid is rejected, including in guest extensions; no decryption is attempted.
- Report SHA-256, selected bundle metadata, code inventory, load paths and review flags. `checks_completed` refers only to these checks, not completeness of metadata. Missing optional versions appear as `unspecified`. `other_file_count` counts non-directory members not classified as inspected code, including metadata/resources; it does not prove they are all nonexecutable. Dependencies outside `/usr/lib/` and public system frameworks are separately listed for layout review; all rpaths require review, with no automatic resolution. Certificate/key/provisioning-named files are listed but their member contents are never opened; whole-archive SHA-256 reads the archive as opaque bytes. A filename is not proof of private-key material or its purpose.

Limits: 2 GiB archive, 16 MiB central directory, 20,000 entries, 512 MiB per uncompressed entry (1 GiB only in explicit extended review), 4 GiB total declared uncompressed data, 1000:1 per-entry ratio, 1 MiB per plist, eight FAT slices, 8192 commands and 4 MiB load commands per slice, 1024 characters per reported metadata/path string. Unsupported input fails visibly rather than widening limits silently. Header/load-command reads remain bounded; the larger cap does not read a whole framework into memory. Seeking within compressed members can still require decompression work.

## Explicitly not verified

No signature validation, entitlement inspection, vendor provenance, dependency resolution, native loading, security certification or runtime feature checks. Executable files hidden in unrecognized resource locations are not exhaustively discovered. Most Mach-O section contents and command types are not semantically validated. No full archive CRC/integrity pass is performed for untouched resources. Unknown platforms in embedded libraries remain a review flag; unsupported declared platforms are rejected. This is not a safe-extraction library, a malware scanner, a decryption tool or installation approval.

Do not bypass rejection by silently deleting encrypted extensions or key-named resources. A future assembler needs an explicit reviewed inclusion/exclusion policy, its own path validation and immutable manifest enforcement. The owner's original must remain untouched. No additional app products or entitlements are authorized here.

Current observed package blockers and boundaries are in `docs/NATIVE_GUEST_PACKAGING.md`. Tests generate synthetic archives and Mach-O headers inside temporary directories; no real social binaries, certificates, profiles or credentials are fixtures.

## Draft private package layout

`package_plan.py` is the next preparation stage, still read-only. It runs the same preflight against the original IPA and produces a digest-bound **draft**, not a manifest accepted by the phone loader:

```powershell
python experiments/native-social-package-tools/package_plan.py 'C:\path\candidate.ipa' --profile extended-review
```

Every non-directory ZIP member receives exactly one action. Proposed destinations stay under `Frameworks/NativeGuest.framework`, retaining the nested library/resource hierarchy; the main executable and root plist require preparation rather than being copied as already usable framework code. Relocated filename collisions and file/directory conflicts reject the plan. This does not prove that the proposed framework layout works with SideStore or LiveProcess.

Guest extension members and material-named files have no destination by default. Old `_CodeSignature` metadata is marked for omission from a future rebuilt copy, never removed from the original. Other resource candidates receive only a four-byte magic check; unclassified Mach-O/FAT candidates have no destination and remain blocked. That check is not a malware scan, script detector or proof that resources are inert. Known material members remain unopened. No hashes/content of individual key-named members are collected.

An optional local `--policy proposal.json` can record **proposed** exact-path exclusions with this shape (illustrative values only):

```json
{
  "schema": 1,
  "input_sha256": "<SHA-256 of the complete original IPA>",
  "excluded_extensions": ["Payload/Example.app/PlugIns/Test.appex"],
  "excluded_materials": ["Payload/Example.app/Resource.bundle/private_key.p12"]
}
```

JSON policies are capped at 1 MiB. Unknown/duplicate fields or targets, non-object JSON, unsupported schemas and stale input digests reject. Only discovered extension roots and discovered material names can be excluded; encrypted/malformed code cannot be hidden with exclusions because preflight runs first. Both the initial and final whole-input hashes must match. Do not concurrently modify an input during planning; this is not a filesystem snapshot/locking implementation.

The planner never writes or extracts files, changes a binary, signs, uploads or executes code. Exit 0 means a draft was generated, **not** that its blockers are resolved: `status=draft_review_required`, `assembly_authorized=false`, `installation_authorized=false` always remain. The JSON policy is not a permission to execute a guest, nor can it authorize new extensions. Keep real plans/policies local. The separate executable adapter, research ZIP writer and host merger are described below; none is automatically applied by the planner. Signing and actual native guest compatibility remain separate gates.

## Narrow executable preparation

`prepare_executable.py` prepares a **separate** main-binary copy before signing. It does not operate on an IPA or change a signed installed app. Its pure `prepare_main(bytes, expected_sha256=...)` interface returns new bytes plus hashes and limitations; `prepare_file`/CLI writes a new destination without replacing any existing file. No native code is executed.

```powershell
python experiments/native-social-package-tools/prepare_executable.py 'C:\private\OriginalMain' 'C:\private\NativeGuest' --input-sha256 '<main-binary SHA-256>'
```

The digest is for the **main executable bytes**, not the whole IPA. The input must be a thin, little-endian ARM64 subtype-0 iOS `MH_EXECUTE`, at most 32 MiB, with the supported command set, conventional 4 GiB `__PAGEZERO`, file-backed `__TEXT`/`__text` entry point and an existing nonempty signature slot. FAT, ARM64e, encrypted code, chained fixups, unknown commands, duplicate dependencies, absent signature slots, malformed ranges and unsupported mappings fail visibly. This is intentionally narrower than the inventory tool.

Preparation inserts a fixed `NativeGuest` dylib identity into verified zero command padding, changes the file type/PIE-related flags and reduces `__PAGEZERO` to one 16 KiB range immediately below the original text base. Section bytes, entry-point offset, dependency paths, link-edit offsets and total file size do not move. Original signing metadata becomes stale: the output **requires fresh signing** and is not a verified or launch-ready dylib. These structural rules use Apple's [Mach-O format definitions](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h) and the reviewed [pinned LiveContainer conversion](https://github.com/LiveContainer/LiveContainer/blob/e370a92dfc03ce109ebce00ed4a7cfc64ad1c801/LiveContainer/LCMachOUtils.m), without adopting optional tweak injection, JIT or signature-validation bypasses.

The publisher writes a uniquely created temporary file, flushes it, then uses no-replace hard-link publication. Existing outputs (including symlinks/hard links) are never overwritten. Filesystems without this operation fail instead of falling back to replacement. Only its own temporary file is cleaned up. A `temporary_cleanup_failed` error can occur after output publication; preserve/check the output instead of deleting it and retrying blindly. The input is never opened for writing. Material-named inputs are rejected before opening. Output parents must already exist and be a trusted local directory chosen by the owner, not a path from an untrusted manifest.

Synthetic tests verify transformation invariants, malformed/rejected cases, no-overwrite publication, cleanup and sanitized failures. The actual RXTikTok main has been adapted **in memory only**; no prepared proprietary binary was saved or run. No Apple signature verifier or dyld runtime has validated this adapter's output. Native package assembly and signed-device tests remain separate gates.

## Private unsigned guest ZIP writer

`assemble_guest.py` recomputes preflight and the plan against the same read-only input handle. It requires an explicit policy, the reviewed plan's `plan_sha256`, and `--acknowledge-unverified-layout`. This last flag acknowledges unresolved dependency/resource/signing/runtime checks for a research copy only; it is not a trust decision or permission to install or execute code.

```powershell
python experiments/native-social-package-tools/package_plan.py 'C:\private\candidate.ipa' --profile extended-review --policy 'C:\private\proposal.json'
python experiments/native-social-package-tools/assemble_guest.py 'C:\private\candidate.ipa' 'C:\private\guest.zip' --profile extended-review --policy 'C:\private\proposal.json' --plan-sha256 '<reviewed plan_sha256>' --acknowledge-unverified-layout
```

There are no default extension/material exclusions: undisposed members, outside-root files and unclassified Mach-O candidates reject assembly. Exclusions cannot conceal encrypted extension code from preflight. Material-named members are not opened. The writer applies the narrow main adapter, changes only the root plist's executable/package-type fields, preserves included embedded code/resources byte-for-byte, and omits obsolete signature metadata. Embedded signatures are not verified and the main signature is invalidated; fresh containing-app signing remains mandatory. No architectures or debugging libraries are silently stripped.

Included members are streamed in 64 KiB chunks to a new ZIP_STORED archive, capped at 2 GiB; the main is bounded at 32 MiB, the root plist at 1 MiB, and the manifest at 16 MiB. `GuestPackage.json` records each included file's pre-signing hash, omissions, adaptation evidence and unverified flags. It is explicitly **not a runtime manifest**. Every included output member is reopened and checked for inventory, size, CRC and SHA-256, then the source hash is checked again before no-replace publication. This is not a snapshot against hostile concurrent input mutation; do not modify the source during assembly.

The existing trusted output parent and hard-link/no-overwrite/owned-temporary-cleanup rules from the adapter also apply. An unsupported filesystem fails; no overwrite fallback exists. A cleanup failure after publication may leave a valid output plus the owned temporary link, so inspect the reported failure before retrying. Omitted members do not receive a full CRC/content check. Output is an **unsigned guest-framework research ZIP, not a host app or IPA**; `installation_authorized=false` and `runtime_manifest=false` remain explicit. Keep all real outputs private. Following explicit owner approval of the two component exclusions, the supplied RXTikTok package has also been assembled locally into a separate ignored research ZIP and readback-verified; see `docs/NATIVE_GUEST_PACKAGING.md`. Host integration, signing and no-account launch remain outstanding. No real binary fixtures or package outputs belong in source or public CI.

## Private Build 20 host merger

`merge_host.py` is a separate, narrow packaging stage for the reviewed Build 20 framework host and prepared TikTok build 439042. It requires externally supplied SHA-256 values for the host IPA, prepared guest ZIP and original guest IPA. Obtain those values from independently reviewed evidence, not from an untrusted package's own claims. A caller-supplied digest is an integrity constraint, not a provenance or malware verdict.

```powershell
python experiments/native-social-package-tools/merge_host.py 'C:\private\Build20-host.ipa' 'C:\private\guest.zip' 'C:\private\CalcVault-native-TikTok-research.ipa' --host-sha256 '<reviewed host SHA-256>' --guest-sha256 '<reviewed ZIP SHA-256>' --guest-input-sha256 '<reviewed original IPA SHA-256>' --acknowledge-unverified-runtime
```

The merger checks the fixed host identity/build, single LiveProcess extension, synthetic replacement inventory, prepared guest identity/build, manifest inventory and per-file hashes. It replaces the synthetic framework and selection descriptor, omits the known obsolete synthetic payload/resource bundle and external signature metadata, and preserves other host file contents including embedded executable/entitlement bytes. It neither grants new entitlements nor adds a guest extension. The guest's prepared main and nested code/resources stay together under `Frameworks/NativeGuest.framework`.

Inputs are opened read-only; ZIP member paths and types are checked before streaming into a new bounded output. The merger verifies output inventory, CRCs and hashes, rechecks inputs, and publishes without replacing existing files. The trusted-parent and cleanup-after-publication cautions above apply. Keep inputs stable during the operation. All proprietary inputs and outputs must remain private and outside tracked source/public CI.

Output is an IPA-shaped **research candidate requiring fresh SideStore signing**, not a verified launchable or production build. It retains the Build 20 research host UI, not the production calculator/vault/browser interface. `installation_authorized=false`, `requires_fresh_signing=true` and `runtime_verified=false` remain explicit. This tool cannot verify the eventual SideStore signature, dependency/resource compatibility, guest behavior, login, highlights or privacy after actual guest loading. Start any separately approved device test without account sign-in or personal data. CalcVault's existing browser/downloader source is untouched.
