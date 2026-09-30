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
