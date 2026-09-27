# Synthetic LiveProcess device probe

This research fixture tests a synthetic native guest inside LiveContainer 3.8.0's actual `LiveProcess.appex` and normal guest bootstrap. It is separate from production CalcVault and contains no TikTok binary or real account data. Upstream is pinned to `e370a92dfc03ce109ebce00ed4a7cfc64ad1c801`; its AGPL-3.0 license applies to the adapted upstream component.

The previous simulator file-read observations do not diagnose a device sandbox defect: [Apple documents that Simulator does not enforce the application sandbox](https://developer.apple.com/videos/play/wwdc2019/418/). The simulator gate here tests build, packaging, guest loading, and visible UI only. The physical-device result is separate.

## Package and signing

The manual `native-social-liveprocess-device.yml` workflow builds one containing app with bundle identity `com.jaylintaylor.calcvault`, one `LiveProcess.appex`, and a synthetic guest dylib under `Frameworks`. The guest is patched before signing and its resources are packaged as a resource bundle, not a second installable app. The workflow uses ad-hoc signatures as input for SideStore re-signing; it never receives the owner's signing certificate or exported signed IPA. Only the generated extra upstream Share/Launch extensions are removed from the disposable build product.

The host and extension request a dedicated synthetic App Group, the app-ID Keychain control group, and one guest Keychain group. Only the host requests the explicit `.com.jaylintaylor.calcvault.hostonly` group. `FAKETEAMID` in the build entitlement fixture is a placeholder for SideStore to rewrite. Unsupported or absent effective groups must yield an inconclusive setup result, not an isolation pass.

## Phone test

This IPA replaces the current disposable Calculator/CalcVault test app under the same identity. It does not require another Home Screen app or removal of SideStore or Spotify. Keep the LiveProcess extension when SideStore asks. No signed IPA export or import is needed for this fixture.

1. Open **Native Probe** and use its prepare/launch control. Setup seeds only uniquely named synthetic file and Keychain fixtures. The host must successfully create and read back its controls.
2. Inside the guest, use the native tap button and boundary-test button. Capture the displayed pre-bookmark, post-bookmark, post-loader, and guest-entry results. Distinct process IDs establish that the guest did not run in the host process.
3. Close the guest panel and refresh the host report. The host verifies its synthetic sentinel has not changed. A denied read alone is insufficient if the control was missing or a write succeeded.

Only `EACCES`/`EPERM` file errors and the explicit Keychain missing-entitlement status are denial observations. Missing files/items, failed positive controls, missing bookmarks, or launch failures remain inconclusive. Any successful host-only read/write is a failed boundary on the tested phone configuration. The shared app-ID Keychain control is expected to remain readable where SideStore grants the same group.

The report concerns synthetic file/Keychain access at launch and after the real guest loader. Lifecycle revocation, media shutdown, refresh, real vault key migration, hostile guest code, and native TikTok compatibility remain later gates. This fixture is not a production security approval.
