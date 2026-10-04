import LocalAuthentication
import Darwin

private final class CVLPBackgroundLeaseExpiryFlag {
    private let lock = NSLock()
    private var expired = false

    func markExpired() {
        lock.lock()
        expired = true
        lock.unlock()
    }

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

@MainActor
final class CVLPLifecycleModel: NSObject, ObservableObject {
    @Published var report = "Build 19. Ready for a disposable lifecycle test."
    @Published var showingGuest = false
    @Published var locked = false
    @Published var attempted = false
    @Published private(set) var verificationSignalProbeAttempted = false
    @Published private(set) var verificationSignalProbeRunning = false
    @Published private(set) var verificationSignalProbeStatus = "Start the test tone in the guest, then tap once; suspension and media stop are unproved."
    @Published private(set) var signalExperimentAttempted = false
    @Published private(set) var holdAttempted = false
    @Published private(set) var holdingSyntheticGuest = false
    @Published private(set) var syntheticHandoffStatus = "No background hold has been requested."
    let guest = CVLPGuestSession()
    private var gate = CVLPLifecycleGate()
    private var handoffGate = CVLPSyntheticHandoffGate()
    private var context: LAContext?
    private var handoffAuthenticationContext: LAContext?
    private var pending: (UInt64, [String: Any], Bool)?
    private var covers: [UIWindow] = []
    private var observations: [String] = []
    private var inactiveTransition = false
    private var surfaceToken: UInt64?
    private var launchedToken: UInt64?
    private var verificationSignalProbeGeneration: UInt64 = 0
    private var verificationSignalContinueWorkItem: DispatchWorkItem?
    private let verificationSignalProbeDuration: TimeInterval = 2.0
    private let handoffClock = ContinuousClock()
    private var handoffToken: UInt64?
    private var heldStartupToken: UInt64?
    private var handoffDeadlineWorkItem: DispatchWorkItem?
    private var handoffBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var handoffLeaseExpiryFlag: CVLPBackgroundLeaseExpiryFlag?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            center.addObserver(self, selector: #selector(inactive(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(background(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(protectedDataWillBecomeUnavailable(_:)),
                           name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
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
        guard !signalExperimentAttempted else { return }
        signalExperimentAttempted = true
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

    var canAuthenticateHeldGuest: Bool {
        holdingSyntheticGuest && handoffGate.phase == .holding &&
            !inactiveTransition && UIApplication.shared.applicationState == .active
    }

    var canContinueAuthenticatedGuest: Bool {
        holdingSyntheticGuest && handoffGate.phase == .readyToResume &&
            !inactiveTransition && UIApplication.shared.applicationState == .active
    }

    func holdSyntheticGuest() {
        guard !signalExperimentAttempted else { return }
        signalExperimentAttempted = true
        holdAttempted = true
        guard Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true,
              !inactiveTransition, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable,
              !locked, showingGuest, let startupToken = launchedToken,
              gate.phase == .running, gate.accepts(token: startupToken), guest.isVerificationSignalProbeAvailable,
              let token = handoffGate.begin(now: handoffClock.now, foreground: true,
                                           protectedDataAvailable: true) else {
            lock(reason: "synthetic hold preconditions refused")
            return
        }
        handoffToken = token
        heldStartupToken = startupToken
        let expiry = CVLPBackgroundLeaseExpiryFlag()
        handoffLeaseExpiryFlag = expiry
        // Acquisition can expire synchronously. Latch before dispatching any actor work.
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "SyntheticGuestHold") { [weak self] in
            expiry.markExpired()
            let expireOnMain = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.handoffToken == token else { return }
                    self.lock(reason: "synthetic background allowance expired")
                }
            }
            if Thread.isMainThread { expireOnMain() }
            else { DispatchQueue.main.async(execute: expireOnMain) }
        }
        handoffBackgroundTask = identifier
        guard handoffGate.leaseAcquired(token: token,
                    valid: identifier != .invalid && !expiry.isExpired,
                    now: handoffClock.now, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable),
              handoffGate.prepareStop(token: token, now: handoffClock.now,
                    foreground: !inactiveTransition && UIApplication.shared.applicationState == .active,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                    guestAttached: guest.viewController.viewIfLoaded?.window != nil),
              !expiry.isExpired,
              guest.requestVerificationSignal(SIGSTOP),
              !expiry.isExpired,
              handoffGate.stopRequestAccepted(token: token, now: handoffClock.now) else {
            lock(reason: "synthetic hold lease or STOP request refused")
            return
        }
        // Revoke ordinary startup/interaction authority without detaching the scene.
        gate.revoke()
        surfaceToken = nil
        launchedToken = nil
        pending = nil
        context?.invalidate(); context = nil
        holdingSyntheticGuest = true
        locked = true
        syntheticHandoffStatus = "Synthetic STOP request submitted. Guest concealed for at most 120 seconds, subject to earlier iOS expiry. Suspension and media stop are unproved. Manual biometric authentication is required to resume this test; it does not unlock the Vault."
        cover()
        observe(syntheticHandoffStatus)
        guard let deadline = handoffGate.deadline else {
            lock(reason: "synthetic hold deadline missing"); return
        }
        let remaining = handoffClock.now.duration(to: deadline).components
        let seconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.handoffToken == token else { return }
                self.lock(reason: "synthetic hold deadline expired")
            }
        }
        handoffDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        refresh()
    }

    private func heldGuestIsLive() -> Bool {
        guard holdingSyntheticGuest, let token = handoffToken,
              heldStartupToken != nil, handoffBackgroundTask != .invalid,
              let expiry = handoffLeaseExpiryFlag, !expiry.isExpired,
              UIApplication.shared.isProtectedDataAvailable else { return false }
        return handoffGate.isLive(token: token, now: handoffClock.now)
    }

    func authenticateAndResumeSyntheticGuest() {
        guard canAuthenticateHeldGuest else { return }
        guard heldGuestIsLive(), let token = handoffToken,
              let attempt = handoffGate.beginAuthentication(token: token, now: handoffClock.now,
                    foreground: !inactiveTransition && UIApplication.shared.applicationState == .active,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) else {
            lock(reason: "synthetic resume authentication preconditions refused"); return
        }
        let authentication = LAContext()
        authentication.localizedFallbackTitle = ""
        handoffAuthenticationContext = authentication
        var error: NSError?
        guard authentication.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            lock(reason: "synthetic biometric authentication unavailable"); return
        }
        syntheticHandoffStatus = "Authenticate to resume the synthetic test. This biometric check does not release Vault keys."
        refresh()
        authentication.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Resume the held synthetic test guest") { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self, self.handoffToken == token,
                      self.handoffAuthenticationContext === authentication else { return }
                self.handoffAuthenticationContext = nil
                authentication.invalidate()
                guard self.heldGuestIsLive() else {
                    self.lock(reason: "synthetic authentication lost hold validity"); return
                }
                let result = self.handoffGate.completeAuthentication(token: token, attempt: attempt,
                    succeeded: success, now: self.handoffClock.now,
                    applicationActive: !self.inactiveTransition && UIApplication.shared.applicationState == .active,
                    backgrounded: UIApplication.shared.applicationState == .background,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
                switch result {
                case .readyToResume:
                    self.syntheticHandoffStatus = "Synthetic authentication accepted. Tap Resume authenticated test to request CONT; the guest remains concealed."
                    self.refresh()
                case .awaitingActivation:
                    self.syntheticHandoffStatus = "Synthetic authentication accepted; waiting for foreground activation with the guest still concealed."
                    self.refresh()
                case .stale: break
                case .failed, .expired, .backgrounded:
                    self.lock(reason: "synthetic authentication cancelled, failed or expired")
                }
            }
        }
    }

    func continueAuthenticatedSyntheticGuest() {
        guard canContinueAuthenticatedGuest else { return }
        resumeAuthenticatedSyntheticGuest()
    }

    private func resumeAuthenticatedSyntheticGuest() {
        guard heldGuestIsLive(), let token = handoffToken,
              handoffGate.prepareContinue(token: token, now: handoffClock.now,
                    foreground: !inactiveTransition && UIApplication.shared.applicationState == .active,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                    guestAttached: guest.viewController.viewIfLoaded?.window != nil),
              heldGuestIsLive(),
              guest.requestVerificationSignal(SIGCONT),
              heldGuestIsLive(),
              handoffGate.continueRequestAccepted(token: token, now: handoffClock.now,
                    foreground: !inactiveTransition && UIApplication.shared.applicationState == .active,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) else {
            lock(reason: "synthetic continuation preconditions or request refused"); return
        }
        cancelSyntheticHandoff()
        holdingSyntheticGuest = false
        locked = false
        syntheticHandoffStatus = "Synthetic CONT request submitted after fresh biometric authentication. Suspension and media stop remain unproved. Next lifecycle departure or Lock revokes the guest normally."
        observe(syntheticHandoffStatus)
        refresh()
        uncoverAfterTransition()
    }

    private func cancelSyntheticHandoff() {
        // Invalidate authority first; late expiry/auth/timer callbacks cannot continue the guest.
        handoffGate.revoke()
        handoffToken = nil
        heldStartupToken = nil
        handoffDeadlineWorkItem?.cancel(); handoffDeadlineWorkItem = nil
        handoffAuthenticationContext?.invalidate(); handoffAuthenticationContext = nil
        let identifier = handoffBackgroundTask
        handoffBackgroundTask = .invalid
        handoffLeaseExpiryFlag = nil
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
    }

    func lock(reason: String = "explicit lock") {
        cover()
        cancelVerificationSignalProbe()
        cancelSyntheticHandoff()
        holdingSyntheticGuest = false
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
        if holdingSyntheticGuest {
            guard heldGuestIsLive() else { lock(reason: "synthetic hold invalid on inactivity"); return }
            refresh()
            return
        }
        // Only the app-owned biometric preparation may survive inactivity.
        // Genuine backgrounding always revokes, including during Face ID.
        if gate.phase != .preparing { lock(reason: "inactive") }
    }
    @objc private func background(_ notification: Notification) {
        inactiveTransition = true
        cover()
        if holdingSyntheticGuest && handoffGate.phase == .holding && heldGuestIsLive() {
            observe("Synthetic hold remains concealed during background allowance; no automatic CONT request.")
            refresh()
            return
        }
        lock(reason: "background or pending synthetic authentication backgrounded")
    }
    @objc private func protectedDataWillBecomeUnavailable(_ notification: Notification) {
        inactiveTransition = true
        lock(reason: "protected-data loss")
    }
    @objc private func active(_ notification: Notification) {
        guard UIApplication.shared.applicationState == .active else { return }
        inactiveTransition = false
        if holdingSyntheticGuest {
            guard heldGuestIsLive() else { lock(reason: "synthetic hold invalid on activation"); return }
            if handoffGate.phase == .awaitingActivation {
                guard let token = handoffToken,
                      handoffGate.activateAfterAuthentication(token: token, now: handoffClock.now,
                        applicationActive: UIApplication.shared.applicationState == .active,
                        backgrounded: UIApplication.shared.applicationState == .background,
                        protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) else {
                    lock(reason: "synthetic pending authentication activation refused"); return
                }
                syntheticHandoffStatus = "Synthetic authentication accepted. Tap Resume authenticated test to request CONT; the guest remains concealed."
                refresh()
            } else { refresh() }
            return
        }
        consumePreparationIfActive()
        uncoverAfterTransition()
    }

    private func cover() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard !covers.contains(where: { $0.windowScene === scene }) else { continue }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 100
            window.backgroundColor = .black
            window.rootViewController = UIHostingController(rootView: CVLPSyntheticHoldCover(model: self))
            window.isHidden = false
            covers.append(window)
        }
        NSLog("CVLP_LIFECYCLE_COVER_INSTALLED")
    }
    private func uncoverAfterTransition() {
        DispatchQueue.main.async { [self] in
            guard !holdingSyntheticGuest, !inactiveTransition, UIApplication.shared.applicationState == .active else { return }
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
            + verificationSignalProbeStatus + "\n\n" + syntheticHandoffStatus + "\n\n" + CVLPProbe.hostSummary()
        NSLog("CVLP_LIFECYCLE_STATUS %@", guest.summary)
    }
}

struct CVLPSyntheticHoldCover: View {
    @ObservedObject var model: CVLPLifecycleModel
    @State private var reportVisible = false
    var body: some View {
        ZStack {
            CVLPCalculatorCover()
            if model.holdingSyntheticGuest && UIApplication.shared.applicationState == .active {
                VStack(spacing: 12) {
                    HStack {
                        Button("Lock") { model.lock() }
                        Spacer()
                        Button("Test report") { model.refresh(); reportVisible = true }
                    }
                    Text(model.syntheticHandoffStatus).font(.footnote)
                    if model.canContinueAuthenticatedGuest {
                        Button("Resume authenticated test") { model.continueAuthenticatedSyntheticGuest() }
                    } else {
                        Button("Authenticate to resume test") { model.authenticateAndResumeSyntheticGuest() }
                            .disabled(!model.canAuthenticateHeldGuest)
                    }
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 80)
                    .foregroundStyle(.white)
            }
        }.sheet(isPresented: $reportVisible) {
            ScrollView { Text(model.report).font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled).padding() }
        }
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
            if model.locked && !model.holdingSyntheticGuest && !reportVisible {
                ZStack(alignment: .topTrailing) {
                    CVLPCalculatorCover()
                    Button("Test report") { reportVisible = true; model.refresh() }.padding(.top, 50).padding(.trailing)
                }
            } else if model.showingGuest && frameworkGuestMode {
                ZStack(alignment: .topLeading) {
                    CVLPGuestSurface(session: model.guest, onReady: model.surfaceReady).ignoresSafeArea()
                        .opacity(model.holdingSyntheticGuest ? 0 : 1)
                        .allowsHitTesting(!model.holdingSyntheticGuest)
                        .accessibilityHidden(model.holdingSyntheticGuest)
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
                        .disabled(model.signalExperimentAttempted || !model.guest.isVerificationSignalProbeAvailable)
                        Button("Hold test guest") { model.holdSyntheticGuest() }
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white).padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color.black.opacity(0.9), in: Capsule())
                            .disabled(model.signalExperimentAttempted || !model.guest.isVerificationSignalProbeAvailable)
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
