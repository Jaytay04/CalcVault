# Disposable Phase 0 device fixture

`phase0-authoritative.tar` is a plain, unencrypted USTAR archive containing two synthetic text files:

- `README.txt` (100 bytes)
- `notes.txt` (88 bytes)

SHA-256: `d89cc9997df58f9cd9a3b3bad18074555521ce2ed3b6f883054b387f8e7d1290`

It exists only to test read-only external archive selection, relaunch access, and visible failure after the authoritative file is moved or renamed. It contains no credentials, private media, or personal data. Plain TAR provides packaging/concealment only; it is not encryption.
