import SwiftUI
import UIKit
import CalcVaultKit

@main
@MainActor
struct LiveContainerSwiftUIApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(IntegrationAppDelegate.self) private var appDelegate
    @StateObject private var host = CalcVaultIntegratedHost {
        try IntegrationRuntime()
    }
    var body: some Scene {
        WindowGroup {
            CalcVaultIntegratedRootView(host: host)
                .onAppear { NSLog("CV_INTEGRATION_ROOT_ACTIVE") }
        }
    }
}

/// Only the scene glue needed by the reviewed runtime. Do not instantiate the
/// upstream app model, restore selections, process intents or launch JIT flows.
@MainActor
private final class IntegrationAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.shortcutItems = nil
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self,
                #selector(UIApplication.requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self,
                #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!)
        // LiveContainer/Tweaks/Dyld.m consumes these symbol offsets. Preserve
        // OS-version invalidation without initializing the upstream UI model.
        let defaults = LCUtils.appGroupUserDefault
        if defaults.string(forKey: "LCLastIOSBuildVersion") != UIDevice.current.buildVersion {
            defaults.removeObject(forKey: "symbolOffsetCache")
            defaults.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        return true
    }
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
private final class IntegrationRuntime: NativeGuestRuntime {
    private let session: CVLPGuestSession
    init() throws {
        // Called only after CalcVault's fresh credential/session checks. This
        // prepares disposable boundary controls, never production key material.
        if let failure = CVLPProbe.prepareHost() {
            throw Self.preparationFailure(failure)
        }
        UserDefaults.lcShared().set(0, forKey: "LCMultitaskMode")
        session = CVLPGuestSession()
    }
    var viewController: UIViewController { session.viewController }
    var summary: String { session.summary + "\n\n" + CVLPProbe.hostSummary() }
    func start(completion: @escaping @MainActor (Bool) -> Void) {
        session.start { success in
            // CVLPGuestSession asserts main-thread delivery; fail closed if
            // future runtime changes violate this actor contract.
            MainActor.assumeIsolated { completion(success) }
        }
    }
    func revoke() { session.revoke() }
    // Exact known fixture messages map to fixed codes; never display arbitrary
    // NSError descriptions, entitlement values or filesystem paths.
    private static func preparationFailure(_ message: String) -> NativeGuestPreparationFailure {
        switch message {
        case "Signing export absence could not be verified; guest launch blocked.": .signingExport
        case "Immutable framework guest contract is missing or invalid.": .immutableContract
        case "Synthetic fixture setup failed (host support directory unavailable).": .hostSupport
        case "Synthetic fixture setup failed (host fixture directory unavailable).": .hostFixtureDirectory
        case "Synthetic fixture setup failed (host sentinel could not be created).": .hostSentinelCreate
        case "Synthetic fixture setup failed (host sentinel readback did not match).": .hostSentinelReadback
        case "Synthetic guest staging failed (host documents directory unavailable).": .hostDocuments
        case "Guest data path is not an ordinary private directory.": .guestDirectoryType
        case "Guest data directory could not be prepared.": .guestDirectoryCreate
        case "CV_INTEGRATION_PREP_APP_ID_CONTROL": .appIDControl
        case "CV_INTEGRATION_PREP_HOST_ONLY_CONTROL": .hostOnlyControl
        case "CV_INTEGRATION_PREP_BOTH_CONTROLS": .bothControls
        default: .unclassified
        }
    }
}
