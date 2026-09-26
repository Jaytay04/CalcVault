# ADR 0002: encrypted storage format version 1

Date: 2026-09-20
Status: accepted for Phase 3 implementation

## Context

CalcVault needs bounded authenticated storage for encrypted metadata and potentially large media. It must preserve the last valid vault through interruption, distinguish first initialization from missing initialized storage, reject stale sessions, and avoid plaintext filenames or titles. The Phase 0 TAR reader and SecretBox diagnostic do not meet those requirements.

The pinned `jedisct1/swift-sodium` 0.11.0 package exposes libsodium KDF, XChaCha20-Poly1305 AEAD, and XChaCha20-Poly1305 secretstream. Upstream secretstream documentation requires ordered authenticated messages and a final tag for complete file streams.

## Decision

- Freeze the exact binary and JSON bounds in `docs/STORAGE_FORMAT.md` as format version 1.
- Derive only the manifest key from the enrolled random root key, using the eight-byte KDF context `CVManV01` and subkey ID 1.
- Generate a fresh random secretstream key for every object revision and keep it only in the encrypted manifest.
- Encrypt the bounded manifest with XChaCha20-Poly1305 and authenticate its version, vault UUID, generation, and ciphertext length as associated data.
- Encrypt objects in 64 KiB secretstream records. Bind the fixed header, sequence number, and record length as associated data; require one final tag and exact EOF.
- Publish validated objects before an atomically replaced manifest. A crash can leave an unreferenced ciphertext object, but never a manifest reference to an incomplete object.
- Store a device-only Keychain initialization marker after initial storage publication. A present marker plus missing/unreadable storage is an error, never permission to make an empty vault.
- Require a revocable session permit at operation start and immediately before publication. The repository does not retain the root key between calls.
- Keep future migration work transactional: build and validate a sibling candidate, then publish it while retaining the previous valid directory.

## Consequences

- Plain observers may infer format version, vault identity, object identifiers, revisions, lengths, chunk boundaries, and approximate item counts. Names, metadata, keys, and content remain encrypted.
- Unreferenced ciphertext can accumulate after interruption; later garbage collection may remove it only after authenticating a valid manifest.
- Version 1 has a 10,000-item and 8 MiB manifest limit. Searching metadata requires an unlocked in-memory manifest; no plaintext index exists.
- This format is local storage, not clean-install recovery. Encrypted backup remains a later gate.
- Complete iOS file protection and backup exclusion add platform protection but do not replace application encryption or guarantee forensic erasure.

## Reviewed risks retained as explicit tests

Wrong keys, tampered manifests, malicious lengths, object truncation, record reordering/duplication, missing final tags, trailing bytes, identity substitution, interrupted manifest replacement, stale-session publication, missing initialized storage, and failed migration are all fail-closed test cases. Real-device file-protection behavior and performance remain separate physical checks.

## Primary references

- Libsodium secretstream: `https://doc.libsodium.org/secret-key_cryptography/secretstream`
- Libsodium key derivation: `https://doc.libsodium.org/key_derivation`
- Swift-Sodium 0.11.0 source: `https://github.com/jedisct1/swift-sodium/tree/0.11.0`
