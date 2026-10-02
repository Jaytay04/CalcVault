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
    private let syntheticHost24: [String: Any] = [
        "CFBundleVersion": "24", "CVNativeGuestKind": "synthetic",
        "CVNativeIntegrationStage": "synthetic-integration-24"
    ]
    private let nativeHost24: [String: Any] = [
        "CFBundleVersion": "24", "CVNativeGuestKind": "tiktok47",
        "CVNativeIntegrationStage": "private-tiktok47-integration-24"
    ]
    private let nativeGuest47: [String: Any] = [
        "schema": 1, "bundleIdentifier": "com.zhiliaoapp.musically",
        "bundleVersion": "470044", "executable": "NativeGuest"
    ]

    func testExactApprovedProfiles() {
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: syntheticHost, descriptor: syntheticGuest), .synthetic)
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: nativeGuest), .tikTok)
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: syntheticHost24, descriptor: syntheticGuest), .synthetic24)
        XCTAssertEqual(NativeGuestIntegrationProfile.resolve(host: nativeHost24, descriptor: nativeGuest47), .tikTok47)
    }

    func testCrossedProfilesAndMissingMetadataFailClosed() {
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: syntheticHost, descriptor: nativeGuest))
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost, descriptor: syntheticGuest))
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: syntheticHost24, descriptor: nativeGuest47))
        XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost24, descriptor: syntheticGuest))
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
        for build in ["22.2", "25"] {
            var host = nativeHost24
            host["CFBundleVersion"] = build
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: host, descriptor: nativeGuest47))
        }
        for (key, value) in [("bundleVersion", "470045"), ("bundleIdentifier", "other.app"),
                             ("executable", "NativeGuest.dylib")] {
            var guest = nativeGuest47
            guest[key] = value
            XCTAssertNil(NativeGuestIntegrationProfile.resolve(host: nativeHost24, descriptor: guest))
        }
        XCTAssertEqual(NativeGuestIntegrationProfile.synthetic.title, "Build 23 synthetic integration test")
        XCTAssertEqual(NativeGuestIntegrationProfile.tikTok.title, "Build 23 native TikTok integration test")
        XCTAssertEqual(NativeGuestIntegrationProfile.synthetic24.title, "Build 24 synthetic integration test")
        XCTAssertEqual(NativeGuestIntegrationProfile.tikTok47.title, "Build 24 native TikTok 47.0.0 integration test")
    }
}
