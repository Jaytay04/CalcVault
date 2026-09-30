import SwiftUI
import UIKit

/// The containing runtime supplies only a guest factory. Authentication, vault
/// keys and session revocation remain owned by CalcVault, not the runtime.
@MainActor
public final class CalcVaultIntegratedHost: NSObject, ObservableObject {
    public let coordinator: AppCoordinator
    private let shield = PrivacyShieldController()

    public init(runtimeFactory: @escaping @MainActor () throws -> any NativeGuestRuntime) {
        coordinator = AppCoordinator(nativeRuntimeFactory: runtimeFactory)
        super.init()
        // Construct the revocation subscriber before any guest can be requested.
        _ = coordinator.nativeGuest
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            center.addObserver(self, selector: #selector(inactive), name: name, object: nil)
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            center.addObserver(self, selector: #selector(background), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            center.addObserver(self, selector: #selector(active), name: name, object: nil)
        }
    }

    @objc private func inactive() {
        shield.coverImmediately()
        coordinator.applicationWillResignActive()
    }

    @objc private func background() {
        shield.coverImmediately()
        coordinator.applicationDidEnterBackground()
    }

    @objc private func active() {
        coordinator.applicationDidBecomeActive()
        shield.revealImmediately()
    }

    public func lock() {
        shield.coverImmediately()
        coordinator.lock()
        // NativeGuestRuntime.revoke hides its surface synchronously. The root
        // view must also finish switching to the calculator before revealing.
        DispatchQueue.main.async { [weak self] in
            guard let self, UIApplication.shared.applicationState == .active,
                  self.coordinator.lifecycle.state == .calculatorLocked else { return }
            self.shield.revealImmediately()
        }
    }
}

public struct CalcVaultIntegratedRootView: View {
    @ObservedObject private var host: CalcVaultIntegratedHost
    @ObservedObject private var guest: NativeGuestCoordinator

    public init(host: CalcVaultIntegratedHost) {
        self.host = host
        self.guest = host.coordinator.nativeGuest
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ContentView()
                .environmentObject(host.coordinator)
                .opacity(guest.showingGuest ? 0 : 1)
                .allowsHitTesting(!guest.showingGuest)
                .accessibilityHidden(guest.showingGuest)
            if guest.showingGuest, let controller = guest.viewController {
                NativeGuestSurface(controller: controller, ready: guest.surfaceReady)
                    .ignoresSafeArea()
                Button("Lock", action: host.lock)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(.black.opacity(0.9), in: Capsule())
                    .padding(.leading, 12).padding(.top, 8)
            }
        }
    }
}

private struct NativeGuestSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    let ready: @MainActor () -> Void
    func makeUIViewController(context: Context) -> NativeGuestMount {
        NativeGuestMount(child: controller, ready: ready)
    }
    func updateUIViewController(_ controller: NativeGuestMount, context: Context) {}
}

private final class NativeGuestMount: UIViewController {
    private let child: UIViewController
    private let ready: @MainActor () -> Void
    private var started = false
    init(child: UIViewController, ready: @escaping @MainActor () -> Void) {
        self.child = child
        self.ready = ready
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        child.view.frame = view.bounds
        startWhenAttached()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startWhenAttached()
    }
    private func startWhenAttached() {
        guard !started, let window = view.window, !view.bounds.isEmpty else { return }
        let frame = view.convert(view.bounds, to: window)
        guard abs(frame.minX - window.bounds.minX) < 0.5,
              abs(frame.minY - window.bounds.minY) < 0.5,
              abs(frame.width - window.bounds.width) < 0.5,
              abs(frame.height - window.bounds.height) < 0.5 else { return }
        started = true
        // Avoid publishing SwiftUI state from inside its layout pass.
        DispatchQueue.main.async { [ready] in ready() }
    }
}

struct NativeGuestIntegrationSection: View {
    @ObservedObject var model: NativeGuestCoordinator
    let start: () -> Void
    @State private var report = ""
    private let profile = NativeGuestIntegrationProfile.current
    var body: some View {
        Section("Native integration test") {
            Text(profile?.title ?? "Native package identity unavailable")
            Text(profile == .tikTok
                 ? "Private native TikTok candidate. Browser services and downloaders remain separate. Guest data is not vault-encrypted."
                 : "Synthetic guest only. Native TikTok is not included in this isolation-test build.")
            Text("Face ID may be requested to verify protected credential metadata before launch. No credential values are shared with the guest.")
            Button(profile == .tikTok ? "Open native TikTok" : "Open isolated test guest", action: start)
                .disabled(profile == nil || (model.state != .idle && model.state != .blocked))
            Text(status)
            Button("Refresh native report") { report = model.summary }
            if !report.isEmpty { Text(report).font(.footnote.monospaced()).textSelection(.enabled) }
            Text("One guest attempt per app launch. Restart after testing. Credential checks do not certify isolation.")
                .font(.footnote)
        }
    }
    private var status: String {
        switch model.state {
        case .unavailable: "Native runtime unavailable."
        case .idle: "Ready to check credentials and launch the test guest."
        case .checking: "Checking credential boundary."
        case .presenting: "Attaching isolated guest."
        case .running: "Guest request accepted; verify visible content separately."
        case .blocked: "Launch blocked. Refresh the native report for the diagnostic code. No credential changes were made by this check."
        case .ended: "Guest revoked. Restart the app before another native launch."
        }
    }
}
