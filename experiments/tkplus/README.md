# Independent TKPlus native feature layer

Original, isolated source for the owner-approved native TikTok research
exception. The initial scope is downloads intended for Vault and local profile
eligibility controls. It does not contain TTKillerPlus code, licensing checks,
paid-feature patches, telemetry, cleaners or Vault credentials.

Read the [implementation record](../../docs/tkplus/INDEPENDENT_IMPLEMENTATION.md)
for the approved boundaries and integration gaps. Existing CalcVault source,
native guest packaging and original private IPAs are not modified by this module.
The [media-only outbox design](TRANSPORT_DESIGN.md) records the proposed handoff
and its mandatory host-side validation; no transport is implemented yet.

## Source layout

- `Guest/TKPMediaSelection.h/.m`: bounded original-URL selection with a caller's
  exact approved-host policy. It performs no network or filesystem operations.
- `Guest/TKPProfileControls.h/.m`: explicit runtime/ABI/image-checked eligibility
  hooks, off by default. It is not an anonymity guarantee.
- `Core/TKPTransfer.h/.c`: portable bounded transfer lease and record validation.
  No encryption, keys, paths or network access.
- `Tests/`: synthetic fixtures for these independently written components.

## Portable transfer checks

From the Calculator project root with Python and Clang:

```sh
python -m unittest discover -s experiments/tkplus/Tests -p test_transfer.py -v
```

This compiles the C11 core with warnings as errors and assertions disabled, then
executes explicit synthetic checks. Compiler absence or test failure fails the
command. It does not test transport, media decoding, Vault commit or iOS isolation.

## Apple source checks

From this directory on macOS with Xcode command-line tools:

```sh
bash Tests/test_media_selection.sh
bash Tests/test_profile_controls.sh
```

The fixtures use reserved synthetic hostnames and generated classes only.
They do not load TikTok, contact a service or read an account. Temporary build
outputs are retained in individually generated test directories for inspection.
Windows cannot establish these Foundation/Objective-C results.

The `tkplus-source-checks.yml` workflow uses the project's existing
Xcode16.4 pin to run these synthetic macOS fixtures. It neither loads a private
IPA nor signs/builds an iOS package, and has no secrets, downloads, upload or
publication step. Its push trigger is restricted to the independently reviewed
`research/tkplus-independent-source-20261002` branch and source/fixture paths.
No default-branch workflow or shipping source is changed. The manual entry is
available only after GitHub recognizes the workflow on the default branch.

## Integration status

This is a source slice, not a complete tweak or a new phone build. Guest model
selection, UI actions, downloading, IPC, host media decode/confirmation/encrypted
import and private packaging are not yet connected. Source and synthetic test
results must be distinguished from native compatibility and signed-phone tests.
Never turn an unsupported selector into a broad hook to make a test pass.
