import CoreFoundation
import Foundation

/// Package identity only, never authentication or permission to launch a guest.
/// The runtime still validates its immutable framework and credential boundary.
public enum NativeGuestIntegrationProfile: Sendable, Equatable {
    case synthetic
    case tikTok

    public static var current: Self? {
        guard let host = Bundle.main.infoDictionary,
              let url = Bundle.main.url(forResource: "CVLPFrameworkGuest", withExtension: "plist"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 65_536,
              let data = try? Data(contentsOf: url), data.count <= 65_536,
              let descriptor = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return resolve(host: host, descriptor: descriptor)
    }

    public static func resolve(host: [String: Any], descriptor: [String: Any]) -> Self? {
        guard host["CFBundleVersion"] as? String == "23",
              Set(descriptor.keys) == ["schema", "bundleIdentifier", "bundleVersion", "executable"],
              let schema = descriptor["schema"] as? NSNumber,
              CFGetTypeID(schema) == CFNumberGetTypeID(),
              String(cString: schema.objCType) != "f", String(cString: schema.objCType) != "d",
              schema.int64Value == 1,
              descriptor["executable"] as? String == "NativeGuest" else { return nil }
        switch (host["CVNativeGuestKind"] as? String,
                host["CVNativeIntegrationStage"] as? String,
                descriptor["bundleIdentifier"] as? String,
                descriptor["bundleVersion"] as? String) {
        case ("synthetic", "synthetic-integration-23", "org.example.syntheticnativeguest.app", "1"):
            return .synthetic
        case ("tiktok", "private-tiktok-integration-23", "com.zhiliaoapp.musically", "439042"):
            return .tikTok
        default:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .synthetic: "Build 23 synthetic integration test"
        case .tikTok: "Build 23 native TikTok integration test"
        }
    }
}
