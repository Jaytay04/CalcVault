import LocalAuthentication
import Darwin

@MainActor
final class CVLPLifecycleModel: NSObject, ObservableObject {
    @Published var report = "Build 19. Ready for a disposable lifecycle test."
    @Published var showingGuest = false
    @Published var locked = false
    @Published var attempted = false
    @Published private(set) var verificationSignalProbeAttempted = false
    @Published private(set) var verificationSignalProbeRunning = false
    @Published private(set) var verificationSignalProbeStatus = "Start the test tone in the guest, then tap once; suspension and media stop are unproved."
    let guest = CVLPGuestSession()
    private var gate = CVLPLifecycleGate()
    private var context: LAContext?
    private var pending: (UInt64, [String: Any], Bool)?
    private var covers: [UIWindow] = []
    private var observations: [String] = []
    private var inactiveTransition = false
    private var surfaceToken: UInt64?
    private var launchedToken: UInt64?
    private var verificationSignalProbeGeneration: UInt64 = 0
    private var verificationSignalContinueWorkItem: DispatchWorkItem?
    private let verificationSignalProbeDuration: TimeInterval = 2.0

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            center.addObserver(self, selector: #selector(inactive(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            center.addObserver(self, selector: #selector(background(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            center.addObserver(self, selector: #selector(active(_:)), name: name, object: nil)
        }
    }

    func start(delayed: Bool = false) {
        guard !attempted, !inactiveTransition, UIApplication.shared.applicationState == .active,
              let token = gate.begin() else { return }
        attempted = true
        locked = false
        observe("Preparation started; one attempt per app launch.")
        let authentication = LAContext()
        context = authentication
        report = "Complete Face ID for disposable test items. No production credentials are read."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CVLPKeychainMigrationFixture.prepare(context: authentication)
            DispatchQueue.main.async { [self] in
                context = nil
                guard gate.accepts(token: token) else {
                    observe("Stale preparation callback REJECTED."); refresh(); return
                }
                // Face ID can finish before UIKit sends didBecomeActive.
                pending = (token, result, delayed)
                consumePreparationIfActive()
            }
        }
    }

    private func consumePreparationIfActive() {
        guard !inactiveTransition, UIApplication.shared.applicationState == .active, let (token, result, delayed) = pending else { return }
        pending = nil
        guard gate.accepts(token: token) else { observe("Stale pending preparation REJECTED."); return }
        CVLPProbe.setMigrationFixture(result)
        if let error = CVLPProbe.prepareHost() {
            _ = gate.prepared(token: token, ready: false)
            locked = true
            observe("Preparation blocked: " + error); refresh(); return
        }
        guard gate.prepared(token: token, ready: true) else { return }
        if delayed {
            observe("Delayed launch armed for 8 seconds. Lock now to reject it.")
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in launch(token: token) }
        } else { launch(token: token) }
    }

    private func launch(token: UInt64) {
        guard gate.accepts(token: token), !inactiveTransition, UIApplication.shared.applicationState == .active else {
            observe("Stale launch callback REJECTED; guest not started."); refresh()
            NSLog("CVLP_LIFECYCLE_STALE_LAUNCH_REJECTED"); return
        }
        UserDefaults.lcShared().set(0, forKey: "LCMultitaskMode")
        surfaceToken = token
        launchedToken = token
        showingGuest = true
    }

    func surfaceReady() {
        guard let token = surfaceToken else { return }
        surfaceToken = nil
        launchedToken = token
        guard gate.accepts(token: token), !inactiveTransition, UIApplication.shared.applicationState == .active else {
            observe("Stale surface attachment REJECTED."); refresh(); return
        }
        guest.start { [self] success in
            guard gate.accepts(token: token), !inactiveTransition, UIApplication.shared.applicationState == .active else {
                guest.revoke(); observe("Stale extension callback REJECTED."); refresh(); return
            }
            if success && gate.attached(token: token) {
                observe("Guest request accepted for the current generation; visibility is a separate check.")
                NSLog("CVLP_HOST_LAUNCHED")
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["CVLP_LIFECYCLE_AUTOTEST"] == "lock" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.lock(reason: "simulator explicit lock") }
                } else if ProcessInfo.processInfo.environment["CVLP_LIFECYCLE_AUTOTEST"] == "diagnostic-deadline" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 35) { self.lock(reason: "simulator diagnostic deadline test") }
                } else if ProcessInfo.processInfo.environment["CVLP_LIFECYCLE_AUTOTEST"] == "portrait",
                          Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.gate.accepts(token: token), !self.inactiveTransition,
                              UIApplication.shared.applicationState == .active,
                              let scene = self.guest.viewController.viewIfLoaded?.window?.windowScene else { return }
                        NSLog("CVLP_PORTRAIT_LANDSCAPE_REQUEST")
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in
                            NSLog("CVLP_PORTRAIT_LANDSCAPE_REJECTED")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, self.gate.accepts(token: token), !self.inactiveTransition,
                              UIApplication.shared.applicationState == .active,
                              let view = self.guest.viewController.viewIfLoaded,
                              let window = view.window, let scene = window.windowScene else { return }
                        if scene.interfaceOrientation == .portrait && window.bounds.width > 0 &&
                            window.bounds.height > window.bounds.width && view.bounds.size == window.bounds.size {
                            NSLog("CVLP_PORTRAIT_HOST_RETAINED")
                        } else { NSLog("CVLP_PORTRAIT_HOST_FAILED") }
                        self.lock(reason: "simulator portrait policy test")
                    }
                }
#endif
            } else { lock(reason: "guest launch failed") }
            refresh()
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CVLP_LIFECYCLE_AUTOTEST"] == "race" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.lock(reason: "simulator pending request race") }
        }
#endif
    }

    func startVerificationSignalProbe() {
        guard !verificationSignalProbeAttempted else { return }
        verificationSignalProbeAttempted = true
        guard Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true else {
            verificationSignalProbeStatus = "Probe refused: fixed synthetic framework research mode is not enabled."
            observe(verificationSignalProbeStatus)
            refresh()
            return
        }
        guard !inactiveTransition, UIApplication.shared.applicationState == .active,
              !locked, showingGuest, let token = launchedToken, gate.accepts(token: token),
              guest.isVerificationSignalProbeAvailable else {
            verificationSignalProbeStatus = "Probe unsupported or refused: exact synthetic descriptor, initialized scene, PID, selector, or foreground state is missing."
            observe(verificationSignalProbeStatus)
            refresh()
            return
        }
        guard guest.requestVerificationSignal(SIGSTOP) else {
            verificationSignalProbeStatus = "SIGSTOP request refused by the synthetic session guard."
            observe(verificationSignalProbeStatus)
            refresh()
            return
        }

        verificationSignalProbeRunning = true
        verificationSignalProbeStatus = "SIGSTOP request submitted; SIGCONT is scheduled after 2 seconds. Observe the guest's counter/control and tone. Suspension and media stop are unproved."
        observe(verificationSignalProbeStatus)
        verificationSignalProbeGeneration &+= 1
        let generation = verificationSignalProbeGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finishVerificationSignalProbe(generation: generation, guestToken: token)
            }
        }
        verificationSignalContinueWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + verificationSignalProbeDuration, execute: workItem)
        refresh()
    }

    private func finishVerificationSignalProbe(generation: UInt64, guestToken: UInt64) {
        guard verificationSignalProbeGeneration == generation,
              verificationSignalProbeRunning,
              launchedToken == guestToken,
              gate.accepts(token: guestToken),
              !inactiveTransition,
              UIApplication.shared.applicationState == .active,
              !locked, showingGuest else {
            cancelVerificationSignalProbe()
            verificationSignalProbeStatus = "Probe cancelled by lifecycle change; no late continuation request will be sent."
            observe(verificationSignalProbeStatus)
            lock(reason: "verification probe lost foreground or generation")
            return
        }
        verificationSignalContinueWorkItem = nil
        verificationSignalProbeRunning = false
        if guest.requestVerificationSignal(SIGCONT) {
            verificationSignalProbeStatus = "SIGCONT request submitted from the scheduled 2-second callback; suspension and media stop remain unproved. Use Lock to revoke the synthetic guest."
        } else {
            verificationSignalProbeStatus = "SIGCONT request refused; the host is revoking the guest now. Suspension and media stop are unproved."
            observe(verificationSignalProbeStatus)
            lock(reason: "verification continuation request refused")
            return
        }
        observe(verificationSignalProbeStatus)
        refresh()
    }

    private func cancelVerificationSignalProbe() {
        verificationSignalProbeGeneration &+= 1
        verificationSignalContinueWorkItem?.cancel()
        verificationSignalContinueWorkItem = nil
        if verificationSignalProbeRunning {
            verificationSignalProbeRunning = false
            verificationSignalProbeStatus = "Probe cancelled by lifecycle revocation; no continuation request will be sent."
        }
    }

    func lock(reason: String = "explicit lock") {
        cover()
        cancelVerificationSignalProbe()
        gate.revoke()
        pending = nil
        surfaceToken = nil
        launchedToken = nil
        context?.invalidate(); context = nil
        guest.revoke()
        showingGuest = false
        locked = true
        observe("Locked: " + reason + "; generation revoked.")
        refresh()
        if UIApplication.shared.applicationState == .active { uncoverAfterTransition() }
        // Observation only; shutdown never waits for these timers.
        for seconds in [1.0, 4.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.refresh() }
        }
    }
    @objc private func inactive(_ notification: Notification) {
        inactiveTransition = true
        cover()
        // Only the app-owned biometric preparation may survive inactivity.
        // Genuine backgrounding always revokes, including during Face ID.
        if gate.phase != .preparing { lock(reason: "inactive") }
    }
    @objc private func background(_ notification: Notification) { inactiveTransition = true; lock(reason: "background or protected-data loss") }
    @objc private func active(_ notification: Notification) {
        inactiveTransition = false
        consumePreparationIfActive()
        uncoverAfterTransition()
    }

    private func cover() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard !covers.contains(where: { $0.windowScene === scene }) else { continue }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 100
            window.backgroundColor = .black
            window.rootViewController = UIHostingController(rootView: CVLPCalculatorCover())
            window.isHidden = false
            covers.append(window)
        }
        NSLog("CVLP_LIFECYCLE_COVER_INSTALLED")
    }
    private func uncoverAfterTransition() {
        DispatchQueue.main.async { [self] in
            guard !inactiveTransition, UIApplication.shared.applicationState == .active else { return }
            for window in covers { window.isHidden = true }
            covers.removeAll()
        }
    }
    private func observe(_ message: String) {
        observations.append(message)
        observations = Array(observations.suffix(30))
    }
    func refresh() {
        if !verificationSignalProbeAttempted && showingGuest {
            verificationSignalProbeStatus = guest.isVerificationSignalProbeAvailable
                ? "Synthetic signal probe ready. Start the guest tone and counter, then tap once; suspension and media stop are unproved."
                : "Signal probe unavailable: exact synthetic descriptor, initialized scene, PID, or selector is missing."
        }
        report = "Build 19 lifecycle observations (not a security certification)\n\n"
            + observations.joined(separator: "\n") + "\n\n" + guest.summary + "\n\n"
            + verificationSignalProbeStatus + "\n\n" + CVLPProbe.hostSummary()
        NSLog("CVLP_LIFECYCLE_STATUS %@", guest.summary)
    }
}

struct CVLPCalculatorCover: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Calculator").padding(.top, 50)
            Spacer()
            HStack { Spacer(); Text("0").font(.system(size: 72, weight: .light)) }
            ForEach([["AC", "±", "%", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["⌫", "0", ".", "="]], id: \.self) { row in
                HStack {
                    ForEach(row, id: \.self) { key in
                        Text(key).font(.title2).frame(maxWidth: .infinity).frame(height: 52)
                            .background(key == row.last ? Color.orange : Color(white: 0.18)).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }.padding(20).foregroundStyle(.white).background(.black).ignoresSafeArea()
    }
}

struct CVLPGuestSurface: UIViewControllerRepresentable {
    let session: CVLPGuestSession
    let onReady: () -> Void
    func makeUIViewController(context: Context) -> UIViewController { CVLPMountController(session: session, onReady: onReady) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

final class CVLPMountController: UIViewController {
    let session: CVLPGuestSession
    let onReady: () -> Void
    private var started = false
    private let frameworkGuestMode = Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true
    private var fullWindowFitLogged = false
    init(session: CVLPGuestSession, onReady: @escaping () -> Void) {
        self.session = session
        self.onReady = onReady
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not used by the synthetic fixture") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let child = session.viewController
        addChild(child)
        if frameworkGuestMode { view.clipsToBounds = true }
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard frameworkGuestMode,
              let childView = session.viewController.viewIfLoaded else { return }
        childView.frame = view.bounds

        guard !fullWindowFitLogged,
              let window = view.window, !view.bounds.isEmpty,
              childView.bounds.size == view.bounds.size else { return }
        let mountInWindow = view.convert(view.bounds, to: window)
        let windowBounds = window.bounds
        guard abs(mountInWindow.minX - windowBounds.minX) <= 1,
              abs(mountInWindow.minY - windowBounds.minY) <= 1,
              abs(mountInWindow.width - windowBounds.width) <= 1,
              abs(mountInWindow.height - windowBounds.height) <= 1 else { return }
        fullWindowFitLogged = true
        NSLog("CVLP_FULL_WINDOW_HOST_FIT")
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started, view.window != nil, !view.bounds.isEmpty else { return }
        started = true
        onReady()
    }
}

struct CVLPHostView: View {
    @StateObject private var model = CVLPLifecycleModel()
    @State private var reportVisible = false
    @State private var autoStarted = false
    private var frameworkGuestMode: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true
    }
    var body: some View {
        Group {
            if model.locked && !reportVisible {
                ZStack(alignment: .topTrailing) {
                    CVLPCalculatorCover()
                    Button("Test report") { reportVisible = true; model.refresh() }.padding(.top, 50).padding(.trailing)
                }
            } else if model.showingGuest && frameworkGuestMode {
                ZStack(alignment: .topLeading) {
                    CVLPGuestSurface(session: model.guest, onReady: model.surfaceReady).ignoresSafeArea()
                    Button("Lock") { reportVisible = false; model.lock() }
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color.black.opacity(0.9), in: Capsule())
                        .padding(.leading, 12)
                        .padding(.top, 8)
                    VStack(spacing: 4) {
                        Button(model.verificationSignalProbeAttempted ? "Signal probe used" : "2-second signal probe") {
                            model.startVerificationSignalProbe()
                        }
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color.black.opacity(0.9), in: Capsule())
                        .disabled(model.verificationSignalProbeAttempted || !model.guest.isVerificationSignalProbeAvailable)
                        Text(model.verificationSignalProbeStatus)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                VStack {
                    HStack {
                        Text("Native lifecycle test · 19").font(.headline)
                        Spacer()
                        Button("Lock") { reportVisible = false; model.lock() }
                    }.padding()
                    if model.showingGuest { CVLPGuestSurface(session: model.guest, onReady: model.surfaceReady) }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Button("Authenticate and launch test guest") { model.start() }.disabled(model.attempted)
                                Button("Prepare delayed launch (8 seconds)") { model.start(delayed: true) }.disabled(model.attempted)
                                Button("Refresh host report") { model.refresh() }
                                Text(model.report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                Text("Synthetic data only. Restart the app for each new launch test. The test tone starts only when tapped inside the guest.").font(.footnote)
                            }.padding()
                        }
                    }
                }
            }
        }.onAppear {
#if targetEnvironment(simulator)
            guard !autoStarted, ProcessInfo.processInfo.environment["CVLP_AUTORUN"] == "1" else { return }
            autoStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.start() }
#endif
        }
    }
}
