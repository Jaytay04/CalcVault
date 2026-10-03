# Independent TKPlus native feature layer

Original, isolated source for the owner-approved native TikTok research
exception. The initial scope is downloads intended for Vault and local profile
eligibility controls. It does not contain TTKillerPlus code, licensing checks,
paid-feature patches, telemetry, cleaners or Vault credentials.

Read the [implementation record](../../docs/tkplus/INDEPENDENT_IMPLEMENTATION.md)
for the approved boundaries and integration gaps. Existing CalcVault source,
native host source and original private IPAs remain unchanged. The local-only
adapter produces a separate testing derivative from the pinned working candidate.
The [media-only outbox design](TRANSPORT_DESIGN.md) records the proposed handoff
and its mandatory host-side validation; no filesystem transport is implemented yet.

## Source layout

- `Guest/TKPMediaSelection.h/.m`: bounded original-URL selection with a caller's
  exact approved-host policy. It performs no network or filesystem operations.
- `Guest/TKPProfileControls.h/.m`: explicit runtime/ABI/image-checked eligibility
  hooks, off by default. It is not an anonymity guarantee.
- `Guest/TKPDevicePanel.m`: Profile-tab long-press entry, separate gear screen
  and explicit opt-in settings in the existing guest window; no native Vault
  download action yet.
- `assemble_device_candidate.py`: pinned, no-overwrite private overlay assembly,
  whole original add-on exclusion and complete member hash/CRC readback.
- `Core/TKPTransfer.h/.c`: portable bounded transfer lease and record validation.
  No encryption, keys, paths or network access.
- `Core/TKPStreamReader.h/.c`: incremental fixed-buffer receiver with encoded-byte
  and record budgets, tentative synchronous output, and explicit EOF gating.
- `Tests/`: synthetic fixtures for these independently written components.

## Portable transfer checks

From the Calculator project root with Python and Clang:

```sh
python -m unittest discover -s experiments/tkplus/Tests -p test_transfer.py -v
python -m unittest discover -s experiments/tkplus/Tests -p test_stream_reader.py -v
```

This compiles the C11 core with warnings as errors and assertions disabled, then
executes explicit synthetic checks. Compiler absence or test failure fails the
command. It does not test transport, media decoding, Vault commit or iOS isolation.

## Apple source checks

From this directory on macOS with Xcode command-line tools:

```sh
bash Tests/test_media_selection.sh
bash Tests/test_profile_controls.sh
bash Tests/test_sanitizers.sh
bash Tests/test_ios_compile.sh
```

The fixtures use reserved synthetic hostnames and generated classes only.
They do not load TikTok, contact a service or read an account. Temporary build
outputs are retained in individually generated test directories for inspection.
Windows cannot establish these Foundation/Objective-C results.
The sanitizer script executes the portable fixtures on macOS with address and
undefined-behavior checks. The iPhoneOS script compiles four independent units
to arm64 objects and verifies their platform/minimum OS metadata. It does not
link an app, execute on iOS or produce an IPA. Missing Apple tools exit 77,
which is a failure in Actions, not a passing skip.

The `tkplus-source-checks.yml` workflow uses the project's existing
Xcode16.4 pin to run these synthetic macOS fixtures and iPhoneOS object checks.
It neither loads a private IPA nor signs/builds an iOS package, and has no
secrets, downloads, upload or publication step. Its push trigger is restricted
to the independently reviewed
`research/tkplus-independent-source-20261002` branch and source/fixture paths.
No default-branch workflow or shipping source is changed. The manual entry is
available only after GitHub recognizes the workflow on the default branch.

## Integration status

The current device slice connects only Profile-tab settings and local profile eligibility
controls. Guest model selection, downloading, IPC and host media
decode/confirmation/encrypted import are not yet connected. The separate
`tkplus-device-addon.yml` workflow links the independent ARM64 iOS18 dylib and
runs a separate synthetic iOS simulator settings fixture. That fixture invokes
controller actions; it does not establish physical gesture recognition or the
actual TikTok tab mapping. Its compile-only image substitution is excluded from
the device module. No extra window or native-controller presentation is used;
private packaging remains local and never supplies a proprietary IPA to CI.
Source and synthetic test
results must be distinguished from native compatibility and signed-phone tests.
Never turn an unsupported selector into a broad hook to make a test pass.

Owner test3 result: Profile hold still fails. The diagnostic follow-up preserves
binding and lifecycle policy and sends only bounded fixed-label/numeric entry
observations through the existing guest report. It does not add a floating
entry, a generic callback bridge or filesystem authority. Phone cause and entry
success remain unverified.

Diagnostic4 owner records establish startup and report delivery but reject the
initial class gate on every discovery tick. Diagnostic5 adds only a numeric
class-gate subcondition (`cls_status`); it does not relax image ownership,
alter the viewport or claim that Profile hold is repaired. See the status map
in `docs/tkplus/INDEPENDENT_IMPLEMENTATION.md`. The device build rejects exports
of the classifier's synthetic-test wrappers.
