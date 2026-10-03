# Independent TKPlus implementation

The owner approved an independently authored native feature layer on 2026-10-02.
The first scope is selected-media downloads intended for the encrypted Vault
and opt-in profile-view controls in CalcVault's existing native TikTok guest.
The source lives at [`experiments/tkplus`](../../experiments/tkplus/README.md).
It is separate from the shipping target and from the original TTKillerPlus code.

## Approved boundary

The runtime-hook exception is narrow. It does not authorize private provider
endpoints, credential/cookie copying, Vault keys in the guest, a general command
bridge, broader bookmarks, new products or additional App IDs. Browser access
for X/Instagram and existing downloader paths remain unchanged. No licensing,
checkout, installation telemetry, region spoofing, inspection-detection or
destructive cleaner code is copied or recreated.

This is independently authored source informed by documented behavior, not a
claim of a legally certified clean-room process or recovered original source.
The preserved publisher IPAs remain unchanged. The first private testing overlay
excludes the original TTKillerPlus add-on as a whole rather than patching its
license gate: its dylib, resource bundle and exclusively used nested Substrate
dependency are omitted. The containing app's separate framework copy remains.

## Current source slice

| Component | Implemented responsibility | Not established |
|---|---|---|
| Guest original-media selection | Bounded candidate lists, exact approved host matching, HTTPS-only URLs, no credentials/fragments, no thumbnail fallback or quality guessing. | CDN host policy, selected private-model adapters, downloader and real surface coverage. |
| Guest profile eligibility controls | Explicit opt-in installation on two exact runtime selectors with method ownership, ABI and image checks. Default behavior forwards originals. Synthetic macOS Apple compilation, ten fixture modes and standalone iPhoneOS object compilation pass. | Actual TikTok47 class/ABI/image eligibility and provider anonymity. |
| Independent device panel | Profile-tab long press, separate gear screen and opt-in settings using owned views in the existing guest window; fixed module-relative canonical image guard and bounded discovery. No extra UIWindow or native-controller presentation. | Actual tab-class mapping, phone interaction and remote-scene compatibility. The previous floating-window candidate blackened the guest on the owner's phone. |
| Portable transfer lease | Bounded versioned records, host-issued opaque ID/generation, ordered chunks, exact completion size and irreversible revocation. | IPC transport, OS isolation, media decoding, protected staging, confirmation and encrypted commit. |
| Incremental stream receiver | Fixed one-frame buffer; fragmented/coalesced input; encoded-byte and record budgets; validated tentative output; finish plus explicit host-observed EOF; fail-closed sink failure, overlap and reentrancy. | Filesystem outbox, actual media validation, protected staging and session-authorized import. |

The current device candidate wires only independent Profile-tab settings and local
profile eligibility controls into the existing Build24 TikTok47 host. There is
no native Save button or guest-to-Vault download wiring yet. New panel execution
and actual target eligibility require the owner's phone test; neither synthetic UIKit
tests nor package verification establish anonymous profile viewing.

## Media delivery contract

Media selection remains in the guest. URLs and their potentially signed query
strings must never be logged or sent to the host. A narrowly scoped adapter
must resolve a user-selected Feed, Story, Explore or Profile item; it must not
scan unrelated profiles or fetch private provider endpoints. Missing model
shapes fail visibly, without silently saving a thumbnail or different item.

The transport format carries only a version, record/media kind, opaque transfer
ID, generation, sequence, payload length and bounded media bytes. It has no
filesystem paths, commands, URLs, cookies, account identifiers or Vault keys.
A host-issued lease is not supplied by the guest and must be revoked on lock.
Its record parser is not an authentication system, encryption or an OS sandbox.
It cannot protect against a hostile guest that already knows its active lease.

The [outbox proposal](../../experiments/tkplus/TRANSPORT_DESIGN.md) uses only the
existing guest-data grant and host-derived transfer locations. It is the next
prototype direction, not a functioning bridge or a validated sandbox boundary.
Completed byte accounting must not keep pending confirmation/import authority
alive after lock; that authority is separate and remains session-revocable.
All access to each C lease must be serialized by its caller, including
cancellation and inspection. It is not a concurrent API; host lock must revoke
session/import authority independently of an in-flight accounting operation.
The incremental receiver's outer state, not its embedded lease, determines
whether EOF-checked byte accounting completed. Its sink writes are tentative:
discard them on failure, cancellation, revocation or host lock. Never feed from
storage overlapping the reader itself or retain its borrowed payload pointer.

The host must still validate actual media type and decode bounds, copy into
protected host-owned storage, request explicit confirmation under a current
Vault session and commit through the existing revocable importer. Size/type
fields from the guest are hints, not trusted proof. A missing final record,
failed decode, stale session or lock must prevent publication and remove only
owned transfer copies. Source media and existing archives must remain intact.

## Profile control limits

The first hook family covers eligibility getters, not general reporting,
network functions or asynchronous callbacks. When off, original implementations
must run exactly once with unchanged arguments. Enabling requires every selected
getter to be present, owned by the exact class, ABI compatible and implemented
in the expected guest image. A failed guard leaves controls unavailable; it must
not fall back to a broad hook or a raw code address.

Returning false from selected local getters does not prove every view report
is prevented. The UI must call this local profile-report suppression, not
guaranteed anonymous viewing. Story/message read controls are outside this first
slice. Settings must disclose scope and remain off by default.

## Validation and remaining integration

Synthetic tests accompany each source component. Portable C execution can be
checked on Windows without executing a proprietary guest. Foundation/Objective-C
fixtures require macOS and Apple tools; source review or string checks must not
be reported as an Apple build. Actual results are recorded in the project
`docs/TEST_REPORT.md`, not inferred from this design.

Public [Actions run 37072656873](https://github.com/Jaytay04/CalcVault/actions/runs/37072656873)
at `2c72f78` passes 16,502 portable transfer checks, the Foundation media fixture,
ten generated Objective-C profile modes and six static-reference tests with
Xcode16.4. The logs were reviewed. No proprietary guest, phone build or actual
download/import is exercised by this run.

Follow-up [run 37075550448](https://github.com/Jaytay04/CalcVault/actions/runs/37075550448)
at `ba8cd74` passes 67,745 incremental receiver checks and 16,502 transfer checks
normally and under macOS ASan/UBSan, plus the media/profile/reference regressions.
All four independent units also compile to verified arm64 iPhoneOS objects
using SDK18.5 with minimum iOS18.0. This is source compilation, not app linking
or real TikTok runtime coverage. An initial script argument-order error was
corrected before the successful full run; no validation gate was removed.

Integration still needs a fixed media-only guest-to-host transport, a trusted
TikTok47 image/ABI manifest, an independently reviewed CDN policy, real content
validation and revocable import wiring. Private assembly must be separate from
public source and preserve existing guest data and working artifacts. Signing,
startup, Highlights, downloads, portrait layout, lock/background/audio cessation,
host-file/Keychain controls and X/Instagram browser regressions need a fresh
owner-operated phone test. No success on those gates is claimed here.

The first device slice links in public [run 37079294023](https://github.com/Jaytay04/CalcVault/actions/runs/37079294023)
at `3ac57ee`, with SDK18.5 and minimum iOS18.0; parallel source regressions pass
in [run 37079294010](https://github.com/Jaytay04/CalcVault/actions/runs/37079294010).
Only independent source and synthetic fixtures enter CI. Local private assembly
produces a private testing IPA with complete member hash/CRC readback and
preserved host/data identity. Private-package fingerprint and size are recorded
only in its private receipt and ledger. This
is a testing derivative requiring SideStore re-signing, not a host rebuild or
a feature-complete release. The owner reports the first floating TK+ panel
blackened the guest. Its replacement uses Profile-tab long press, a gear entry
and own settings views. Actual entry and target eligibility remain owner-test
gates; native media delivery is still unwired.
