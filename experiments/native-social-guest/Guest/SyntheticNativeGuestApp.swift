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

    var body: some View {
        VStack(spacing: 24) {
            Text("Synthetic native guest")
                .font(.title)
            Text("No account, network, or private media")
                .foregroundStyle(.secondary)
            Text("Taps: \(tapCount)")
            Button("Tap native control") {
                tapCount += 1
            }
            .buttonStyle(.borderedProminent)
            Button("Write and read synthetic canary") {
                checkCanary()
            }
            .buttonStyle(.bordered)
            Text(canaryStatus)
                .accessibilityIdentifier("syntheticCanaryStatus")
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
}
