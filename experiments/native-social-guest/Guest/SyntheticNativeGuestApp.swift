import SwiftUI

@main
struct SyntheticNativeGuestApp: App {
    var body: some Scene {
        WindowGroup {
            SyntheticGuestView()
        }
    }
}

private struct SyntheticGuestView: View {
    @State private var tapCount = 0
    @State private var canaryStatus = "Not checked"
    @State private var hostFileStatus = "Host file not checked"

    var body: some View {
        VStack(spacing: 24) {
            Text("Synthetic native guest")
                .font(.title)
            Text("No account, network, or private media")
                .foregroundStyle(.secondary)
            Text("Taps: \(tapCount)")
                .accessibilityIdentifier("syntheticTapCount")
            Button("Tap native control") {
                tapCount += 1
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("syntheticTapButton")
            Button("Write and read synthetic canary") {
                checkCanary()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("syntheticCanaryButton")
            Text(canaryStatus)
                .accessibilityIdentifier("syntheticCanaryStatus")
            Button("Check synthetic host file") {
                checkHostFile()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("syntheticHostFileButton")
            Text(hostFileStatus)
                .accessibilityIdentifier("syntheticHostFileStatus")
        }
        .padding()
        .accessibilityIdentifier("syntheticNativeGuest")
    }

    private func checkCanary() {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            canaryStatus = "No documents directory"
            return
        }

        let canaryURL = documentsURL.appendingPathComponent("synthetic-guest-canary.txt")
        let expected = "Synthetic guest canary"
        do {
            try expected.write(to: canaryURL, atomically: true, encoding: .utf8)
            let observed = try String(contentsOf: canaryURL, encoding: .utf8)
            canaryStatus = observed == expected ? "Canary round trip passed" : "Canary mismatch"
        } catch {
            canaryStatus = "Canary round trip failed"
        }
    }

    private func checkHostFile() {
        guard let hostHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"] else {
            hostFileStatus = "Host path unavailable"
            return
        }

        let hostFile = URL(fileURLWithPath: hostHome)
            .appendingPathComponent("Library/Application Support/synthetic-host-sentinel.txt")
        do {
            let value = try String(contentsOf: hostFile, encoding: .utf8)
            hostFileStatus = value == "Synthetic host-only sentinel"
                ? "Host file readable by guest"
                : "Host file content mismatch"
        } catch {
            hostFileStatus = "Host file inaccessible to guest"
        }
    }
}
