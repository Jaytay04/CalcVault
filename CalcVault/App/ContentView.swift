import SwiftUI
import UniformTypeIdentifiers

enum RecoveryGesturePolicy {
    static let requiredTapCount = 15
    static let hotspotWidth: CGFloat = 112
    static let hotspotHeight: CGFloat = 120
}

struct RecoveryTapAccumulator {
    private(set) var tapCount = 0

    mutating func registerTap() -> Bool {
        tapCount += 1

        guard tapCount == RecoveryGesturePolicy.requiredTapCount else {
            return false
        }

        reset()
        return true
    }

    mutating func reset() {
        tapCount = 0
    }
}

public struct ContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    public init() {}

    public var body: some View {
        switch coordinator.setupState {
        case .loading:
            ProgressView("Checking local configuration")
        case .needsEnrollment:
            EnrollmentView()
        case .unavailable(let message):
            ContentUnavailableView(
                "Configuration unavailable",
                systemImage: "exclamationmark.shield",
                description: Text(message)
            )
        case .ready(let biometricEnabled):
            switch coordinator.lifecycleState {
            case .calculatorLocked:
                CalculatorShellView()
            case .authenticating:
                AuthenticationView(biometricEnabled: biometricEnabled)
            case .privateUnlocked:
                PrivateAreaView()
            case .locking:
                ProgressView("Locking")
            }
        }
    }
}

private struct CalculatorShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var recoveryTaps = RecoveryTapAccumulator()

    var body: some View {
        NavigationStack {
            CalculatorView(model: coordinator.calculator)
        }
        .overlay(alignment: .topTrailing) {
            // Documented owner recovery route. A dedicated overlay is used
            // because transparent toolbar items are not reliable hit targets.
            Button {
                if recoveryTaps.registerTap() {
                    coordinator.requestRecoveryAuthentication()
                }
            } label: {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(
                        width: RecoveryGesturePolicy.hotspotWidth,
                        height: RecoveryGesturePolicy.hotspotHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }
}

private struct EnrollmentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var sequence = ""
    @State private var sequenceConfirmation = ""
    @State private var passphrase = ""
    @State private var passphraseConfirmation = ""
    @State private var enableBiometrics = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("8–12 digit sequence", text: $sequence)
                        .keyboardType(.numberPad)
                    SecureField("Confirm sequence", text: $sequenceConfirmation)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Calculator entry")
                } footer: {
                    Text("The sequence followed by = opens authentication. It is a navigation secret, not an encryption password.")
                }

                Section {
                    SecureField("At least 12 characters", text: $passphrase)
                        .textContentType(.newPassword)
                    SecureField("Confirm passphrase", text: $passphraseConfirmation)
                        .textContentType(.newPassword)
                } header: {
                    Text("Independent vault passphrase")
                } footer: {
                    Text("The passphrase is not trimmed or case-folded. Losing it can make future vault data inaccessible unless a tested backup exists.")
                }

                Section {
                    Toggle("Use Face ID when available", isOn: $enableBiometrics)
                } header: {
                    Text("Convenience")
                } footer: {
                    Text("Face ID protects a device-only root-key copy. The independent passphrase remains the recovery path.")
                }

                if let message = coordinator.enrollmentMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(coordinator.isEnrollmentBusy ? "Configuring…" : "Configure CalcVault") {
                        let submittedSequence = sequence
                        let submittedSequenceConfirmation = sequenceConfirmation
                        let submittedPassphrase = passphrase
                        let submittedPassphraseConfirmation = passphraseConfirmation
                        sequence = ""
                        sequenceConfirmation = ""
                        passphrase = ""
                        passphraseConfirmation = ""
                        coordinator.enroll(
                            navigationSequence: submittedSequence,
                            sequenceConfirmation: submittedSequenceConfirmation,
                            passphrase: submittedPassphrase,
                            passphraseConfirmation: submittedPassphraseConfirmation,
                            enableBiometrics: enableBiometrics
                        )
                    }
                    .disabled(coordinator.isEnrollmentBusy)
                }
            }
            .navigationTitle("Set up CalcVault")
        }
    }
}

private struct AuthenticationView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let biometricEnabled: Bool
    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Vault passphrase") {
                    SecureField("Independent passphrase", text: $passphrase)
                        .textContentType(.password)
                        .onSubmit(submitPassphrase)
                    Button("Unlock with passphrase", action: submitPassphrase)
                        .disabled(coordinator.isAuthenticationBusy || passphrase.isEmpty)
                }

                if biometricEnabled {
                    Section("Convenience") {
                        Button("Unlock with Face ID") {
                            coordinator.authenticateWithBiometrics()
                        }
                        .disabled(coordinator.isAuthenticationBusy)
                    }
                }

                if coordinator.isAuthenticationBusy {
                    Section { ProgressView("Authenticating") }
                }
                if let message = coordinator.authenticationMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Private access")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { coordinator.cancelAuthentication() }
                }
            }
        }
    }

    private func submitPassphrase() {
        let submitted = passphrase
        passphrase = ""
        coordinator.authenticate(passphrase: submitted)
    }
}

private struct PrivateAreaView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selectedArea: PrivateArea = .files
    @State private var selectedService: SocialService = .tikTok
    @State private var showsEntryChange = false
    @State private var socialDownloadRequest: SocialDownloadRequest?

    private enum PrivateArea {
        case files
        case social
        case security
    }

    var body: some View {
        ZStack {
            NavigationStack {
                PrototypeToolsView()
                    .toolbar { privateToolbar }
            }
            .opacity(selectedArea == .files ? 1 : 0)
            .allowsHitTesting(selectedArea == .files)
            .accessibilityHidden(selectedArea != .files)

            NavigationStack {
                SocialWorkspaceView(
                    selectedService: $selectedService,
                    isWorkspaceActive: selectedArea == .social,
                    requestDownload: { service, pageURL in
                        socialDownloadRequest = SocialDownloadRequest(service: service, pageURL: pageURL)
                    }
                )
                .toolbar { privateToolbar }
                .sheet(item: $socialDownloadRequest) { request in
                    SocialDownloadView(request: request)
                        .environmentObject(coordinator)
                }
            }
            .opacity(selectedArea == .social ? 1 : 0)
            .allowsHitTesting(selectedArea == .social)
            .accessibilityHidden(selectedArea != .social)

            NavigationStack {
                List {
                    Section("Session") {
                        Text("Private access is active. Backgrounding or locking returns to a clean calculator.")
                        Button("Lock now", action: coordinator.lock)
                    }
                    Section("Calculator entry") {
                        Button("Change entry sequence") { showsEntryChange = true }
                        Text("The sequence only opens vault authentication; it does not unlock the vault.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Phase 2") {
                        Text("Authentication is active. Encrypted storage status appears in Files.")
                    }
                    Section("Credential storage") {
                        Text("Host-only Keychain migration is enabled. Existing biometric credentials migrate during Face ID unlock.")
                        Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
                            .foregroundStyle(.secondary)
                    }
                    if Bundle.main.object(forInfoDictionaryKey: "CVNativeIntegrationStage") as? String == "credential-preflight-21" {
                        NativeGuestPreflightSection(model: coordinator.nativeGuestPreflight)
                    }
                    if coordinator.nativeGuestAvailable {
                        NativeGuestIntegrationSection(model: coordinator.nativeGuest,
                                                      start: coordinator.startNativeGuest)
                    }
                }
                .navigationTitle("Security")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { privateToolbar }
                .sheet(isPresented: $showsEntryChange) {
                    ChangeEntrySequenceView()
                        .environmentObject(coordinator)
                }
            }
            .opacity(selectedArea == .security ? 1 : 0)
            .allowsHitTesting(selectedArea == .security)
            .accessibilityHidden(selectedArea != .security)
        }
    }

    @ToolbarContentBuilder
    private var privateToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Files", systemImage: "archivebox") { selectedArea = .files }
                Section("Social") {
                    ForEach(SocialService.allCases) { service in
                        Button(service.displayName) {
                            selectedService = service
                            selectedArea = .social
                        }
                    }
                }
                Button("Security", systemImage: "lock.shield") { selectedArea = .security }
            } label: {
                Label("Navigate", systemImage: "line.3.horizontal")
            }
            .accessibilityLabel("Navigate private area")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Lock", action: coordinator.lock)
        }
    }
}

private struct ChangeEntrySequenceView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassphrase = ""
    @State private var newSequence = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Fresh authentication") {
                    SecureField("Current vault passphrase", text: $currentPassphrase)
                        .textContentType(.password)
                }
                Section {
                    SecureField("New calculator sequence", text: $newSequence)
                        .keyboardType(.numberPad)
                    SecureField("Confirm new sequence", text: $confirmation)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Calculator entry")
                } footer: {
                    Text("Use 8–12 digits normally. A one-digit sequence is for temporary testing and may trigger authentication during ordinary calculations. The vault still requires its passphrase or Face ID.")
                }
                if let message = coordinator.navigationChangeMessage {
                    Section { Text(message) }
                }
                Section {
                    Button("Change sequence") {
                        let submittedPassphrase = currentPassphrase
                        let submittedSequence = newSequence
                        let submittedConfirmation = confirmation
                        currentPassphrase = ""
                        newSequence = ""
                        confirmation = ""
                        coordinator.changeNavigationSequence(
                            currentPassphrase: submittedPassphrase,
                            newSequence: submittedSequence,
                            confirmation: submittedConfirmation
                        )
                    }
                    .disabled(coordinator.isNavigationChangeBusy || currentPassphrase.isEmpty || newSequence.isEmpty)
                    if coordinator.isNavigationChangeBusy {
                        ProgressView("Verifying")
                    }
                }
            }
            .navigationTitle("Change entry sequence")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(coordinator.isNavigationChangeBusy)
                }
            }
            .interactiveDismissDisabled(coordinator.isNavigationChangeBusy)
        }
    }
}

private struct PrototypeToolsView: View {
    var body: some View {
        VaultWorkspaceRootView()
    }
}

@available(iOS 17.0, *)
struct Phase0DiagnosticsView: View {
    @State private var cryptoResult: DummyCryptoExerciseResult?
    @State private var keychainResult: KeychainProbeResult?
    @State private var cryptoError: String?

    var body: some View {
        List {
            Section {
                Button("Run dummy authenticated encryption") {
                    do {
                        cryptoResult = try VaultKeyManager().runDummyExercise()
                        cryptoError = nil
                    } catch {
                        cryptoResult = nil
                        cryptoError = String(describing: error)
                    }
                }

                if let cryptoResult {
                    LabeledContent("Round trip", value: cryptoResult.roundTripSucceeded ? "Passed" : "Failed")
                    LabeledContent(
                        "Tamper rejection",
                        value: cryptoResult.tamperedCiphertextRejected ? "Passed" : "Failed"
                    )
                    LabeledContent("Ciphertext bytes", value: "\(cryptoResult.ciphertext.count)")
                }

                if let cryptoError {
                    Text(cryptoError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("libsodium SecretBox")
            } footer: {
                Text("The key and plaintext are disposable fixtures and are not persisted.")
            }

            Section {
                Button("Run disposable Keychain probe") {
                    keychainResult = KeychainProbe().run()
                }

                if let keychainResult {
                    LabeledContent("Item added", value: keychainResult.itemAdded ? "Yes" : "No")
                    LabeledContent("Protected read", value: keychainResult.protectedReadMatched ? "Matched" : "Failed")
                    LabeledContent("Cleanup", value: keychainResult.cleanupCompleted ? "Completed" : "Failed")
                    LabeledContent("Overall", value: keychainResult.succeeded ? "Passed" : "Not verified")
                }
            } header: {
                Text("Keychain access policy")
            } footer: {
                Text("Uses a unique dummy fixture with WhenPasscodeSetThisDeviceOnly and the current biometric set. A simulator or device without a passcode may fail this probe.")
            }
        }
        .navigationTitle("Diagnostics")
    }
}

@available(iOS 17.0, *)
struct LocalArchivePrototypeView: View {
    @State private var archiveSource = LocalArchiveSource()
    @State private var showingImporter = false
    @State private var status = "No external archive selected."
    @State private var entries: [TAREntry] = []

    var body: some View {
        List {
            Section {
                Button("Choose TAR archive") {
                    showingImporter = true
                }

                Button("Read selected archive") {
                    do {
                        entries = try archiveSource.listCurrentArchive()
                        status = "Read-only listing succeeded: \(entries.count) entr\(entries.count == 1 ? "y" : "ies")."
                    } catch {
                        entries = []
                        status = error.localizedDescription
                    }
                }

                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Independent local archive")
            } footer: {
                Text("The selected archive is authoritative. Missing or unreadable data is reported; the app never creates an empty replacement. Plain TAR is packaging/concealment, not encryption.")
            }

            if !entries.isEmpty {
                Section("Read-only entries") {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.path)
                            Text("\(entry.kind.rawValue) · \(entry.size) bytes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Local archive")
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try archiveSource.selectArchive(at: url)
                    entries = []
                    status = "Archive selected: \(url.lastPathComponent)"
                } catch {
                    entries = []
                    status = error.localizedDescription
                }
            case .failure(let error):
                entries = []
                status = error.localizedDescription
            }
        }
    }
}
