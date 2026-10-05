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
        for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(background), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(protectedDataUnavailable),
                           name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
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
        if !UIApplication.shared.isProtectedDataAvailable {
            protectedDataUnavailable()
            return
        }
        coordinator.applicationDidBecomeActive()
        shield.revealImmediately()
    }

    @objc private func protectedDataUnavailable() {
        shield.coverImmediately()
        coordinator.nativeGuest.endVerificationHandoff()
        coordinator.applicationDidEnterBackground()
    }

    public func beginVerificationHandoff() {
        guard UIApplication.shared.isProtectedDataAvailable else {
            protectedDataUnavailable()
            return
        }
        shield.coverImmediately()
        if coordinator.nativeGuest.beginVerificationHandoff() {
            coordinator.lockForNativeVerificationHandoff()
        } else {
            coordinator.lock()
        }
        revealCalculatorAfterLock()
    }

    public func beginSignalDiagnostic() {
        guard UIApplication.shared.isProtectedDataAvailable else {
            protectedDataUnavailable()
            return
        }
        shield.coverImmediately()
        if coordinator.nativeGuest.beginSignalDiagnostic() {
            coordinator.lockForNativeVerificationHandoff()
        } else {
            coordinator.lock()
        }
        revealCalculatorAfterLock()
    }

    public func lock() {
        shield.coverImmediately()
        coordinator.lock()
        revealCalculatorAfterLock()
    }

    private func revealCalculatorAfterLock() {
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
            if let controller = guest.mountedViewController {
                NativeGuestSurface(controller: controller, authorized: guest.showingGuest, ready: guest.surfaceReady)
                    .ignoresSafeArea()
                    .opacity(guest.showingGuest ? 1 : 0)
                    .allowsHitTesting(guest.showingGuest)
                    .accessibilityHidden(!guest.showingGuest)
            }
            if guest.showingGuest {
                HStack {
                    Button("Lock", action: host.lock)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.9), in: Capsule())
                    if guest.canBeginVerificationHandoff {
                        Button("Get code", action: host.beginVerificationHandoff)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.black.opacity(0.9), in: Capsule())
                            .accessibilityHint("Locks the Vault and holds this guest for up to two minutes while you get a verification code. Keep the phone unlocked and authenticate again on return.")
                    }
                    if guest.canBeginSignalDiagnostic {
                        Button("Pause test", action: host.beginSignalDiagnostic)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.black.opacity(0.9), in: Capsule())
                            .accessibilityHint("Conceals the guest before submitting a signal pause request. Guest suspension and media stop are unproved. Resume requires fresh authentication and a credential check within 30 seconds. Lock, protected-data loss, or expiry ends the test.")
                    }
                }
                .padding(.leading, 12).padding(.top, 8)
            }
        }
    }
}

private struct NativeGuestSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    let authorized: Bool
    let ready: @MainActor () -> Void
    func makeUIViewController(context: Context) -> NativeGuestMount {
        NativeGuestMount(child: controller, authorized: authorized, ready: ready)
    }
    func updateUIViewController(_ controller: NativeGuestMount, context: Context) {
        controller.updateAuthorization(authorized)
    }
}

private final class NativeGuestMount: UIViewController {
    private let child: UIViewController
    private let ready: @MainActor () -> Void
    private var started = false
    private var authorized: Bool
    init(child: UIViewController, authorized: Bool, ready: @escaping @MainActor () -> Void) {
        self.child = child
        self.authorized = authorized
        self.ready = ready
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    func updateAuthorization(_ authorized: Bool) {
        self.authorized = authorized
        if !authorized { started = false; return }
        startWhenAttached()
    }
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
        guard authorized, !started, let window = view.window, !view.bounds.isEmpty else { return }
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

/// A manual shortcut to the same checked launch used by the diagnostic section.
struct NativeGuestSocialLaunchButton: View {
    @ObservedObject var model: NativeGuestCoordinator
    let start: () -> Void
    private let profile = NativeGuestIntegrationProfile.current

    var body: some View {
        if profile?.representsTikTokGuest == true {
            Button(model.canResumeSignalDiagnostic ? "Resume pause test" : (model.canResumeVerification ? "Resume TikTok verification" : "TikTok (native)"), systemImage: "play.rectangle", action: start)
                .disabled(!model.canRequestLaunch && !model.canResumeVerification && !model.canResumeSignalDiagnostic)
                .accessibilityIdentifier("native-tiktok-launch")
        }
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
            Text(profile?.representsTikTokGuest == true
                 ? "Private native TikTok candidate. Browser services and downloaders remain separate. Guest data is not vault-encrypted."
                 : "Synthetic guest only. Native TikTok is not included in this isolation-test build.")
            Text("Face ID may be requested to verify protected credential metadata before launch. No credential values are shared with the guest.")
            Button(model.canResumeSignalDiagnostic ? "Resume pause test" : (model.canResumeVerification ? "Resume verification" : (profile?.representsTikTokGuest == true ? "Open native TikTok" : "Open isolated test guest")), action: start)
                .disabled(profile == nil || (!model.canRequestLaunch && !model.canResumeVerification && !model.canResumeSignalDiagnostic))
            Text(status)
            Button("Refresh native report") { report = model.summary }
            if !report.isEmpty { Text(report).font(.footnote.monospaced()).textSelection(.enabled) }
            Text("One guest attempt per app launch. Restart after testing. Credential checks do not certify isolation.")
                .font(.footnote)
            Text("The verified two-minute handoff is unavailable unless the runtime proves pause and resume. The separate signal diagnostic is opt-in and lasts at most 30 seconds. It conceals the guest before submitting a pause request; submission does not prove suspension or media stop. Resume is manual through the normal fresh-authentication and credential-check path. A failed or cancelled check stays concealed; no automatic resume signal is sent. Lock, protected-data loss, lease failure or expiry ends the diagnostic.")
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
        case .holding: model.isSignalDiagnosticHeld
            ? (model.isSignalDiagnosticPauseRequestSubmitted
                ? "Signal pause request submitted. Suspension and media stop are unproved; resume requires fresh authentication and a current credential check."
                : "Signal diagnostic request pending. Suspension and media stop are unproved.")
            : "Verification handoff held behind the locked calculator. Resume requires fresh authentication and a current credential check."
        case .blocked: "Launch blocked. Refresh the native report for the diagnostic code. No credential changes were made by this check."
        case .ended: "Guest revoked. Restart the app before another native launch."
        }
    }
}
