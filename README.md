# CalcVault

CalcVault is a personal iOS prototype following [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md). Phase 0 proves the native build/install route and risky integrations. Phase 1 adds the calculator. Phase 2 adds owner enrollment, authentication, and revocable private sessions. Phase 3 adds the versioned encrypted manifest/object-storage foundation and fail-safe repository behavior. File/photo vault UX remains a later phase.

Nothing in this repository is a release claim. The current evidence status is in [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md).

## macOS quick start

Prerequisites: macOS, Xcode with the iOS 18 SDK, and XcodeGen 2.46.0.

```sh
sh scripts/generate-project.sh
sh scripts/test-macos.sh
sh scripts/build-unsigned-ipa.sh
```

The last command produces `build/artifacts/CalcVault-unsigned.ipa` only after a successful `iphoneos` build and artifact inspection. The manual GitHub Actions workflow is an optional route; review account minutes/billing before running it.

## Safety

Use only disposable fixtures and dummy data. The Phase 3 storage foundation passed automated tests and its physical initialization/persistence checkpoint, but it has not received an independent external security audit. Plain TAR files are not encrypted. Do not place credentials, signing material, or private media in this repository.

After enrollment, the documented recovery route is fifteen taps in the calculator's blank top-right navigation-bar area. It opens authentication only; it does not bypass the independent passphrase or enrolled Face ID path.
