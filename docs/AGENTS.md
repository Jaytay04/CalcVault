# Project instructions — CalcVault

Read `IMPLEMENTATION_PLAN.md` before implementation. Use `TASKS.md` as the execution ledger. This is a personal SideStore iPhone app: a real calculator, an authenticated encrypted vault, and separate signed-in website profiles for TikTok, X/Twitter, and Instagram.

## Working method

Inspect the repository and existing instructions first. Preserve unrelated work. Do not overwrite global Codex configuration, delete user data, publish a repository, spend money, install paid services, or handle account credentials without explicit authorization. Make reversible local changes and keep scope tied to this plan.

Implement working vertical slices, not screenshots or placeholder buttons. Begin with Phase 0: project/build infrastructure, dummy-data crypto, lifecycle shielding, and a minimal three-profile web prototype. Continue into the next unblocked task after each gate; do not stop merely to rewrite the plan or ask about nonessential cosmetic choices.

Record assumptions and missing environment information in `docs/ENVIRONMENT.md`. Windows is an established editing environment; Mac access and the exact iPhone/iOS version are not established. Use the plan's provisional iOS 18 target until verified. Never report a macOS build, SideStore installation, biometric test, or live website login as passed without actual evidence.

Update `TASKS.md` and `docs/TEST_REPORT.md` after each meaningful slice. Distinguish implemented, automatically tested, device verified, blocked, and not tested. Preserve exact failure messages in sanitized reports. Continue independent work when a device or provider test is unavailable.

## Security boundaries

The calculator sequence is only a navigation secret. It must not be the vault's encryption key or the only authentication boundary. No hardcoded entry codes, app passphrases, recovery secrets, unprotected root keys, fast password-hash substitutes, or release unlock bypasses.

Use upstream, pinned cryptographic primitives; do not invent algorithms or silently weaken parameters. Maintain and test a versioned storage format. Protect content, filenames, note titles, thumbnails, metadata, and object keys. Disk-backed temporary previews are a documented exception requiring protection and lifecycle cleanup, not 'fully encrypted' files.

A Keychain read protected by the selected access policy must actually release the biometric convenience key. A standalone Face ID success Boolean is not enough. Keep the independent app-passphrase recovery path. Do not silently replace app-passphrase protection with the device passcode.

Fail closed on authentication/corruption and fail non-destructively on missing keys. Never replace a populated vault with an empty one after a read error. Backups and clean-install restore are release requirements. Do not auto-delete imported originals, implement failed-login auto-wipe, or call flash deletion irreversible.

The browser is not the vault. Persistent WebKit sessions remain browser-managed and are not automatically encrypted by the vault key. Use separate supported website-data stores, disclose persistence, support ephemeral mode, and implement awaited local-data reset. No cookie copying, private WebKit database manipulation, or generic native-JavaScript bridge.

Service sign-in happens only on genuine official HTTPS pages, manually operated by the owner. Never inspect password fields, intercept credentials, log cookies/URLs with secrets, spoof login forms, bypass provider restrictions, or submit account actions during automated testing. A Safari fallback does not prove an embedded login works.

Locking must cover private UI promptly, stop media, revoke the session, cancel private work, invalidate stale callbacks, and release sensitive state. Test the Face ID inactive/background race explicitly. Do not claim screenshot prevention or forensic invisibility.

## Implementation discipline

Keep calculator math independent of UI, authentication, and WebKit. Use explicit input sources and a bounded stateful entry detector; never a rolling suffix trigger across unrelated expressions. Keep correct secret entries out of history and restoration.

Freeze shared interfaces before parallel work. One integrator owns project configuration, dependencies, application state, and release gates. Parallel calculator, storage, and browser work is optional. Review security-sensitive changes from an independent perspective and record unresolved findings.

Use synthetic fixtures for tests and sanitized screenshots. Exact Apple Calculator parity requires an identified version and observed reference behavior. Third-party website compatibility is per service, login method, device, and date; do not guess.

Run applicable tests for every change. Check stream truncation/reordering, malicious headers, failed writes, cancelled imports, stale sessions, temporary-file cleanup, and backup corruption. Do not make green tests by disabling security, suppressing errors, or replacing production encryption with mocks.

## Delivery

Provide source, reproducible Xcode configuration, pinned dependencies, macOS build/test scripts, a device-target IPA only when actually built, checksums, SideStore instructions, and completed security/privacy/storage/test reports. Label remaining gaps. Do not claim the application is audited, unhackable, undetectable, or fully equivalent to native social clients.
