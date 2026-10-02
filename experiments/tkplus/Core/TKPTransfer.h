#ifndef TKP_TRANSFER_H
#define TKP_TRANSFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TKP_TRANSFER_HEADER_SIZE ((size_t)48)
#define TKP_TRANSFER_MAX_PAYLOAD ((uint32_t)65536)
#define TKP_TRANSFER_MAX_SIZE UINT64_C(1073741824)
#define TKP_TRANSFER_ID_SIZE ((size_t)16)

typedef enum TKPTransferMediaKind {
    TKP_TRANSFER_MEDIA_JPEG = 1,
    TKP_TRANSFER_MEDIA_PNG = 2,
    TKP_TRANSFER_MEDIA_MP4 = 3
} TKPTransferMediaKind;

typedef enum TKPTransferRecordKind {
    TKP_TRANSFER_RECORD_CHUNK = 1,
    TKP_TRANSFER_RECORD_FINISH = 2
} TKPTransferRecordKind;

typedef enum TKPTransferLeaseState {
    TKP_TRANSFER_LEASE_EMPTY = 0,
    TKP_TRANSFER_LEASE_OPEN = 1,
    TKP_TRANSFER_LEASE_COMPLETE = 2,
    TKP_TRANSFER_LEASE_REVOKED = 3,
    TKP_TRANSFER_LEASE_CANCELLED = 4
} TKPTransferLeaseState;

typedef enum TKPTransferError {
    TKP_TRANSFER_OK = 0,
    TKP_TRANSFER_ERROR_ARGUMENT,
    TKP_TRANSFER_ERROR_LEASE_CONFIG,
    TKP_TRANSFER_ERROR_ALREADY_INITIALIZED,
    TKP_TRANSFER_ERROR_INVALID_LEASE,
    TKP_TRANSFER_ERROR_TERMINAL_COMPLETE,
    TKP_TRANSFER_ERROR_TERMINAL_REVOKED,
    TKP_TRANSFER_ERROR_TERMINAL_CANCELLED,
    TKP_TRANSFER_ERROR_FRAME_TOO_SHORT,
    TKP_TRANSFER_ERROR_MAGIC,
    TKP_TRANSFER_ERROR_VERSION,
    TKP_TRANSFER_ERROR_RESERVED,
    TKP_TRANSFER_ERROR_RECORD_KIND,
    TKP_TRANSFER_ERROR_MEDIA_KIND,
    TKP_TRANSFER_ERROR_GENERATION,
    TKP_TRANSFER_ERROR_TRANSFER_ID,
    TKP_TRANSFER_ERROR_SEQUENCE,
    TKP_TRANSFER_ERROR_PAYLOAD_TOO_LARGE,
    TKP_TRANSFER_ERROR_FRAME_SIZE,
    TKP_TRANSFER_ERROR_EMPTY_CHUNK,
    TKP_TRANSFER_ERROR_FINISH_PAYLOAD,
    TKP_TRANSFER_ERROR_SIZE_EXCEEDED,
    TKP_TRANSFER_ERROR_SIZE_MISMATCH
} TKPTransferError;

/*
 * Host-owned accounting state for one transfer. Initialize it to zero before
 * calling tkp_transfer_lease_init(). The host must preserve this object for the
 * lifetime of the lease and must not edit its fields after initialization.
 * Serialize ALL access to a lease on one executor or under one host-owned lock,
 * including inspection, accept, cancel and revoke. This API is not thread-safe;
 * a lock callback must not mutate it concurrently with an in-flight accept.
 * Completion is accounting only. Independently revocable host session/import
 * authority must still be checked before preview, confirmation and commit.
 *
 * This API validates framing and accounts byte lengths only. It does not
 * encrypt data or establish iOS/OS sandbox isolation. It has no path, URL,
 * cookie, or credential fields. Payload bytes are opaque: they are neither
 * inspected nor retained, so the host must supply the intended media.
 */
typedef struct TKPTransferLease {
    uint64_t generation;
    uint64_t expected_size;
    uint64_t received_size;
    uint64_t next_sequence;
    uint8_t transfer_id[16];
    TKPTransferLeaseState state;
    uint8_t media_kind;
    uint8_t reserved[3];
} TKPTransferLease;

#define TKP_TRANSFER_LEASE_INITIALIZER {0}

/*
 * Initialize a zero-initialized lease with host-created identity and bounds.
 * Valid generations and IDs are nonzero; expected_size is 1..1 GiB; media_kind
 * must be JPEG, PNG, or MP4. A lease cannot be initialized more than once.
 */
TKPTransferError tkp_transfer_lease_init(
    TKPTransferLease *lease,
    uint64_t generation,
    const uint8_t transfer_id[TKP_TRANSFER_ID_SIZE],
    uint8_t media_kind,
    uint64_t expected_size);

/*
 * Validate one complete wire frame. Chunk sequence numbers start at zero and
 * increase by one; the finish record uses the next sequence number. A valid
 * finish completes the lease only when received_size equals expected_size.
 * Any malformed frame or lease mismatch revokes an open lease. Calls against
 * terminal leases return a terminal error without changing that state.
 */
TKPTransferError tkp_transfer_lease_accept(
    TKPTransferLease *lease,
    const uint8_t *frame,
    size_t frame_size);

/* Revoke or cancel an open lease. Terminal states cannot be reopened. */
TKPTransferError tkp_transfer_lease_revoke(TKPTransferLease *lease);
TKPTransferError tkp_transfer_lease_cancel(TKPTransferLease *lease);

#ifdef __cplusplus
}
#endif

#endif
