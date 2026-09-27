struct CVLPHostView: View {
    @State private var report = "Ready to prepare synthetic fixtures."
    @State private var launched = false
    @State private var autoStarted = false
    @State private var preparing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Native LiveProcess probe").font(.title2)
                    Text("This test loads a synthetic native guest in a separate process and checks its access to host test files and keys.")
                    Button("Test migration with Face ID and launch guest", action: launch)
                        .buttonStyle(.borderedProminent)
                        .disabled(launched || preparing)
                    Button("Refresh host report") { report = CVLPProbe.hostSummary() }
                        .buttonStyle(.bordered)
                    Text(report).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Close the guest panel before refreshing the host report. Relaunch the host app for a fresh test.")
                        .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("Synthetic test")
        }
        .onAppear {
#if targetEnvironment(simulator)
            guard !autoStarted, ProcessInfo.processInfo.environment["CVLP_AUTORUN"] == "1" else { return }
            autoStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { launch() }
#endif
        }
    }

    private func launch() {
        guard !launched, !preparing else { return }
        preparing = true
        report = "Preparing disposable migration items. Complete Face ID if prompted."
        DispatchQueue.global(qos: .userInitiated).async {
            let fixture = CVLPKeychainMigrationFixture.prepare()
            DispatchQueue.main.async {
                CVLPProbe.setMigrationFixture(fixture)
                preparing = false
                launchPreparedGuest()
            }
        }
    }

    private func launchPreparedGuest() {
        if let error = CVLPProbe.prepareHost() {
            report = error + "\n\n" + CVLPProbe.hostSummary()
            NSLog("CVLP_HOST_SETUP_INCONCLUSIVE")
            return
        }
        UserDefaults.standard.set("org.example.syntheticnativeguest.app", forKey: "selected")
        UserDefaults.standard.set("synthetic-liveprocess-device", forKey: "selectedContainer")
        UserDefaults.standard.set(false, forKey: "LCSharePrivateDataWithLiveProcess")
        UserDefaults.lcShared().set(0, forKey: "LCMultitaskMode")
        launched = true
        report = CVLPProbe.hostSummary()
        LCUtils.launchMultitaskGuestApp("Synthetic native guest") { pid, error in
            DispatchQueue.main.async {
                if let error {
                    report = "Guest launch failed: \(error.localizedDescription)\n\n" + CVLPProbe.hostSummary()
                    NSLog("CVLP_HOST_LAUNCH_FAILED")
                    launched = false
                } else {
                    report = "Guest process started (PID \(pid?.intValue ?? 0)).\n\n" + CVLPProbe.hostSummary()
                    NSLog("CVLP_HOST_LAUNCHED")
                }
            }
        }
    }
}
