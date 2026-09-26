import SwiftUI

@main
@MainActor
public struct CalcVaultApp: App {
    @UIApplicationDelegateAdaptor(CalcVaultAppDelegate.self) private var appDelegate
    @StateObject private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        _coordinator = StateObject(wrappedValue: AppCoordinator())
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .onAppear {
                    appDelegate.privacyShieldController.revealImmediately()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                coordinator.applicationDidBecomeActive()
                appDelegate.privacyShieldController.revealImmediately()
            case .inactive:
                coordinator.applicationWillResignActive()
                appDelegate.privacyShieldController.coverImmediately()
            case .background:
                coordinator.applicationDidEnterBackground()
                appDelegate.privacyShieldController.coverImmediately()
            @unknown default:
                break
            }
        }
    }
}
