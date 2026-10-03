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

The Profile-tab replacement links and runs its synthetic iOS settings fixture
in [run 37084180710](https://github.com/Jaytay04/CalcVault/actions/runs/37084180710),
with regressions passing in
[run 37084180711](https://github.com/Jaytay04/CalcVault/actions/runs/37084180711),
at `a6d49e9`. Private packaging and complete readback pass. The fixture invokes
controller actions rather than physical touches; real tab mapping, touch
arbitration and remote-scene compatibility remain owner-test gates.

The owner subsequently reports that test2's Profile long press does not work.
Its fixture defined both exact expected classes, so its PASS did not validate
the real class family or container. The corrective test removes the unverified
TTKTabBar dependency and accepts the fixed Profile-button base class or derived
classes only when every class down to that base belongs to the canonical guest
image. Unique visible target, bounded traversal and lifecycle checks remain.
No label, screen-region or account-model fallback is authorized. A fresh phone
test is still required; this is not evidence of a working entry yet.

That corrective candidate is withheld. Targeted class metadata links the base
to AWESlidingTabButton and Video/Like/Favourite descendants, suggesting the tabs
inside a profile rather than the requested bottom navigation tab. View containment
is not established by metadata. Further work must trace the original installer's
actual target selection and image ownership, not treat the base name as proof.
No test3 IPA or device result is claimed.

## Verified original Profile entry

Read-only disassembly of the preserved original add-on establishes a different
entry protocol. Its exact `TTKTabBar` registration hooks `layoutSubviews` and
`reload`. Layout calls the saved original implementation before the installer;
reload schedules its installer on the main queue. The installer reads the bar's
`buttons` collection, requires at least five entries, selects index four and
requires a UIView. It enables interaction, installs a 0.4-second long press and
uses an associated object to avoid duplicate recognizers. Its handler acts only
in the began state. A captured alert-action block calls
`openRootOptionsController`; the handler itself presents an action sheet, so
this does not establish the exact rendering of the owner's gear-only screenshot.

The independent replacement source uses that observed navigation collection and
index, not an inner-profile button name or a screen coordinate. Only the exact
trusted tab-bar family and its image/ABI-checked `buttons` UI getter are eligible.
A filtered recognizer on the stable bar will resolve the current fifth button
before accepting a touch and again before opening our own gear/settings views.
This deliberately avoids copying the original layout hooks, action bodies or
licensing logic. Lock cleanup, ambiguity rejection and explicit opt-in remain.

Only eligible visible bars count toward ambiguity. The getter's method list,
array size and view traversal are bounded; getter/array exceptions fail closed.
The accepted item is captured weakly at touch start and must still equal a fresh
selection at began and before drawing. Disabled native items are rejected rather
than enabled as in the original. A whole-bar replacement after the initial
bounded discovery is not automatically hooked: foreground activation reacquires
it. Stable-bar child replacement is handled without copying layout/reload hooks.
These are deliberate differences and compatibility limits, not claims of exact
replication. Apple and phone execution remain separately recorded test gates.

Fresh direct chained-pointer parsing positively establishes TTKTabBar in the
native MusicallyCore class list. Its class object is at 0x3023d628, class_ro at
0x3023d5c8 and name pointer at 0x25357080 in __cstring. An earlier parser path's
partial-name result did not reproduce and is withdrawn; it was not a Swift or
runtime-absence finding. Runtime activation, actual view containment and touch
delivery remain phone tests. Missing or incompatible runtime classes must still
fail closed; synthetic fixtures cannot prove phone compatibility.

TTKTabBar directly declares the `buttons` getter with type encoding `@16@0:8`
(object return, self and selector only), implementation VA 0x15babb48. The
replacement validates runtime metadata and image ownership, never that raw
address. The getter body was not inspected; the original installer's use of
its result and runtime array/view checks establish the narrow UI protocol.

## Profile entry diagnostic follow up

The owner reports that profile-settings-test3 still does not respond to the
bottom Profile hold. Its synthetic UIKit PASS does not establish compatibility
with native startup or real touches. Earlier guest geometry reports show
activation notifications before visible windows and a startup inactive
transition. The module starts discovery only while active and cancels on
inactivity, without a window-readiness retry. A missed readiness interval is a
hypothesis; loading, canonical image guards, getter validation and touch routing
remain possible causes.

The next candidate is diagnostic-only. It preserves target selection, discovery
timing, lifecycle cleanup, ambiguity rejection and opt-in policy. Diagnostics
use fixed labels and bounded numeric counters, not paths, runtime class names,
account models, URLs, media or signing data. They use the existing guest report
method rather than a new filesystem channel or host capability.

Static metadata in the pinned host package establishes that CVLPProbe is defined
in the containing app's LiveContainerShared framework, not the LiveProcess main
executable. Its metaclass declares recordGuestDiagnostic: with encoding
`v24@0:8@16`: void return, self, selector and one object argument. The producer
must validate that exact class-method ABI and both class/implementation image
ownership before sending a sanitized line. Static package metadata is not proof
that the runtime sink will resolve or that a phone report will contain a line.

The fixed marker is `CVLP_GUEST_GEOMETRY phase=tkp-entry version=4`. Emission
has a process-wide budget of 24 records and a 320-byte formatting buffer.
Counters saturate at 9,999. Discovery emits changes, selected tick milestones
(1, 4, 16 and 64) and its existing terminal event, rather than every 0.25-second
tick. No new timer or discovery retry is introduced. Exhaustion stops diagnostic
delivery, not lifecycle cleanup. The testing macro substitutes only the synthetic
fixture executable's sink image and is absent from the phone module.

| Event code | Meaning |
| --- | --- |
| 1 | Module constructor |
| 2 | Startup requested |
| 3 | Startup dispatched on the main queue |
| 4 | Discovery start or inactive refusal |
| 5 | Discovery outcome changed |
| 6 | Existing discovery tick milestone |
| 7 | Existing discovery deadline |
| 8 | Lifecycle cleanup completed |
| 9 | Touch accepted or rejected |
| 10 | Began handler accepted or rejected |
| 11 | Own gear screen drawn |

Reason codes are: 0 none, 1 constructor, 2 startup requested, 3 main-queue
startup, 4 inactive, 5 image rejection, 6 class rejection, 7 getter rejection,
8 view rejection, 9 array rejection, 10 no eligible bar, 11 ambiguity,
12 traversal bounds, 13 recognizer installed, 14 touch accepted, 15 touch
rejected, 16 interaction-context rejection, 17 deadline, 18 lifecycle cleanup
and 19 gear drawn. Counter fields summarize only these guarded UI decisions;
they do not identify any underlying content. A reason is an observed branch,
not a diagnosis of its upstream cause.

## Runtime class rejection follow up

The owner diagnostic4 report establishes constructor, main-queue startup and
discovery execution, followed by 110 reason-6 class rejections. No recognizer
or gear view was installed. Startup readiness therefore does not explain this
attempt. The static class metadata belongs to the same pinned guest input; the
fixed loader route disables its conditional image-hiding behavior. Neither
fact proves which runtime subcondition failed.

The same package's superclass chained bind resolves to UITabBar, consistent
with UIView ancestry. This static result does not replace runtime validation.

The diagnostic5 phone report has `cls_status=9`: the looked-up base passes.
Reason 6 is also emitted during visible-view traversal when a derived tab-bar
class fails the strict same-image chain check. That later site accounts for
the new report; reason 6 alone did not establish a pre-traversal failure.
The actual subclass is not identified. Runtime-generated wrappers and a
packaged subclass in another image remain hypotheses, not diagnoses.

Diagnostic5 preserves the exact class/image acceptance predicate and adds the
latest numeric `cls_status` from the initial class gate to version-5 records.
Only status 9 accepts a class; all other statuses still fail closed. No path,
class name, address or account content is emitted. The existing 24-record cap,
320-byte buffer, discovery schedule, getter guards, target checks and lifecycle
cleanup remain unchanged. Test-only wrappers exercise the same classifier and
are excluded from the device module.

| Class status | Meaning |
| --- | --- |
| 0 | Initial class gate not evaluated yet |
| 1 | Expected class lookup returned nil |
| 2 | Candidate is a metaclass |
| 3 | Expected image URL unavailable |
| 4 | Candidate does not reach UIView within the existing depth bound |
| 5 | Class image name unavailable or empty |
| 6 | Class image path cannot be canonicalized |
| 7 | Expected image path cannot be canonicalized |
| 8 | Canonical class image differs from expected image |
| 9 | Exact canonical image match and UIView ancestry |

Diagnostic6 retains `cls_status` for the base result and adds `cs` for the
first failed image status in a rejected candidate's class chain and `cd` for
its zero-based superclass-hop depth. Both are zero when not evaluated. The
status codes above are reused; no class names, image paths or addresses are
reported. The strict chain acceptance remains unchanged. A synthetic dynamic
subclass inheriting the valid base getter must still be rejected without a
gesture: getter provenance alone is not substituted for class ownership.

The gray search/context banner in the supplied screenshot belongs to native
TikTok UI. Its reported position change has not been measured against a matched
baseline. Diagnostic4 installed no independent overlay; diagnostic5 does not
alter native window frames, safe areas, constraints or banner layout. The older
add-on had tab-spacing hooks, but their removal is not established as the cause
of this reported movement.
