# Media-only outbox proposal

Status: reviewed direction, not implemented or device-validated. This proposal
does not authorize new bookmarks, an App Group, another extension or App ID.

## Why a new transport is needed

The current native research runtime exposes presentation, launch, revoke and
diagnostics only. `NativeGuestRuntime` and `CVLPGuestSession` do not expose a
bounded media callback. Synthetic report paths are diagnostic canaries, not an
import channel, and must not be repurposed to carry media.

An outbox beneath the already-bookmarked guest-specific data directory is the
preferred next prototype. It avoids a new listening network service and a wider
filesystem grant. The entire outbox remains untrusted guest-controlled storage;
its location does not establish confidentiality, authenticity or isolation.

## Host responsibilities

1. Require a current authenticated Vault session before offering a Save action.
   Create a fresh opaque random transfer ID and session generation. Allow one
   pending transfer, with a bounded deadline and host resource budget. A new
   transfer object is required for each attempt; never reset an old lease.
   Serialize all lease operations and inspection on one executor or under one
   host lock; the C API has no internal synchronization. Revoke host-session
   authority synchronously on lock independently of any queued byte accounting.
   Cap encoded input bytes and record count as well as aggregate payload: many
   one-byte chunks must not turn a bounded payload into unbounded framing work.
2. Derive the outbox root from the host's approved guest descriptor and fixed
   data identity. Pin a directory file descriptor using no-follow directory
   checks. Do not accept a root, filename, path, URL or destination from the guest.
   Every transfer filename is derived from the host-issued ID in a fixed format.
3. Only discover a completed transfer after its fixed ready marker appears.
   Atomic publication by a cooperative guest is a convenience, not trusted proof.
   Open relative to the pinned directory descriptor with no-follow/nonblocking
   checks; reject directories, symlinks, special files and unexpected hard links.
   Never wait on a guest-controlled FIFO or import directly from a guest URL.
4. Stream the bounded records into a newly created, protected host-owned staging
   file. Check record identity, generation, order, payload and aggregate limits
   through `TKPTransfer`. Require exact completion and EOF; reject partial reads,
   trailing records/bytes, oversized input and inconsistent file metadata.
   Check input identity and size across the copy; these checks do not prove that
   a hostile guest left every byte unchanged. The copied bytes are still hostile.
5. Validate the actual copied media type, dimensions and decoder/resource limits,
   independent of the guest's declared JPEG/PNG/MP4 kind. Never decode or preview
   directly from the guest-controlled source. Parser completion is byte
   accounting, not permission to commit or a proof of valid media.
6. Present confirmation in CalcVault under the same active session generation.
   Recheck authority before staging, preview, confirmation and encrypted commit.
   Use the existing revocable importer, not guest access to a repository or key.
7. Lock, background, timeout, error or cancellation revokes the pending import
   authority even if the byte lease already reached COMPLETE. Cancel decoding,
   previews and import callbacks. Clean only host-owned staging and exact owned
   transfer entries, relative to pinned descriptors; never recurse through or
   clean arbitrary guest paths. Existing archives and source media stay intact.

## Wire record

All integers are little-endian. No paths, URLs, cookies, accounts, commands or
Vault keys occur in the envelope. Payload is untrusted opaque media bytes.

| Offset | Length | Value |
|---|---|---|
| 0 | 4 | `TKP1` magic |
| 4 | 1 | Version 1 |
| 5 | 1 | Record kind: chunk 1 / finish 2 |
| 6 | 1 | Declared media kind: JPEG 1 / PNG 2 / MP4 3 |
| 7 | 1 | Reserved zero |
| 8 | 8 | Host-issued nonzero generation |
| 16 | 16 | Host-issued nonzero opaque transfer ID |
| 32 | 8 | Sequence, starting at zero |
| 40 | 4 | Payload length, at most 65,536 bytes |
| 44 | 4 | Reserved zero |
| 48 | variable | Nonempty chunk bytes; finish has no payload |

The expected total size is pinned in host state and capped at 1 GiB by the core;
the prototype should impose a smaller operational budget if decoder/storage
requirements demand it. It must not silently raise bounds when a transfer fails.
An active ID known to the guest is not authentication against that guest.

## Required proof before integration

Use disposable synthetic fixtures to exercise symlink/FIFO/hard-link rejection,
root replacement, truncation, concurrent source mutation, missing readiness,
   partial/trailing records, exhaustion, stale generation, late confirmation and
lock during copy/decode/import. Confirm no new or wider bookmark and no guest
read of host staging. Compile on Apple tools and repeat the signed-phone
file/Keychain/certificate and lifecycle checks before using real media.

No outbox reader, producer, downloader, network service or import wiring exists
in this source slice. Source review alone cannot pass these gates.
