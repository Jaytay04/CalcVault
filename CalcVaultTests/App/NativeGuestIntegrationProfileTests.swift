import Foundation
import XCTest
@testable import CalcVault

final class NativeGuestIntegrationProfileTests: XCTestCase {
    private let syntheticHost: [String: Any] = [
        "CFBundleVersion": "23", "CVNativeGuestKind": "synthetic",
        "CVNativeIntegrationStage": "synthetic-integration-23"
    ]
    private let syntheticGuest: [String: Any] = [
        "schema": 1, "bundleIdentifier": "org.example.syntheticnativeguest.app",
        "bundleVersion": "1", "executable": "NativeGuest"
    ]
    private let nativeHost: [String: Any] = [
        "CFBundleVersion": "23", "CVNativeGuestKind": "tiktok",
        "CVNativeIntegrationStage": "private-tiktok-integration-23"
    ]
    private let nativeGuest: [String: Any] = [
        "schema": 1, "bundleIdentifier": "com.zhiliaoapp.musically",
        "bundleVersion": "439042", "executable": "NativeGuest"
    ]

    func testExactApprovedProfiles() {
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: syntheticHost, descriptor: syntheticGuest), .synthetic)
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: nativeGuest), .tikTok)
    }

    func testCrossedProfilesAndMissingMetadataFailClosed() {
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: syntheticHost, descriptor: nativeGuest))
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: syntheticGuest))
        for key in nativeHost.keys {
            var host = nativeHost
            host.removeValue(forKey: key)
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: host, descriptor: nativeGuest))
        }
        for key in nativeGuest.keys {
            var guest = nativeGuest
            guest.removeValue(forKey: key)
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: guest))
        }
    }

    func testUnapprovedVersionsExecutablesAndSchemasAreRejected() {
        for (key, value) in [("bundleVersion", "439043"), ("bundleIdentifier", "other.app"),
                             ("executable", "../NativeGuest")] {
            var guest = nativeGuest
            guest[key] = value
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: guest))
        }
        for value in [true, 1.5, "1", 2] as [Any] {
            var guest = nativeGuest
            guest["schema"] = value
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: guest))
        }
        var guest = nativeGuest
        guest["extra"] = "unexpected"
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: guest))
        var host = nativeHost
        host["CFBundleVersion"] = "22.2"
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: host, descriptor: nativeGuest))
    }
}
