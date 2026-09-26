# ADR 0001: Phase 0 dependencies and identities

Status: accepted for prototype; device verification pending.

## Decision

Generate the project with XcodeGen 2.46.0 and pin `jedisct1/swift-sodium` to exact version 0.11.0. The package bundles libsodium for Apple platforms and is ISC licensed. Phase 0 uses its authenticated secret-box API only for a dummy round trip; later vault work must adopt the plan's reviewed XChaCha20-Poly1305/secretstream/KDF design rather than treating the probe as a storage format. The manual CI route selects Xcode 16.4 (`16F6`) on the `macos-15` image.

Use one application target with a primary Release bundle ID and one additional RecoveryTest bundle ID. The latter enables side-by-side disposable install/recovery checks without creating a second shipped product or deleting primary data.

Use Foundation/WebKit/Security/UIKit/SwiftUI for the remainder. The bounded TAR reader is internal and read-only, avoiding a broad archive dependency during the feasibility spike.

## Consequences

macOS/Xcode remains mandatory for authoritative builds. Package resolution needs network access on the build machine. The exact bundled libsodium version and binary provenance still require inspection after dependency resolution/build. Neither App ID nor SideStore behavior is verified until a real signed device install.
