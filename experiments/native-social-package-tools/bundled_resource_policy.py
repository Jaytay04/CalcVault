"""One owner-reviewed opaque resource exception; never imports or decrypts keys."""
import hashlib

import ipa_preflight as preflight

ACTION = 'retain_reviewed_bundled_resource'
DESTINATION_ROOT = 'Frameworks/NativeGuest.framework'
# Metadata only. The payload and local policy must never enter source/public CI.
REVIEWED_RESOURCE = (
    '8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198',
    'Payload/TikTok.app/SessionCheck.bundle/private_key.p12',
    DESTINATION_ROOT + '/SessionCheck.bundle/private_key.p12',
    1525,
    'c7078a0830fad2691e26ccc92bd428f02254561f16aad78574d29922bd840dca',
)


def matches(input_digest, source, destination, size, digest=None):
    expected_input, expected_source, expected_target, expected_size, expected_digest = REVIEWED_RESOURCE
    return (input_digest == expected_input and source == expected_source
            and destination == expected_target and type(size) is int and size == expected_size
            and (digest is None or digest == expected_digest))


def verify_member(archive, entry, input_digest):
    """Hash only the exact approved bounded opaque bytes; never expose contents."""
    preflight.require(matches(input_digest, entry.filename, REVIEWED_RESOURCE[2], entry.file_size),
                      'unapproved_bundled_resource')
    with archive.open(entry) as stream:
        data = stream.read(REVIEWED_RESOURCE[3] + 1)
    preflight.require(len(data) == REVIEWED_RESOURCE[3]
                      and hashlib.sha256(data).hexdigest() == REVIEWED_RESOURCE[4],
                      'bundled_resource_digest_mismatch')


def verify_row(row, input_digest, *, copied=False):
    preflight.require(isinstance(row, dict), 'unapproved_bundled_resource')
    target = row.get('path') if copied else row.get('proposed_destination')
    size = row.get('size') if copied else row.get('declared_size')
    digest = row.get('sha256_before_signing') if copied else None
    preflight.require((not copied or digest == REVIEWED_RESOURCE[4])
                      and row.get('action') == ACTION
                      and matches(input_digest, row.get('source'), target, size, digest),
                      'unapproved_bundled_resource')
