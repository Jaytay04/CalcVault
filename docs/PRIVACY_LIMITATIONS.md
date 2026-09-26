# Current privacy limitations

- The app is a prototype and has not been audited.
- A calculator appearance does not make installed software or its activity undetectable.
- Plain TAR archives are not encrypted and can expose names, sizes, metadata, and contents.
- The stored security-scoped bookmark may reveal external archive file-location metadata outside the encrypted vault.
- Persistent WebKit profiles may keep cookies, local storage, and caches outside vault encryption.
- The lifecycle cover concealed tested Files and Social app-switcher states on the target iPhone, but it is not screenshot prevention and has not been validated for every system interruption or private screen.
- Website operators, iOS, network observers, backups, storage reporting, and device analysis may reveal use.
- External browser fallback, if needed, does not transfer or prove an embedded WebKit session.
- The Phase 0 Keychain/crypto diagnostic and external TAR probe are not a recoverable vault or a backup.
- Phase 3 encrypted storage has automated adversarial coverage and a limited physical initialization/persistence checkpoint, but no independent security audit, encrypted backup/restore, or destructive installed-container corruption test.
- Phase 4 imports copy data into the encrypted vault and preserve the original. Files-provider sources, Photos originals, Recently Deleted items, synced libraries, device/cloud backups, and later exports can remain outside vault encryption; the app never automatically deletes them.
- Picker staging uses protected, backup-excluded app-owned temporary plaintext files. Successful import and cancellation remove them, and the manager removes leftovers on next launch, but a crash or forced termination can leave protected temporary plaintext until that cleanup runs.
- Text and note previews are limited to 2 MiB, images to 32 MiB, and PDFs to 64 MiB in memory. PDFKit receives data rather than a decrypted file, but its internal decoded-page/cache behavior is framework-managed and is not claimed to be perfectly zeroized.
- Strict preview mode is enabled by default and disables video playback. When the owner disables strict mode, an authenticated video is fully decrypted into a protected, backup-excluded, randomly named temporary plaintext file for native playback. Dismissal and lock request cleanup; a crash can defer cleanup until next launch.
- Explicit export intentionally crosses the vault boundary. The receiving application, Files provider, share extension, backups, or user can retain the unencrypted copy, and CalcVault cannot revoke it.
- Phase 4 simulator tests and declared disposable-fixture device paths pass. Direct inspection of protected temporary-file deletion, PDFKit internal caching, and iOS Data Protection internals was not performed. Continue using disposable synthetic fixtures only.
