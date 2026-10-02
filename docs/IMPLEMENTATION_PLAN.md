# CalcVault — Codex Implementation Plan

**Prepared:** September 16, 2026  
**Owner:** Private project maintainer  
**Deliverable:** A personally sideloaded iPhone application, not an App Store submission.  
**Status:** Implementation specification. No application, signed IPA, security audit, or live social-login test has been completed by preparing this plan.

## 1. Product objective and interpretation

Build one native iPhone app with three deliberately separate areas: a convincing, functional iOS Calculator-style public interface; an authenticated, encrypted private vault; and an authenticated browser workspace for the owner's TikTok, X/Twitter, and Instagram accounts.

The public calculator must be useful on its own. A user-configured numeric sequence followed by `=` requests entry to the private area. The sequence is a discreet navigation mechanism, not the encryption password. The recommended default then authenticates with Face ID or an independent strong vault passphrase. No secret value is to be hardcoded in source, build configuration, or the distributed IPA.

Inside the private area, provide **Vault**, **Social**, and **Settings**, with a persistent, immediately available **return to calculator and lock** action. Vault contains files, photos, videos, and private notes. Social contains three independent browser profiles pointing at the services' official websites. The owner signs in directly to those websites.

This is not a way to run the three companies' native apps inside another app. iOS app sandboxing remains applicable to personally sideloaded software. The proposed integration is web browsing, not embedding installed apps, importing their sessions, or recreating their private APIs. [S03, S04]

### Working assumptions

Use Swift and SwiftUI, with UIKit integration where lifecycle timing, media presentation, or WebKit requires it. Start with an **iOS 18.0 deployment target** as a project choice, not as a claim about the owner's installed version. Record the actual phone model, iOS version, SideStore version, and available build tools when they become available. Do not halt independent work merely because these details are unknown.

The owner develops primarily on Windows and also has a Linux laptop; Mac access has not been established. Prepare a macOS/Xcode build route from the beginning. Apple documents its simulator and iOS development workflow through Xcode on a Mac; GitHub-hosted macOS runners are one possible build environment. Windows remains the editing/orchestration machine. [S01, S02]

Match the **owner's selected Calculator version**, not an unspecified mixture of historic and current designs. Until a real reference is available, implement an adjustable Apple-style layout and label exact visual parity unverified. Never invent measurements from screenshots that have not been supplied or inspected.

### Scope boundaries

The target first complete release includes basic and scientific calculation, normal calculation history, offline unit conversion, vault CRUD and previews, encrypted backup/restore, and the three browser tabs to the extent confirmed by real-device tests. Handwritten Math Notes, live currency rates, graphing, cloud sync, multi-account switching within each service, native social SDK clients, and push notifications are later projects. Do not display nonfunctional buttons that imply those features exist.

Do not claim that the app, its data footprint, or website use is undetectable. A calculator façade is not deniable encryption. Treat Settings, storage usage, usage reporting, permission prompts, network observation, backups, screenshots, and analysis of the app itself as possible disclosure surfaces. The design aims to reduce accidental disclosure and protect vault data at rest, not hide activity from iOS or a compromised device.

## 2. Non-negotiable security and product rules

### Approved independent TKPlus research exception

On 2026-10-02 the owner explicitly approved a narrow exception to the native
runtime-hook exclusion for an independently authored layer in the existing
native TikTok guest. The first scope is selected-media downloads intended for
the encrypted Vault and opt-in profile-view eligibility controls. This is not
permission to clone all TTKillerPlus behavior or certify provider anonymity.
See `docs/tkplus/INDEPENDENT_IMPLEMENTATION.md` for the current execution slice.

The guest must not obtain Vault keys, repositories, arbitrary host filesystem
access, account credentials or copied cookies. No licensing bypass, checkout,
telemetry, destructive cleaner, region spoofing or anti-inspection hook is in
scope. Private provider endpoints remain prohibited. Existing products,
App IDs, bookmarks, signing-resource policy and lifecycle checks do not expand
under this exception. Synthetic tests precede private assembly and phone use.
The general exclusions below remain applicable outside this exact scope.

The vault's confidentiality must come from cryptographic keys and authenticated encryption, not from a hidden view or an `isUnlocked` Boolean. A plain or salted SHA-256 hash of a short calculator PIN is not an adequate vault design. Use an independent high-entropy key, a password-hardening function for the actual vault passphrase, and a protected biometric convenience path. Libsodium documents Argon2id password derivation and authenticated streaming encryption; use those implementations rather than inventing replacements. [S08, S09]

The browser session store is a **separate protection boundary**. A persistent `WKWebsiteDataStore` may keep website state on disk. Hiding or destroying a web view does not make that store part of the encrypted vault. The UI and documentation must distinguish persistent browser convenience from encrypted file storage. [S05, S06]

Do not collect service passwords, inject login forms, inspect password fields, export authentication cookies, forward browsing traffic through a custom server, or put personal credentials in the agent's prompt, tests, logs, screenshots, or repository. The owner performs real login and two-factor steps manually. No unauthorized posting, messaging, following, liking, or account changes during testing.

Use public APIs and ordinary entitlements. Do not copy Apple's binary, bundle identifier, extracted assets, or private frameworks. Recreate the calculator interface with system typography and independently implemented controls; create an original calculator-style icon. No jailbreak, private WebKit storage manipulation, runtime hooks, or restrictions-bypass dependency.

Do not ship destructive auto-wipe, a duress PIN, fake data destruction, or unreviewed crypto. Locking must never delete the vault. An error reading keys, authenticating data, migrating storage, or refreshing signing must never silently initialize a replacement vault over existing data.

## 3. Architecture and dependency boundaries

Use the following modules or folders. They can be local Swift packages where useful; avoid needless framework proliferation.

```text
CalcVault/
  AGENTS.md
  IMPLEMENTATION_PLAN.md
  TASKS.md
  README.md
  CalcVault.xcodeproj/            # A reproducibly generated equivalent is acceptable
  App/
    AppCoordinator.swift
    PrivacyShieldController.swift
    SessionLifecycleCoordinator.swift
  Calculator/
    CalculatorView.swift
    CalculatorViewModel.swift
    CalculatorEngine.swift
    ExpressionParser.swift
    CalculatorFormatting.swift
    CalculatorHistoryStore.swift
    CalculatorTheme.swift
    SecretEntryDetector.swift
  Security/
    VaultKeyManager.swift
    KeychainStore.swift
    PassphraseKeyDeriver.swift
    AuthenticatedCipher.swift
    EncryptedStream.swift
    VaultSession.swift
    AuthenticationCoordinator.swift
  Vault/
    VaultRepository.swift
    VaultManifest.swift
    VaultImportService.swift
    VaultPreviewCoordinator.swift
    ProtectedTemporaryFileStore.swift
    VaultBackupService.swift
    VaultMigrationService.swift
    Views/
  Social/
    SocialWorkspaceView.swift
    SocialService.swift
    BrowserProfileStore.swift
    SocialWebView.swift
    BrowserNavigationPolicy.swift
    BrowserMediaController.swift
    BrowserDataResetService.swift
  Tests/
    CalculatorTests/
    SecurityTests/
    VaultTests/
    BrowserPolicyTests/
  UITests/
  scripts/
    test-macos.sh
    build-unsigned-ipa.sh
    verify-artifact.sh
  docs/
    ENVIRONMENT.md
    SECURITY.md
    STORAGE_FORMAT.md
    PRIVACY_LIMITATIONS.md
    CALCULATOR_PARITY.md
    SOCIAL_COMPATIBILITY.md
    TEST_REPORT.md
    SIDESTORE_INSTALL.md
    adr/
  .github/workflows/
    ios-build.yml
```

**Dependency rules:** Calculator math cannot import authentication, WebKit, or the vault. The entry detector emits an unlock request to the coordinator; it cannot obtain keys. Social does not receive vault keys, repositories, or native file access. Vault preview code cannot mount local content in a social web view. Persistence and crypto operations live behind testable interfaces; UI-facing state changes run on the main actor. Serialize mutation through actors or another explicitly tested concurrency model.

Use an explicit application state machine: `firstRun`, `calculatorLocked`, `authenticating(attemptID)`, `privateUnlocked(sessionID)`, and `locking`. Use a monotonically changing session generation or equivalent revocable token. Every asynchronous result must verify that its session is still valid before exposing plaintext, committing a change, or restoring a private view.

### Dependency decision

Preferred crypto dependency: the upstream `jedisct1/swift-sodium` package, pinned to a reviewed revision compatible with the chosen Xcode toolchain. It exposes libsodium primitives including secretstream and password hashing. Record the actual bundled libsodium version and binary provenance, inspect licensing, and verify device plus simulator builds. Do not assume that an upstream library's security reputation is a security audit of this application. [S10]

Use Apple's Security and LocalAuthentication frameworks for Keychain and biometrics. Keep optional dependencies minimal. Any additional package requires a brief architecture decision explaining necessity, license, source provenance, maintenance status, and a pinned version. Do not silently downgrade crypto to make a build pass.

## 4. Phase 0 — prove the risky assumptions first

Create a minimal installable app containing a calculator placeholder, a real key-generation/encrypt/decrypt exercise using dummy data, the lifecycle shield, and three WebKit profiles. This is a technical prototype, not the finished UI.

Verify the build and signing pipeline immediately. Produce a device-target application, package it for SideStore re-signing, install it on the owner's phone, and confirm that its selected crypto library and Keychain settings work. Record the effective bundle identity and entitlements after re-signing without recording personal credentials.

Manually test each social site's landing page, direct sign-in, two-factor challenge, signed-in home/feed, video playback, and session persistence. Explicitly mark untested functions. Do not infer Instagram compatibility from X, or WKWebView compatibility from Safari. A live server or identity provider can behave differently by login method, device, region, or date.

Google explicitly documents `disallowed_useragent` errors for OAuth in embedded agents, including WKWebView. This does not prove that all three services are unusable; it makes login-method validation a prerequisite. Do not disguise the user agent or weaken browser protections to evade a login restriction. [S07]

The Phase 0 decision is per service: **confirmed in embedded browser**, **partially usable**, **external-browser fallback required**, or **not yet tested**. Continue calculator/vault implementation when a service is blocked, but do not describe that blocked service as complete.

**Gate G0:** A real macOS build result, an installable device artifact, and a compatibility report. Without phone access, create the prototype and exact manual test instructions, but leave on-device checks explicitly BLOCKED or NOT RUN.

## 5. Calculator implementation and parity

### Visual behavior

Recreate the selected reference's spacing, safe-area placement, display alignment, number scaling, button geometry, colors, selected-operator feedback, clear/delete states, mode control, scientific layout, and animations. Keep measurements in `CalculatorTheme` rather than scattering constants through views. Support portrait and landscape, accessible labels, reasonable Dynamic Type adaptation, and reduced motion.

Do not assume that all Calculator versions use identical zero-button shapes, delete gestures, scientific-mode entry, or history placement. `CALCULATOR_PARITY.md` must identify reference version, screen size, display settings, screenshots used, and discrepancies. Automated visual snapshots supplement arithmetic tests; they do not establish accuracy by themselves.

### Math engine

Use a deterministic tokenizer/parser/evaluator, not JavaScript `eval`, network calls, or UI-string substitutions. Preserve editable number text separately from the numeric value. A decimal representation is preferred for ordinary base-10 entry; scientific functions may use floating point with defined precision and error handling. Do not repeatedly round-trip display strings into calculation state.

Implement digits, decimal entry, addition, subtraction, multiplication, division, sign toggle, percent, equals, clear/all-clear, and deletion. Handle repeated equals, operator replacement, continued calculations after equals, leading zeros, negative zero, long input, divide by zero, overflow, nonfinite results, and malformed pasted expressions.

Scientific scope: parentheses, powers and roots, reciprocal, factorial for its supported integer domain, logarithms, exponentials, constants, degree/radian selection, trigonometric and inverse functions, and the memory controls present in the reference. Test domain boundaries. Do not silently treat degrees as radians or approximate singularities as ordinary answers.

Implement normal calculation history with inspect/reuse/delete actions. Add offline unit conversion for a bounded, tested set: length, mass, temperature, area, volume, time, and speed. Separate affine temperature conversions from multiplicative conversions. Live currency rates remain excluded unless a later feature specifies a provider, freshness policy, and network disclosure.

### Parity test fixture

Capture both the key sequence and observed reference output for context-dependent behavior. Percent arithmetic, precedence in chained operations, repeated equals, and sign changes are especially important. Provisional expectations must not be misrepresented as observed Apple behavior.

Examples for tests include `0.1 + 0.2`, `2 + 3 × 4`, `200 + 10%`, `200 × 10%`, `5 + = =`, multiple consecutive operators, deletion after equals, `sqrt(-1)`, `log(0)`, degree/radian conversions, large factorials, and locale-specific separators. Numeric unit tests must distinguish exact results from tolerance-based scientific results.

**Gate G1:** Core arithmetic, scientific functions, history, and selected unit conversions pass automated tests. Visual and behavioral parity have a written comparison, with any unverified reference behavior explicitly identified.

## 6. Secret calculator entry and first-run setup

### Enrollment

An unconfigured install may show a one-time setup flow. Do not conceal the setup flow from the owner or provision a universal default code. Have the owner configure an 8–12 digit entry sequence, a delimiter (initially `=`), an independent strong vault passphrase, and optional biometric convenience access. Explain that entering the numeric code reveals the authentication step; it does not alone decrypt the vault.

After enrollment, every cold launch starts at the calculator. Provide a documented, deliberate recovery route from a neutral calculator settings/help interaction that opens authentication without knowing the entry sequence. It must not bypass the vault passphrase. This route trades some discoverability for recovery and should be disclosed, not portrayed as impossible to find.

### Input state machine

Recognize the sequence only in a fresh manual numeric entry after all-clear or a fresh calculator session. Track input source. Digits typed on the keypad or an explicitly supported physical keyboard may participate; pasted numbers, history recall, calculation results, and imported expressions do not. Preserve leading zeros in the detector independently of display formatting.

Use a bounded candidate buffer. Reset it on all-clear, unrelated operators, decimal/sign transformations, completed unrelated calculations, timeout, backgrounding, and lock. Do not implement a global rolling suffix match across arbitrary calculations. All nonmatching input must still behave exactly as calculator input, with no special error or hint.

When the configured sequence and delimiter match, consume the delimiter before calculation-history publication, erase the candidate and visible number, and issue one authentication request. Do not continue normal result/history handling for that consumed event. Authentication cancellation returns to a clean calculator. Correct secret entries must never enter calculator history, crash diagnostics, debug logs, clipboard, or state restoration.

Store the navigation sequence in a separate Keychain item accessible while the device is unlocked, and use a constant-time comparison utility. It is acceptable for this navigation item not to require biometrics: it has no decryption authority. Do not confuse it with the protected vault key. A person observing the screen or accessibility output while the digits are typed may see them; the app cannot both display ordinary calculator digits and guarantee those digits are invisible to observers.

Changing the sequence, resetting biometric access, exporting a backup, and changing the vault passphrase require an authenticated private session; sensitive settings should request fresh authentication. Rate-limit failed vault authentication without blocking ordinary calculator use. Persist best-effort retry state, but do not claim it prevents offline guesses against a copied password envelope.

**Gate G2:** Automated tests cover matches, nonmatches, leading zeros, paste/recall exclusion, interrupted sequences, duplicate taps, cancellation, and absence from history. There is no default unlock code or release authentication bypass.

## 7. Cryptographic storage design

Implement and review `STORAGE_FORMAT.md` before storing real files. This specification sets the architecture; the exact serialized fields, bounds, and migration behavior must be frozen and tested by the implementation.

### Key hierarchy

Generate a random 256-bit vault root key using a cryptographically secure random generator. Never derive the root directly from the calculator code. Derive purpose-separated subkeys from the root using a library key-derivation primitive with fixed, versioned context identifiers. Generate a fresh random data-encryption key for every new file object and content revision.

For passphrase access, use libsodium Argon2id to derive a key-encryption key, with a random salt and stored algorithm/version/work parameters. Start benchmarking from the library's interactive baseline, which the documentation currently identifies as using 64 MiB; record measured cost on the target phone rather than copying a desktop timing estimate. Store explicit parameters, bound them before allocation, and never silently lower them after a resource failure. [S08]

Use XChaCha20-Poly1305 authenticated encryption to wrap the root key. Authenticate the version, vault identity, purpose, and KDF parameters as associated data. Use library-generated fresh nonces. Define a consistent, versioned UTF-8/normalization policy for passphrases; never trim or case-fold them implicitly. An authenticated unwrap can verify the password without storing a separate fast password hash.

For Face ID/Touch ID convenience, store a root-key copy in Keychain using `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and a biometric-current-set access policy. The actual protected Keychain read must succeed; a successful Boolean from a separate biometric dialog is not enough. Do not silently switch to device-passcode fallback when app-passphrase isolation is intended. Keychain access-control policies can bind access to biometrics and enrollment, while this device-only class does not migrate as a recoverable cloud key. [S11]

A changed biometric enrollment, removed device passcode, or inaccessible Keychain item must lead to the independent passphrase path, not data deletion. Re-enrollment occurs only after successful passphrase unlock and explicit consent. Keep a fresh authentication context per attempt and invalidate it on genuine lock/background events.

### Storage layout

Store vault-owned files under a private Application Support directory, not a publicly shared Documents directory. Use random object identifiers for disk filenames. The encrypted manifest holds original filenames, note titles, folders, MIME/type hints, timestamps, thumbnail references, revisions, and per-object keys. Do not keep a plaintext SQLite/SwiftData mirror of that information.

An encrypted, atomically replaced manifest is sufficient for a first release with a defined tested item-count limit. Do not add an unencrypted search index. Search decrypted metadata only while unlocked. Encrypt note bodies, thumbnails, and any generated preview cache as private objects. Leave only required format/version/KDF metadata outside encryption; disclose that ciphertext sizes and counts may remain inferable.

Use libsodium secretstream for potentially large content instead of loading an entire video into memory or designing independent AES chunks. Add only a versioned, bounded record framing layer. Require a final authenticated tag, reject missing or extra terminal data, and bind each stream to its vault/object identity and revision through authenticated metadata or associated data. Explicitly test truncation, reordering, duplication, substitution, and malformed lengths. [S09]

Set appropriate file protection on every vault-owned file and temporary plaintext file; prefer complete protection for content not intended for background access. iOS Data Protection is an additional OS layer, not a substitute for the app's vault key. [S12]

### Atomicity and recovery

For import, encrypt into a new staging object, finish and validate it, then atomically publish the new encrypted manifest referring to it. A crash must leave either the old committed state or the new committed state, never a reference to half-written ciphertext. Garbage collection may remove only demonstrably unreferenced objects and must not interpret an unavailable key as an empty vault.

For notes, create a new revision and commit it atomically. For deletion, commit removal from the manifest and then remove unreferenced blobs. Do not claim secure physical erasure from flash storage or existing backups. Maintain migration fixtures and preserve the previous valid state until a migration succeeds.

Hold keys and decrypted metadata only for an active session. Minimize copies, zero mutable sensitive buffers where practical, and release caches on lock. Swift value semantics, framework internals, and process memory make perfect zeroization an inappropriate guarantee.

**Gate G3:** Wrong passphrases, corrupted envelopes, modified ciphertext, missing chunks, malicious size fields, and stale sessions fail closed. No plaintext titles, filenames, thumbnails, or content appear in the application's persistent vault files. A failed migration cannot destroy the previous vault.

## 8. Vault UX, import, preview, and export

Provide a grid/list toggle for media, folders, file search, note creation/editing, rename/move/delete, import progress, and explicit export. Keep the first implementation local-only. No telemetry, cloud account, remote config, or custom backend.

Use system photo and file pickers to let the owner select content, requesting only access needed for the operation. Handle security-scoped URLs and coordinated access where required. Do not load large selected files through an unbounded `Data(contentsOf:)` path. Reject or gracefully handle unsupported types, disk exhaustion, unavailable cloud-backed source items, cancelled pickers, and background interruption.

Import is a **copy**, not a guarantee that the original disappeared. Preserve source files by default. Explain that originals, Photos copies, Recently Deleted items, other backups, and exports may remain outside this app. Never automatically delete the owner's source library.

### Preview profiles

Implement image and plain-text previews from memory when practical. For supported PDFs, prefer a native data-based viewer and audit its caching behavior. Do not send private local documents through the internet-enabled social web view.

Secretstream is sequential, so instant random-access video playback is not a feature to assume. For the first functional media release, fully decrypt and authenticate a requested video into a protected, randomly named temporary file, then play it using a native media controller. This is a documented privacy tradeoff: the active preview file is protected by iOS but temporarily is not wrapped by the vault cipher. A strict mode can disable disk-backed previews and therefore video playback until a separately reviewed streaming solution exists.

Use one temporary-file manager for preview, export, picker staging, and media. Apply protection/exclusion properties at creation; avoid revealing filenames where the system permits. Remove owned temporary files on preview dismissal, lock, cancellation, and next launch after a crash. On background lock, stop readers and revoke access first; cleanup must not depend on unlimited background execution. A crash or forced termination may leave protected temporary files until cleanup, and documentation must say so.

Do not launch Quick Look or arbitrary third-party document apps with decrypted files silently. An explicit plaintext export is an intentional boundary crossing. Warn before sharing outside the vault; the receiving app can retain the copy and this app cannot revoke it. Scope cleanup carefully so it does not break an in-progress user-authorized share.

**Gate G4:** Import/view/edit/delete works for the declared types and sizes, no unbounded memory path exists, and interruption tests preserve the last committed data. All disk-backed preview exceptions are documented and tested.

## 9. Social workspace

### Structure and login ownership

Show three service tabs under Social: TikTok, X/Twitter, and Instagram. Their initial destinations are the official HTTPS website origins, not copied login pages. Display the current hostname in native browser chrome, especially during authentication and off-site navigation. Label these as web experiences, not native-client equivalents.

The owner signs in directly within the website when supported. No API key or custom OAuth client is needed simply to navigate a website. Do not create a backend, native login form, scraper, or undocumented endpoint integration for v1. Do not treat a provider's developer API login as automatically granting the web site's browser session.

Some login paths may require supported system browser surfaces. `SFSafariViewController` or external Safari can be offered as explicit fallbacks; do not promise that their cookies will transfer into WKWebView. `ASWebAuthenticationSession` is not a generic cookie-copying tool for arbitrary third-party websites. A provider-controlled OAuth redirect belongs to that provider, not to this app. Mark an external fallback as a compatibility compromise, not as satisfying an embedded-login requirement. [S05, S07, S17]

### Profile and persistence policy

Use a separate stable-identifier `WKWebsiteDataStore` for each service in **remembered-session mode**. Use the supported identifier-based APIs with availability checks. Do not assume separate `WKProcessPool` objects create separate cookie stores, and do not manipulate WebKit's private database paths. [S05, S06]

Remembered-session mode preserves login where the site permits, including across app lock/restart. Its explicit disclosure: browser-managed cookies, local storage, caches, and other website state may persist outside vault encryption. The app is designed to restrict UI access to that state, not to make it equivalent to an encrypted vault file. Do not guarantee indefinite login; the service may expire or revoke sessions.

Provide **ephemeral mode** per service using nonpersistent stores. Destroy all associated views/store references on lock. Explain that this may require signing in again, especially when leaving the app to obtain a two-factor code. Do not describe ephemeral mode as network anonymity or guaranteed forensic erasure. Switching modes must explicitly resolve old persistent data; it cannot silently leave a supposedly cleared profile behind.

Default onboarding should ask the owner to choose remembered versus ephemeral mode, with remembered mode presented as the practical choice for frequent social use and its limitation visible before selection. Never label remembered mode 'fully vault encrypted.'

### Navigation, permissions, and media

Implement back, forward, reload, home, loading/error UI, bounded new-window handling, and a reachable lock action. Keep views stable while the private session is active so a SwiftUI state update does not recreate them or discard a composed message. Keep a bounded number of live views and stop inactive media; recreate from the persistent store after a full lock.

Apply a top-level navigation policy with correctly parsed hosts and scheme checks. Do not use substring host comparisons. Allow required first-party/authentication navigation only after verification. Ask before deliberate navigation to unrelated sites. Do not apply a naive three-domain blocklist to every resource: service CDNs and identity flows need separate treatment. An allowlisted website is still untrusted web content.

Never automatically open native social apps, App Store links, phone links, or arbitrary URL schemes. Require an explicit user gesture and confirmation for external actions, and lock/cover the private workspace before leaving. Preserve standard TLS validation; no blanket App Transport Security exceptions.

No native-to-JavaScript bridge may expose vault files, filesystem paths, keys, credentials, or a generic command executor. Do not inject scripts into password fields or serialize authentication cookies. Do not spoof another app or patch anti-bot logic. Narrow supported media control is different from manipulating site authentication.

Deny camera/microphone access by default. Add it only for an explicitly selected feature with an origin-aware permission request. Request no photo-library-wide access merely to show feeds. No background audio, Picture in Picture, notifications, widgets, Siri suggestions, or account badges in v1. Verify that audio and external playback stop on lock; merely hiding the web view is not an adequate test.

Provide 'clear this site's local data' and 'clear all local browser data.' Shut down views, await supported website-data deletion, rotate/remove profile identifiers as appropriate, and recreate a clean store. Distinguish local data removal from server-side session revocation and deletion of account history.

### Compatibility matrix

For each service and each tested login method, record the date, OS/device, browser mode, observed result, and limitations. Test direct login, two-factor authentication, restart persistence, feed scrolling, video, search, profile, links, and local reset. Messaging, posting/upload, live streams, calls, passkeys, and other advanced features are optional until positively tested. Use 'NOT TESTED' rather than guessing.

Functional tests involving an account are manual and owner-operated. Automated CI uses local, synthetic HTML fixtures for cookies, popups, redirects, file inputs, media, and JavaScript dialogs. Never record real sessions into test fixtures.

**Gate G5:** All three tabs have truthful per-feature status. No website state or JavaScript obtains vault access. Persistent/ephemeral behavior and local data reset are tested separately. A blocked login remains a documented limitation, not a claimed success.

## 10. Lifecycle privacy and locking

A SwiftUI screen swap scheduled later on the main queue is not the whole privacy strategy. Install an opaque calculator-style cover synchronously through UIKit lifecycle hooks before the system can capture the background representation. Cover presented private sheets and any app-owned windows as well as the main view. Apple's background-UI guidance is the relevant API reference; validate timing on a physical phone. [S13]

On genuine backgrounding, device data-protection loss, explicit lock, and the configured inactivity timeout: cover immediately, deny private interaction, invalidate the session, cancel private operations, stop media, discard web views, clear decrypted UI/cache state, invalidate authentication contexts, and release keys. Return with the calculator visible and require a new unlock. Do not rely on a termination callback.

Distinguish foreground-inactive transitions caused by the app's own active Face ID prompt from actual backgrounding. Keep the privacy cover in place during the prompt, but do not create an infinite cancel/retry loop by invalidating that prompt merely because the app became inactive. A later callback must match the active attempt, a valid session generation, and a foreground scene before it can expose private UI. Backgrounding always invalidates the attempt.

The default is immediate lock on background and a configurable two-minute inactivity lock. The timeout must account for actual interaction inside a web view and native editors without reading keystrokes or page contents. Use public input-event observation and test it; do not reset the timer continuously just because a page is playing video or polling.

There is no promise that arbitrary unlocked UI cannot be screenshotted. Use supported recording/mirroring signals to cover content where possible and test their availability, but do not use undocumented secure-text-field screenshot hacks. A screenshot notification is not a preventative boundary. [S14]

Suppress private state restoration, automatic clipboard writes, Spotlight indexing, donated activities, and private launch shortcuts. Copies must be user-initiated; use supported local-only/expiration clipboard options where available. Do not blindly erase clipboard content that no longer belongs to this app. No logging of calculations during secret entry, decrypted metadata, page contents, full URLs with query strings, cookies, or authentication fields.

**Gate G6:** Physical-device tests cover app switcher, lock screen, Control Center, phone interruption, biometric cancellation, fast background/foreground cycling, media playback, rotation, browser popups, and private sheets. No stale async callback may reopen the vault after lock.

## 11. Backup, recovery, and data-loss prevention

Encrypted backup and tested restore are release requirements, not a future convenience. A device-only biometric Keychain item is not a recovery plan. [S11]

Use a versioned, streamable backup container containing the encrypted vault manifest and ciphertext objects plus a root-key envelope protected by a **separate backup passphrase**. Derive its wrapping key with Argon2id and fresh parameters/salt. Authenticate the collection inventory, object identities, lengths, and ciphertext digests so missing or substituted objects are detected. Do not include service cookies, website sessions, the calculator entry sequence, device-bound biometric items, or any plaintext secret.

The container can use a vetted archive layer or a narrow bounded record format, but its encryption must remain the reviewed library-based construction. Do not rely on password-protected ZIP as the security design. Never embed the backup passphrase beside the backup. Export uses an explicit system share/save action and a warning to store the archive and passphrase separately.

Restore must work into a fresh application container with no previous Keychain state. Verify the full archive and all referenced objects into a staging area before publishing it. Reject unsupported versions, duplicate identities, missing final tags, impossible lengths, excess resources, and unsafe archive paths. Preserve any existing vault until an explicit, authenticated replacement operation completes. Merge restore is out of scope for v1.

After restore, the owner sets a new calculator sequence, chooses the local vault passphrase, and re-enrolls biometrics; website sign-in is separate. Prove recovery from an archive after deleting test Keychain entries. Test an older supported archive after a schema update.

Request backup exclusion for vault-owned local directories and temporary content where supported, while offering explicit encrypted exports. Treat Apple's exclusion flag as an API to use and verify, not as a guarantee that every OS-managed browser artifact is excluded from every backup mechanism. [S15]

A passphrase change rewraps the same root key transactionally. Old backups may still open with their old backup passphrase; explain that changing local credentials does not revoke already exported archives. Deleting the app, losing all passphrases/backups, or losing app identity can cause loss or inaccessibility. Never recommend deleting a populated install as the first fix for SideStore signing trouble.

**Gate G7:** An encrypted archive restores successfully into a clean install, reconstructs all sample files byte-for-byte, and needs neither the old device key nor the old calculator sequence. Corrupt and wrong-password restores leave existing data intact.

## 12. Windows development, macOS builds, and SideStore

Keep the repository usable from Windows for source editing, documentation, and applicable platform-neutral tests. Put UIKit, WebKit, and Keychain implementations behind interfaces, but do not introduce fake production crypto just to make Linux/Windows tests compile. The authoritative iOS build and integration test runs happen on macOS with Xcode. [S01]

Provide a committed Xcode project or a pinned project-generation tool and deterministic configuration. Record the selected macOS runner image, exact Xcode version, simulator runtime, Swift version, SDK, minimum deployment target, and dependency revisions. Avoid a floating 'latest' configuration without recording what actually ran. GitHub Actions offers macOS runners; check the account's current usage/billing before spending build minutes. [S02]

CI should compile, run unit tests, execute fixture-driven simulator UI tests, build a Release **iphoneos** app, verify the bundle, and package `Payload/<AppName>.app` into an unsigned IPA intended for SideStore re-signing. A simulator `.app` is not an installable phone build. The implementation must prove that its package works with the owner's SideStore, not just that ZIP creation succeeded.

A conceptual command for the build script is:

```sh
xcodebuild \
  -project CalcVault.xcodeproj \
  -scheme CalcVault \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Resolve the actual app product from build settings, verify its platform/architecture and required resources, then package it. Do not assume this example alone constitutes a working release pipeline. Exclude simulator slices, test-only flags, secrets, extra extensions, and unsupported entitlements. Do not place signing certificates, Apple account passwords, pairing files, or social credentials in CI.

Keep one stable non-Apple bundle identifier and document any SideStore rewrite of app identity. Do not hardcode a developer Team ID or shared Keychain access group. Avoid extensions and unnecessary app groups. Re-signing, team changes, and identity changes must be tested because access to previous data/Keychain items is an integration concern, not an assumption.

SideStore's standard free-account documentation describes a normal seven-day refresh period and three active apps including SideStore. This single app should not require three extra app slots for its social tabs. Document the owner's actual installation/refresh behavior rather than assuming a bypass or paid membership. [S16]

Installation documentation must explain: transfer the generated IPA to the phone; import and re-sign it using the already installed SideStore; complete one-time setup; create a dummy-data backup; and run the privacy/restore checks before trusting it with irreplaceable files. Updating a populated vault requires a verified backup and the same app identity; test in-place updates with dummy data first.

**Gate G8:** The release IPA is installed by SideStore, opens after refresh, retains dummy vault data through an in-place update, and can restore an encrypted backup without old Keychain state. Otherwise label the release candidate unverified.

## 13. Acceptance test inventory

Maintain `TEST_REPORT.md` with PASS, FAIL, BLOCKED, or NOT RUN; include environment, command or manual steps, expected behavior, observed behavior, and sanitized evidence. Compilation, simulator tests, device tests, and live-account compatibility are different forms of evidence.

| Area | Required cases |
|---|---|
| Calculator | Decimal arithmetic, percent contexts, chaining, repeated equals, scientific domains, locales, long values, orientation, history, conversion fixtures. |
| Entry detector | Correct sequence, nonmatch, unrelated expressions, paste/recall exclusion, leading zeros, timeout, restart, duplicate events, no history/log leak. |
| Authentication | Wrong passphrase, biometric cancel/failure, enrollment change, missing Keychain item, changed signing identity, stale callback, failed-attempt delays. |
| Cipher/storage | Round trips, known library vectors where available, nonce policy, wrong key, tampered metadata, reordered/truncated streams, malformed headers, resource bounds. |
| File operations | Empty file, large video, Unicode name, rename/move/delete, concurrent actions, source unavailable, low disk, interrupted import, interrupted migration. |
| Preview/privacy | Memory preview, protected temp preview, dismissal cleanup, forced termination cleanup, app switcher, device lock, sheet/popover, recording, media stop. |
| Browser | Three-store separation, remembered/ephemeral modes, restart, popups, external links, blocked login, local reset, process termination, no vault bridge. |
| Backup | Clean-install restore, missing old keys, wrong password, corruption, missing object, unsafe path/length, old format, failed replacement preserving old data. |
| Distribution | Real iphoneos binary, correct entitlements, no secrets/test bypass, SideStore install/refresh/update, stable identity, artifact digest. |

Security-critical regressions block release. Include adversarial tests for unlocking after a lock race, showing a decrypted thumbnail from a stale cache, activating a vault action through a web message, and restoring browser content without authentication. Keep real private material out of testing; use dummy assets and synthetic credentials.

## 14. Agent execution order and ownership

Implement in small, reviewable vertical slices. Complete the earliest available gate, update the task ledger, and continue to the next unblocked task. Do not repeatedly redesign already approved decisions or rewrite the plan in place of implementing it.

Suggested order: environment/build prototype and browser-login spike; calculator engine/UI; enrollment and state machine; crypto/storage; vault import and basic previews; browser workspace; lifecycle/privacy hardening; backup/restore; scientific/conversion/parity completion; release verification. Basic lifecycle protection and dummy crypto are required in the initial prototype even though later phases deepen them.

Parallel work is optional, not a requirement to spawn many agents. A calculator worker can own calculator code and tests; a storage/security worker can own the crypto interfaces and vault repository; a browser worker can own WebKit integration and synthetic fixtures. One integrator owns application state, project configuration, dependency versions, and final gates. Freeze shared interfaces before parallel changes. Security review should be performed from an independent perspective, and unresolved findings remain visible.

Use existing repository instructions. Do not replace global Codex configuration. The supplied root `AGENTS.md` supplies project-specific working agreements; Codex supports loading project instructions from that file. [S18]

When blocked by unavailable macOS execution, account access, a physical phone, or a provider restriction, continue safe independent work and record the exact remaining test. Do not fabricate successful builds, use personal credentials from chat, or weaken protection to manufacture a green status.

### Final implementation handoff

Deliver source and project configuration, pinned dependencies, repeatable build/test scripts, the unsigned device IPA when actually produced, its checksum, the installation guide, security/storage/privacy documents, a populated compatibility matrix, a populated test report, and unresolved limitations. A release summary must separate **implemented**, **automatically tested**, **device verified**, and **not verified**.

Do not label the app audited, unhackable, undetectable, or equivalent to all native social apps. The intended result is a useful calculator, a reviewed-and-tested encrypted local vault, and clearly bounded signed-in web access.

## 15. Primary-source reference index

These references informed feasibility and API choices. Requirements and architecture in this plan are proposed engineering decisions, not claims that the sources endorse this exact app. Some Apple API pages require JavaScript; Codex must verify exact signatures and availability against the installed SDK and current documentation before coding.

| ID | Source and purpose |
|---|---|
| S01 | Apple, Xcode: development and simulator environment. `https://developer.apple.com/xcode/` |
| S02 | GitHub, hosted runners: macOS build infrastructure. `https://docs.github.com/en/actions/reference/runners/github-hosted-runners` |
| S03 | Apple Platform Security, runtime sandbox and entitlements. `https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web` |
| S04 | Apple, WKWebView. `https://developer.apple.com/documentation/webkit/wkwebview` |
| S05 | Apple, WKWebsiteDataStore. `https://developer.apple.com/documentation/webkit/wkwebsitedatastore` |
| S06 | Apple, identifier-based persistent website data stores. `https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)` |
| S07 | Google, OAuth for native applications; embedded-user-agent errors. `https://developers.google.com/identity/protocols/oauth2/native-app` |
| S08 | Libsodium, Argon2 password-key derivation. `https://doc.libsodium.org/password_hashing/default_phf` |
| S09 | Libsodium, authenticated secret streams. `https://doc.libsodium.org/secret-key_cryptography/secretstream` |
| S10 | Upstream Swift-Sodium package, API and binary provenance. `https://github.com/jedisct1/swift-sodium` |
| S11 | Apple Platform Security, Keychain data protection and access control. `https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web` |
| S12 | Apple Platform Security, Data Protection overview. `https://support.apple.com/guide/security/data-protection-overview-secf6276da8a/web` |
| S13 | Apple, preparing UI for background execution. `https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background` |
| S14 | Apple, screenshot notification. `https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification` |
| S15 | Apple, backup exclusion resource property. `https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup` |
| S16 | SideStore, FAQ and standard account/refresh limitations. `https://docs.sidestore.io/docs/faq` |
| S17 | Apple, SFSafariViewController. `https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller` |
| S18 | OpenAI, project instructions with AGENTS.md. `https://developers.openai.com/codex/guides/agents-md/` |
