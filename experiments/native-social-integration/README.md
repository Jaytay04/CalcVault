# Combined CalcVault synthetic integration

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
- The fixed `integration-synthetic-22` data directory is separate from the old
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
Signed-phone guest launch, denial probes, media stop, cover, browser regressions
and SideStore refresh must still be checked before private guest inclusion.

On the phone, unlock normally and use Security > Native integration test. After
locking the synthetic guest, reauthenticate and choose Refresh native report.
Restart CalcVault before another guest attempt. Use disposable vault fixtures;
these observations are not a security certification.
