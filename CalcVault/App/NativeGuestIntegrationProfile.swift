import CoreFoundation
import Foundation

/// Package identity only, never authentication or permission to launch a guest.
/// The runtime still validates its immutable framework and credential boundary.
public enum NativeGuestIntegrationProfile: Sendable, Equatable {
    case synthetic
    case tikTok
    case synthetic24
    case tikTok47

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
        guard let hostBuild = host["CFBundleVersion"] as? String,
              hostBuild == "23" || hostBuild == "24",
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
            return hostBuild == "23" ? .synthetic : nil
        case ("tiktok", "private-tiktok-integration-23", "com.zhiliaoapp.musically", "439042"):
            return hostBuild == "23" ? .tikTok : nil
        case ("synthetic", "synthetic-integration-24", "org.example.syntheticnativeguest.app", "1"):
            return hostBuild == "24" ? .synthetic24 : nil
        case ("tiktok47", "private-tiktok47-integration-24", "com.zhiliaoapp.musically", "470044"):
            return hostBuild == "24" ? .tikTok47 : nil
        default:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .synthetic: "Build 23 synthetic integration test"
        case .tikTok: "Build 23 native TikTok integration test"
        case .synthetic24: "Build 24 synthetic integration test"
        case .tikTok47: "Build 24 native TikTok 47.0.0 integration test"
        }
    }

    public var representsTikTokGuest: Bool {
        self == .tikTok || self == .tikTok47
    }
}
