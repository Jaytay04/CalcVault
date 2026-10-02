#include "TKPStreamReader.h"

#include <string.h>

#define TKP_STREAM_READER_INITIALIZED_MARKER UINT8_C(0xa7)

static uint32_t tkp_stream_read_u32_le(const uint8_t *bytes) {
    return ((uint32_t)bytes[0]) |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

/* Treat unrepresentable pointer spans as overlap and fail closed. */
static int tkp_stream_input_overlaps_reader(
    const TKPStreamReader *reader,
    const uint8_t *bytes,
    size_t size) {
    const uintptr_t input_start = (uintptr_t)(const void *)bytes;
    const uintptr_t reader_start = (uintptr_t)(const void *)reader;
    uintptr_t input_end;
    uintptr_t reader_end;

    if ((uintmax_t)size > (uintmax_t)(UINTPTR_MAX - input_start) ||
        (uintmax_t)sizeof(*reader) >
            (uintmax_t)(UINTPTR_MAX - reader_start)) {
        return 1;
    }
    input_end = input_start + (uintptr_t)size;
    reader_end = reader_start + (uintptr_t)sizeof(*reader);
    return input_start < reader_end && reader_start < input_end;
}

static int tkp_stream_reader_state_is_valid(TKPStreamReaderState state) {
    return state == TKP_STREAM_READER_OPEN ||
           state == TKP_STREAM_READER_FINISH_SEEN ||
           state == TKP_STREAM_READER_COMPLETE ||
           state == TKP_STREAM_READER_REVOKED ||
           state == TKP_STREAM_READER_CANCELLED;
}

static int tkp_stream_reader_is_valid(const TKPStreamReader *reader) {
    return reader != NULL &&
           reader->initialized == TKP_STREAM_READER_INITIALIZED_MARKER &&
           tkp_stream_reader_state_is_valid(reader->state) &&
           reader->sink != NULL &&
           reader->encoded_byte_budget > 0 &&
           reader->encoded_byte_budget <= TKP_STREAM_READER_MAX_ENCODED_BYTES &&
           reader->record_budget > 0 &&
           reader->record_budget <= TKP_STREAM_READER_MAX_RECORDS &&
           reader->encoded_bytes_seen <= reader->encoded_byte_budget &&
           reader->records_seen <= reader->record_budget &&
           reader->buffered_size <= TKP_STREAM_READER_FRAME_CAPACITY &&
           reader->frame_size <= TKP_STREAM_READER_FRAME_CAPACITY;
}

static TKPStreamReaderError tkp_stream_terminal_error(
    const TKPStreamReader *reader) {
    if (reader->state == TKP_STREAM_READER_COMPLETE) {
        return TKP_STREAM_READER_ERROR_TERMINAL_COMPLETE;
    }
    if (reader->state == TKP_STREAM_READER_REVOKED) {
        return TKP_STREAM_READER_ERROR_TERMINAL_REVOKED;
    }
    if (reader->state == TKP_STREAM_READER_CANCELLED) {
        return TKP_STREAM_READER_ERROR_TERMINAL_CANCELLED;
    }
    return TKP_STREAM_READER_ERROR_INVALID_READER;
}

static int tkp_stream_reader_is_terminal(const TKPStreamReader *reader) {
    return reader->state == TKP_STREAM_READER_COMPLETE ||
           reader->state == TKP_STREAM_READER_REVOKED ||
           reader->state == TKP_STREAM_READER_CANCELLED;
}

/* Best-effort clearing; callers make no forensic-zeroization claim. */
static void tkp_stream_clear_frame(TKPStreamReader *reader) {
    if (reader->buffered_size != 0U) {
        (void)memset(reader->frame_buffer, 0, reader->buffered_size);
    }
    reader->buffered_size = 0U;
    reader->frame_size = 0U;
    reader->declared_payload_size = 0U;
}

static void tkp_stream_revoke_lease_if_open(TKPStreamReader *reader) {
    if (reader->lease.state == TKP_TRANSFER_LEASE_OPEN) {
        (void)tkp_transfer_lease_revoke(&reader->lease);
    }
}

static TKPStreamReaderError tkp_stream_fail(
    TKPStreamReader *reader,
    TKPStreamReaderError error) {
    if (!tkp_stream_reader_is_terminal(reader)) {
        reader->state = TKP_STREAM_READER_REVOKED;
        tkp_stream_revoke_lease_if_open(reader);
    }
    if (reader->busy == 0U) {
        tkp_stream_clear_frame(reader);
    }
    return error;
}

static TKPStreamReaderError tkp_stream_fail_reentrant(
    TKPStreamReader *reader) {
    if (reader->initialized == TKP_STREAM_READER_INITIALIZED_MARKER &&
        (reader->state == TKP_STREAM_READER_OPEN ||
         reader->state == TKP_STREAM_READER_FINISH_SEEN)) {
        reader->state = TKP_STREAM_READER_REVOKED;
        tkp_stream_revoke_lease_if_open(reader);
    }
    return TKP_STREAM_READER_ERROR_REENTRANT;
}

static TKPStreamReaderError tkp_stream_invalid_frame(
    TKPStreamReader *reader,
    TKPTransferError transfer_error) {
    reader->last_transfer_error = transfer_error;
    reader->state = TKP_STREAM_READER_REVOKED;
    tkp_stream_revoke_lease_if_open(reader);
    return TKP_STREAM_READER_ERROR_FRAME_REJECTED;
}

TKPStreamReaderError tkp_stream_reader_init(
    TKPStreamReader *reader,
    uint64_t generation,
    const uint8_t transfer_id[TKP_TRANSFER_ID_SIZE],
    uint8_t media_kind,
    uint64_t expected_size,
    uint64_t encoded_byte_budget,
    uint32_t record_budget,
    TKPStreamReaderPayloadSink sink,
    void *sink_context) {
    uint64_t chunk_count;
    uint64_t minimum_record_count;
    uint64_t minimum_encoded_bytes;
    TKPTransferError transfer_error;

    if (reader == NULL || transfer_id == NULL || sink == NULL) {
        return TKP_STREAM_READER_ERROR_ARGUMENT;
    }
    if (reader->initialized != 0U || reader->state != TKP_STREAM_READER_EMPTY ||
        reader->lease.state != TKP_TRANSFER_LEASE_EMPTY) {
        return TKP_STREAM_READER_ERROR_ALREADY_INITIALIZED;
    }
    if (generation == 0U || expected_size == 0U ||
        expected_size > TKP_TRANSFER_MAX_SIZE ||
        encoded_byte_budget == 0U ||
        encoded_byte_budget > TKP_STREAM_READER_MAX_ENCODED_BYTES ||
        record_budget == 0U ||
        record_budget > TKP_STREAM_READER_MAX_RECORDS) {
        return TKP_STREAM_READER_ERROR_CONFIG;
    }

    chunk_count = (expected_size +
                   (uint64_t)TKP_TRANSFER_MAX_PAYLOAD - UINT64_C(1)) /
                  (uint64_t)TKP_TRANSFER_MAX_PAYLOAD;
    minimum_record_count = chunk_count + UINT64_C(1);
    minimum_encoded_bytes = expected_size +
        (minimum_record_count * (uint64_t)TKP_TRANSFER_HEADER_SIZE);
    if ((uint64_t)record_budget < minimum_record_count) {
        return TKP_STREAM_READER_ERROR_CONFIG;
    }
    if (encoded_byte_budget < minimum_encoded_bytes) {
        return TKP_STREAM_READER_ERROR_CONFIG;
    }

    transfer_error = tkp_transfer_lease_init(
        &reader->lease,
        generation,
        transfer_id,
        media_kind,
        expected_size);
    if (transfer_error != TKP_TRANSFER_OK) {
        return TKP_STREAM_READER_ERROR_CONFIG;
    }

    reader->sink = sink;
    reader->sink_context = sink_context;
    reader->encoded_byte_budget = encoded_byte_budget;
    reader->minimum_record_budget = (uint32_t)minimum_record_count;
    reader->record_budget = record_budget;
    reader->last_transfer_error = TKP_TRANSFER_OK;
    reader->state = TKP_STREAM_READER_OPEN;
    reader->initialized = TKP_STREAM_READER_INITIALIZED_MARKER;
    return TKP_STREAM_READER_OK;
}

TKPStreamReaderError tkp_stream_reader_feed(
    TKPStreamReader *reader,
    const uint8_t *bytes,
    size_t size) {
    size_t consumed = 0U;
    TKPStreamReaderError result = TKP_STREAM_READER_OK;

    if (reader == NULL) {
        return TKP_STREAM_READER_ERROR_ARGUMENT;
    }
    if (reader->busy != 0U) {
        return tkp_stream_fail_reentrant(reader);
    }
    if (!tkp_stream_reader_is_valid(reader)) {
        return TKP_STREAM_READER_ERROR_INVALID_READER;
    }
    if (tkp_stream_reader_is_terminal(reader)) {
        return tkp_stream_terminal_error(reader);
    }

    /* Check the caller-supplied length before dereferencing `bytes`. */
    if ((uint64_t)size >
        reader->encoded_byte_budget - reader->encoded_bytes_seen) {
        return tkp_stream_fail(reader, TKP_STREAM_READER_ERROR_ENCODED_BUDGET);
    }
    if (size == 0U) {
        return TKP_STREAM_READER_OK;
    }
    if (bytes == NULL) {
        return tkp_stream_fail(reader, TKP_STREAM_READER_ERROR_ARGUMENT);
    }
    if (tkp_stream_input_overlaps_reader(reader, bytes, size)) {
        return tkp_stream_fail(
            reader, TKP_STREAM_READER_ERROR_INPUT_OVERLAP);
    }

    reader->encoded_bytes_seen += (uint64_t)size;
    if (reader->state == TKP_STREAM_READER_FINISH_SEEN) {
        return tkp_stream_fail(reader, TKP_STREAM_READER_ERROR_TRAILING_BYTES);
    }

    reader->busy = 1U;
    while (consumed < size && reader->state == TKP_STREAM_READER_OPEN) {
        size_t target_size;
        size_t amount;

        if (reader->frame_size == 0U) {
            target_size = TKP_TRANSFER_HEADER_SIZE;
        } else {
            target_size = reader->frame_size;
        }
        amount = target_size - reader->buffered_size;
        if (amount > size - consumed) {
            amount = size - consumed;
        }
        (void)memcpy(reader->frame_buffer + reader->buffered_size,
                     bytes + consumed, amount);
        reader->buffered_size += amount;
        consumed += amount;

        if (reader->frame_size == 0U &&
            reader->buffered_size == TKP_TRANSFER_HEADER_SIZE) {
            uint32_t payload_size = tkp_stream_read_u32_le(
                reader->frame_buffer + 40U);

            if (payload_size > TKP_TRANSFER_MAX_PAYLOAD) {
                result = tkp_stream_fail(
                    reader, TKP_STREAM_READER_ERROR_PAYLOAD_TOO_LARGE);
                break;
            }
            if (reader->records_seen >= reader->record_budget) {
                result = tkp_stream_fail(
                    reader, TKP_STREAM_READER_ERROR_RECORD_BUDGET);
                break;
            }
            reader->declared_payload_size = payload_size;
            reader->frame_size = TKP_TRANSFER_HEADER_SIZE +
                                 (size_t)payload_size;
        }

        if (reader->frame_size != 0U &&
            reader->buffered_size == reader->frame_size) {
            const uint8_t record_kind = reader->frame_buffer[5];
            const uint64_t sequence = reader->lease.next_sequence;
            TKPTransferError transfer_error = tkp_transfer_lease_accept(
                &reader->lease,
                reader->frame_buffer,
                reader->buffered_size);

            if (transfer_error != TKP_TRANSFER_OK) {
                result = tkp_stream_invalid_frame(reader, transfer_error);
                break;
            }
            reader->last_transfer_error = TKP_TRANSFER_OK;
            ++reader->records_seen;

            if (record_kind == (uint8_t)TKP_TRANSFER_RECORD_FINISH) {
                reader->state = TKP_STREAM_READER_FINISH_SEEN;
                tkp_stream_clear_frame(reader);
                if (consumed < size) {
                    result = tkp_stream_fail(
                        reader, TKP_STREAM_READER_ERROR_TRAILING_BYTES);
                }
                break;
            }

            {
                int sink_result = reader->sink(
                    reader->sink_context,
                    reader->frame_buffer + TKP_TRANSFER_HEADER_SIZE,
                    (size_t)reader->declared_payload_size,
                    sequence);

                if (reader->state != TKP_STREAM_READER_OPEN) {
                    result = tkp_stream_terminal_error(reader);
                    tkp_stream_clear_frame(reader);
                    break;
                }
                if (sink_result != 0) {
                    result = tkp_stream_fail(
                        reader, TKP_STREAM_READER_ERROR_SINK_FAILED);
                    tkp_stream_clear_frame(reader);
                    break;
                }
            }
            tkp_stream_clear_frame(reader);
        }
    }
    reader->busy = 0U;
    if (reader->state == TKP_STREAM_READER_REVOKED ||
        reader->state == TKP_STREAM_READER_CANCELLED) {
        tkp_stream_clear_frame(reader);
    }
    return result;
}

TKPStreamReaderError tkp_stream_reader_finalize(TKPStreamReader *reader) {
    if (reader == NULL) {
        return TKP_STREAM_READER_ERROR_ARGUMENT;
    }
    if (reader->busy != 0U) {
        return tkp_stream_fail_reentrant(reader);
    }
    if (!tkp_stream_reader_is_valid(reader)) {
        return TKP_STREAM_READER_ERROR_INVALID_READER;
    }
    if (tkp_stream_reader_is_terminal(reader)) {
        return tkp_stream_terminal_error(reader);
    }
    if (reader->state == TKP_STREAM_READER_OPEN) {
        return tkp_stream_fail(
            reader,
            reader->buffered_size == 0U
                ? TKP_STREAM_READER_ERROR_MISSING_FINISH
                : TKP_STREAM_READER_ERROR_TRUNCATED_RECORD);
    }
    if (reader->state != TKP_STREAM_READER_FINISH_SEEN) {
        return TKP_STREAM_READER_ERROR_INVALID_READER;
    }

    reader->state = TKP_STREAM_READER_COMPLETE;
    tkp_stream_clear_frame(reader);
    return TKP_STREAM_READER_OK;
}

TKPStreamReaderError tkp_stream_reader_revoke(TKPStreamReader *reader) {
    if (reader == NULL) {
        return TKP_STREAM_READER_ERROR_ARGUMENT;
    }
    if (!tkp_stream_reader_is_valid(reader)) {
        return TKP_STREAM_READER_ERROR_INVALID_READER;
    }
    if (reader->state == TKP_STREAM_READER_COMPLETE ||
        reader->state == TKP_STREAM_READER_REVOKED ||
        reader->state == TKP_STREAM_READER_CANCELLED) {
        return tkp_stream_terminal_error(reader);
    }
    reader->state = TKP_STREAM_READER_REVOKED;
    tkp_stream_revoke_lease_if_open(reader);
    if (reader->busy == 0U) {
        tkp_stream_clear_frame(reader);
    }
    return TKP_STREAM_READER_OK;
}

TKPStreamReaderError tkp_stream_reader_cancel(TKPStreamReader *reader) {
    if (reader == NULL) {
        return TKP_STREAM_READER_ERROR_ARGUMENT;
    }
    if (!tkp_stream_reader_is_valid(reader)) {
        return TKP_STREAM_READER_ERROR_INVALID_READER;
    }
    if (reader->state == TKP_STREAM_READER_COMPLETE ||
        reader->state == TKP_STREAM_READER_REVOKED ||
        reader->state == TKP_STREAM_READER_CANCELLED) {
        return tkp_stream_terminal_error(reader);
    }
    reader->state = TKP_STREAM_READER_CANCELLED;
    if (reader->lease.state == TKP_TRANSFER_LEASE_OPEN) {
        (void)tkp_transfer_lease_cancel(&reader->lease);
    }
    if (reader->busy == 0U) {
        tkp_stream_clear_frame(reader);
    }
    return TKP_STREAM_READER_OK;
}
