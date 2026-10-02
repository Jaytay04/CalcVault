# TTKillerPlus static evidence and remaining limits

Review date: 2026-10-02. Target: TikTok47.0 / TTKillerPlus2.2 publisher-linked
ARM64 package. This record is sufficient to interpret the accompanying
reference without the historical CalcVault task ledger.

## Exact target

- IPA: 470,033,098 bytes; SHA256
  `8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198`.
- App metadata: TikTok47.0.0, build470044, bundle
  `com.zhiliaoapp.musically`.
- Inspected member: `Payload/TikTok.app/Frameworks/TTKPlus.dylib`;
  812,816 bytes; SHA256
  `e99888d3d7e2c37839f5361ccfe2abafcfb1c20ef72c82d9062beb4ed1ab6a55`.
- Original archive: 3,518 entries; prior bounded all-entry CRC checks passed.
  ARM64 code preflight reported cryptid0. Digests/CRC identify bytes, not
  publisher trust, safety, authorship or licensing rights.
- Preserved originals are outside Calculator under
  `../iKarwan-IPAs/2026-10-02/`, alongside preservation/checksum records.

## Checks actually run

PASS: exact IPA/dylib digest validation; full declared class/category parsing;
578 declared methods; 978 validated selector stubs; 1,732 compiler function starts;
8,061 direct branches to selector stubs across 976 functions.

PASS: LLVM registration-reference scan cross-checks 165 method-hook +
73 method-add sites, plus five C-function hook sites. Expanded argument
reconstruction accounts for all238 method-registration sites. The earlier
237 total omitted0x12ff8 because a range began at0x13000. This was corrected
to0x12000; no runtime fix or hook success is implied.

PASS: all578 saved owner/kind/selector/type tuples match the original parser;
all21 declared Boolean-toggle handlers contain the expected direct preference
write calls. A valid-input optimized-Python header agrees with saved target,
counts, libraries, preference names, selector stubs and registration candidates.

PASS: six local validation tests. They check class/category/method accounting,
method sizes/types/direct-call count structure, exact target/stub accounting,
238/5 registration totals, all21 toggle call sets, sanitized metadata contents,
and rejection of a synthetic unpinned IPA in both normal and optimized Python.

An independent review caught that initial assertion-based input guards would
disappear under Python -O. Every such analyzer guard was changed to an explicit
runtime check; the rejection test and valid-input optimized run passed.
These are inspection-tool integrity checks, not a security audit of the tweak.

Additional static body traces support the described media-to-Photos callbacks,
preference-gated profile/story/message wrappers, recommendation-card skipping,
ad-model filtering, live control lifecycle, region fallback, confirmations,
checkout callbacks and broad deletion helpers. API presence and registration
candidates remain weaker evidence than reconstructed branches.

Reset workers resolve standard user-domain directory enums and remove children;
several also clear bundle/suite defaults, temporary paths or accessible Keychain
classes. These are not add-on-owned-only operations. The cache-clearing worker
and nested authentication-storage helper writes remain unresolved. Outbound
installation/activation-report request construction is traced; endpoint/body
semantics and runtime transmission are not established.

## Prior PKCS12 findings

A separate bounded study of the same original IPA inspected structural metadata
for a 1,525-byte SessionCheck PKCS12 resource in MusicallyCore. It reported a
PFXv3 container with a visible encrypted private-key bag and an additional
encrypted contents section. No password attempts, identity import, decryption,
key bytes, certificate identity or resource payload were used or exported.

MusicallyCore contains resource-name/type, loading, authentication-challenge and
PKCS12/identity-API references. Inspected TTKPlus sections did not show matching
resource references or a SecPKCS12Import import. This supports a possible
session/network identity purpose in the TikTok core, not a proven call flow,
vendor provenance, licensing purpose or owner/Apple signing identity.

These are prior static findings, not a new import/use test. Exact certificate
contents and resource-to-challenge behavior remain unverified. No PKCS12 file
or key material is included in this documentation package.

## What has not been established

No target-code execution, authentication request, checkout/purchase, account
unlink, cloud sync, Keychain or cleaner/reset operation, source-library deletion,
private media/account action, Apple compilation, new installation or phone
regression was performed for this study.

The inventory does not recover original source, all receiver types, indirect
call targets, every nested block/error path, full licensing protocol, runtime
registration success or all media surface/model variants. Static privacy
suppression is not provider-level anonymity. Region overrides are not a VPN.

Deletion-helper APIs/query shape were inspected, but OS/entitlement-dependent
effects were not tested. The environment/interception and inspection-detection
methods are not a trust boundary for CalcVault. Future feature implementation,
native-to-Vault transfer, package changes and live tests require separate work.

The original IPA and extracted dylib remain unchanged. Existing project source
changes were preserved. This package does not include or authorize licensing
bypasses, expanded Vault access, new products/App IDs, publication or release.
