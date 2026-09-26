import ExtensionFoundation
import ExtensionKit
import SwiftUI

extension AppExtensionPoint {
    @Definition
    static var syntheticVaultUI: AppExtensionPoint {
            Name("SyntheticVaultUI")
            UserInterface(true)
            #if ENHANCED_SECURITY
            EnhancedSecurity(true)
            #endif
    }
}

@main
struct SyntheticHostApp: App {
    var body: some Scene {
        WindowGroup {
            SyntheticHostView()
        }
    }
}

private struct SyntheticHostView: View {
    @State private var identity: AppExtensionIdentity?
    @State private var status = "Looking for isolated UI"

    var body: some View {
        VStack(spacing: 20) {
            Text("Synthetic host")
            Text(status)
            if let identity {
                SyntheticExtensionView(identity: identity)
                    .frame(maxWidth: .infinity, maxHeight: 300)
            }
        }
        .padding()
        .task {
            do {
                let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .syntheticVaultUI)
                identity = monitor.identities.first
                status = identity == nil ? "Extension not approved or unavailable" : "Extension discovered"
            } catch {
                status = "Extension discovery failed"
            }
            let statusURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("synthetic-discovery.txt")
            try? status.write(to: statusURL, atomically: true, encoding: .utf8)
            await probeExtensionFileAccess()
        }
    }

    private func probeExtensionFileAccess() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetPathURL = documentsURL.appendingPathComponent("synthetic-target-path.txt")
        let resultURL = documentsURL.appendingPathComponent("synthetic-host-read.txt")
        for _ in 0..<60 {
            if let path = try? String(contentsOf: targetPathURL, encoding: .utf8), !path.isEmpty {
                let targetURL = URL(fileURLWithPath: path)
                let result: String
                if let data = try? Data(contentsOf: targetURL),
                   String(data: data, encoding: .utf8) == "Extension scene appeared" {
                    result = "READABLE"
                } else {
                    result = "NOT_READABLE"
                }
                try? result.write(to: resultURL, atomically: true, encoding: .utf8)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? "NO_TARGET".write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct SyntheticExtensionView: UIViewControllerRepresentable {
    let identity: AppExtensionIdentity

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.delegate = context.coordinator
        controller.configuration = .init(appExtension: identity, sceneID: "SyntheticVaultScene")
        return controller
    }

    func updateUIViewController(_ controller: EXHostViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            writeStatus("Extension host view activated")
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) {
            writeStatus("Extension host view deactivated")
        }

        private func writeStatus(_ status: String) {
            NSLog("Synthetic host view status: %@", status)
            let statusURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("synthetic-activation.txt")
            try? status.write(to: statusURL, atomically: true, encoding: .utf8)
        }
    }
}
