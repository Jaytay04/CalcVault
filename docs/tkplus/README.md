# TTKillerPlus 2.2 documentation package

This package maps the full TTKillerPlus add-on in the preserved TikTok47 IPA:
startup and environment hooks, settings and UI utilities, licensing and checkout,
identity and storage, region controls, all identified social feature families,
downloads and composition, and cleaner/reset operations.

This is static reverse engineering, not recovered original source or runtime
certification. Traced behavior, declarations and remaining unknowns are separated.
The whole TikTok core and other KillerPlus products are outside this target.

## Package contents

The independently authored implementation now starts in
[the implementation record](INDEPENDENT_IMPLEMENTATION.md) and
[`experiments/tkplus`](../../experiments/tkplus/README.md). The reference below
remains evidence about the original add-on, not source for the new layer.

| File | Purpose |
|---|---|
| [Reverse engineering reference](TTKILLERPLUS_REVERSE_ENGINEERING.md) | Human-readable architecture, mechanisms, data flows, evidence locators and risks. |
| [Static component index](research/TTKILLERPLUS_2_2_STATIC_INDEX.json) | All 578 declared methods, 978 selector stubs, 238 method-registration candidates and metadata. |
| [Evidence and limits](EVIDENCE_AND_LIMITS.md) | Target identity, checks actually run, unresolved coverage and prior PKCS12 findings. |
| [Inspection tool](tools/inventory.py) | Exact-digest read-only metadata/direct-call analysis; optional LLVM registration cross-check. |
| [Validation tests](tools/test_inventory.py) | Six integrity/rejection tests, using no target code execution. |

No IPA, dylib, credential, private-key/resource payload, account data, endpoint
URL or license patch is included. Original IPAs remain in the separately
preserved sibling archive, not in this documentation directory.

## Read first

Start with the reference's scope/coverage ledger and component table.
The JSON is a lookup index, not executable source. In particular, a method name
or a direct selector call is not proof that the feature works on a device.

A significant static finding is that the Keychain-reset helper builds class-wide
deletion queries without a service/account filter, within the caller's OS
access scope. Do not treat the tweak's cleaner/reset controls as harmless
cache cleanup when evaluating an embedded guest. Traced reset workers also
target broad standard app-data folders, not just tweak-owned cache files.
No reset was run.

## Reproduce the static checks

Run from the Calculator project root. Python3.13 was used; the tool has no
third-party Python dependencies. Input digest and bounds checks remain active
under optimized Python.

```powershell
python -m unittest discover -s docs/tkplus/tools -p test_inventory.py -v
python docs/tkplus/tools/inventory.py "../iKarwan-IPAs/2026-10-02/TikTok_47.0_TTKillerPlus_2.2.ipa" --part header
```

The second command hashes the preserved original and prints metadata only.
It does not extract files, install or load code, or contact a service.
Use --part component --owner RootOptionsController to inspect one component.

For registration analysis, supply an unchanged, separately extracted
TTKPlus.dylib and the LLVM objdump path:

```powershell
python docs/tkplus/tools/inventory.py "../iKarwan-IPAs/2026-10-02/TikTok_47.0_TTKillerPlus_2.2.ipa" --dylib "build/startup-diagnostics2/build/ttkiller-feature-review-20261002/TTKPlus.original.dylib" --llvm "C:\Program Files\LLVM\bin\llvm-objdump.exe" --part header
```

Without --dylib, method-registration fields are omitted because no LLVM
cross-check ran. The supplied dylib digest is verified before analysis.
The existing ignored extraction path above is an environment convenience,
not required package content; a different exact-byte copy can be supplied.

The parser is specific to this pinned ARM64 input, not a general hostile-file
parser. It supports this input's relative ObjC method lists and local chained
pointers, and rejects imported/bound pointers instead of following them.
Direct-call summaries exclude indirect dispatch, superclass calls, C calls
and nested blocks/helpers. Registration reconstruction is bounded straight-line
dataflow, not a receiver/ABI proof or complete control-flow analysis.
No output file is written automatically.

## Status

Six local validation tests passed. The original metadata rows and regenerated
header were cross-checked, including valid-input analysis under optimized Python.
No proprietary code was executed, patched or newly installed for this study.
Runtime behavior, endpoint protocol, every callback/failure path and provider-side
privacy remain unverified. Markdown was read back and link/structure checked;
a rendered layout preview was not available.
