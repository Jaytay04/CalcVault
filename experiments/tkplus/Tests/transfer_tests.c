#include "../Core/TKPTransfer.h"

#include <stdio.h>
#include <string.h>

static unsigned int failures = 0;
static unsigned int checks = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        ++checks;                                                               \
        if (!(condition)) {                                                     \
            ++failures;                                                        \
            (void)fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,    \
                          #condition);                                         \
        }                                                                       \
    } while (0)

static const uint8_t valid_id[TKP_TRANSFER_ID_SIZE] = {
    0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
    0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f
};

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value & UINT32_C(0xff));
    bytes[1] = (uint8_t)((value >> 8) & UINT32_C(0xff));
    bytes[2] = (uint8_t)((value >> 16) & UINT32_C(0xff));
    bytes[3] = (uint8_t)((value >> 24) & UINT32_C(0xff));
}

static void write_u64_le(uint8_t *bytes, uint64_t value) {
    size_t index;
    for (index = 0; index < 8; ++index) {
        bytes[index] = (uint8_t)(value & UINT64_C(0xff));
        value >>= 8;
    }
}

static size_t make_frame(
    uint8_t *frame,
    uint8_t record_kind,
    uint8_t media_kind,
    uint64_t generation,
    const uint8_t id[TKP_TRANSFER_ID_SIZE],
    uint64_t sequence,
    uint32_t payload_size) {
    size_t index;

    (void)memset(frame, 0, TKP_TRANSFER_HEADER_SIZE + (size_t)payload_size);
    frame[0] = (uint8_t)'T';
    frame[1] = (uint8_t)'K';
    frame[2] = (uint8_t)'P';
    frame[3] = (uint8_t)'1';
    frame[4] = 1;
    frame[5] = record_kind;
    frame[6] = media_kind;
    write_u64_le(frame + 8, generation);
    for (index = 0; index < TKP_TRANSFER_ID_SIZE; ++index) {
        frame[16 + index] = id[index];
    }
    write_u64_le(frame + 32, sequence);
    write_u32_le(frame + 40, payload_size);
    for (index = 0; index < (size_t)payload_size; ++index) {
        frame[TKP_TRANSFER_HEADER_SIZE + index] = (uint8_t)(index & 0xffU);
    }
    return TKP_TRANSFER_HEADER_SIZE + (size_t)payload_size;
}

static TKPTransferLease new_lease(uint64_t expected_size) {
    TKPTransferLease lease = TKP_TRANSFER_LEASE_INITIALIZER;
    CHECK(tkp_transfer_lease_init(
              &lease,
              UINT64_C(7),
              valid_id,
              (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
              expected_size) == TKP_TRANSFER_OK);
    return lease;
}

static void expect_rejected_frame(
    uint8_t *frame,
    size_t frame_size,
    TKPTransferError expected_error) {
    TKPTransferLease lease = new_lease(UINT64_C(4));
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == expected_error);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);
}

static void test_success_and_terminal_complete(void) {
    TKPTransferLease lease = new_lease(UINT64_C(5));
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + TKP_TRANSFER_MAX_PAYLOAD];
    size_t frame_size = make_frame(
        frame,
        (uint8_t)TKP_TRANSFER_RECORD_CHUNK,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
        UINT64_C(7), valid_id, UINT64_C(0), UINT32_C(3));

    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(lease.received_size == UINT64_C(3));
    CHECK(lease.next_sequence == UINT64_C(1));
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_OPEN);

    frame_size = make_frame(
        frame,
        (uint8_t)TKP_TRANSFER_RECORD_CHUNK,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
        UINT64_C(7), valid_id, UINT64_C(1), UINT32_C(2));
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(lease.received_size == UINT64_C(5));

    frame_size = make_frame(
        frame,
        (uint8_t)TKP_TRANSFER_RECORD_FINISH,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
        UINT64_C(7), valid_id, UINT64_C(2), UINT32_C(0));
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(tkp_transfer_lease_accept(&lease, NULL, 0) ==
          TKP_TRANSFER_ERROR_TERMINAL_COMPLETE);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(tkp_transfer_lease_revoke(&lease) == TKP_TRANSFER_ERROR_TERMINAL_COMPLETE);
    CHECK(tkp_transfer_lease_cancel(&lease) == TKP_TRANSFER_ERROR_TERMINAL_COMPLETE);
    CHECK(tkp_transfer_lease_init(
              &lease, UINT64_C(8), valid_id,
              (uint8_t)TKP_TRANSFER_MEDIA_PNG, UINT64_C(5)) ==
          TKP_TRANSFER_ERROR_ALREADY_INITIALIZED);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_COMPLETE);
}

static void test_identity_and_sequence_mismatches(void) {
    TKPTransferLease lease;
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + 1];
    uint8_t wrong_id[TKP_TRANSFER_ID_SIZE];
    size_t frame_size;

    lease = new_lease(UINT64_C(1));
    (void)memcpy(wrong_id, valid_id, sizeof(wrong_id));
    wrong_id[4] ^= UINT8_C(0x80);
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), wrong_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_TRANSFER_ID);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(1));
    frame_size = make_frame(frame, 1, 1, UINT64_C(8), valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_GENERATION);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(1));
    frame_size = make_frame(frame, 1, 2, UINT64_C(7), valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_MEDIA_KIND);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(2));
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), valid_id, 1, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_SEQUENCE);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(2));
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_SEQUENCE);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(3));
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), valid_id, 1, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    frame_size = make_frame(frame, 1, 1, UINT64_C(7), valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_SEQUENCE);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);
}

static void test_malformed_frames_revoke(void) {
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + TKP_TRANSFER_MAX_PAYLOAD];
    size_t frame_size;

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    frame[0] = (uint8_t)'X';
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_MAGIC);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    frame[4] = 2;
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_VERSION);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    frame[7] = 1;
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_RESERVED);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    frame[44] = 1;
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_RESERVED);

    frame_size = make_frame(frame, 3, 1, 7, valid_id, 0, 1);
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_RECORD_KIND);

    frame_size = make_frame(frame, 1, 9, 7, valid_id, 0, 1);
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_MEDIA_KIND);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    expect_rejected_frame(frame, TKP_TRANSFER_HEADER_SIZE - 1,
                          TKP_TRANSFER_ERROR_FRAME_TOO_SHORT);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    expect_rejected_frame(frame, frame_size - 1, TKP_TRANSFER_ERROR_FRAME_SIZE);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 0);
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_EMPTY_CHUNK);

    frame_size = make_frame(frame, 2, 1, 7, valid_id, 0, 1);
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_FINISH_PAYLOAD);

    frame_size = make_frame(frame, 2, 1, 7, valid_id, 0, 0);
    expect_rejected_frame(frame, frame_size + 1, TKP_TRANSFER_ERROR_FRAME_SIZE);

    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    write_u32_le(frame + 40, TKP_TRANSFER_MAX_PAYLOAD + UINT32_C(1));
    expect_rejected_frame(frame, frame_size, TKP_TRANSFER_ERROR_PAYLOAD_TOO_LARGE);
}

static void test_bounds_and_missing_finish(void) {
    TKPTransferLease lease = new_lease(UINT64_C(3));
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + 4];
    size_t frame_size = make_frame(frame, 2, 1, 7, valid_id, 0, 0);

    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_SIZE_MISMATCH);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(3));
    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 4);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_SIZE_EXCEEDED);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(3));
    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 3);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_OPEN);
    CHECK(lease.received_size == UINT64_C(3));
    CHECK(tkp_transfer_lease_cancel(&lease) == TKP_TRANSFER_OK);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_CANCELLED);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) ==
          TKP_TRANSFER_ERROR_TERMINAL_CANCELLED);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_CANCELLED);
    CHECK(tkp_transfer_lease_init(
              &lease, UINT64_C(7), valid_id,
              (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(3)) ==
          TKP_TRANSFER_ERROR_ALREADY_INITIALIZED);
    CHECK(tkp_transfer_lease_revoke(&lease) ==
          TKP_TRANSFER_ERROR_TERMINAL_CANCELLED);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_CANCELLED);
}

static void test_exact_maximum_size(void) {
    TKPTransferLease lease = new_lease(TKP_TRANSFER_MAX_SIZE);
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + TKP_TRANSFER_MAX_PAYLOAD];
    const uint32_t full_payload = TKP_TRANSFER_MAX_PAYLOAD;
    const uint64_t chunk_count = TKP_TRANSFER_MAX_SIZE / (uint64_t)full_payload;
    uint64_t sequence;
    size_t frame_size;

    for (sequence = 0; sequence < chunk_count; ++sequence) {
        frame_size = make_frame(
            frame, (uint8_t)TKP_TRANSFER_RECORD_CHUNK,
            (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(7), valid_id,
            sequence, full_payload);
        CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    }
    CHECK(lease.received_size == TKP_TRANSFER_MAX_SIZE);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_OPEN);

    frame_size = make_frame(
        frame, (uint8_t)TKP_TRANSFER_RECORD_FINISH,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(7), valid_id,
        chunk_count, UINT32_C(0));
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_COMPLETE);
}

static void test_argument_and_revoke_behavior(void) {
    TKPTransferLease lease = TKP_TRANSFER_LEASE_INITIALIZER;
    const uint8_t zero_id[TKP_TRANSFER_ID_SIZE] = {0};
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + 1];
    size_t frame_size;

    CHECK(tkp_transfer_lease_init(NULL, 1, valid_id, 1, 1) ==
          TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(tkp_transfer_lease_init(&lease, 1, NULL, 1, 1) ==
          TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(tkp_transfer_lease_init(&lease, 0, valid_id, 1, 1) ==
          TKP_TRANSFER_ERROR_LEASE_CONFIG);
    CHECK(tkp_transfer_lease_init(&lease, 1, zero_id, 1, 1) ==
          TKP_TRANSFER_ERROR_LEASE_CONFIG);
    CHECK(tkp_transfer_lease_init(&lease, 1, valid_id, 4, 1) ==
          TKP_TRANSFER_ERROR_LEASE_CONFIG);
    CHECK(tkp_transfer_lease_init(&lease, 1, valid_id, 1, 0) ==
          TKP_TRANSFER_ERROR_LEASE_CONFIG);
    CHECK(tkp_transfer_lease_init(&lease, 1, valid_id, 1,
                                  TKP_TRANSFER_MAX_SIZE + UINT64_C(1)) ==
          TKP_TRANSFER_ERROR_LEASE_CONFIG);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_EMPTY);
    CHECK(tkp_transfer_lease_accept(NULL, NULL, 0) == TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(tkp_transfer_lease_revoke(NULL) == TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(tkp_transfer_lease_cancel(NULL) == TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(tkp_transfer_lease_accept(&lease, frame, sizeof(frame)) ==
          TKP_TRANSFER_ERROR_INVALID_LEASE);

    lease = new_lease(UINT64_C(1));
    CHECK(tkp_transfer_lease_revoke(&lease) == TKP_TRANSFER_OK);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);
    CHECK(tkp_transfer_lease_accept(&lease, NULL, 0) ==
          TKP_TRANSFER_ERROR_TERMINAL_REVOKED);
    CHECK(tkp_transfer_lease_cancel(&lease) == TKP_TRANSFER_ERROR_TERMINAL_REVOKED);
    CHECK(tkp_transfer_lease_revoke(&lease) == TKP_TRANSFER_ERROR_TERMINAL_REVOKED);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(1));
    CHECK(tkp_transfer_lease_accept(&lease, NULL, 0) == TKP_TRANSFER_ERROR_ARGUMENT);
    CHECK(lease.state == (uint8_t)TKP_TRANSFER_LEASE_REVOKED);

    lease = new_lease(UINT64_C(1));
    frame_size = make_frame(frame, 1, 1, 7, valid_id, 0, 1);
    CHECK(tkp_transfer_lease_accept(&lease, frame, frame_size) == TKP_TRANSFER_OK);
}

int main(void) {
    test_success_and_terminal_complete();
    test_identity_and_sequence_mismatches();
    test_malformed_frames_revoke();
    test_bounds_and_missing_finish();
    test_exact_maximum_size();
    test_argument_and_revoke_behavior();

    if (failures != 0U) {
        (void)fprintf(stderr, "%u of %u checks failed\n", failures, checks);
        return 1;
    }
    (void)printf("PASS: %u checks\n", checks);
    return 0;
}
