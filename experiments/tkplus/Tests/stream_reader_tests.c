#include "../Core/TKPStreamReader.h"

#include <stdio.h>
#include <string.h>

static unsigned int checks = 0U;
static unsigned int failures = 0U;

#define CHECK(condition)                                                        \
    do {                                                                        \
        ++checks;                                                               \
        if (!(condition)) {                                                     \
            ++failures;                                                        \
            (void)fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,     \
                          #condition);                                          \
        }                                                                       \
    } while (0)

static const uint8_t valid_id[TKP_TRANSFER_ID_SIZE] = {
    0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
    0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f
};

typedef enum SinkAction {
    SINK_ACTION_NONE = 0,
    SINK_ACTION_CANCEL,
    SINK_ACTION_REVOKE,
    SINK_ACTION_REENTRANT_FEED,
    SINK_ACTION_REENTRANT_FINALIZE
} SinkAction;

typedef struct SinkContext {
    TKPStreamReader *reader;
    unsigned int calls;
    uint64_t bytes_seen;
    uint64_t next_expected_sequence;
    uint64_t byte_sum;
    int return_value;
    SinkAction action;
    TKPStreamReaderError action_result;
} SinkContext;

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value & UINT32_C(0xff));
    bytes[1] = (uint8_t)((value >> 8) & UINT32_C(0xff));
    bytes[2] = (uint8_t)((value >> 16) & UINT32_C(0xff));
    bytes[3] = (uint8_t)((value >> 24) & UINT32_C(0xff));
}

static void write_u64_le(uint8_t *bytes, uint64_t value) {
    size_t index;
    for (index = 0U; index < 8U; ++index) {
        bytes[index] = (uint8_t)(value & UINT64_C(0xff));
        value >>= 8;
    }
}

static uint64_t min_encoded_budget(uint64_t expected_size) {
    const uint64_t chunks =
        (expected_size + (uint64_t)TKP_TRANSFER_MAX_PAYLOAD - UINT64_C(1)) /
        (uint64_t)TKP_TRANSFER_MAX_PAYLOAD;
    return expected_size +
           ((chunks + UINT64_C(1)) * (uint64_t)TKP_TRANSFER_HEADER_SIZE);
}

static uint32_t min_record_budget(uint64_t expected_size) {
    const uint64_t chunks =
        (expected_size + (uint64_t)TKP_TRANSFER_MAX_PAYLOAD - UINT64_C(1)) /
        (uint64_t)TKP_TRANSFER_MAX_PAYLOAD;
    return (uint32_t)(chunks + UINT64_C(1));
}

static size_t make_frame(
    uint8_t *frame,
    uint8_t kind,
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
    frame[4] = UINT8_C(1);
    frame[5] = kind;
    frame[6] = media_kind;
    write_u64_le(frame + 8U, generation);
    for (index = 0U; index < TKP_TRANSFER_ID_SIZE; ++index) {
        frame[16U + index] = id[index];
    }
    write_u64_le(frame + 32U, sequence);
    write_u32_le(frame + 40U, payload_size);
    for (index = 0U; index < (size_t)payload_size; ++index) {
        frame[TKP_TRANSFER_HEADER_SIZE + index] =
            (uint8_t)((sequence * UINT64_C(17) + (uint64_t)index) &
                      UINT64_C(0xff));
    }
    return TKP_TRANSFER_HEADER_SIZE + (size_t)payload_size;
}

static size_t append_chunk(
    uint8_t *stream,
    size_t offset,
    uint64_t sequence,
    uint32_t payload_size) {
    return offset + make_frame(
        stream + offset,
        (uint8_t)TKP_TRANSFER_RECORD_CHUNK,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
        UINT64_C(7), valid_id, sequence, payload_size);
}

static size_t append_finish(uint8_t *stream, size_t offset, uint64_t sequence) {
    return offset + make_frame(
        stream + offset,
        (uint8_t)TKP_TRANSFER_RECORD_FINISH,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
        UINT64_C(7), valid_id, sequence, UINT32_C(0));
}

static int payload_sink(
    void *opaque,
    const uint8_t *payload,
    size_t payload_size,
    uint64_t sequence) {
    SinkContext *context = (SinkContext *)opaque;
    size_t index;

    CHECK(context != NULL);
    CHECK(payload != NULL);
    if (context == NULL || payload == NULL) {
        return 1;
    }
    CHECK(payload_size > 0U);
    CHECK(sequence == context->next_expected_sequence);
    ++context->calls;
    context->bytes_seen += (uint64_t)payload_size;
    context->next_expected_sequence = sequence + UINT64_C(1);
    for (index = 0U; index < payload_size; ++index) {
        CHECK(payload[index] ==
              (uint8_t)((sequence * UINT64_C(17) + (uint64_t)index) &
                        UINT64_C(0xff)));
        context->byte_sum += payload[index];
    }

    switch (context->action) {
        case SINK_ACTION_CANCEL:
            context->action_result = tkp_stream_reader_cancel(context->reader);
            break;
        case SINK_ACTION_REVOKE:
            context->action_result = tkp_stream_reader_revoke(context->reader);
            break;
        case SINK_ACTION_REENTRANT_FEED:
            context->action_result = tkp_stream_reader_feed(
                context->reader, NULL, 0U);
            break;
        case SINK_ACTION_REENTRANT_FINALIZE:
            context->action_result = tkp_stream_reader_finalize(context->reader);
            break;
        case SINK_ACTION_NONE:
        default:
            context->action_result = TKP_STREAM_READER_OK;
            break;
    }
    return context->return_value;
}

static void init_reader_with_budgets(
    TKPStreamReader *reader,
    SinkContext *sink_context,
    uint64_t expected_size,
    uint64_t encoded_budget,
    uint32_t record_budget) {
    (void)memset(reader, 0, sizeof(*reader));
    (void)memset(sink_context, 0, sizeof(*sink_context));
    sink_context->reader = reader;
    CHECK(tkp_stream_reader_init(
              reader, UINT64_C(7), valid_id,
              (uint8_t)TKP_TRANSFER_MEDIA_JPEG,
              expected_size, encoded_budget, record_budget,
              payload_sink, sink_context) == TKP_STREAM_READER_OK);
}

static void init_reader(
    TKPStreamReader *reader,
    SinkContext *sink_context,
    uint64_t expected_size) {
    init_reader_with_budgets(
        reader, sink_context, expected_size,
        min_encoded_budget(expected_size), min_record_budget(expected_size));
}

static void test_api_and_budget_configuration(void) {
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};
    uint8_t zero_id[TKP_TRANSFER_ID_SIZE] = {0};

    CHECK(tkp_stream_reader_init(
              NULL, 7U, valid_id, 1U, 1U, 97U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_ARGUMENT);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, NULL, 1U, 1U, 97U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_ARGUMENT);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U, 97U, 2U,
              NULL, &sink_context) == TKP_STREAM_READER_ERROR_ARGUMENT);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, zero_id, 1U, 1U, 97U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 0U, valid_id, 1U, 1U, 97U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 0U, 97U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U,
              TKP_STREAM_READER_MAX_ENCODED_BYTES + UINT64_C(1), 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U, 97U, 0U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U, 97U,
              TKP_STREAM_READER_MAX_RECORDS + UINT32_C(1),
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U, 97U, 1U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(tkp_stream_reader_init(
              &reader, 7U, valid_id, 1U, 1U, 96U, 2U,
              payload_sink, &sink_context) == TKP_STREAM_READER_ERROR_CONFIG);
    CHECK(reader.state == TKP_STREAM_READER_EMPTY);

    init_reader(&reader, &sink_context, 1U);
    CHECK(tkp_stream_reader_init(
              &reader, 8U, valid_id, 1U, 1U, 97U, 2U,
              payload_sink, &sink_context) ==
          TKP_STREAM_READER_ERROR_ALREADY_INITIALIZED);
    CHECK(tkp_stream_reader_feed(&reader, NULL, 0U) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_OPEN);
}

static void test_every_two_part_split_point(void) {
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 2U + 3U];
    size_t stream_size = make_frame(
        stream, (uint8_t)TKP_TRANSFER_RECORD_CHUNK,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(7), valid_id,
        UINT64_C(0), UINT32_C(3));
    size_t split;

    stream_size += make_frame(
        stream + stream_size, (uint8_t)TKP_TRANSFER_RECORD_FINISH,
        (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(7), valid_id,
        UINT64_C(1), UINT32_C(0));
    for (split = 0U; split <= stream_size; ++split) {
        TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
        SinkContext sink_context = {0};
        TKPStreamReaderError first;
        TKPStreamReaderError second;

        sink_context.reader = &reader;
        CHECK(tkp_stream_reader_init(
                  &reader, UINT64_C(7), valid_id,
                  (uint8_t)TKP_TRANSFER_MEDIA_JPEG, UINT64_C(3),
                  min_encoded_budget(UINT64_C(3)), UINT32_C(2),
                  payload_sink, &sink_context) == TKP_STREAM_READER_OK);
        first = tkp_stream_reader_feed(
            &reader, split == 0U ? NULL : stream, split);
        second = tkp_stream_reader_feed(
            &reader,
            split == stream_size ? NULL : stream + split,
            stream_size - split);
        CHECK(first == TKP_STREAM_READER_OK);
        CHECK(second == TKP_STREAM_READER_OK);
        CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
        CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
        CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);
        CHECK(reader.state == TKP_STREAM_READER_COMPLETE);
        CHECK(reader.records_seen == UINT32_C(2));
        CHECK(reader.encoded_bytes_seen == (uint64_t)stream_size);
        CHECK(sink_context.calls == 1U);
        CHECK(sink_context.bytes_seen == UINT64_C(3));
    }
}

static void test_one_byte_fragments_and_coalesced_records(void) {
    uint8_t small_stream[TKP_TRANSFER_HEADER_SIZE * 3U + 17U];
    uint8_t coalesced_stream[TKP_TRANSFER_HEADER_SIZE * 5U + 17U];
    size_t small_size = make_frame(
        small_stream, 1U, 1U, UINT64_C(7), valid_id, 0U, 1U);
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};
    size_t index;
    size_t offset = 0U;

    small_size += make_frame(
        small_stream + small_size, 2U, 1U, UINT64_C(7), valid_id, 1U, 0U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    for (index = 0U; index < small_size; ++index) {
        CHECK(tkp_stream_reader_feed(&reader, small_stream + index, 1U) ==
              TKP_STREAM_READER_OK);
    }
    CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
    CHECK(sink_context.calls == 1U);
    CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);

    (void)memset(&reader, 0, sizeof(reader));
    offset = append_chunk(coalesced_stream, offset, 0U, 1U);
    offset = append_chunk(coalesced_stream, offset, 1U, 3U);
    offset = append_chunk(coalesced_stream, offset, 2U, 4U);
    offset = append_chunk(coalesced_stream, offset, 3U, 9U);
    offset = append_finish(coalesced_stream, offset, 4U);
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(17),
        UINT64_C(17) + UINT64_C(5) * (uint64_t)TKP_TRANSFER_HEADER_SIZE,
        UINT32_C(5));
    CHECK(tkp_stream_reader_feed(&reader, coalesced_stream, offset) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.encoded_bytes_seen == (uint64_t)offset);
    CHECK(reader.records_seen == UINT32_C(5));
    CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
    CHECK(sink_context.calls == 4U);
    CHECK(sink_context.bytes_seen == UINT64_C(17));
    CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_COMPLETE);
}

static void test_minimum_and_maximum_payload(void) {
    uint8_t tiny_stream[TKP_TRANSFER_HEADER_SIZE * 2U + 1U];
    uint8_t max_stream[TKP_TRANSFER_HEADER_SIZE * 2U +
                       TKP_TRANSFER_MAX_PAYLOAD];
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};
    size_t tiny_size;
    size_t max_size;

    tiny_size = make_frame(
        tiny_stream, 1U, 1U, UINT64_C(7), valid_id, 0U, 1U);
    tiny_size += make_frame(
        tiny_stream + tiny_size, 2U, 1U, UINT64_C(7), valid_id, 1U, 0U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, tiny_stream, tiny_size) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.encoded_byte_budget == (uint64_t)tiny_size);
    CHECK(reader.records_seen == UINT32_C(2));
    CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);

    (void)memset(&reader, 0, sizeof(reader));
    max_size = make_frame(
        max_stream, 1U, 1U, UINT64_C(7), valid_id, 0U,
        TKP_TRANSFER_MAX_PAYLOAD);
    max_size += make_frame(
        max_stream + max_size, 2U, 1U, UINT64_C(7), valid_id, 1U, 0U);
    init_reader(&reader, &sink_context, (uint64_t)TKP_TRANSFER_MAX_PAYLOAD);
    CHECK(tkp_stream_reader_feed(&reader, max_stream, max_size) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.records_seen == UINT32_C(2));
    CHECK(sink_context.calls == 1U);
    CHECK(sink_context.bytes_seen == (uint64_t)TKP_TRANSFER_MAX_PAYLOAD);
    CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_COMPLETE);
}

static void test_explicit_eof_and_truncation(void) {
    uint8_t frames[TKP_TRANSFER_HEADER_SIZE * 2U + 2U];
    size_t chunk_size = make_frame(
        frames, 1U, 1U, UINT64_C(7), valid_id, 0U, 2U);
    size_t finish_size = make_frame(
        frames + chunk_size, 2U, 1U, UINT64_C(7), valid_id, 1U, 0U);
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};

    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_MISSING_FINISH);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_REVOKED);
    CHECK(sink_context.calls == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_feed(&reader, frames, 13U) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.buffered_size == 13U);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TRUNCATED_RECORD);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.buffered_size == 0U);
    CHECK(sink_context.calls == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_feed(
              &reader, frames, TKP_TRANSFER_HEADER_SIZE + 1U) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.buffered_size == TKP_TRANSFER_HEADER_SIZE + 1U);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TRUNCATED_RECORD);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.buffered_size == 0U);
    CHECK(sink_context.calls == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_feed(&reader, frames, chunk_size) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.records_seen == UINT32_C(1));
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_MISSING_FINISH);
    CHECK(sink_context.calls == 1U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_feed(&reader, frames, chunk_size + finish_size) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
    CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(reader.state != TKP_STREAM_READER_COMPLETE);
    CHECK(tkp_stream_reader_feed(&reader, NULL, 0U) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
    CHECK(tkp_stream_reader_finalize(&reader) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_COMPLETE);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_COMPLETE);
    CHECK(tkp_stream_reader_revoke(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_COMPLETE);
    CHECK(tkp_stream_reader_cancel(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_COMPLETE);
    CHECK(tkp_stream_reader_init(
              &reader, 8U, valid_id, 1U, 2U, 98U, 2U,
              payload_sink, &sink_context) ==
          TKP_STREAM_READER_ERROR_ALREADY_INITIALIZED);
}

static void test_trailing_and_doubled_finish(void) {
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 3U + 1U];
    uint8_t trailing = UINT8_C(0x5a);
    size_t offset;
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};

    offset = append_chunk(stream, 0U, 0U, 1U);
    offset = append_finish(stream, offset, 1U);
    stream[offset++] = trailing;
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(1),
        min_encoded_budget(UINT64_C(1)) + UINT64_C(1), UINT32_C(2));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_TRAILING_BYTES);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(sink_context.calls == 1U);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_REVOKED);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    offset = append_chunk(stream, 0U, 0U, 1U);
    offset = append_finish(stream, offset, 1U);
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(1),
        min_encoded_budget(UINT64_C(1)) + UINT64_C(1), UINT32_C(2));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_OK);
    CHECK(tkp_stream_reader_feed(&reader, &trailing, 1U) ==
          TKP_STREAM_READER_ERROR_TRAILING_BYTES);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    offset = append_chunk(stream, 0U, 0U, 1U);
    offset = append_finish(stream, offset, 1U);
    offset = append_finish(stream, offset, 2U);
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(1),
        min_encoded_budget(UINT64_C(1)) + UINT64_C(48), UINT32_C(2));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_TRAILING_BYTES);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.records_seen == UINT32_C(2));
    CHECK(sink_context.calls == 1U);
}

static void test_invalid_frames_revoke_and_stop_callbacks(void) {
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 3U + 2U];
    uint8_t wrong_id[TKP_TRANSFER_ID_SIZE];
    size_t offset;
    size_t frame_size;
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};

    offset = append_chunk(stream, 0U, 0U, 1U);
    frame_size = make_frame(
        stream + offset, 1U, 1U, 7U, valid_id, 2U, 1U);
    offset += frame_size;
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(3),
        min_encoded_budget(UINT64_C(3)) + UINT64_C(100), UINT32_C(4));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_FRAME_REJECTED);
    CHECK(reader.last_transfer_error == TKP_TRANSFER_ERROR_SEQUENCE);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(sink_context.calls == 1U);
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_TERMINAL_REVOKED);
    CHECK(sink_context.calls == 1U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    (void)memcpy(wrong_id, valid_id, sizeof(wrong_id));
    wrong_id[0] ^= UINT8_C(1);
    frame_size = make_frame(
        stream, 1U, 1U, 7U, wrong_id, 0U, 1U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, stream, frame_size) ==
          TKP_STREAM_READER_ERROR_FRAME_REJECTED);
    CHECK(reader.last_transfer_error == TKP_TRANSFER_ERROR_TRANSFER_ID);
    CHECK(sink_context.calls == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    frame_size = make_frame(stream, 1U, 1U, 8U, valid_id, 0U, 1U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, stream, frame_size) ==
          TKP_STREAM_READER_ERROR_FRAME_REJECTED);
    CHECK(reader.last_transfer_error == TKP_TRANSFER_ERROR_GENERATION);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    frame_size = make_frame(stream, 1U, 1U, 7U, valid_id, 0U, 3U);
    init_reader(&reader, &sink_context, UINT64_C(2));
    CHECK(tkp_stream_reader_feed(&reader, stream, frame_size) ==
          TKP_STREAM_READER_ERROR_FRAME_REJECTED);
    CHECK(reader.last_transfer_error == TKP_TRANSFER_ERROR_SIZE_EXCEEDED);
    CHECK(sink_context.calls == 0U);
}

static void test_header_length_and_record_budget(void) {
    uint8_t header[TKP_TRANSFER_HEADER_SIZE + 1U];
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 3U + 3U];
    size_t offset;
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};

    (void)make_frame(header, 1U, 1U, 7U, valid_id, 0U, 1U);
    write_u32_le(header + 40U, TKP_TRANSFER_MAX_PAYLOAD + UINT32_C(1));
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, header, sizeof(header)) ==
          TKP_STREAM_READER_ERROR_PAYLOAD_TOO_LARGE);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.buffered_size == 0U);
    CHECK(sink_context.calls == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    offset = append_chunk(stream, 0U, 0U, 1U);
    offset = append_chunk(stream, offset, 1U, 1U);
    (void)make_frame(stream + offset, 1U, 1U, 7U, valid_id, 2U, 1U);
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(2),
        min_encoded_budget(UINT64_C(2)) + (uint64_t)TKP_TRANSFER_HEADER_SIZE,
        UINT32_C(2));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.records_seen == UINT32_C(2));
    CHECK(reader.lease.received_size == UINT64_C(2));
    CHECK(tkp_stream_reader_feed(
              &reader, stream + offset, TKP_TRANSFER_HEADER_SIZE) ==
          TKP_STREAM_READER_ERROR_RECORD_BUDGET);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(sink_context.calls == 2U);
}

static void test_encoded_budget_and_alias_rejection(void) {
    uint8_t one_byte = UINT8_C(0x42);
    uint8_t frame[TKP_TRANSFER_HEADER_SIZE + 1U];
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};
    size_t frame_size;

    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(
              &reader, &one_byte,
              (size_t)(min_encoded_budget(UINT64_C(1)) + UINT64_C(1))) ==
          TKP_STREAM_READER_ERROR_ENCODED_BUDGET);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.encoded_bytes_seen == 0U);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    frame_size = make_frame(frame, 1U, 1U, 7U, valid_id, 0U, 1U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(
              &reader, reader.frame_buffer, frame_size) ==
          TKP_STREAM_READER_ERROR_INPUT_OVERLAP);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(sink_context.calls == 0U);
}

static void test_sink_failure_and_reentrant_terminal_actions(void) {
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 3U + 2U];
    size_t offset;
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};
    const SinkAction actions[] = {
        SINK_ACTION_CANCEL,
        SINK_ACTION_REVOKE,
        SINK_ACTION_REENTRANT_FEED,
        SINK_ACTION_REENTRANT_FINALIZE
    };
    size_t action_index;

    offset = append_chunk(stream, 0U, 0U, 1U);
    offset = append_chunk(stream, offset, 1U, 1U);
    offset = append_finish(stream, offset, 2U);
    init_reader_with_budgets(
        &reader, &sink_context, UINT64_C(2),
        min_encoded_budget(UINT64_C(2)) + UINT64_C(48), UINT32_C(3));
    sink_context.return_value = 1;
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_SINK_FAILED);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(sink_context.calls == 1U);
    CHECK(reader.records_seen == UINT32_C(1));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_ERROR_TERMINAL_REVOKED);
    CHECK(sink_context.calls == 1U);

    for (action_index = 0U;
         action_index < sizeof(actions) / sizeof(actions[0]);
         ++action_index) {
        TKPStreamReaderError expected_outer;
        TKPStreamReaderError expected_action;

        (void)memset(&reader, 0, sizeof(reader));
        sink_context = (SinkContext){0};
        init_reader_with_budgets(
            &reader, &sink_context, UINT64_C(2),
            min_encoded_budget(UINT64_C(2)) + UINT64_C(48), UINT32_C(3));
        sink_context.action = actions[action_index];
        if (actions[action_index] == SINK_ACTION_CANCEL) {
            expected_outer = TKP_STREAM_READER_ERROR_TERMINAL_CANCELLED;
            expected_action = TKP_STREAM_READER_OK;
        } else if (actions[action_index] == SINK_ACTION_REVOKE) {
            expected_outer = TKP_STREAM_READER_ERROR_TERMINAL_REVOKED;
            expected_action = TKP_STREAM_READER_OK;
        } else {
            expected_outer = TKP_STREAM_READER_ERROR_TERMINAL_REVOKED;
            expected_action = TKP_STREAM_READER_ERROR_REENTRANT;
        }
        CHECK(tkp_stream_reader_feed(&reader, stream, offset) == expected_outer);
        CHECK(sink_context.action_result == expected_action);
        CHECK(sink_context.calls == 1U);
        CHECK(reader.records_seen == UINT32_C(1));
        CHECK(reader.state == (actions[action_index] == SINK_ACTION_CANCEL
                                   ? TKP_STREAM_READER_CANCELLED
                                   : TKP_STREAM_READER_REVOKED));
        CHECK(reader.buffered_size == 0U);
        CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
              (reader.state == TKP_STREAM_READER_CANCELLED
                   ? TKP_STREAM_READER_ERROR_TERMINAL_CANCELLED
                   : TKP_STREAM_READER_ERROR_TERMINAL_REVOKED));
        CHECK(sink_context.calls == 1U);
    }
}

static void test_cancel_and_revoke_after_finish_gate(void) {
    uint8_t stream[TKP_TRANSFER_HEADER_SIZE * 2U + 1U];
    size_t offset = append_chunk(stream, 0U, 0U, 1U);
    TKPStreamReader reader = TKP_STREAM_READER_INITIALIZER;
    SinkContext sink_context = {0};

    offset = append_finish(stream, offset, 1U);
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_FINISH_SEEN);
    CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(tkp_stream_reader_cancel(&reader) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_CANCELLED);
    CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_CANCELLED);

    (void)memset(&reader, 0, sizeof(reader));
    sink_context = (SinkContext){0};
    init_reader(&reader, &sink_context, UINT64_C(1));
    CHECK(tkp_stream_reader_feed(&reader, stream, offset) ==
          TKP_STREAM_READER_OK);
    CHECK(tkp_stream_reader_revoke(&reader) == TKP_STREAM_READER_OK);
    CHECK(reader.state == TKP_STREAM_READER_REVOKED);
    CHECK(reader.lease.state == TKP_TRANSFER_LEASE_COMPLETE);
    CHECK(tkp_stream_reader_finalize(&reader) ==
          TKP_STREAM_READER_ERROR_TERMINAL_REVOKED);
}

int main(void) {
    test_api_and_budget_configuration();
    test_every_two_part_split_point();
    test_one_byte_fragments_and_coalesced_records();
    test_minimum_and_maximum_payload();
    test_explicit_eof_and_truncation();
    test_trailing_and_doubled_finish();
    test_invalid_frames_revoke_and_stop_callbacks();
    test_header_length_and_record_budget();
    test_encoded_budget_and_alias_rejection();
    test_sink_failure_and_reentrant_terminal_actions();
    test_cancel_and_revoke_after_finish_gate();

    if (failures != 0U) {
        (void)fprintf(stderr, "%u of %u checks failed\n", failures, checks);
        return 1;
    }
    (void)printf("PASS: %u checks\n", checks);
    return 0;
}
