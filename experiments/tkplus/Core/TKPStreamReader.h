#ifndef TKP_STREAM_READER_H
#define TKP_STREAM_READER_H

#include "TKPTransfer.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TKP_STREAM_READER_MAX_RECORDS UINT32_C(65536)
#define TKP_STREAM_READER_MAX_ENCODED_BYTES \
    (TKP_TRANSFER_MAX_SIZE + \
     ((uint64_t)TKP_TRANSFER_HEADER_SIZE * \
      (uint64_t)TKP_STREAM_READER_MAX_RECORDS))
#define TKP_STREAM_READER_FRAME_CAPACITY \
    (TKP_TRANSFER_HEADER_SIZE + (size_t)TKP_TRANSFER_MAX_PAYLOAD)

typedef enum TKPStreamReaderState {
    TKP_STREAM_READER_EMPTY = 0,
    TKP_STREAM_READER_OPEN = 1,
    TKP_STREAM_READER_FINISH_SEEN = 2,
    TKP_STREAM_READER_COMPLETE = 3,
    TKP_STREAM_READER_REVOKED = 4,
    TKP_STREAM_READER_CANCELLED = 5
} TKPStreamReaderState;

typedef enum TKPStreamReaderError {
    TKP_STREAM_READER_OK = 0,
    TKP_STREAM_READER_ERROR_ARGUMENT,
    TKP_STREAM_READER_ERROR_CONFIG,
    TKP_STREAM_READER_ERROR_ALREADY_INITIALIZED,
    TKP_STREAM_READER_ERROR_INVALID_READER,
    TKP_STREAM_READER_ERROR_INPUT_OVERLAP,
    TKP_STREAM_READER_ERROR_TERMINAL_COMPLETE,
    TKP_STREAM_READER_ERROR_TERMINAL_REVOKED,
    TKP_STREAM_READER_ERROR_TERMINAL_CANCELLED,
    TKP_STREAM_READER_ERROR_ENCODED_BUDGET,
    TKP_STREAM_READER_ERROR_RECORD_BUDGET,
    TKP_STREAM_READER_ERROR_PAYLOAD_TOO_LARGE,
    TKP_STREAM_READER_ERROR_TRAILING_BYTES,
    TKP_STREAM_READER_ERROR_MISSING_FINISH,
    TKP_STREAM_READER_ERROR_TRUNCATED_RECORD,
    TKP_STREAM_READER_ERROR_FRAME_REJECTED,
    TKP_STREAM_READER_ERROR_SINK_FAILED,
    TKP_STREAM_READER_ERROR_REENTRANT
} TKPStreamReaderError;

/*
 * A synchronous tentative sink. It is called only for a complete chunk after
 * TKPTransfer has validated and accounted for that record. Return 0 to accept
 * the tentative write or any nonzero value to fail the stream. The payload is
 * borrowed from reader-owned storage and is valid only until this call returns;
 * do not retain its pointer. The sequence is the validated chunk sequence.
 *
 * Sink output is tentative. The caller must discard all such output if a feed
 * or finalization fails, the stream is cancelled or revoked, or the host
 * session is locked/revoked. This receiver grants no import authority.
 */
typedef int (*TKPStreamReaderPayloadSink)(
    void *context,
    const uint8_t *payload,
    size_t payload_size,
    uint64_t sequence);

/*
 * Caller-owned parser state. Initialize this object from all zeroes and retain
 * it until the transfer is terminal. It contains untrusted media bytes in a
 * fixed one-frame buffer. Release/scrub the caller-owned object when finished;
 * internal clearing is best effort and makes no forensic-zeroization promise.
 * There is no dynamic allocation, filesystem, network, key or import access.
 * Do not read or mutate fields concurrently or edit any field after init;
 * inspect the outer `state` only under the same serialized-access rule.
 *
 * Serialize ALL calls, including inspection and the sink callback, on one
 * executor/lock. Calls are not thread-safe. A sink may call revoke/cancel, but
 * must not recursively feed or finalize; those reentrant operations fail closed.
 * The embedded lease can be COMPLETE while the outer reader is still
 * FINISH_SEEN. Callers must gate stream success on the outer state becoming
 * COMPLETE after explicit EOF, then independently check revocable host session
 * and import authority before preview, confirmation or commit.
 */
typedef struct TKPStreamReader {
    TKPTransferLease lease;
    TKPStreamReaderPayloadSink sink;
    void *sink_context;
    uint64_t encoded_byte_budget;
    uint64_t encoded_bytes_seen;
    uint32_t minimum_record_budget;
    uint32_t record_budget;
    uint32_t records_seen;
    size_t buffered_size;
    size_t frame_size;
    uint32_t declared_payload_size;
    TKPTransferError last_transfer_error;
    TKPStreamReaderState state;
    uint8_t initialized;
    uint8_t busy;
    uint8_t reserved[6];
    uint8_t frame_buffer[TKP_STREAM_READER_FRAME_CAPACITY];
} TKPStreamReader;

#define TKP_STREAM_READER_INITIALIZER {0}

/*
 * Initialize one zero-initialized reader with host-issued identity and budgets.
 * Budgets must be within the published maxima and large enough for the exact
 * minimum framing overhead: ceil(expected_size / max_payload) chunk records
 * plus one finish record. `record_budget` includes that finish record. `sink`
 * must be non-NULL and is immutable for this reader's lifetime.
 */
TKPStreamReaderError tkp_stream_reader_init(
    TKPStreamReader *reader,
    uint64_t generation,
    const uint8_t transfer_id[TKP_TRANSFER_ID_SIZE],
    uint8_t media_kind,
    uint64_t expected_size,
    uint64_t encoded_byte_budget,
    uint32_t record_budget,
    TKPStreamReaderPayloadSink sink,
    void *sink_context);

/*
 * Feed an arbitrary byte fragment. NULL with size zero is a no-op while the
 * stream is active; reentrancy is checked before that no-op. Input length is
 * checked against the remaining byte budget before any input pointer access.
 * The caller must provide a valid, stable input range disjoint from the reader
 * object; overlapping ranges are rejected to avoid undefined memcpy behavior.
 * A zero return means bytes were consumed, not that the stream is complete.
 */
TKPStreamReaderError tkp_stream_reader_feed(
    TKPStreamReader *reader,
    const uint8_t *bytes,
    size_t size);

/*
 * Signal EOF only after the host has actually observed end-of-input. Completion
 * requires a validated finish record first; this call cannot infer transport EOF.
 */
TKPStreamReaderError tkp_stream_reader_finalize(TKPStreamReader *reader);

/* Revoke or cancel the stream gate, including after a validated finish record. */
TKPStreamReaderError tkp_stream_reader_revoke(TKPStreamReader *reader);
TKPStreamReaderError tkp_stream_reader_cancel(TKPStreamReader *reader);

#ifdef __cplusplus
}
#endif

#endif
