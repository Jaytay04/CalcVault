# Synthetic signed-device boundary probe

This is a disposable host with one `LiveProcess`-style classic extension. It tests whether the extension can read a synthetic host-only Application Support file and a random synthetic Keychain item. It does not contain or inspect CalcVault vault data, social credentials, a TikTok IPA, or a guest binary.

The host's base bundle ID is `com.jaylintaylor.calcvault` so SideStore can attempt to replace the existing CalcVault install instead of consuming another active-app slot. The extension has its own bundle ID inside the IPA. SideStore's **Keep All Extensions (Use Main Profile)** mode may sign both with one registered App ID; this must be verified on the owner's device. Reusing the profile is a signing experiment, not a confidentiality claim.

The extension is invoked using the same nonpublic `NSExtension` class and `com.apple.ar.viewer` extension point used by the pinned LiveContainer 3.8.0 research path. This probe is not production code. Passing it would be a necessary baseline, not proof that a native TikTok guest is isolated after LiveContainer's loader and hooks run.

## Evidence gates

1. Manual CI builds the separate simulator host and unsigned `iphoneos` host plus embedded extension, smoke-tests that a separate extension process returns a result item, and uploads an unsigned IPA with SHA-256. Ad-hoc simulator signing may lack the Keychain entitlement; that check is explicitly **NOT TESTED** in this case. A simulator read is **not** an isolation pass.
2. Before phone installation, verify the IPA's base bundle ID and embedded extension, download/hash, and preserve any CalcVault data or sessions the owner wants. The probe does not export or recover them.
3. In SideStore, select **Keep All Extensions (Use Main Profile)**. Stop if it proposes another App ID, another active app, removal of Spotify, or deletion of CalcVault. Do not use an extension-stripping option: that makes the test inconclusive.
4. Open **CalcVault Boundary Probe**. It runs once automatically; **Run test again** retries. A result must show distinct host and extension PIDs plus both access statuses. A screenshot of this synthetic-only screen is sufficient for the first device observation.
5. On the signed phone, fixture creation must succeed first. `READABLE` for either host file or Keychain item fails that boundary. `NOT READABLE` for both is a provisional pass only for this minimal extension and its actual signing mode. Missing extension, no report, timeout, or unavailable fixture is inconclusive. Never infer real vault safety from installation or compilation alone.

The probe creates only a uniquely named synthetic file and a Keychain item under the exact test service `org.example.calcvault.synthetic-boundary-probe`. It removes those fixtures after a result or timeout. It does not enumerate, rewrite, or delete other app data. An interrupted run may leave a synthetic item; the next run replaces only that exact test item.

Because this build uses CalcVault's base ID, installing it can replace the existing app and may affect local settings and browser sessions. It must not be installed until the owner reviews the artifact and accepts that tradeoff. Restore the ordinary CalcVault build through an in-place SideStore install with the same signed identity; do not delete the app as a troubleshooting shortcut.
