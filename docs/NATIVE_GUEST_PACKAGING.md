# Native guest packaging research

Status: local static research, 2026-09-27. Not an installer, trust verdict, or production native-guest authorization. Build 19's synthetic loader and the normal CalcVault app are unchanged.

## Public candidate discovery

The owner requested inspection of `BandarHL/BHTikTok` and its `raulsaeed/BHTikTokPlusPlus` fork. Both source projects build injected tweaks, not the proprietary TikTok client. The original's `0.0.1` release offers a TikTok 30.3.0 IPA (July 2023). The fork's `v.1.1.0` release offers TikTok 36.4.0 (September 2024); its newer `v1.9.3` release points to its Telegram channel for IPAs. That linked channel advertises RXTikTok 1.6.6 / TikTok 43.9.0. The newer binary, its relationship to the public source, current features and highlights remain unverified.

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

## Next gate

Use the separate read-only local preflight tool to repeat archive and Mach-O structural checks on candidate IPAs. Its report is only an inventory with review flags, never installation authorization. Keep real binary inputs and reports private; automated tests use generated synthetic bytes only. No tool may read signing-key contents, call a signing service, execute a guest, mutate the original or upload it.

After the inventory, the outstanding implementation is private local executable preparation and immutable guest packaging, followed by reviewed signing and no-account launch tests. A newer owner-supplied RXTikTok IPA can be inspected in parallel, but it must not be installed or used for real login on the strength of these static checks. Native highlights, media, isolation and lifecycle all still require actual package-specific validation.
