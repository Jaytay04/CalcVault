import Foundation
import WebKit

/// The only supported social destinations in the Phase 0 prototype.
///
/// These are ordinary HTTPS websites. There is no provider SDK, unofficial API,
/// cookie export, or native-to-JavaScript bridge in this module.
public enum SocialService: String, CaseIterable, Identifiable, Sendable {
    case tikTok
    case x
    case instagram

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tikTok: return "TikTok"
        case .x: return "X"
        case .instagram: return "Instagram"
        }
    }

    public var prefersDesktopSiteByDefault: Bool {
        self == .tikTok || self == .x
    }

    /// The host shown in native UI and used to identify each profile.
    public var officialHostname: String {
        switch self {
        case .tikTok: return "www.tiktok.com"
        case .x: return "x.com"
        case .instagram: return "www.instagram.com"
        }
    }

    public var officialURL: URL {
        // These literals are fixed, first-party HTTPS landing pages, not user input.
        switch self {
        case .tikTok: return URL(string: "https://www.tiktok.com/")!
        case .x: return URL(string: "https://x.com/")!
        case .instagram: return URL(string: "https://www.instagram.com/")!
        }
    }

    /// A stable identifier gives each remembered profile an independent WebKit store.
    public var websiteDataStoreIdentifier: UUID {
        // These UUIDs are stable across launches and intentionally distinct per service.
        switch self {
        case .tikTok: return UUID(uuidString: "D7D3A180-9A53-4E92-94B4-A3D1B9C2CF01")!
        case .x: return UUID(uuidString: "2F5D47E4-31DB-4B15-A0F0-86E8A6EA2B02")!
        case .instagram: return UUID(uuidString: "8B4A3F26-7596-4DA3-9F1A-E6F2C6AE4B03")!
        }
    }

    public func acceptsOfficialHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == officialHostname || host.hasSuffix(".\(officialHostname)")
    }
}

/// Only a recognizable content address is offered as a share link.
/// A feed/profile URL cannot identify the story currently shown in an overlay.
enum SocialLinkPolicy {
    static func contentURL(_ url: URL?, service: SocialService) -> URL? {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents
        func hasIdentifier(_ index: Int) -> Bool {
            parts.count > index && !parts[index].isEmpty && parts[index] != "/"
        }
        let isContent: Bool
        switch service {
        case .tikTok:
            isContent = (host == "tiktok.com" || host.hasSuffix(".tiktok.com"))
                && hasIdentifier(3) && parts[1].hasPrefix("@")
                && ["video", "photo", "story", "stories"].contains(parts[2])
        case .x:
            isContent = (host == "x.com" || host == "www.x.com"
                || host == "twitter.com" || host == "www.twitter.com")
                && hasIdentifier(3) && parts[2] == "status"
        case .instagram:
            isContent = (host == "instagram.com" || host == "www.instagram.com")
                && ((hasIdentifier(2) && ["p", "reel", "tv"].contains(parts[1]))
                    || (hasIdentifier(3) && parts[1] == "stories"))
        }
        guard isContent else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

public enum BrowserPersistenceMode: String, CaseIterable, Identifiable, Sendable {
    case remembered
    case ephemeral

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remembered: return "Remembered"
        case .ephemeral: return "Ephemeral"
        }
    }

    public var disclosure: String {
        switch self {
        case .remembered:
            return "Browser-managed cookies and site data may persist outside vault encryption."
        case .ephemeral:
            return "This profile asks WebKit not to persist website data after its process ends."
        }
    }
}

/// Creates isolated configurations for the three profiles.
///
/// Only TikTok receives a narrow user-tapped video presentation script. No
/// message handlers, credential access, or file/vault objects are attached.
@available(iOS 17.0, *)
@MainActor
public final class BrowserProfileStore {
    private let fixtureIdentifiers: [SocialService: UUID]?

    public init() {
        fixtureIdentifiers = nil
    }

    /// Test fixtures use random stores so storage tests never touch real profiles.
    init(fixtureIdentifiers: [SocialService: UUID]) {
        self.fixtureIdentifiers = fixtureIdentifiers
    }

    private func identifier(for service: SocialService) -> UUID {
        fixtureIdentifiers?[service] ?? service.websiteDataStoreIdentifier
    }

    public func configuration(
        for service: SocialService,
        persistence: BrowserPersistenceMode
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        switch persistence {
        case .remembered:
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier(for: service))
        case .ephemeral:
            configuration.websiteDataStore = .nonPersistent()
        }
        if service == .tikTok || service == .x {
            // Honor inline playback when the website supplies playsinline markup.
            configuration.allowsInlineMediaPlayback = true
        }
        if service == .tikTok {
            configuration.preferences.isElementFullscreenEnabled = true
            configuration.userContentController.addUserScript(TikTokFullscreenControl.userScript)
        }
        // X's desktop Home feed needs the same muted-video autoplay opportunity
        // that WebKit offers Safari. Keep audible media gesture-gated, and keep
        // inactive profiles suspended. Other services retain tap-to-play video.
        configuration.mediaTypesRequiringUserActionForPlayback = service == .x ? [.audio] : [.video, .audio]
        return configuration
    }

    /// Deletes only this service's identifier-backed remembered store.
    /// Call after removing its WebKit views from the hierarchy.
    public func clearRememberedData(for service: SocialService) async {
        let store = WKWebsiteDataStore(forIdentifier: identifier(for: service))
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }
}

/// Stores the owner's per-service browsing choice, never website credentials.
public enum BrowserProfilePreferences {
    public static func hasChoice(
        for service: SocialService,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.string(forKey: key(for: service)) != nil
    }

    public static func mode(
        for service: SocialService,
        defaults: UserDefaults = .standard
    ) -> BrowserPersistenceMode {
        let value = defaults.string(forKey: key(for: service))
        return value.flatMap(BrowserPersistenceMode.init(rawValue:)) ?? .remembered
    }

    public static func setMode(
        _ mode: BrowserPersistenceMode,
        for service: SocialService,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key(for: service))
    }

    private static func key(for service: SocialService) -> String {
        "social.persistence.\(service.id)"
    }
}

public enum SocialNavigationPolicy {
    /// App Store destinations are never opened automatically from website content.
    public static func isAppStoreDestination(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "itms-apps" { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "apps.apple.com" || host == "itunes.apple.com"
    }

    /// Only ordinary HTTPS page loads are accepted by the embedded browser.
    /// Other schemes and App Store destinations require a separate explicit action.
    public static func permitsEmbeddedLoad(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && !isAppStoreDestination(url)
    }

    public static func permitsPopupBootstrap(_ url: URL) -> Bool {
        permitsEmbeddedLoad(url) || url.absoluteString == "about:blank"
    }
}

/// Keeps a deliberate navigation rejection visible when WebKit later reports
/// the secondary policy-interruption error for that same attempt.
enum SocialNavigationErrorPolicy {
    // WebKit's frame-load-interrupted-by-policy-change error code.
    private static let policyInterruptionCode = 102

    static func shouldReport(_ error: NSError, hasExistingMessage: Bool) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return false
        }
        if hasExistingMessage && error.domain == "WebKitErrorDomain" && error.code == policyInterruptionCode {
            return false
        }
        return true
    }
}
