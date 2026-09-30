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
        if CVLPProbe.prepareHost() != nil { throw PreparationFailure.unavailable }
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
    private enum PreparationFailure: Error { case unavailable }
}
