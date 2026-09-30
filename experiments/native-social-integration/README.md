# Combined CalcVault native integration candidate

Build 23 follows the owner's 22.2 signed-phone synthetic denial, launch,
cancellation, explicit-lock, browser/download and refresh observations. Public
CI still generates **only a synthetic guest**. A separate local-only merger
copies the unchanged immutable framework and descriptor from the checksum-pinned
20.6 private candidate; it does not patch guest code, sign or install anything.
The two host package variants have explicit kind/stage metadata. Before preparing
the runtime, the host requires that metadata to match the approved descriptor
identity/version. Neither package recognition nor a biometric Boolean authorizes
launch independently of the complete credential/session checks.

The Build 23 guest data directory is `integration-native-23`, separate from both
`integration-synthetic-22` and the old 20.6 guest. No existing guest data or login
state is copied. Guest data is not vault-encrypted. The private candidate is not
physically accepted until its own startup, playback, lock/background and browser
checks pass; the working 20.6 IPA remains unchanged.

Build 22.2 adds an explicit biometric retry only when the initial metadata scan
reports interaction-not-allowed for the fixed host-only biometric item. A fresh
biometrics-only context is used for a complete second scan; a successful prompt
alone cannot authorize launch. Both scans prohibit implicit Keychain prompts
and never request credential values. The prompt exception is session-bound,
limited to 45 seconds and revoked by background/lock; launch waits for foreground.
Cancellation fails closed. No credential reset or migration is performed.

Build 22.1 adds bounded launch-failure diagnostics to the same synthetic-only
integration. If blocked, remain unlocked and choose Refresh native report;
report only its fixed stage/reason codes. Credential values, raw errors,
identities and paths are excluded. Do not reset credentials to force a pass.
The existing synthetic data directory and launch protections are unchanged.

Build 22 combines the existing CalcVault UI/security/browser code with the
reviewed immutable-framework LiveProcess route. It contains only the generated
synthetic guest, not TikTok. Keep the known-good private 20.6 IPA unchanged.

## Boundary

- `CalcVaultKit.framework` is linked by the containing UI framework, not the
  guest extension. This packaging distinction does not itself prove isolation.
- CalcVault owns authentication and session generation. Each launch rescans the
  exact credential inventory, requires host-only destination metadata, and
  rejects late results after session invalidation. No credential values are
  passed to the runtime.
- Only one runtime attempt is permitted per host launch. Lock/inactivity covers
  and revokes synchronously. Reauthentication allows diagnostic report access,
  not reuse of a revoked guest.
- The fixed `integration-native-23` data directory is separate from the old
  private research guest. Exact path guards and the two narrow framework/data
  bookmarks remain in place. No vault bookmark or command bridge is introduced.
- The host does not run upstream cookie/preferences restoration, self-tweaks,
  selected-guest dispatch, JIT/intent handlers or model termination callbacks.
  Host file sharing and inherited broad ATS/background exceptions are removed.
- The historical biometric migration experiment is not rerun or falsely marked
  successful. Independent synthetic file/Keychain controls remain. Use the
  reviewed SideStore no-certificate-export build for phone re-signing.

## Build and evidence

Dispatch `native-social-liveprocess-device.yml` with `integration_guest=true` on
the intended source ref. The reusable workflow pins upstream source and Xcode,
builds each SDK separately, prepatches only generated synthetic Mach-O payloads
before signing, stages the kit, verifies signatures/linkage/entitlements and
packages one containing app with one LiveProcess extension.

The simulator smoke checks the locked CalcVault root without an authentication
bypass or automatic guest launch. It is not a guest-execution or sandbox test.
The ordinary `ios-build.yml` suite separately tests the session/credential gates.
The owner supplied the bounded 22.2 phone checks before this private-candidate
slice. Build 23 is a new candidate; unchanged code does not substitute for its
own physical startup and lifecycle acceptance.

On the phone, unlock normally and use Security > Native integration test. After
locking the synthetic guest, reauthenticate and choose Refresh native report.
Restart CalcVault before another guest attempt. Use disposable vault fixtures;
these observations are not a security certification.

## Private assembly

After verifying the CI host checksum and its build evidence, use the local
`merge-private-guest.py` tool with the host IPA, the original known-good 20.6 IPA,
a new output IPA path and `--host-sha256` set to the verified CI digest. The
production CLI pins the 20.6 input digest internally; it offers no guest-digest
override. Tests use disposable synthetic fixtures, never the private input.

The output is a SideStore re-signing candidate. Its copied outer/nested signature
metadata is not asserted valid after assembly. Readback proves guest file bytes
match the pinned source before signing; subsequent SideStore signing necessarily
refreshes signatures. Do not upload the input or merged IPA to public CI/source.
Keep the previous artifacts unchanged and publish only to the verified-private
download repository when authorized.

## Temporary RX-disabled comparison

The owner approved a narrowly scoped Highlights comparison using the delivered
Build 23 package. `prepare-rx-disabled.py INPUT.ipa NEW_OUTPUT.ipa` accepts only
the digest-pinned input and omits exactly the bundled RX dylib. It does not patch
the guest executable or licensing, rewrite metadata, add code, change the guest
data directory, or modify either an existing output or the original IPA.
Every remaining member is stream-copied and digest-verified before publication.
The fixed host/guest identity checks and exactly one weak RX dependency must pass.

The optional dependency is not proof that the guest will launch without RX:
[Apple's weak-linking guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/WeakLinking.html)
requires callers to tolerate unavailable symbols. The signed-phone comparison
must establish actual startup and behavior. Copied signature metadata is not a
valid final signature; SideStore must re-sign the whole candidate.

Install in place without deleting CalcVault. The host still reports Build 23;
identify this candidate by its RX-disabled artifact name and checksum. This
comparison intentionally keeps the existing guest data-directory setting and
does not clear preferences or sessions. It isolates current RX library loading,
not all possible effects of previously stored preferences or remote rollout
state. Preserve the known-good download so RX can be restored afterward.
Check the same profile/account for Highlights, playback/layout and Lock/Home
audio cessation. Do not mistake package checks for a successful device test.

## Opt-in Highlights diagnostic candidate

Dispatch the registered `native-social-liveprocess-device.yml` workflow with
`integration_guest=true` and `highlights_diagnostics=true`. Its reusable
`native-social-integration.yml` workflow receives the default-off input, which
adds only the approved observer to generated integration-host sources. Its default
is false. The report marker is `integration-23-highlights1`; the containing app
identity/build contract and `integration-native-23` data directory stay unchanged.
Public CI still builds synthetic code only. Use the existing pinned local merger
to retain all RX-enabled guest bytes; preserve both previous candidate IPAs.

The observer aggregates only results of naturally occurring, exact-signature
Highlights calls and bounded view geometry. It does not invoke a provider API,
force configuration, fetch data, copy sessions or collect profile/media strings.
No observed call means unknown, not false. Swift direct calls may bypass Objective-C
instrumentation; no mounted component or visible cell observation alone cannot
prove missing server data or a disabled feature. A non-nil model does not establish
a nonempty or eligible Highlights collection. Synthetic tests and compilation
cannot establish real TikTok compatibility.

Each `CVLP_HIGHLIGHTS` line uses a fixed numeric schema. Indices 0 through 5 map
to consumption eligibility, creation eligibility, model presence, component mount,
collection UI update and collection height. `st` is installation status (0 unknown,
1 installed, 2 missing, 3 inherited/skipped, 4 ABI mismatch, 5 ambiguous,
6 incomplete lookup, 7 installation failure); `c` is a saturating call count.
`l0`/`l1`/`l2` are last observed booleans, with -1 meaning unknown. `l5` is the
last finite height; `l3`/`l4` are unused. Tree fields report traversal/window/row
counts and the first matched cell's own hidden/alpha/size values. They do not
establish effective visibility through ancestors or server eligibility. `trunc=1`
or `err=1` means the tree observation is incomplete; zero matched rows must not
be interpreted as proof that no Highlights implementation exists.

For a diagnostic phone run, open native TikTok and navigate to the comparison
profile within two minutes. Leave it visible for at least 15 seconds, then Lock.
Unlock CalcVault and refresh the native report; provide the `CVLP_HIGHLIGHTS`
lines, the report marker, and whether playback stopped/calculator cover appeared.
Repeat after a cold launch if the first run did not reach the profile in time.
Do not clear data, change accounts or supply profile content for this check.
