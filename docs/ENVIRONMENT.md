# Phase 0 environment

Recorded: 2026-09-19

## Observed local environment

- Host: Windows, PowerShell workspace.
- `git`: available.
- `xcodebuild`: not available.
- `swift`: not available.
- `xcodegen`: not available.
- Physical device: iPhone 16 Pro Max, iOS 18.6 (`22G86`).
- SideStore: 0.7.0 (`20260911.328+6032424a`, build 0700); effective primary identity observed as `com.jaylintaylor.calcvault.<SideStore suffix>` and intentionally sanitized here.
- Remote macOS/Xcode execution: established through the manual GitHub Actions workflow.

The Windows host still cannot run Xcode locally. GitHub Actions supplies the authoritative macOS build/test environment. SideStore import and launch have run on the physical phone; broader biometric, lifecycle, archive, and live-site checks remain incomplete.

## Observed GitHub build environment

- Latest workflow run: `35460669067`, head commit `8fdc9ad11defe0bb91e777a307c1c700e6bc64ba`.
- Runner: `macos-15-arm64`, image version `20260907.0337.1`, macOS 15.7.9, arm64.
- Xcode: 16.4 (`16F6`).
- Swift: Apple Swift 6.1.2 (`swiftlang-6.1.2.1.2`, clang `1700.0.13.5`).
- XcodeGen: 2.46.0.
- SDKs: iPhoneSimulator 18.5 and iPhoneOS 18.5.
- Test destination selected by Xcode: iPhone 16 Pro simulator, iOS 26.2, arm64.
- Dependency resolved: `jedisct1/swift-sodium` 0.11.0.

## Reproducible route

- Deployment target: iOS 18.0 (provisional per the implementation plan).
- Project generator: XcodeGen 2.46.0; the generator script rejects another version.
- Crypto package: `jedisct1/swift-sodium` 0.11.0 through an exact Swift Package version requirement.
- CI runner label: `macos-15`, manual dispatch only. The workflow selects Xcode 16.4 (`16F6`) explicitly and fails if that version is unavailable; it also records the actual environment. GitHub's runner-image inventory currently lists that toolchain at `/Applications/Xcode_16.4.app`.
- Authoritative integration environment: macOS/Xcode plus a physical iPhone for SideStore, Keychain, lifecycle, and website behavior.

The manual workflow was dispatched only after the owner reported no usage and authorized continuation while it remained free. The corrected build run took 1 minute 54 seconds. No paid infrastructure was configured.

## App identities

One source target produces one shipped app:

- Shipped bundle ID: `com.jaylintaylor.calcvault`
- Additional, non-shipped recovery/install-check App ID: `com.jaylintaylor.calcvault.recoverytest`

The second identity is a build configuration of the same target, not another product or extension. It is reserved for side-by-side disposable recovery/install checks without deleting a populated primary install. SideStore registered exactly one CalcVault project App ID for the primary app, rewriting it as `com.jaylintaylor.calcvault.<SideStore suffix>`; no CalcVault extension App ID appeared. The Apple-generated identifier and suffix are not stored in the repository. The recovery-test identity remains unused and unregistered.

The simulator-only XCTest bundle has a bundle identifier for Xcode bookkeeping but signing is disabled; it is not a third registered App ID or a shipped product.
