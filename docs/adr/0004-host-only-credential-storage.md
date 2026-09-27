# ADR 0004: Host-only credential storage, without native guests

Status: implementation candidate, 2026-09-27. Signed-phone production-store verification pending.

## Evidence and scope

Build 15's owner-reported signed-phone test verified migration of disposable metadata and biometric-protected bytes, removal of old copies, denied guest access to the host-only copies, and blocked launch after cancelled authentication. This is not a production isolation certification. The owner requested continuing with the actual credential-store integration. This decision permits that narrowly scoped storage hardening; it does not approve adding LiveProcess, loader hooks, shared App Groups, or a TikTok binary to the production app. ADR 0003's native-guest lifecycle gates remain open.

## Decision

Both concrete credential stores now use `HostOnlyKeychainStorage`. The vault initialization marker uses the same metadata store and follows the same route. Every credential query names an exact service, account, nonsynchronizing state and access group. New writes target only the host-only group and refuse existing copies. Reads and metadata updates first migrate supported legacy copies using copy, byte verification, source recheck and source removal. Conflicts across any supported sources/destination fail before migration starts; interrupted copies are retryable. Explicit deletion remains exact-item deletion, not broad service or group deletion. A process-wide lock serializes these operations; this does not coordinate another process, and no guest is enabled here.

The signing prefix comes from a unique, non-secret public-Keychain probe, never a hardcoded developer Team ID or private `SecTask` API. Only the expected base/runtime bundle-ID default groups are accepted. The runtime app-ID and base-ID legacy candidates, when different, are separately positive-controlled along with the host-only destination. This accounts for SideStore's bundle suffix and the fact that adding explicit entitlements can change the default group. All controls must add, read back and delete their own fixture before credentials are accessed. Unexpected identity or unavailable groups fail visibly rather than implying an empty configuration. Other signing-team migrations are not supported by guessing or broad queries.

Metadata migration needs no biometric prompt. The root-key migration occurs during an explicit biometric unlock using its authentication context; the passphrase path does not trigger it. A passphrase-only user may therefore still have an old biometric copy, and a future native-guest launch must independently require its removal. New biometric copies use `WhenPasscodeSetThisDeviceOnly` with `biometryCurrentSet`. Reads also check accessibility, group, and presence of an access-control object. Public attributes do not independently certify an existing item's enrolled-set constraints; enrollment changes remain a device test. The context is invalidated when the unlock attempt completes.

The device IPA is ad-hoc signed with placeholder application/group identities so SideStore can read the source entitlement blob and rewrite its prefix. It contains no real signing material, extension or App Group. The historical `CalcVault-unsigned.ipa` filename is retained for workflow compatibility; it now means a SideStore re-signing candidate, not an unsigned Mach-O or an installable Apple-signed app. CI verifies the exact entitlement set and order, valid ad-hoc signature, one app, no extensions and no P12/PFX exports. Use patched SideStore `.cv1` for the owner test.

## Validation and remaining gates

Fake-store tests cover routing, conflicts, cancellation/error propagation, retry, wrapper protection policy and identity controls. They do not validate Security's actual queries, biometric behavior, post-signing identities or device sandboxing. The next phone checks are preservation of the entry sequence, passphrase and Face ID unlock, cancellation, dummy-note persistence across restart and refresh, and explicit build identification under Security. If startup reports a credential error, stop; do not reenroll or delete the installation to bypass it.

Native guest shutdown on lock/background, stale callback revocation, real TikTok loading, and compatibility remain separate work. No vault files or archive formats are changed by this slice.

References: Apple's [Keychain group behavior](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) and [return-result keys](https://developer.apple.com/documentation/security/item-return-result-keys).
