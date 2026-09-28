# Native guest packaging research

Status: local static research, 2026-09-28. Not an installer, trust verdict, or production native-guest authorization. Build 19's synthetic loader and the normal CalcVault app are unchanged.

## Public candidate discovery

The owner requested inspection of `BandarHL/BHTikTok` and its `raulsaeed/BHTikTokPlusPlus` fork. Both source projects build injected tweaks, not the proprietary TikTok client. The original's `0.0.1` release offers a TikTok 30.3.0 IPA (July 2023). The fork's `v.1.1.0` release offers TikTok 36.4.0 (September 2024); its newer `v1.9.3` release points to its Telegram channel for IPAs. That linked channel advertises RXTikTok 1.6.6 / TikTok 43.9.0. The owner subsequently supplied that named package for local static inspection, recorded below. Its relationship to the public source, current features and highlights remain unverified.

Sources: [original release](https://github.com/BandarHL/BHTikTok/releases/tag/0.0.1), [fork IPA release](https://github.com/raulsaeed/BHTikTokPlusPlus/releases/tag/v.1.1.0), [fork newer release](https://github.com/raulsaeed/BHTikTokPlusPlus/releases/tag/v1.9.3), [project-linked channel](https://t.me/s/BHTikTokPlusPlus).

The inspected source heads were original `18b4477ee29581aa99d0851776a58b008b78ede9` and fork `6add794fc818f0ceca76279d90cb9c4e3f9a5150`. Source-to-release-binary equivalence was not established. The fork's current source removed private Preferences/Cephei build dependencies, but the older IPA still links them. Both use process-wide hooks and media cleanup in Documents/temp; the fork's HD download sends content identifiers to a third-party service. These are reasons to preserve the separate guest process and scoped data boundary, not to merge the tweak into the vault. No generic vault file bridge or automatic Photos export is approved.

## Older IPA static observation

Downloaded only from the fork's public `v.1.1.0` GitHub release into ignored local `build/bhtiktok-static-review-20260927/`. No execution, installation, decryption, signing, source extraction or upload occurred. The original download is preserved.

- Artifact name: `TikTok_36.4.0_BH_v1.1.0.ipa`; 308,007,331 bytes.
- SHA-256: `0d51927ef4c66183b6d551d7feecc695480273b650b43619e656a45924a5d03a`. This identifies the inspected download; it does not authenticate the publisher or certify the binary.
- Bundle: `com.zhiliaoapp.musically`, version 36.4.0, build 364020.
- Main executable: ARM64, `MH_EXECUTE`, iOS platform 2, encryption command `cryptid=0`, `LC_MAIN` entry offset 29964, and a 4 GiB `__PAGEZERO` segment.
- ZIP inventory: 2,691 entries; 21 frameworks, 28 loose dylibs and eight extension bundles. The initial checks found no duplicate names, parent-traversal paths or symlink entries. This is not a comprehensive ZIP integrity verdict.
- The main executable and `MusicallyCore` both use `@executable_path/Frameworks`; the main also loads `@executable_path/BHTikTok.dylib`. Location-dependent loading must be reviewed for the immutable guest-code layout before signing; do not assume copying directories solves it.
- The tweak has ARM64 and ARM64e slices and links Preferences, Cephei/CepheiPrefs/CepheiUI and CydiaSubstrate. Examined encryption commands in the main, 48 thin embedded-code files and both tweak slices were zero. This is not signature verification or a proof of executable correctness.
- `SessionCheck.bundle/private_key.p12` exists. Its contents were not inspected; neither purpose nor presence of private-key material was established. Do not identify it as the owner's SideStore key, delete it blindly, or copy it into source/CI. It is an unresolved packaging-review item.

All eight guest extensions need a deliberate disposition before a package can be assembled. This research does not authorize registering them, adding Home Screen apps, or removing SideStore/Spotify. Feature effects from omitting them are untested.

## Repeatable preflight result

`experiments/native-social-package-tools/ipa_preflight.py` now implements a bounded, read-only ZIP/Mach-O inventory with generated synthetic tests. Its 32 local tests and the seven existing LiveProcess packaging regression tests passed on Windows. The complete older IPA is **REJECTED: encrypted_macho**, not approved for packaging: a follow-up member-specific header check identified `AwemeNotificationService.appex` as retaining nonzero cryptid. The other seven declared extension executables passed the implemented metadata parser. The earlier main/framework/tweak observations remain accurate, but were not whole-package encryption clearance.

The original SHA-256 and contents are unchanged. No extension was removed or decrypted. A future candidate package needs a reviewed guest-extension exclusion policy, not an option that quietly ignores encrypted code. The tool also deliberately leaves signatures, entitlements, hidden resource executables, full resource CRCs and runtime trust unverified. The named PKCS#12 file remains unopened and unresolved.

## Owner-supplied RXTikTok static observation (2026-09-28)

The local `RXTikTok-v1.6.6_43.9.0.ipa` is 361,528,379 bytes, SHA-256 `8db5258b016869bc515915f731780eece9b66ecb12530d204834e2e381f08369`. Original and post-inspection hashes match. No execution, installation, extraction, decryption, signing or upload occurred. This digest identifies these bytes, not publisher authenticity.

- Main bundle `com.zhiliaoapp.musically`, version 43.9.0, build 439042; executable `TikTok`, ARM64, iOS platform 2, `MH_EXECUTE`, cryptid 0.
- 2,464 ZIP entries; 673,700,921 bytes declared uncompressed; 17 frameworks, five loose dylibs, one Safari extension (`OpenTikTokSafariExtension.appex`). The older encrypted notification extension is absent. The extension is inventoried, not approved for inclusion or App ID registration.
- Default preflight rejects `archive_entry_limit`: `MusicallyCore` is 560,847,136 bytes, above the default 512 MiB per-member limit. Its compression ratio is about 1.96:1. This is a tooling limit, not a malware finding.
- Supplemental bounded header inspection identified ARMv7 plus ARM64 in `libsubstrate.dylib`; the default ARM64-only parser rejects the extra architecture. The ARM64 slice has no encryption command. No architecture was removed, skipped as approved code, or executed.
- The main directly loads `___RXTikTok.dylib`, `libFLEX.dylib`, `FLEXing.dylib` and `libsubstrate.dylib`. RXTikTok links Apple's private Preferences framework; RXTikTok and FLEXing both link the bundled substrate library. These dependencies need runtime review. Removing debug libraries without reviewing dependent loads would be a separate executable modification, not harmless resource cleanup.
- `SessionCheck.bundle/private_key.p12` is present. Its member contents remain unopened; neither purpose nor actual private-key presence is established. It must not enter source, public CI or public artifacts. Its disposition is unresolved, not automatically deletion or approval.
- Main load-command inspection: 39 commands / 4,240 bytes, `LC_MAIN` entry offset 23,200, 4 GiB `__PAGEZERO`, rpaths `/usr/lib/swift` and `@executable_path/Frameworks`. The first file-backed section offset is 23,068, leaving an apparent 18,796-byte header-to-section gap. This is not verification that the gap is free writable padding or approval to patch it.

The review parser's architecture definitions are checked against Apple's [Mach-O header and command structures](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h) and [CPU subtype definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/machine.h). These specify the 28-byte ARM header, 32-byte ARM64 header, 4/8-byte command alignment and ARMv7 subtype 9. Supporting inventory of a legacy slice does not authorize running it on the phone.

### Concrete next packaging boundary

Final tooling verification increased to 45 passing inspector tests after preserving strict-profile malformed-input error codes identified in independent review; the initial 43-test run below remains historical evidence.

The implemented explicit `extended-review` profile completed the supported inventory on this original IPA: 24 declared code files / 27 architecture slices, all examined encryption commands zero or absent. Status remains `review_required`, `installation_authorized=false`. The default profile still rejects the size; extended review records its 1 GiB cap and flags the ARMv7 slice for disposition. No hidden resource-executable scan, complete ZIP CRC, signature verification or runtime test is implied. Forty-three generated synthetic inspector tests and seven existing synthetic packaging regressions pass locally on Windows; the original hash was checked again after the real-package read.

The next implementation target is a private local, synthetic-tested preparation/assembly tool, not a generic on-device IPA importer. It must preserve the original, bind an explicit input digest and reviewed manifest, prepare a separate immutable guest-code copy before SideStore signing, and fail on undisposed extensions/material-named resources or unresolved load paths. No real guest manifest is accepted by the current loader.

Keep the guest's nested dependency hierarchy separate from host frameworks. The pinned upstream `LCBootstrap.m` deliberately changes the executable path before `dlopen`; CalcVault's synthetic patch currently redirects it to one containing-app dylib. Therefore executable-relative dependencies are not by themselves proof of incompatibility, but the one-file fixture does not validate a nested TikTok framework graph. An adapter must test the actual immutable path, guest resource bundle and `NSBundle` view together. Do not solve a path failure with a host Documents-root bookmark or with the guest running in the vault process.

No additional guest extension is authorized. A proposed assembly would exclude the Safari extension explicitly and report the omitted capability, subject to manifest review; this turn did not remove it. Debug-library and PKCS#12 resource disposition remain separate review items. Private Preferences availability, signature/entitlements, no-account native launch, highlights and package-specific lifecycle/isolation remain NOT RUN.

## Draft manifest implementation (2026-09-28)

`experiments/native-social-package-tools/package_plan.py` now accounts for every non-directory archive member without extraction. It proposes a separate immutable `Frameworks/NativeGuest.framework` hierarchy, marks main executable/plist preparation, checks relocated destination collisions/prefix conflicts, and keeps extensions and material-named members without destinations pending explicit digest-bound exclusion proposals. A proposal cannot hide an encrypted extension from preflight. Reports always deny assembly/installation authorization; the phone loader does not consume them.

On the unchanged owner-supplied RXTikTok input, the no-policy draft accounts for all 2,464 files: 1 main executable, 1 root metadata file, 22 other code files, 17 nested bundle plists, 21 Safari-extension members, 1 material-named resource, 18 old signature-metadata files, and 2,383 resource candidates. Four-byte resource-prefix inspection found no additional unclassified Mach-O/FAT candidates in that inspected resource subset. It does not establish absence of scripts, dynamically obtained code or other executable formats. No material member contents were opened. All 21 extension files and the material resource remain unapproved, without a proposed destination. Debug libraries remain visible in the embedded-code review, not stripped.

The original SHA-256 still matches `8db5258b016869bc515915f731780eece9b66ecb12530d204834e2e381f08369`. No private plan file or exclusion policy was persisted, no package assembled, and no original files changed. Local tests: 63 generated preflight/planner tests (45 existing preflight + 18 new planner) and seven existing synthetic LiveProcess packaging regressions pass. See `TEST_REPORT.md` for verification limits.

## Main-executable adapter (2026-09-28)

Implemented a separate narrow pre-signing adapter with synthetic tests and no native execution. It supports only the reviewed thin ARM64 subtype-0 iOS executable layout, validates padding/ranges/entry point, inserts a fixed dylib identity, converts header flags/type and reduces `__PAGEZERO` without moving section/link-edit data or changing file size. Unsupported commands (including chained fixups), architectures, encrypted data and layouts fail visibly. The separate-file publisher refuses in-place/existing destinations and uses no-replace hard-link publication. Signing is still required; preserving the old signature bytes does not preserve validity.

The original IPA's main was read and transformed in memory only. It satisfies this adapter's checks: 80,192 bytes, entry offset 23,200 retained, all bytes from offset 4,312 onward unchanged. Main input SHA-256 `3a1f207994bea4d31e1555a5bf6ad2875891df6b0f6d6bc87fbaffffa84fa1a7`; prepared in-memory SHA-256 `277d9d40a5dff8de8fc365e62d256a6de882afb35184ff0db44826ede96044b7`. No prepared proprietary file/IPA was written, signed, uploaded or executed. Whole original IPA SHA-256 remains unchanged. This is structural conversion evidence, not a launch/compatibility result.

Local tests now pass 85 cases across preflight, planner and adapter, plus seven existing LiveProcess packaging regressions. The planner now reports `main_adapter_not_applied` rather than unimplemented; it does not call the adapter or authorize assembly. Full output packaging, resource/extension disposition, loader manifest changes, signer verification and no-account device launch remain outstanding.

## Next gate

Final writer review found no blocker in the assigned safeguards. A further cleanup-after-publication regression raises the final local count to 105 tooling tests plus seven existing packaging regressions. A cleanup error may leave an already-published output; callers must inspect it rather than overwrite it on retry.

The separate `assemble_guest.py` research writer is now implemented and synthetic-tested (104 tooling tests plus seven existing packaging regressions). It requires a fresh matching plan fingerprint, explicit disposition policy and acknowledgment of unresolved layout checks; it prepares only the main/root plist and streams other included files unchanged. It verifies included output CRCs/hashes/inventory, rechecks the original digest and publishes with no replacement. Excluded key-named member contents remain unopened. Output is a private unsigned guest-framework ZIP, not an installable host IPA or an accepted runtime manifest. Only synthetic archives have been assembled. The original RXTikTok IPA and installed Build 19 remain untouched.

Use the separate read-only local preflight tool to repeat archive and Mach-O structural checks on candidate IPAs. Its report is only an inventory with review flags, never installation authorization. Keep real binary inputs and reports private; automated tests use generated synthetic bytes only. No tool may read signing-key contents, call a signing service, execute a guest, mutate the original or upload it.

The owner subsequently approved omitting the Safari extension and unopened PKCS#12-named resource from a separate copy after clarification that this does not remove Safari or CalcVault's Instagram/X browsing and downloader code. The private assembly below supersedes the earlier synthetic-only checkpoint. Omission can remove a guest feature or break initialization, and is not a finding about the resource's contents. Host/loader integration with reviewed dependency/resource layout, signing verification and no-account native launch remain separate gates. The owner-supplied RXTikTok IPA must not be installed or used for real login on the strength of static checks. Native highlights, media, isolation and lifecycle all still require actual package-specific validation.

## Owner-approved private research ZIP (2026-09-28)

Integration source follow-up: a separate opt-in Build 20 loader adapter now targets the same immutable framework root for executable and main-bundle resources, with a fixed selection contract and dedicated data directory. It removes the synthetic route's Documents payload copy and mutable metadata fallback only in the disposable generated variant. Public CI will exercise this with a generated synthetic guest and fresh signing, not the actual TikTok ZIP. Local source/fixture tests pass; native compilation, framework loading and lifecycle checks remain separate verification. The private host merger and package-specific signing/launch are not implemented by this adapter alone.

Created `build/private-native-guest-rx166/guest.zip` through the reviewed assembler with an exact input-bound policy excluding only the discovered Safari extension subtree and `SessionCheck.bundle/private_key.p12`, plus the writer's obsolete signature metadata omissions. This Git-ignored output is 673,484,480 bytes; SHA-256 `d725967840f37580b3e8ede08ac40a01d0a86c8681d3cbffcad0ef587348543e`. The fresh reviewed plan digest was `7842d736704e89b61ba6d6ed25b85aa8c5c71aca243a4c12a3ff349330adc3a7`.

There are 2,424 included payload files and one research manifest. The 40 omissions comprise 21 Safari-extension members, one unopened material-named resource and 18 obsolete signature metadata members. Included member CRC/hash/inventory verification passed during creation and again on a separate readback; root metadata uses `NativeGuest`/`FMWK`, with no `.appex` or known material-suffix output entries. The original IPA's independently rechecked SHA-256 remains `8db5258b016869bc515915f731780eece9b66ecb12530d204834e2e381f08369`. No original data was removed, and no key contents were opened. Debug libraries and existing dependency/resource hierarchy are retained, not runtime-approved.

This is **not an IPA**, not a signed package and not a loader-accepted runtime manifest. No containing-host assembly, public upload, Actions build, SideStore installation, native execution or account sign-in occurred. All CalcVault browser/downloader/production code remains unchanged. The next implementation boundary is a narrowly reviewed private containing-host and loader integration, not a generic phone importer or a grant of host vault/filesystem access.
