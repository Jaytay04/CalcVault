# Synthetic native guest feasibility probe

This disposable app contains one SwiftUI screen and a synthetic local-file canary. It does not contain CalcVault source, a vault key, a TikTok IPA, social credentials, network code, or private media. It is **not** a replacement for the current CalcVault app.

The first question is whether a native app guest can launch and interact in a LiveContainer-style host. The second, separate question is whether a host containing vault plaintext can remain isolated from that guest. Passing the first test does **not** answer the second.

## Pinned upstream reference

Prototype against [LiveContainer 3.8.0](https://github.com/LiveContainer/LiveContainer/releases/tag/3.8.0), source commit `e370a92dfc03ce109ebce00ed4a7cfc64ad1c801`. Its [native guest loader](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/README.md#how-does-it-work) modifies the guest executable and uses runtime hooks; the [LiveProcess extension](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveProcess/Info.plist) is a classic app extension in `PlugIns`, unlike the Xcode 26 ExtensionKit UI extension tested in the adjacent experiment. Do not transfer the earlier ExtensionKit signing or isolation result to this architecture.

LiveContainer's [multitask guide](https://livecontainer.github.io/docs/guides/multitask) lists iOS 16+ and an installation retaining app extensions. Thus an iOS 26 upgrade is not a prerequisite for this *initial* guest-launch probe. The future CalcVault integration, SideStore signing, TikTok compatibility, and actual iOS-version choice remain unverified.

## Build and evidence gate

When macOS CI is available, the manual `native-social-guest-fixture.yml` workflow generates this separate project with XcodeGen 2.46.0 and compiles `SyntheticNativeGuest` for the iOS simulator and unsigned device target. It does not install, sign, or publish an IPA. A later, separate LiveContainer host trial would package only this disposable guest and record the Xcode, SDK, simulator, LiveContainer revision, and artifact digest. Do not upload a real social IPA or sign into an account during the synthetic test.

Expected guest result: the native button increments once per tap, and the canary reports `Canary round trip passed`. That proves only guest execution and access to its own selected data location. Before adapting the host, use synthetic vault-file and Keychain sentinels to test guest-to-host access, both before and after lock. The security gate fails if the guest can read host plaintext, reach host-only keys, invoke vault operations, or keep the host's private UI exposed on backgrounding. Ciphertext visibility alone is not proof of plaintext compromise, but guest write/delete access still matters for integrity and availability.

The pinned LiveContainer host and `LiveProcess` entitlement templates both request the same 128 Keychain access groups and App Group placeholders. Do not reuse those shared groups for the vault root key or infer isolation from a separate process name. Compare **effective post-signing** entitlements and perform an attempted Keychain read from the guest before any production design is considered.

No CI build or simulator/device run has occurred for this fixture. The repository's GitHub Actions account currently rejects new jobs for an account-payment or spending-limit restriction; do not dispatch another run until that is resolved. A physical-device trial would also need a separately reviewed signing and App ID plan. Do not remove Spotify, reinstall CalcVault, upgrade iOS, or touch the populated vault for this probe.
