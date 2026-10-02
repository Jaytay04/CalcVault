#include "TKPTransfer.h"

static uint32_t tkp_read_u32_le(const uint8_t *bytes) {
    return ((uint32_t)bytes[0]) |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static uint64_t tkp_read_u64_le(const uint8_t *bytes) {
    return ((uint64_t)bytes[0]) |
           ((uint64_t)bytes[1] << 8) |
           ((uint64_t)bytes[2] << 16) |
           ((uint64_t)bytes[3] << 24) |
           ((uint64_t)bytes[4] << 32) |
           ((uint64_t)bytes[5] << 40) |
           ((uint64_t)bytes[6] << 48) |
           ((uint64_t)bytes[7] << 56);
}

static int tkp_media_kind_is_valid(uint8_t media_kind) {
    return media_kind == (uint8_t)TKP_TRANSFER_MEDIA_JPEG ||
           media_kind == (uint8_t)TKP_TRANSFER_MEDIA_PNG ||
           media_kind == (uint8_t)TKP_TRANSFER_MEDIA_MP4;
}

static int tkp_bytes_are_zero(const uint8_t *bytes, size_t length) {
    size_t index;
    uint8_t aggregate = 0;

    for (index = 0; index < length; ++index) {
        aggregate = (uint8_t)(aggregate | bytes[index]);
    }
    return aggregate == 0;
}

static int tkp_bytes_equal(const uint8_t *left, const uint8_t *right, size_t length) {
    size_t index;
    uint8_t difference = 0;

    for (index = 0; index < length; ++index) {
        difference = (uint8_t)(difference | (uint8_t)(left[index] ^ right[index]));
    }
    return difference == 0;
}

static TKPTransferError tkp_terminal_error(const TKPTransferLease *lease) {
    if (lease->state == TKP_TRANSFER_LEASE_COMPLETE) {
        return TKP_TRANSFER_ERROR_TERMINAL_COMPLETE;
    }
    if (lease->state == TKP_TRANSFER_LEASE_REVOKED) {
        return TKP_TRANSFER_ERROR_TERMINAL_REVOKED;
    }
    if (lease->state == TKP_TRANSFER_LEASE_CANCELLED) {
        return TKP_TRANSFER_ERROR_TERMINAL_CANCELLED;
    }
    return TKP_TRANSFER_ERROR_INVALID_LEASE;
}

static TKPTransferError tkp_revoke_with_error(
    TKPTransferLease *lease,
    TKPTransferError error) {
    lease->state = TKP_TRANSFER_LEASE_REVOKED;
    return error;
}

TKPTransferError tkp_transfer_lease_init(
    TKPTransferLease *lease,
    uint64_t generation,
    const uint8_t transfer_id[TKP_TRANSFER_ID_SIZE],
    uint8_t media_kind,
    uint64_t expected_size) {
    if (lease == NULL || transfer_id == NULL) {
        return TKP_TRANSFER_ERROR_ARGUMENT;
    }
    if (lease->state != TKP_TRANSFER_LEASE_EMPTY) {
        return TKP_TRANSFER_ERROR_ALREADY_INITIALIZED;
    }
    if (generation == 0 || tkp_bytes_are_zero(transfer_id, TKP_TRANSFER_ID_SIZE) ||
        !tkp_media_kind_is_valid(media_kind) || expected_size == 0 ||
        expected_size > TKP_TRANSFER_MAX_SIZE) {
        return TKP_TRANSFER_ERROR_LEASE_CONFIG;
    }

    lease->generation = generation;
    lease->expected_size = expected_size;
    lease->received_size = 0;
    lease->next_sequence = 0;
    for (size_t index = 0; index < TKP_TRANSFER_ID_SIZE; ++index) {
        lease->transfer_id[index] = transfer_id[index];
    }
    lease->media_kind = media_kind;
    lease->state = TKP_TRANSFER_LEASE_OPEN;
    for (size_t index = 0; index < sizeof(lease->reserved); ++index) {
        lease->reserved[index] = 0;
    }
    return TKP_TRANSFER_OK;
}

TKPTransferError tkp_transfer_lease_accept(
    TKPTransferLease *lease,
    const uint8_t *frame,
    size_t frame_size) {
    uint8_t record_kind;
    uint8_t media_kind;
    uint64_t generation;
    uint64_t sequence;
    uint32_t payload_size;
    uint64_t remaining_size;

    if (lease == NULL) {
        return TKP_TRANSFER_ERROR_ARGUMENT;
    }
    if (lease->state != TKP_TRANSFER_LEASE_OPEN) {
        if (lease->state == TKP_TRANSFER_LEASE_COMPLETE ||
            lease->state == TKP_TRANSFER_LEASE_REVOKED ||
            lease->state == TKP_TRANSFER_LEASE_CANCELLED) {
            return tkp_terminal_error(lease);
        }
        return TKP_TRANSFER_ERROR_INVALID_LEASE;
    }
    if (frame == NULL) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_ARGUMENT);
    }
    if (lease->generation == 0 || lease->expected_size == 0 ||
        lease->expected_size > TKP_TRANSFER_MAX_SIZE ||
        lease->received_size > lease->expected_size ||
        lease->next_sequence == UINT64_MAX ||
        !tkp_media_kind_is_valid(lease->media_kind) ||
        tkp_bytes_are_zero(lease->transfer_id, TKP_TRANSFER_ID_SIZE) ||
        !tkp_bytes_are_zero(lease->reserved, sizeof(lease->reserved))) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_INVALID_LEASE);
    }
    if (frame_size < TKP_TRANSFER_HEADER_SIZE) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_FRAME_TOO_SHORT);
    }

    if (frame[0] != (uint8_t)'T' || frame[1] != (uint8_t)'K' ||
        frame[2] != (uint8_t)'P' || frame[3] != (uint8_t)'1') {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_MAGIC);
    }
    if (frame[4] != 1) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_VERSION);
    }
    if (frame[7] != 0 || !tkp_bytes_are_zero(frame + 44, 4)) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_RESERVED);
    }

    record_kind = frame[5];
    if (record_kind != (uint8_t)TKP_TRANSFER_RECORD_CHUNK &&
        record_kind != (uint8_t)TKP_TRANSFER_RECORD_FINISH) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_RECORD_KIND);
    }
    media_kind = frame[6];
    if (!tkp_media_kind_is_valid(media_kind)) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_MEDIA_KIND);
    }
    if (media_kind != lease->media_kind) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_MEDIA_KIND);
    }

    generation = tkp_read_u64_le(frame + 8);
    if (generation != lease->generation) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_GENERATION);
    }
    if (!tkp_bytes_equal(frame + 16, lease->transfer_id, TKP_TRANSFER_ID_SIZE)) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_TRANSFER_ID);
    }
    sequence = tkp_read_u64_le(frame + 32);
    if (sequence != lease->next_sequence) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_SEQUENCE);
    }
    payload_size = tkp_read_u32_le(frame + 40);
    if (payload_size > TKP_TRANSFER_MAX_PAYLOAD) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_PAYLOAD_TOO_LARGE);
    }
    if (frame_size != TKP_TRANSFER_HEADER_SIZE + (size_t)payload_size) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_FRAME_SIZE);
    }

    if (record_kind == (uint8_t)TKP_TRANSFER_RECORD_CHUNK) {
        if (payload_size == 0) {
            return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_EMPTY_CHUNK);
        }
        remaining_size = lease->expected_size - lease->received_size;
        if ((uint64_t)payload_size > remaining_size) {
            return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_SIZE_EXCEEDED);
        }
        lease->received_size += (uint64_t)payload_size;
        lease->next_sequence += UINT64_C(1);
        return TKP_TRANSFER_OK;
    }

    if (payload_size != 0) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_FINISH_PAYLOAD);
    }
    if (lease->received_size != lease->expected_size) {
        return tkp_revoke_with_error(lease, TKP_TRANSFER_ERROR_SIZE_MISMATCH);
    }
    lease->state = TKP_TRANSFER_LEASE_COMPLETE;
    return TKP_TRANSFER_OK;
}

TKPTransferError tkp_transfer_lease_revoke(TKPTransferLease *lease) {
    if (lease == NULL) {
        return TKP_TRANSFER_ERROR_ARGUMENT;
    }
    if (lease->state == TKP_TRANSFER_LEASE_COMPLETE ||
        lease->state == TKP_TRANSFER_LEASE_REVOKED ||
        lease->state == TKP_TRANSFER_LEASE_CANCELLED) {
        return tkp_terminal_error(lease);
    }
    if (lease->state != TKP_TRANSFER_LEASE_OPEN) {
        return TKP_TRANSFER_ERROR_INVALID_LEASE;
    }
    lease->state = TKP_TRANSFER_LEASE_REVOKED;
    return TKP_TRANSFER_OK;
}

TKPTransferError tkp_transfer_lease_cancel(TKPTransferLease *lease) {
    if (lease == NULL) {
        return TKP_TRANSFER_ERROR_ARGUMENT;
    }
    if (lease->state == TKP_TRANSFER_LEASE_COMPLETE ||
        lease->state == TKP_TRANSFER_LEASE_REVOKED ||
        lease->state == TKP_TRANSFER_LEASE_CANCELLED) {
        return tkp_terminal_error(lease);
    }
    if (lease->state != TKP_TRANSFER_LEASE_OPEN) {
        return TKP_TRANSFER_ERROR_INVALID_LEASE;
    }
    lease->state = TKP_TRANSFER_LEASE_CANCELLED;
    return TKP_TRANSFER_OK;
}
