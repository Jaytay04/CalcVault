import AVKit
import CoreTransferable
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct VaultPickedMediaFile: Transferable, Sendable {
    let request: VaultImportRequest

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try importFile(received, kind: .photo, fallbackExtension: "img")
        }
        FileRepresentation(importedContentType: .movie) { received in
            try importFile(received, kind: .video, fallbackExtension: "mov")
        }
    }

    private static func importFile(
        _ received: ReceivedTransferredFile,
        kind: VaultItemKind,
        fallbackExtension: String
    ) throws -> VaultPickedMediaFile {
        let manager = try VaultTemporaryFileRegistry.shared()
        let stager = VaultFileStager(temporaryFiles: manager)
        let contentType = UTType(filenameExtension: received.file.pathExtension)
        let fileExtension = received.file.pathExtension.isEmpty
            ? contentType?.preferredFilenameExtension ?? fallbackExtension
            : received.file.pathExtension
        let staged = try stager.stage(
            sourceURL: received.file,
            preferredExtension: fileExtension
        )
        let baseName = kind == .photo ? "Photo" : "Video"
        return VaultPickedMediaFile(
            request: VaultImportRequest(
                sourceURL: staged,
                displayName: "\(baseName).\(fileExtension)",
                kind: kind,
                mediaType: contentType?.preferredMIMEType
            )
        )
    }
}

enum VaultNoteDraftPresentationDecision {
    case none
    case editNote(VaultManifestItem, String)
}

func vaultNoteDraftPresentationDecision(
    draft: VaultNoteDraft?,
    pendingNoteEditorItemID: UUID?
) -> VaultNoteDraftPresentationDecision {
    guard let draft,
          let pendingNoteEditorItemID,
          draft.item.id == pendingNoteEditorItemID else {
        return .none
    }
    return .editNote(draft.item, draft.body)
}

struct VaultWorkspaceRootView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var presentedPreview: VaultPreviewPayload?
    @State private var presentedExport: VaultExportPayload?

    var body: some View {
        VaultWorkspaceView()
            .onReceive(coordinator.$vaultPreview) { presentedPreview = $0 }
            .onReceive(coordinator.$vaultExport) { presentedExport = $0 }
            .sheet(item: $presentedPreview) { preview in
                VaultPreviewView(preview: preview)
                    .onDisappear(perform: coordinator.dismissVaultPreview)
            }
            .sheet(item: $presentedExport) { export in
                VaultShareSheet(fileURL: export.fileURL) {
                    presentedExport = nil
                    coordinator.finishVaultExport()
                }
            }
    }
}

struct VaultWorkspaceView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let parentID: UUID?
    let title: String

    @State private var searchText = ""
    @State private var gridMode = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var editor: VaultItemEditor?
    @State private var movingItem: VaultManifestItem?
    @State private var deletingItem: VaultManifestItem?
    @State private var exportCandidate: VaultManifestItem?
    @State private var pendingNoteEditorItemID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var showingExportWarning = false
    @State private var strictMode = true

    init(parentID: UUID? = nil, title: String = "Files") {
        self.parentID = parentID
        self.title = title
    }

    private var visibleItems: [VaultManifestItem] {
        vaultVisibleItems(
            coordinator.vaultItems,
            parentID: parentID,
            searchText: searchText
        )
    }

    var body: some View {
        Group {
            switch coordinator.vaultStorageState {
            case .locked:
                ContentUnavailableView("Vault locked", systemImage: "lock")
            case .checking:
                ProgressView("Checking encrypted storage")
            case .notInitialized:
                initializationView
            case .ready:
                vaultContents
            case .unavailable(let message):
                ContentUnavailableView(
                    "Vault unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search encrypted items")
        .toolbar { workspaceToolbar }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 50,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            loadPhotoSelection(selection)
        }
        .onReceive(coordinator.$vaultNoteDraft, perform: handleVaultNoteDraft)
        .onAppear { strictMode = coordinator.strictDiskPreviewMode }
        .onChange(of: strictMode) { _, enabled in
            coordinator.setStrictDiskPreviewMode(enabled)
        }
        .sheet(item: $editor) { editor in
            VaultItemEditorView(editor: editor, parentID: parentID)
                .environmentObject(coordinator)
        }
        .sheet(item: $movingItem) { item in
            VaultMoveView(item: item)
                .environmentObject(coordinator)
        }
        .alert("Delete item?", isPresented: $showingDeleteConfirmation, presenting: deletingItem) { item in
            Button("Delete", role: .destructive) {
                coordinator.deleteVaultItem(item.id)
                deletingItem = nil
            }
            Button("Cancel", role: .cancel) { deletingItem = nil }
        } message: { item in
            Text("This removes “\(item.displayName)” from the encrypted vault. Flash storage and backups cannot be claimed to be securely erased.")
        }
        .alert("Export plaintext?", isPresented: $showingExportWarning, presenting: exportCandidate) { item in
            Button("Export") {
                coordinator.prepareVaultExport(item)
                exportCandidate = nil
            }
            Button("Cancel", role: .cancel) { exportCandidate = nil }
        } message: { _ in
            Text("The receiving app may retain an unencrypted copy. CalcVault cannot revoke it after sharing.")
        }
    }

    private var initializationView: some View {
        ContentUnavailableView {
            Label("Encrypted vault not initialized", systemImage: "archivebox")
        } description: {
            Text("Initialization is explicit. Missing or corrupt initialized storage is never replaced with an empty vault.")
        } actions: {
            Button("Initialize encrypted vault", action: coordinator.initializeEncryptedVault)
                .disabled(coordinator.isVaultStorageBusy)
        }
    }

    private var vaultContents: some View {
        VStack(spacing: 0) {
            if let progress = coordinator.vaultOperationProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress.fractionCompleted)
                    HStack {
                        Text(progress.label).font(.caption)
                        Spacer()
                        Button("Cancel", action: coordinator.cancelVaultOperation)
                    }
                }
                .padding()
                .background(.thinMaterial)
            }

            if gridMode {
                ScrollView {
                    if visibleItems.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No items" : "No matches",
                            systemImage: searchText.isEmpty ? "archivebox" : "magnifyingglass"
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(visibleItems) { item in
                                gridItem(item)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                List {
                    if let message = coordinator.vaultOperationMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if visibleItems.isEmpty {
                        Text(searchText.isEmpty ? "No encrypted items." : "No matching encrypted items.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleItems) { item in
                        listItem(item)
                    }
                    if parentID == nil {
                        privacySection
                        prototypeSection
                    }
                }
                .refreshable { coordinator.refreshVaultItems() }
            }
        }
    }

    @ViewBuilder
    private func listItem(_ item: VaultManifestItem) -> some View {
        if item.kind == .folder {
            NavigationLink {
                VaultWorkspaceView(parentID: item.id, title: item.displayName)
            } label: {
                VaultItemLabel(item: item)
            }
            .contextMenu { itemActions(item) }
        } else {
            Button { coordinator.previewVaultItem(item) } label: {
                VaultItemLabel(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { itemActions(item) }
        }
    }

    private func gridItem(_ item: VaultManifestItem) -> some View {
        Group {
            if item.kind == .folder {
                NavigationLink {
                    VaultWorkspaceView(parentID: item.id, title: item.displayName)
                } label: {
                    VaultGridItem(item: item)
                }
            } else {
                Button { coordinator.previewVaultItem(item) } label: {
                    VaultGridItem(item: item)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { itemActions(item) }
    }

    @ViewBuilder
    private func itemActions(_ item: VaultManifestItem) -> some View {
        if item.kind == .note {
            Button("Edit note", systemImage: "square.and.pencil") {
                openNoteEditor(item)
            }
        }
        Button("Rename", systemImage: "pencil") { editor = .rename(item) }
        Button("Move", systemImage: "folder") { movingItem = item }
        if item.kind != .folder {
            Button("Export plaintext", systemImage: "square.and.arrow.up") {
                exportCandidate = item
                showingExportWarning = true
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            deletingItem = item
            showingDeleteConfirmation = true
        }
    }

    private var privacySection: some View {
        Section("Preview privacy") {
            Toggle(
                "Strict mode (disable video previews)",
                isOn: $strictMode
            )
            Text("Imports copy and preserve originals. Image, text, and supported PDF previews stay memory-backed. Video preview temporarily creates a protected, randomly named plaintext file when strict mode is off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var prototypeSection: some View {
        Section("Phase 0 tools") {
            NavigationLink("Diagnostics", destination: Phase0DiagnosticsView())
            NavigationLink("Independent local archive", destination: LocalArchivePrototypeView())
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                gridMode.toggle()
            } label: {
                Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2")
            }
            Menu {
                Button("Import files", systemImage: "doc.badge.plus") {
                    showingFileImporter = true
                }
                Button("Import photos or videos", systemImage: "photo.on.rectangle") {
                    showingPhotoPicker = true
                }
                Button("New folder", systemImage: "folder.badge.plus") { editor = .newFolder }
                Button("New note", systemImage: "note.text.badge.plus") { editor = .newNote }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(coordinator.isVaultStorageBusy)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            coordinator.importFiles(urls.map(VaultImportRequest.init(sourceURL:)), parentID: parentID)
        case .failure(let error):
            coordinator.reportVaultPickerError(error)
        }
    }

    private func loadPhotoSelection(_ selection: [PhotosPickerItem]) {
        photoSelection = []
        Task {
            var requests: [VaultImportRequest] = []
            do {
                for item in selection {
                    guard let imported = try await item.loadTransferable(type: VaultPickedMediaFile.self) else {
                        throw VaultFormatError.unsupportedImport
                    }
                    requests.append(imported.request)
                }
                await MainActor.run {
                    coordinator.importFiles(requests, parentID: parentID)
                }
            } catch {
                await MainActor.run {
                    coordinator.discardStagedImports(requests)
                    coordinator.reportVaultPickerError(error)
                }
            }
        }
    }

    private func openNoteEditor(_ item: VaultManifestItem) {
        guard !coordinator.isVaultStorageBusy else { return }
        pendingNoteEditorItemID = item.id
        coordinator.prepareVaultNoteEditor(item)
        Task { @MainActor in
            while coordinator.isVaultStorageBusy {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if coordinator.vaultNoteDraft == nil {
                pendingNoteEditorItemID = nil
            }
        }
    }

    private func handleVaultNoteDraft(_ draft: VaultNoteDraft?) {
        switch vaultNoteDraftPresentationDecision(
            draft: draft,
            pendingNoteEditorItemID: pendingNoteEditorItemID
        ) {
        case .none:
            return
        case .editNote(let item, let body):
            pendingNoteEditorItemID = nil
            coordinator.dismissVaultNoteDraft()
            editor = .editNote(item, body)
        }
    }
}

private enum VaultItemEditor: Identifiable {
    case newFolder
    case newNote
    case editNote(VaultManifestItem, String)
    case rename(VaultManifestItem)

    var id: String {
        switch self {
        case .newFolder: return "new-folder"
        case .newNote: return "new-note"
        case .editNote(let item, _): return "edit-note-\(item.id)"
        case .rename(let item): return "rename-\(item.id)"
        }
    }
}

private struct VaultItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    let editor: VaultItemEditor
    let parentID: UUID?
    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(titlePrompt, text: $title)
                if isNote {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 240)
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: populate)
        }
    }

    private var isNote: Bool {
        switch editor {
        case .newNote, .editNote: return true
        default: return false
        }
    }

    private var navigationTitle: String {
        switch editor {
        case .newFolder: return "New folder"
        case .newNote: return "New note"
        case .editNote: return "Edit note"
        case .rename: return "Rename"
        }
    }

    private var titlePrompt: String { isNote ? "Title" : "Name" }

    private func populate() {
        switch editor {
        case .editNote(let item, let body):
            title = item.displayName
            bodyText = body
        case .rename(let item):
            title = item.displayName
        default:
            break
        }
    }

    private func save() {
        switch editor {
        case .newFolder:
            coordinator.createVaultFolder(name: title, parentID: parentID)
        case .newNote:
            coordinator.saveVaultNote(itemID: nil, title: title, body: bodyText, parentID: parentID)
        case .editNote(let item, _):
            coordinator.saveVaultNote(itemID: item.id, title: title, body: bodyText, parentID: item.parentID)
        case .rename(let item):
            coordinator.renameVaultItem(item.id, to: title)
        }
        dismiss()
    }
}

private struct VaultMoveView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    let item: VaultManifestItem

    private var folders: [VaultManifestItem] {
        vaultMoveDestinations(coordinator.vaultItems, excluding: item.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Button("Vault root") { move(to: nil) }
                ForEach(folders) { folder in
                    Button(folder.displayName) { move(to: folder.id) }
                }
            }
            .navigationTitle("Move \(item.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func move(to parentID: UUID?) {
        coordinator.moveVaultItem(item.id, to: parentID)
        dismiss()
    }
}

private struct VaultItemLabel: View {
    let item: VaultManifestItem

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(item.displayName)
                if item.kind != .folder {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(item.kind == .folder ? .blue : .secondary)
        }
    }

    private var iconName: String {
        switch item.kind {
        case .folder: "folder.fill"
        case .note: "note.text"
        case .photo: "photo"
        case .video: "video"
        default: "doc"
        }
    }
}

private struct VaultGridItem: View {
    let item: VaultManifestItem

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: item.kind == .folder ? "folder.fill" : "doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(item.kind == .folder ? .blue : .secondary)
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VaultPreviewView: View {
    let preview: VaultPreviewPayload

    var body: some View {
        NavigationStack {
            Group {
                switch preview.content {
                case .text(let text):
                    ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding() }
                case .image(let data):
                    if let image = UIImage(data: data) {
                        GeometryReader { viewport in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(
                                    width: viewport.size.width,
                                    height: viewport.size.height
                                )
                        }
                        .padding()
                    } else {
                        ContentUnavailableView("Image unavailable", systemImage: "photo")
                    }
                case .pdf(let data):
                    VaultPDFView(data: data)
                case .videoFile(let url):
                    VideoPlayer(player: AVPlayer(url: url))
                }
            }
            .navigationTitle(preview.item.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct VaultPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}

private struct VaultShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private func vaultVisibleItems(
    _ allItems: [VaultManifestItem],
    parentID: UUID?,
    searchText: String
) -> [VaultManifestItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [VaultManifestItem] = []
    result.reserveCapacity(allItems.count)
    for item in allItems {
        if query.isEmpty {
            if item.parentID == parentID { result.append(item) }
        } else if item.displayName.localizedCaseInsensitiveContains(query) {
            result.append(item)
        }
    }
    return result.sorted(by: vaultItemOrder)
}

private func vaultMoveDestinations(
    _ allItems: [VaultManifestItem],
    excluding itemID: UUID
) -> [VaultManifestItem] {
    var result: [VaultManifestItem] = []
    for item in allItems where item.kind == .folder && item.id != itemID {
        result.append(item)
    }
    return result.sorted(by: vaultItemOrder)
}

private func vaultItemOrder(_ lhs: VaultManifestItem, _ rhs: VaultManifestItem) -> Bool {
    if (lhs.kind == .folder) != (rhs.kind == .folder) {
        return lhs.kind == .folder
    }
    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
}
