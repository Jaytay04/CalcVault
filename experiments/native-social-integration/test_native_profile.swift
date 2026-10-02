import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("Native guest profile fixture failed: \(message)") }
}

@main
struct NativeGuestProfileFixture {
    static func main() {
let syntheticGuest: [String: Any] = [
    "schema": 1, "bundleIdentifier": "org.example.syntheticnativeguest.app",
    "bundleVersion": "1", "executable": "NativeGuest"
]
let tiktok23Guest: [String: Any] = [
    "schema": 1, "bundleIdentifier": "com.zhiliaoapp.musically",
    "bundleVersion": "439042", "executable": "NativeGuest"
]
let tiktok47Guest: [String: Any] = [
    "schema": 1, "bundleIdentifier": "com.zhiliaoapp.musically",
    "bundleVersion": "470044", "executable": "NativeGuest"
]
let synthetic23Host: [String: Any] = [
    "CFBundleVersion": "23", "CVNativeGuestKind": "synthetic",
    "CVNativeIntegrationStage": "synthetic-integration-23"
]
let tiktok23Host: [String: Any] = [
    "CFBundleVersion": "23", "CVNativeGuestKind": "tiktok",
    "CVNativeIntegrationStage": "private-tiktok-integration-23"
]
let synthetic24Host: [String: Any] = [
    "CFBundleVersion": "24", "CVNativeGuestKind": "synthetic",
    "CVNativeIntegrationStage": "synthetic-integration-24"
]
let tiktok47Host: [String: Any] = [
    "CFBundleVersion": "24", "CVNativeGuestKind": "tiktok47",
    "CVNativeIntegrationStage": "private-tiktok47-integration-24"
]

require(NativeGuestIntegrationProfile.resolve(host: synthetic23Host, descriptor: syntheticGuest) == .synthetic,
        "Build 23 synthetic profile")
require(NativeGuestIntegrationProfile.resolve(host: tiktok23Host, descriptor: tiktok23Guest) == .tikTok,
        "Build 23 TikTok profile")
require(NativeGuestIntegrationProfile.resolve(host: synthetic24Host, descriptor: syntheticGuest) == .synthetic24,
        "Build 24 synthetic profile")
require(NativeGuestIntegrationProfile.resolve(host: tiktok47Host, descriptor: tiktok47Guest) == .tikTok47,
        "Build 24 TikTok 47.0044 profile")

require(NativeGuestIntegrationProfile.resolve(host: synthetic24Host, descriptor: tiktok47Guest) == nil,
        "crossed Build 24 host and guest")
require(NativeGuestIntegrationProfile.resolve(host: tiktok47Host, descriptor: tiktok23Guest) == nil,
        "Build 23 TikTok version on the Build 24 host")
var crossedStage = tiktok47Host
crossedStage["CVNativeIntegrationStage"] = "private-tiktok-integration-23"
require(NativeGuestIntegrationProfile.resolve(host: crossedStage, descriptor: tiktok47Guest) == nil,
        "Build 23 stage on the Build 24 host")
let invalidSchemas: [Any] = [true, 1.5]
for schema in invalidSchemas {
    var malformed = tiktok47Guest
    malformed["schema"] = schema
    require(NativeGuestIntegrationProfile.resolve(host: tiktok47Host, descriptor: malformed) == nil,
            "noninteger schema rejected")
}
var extraField = tiktok47Guest
extraField["unexpected"] = "rejected"
require(NativeGuestIntegrationProfile.resolve(host: tiktok47Host, descriptor: extraField) == nil,
        "extra descriptor key rejected")

require(NativeGuestIntegrationProfile.synthetic.title == "Build 23 synthetic integration test",
        "Build 23 synthetic title preserved")
require(NativeGuestIntegrationProfile.tikTok.title == "Build 23 native TikTok integration test",
        "Build 23 TikTok title preserved")
require(NativeGuestIntegrationProfile.synthetic24.title == "Build 24 synthetic integration test",
        "Build 24 synthetic title")
require(NativeGuestIntegrationProfile.tikTok47.title == "Build 24 native TikTok 47.0.0 integration test",
        "Build 24 TikTok title")

print("Native guest profile fixtures: PASS")
    }
}
