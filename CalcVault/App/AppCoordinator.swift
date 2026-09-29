import Combine
import Foundation
import LocalAuthentication
import UIKit
import UniformTypeIdentifiers

public enum AppSetupState: Equatable {
    case loading
    case needsEnrollment
    case ready(biometricEnabled: Bool)
    case unavailable(message: String)
}

public enum VaultStorageUIState: Equatable {
    case locked
    case checking
    case notInitialized
    case ready(itemCount: Int, generation: UInt64)
    case unavailable(message: String)
}

public struct VaultOperationProgress: Equatable, Sendable {
    public let label: String
    public let completedBytes: UInt64
    public let totalBytes: UInt64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public struct VaultImportRequest: Sendable {
    public let sourceURL: URL
    public let displayName: String
    public let kind: VaultItemKind
    public let mediaType: String?

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
        displayName = sourceURL.lastPathComponent.isEmpty ? "Imported file" : sourceURL.lastPathComponent
        let type = UTType(filenameExtension: sourceURL.pathExtension)
        if type?.conforms(to: .image) == true {
            kind = .photo
        } else if type?.conforms(to: .movie) == true {
            kind = .video
        } else {
            kind = .file
        }
        mediaType = type?.preferredMIMEType
    }

    public init(
        sourceURL: URL,
        displayName: String,
        kind: VaultItemKind,
        mediaType: String?
    ) {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.kind = kind
        self.mediaType = mediaType
    }
}

public enum VaultPreviewContent: Sendable {
    case text(String)
    case image(Data)
    case pdf(Data)
    case videoFile(URL)
}

public struct VaultPreviewPayload: Identifiable, Sendable {
    public let item: VaultManifestItem
    public let content: VaultPreviewContent
    public var id: UUID { item.id }
}

public struct VaultNoteDraft: Identifiable, Sendable {
    public let item: VaultManifestItem
    public let body: String
    public var id: UUID { item.id }
}

public struct VaultExportPayload: Identifiable, Sendable {
    public let item: VaultManifestItem
    public let fileURL: URL
    public var id: UUID { item.id }
}

/// Owns enrollment, authentication attempts, and the revocable Phase 2 session.
/// Private UI receives only lifecycle state; root key bytes remain here for the
/// future Phase 3 storage boundary.
@MainActor
public final class AppCoordinator: ObservableObject {
    public let lifecycle: SessionLifecycleCoordinator
    public let calculator: CalculatorViewModel
    private let nativeRuntimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?
    public var nativeGuestAvailable: Bool { nativeRuntimeFactory != nil }
    public lazy var nativeGuest = NativeGuestCoordinator(
        lifecycle: lifecycle,
        check: { biometricEnabled in
            try await Task.detached(priority: .userInitiated) {
                try NativeGuestCredentialInventory.checkForLaunch(biometricEnabled: biometricEnabled)
            }.value
        },
        runtimeFactory: nativeRuntimeFactory
    )

    public func startNativeGuest() {
        guard case .ready(let biometricEnabled) = setupState else { return }
        nativeGuest.start(biometricEnabled: biometricEnabled)
    }

    /// Diagnostic only. No guest launch capability is granted by this model.
    public lazy var nativeGuestPreflight = NativeGuestPreflightModel(lifecycle: lifecycle) {
        try await Task.detached(priority: .userInitiated) {
            try NativeGuestCredentialInventory.checkLegacyAbsence()
        }.value
    }

    @Published public private(set) var lifecycleState: LifecycleState = .calculatorLocked
    @Published public private(set) var setupState: AppSetupState = .loading
    @Published public private(set) var authenticationMessage: String?
    @Published public private(set) var enrollmentMessage: String?
    @Published public private(set) var isAuthenticationBusy = false
    @Published public private(set) var isEnrollmentBusy = false
    @Published public private(set) var navigationChangeMessage: String?
    @Published public private(set) var isNavigationChangeBusy = false
    @Published public private(set) var vaultStorageState: VaultStorageUIState = .locked
    @Published public private(set) var isVaultStorageBusy = false
    @Published public private(set) var vaultItems: [VaultManifestItem] = []
    @Published public private(set) var vaultOperationProgress: VaultOperationProgress?
    @Published public private(set) var vaultOperationMessage: String?
    @Published public private(set) var vaultPreview: VaultPreviewPayload?
    @Published public private(set) var vaultNoteDraft: VaultNoteDraft?
    @Published public private(set) var vaultExport: VaultExportPayload?
    @Published public private(set) var strictDiskPreviewMode = true

    private let credentials: Phase2CredentialManager
    private let rateLimiter: AuthenticationRateLimiter
    private let vaultSessionAuthority: VaultSessionAuthority
    private let vaultRepository: VaultRepository?
    private let vaultRepositoryFailure: String?
    private let vaultTemporaryFiles: VaultTemporaryFileManager?
    private let vaultFileStager: VaultFileStager?
    private var sessionRootKey: Data?
    private var pendingAuthentication: (attemptID: UUID, rootKey: Data)?
    private var activeVaultAccess: (permit: VaultSessionPermit, vaultID: UUID)?
    private var vaultOperationCancellation: VaultOperationCancellation?
    private var vaultOperationTask: Task<Void, Never>?

    public init(
        lifecycle: SessionLifecycleCoordinator = SessionLifecycleCoordinator(),
        calculator: CalculatorViewModel = CalculatorViewModel(),
        credentials: Phase2CredentialManager = Phase2CredentialManager(),
        rateLimiter: AuthenticationRateLimiter = AuthenticationRateLimiter(),
        nativeRuntimeFactory: (@MainActor () throws -> any NativeGuestRuntime)? = nil
    ) {
        self.lifecycle = lifecycle
        self.calculator = calculator
        self.credentials = credentials
        self.rateLimiter = rateLimiter
        self.nativeRuntimeFactory = nativeRuntimeFactory
        let vaultSessionAuthority = VaultSessionAuthority()
        self.vaultSessionAuthority = vaultSessionAuthority
        do {
            let temporaryFiles = try VaultTemporaryFileRegistry.shared()
            self.vaultRepository = VaultRepository(
                rootDirectory: try VaultRepository.defaultRootDirectory(),
                sessionValidator: { [vaultSessionAuthority] permit in
                    vaultSessionAuthority.validate(permit)
                }
            )
            self.vaultTemporaryFiles = temporaryFiles
            self.vaultFileStager = VaultFileStager(temporaryFiles: temporaryFiles)
            self.vaultRepositoryFailure = nil
        } catch {
            self.vaultRepository = nil
            self.vaultTemporaryFiles = nil
            self.vaultFileStager = nil
            self.vaultRepositoryFailure = error.localizedDescription
        }
        lifecycleState = lifecycle.state
        reloadSetupState()
    }

    public func initializeEncryptedVault() {
        guard !isVaultStorageBusy,
              case .notInitialized = vaultStorageState,
              let repository = vaultRepository,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        isVaultStorageBusy = true
        vaultStorageState = .checking
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            do {
                let manifest = try await repository.initialize(
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit,
                    nowMilliseconds: now
                )
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                isVaultStorageBusy = false
                vaultStorageState = .ready(
                    itemCount: manifest.items.count,
                    generation: manifest.generation
                )
                vaultItems = manifest.items
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                isVaultStorageBusy = false
                vaultStorageState = .unavailable(message: error.localizedDescription)
            }
        }
    }

    public func refreshVaultItems() {
        guard !isVaultStorageBusy,
              let repository = vaultRepository,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            do {
                let manifest = try await repository.loadManifest(
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit
                )
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                applyLoadedManifest(manifest)
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                isVaultStorageBusy = false
                vaultOperationMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func importFiles(_ requests: [VaultImportRequest], parentID: UUID?) -> Bool {
        guard !requests.isEmpty else { return false }
        guard !isVaultStorageBusy,
              let repository = vaultRepository,
              let stager = vaultFileStager,
              let temporaryFiles = vaultTemporaryFiles,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else {
            discardStagedImports(requests)
            return false
        }
        let cancellation = VaultOperationCancellation()
        vaultOperationCancellation = cancellation
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        let task = Task { [weak self] in
            var operationKey = rootKey
            defer {
                operationKey.resetBytes(in: operationKey.indices)
                for request in requests where temporaryFiles.owns(request.sourceURL) {
                    temporaryFiles.remove(request.sourceURL)
                }
            }
            do {
                for request in requests {
                    guard !cancellation.isCancelled() else {
                        throw VaultFormatError.operationCancelled
                    }
                    let stageProgress: EncryptedStream.ProgressHandler = { [weak self] completed, total in
                        Task { @MainActor in
                            guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                            self.vaultOperationProgress = VaultOperationProgress(
                                label: "Staging \(request.displayName)",
                                completedBytes: completed,
                                totalBytes: total
                            )
                        }
                    }
                    let staged: URL
                    if temporaryFiles.owns(request.sourceURL) {
                        staged = request.sourceURL
                    } else {
                        staged = try await Task.detached(priority: .userInitiated) {
                            try stager.stage(
                                sourceURL: request.sourceURL,
                                preferredExtension: request.sourceURL.pathExtension,
                                progress: stageProgress,
                                cancellation: cancellation
                            )
                        }.value
                    }
                    do {
                        _ = try await repository.commitObject(
                            sourceURL: staged,
                            displayName: request.displayName,
                            kind: request.kind,
                            mediaType: request.mediaType,
                            parentID: parentID,
                            rootKey: operationKey,
                            vaultID: access.vaultID,
                            permit: access.permit,
                            nowMilliseconds: Self.nowMilliseconds(),
                            progress: { [weak self] completed, total in
                                Task { @MainActor in
                                    guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                                    self.vaultOperationProgress = VaultOperationProgress(
                                        label: "Encrypting \(request.displayName)",
                                        completedBytes: completed,
                                        totalBytes: total
                                    )
                                }
                            },
                            cancellation: cancellation
                        )
                        temporaryFiles.remove(staged)
                    } catch {
                        temporaryFiles.remove(staged)
                        throw error
                    }
                }
                let manifest = try await repository.loadManifest(
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit
                )
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                applyLoadedManifest(manifest)
                vaultOperationMessage = "Import completed. Source originals were preserved."
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                finishVaultOperation(error: error)
            }
        }
        vaultOperationTask = task
        return true
    }

    public func cancelVaultOperation() {
        vaultOperationCancellation?.cancel()
        vaultOperationTask?.cancel()
    }

    public func reportVaultPickerError(_ error: Error) {
        vaultOperationMessage = error.localizedDescription
    }

    public func discardStagedImports(_ requests: [VaultImportRequest]) {
        guard let temporaryFiles = vaultTemporaryFiles else { return }
        for request in requests where temporaryFiles.owns(request.sourceURL) {
            temporaryFiles.remove(request.sourceURL)
        }
    }

    public func createVaultFolder(name: String, parentID: UUID?) {
        runVaultMutation(successMessage: "Folder created.") { repository, key, access, now, _ in
            _ = try await repository.createFolder(
                displayName: name,
                parentID: parentID,
                rootKey: key,
                vaultID: access.vaultID,
                permit: access.permit,
                nowMilliseconds: now
            )
        }
    }

    public func saveVaultNote(
        itemID: UUID?,
        title: String,
        body: String,
        parentID: UUID?
    ) {
        runVaultMutation(successMessage: itemID == nil ? "Note created." : "Note updated.") {
            repository, key, access, now, cancellation in
            if let itemID {
                _ = try await repository.updateNote(
                    itemID: itemID,
                    title: title,
                    body: body,
                    rootKey: key,
                    vaultID: access.vaultID,
                    permit: access.permit,
                    nowMilliseconds: now,
                    cancellation: cancellation
                )
            } else {
                _ = try await repository.createNote(
                    title: title,
                    body: body,
                    parentID: parentID,
                    rootKey: key,
                    vaultID: access.vaultID,
                    permit: access.permit,
                    nowMilliseconds: now,
                    cancellation: cancellation
                )
            }
        }
    }

    public func renameVaultItem(_ itemID: UUID, to displayName: String) {
        runVaultMutation(successMessage: "Item renamed.") { repository, key, access, now, _ in
            _ = try await repository.renameItem(
                itemID: itemID,
                displayName: displayName,
                rootKey: key,
                vaultID: access.vaultID,
                permit: access.permit,
                nowMilliseconds: now
            )
        }
    }

    public func moveVaultItem(_ itemID: UUID, to parentID: UUID?) {
        runVaultMutation(successMessage: "Item moved.") { repository, key, access, now, _ in
            _ = try await repository.moveItem(
                itemID: itemID,
                destinationParentID: parentID,
                rootKey: key,
                vaultID: access.vaultID,
                permit: access.permit,
                nowMilliseconds: now
            )
        }
    }

    public func deleteVaultItem(_ itemID: UUID) {
        runVaultMutation(successMessage: "Item removed from the vault.") { repository, key, access, now, _ in
            try await repository.deleteItem(
                itemID: itemID,
                rootKey: key,
                vaultID: access.vaultID,
                permit: access.permit,
                nowMilliseconds: now
            )
        }
    }

    public func setStrictDiskPreviewMode(_ enabled: Bool) {
        strictDiskPreviewMode = enabled
        if enabled, let preview = vaultPreview, case .videoFile = preview.content {
            dismissVaultPreview()
        }
    }

    public func previewVaultItem(_ item: VaultManifestItem) {
        guard !isVaultStorageBusy,
              item.kind != .folder,
              let repository = vaultRepository,
              let temporaryFiles = vaultTemporaryFiles,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        let cancellation = VaultOperationCancellation()
        vaultOperationCancellation = cancellation
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        let task = Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            do {
                let contentType = Self.contentType(for: item)
                let content: VaultPreviewContent
                if item.kind == .note || contentType?.conforms(to: .plainText) == true {
                    let data = try await repository.readItemData(
                        itemID: item.id,
                        maximumBytes: VaultFormatV1.textPreviewLimit,
                        rootKey: operationKey,
                        vaultID: access.vaultID,
                        permit: access.permit,
                        cancellation: cancellation
                    )
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw VaultFormatError.unsupportedPreview
                    }
                    content = .text(text)
                } else if item.kind == .photo || contentType?.conforms(to: .image) == true {
                    let data = try await repository.readItemData(
                        itemID: item.id,
                        maximumBytes: VaultFormatV1.imagePreviewLimit,
                        rootKey: operationKey,
                        vaultID: access.vaultID,
                        permit: access.permit,
                        cancellation: cancellation
                    )
                    content = .image(data)
                } else if contentType?.conforms(to: .pdf) == true {
                    let data = try await repository.readItemData(
                        itemID: item.id,
                        maximumBytes: VaultFormatV1.pdfPreviewLimit,
                        rootKey: operationKey,
                        vaultID: access.vaultID,
                        permit: access.permit,
                        cancellation: cancellation
                    )
                    content = .pdf(data)
                } else if item.kind == .video || contentType?.conforms(to: .movie) == true {
                    guard self?.strictDiskPreviewMode == false else {
                        throw VaultFormatError.unsupportedPreview
                    }
                    let destination = try temporaryFiles.makeDestination(
                        preferredExtension: Self.preferredExtension(for: item)
                    )
                    do {
                        try await repository.decryptItem(
                            itemID: item.id,
                            destinationURL: destination,
                            rootKey: operationKey,
                            vaultID: access.vaultID,
                            permit: access.permit,
                            cancellation: cancellation
                        )
                        try temporaryFiles.finalizeFile(at: destination)
                        content = .videoFile(destination)
                    } catch {
                        temporaryFiles.remove(destination)
                        throw error
                    }
                } else {
                    throw VaultFormatError.unsupportedPreview
                }
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                vaultPreview = VaultPreviewPayload(item: item, content: content)
                isVaultStorageBusy = false
                vaultOperationCancellation = nil
                vaultOperationTask = nil
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                finishVaultOperation(error: error)
            }
        }
        vaultOperationTask = task
    }

    public func dismissVaultPreview() {
        if case .videoFile(let url) = vaultPreview?.content {
            vaultTemporaryFiles?.remove(url)
        }
        vaultPreview = nil
    }

    public func prepareVaultNoteEditor(_ item: VaultManifestItem) {
        guard !isVaultStorageBusy,
              item.kind == .note,
              let repository = vaultRepository,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        let cancellation = VaultOperationCancellation()
        vaultOperationCancellation = cancellation
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        vaultNoteDraft = nil
        let task = Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            do {
                let data = try await repository.readItemData(
                    itemID: item.id,
                    maximumBytes: VaultFormatV1.textPreviewLimit,
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit,
                    cancellation: cancellation
                )
                guard let body = String(data: data, encoding: .utf8) else {
                    throw VaultFormatError.unsupportedPreview
                }
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                vaultNoteDraft = VaultNoteDraft(item: item, body: body)
                isVaultStorageBusy = false
                vaultOperationCancellation = nil
                vaultOperationTask = nil
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                finishVaultOperation(error: error)
            }
        }
        vaultOperationTask = task
    }

    public func dismissVaultNoteDraft() {
        vaultNoteDraft = nil
    }

    public func prepareVaultExport(_ item: VaultManifestItem) {
        guard !isVaultStorageBusy,
              item.kind != .folder,
              let repository = vaultRepository,
              let temporaryFiles = vaultTemporaryFiles,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        let cancellation = VaultOperationCancellation()
        vaultOperationCancellation = cancellation
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        let task = Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            let destination: URL
            do {
                destination = try temporaryFiles.makeDestination(
                    preferredExtension: Self.preferredExtension(for: item)
                )
            } catch {
                guard let self else { return }
                finishVaultOperation(error: error)
                return
            }
            do {
                try await repository.decryptItem(
                    itemID: item.id,
                    destinationURL: destination,
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit,
                    progress: { [weak self] completed, total in
                        Task { @MainActor in
                            guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                            self.vaultOperationProgress = VaultOperationProgress(
                                label: "Preparing explicit plaintext export",
                                completedBytes: completed,
                                totalBytes: total
                            )
                        }
                    },
                    cancellation: cancellation
                )
                try temporaryFiles.finalizeFile(at: destination)
                guard let self, self.activeVaultAccess?.permit == access.permit else {
                    temporaryFiles.remove(destination)
                    return
                }
                vaultExport = VaultExportPayload(item: item, fileURL: destination)
                isVaultStorageBusy = false
                vaultOperationProgress = nil
                vaultOperationCancellation = nil
                vaultOperationTask = nil
            } catch {
                temporaryFiles.remove(destination)
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                finishVaultOperation(error: error)
            }
        }
        vaultOperationTask = task
    }

    public func finishVaultExport() {
        if let url = vaultExport?.fileURL {
            vaultTemporaryFiles?.remove(url)
        }
        vaultExport = nil
    }

    public func enroll(
        navigationSequence: String,
        sequenceConfirmation: String,
        passphrase: String,
        passphraseConfirmation: String,
        enableBiometrics: Bool
    ) {
        guard !isEnrollmentBusy else { return }
        guard navigationSequence == sequenceConfirmation else {
            enrollmentMessage = "The calculator entry sequences do not match."
            return
        }
        guard passphrase == passphraseConfirmation else {
            enrollmentMessage = "The vault passphrases do not match."
            return
        }

        isEnrollmentBusy = true
        enrollmentMessage = nil
        let credentials = credentials
        Task { [weak self] in
            let failureMessage = await Task.detached { () -> String? in
                do {
                    try credentials.enroll(
                        navigationSequence: navigationSequence,
                        passphrase: passphrase,
                        enableBiometrics: enableBiometrics
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            isEnrollmentBusy = false
            if let failureMessage {
                enrollmentMessage = failureMessage
                reloadSetupState(preserveEnrollmentError: true)
            } else {
                reloadSetupState()
                calculator.prepareFreshSecretEntry()
            }
        }
    }

    public func requestAuthentication() {
        guard case .ready = setupState,
              lifecycle.state == .calculatorLocked else { return }
        authenticationMessage = nil
        _ = lifecycle.beginAuthentication()
        lifecycle.setAuthenticationPromptActive(false)
        synchronizeLifecycleState()
    }

    public func requestRecoveryAuthentication() {
        calculator.prepareFreshSecretEntry()
        requestAuthentication()
    }

    public func changeNavigationSequence(
        currentPassphrase: String,
        newSequence: String,
        confirmation: String
    ) {
        guard !isNavigationChangeBusy,
              case .privateUnlocked(let sessionID) = lifecycle.state,
              sessionRootKey != nil else { return }
        guard newSequence == confirmation else {
            navigationChangeMessage = "The new sequences do not match."
            return
        }
        guard (try? SecretEntryConfiguration(sequence: newSequence)) != nil else {
            navigationChangeMessage = Phase2CredentialError.invalidReplacementNavigationSequence.localizedDescription
            return
        }
        if let retryAfter = rateLimiter.retryAfter() {
            navigationChangeMessage = "Try again in \(max(1, Int(retryAfter.rounded(.up)))) seconds."
            return
        }

        navigationChangeMessage = nil
        isNavigationChangeBusy = true
        let generation = lifecycle.sessionGeneration
        let credentials = credentials
        Task { [weak self] in
            let result = await Task.detached { () -> PassphraseWorkResult in
                do {
                    return .success(try credentials.unlock(passphrase: currentPassphrase))
                } catch let error as Phase2CredentialError {
                    return .credentialFailure(error)
                } catch {
                    return .otherFailure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            isNavigationChangeBusy = false
            guard lifecycle.isValidSession(sessionID: sessionID, generation: generation) else { return }
            switch result {
            case .success(var authenticatedRootKey):
                defer { authenticatedRootKey.resetBytes(in: authenticatedRootKey.indices) }
                guard let activeRootKey = self.sessionRootKey else { return }
                guard SecretEntryDetector.constantTimeEquals(
                    Array(authenticatedRootKey), Array(activeRootKey)
                ) else {
                    navigationChangeMessage = "Authentication failed."
                    return
                }
                do {
                    try credentials.replaceNavigationSequence(newSequence)
                    try calculator.configureSecretEntry(sequence: newSequence) { [weak self] in
                        self?.requestAuthentication()
                    }
                    calculator.prepareFreshSecretEntry()
                    rateLimiter.recordSuccess()
                    navigationChangeMessage = "Calculator entry sequence updated."
                } catch {
                    navigationChangeMessage = error.localizedDescription
                }
            case .credentialFailure(let error):
                if error == .authenticationFailed {
                    let delay = rateLimiter.recordFailure()
                    navigationChangeMessage = delay > 0
                        ? "Authentication failed. Try again in \(Int(delay)) seconds."
                        : "Authentication failed."
                } else {
                    navigationChangeMessage = error.localizedDescription
                }
            case .otherFailure(let message):
                navigationChangeMessage = message
            }
        }
    }

    public func cancelAuthentication() {
        authenticationMessage = nil
        isAuthenticationBusy = false
        clearPendingAuthentication()
        lifecycle.lock()
        clearRootKey()
        calculator.prepareFreshSecretEntry()
        synchronizeLifecycleState()
    }

    public func authenticate(passphrase: String) {
        guard !isAuthenticationBusy,
              case .authenticating(let attemptID) = lifecycle.state else { return }
        if let retryAfter = rateLimiter.retryAfter() {
            authenticationMessage = "Try again in \(max(1, Int(retryAfter.rounded(.up)))) seconds."
            return
        }

        isAuthenticationBusy = true
        authenticationMessage = nil
        let credentials = credentials
        Task { [weak self] in
            let result = await Task.detached { () -> PassphraseWorkResult in
                do {
                    return .success(try credentials.unlock(passphrase: passphrase))
                } catch let error as Phase2CredentialError {
                    return .credentialFailure(error)
                } catch {
                    return .otherFailure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            isAuthenticationBusy = false
            switch result {
            case .success(let rootKey):
                rateLimiter.recordSuccess()
                finishAuthentication(rootKey: rootKey, attemptID: attemptID)
            case .credentialFailure(let error):
                if error == .authenticationFailed {
                    let delay = rateLimiter.recordFailure()
                    authenticationMessage = delay > 0
                        ? "Authentication failed. Try again in \(Int(delay)) seconds."
                        : "Authentication failed."
                } else {
                    authenticationMessage = error.localizedDescription
                }
            case .otherFailure(let message):
                authenticationMessage = message
            }
        }
    }

    public func authenticateWithBiometrics() {
        guard !isAuthenticationBusy,
              case .ready(let biometricEnabled) = setupState,
              biometricEnabled,
              case .authenticating(let attemptID) = lifecycle.state else { return }

        isAuthenticationBusy = true
        authenticationMessage = nil
        lifecycle.setAuthenticationPromptActive(true)
        let credentials = credentials
        Task { [weak self] in
            let rootKey = await Task.detached { () -> Data? in
                let context = LAContext()
                context.localizedReason = "Unlock the CalcVault private area"
                defer { context.invalidate() }
                return try? credentials.unlockWithBiometrics(context: context)
            }.value
            guard let self else { return }
            isAuthenticationBusy = false
            if let rootKey {
                rateLimiter.recordSuccess()
                finishAuthentication(rootKey: rootKey, attemptID: attemptID)
            } else {
                lifecycle.setAuthenticationPromptActive(false)
                authenticationMessage = "Biometric authentication was cancelled or unavailable. Use the vault passphrase."
                lifecycle.lock()
                calculator.prepareFreshSecretEntry()
                synchronizeLifecycleState()
            }
        }
    }

    public func applicationWillResignActive() {
        let previousState = lifecycle.state
        lifecycle.applicationWillResignActive()
        calculator.resetSecretEntryForBackground()
        if previousState != .calculatorLocked, lifecycle.state == .calculatorLocked {
            clearRootKey()
            calculator.prepareFreshSecretEntry()
        }
        synchronizeLifecycleState()
    }

    public func applicationDidBecomeActive() {
        lifecycle.applicationDidBecomeActive()
        if let pendingAuthentication {
            self.pendingAuthentication = nil
            lifecycle.setAuthenticationPromptActive(false)
            finishAuthentication(
                rootKey: pendingAuthentication.rootKey,
                attemptID: pendingAuthentication.attemptID
            )
        }
        if lifecycle.state == .calculatorLocked {
            clearRootKey()
        }
        synchronizeLifecycleState()
    }

    public func applicationDidEnterBackground() {
        navigationChangeMessage = nil
        clearPendingAuthentication()
        lifecycle.applicationDidEnterBackground()
        clearRootKey()
        calculator.prepareFreshSecretEntry()
        synchronizeLifecycleState()
    }

    public func lock() {
        navigationChangeMessage = nil
        clearPendingAuthentication()
        lifecycle.lock()
        clearRootKey()
        calculator.prepareFreshSecretEntry()
        synchronizeLifecycleState()
    }

    private func finishAuthentication(rootKey: Data, attemptID: UUID) {
        if let sessionID = lifecycle.completeAuthentication(attemptID: attemptID) {
            clearRootKey()
            sessionRootKey = rootKey
            authenticationMessage = nil
            configureVaultAccess(sessionID: sessionID, rootKey: rootKey)
            synchronizeLifecycleState()
            return
        }
        if case .authenticating(let activeAttemptID) = lifecycle.state,
           activeAttemptID == attemptID {
            clearPendingAuthentication()
            pendingAuthentication = (attemptID, rootKey)
            return
        }

        do {
            var discarded = rootKey
            discarded.resetBytes(in: discarded.indices)
        }
        lifecycle.lock()
        calculator.prepareFreshSecretEntry()
        synchronizeLifecycleState()
    }

    private func reloadSetupState(preserveEnrollmentError: Bool = false) {
        do {
            switch try credentials.enrollmentState() {
            case .unconfigured:
                setupState = .needsEnrollment
            case .inconsistent:
                setupState = .unavailable(
                    message: "The existing authentication configuration is incomplete. It was not replaced."
                )
            case .configured(let biometricEnabled):
                guard let sequence = try credentials.navigationSequence() else {
                    setupState = .unavailable(
                        message: "The navigation sequence is missing. No replacement was created."
                    )
                    return
                }
                try calculator.configureSecretEntry(sequence: sequence) { [weak self] in
                    self?.requestAuthentication()
                }
                setupState = .ready(biometricEnabled: biometricEnabled)
                if !preserveEnrollmentError {
                    enrollmentMessage = nil
                }
            }
        } catch {
            setupState = .unavailable(message: error.localizedDescription)
        }
    }

    private func synchronizeLifecycleState() {
        lifecycleState = lifecycle.state
    }

    private func runVaultMutation(
        successMessage: String,
        operation: @escaping @Sendable (
            VaultRepository,
            Data,
            (permit: VaultSessionPermit, vaultID: UUID),
            Int64,
            VaultOperationCancellation
        ) async throws -> Void
    ) {
        guard !isVaultStorageBusy,
              let repository = vaultRepository,
              let access = activeVaultAccess,
              let rootKey = sessionRootKey else { return }
        let cancellation = VaultOperationCancellation()
        vaultOperationCancellation = cancellation
        isVaultStorageBusy = true
        vaultOperationMessage = nil
        let task = Task { [weak self] in
            var operationKey = rootKey
            defer { operationKey.resetBytes(in: operationKey.indices) }
            do {
                try await operation(
                    repository,
                    operationKey,
                    access,
                    Self.nowMilliseconds(),
                    cancellation
                )
                let manifest = try await repository.loadManifest(
                    rootKey: operationKey,
                    vaultID: access.vaultID,
                    permit: access.permit
                )
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                applyLoadedManifest(manifest)
                vaultOperationMessage = successMessage
            } catch {
                guard let self, self.activeVaultAccess?.permit == access.permit else { return }
                finishVaultOperation(error: error)
            }
        }
        vaultOperationTask = task
    }

    private func applyLoadedManifest(_ manifest: VaultManifest) {
        vaultItems = manifest.items
        vaultStorageState = .ready(itemCount: manifest.items.count, generation: manifest.generation)
        isVaultStorageBusy = false
        vaultOperationProgress = nil
        vaultOperationCancellation = nil
        vaultOperationTask = nil
    }

    private func finishVaultOperation(error: Error) {
        isVaultStorageBusy = false
        vaultOperationProgress = nil
        vaultOperationCancellation = nil
        vaultOperationTask = nil
        if (error as? VaultFormatError) == .operationCancelled {
            vaultOperationMessage = "Operation cancelled. The last committed vault state was preserved."
        } else {
            vaultOperationMessage = error.localizedDescription
        }
    }

    nonisolated private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    nonisolated private static func contentType(for item: VaultManifestItem) -> UTType? {
        if let mediaType = item.mediaType?.split(separator: ";").first,
           let type = UTType(mimeType: String(mediaType)) {
            return type
        }
        let fileExtension = item.displayName.split(separator: ".").last.map(String.init)
        return fileExtension.flatMap { UTType(filenameExtension: $0) }
    }

    nonisolated private static func preferredExtension(for item: VaultManifestItem) -> String? {
        if item.displayName.contains("."), !item.displayName.hasSuffix(".") {
            return item.displayName.split(separator: ".").last.map(String.init)
        }
        if item.kind == .note { return "txt" }
        return contentType(for: item)?.preferredFilenameExtension
    }

    private func clearRootKey() {
        vaultOperationCancellation?.cancel()
        vaultOperationTask?.cancel()
        vaultOperationCancellation = nil
        vaultOperationTask = nil
        vaultOperationProgress = nil
        vaultOperationMessage = nil
        dismissVaultPreview()
        dismissVaultNoteDraft()
        finishVaultExport()
        vaultTemporaryFiles?.removeAll()
        vaultSessionAuthority.revoke()
        activeVaultAccess = nil
        isVaultStorageBusy = false
        vaultStorageState = .locked
        vaultItems = []
        guard var key = sessionRootKey else { return }
        key.resetBytes(in: key.indices)
        sessionRootKey = nil
    }

    private func configureVaultAccess(sessionID: UUID, rootKey: Data) {
        guard let repository = vaultRepository else {
            vaultStorageState = .unavailable(
                message: vaultRepositoryFailure ?? "Encrypted vault storage is unavailable."
            )
            return
        }
        do {
            let vaultID = try credentials.vaultIdentity()
            let permit = VaultSessionPermit(
                sessionID: sessionID,
                generation: lifecycle.sessionGeneration
            )
            activeVaultAccess = (permit, vaultID)
            vaultSessionAuthority.activate(permit)
            vaultStorageState = .checking
            isVaultStorageBusy = true
            Task { [weak self] in
                var operationKey = rootKey
                defer { operationKey.resetBytes(in: operationKey.indices) }
                do {
                    let state = try await repository.state(
                        rootKey: operationKey,
                        vaultID: vaultID,
                        permit: permit
                    )
                    guard let self, self.activeVaultAccess?.permit == permit else { return }
                    isVaultStorageBusy = false
                    switch state {
                    case .notInitialized:
                        vaultStorageState = .notInitialized
                    case .ready(let itemCount, let generation):
                        let manifest = try await repository.loadManifest(
                            rootKey: operationKey,
                            vaultID: vaultID,
                            permit: permit
                        )
                        guard self.activeVaultAccess?.permit == permit else { return }
                        vaultItems = manifest.items
                        vaultStorageState = .ready(itemCount: itemCount, generation: generation)
                    }
                } catch {
                    guard let self, self.activeVaultAccess?.permit == permit else { return }
                    isVaultStorageBusy = false
                    vaultStorageState = .unavailable(message: error.localizedDescription)
                }
            }
        } catch {
            vaultStorageState = .unavailable(message: error.localizedDescription)
        }
    }

    private func clearPendingAuthentication() {
        guard var key = pendingAuthentication?.rootKey else {
            pendingAuthentication = nil
            return
        }
        key.resetBytes(in: key.indices)
        pendingAuthentication = nil
    }
}

private enum PassphraseWorkResult: Sendable {
    case success(Data)
    case credentialFailure(Phase2CredentialError)
    case otherFailure(String)
}

@MainActor
public final class CalcVaultAppDelegate: NSObject, UIApplicationDelegate {
    public let privacyShieldController = PrivacyShieldController()

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    public func applicationWillResignActive(_ application: UIApplication) {
        privacyShieldController.coverImmediately()
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        privacyShieldController.coverImmediately()
    }
}
