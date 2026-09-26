# CalcVault encrypted storage format

Status: **Frozen for format version 1 (Phase 3)**
Date: 2026-09-20

This document defines the first encrypted local-vault format. It supersedes only the unfinished Phase 0 storage-format placeholder. The independently stored TAR selected by the owner remains a separate, authoritative, read-only source; plain TAR remains concealment/packaging and is not encryption.

## Security boundary

- The enrolled random 256-bit root key is never derived from the calculator sequence.
- A purpose-separated manifest key is derived with libsodium `crypto_kdf` context `CVManV01`, subkey ID `1`, and 32-byte output.
- Every object and every content revision receives a new random 256-bit secretstream key. Object keys exist only inside the encrypted manifest.
- Manifest encryption uses XChaCha20-Poly1305 with a fresh library-generated nonce.
- Object encryption uses libsodium XChaCha20-Poly1305 secretstream and requires exactly one authenticated final tag.
- Filenames, titles, note text, type hints, timestamps, folder relationships, thumbnails, and object keys are encrypted. Plaintext storage reveals the format version, vault UUID, random object identifiers, revisions, ciphertext lengths, chunk size, and approximate item count.
- Version 1 passphrases use the Phase 2 `utf8-exact-v1` policy and Argon2id envelope. Input is not trimmed, case-folded, or normalized.

The application is not a security audit, does not promise forensic invisibility, and does not claim secure erasure from flash storage or backups.

## Location and initialization state

Vault-owned files live under private Application Support in `CalcVaultVault/v1/vault`. The directory is excluded from ordinary device backup where the public Foundation API supports that request. Vault files use complete iOS file protection.

Initialization is explicit while an authenticated private session is active. A device-only Keychain marker stores the vault UUID after the complete initial directory and encrypted manifest have been atomically published.

State handling is fail-closed:

- No marker and no vault directory: `notInitialized`; the UI may offer explicit initialization.
- Marker present and a valid matching vault: `ready`.
- Marker present but the directory, header, manifest, key, or authenticated data is missing/unreadable/corrupt: visible failure; never initialize a replacement.
- Directory present without its marker: visible inconsistent state; never overwrite or delete it automatically.
- Marker or header for another vault UUID: visible identity mismatch.

## Integer and UUID encoding

All integers in binary files are unsigned big-endian. UUIDs are the 16 RFC 4122 bytes used by Foundation `UUID`. Reserved fields must be zero. Readers reject unsupported versions, nonzero reserved fields, trailing bytes, duplicate identities, and values outside the bounds below.

## Plaintext vault header: `vault.header`

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | ASCII magic `CVROOT01` |
| 8 | 2 | format version `1` |
| 10 | 2 | reserved `0` |
| 12 | 16 | vault UUID |

The file is exactly 28 bytes. It contains routing metadata only and provides no authentication by itself. The authenticated manifest must match its vault UUID.

## Encrypted manifest: `manifest.cvm`

The 44-byte plaintext envelope header is:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | ASCII magic `CVMAN001` |
| 8 | 2 | format version `1` |
| 10 | 2 | reserved `0` |
| 12 | 16 | vault UUID |
| 28 | 8 | manifest generation, starting at `1` |
| 36 | 8 | nonce-plus-ciphertext byte length |

The complete 44-byte header is XChaCha20-Poly1305 associated data. It is followed by the library's combined 24-byte nonce, ciphertext, and 16-byte tag. The file must end exactly after the declared ciphertext. Manifest plaintext is UTF-8 JSON emitted with sorted keys.

The JSON contains `formatVersion`, `vaultID`, `generation`, millisecond creation/update timestamps, and `items`. Each item contains a random UUID, optional parent UUID, kind, display name, optional media type, byte count, timestamps, revision, random `.cvobj` filename, 32-byte object key, and optional thumbnail UUID. All JSON fields are confidential and authenticated.

Limits:

- manifest plaintext: 8 MiB
- manifest items: 10,000
- display name: 1,024 UTF-8 bytes
- media type: 255 UTF-8 bytes
- object key: exactly 32 bytes
- object filename: lowercase UUID plus `.cvobj`, with no path separators
- duplicate item UUIDs or object filenames: rejected

The decoded JSON vault UUID and generation must equal the authenticated envelope header.

## Encrypted object: `objects/<random-uuid>.cvobj`

Each content revision is a separate file. The fixed 88-byte header is:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | ASCII magic `CVOBJ001` |
| 8 | 2 | format version `1` |
| 10 | 2 | reserved `0` |
| 12 | 16 | vault UUID |
| 28 | 16 | object UUID |
| 44 | 8 | revision, starting at `1` |
| 52 | 8 | total plaintext byte length |
| 60 | 4 | plaintext chunk size, fixed at 65,536 |
| 64 | 24 | libsodium secretstream header |

The object header is followed by ordered records:

| Size | Field |
|---:|---|
| 4 | zero-based sequence number |
| 4 | ciphertext length |
| variable | secretstream ciphertext |

For each record, associated data is the complete 88-byte object header followed by that record's sequence number and ciphertext length. Ciphertext length is plaintext length plus the library's 17-byte secretstream overhead. Nonfinal records must decrypt to exactly 65,536 bytes. The last record uses `TAG_FINAL`; an empty object has one zero-length final plaintext record. `PUSH` and `REKEY` tags are not valid in format version 1.

Readers reject wrong vault/object/revision identity, malformed sizes, sequence gaps, duplicates, reordering, substitution, authentication failure, missing final tags, early final tags, bytes after the final record, and plaintext-length disagreement. The maximum plaintext object length is 256 GiB.

## Atomic commit protocol

All staging occurs on the same volume under a private `.staging` directory.

1. Encrypt a new object revision to a unique staging path.
2. Close and synchronize it, apply file protection, then decrypt and authenticate the staged file to a disposable validation target.
3. Confirm the authenticated session generation is still current.
4. Move the validated ciphertext into `objects`. At this point it is unreferenced and harmless if the process stops.
5. Construct generation `N + 1` of the manifest, encrypt it to a unique staging file, close/synchronize it, and reopen/authenticate it.
6. Recheck the session and atomically replace `manifest.cvm`.

A failure before step 6 leaves the old manifest authoritative. Unreferenced ciphertext may be garbage-collected only after a valid manifest has been authenticated; inability to authenticate is never interpreted as an empty manifest. Deletion first commits a manifest without the reference and only then permits removing the unreferenced ciphertext. Version 1 does not claim physical secure deletion.

## Migration

Format version 1 has no supported predecessor. Future migrations must build a complete candidate in a sibling staging directory, authenticate and validate it under bounded readers, and only then atomically publish it while retaining the previous valid directory as a rollback copy. A failed build, validation, or publish leaves the prior vault unchanged. Unsupported versions fail visibly; they are never opened as empty version 1 vaults.

## Recovery and backup boundary

This local format is not a standalone backup. Its root-key envelope remains in Keychain, and biometric material is device-bound. Phase 7 defines a separate encrypted backup container and clean-install restore. Until that gate passes, use only disposable synthetic fixtures and do not store irreplaceable private media.
