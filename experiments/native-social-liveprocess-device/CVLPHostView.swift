import LocalAuthentication

@MainActor
final class CVLPLifecycleModel: NSObject, ObservableObject {
    @Published var report = "Build 18. Ready for a disposable lifecycle test."
    @Published var showingGuest = false
    @Published var locked = false
    @Published var attempted = false
    let guest = CVLPGuestSession()
    private var gate = CVLPLifecycleGate()
    private var context: LAContext?
    private var pending: (UInt64, [String: Any], Bool)?
    private var covers: [UIWindow] = []
    private var observations: [String] = []
    private var inactiveTransition = false
    private var surfaceToken: UInt64?

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
        showingGuest = true
    }

    func surfaceReady() {
        guard let token = surfaceToken else { return }
        surfaceToken = nil
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

    func lock(reason: String = "explicit lock") {
        cover()
        gate.revoke()
        pending = nil
        surfaceToken = nil
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
        report = "Build 18 lifecycle observations (not a security certification)\n\n"
            + observations.joined(separator: "\n") + "\n\n" + guest.summary + "\n\n" + CVLPProbe.hostSummary()
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
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
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
    var body: some View {
        Group {
            if model.locked && !reportVisible {
                ZStack(alignment: .topTrailing) {
                    CVLPCalculatorCover()
                    Button("Test report") { reportVisible = true; model.refresh() }.padding(.top, 50).padding(.trailing)
                }
            } else {
                VStack {
                    HStack {
                        Text("Native lifecycle test · 18").font(.headline)
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
