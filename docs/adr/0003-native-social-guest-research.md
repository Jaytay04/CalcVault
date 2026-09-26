# ADR 0003: Isolated native-social guest research

Status: experimental authorization only, 2026-09-25. Not approved for the shipping CalcVault target.

## Context

The owner requires native TikTok inside CalcVault to access features absent from TikTok's desktop website, with X and Instagram possible later. They approved a **separate synthetic prototype** using a LiveContainer-style native guest, even though this research requires runtime hooks and an additional extension outside the original implementation plan. This does not authorize modifying the populated install, importing a real social IPA, signing into a real account, upgrading iOS, changing App IDs on the device, or relaxing the vault's confidentiality gate.

The previous Xcode 26 ExtensionKit UI experiment failed its simulator vault-isolation assertion. The host directly read the extension's synthetic file even after ad-hoc signing, and `EnhancedSecurity(true)` conflicts with `UserInterface(true)`. That does not settle LiveContainer's different architecture: it uses a classic `LiveProcess.appex` in `PlugIns` and executable-loading hooks. Its [3.8.0 source](https://github.com/LiveContainer/LiveContainer/tree/e370a92dfc03ce109ebce00ed4a7cfc64ad1c801) is pinned for analysis. Its [documentation](https://livecontainer.github.io/docs/guides/multitask) says multitasking requires iOS 16+ and retained extensions; iOS 26 is not a prerequisite for the initial synthetic launch test.

## Decision for the research spike

Keep the shipping project untouched. Build the independent `experiments/native-social-guest` app as the first guest fixture. If native launch works in a disposable host, adapt a separate host prototype with synthetic vault sentinels. Vault decryption, key access, file mutation, background cover, lock, and guest termination must then be adversarially tested on simulator and a signed physical device before any production integration. A synthetic guest launch by itself does not establish a secure native TikTok integration.

The candidate placement is vault code in the host and guest code in a separate `LiveProcess`-style extension. This is a hypothesis, not an isolation claim. LiveContainer's own [README](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/README.md#limitations) warns ordinary guests are not mutually sandboxed, and its [extension metadata](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveProcess/Info.plist) uses nonstandard extension/XPC configuration. It also requires code review under AGPL-3.0 before adaptation. The guest must never receive vault keys or a vault-command bridge. App Groups, security-scoped bookmarks, Keychain access groups, and signing-profile reuse must be treated as possible cross-boundary access, not presumed safe defaults.

At the pinned revision, the [host entitlement template](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/entitlements.xml) and [LiveProcess entitlement template](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveProcess/LiveProcess.entitlements) both enumerate the same 128 `com.kdt.livecontainer.shared` Keychain access groups and the same SideStore/AltStore App Group placeholders. This source comparison is a concrete warning, not proof of effective post-signing entitlements. A CalcVault vault key cannot be stored in any group granted to the guest extension; a host-only group and distinct effective provisioning would need to be demonstrated before importing even a synthetic guest into a vault host.

The SideStore `PlugIns` discovery issue is different from the earlier `Extensions`-directory problem. LiveContainer documents an installer option to [retain extensions using the main profile](https://livecontainer.github.io/docs/installation/lc_sidestore), but that is not proof that CalcVault's existing SideStore version, entitlement set, and App ID budget can sign and refresh this design without a new identity. Measure the resulting registered IDs and effective entitlements before any device plan. Do not delete another app to free a slot by assumption.

## Exit criteria

1. Native synthetic guest launches inside one disposable host and accepts input; simulator and device evidence are recorded separately.
2. Synthetic guest cannot obtain host plaintext, host-only Keychain key, or vault operation authority; attempted file modification cannot silently replace the authoritative archive. Repeat after background/lock and with all required signing entitlements.
3. Guest lifecycle, media/audio stop, privacy cover, and return to calculator are verified without leaking a guest scene to the app switcher.
4. SideStore in-place refresh and App ID/entitlement effects are measured using only disposable data. TikTok IPA compatibility and owner-operated login are later, separately consented tests.

Any failed security criterion blocks production integration; a workaround must address the boundary rather than hiding the failure. X and Instagram remain future guests under the same gates, not automatic additions.

## Simulator finding: same-process launch

Run [36217778382](https://github.com/Jaytay04/CalcVault/actions/runs/36217778382) verified native guest button interaction and a synthetic canary round trip, then observed the guest read a synthetic host-only Application Support file. The test's isolation assertion failed. This rules out treating the tested same-process LiveContainer launch as an isolated vault/social boundary. It does not prove or disprove a separately sandboxed `LiveProcess` extension, which still requires its own file, Keychain, and effective-entitlement probes before any production consideration. No real vault data or TikTok code was involved.

## Simulator finding: `LiveProcess` with shared App Group

Run [36220296477](https://github.com/Jaytay04/CalcVault/actions/runs/36220296477) launched `LiveProcess` in a process distinct from the host, but its synthetic host-file read succeeded after guest bookmark activation. Both ad-hoc-signed simulator bundles carried the same synthetic App Group. This fails the host-file boundary for that configuration; process separation alone is not sufficient evidence of vault isolation. The probe returned before executing guest code. Signed-device/effective-entitlement tests are required before generalizing to physical iOS.

The no-shared-App-Group control, [run 36220860618](https://github.com/Jaytay04/CalcVault/actions/runs/36220860618), still read the host-only synthetic file from the distinct `LiveProcess` PID. Effective ad-hoc simulator entitlements showed an empty extension dictionary, so a shared App Group was not the sole cause. The [pre-bookmark control](https://github.com/Jaytay04/CalcVault/actions/runs/36221552703) also read that file before any guest bookmark was activated; bookmarks were not required for this simulator read. A foreign-app-container control is the next scope check. None of these outcomes can be generalized to physical SideStore signing. Native guest execution and host-only Keychain protection remain untested, and production integration is not approved.
