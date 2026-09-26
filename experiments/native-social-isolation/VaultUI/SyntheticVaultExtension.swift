import ExtensionFoundation
import ExtensionKit
import SwiftUI

@main
struct SyntheticVaultExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "org.example.syntheticisolation", name: "SyntheticVaultUI")
    }

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(SyntheticVaultScene())
    }
}

private struct SyntheticVaultScene: AppExtensionScene {
    var body: some AppExtensionScene {
        PrimitiveAppExtensionScene(id: "SyntheticVaultScene") {
            SyntheticVaultContent()
        } onConnection: { _ in
            false
        }
    }
}

private struct SyntheticVaultContent: View {
    var body: some View {
        VStack {
            Text("Synthetic vault extension")
            Text("No real data")
        }
        .onAppear {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let markerURL = documentsURL.appendingPathComponent("synthetic-extension.txt")
            do {
                try "Extension scene appeared".write(to: markerURL, atomically: true, encoding: .utf8)
                NSLog("Synthetic extension marker written at %@", markerURL.path)
            } catch {
                NSLog("Synthetic extension marker write failed: %@", String(describing: error))
            }
            let targetPathURL = documentsURL.appendingPathComponent("synthetic-host-target-path.txt")
            let readResult: String
            if let path = try? String(contentsOf: targetPathURL, encoding: .utf8), !path.isEmpty {
                let targetURL = URL(fileURLWithPath: path)
                if let data = try? Data(contentsOf: targetURL),
                   String(data: data, encoding: .utf8) == "Synthetic host sentinel" {
                    readResult = "READABLE"
                } else {
                    readResult = "NOT_READABLE"
                }
            } else {
                readResult = "NO_TARGET"
            }
            let readResultURL = documentsURL.appendingPathComponent("synthetic-extension-read.txt")
            try? readResult.write(to: readResultURL, atomically: true, encoding: .utf8)
            NSLog("Synthetic extension host-file read: %@", readResult)
        }
    }
}
