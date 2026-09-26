# SideStore installation — Phase 0

The latest primary IPA from workflow run `35470420463` has been installed in place, signed, refreshed, and launched through SideStore. Its physical crypto, disposable protected-Keychain, privacy-cover, and WebKit media-pause checks passed. Earlier IPAs are superseded and must not be reused.

1. On macOS with Xcode and XcodeGen 2.46.0, run `sh scripts/test-macos.sh`.
2. Run `sh scripts/build-unsigned-ipa.sh`. Continue only if its artifact verification passes and it prints an IPA path plus SHA-256 digest.
3. Transfer `build/artifacts/CalcVault-unsigned.ipa` and its `.sha256` file to the iPhone without adding signing secrets to the repository.
4. In SideStore, import and sign the IPA using the owner's existing account. Record SideStore's effective bundle identifier and entitlements without recording account data.
5. Launch Calculator and run the on-screen dummy crypto/Keychain diagnostic.
6. Download `fixtures/phase0-authoritative.tar` from the repository into Files. Verify its SHA-256 from `fixtures/README.md`, select it in the app, and confirm the two synthetic entries are listed. Then rename or move the TAR in Files and confirm the app reports the authoritative archive unavailable instead of showing or creating an empty archive.
7. Run the lifecycle and per-service checks in `TEST_REPORT.md` and `SOCIAL_COMPATIBILITY.md`.

Use the shipped identity for normal tests. The `RecoveryTest` configuration uses the one additional App ID for a side-by-side disposable install; it is not a second shipped app. Registering/using it and any resulting app-slot impact require owner review.

Do not delete a populated app to troubleshoot signing. Do not remove the only valid archive or erase device data. Ask before any destructive device action. The prototype never deletes Photos originals automatically.
