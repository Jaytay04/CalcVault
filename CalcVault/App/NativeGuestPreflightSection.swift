import SwiftUI

/// Available only in the explicitly selected integration-preflight artifact.
struct NativeGuestPreflightSection: View {
    @ObservedObject var model: NativeGuestPreflightModel

    var body: some View {
        Section("Native integration preflight") {
            Text("This build checks legacy credential storage. Native TikTok is not enabled in this candidate.")
            Button(model.state == .checking ? "Checking credentials…" : "Check legacy credential storage") {
                _ = model.check()
            }
            .disabled(model.state == .checking)
            Text(statusText)
                .foregroundStyle(model.state == .blocked ? Color.red : Color.secondary)
            Text("The check does not read credential values or migrate or delete credentials. It does not certify isolation or authorize a guest launch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch model.state {
        case .notChecked:
            return "Not checked in this private session."
        case .checking:
            return "Checking known legacy locations without requesting biometric access."
        case .noLegacyCopiesObserved:
            return "No legacy copies found for the known credential inventory at the time of this check."
        case .blocked:
            return "Check blocked: a legacy credential remains or its absence could not be verified. Existing credentials were not changed. If an old biometric copy remains, unlock through Face ID and retry; do not delete your configuration."
        }
    }
}
