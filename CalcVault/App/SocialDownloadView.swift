import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A user-directed transfer. Downloader pages use a separate ephemeral WebKit
/// store and never receive the social profile's cookies or vault objects.
struct SocialDownloadRequest: Identifiable {
    let id = UUID()
    let service: SocialService
    let pageURL: URL?
}

enum SocialDownloadPolicy {
    static func providerURL(for service: SocialService) -> URL {
        switch service {
        case .tikTok: URL(string: "https://www.tikvib.com/")!
        case .x: URL(string: "https://ssstwitter.com/")!
        case .instagram: URL(string: "https://fastdl.app/en5IW")!
        }
    }

    static func isProviderPage(_ url: URL, service: SocialService) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              let providerHost = providerURL(for: service).host else { return false }
        return host == providerHost || host == "www.\(providerHost)"
            || (providerHost.hasPrefix("www.") && host == String(providerHost.dropFirst(4)))
    }

    static func postURL(_ url: URL?, service: SocialService) -> URL? {
        SocialLinkPolicy.contentURL(url, service: service)
    }

    static func mediaType(suggestedFilename: String, mimeType: String?) -> (name: String, kind: VaultItemKind, mime: String)? {
        let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.count <= 180,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
        // Refuse executable image formats and misleading response types.
        guard type.identifier != "public.svg-image" else { return nil }
        if let mimeType, mimeType != "application/octet-stream" {
            guard let responseType = UTType(mimeType: mimeType),
                  responseType.conforms(to: type.conforms(to: .image) ? .image : .movie) else {
                return nil
            }
        }
        return (name, type.conforms(to: .image) ? .photo : .video,
                type.preferredMIMEType ?? mimeType ?? "application/octet-stream")
    }
}

@available(iOS 18.0, *)
struct SocialDownloadView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    let request: SocialDownloadRequest
    @StateObject private var browser: SocialDownloadBrowser
    @State private var postLink: String

    init(request: SocialDownloadRequest) {
        self.request = request
        _browser = StateObject(wrappedValue: SocialDownloadBrowser(service: request.service))
        _postLink = State(initialValue: SocialDownloadPolicy.postURL(request.pageURL, service: request.service)?.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Only public post or Story links are supported. The downloader receives the link you paste into its page; do not sign in there. Its website data is separate from your social session and vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Paste a post or Story link", text: $postLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Copy link") { copyPostLink() }
                            .disabled(validatedPostURL == nil)
                    }
                    Text("Copy the link, paste it into the website below, and choose its media download. CalcVault will encrypt a supported image or video into Files when WebKit supplies a download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = browser.message {
                        Text(message).font(.footnote)
                            .foregroundStyle(browser.hasError ? Color.red : Color.secondary)
                    }
                    if coordinator.isVaultStorageBusy {
                        ProgressView(coordinator.vaultOperationProgress?.label ?? "Encrypting download")
                    } else if let message = coordinator.vaultOperationMessage {
                        Text(message).font(.footnote)
                    }
                }
                .padding()

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text(browser.host ?? SocialDownloadPolicy.providerURL(for: request.service).host ?? "Website")
                        .font(.footnote.monospaced())
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)

                SocialDownloaderWebView(browser: browser)
            }
            .navigationTitle("Download from \(request.service.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            browser.onFile = { file in coordinator.importFiles([file], parentID: nil) }
        }
        .onDisappear { browser.stop() }
        .onChange(of: coordinator.lifecycleState) { _, state in
            if case .privateUnlocked = state { return }
            browser.stop()
        }
        .alert("Save download to encrypted Files?", isPresented: $browser.isAwaitingSave) {
            Button("Save to Files") { browser.acceptPendingFile() }
            Button("Discard", role: .cancel) { browser.discardPendingFile() }
        } message: {
            Text(browser.pendingName ?? "Downloaded media")
        }
    }

    private var validatedPostURL: URL? {
        SocialDownloadPolicy.postURL(URL(string: postLink.trimmingCharacters(in: .whitespacesAndNewlines)), service: request.service)
    }

    private func copyPostLink() {
        guard let validatedPostURL else { return }
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: validatedPostURL.absoluteString]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        browser.message = "Link copied locally for two minutes. Paste it into the downloader."
        browser.hasError = false
    }
}

@available(iOS 18.0, *)
private struct SocialDownloaderWebView: UIViewRepresentable {
    @ObservedObject var browser: SocialDownloadBrowser

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = browser
        webView.uiDelegate = browser
        browser.attach(webView)
        webView.load(URLRequest(url: SocialDownloadPolicy.providerURL(for: browser.service)))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

@available(iOS 18.0, *)
@MainActor
final class SocialDownloadBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var message: String?
    @Published var hasError = false
    @Published var host: String?
    @Published var isAwaitingSave = false
    @Published var pendingName: String?
    let service: SocialService
    var onFile: ((VaultImportRequest) -> Bool)?
    private weak var webView: WKWebView?
    private let temporaryFiles = try? VaultTemporaryFileRegistry.shared()
    private var downloads: [ObjectIdentifier: (download: WKDownload, file: URL, name: String, kind: VaultItemKind, mime: String)] = [:]
    private var pendingFile: VaultImportRequest?
    private var sizeTimer: Timer?
    private let sizeLimit: Int64 = 1_024 * 1_024 * 1_024

    init(service: SocialService) {
        self.service = service
        super.init()
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        host = SocialDownloadPolicy.providerURL(for: service).host
    }

    func stop() {
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView?.closeAllMediaPresentations(completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        sizeTimer?.invalidate()
        sizeTimer = nil
        for entry in downloads.values {
            entry.download.cancel(nil)
            temporaryFiles?.remove(entry.file)
        }
        downloads.removeAll()
        discardPendingFile()
        onFile = nil
    }

    func acceptPendingFile() {
        guard let pendingFile else { return }
        self.pendingFile = nil
        pendingName = nil
        isAwaitingSave = false
        guard onFile?(pendingFile) == true else {
            temporaryFiles?.remove(pendingFile.sourceURL)
            fail("The vault is unavailable or busy. Nothing was saved.")
            return
        }
        message = "Download complete. Encrypting into Files…"
        hasError = false
    }

    func discardPendingFile() {
        if let pendingFile { temporaryFiles?.remove(pendingFile.sourceURL) }
        pendingFile = nil
        pendingName = nil
        isAwaitingSave = false
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else {
            fail("The downloader tried to open an unsupported destination.")
            decisionHandler(.cancel)
            return
        }
        // Some providers generate a media Blob locally. WebKit can download it
        // without exposing that Blob or the native destination to page script.
        if url.scheme?.lowercased() == "blob", action.shouldPerformDownload,
           let pageURL = webView.url,
           SocialDownloadPolicy.isProviderPage(pageURL, service: service) {
            decisionHandler(.download)
            return
        }
        guard SocialNavigationPolicy.permitsEmbeddedLoad(url) else {
            fail("The downloader tried to open an unsupported destination.")
            decisionHandler(.cancel)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard let url = navigationResponse.response.url,
              SocialNavigationPolicy.permitsEmbeddedLoad(url)
                || (url.scheme?.lowercased() == "blob"
                    && webView.url.map { SocialDownloadPolicy.isProviderPage($0, service: service) } == true) else {
            decisionHandler(.cancel)
            return
        }
        let mime = navigationResponse.response.mimeType ?? ""
        if !navigationResponse.canShowMIMEType || mime.hasPrefix("image/") || mime.hasPrefix("video/") {
            decisionHandler(.download)
        } else if SocialDownloadPolicy.isProviderPage(url, service: service) {
            decisionHandler(.allow)
        } else {
            fail("The downloader opened an unrelated page; it was blocked.")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        host = webView.url?.host
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = action.request.url,
              SocialNavigationPolicy.permitsEmbeddedLoad(url) else { return nil }
        webView.load(action.request)
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard downloads.isEmpty, pendingFile == nil,
              response.expectedContentLength < 0 || response.expectedContentLength <= sizeLimit,
              let media = SocialDownloadPolicy.mediaType(
                suggestedFilename: suggestedFilename,
                mimeType: response.mimeType
              ), let temporaryFiles else {
            fail("This download is not a supported image or video, or it exceeds 1 GB.")
            completionHandler(nil)
            return
        }
        do {
            let destination = try temporaryFiles.makeDestination(
                preferredExtension: URL(fileURLWithPath: media.name).pathExtension
            )
            downloads[ObjectIdentifier(download)] = (download, destination, media.name, media.kind, media.mime)
            message = "Downloading to private temporary storage…"
            hasError = false
            startSizeTimer()
            completionHandler(destination)
        } catch {
            fail("Private download storage is unavailable.")
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)),
              let temporaryFiles else { return }
        defer { if downloads.isEmpty { sizeTimer?.invalidate(); sizeTimer = nil } }
        do {
            try temporaryFiles.finalizeFile(at: entry.file)
            let size = try entry.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, Int64(size) <= sizeLimit else {
                temporaryFiles.remove(entry.file)
                fail("The downloaded file is empty or exceeds 1 GB.")
                return
            }
            guard pendingFile == nil else {
                temporaryFiles.remove(entry.file)
                fail("Finish the pending save before downloading another file.")
                return
            }
            pendingFile = VaultImportRequest(
                sourceURL: entry.file,
                displayName: entry.name,
                kind: entry.kind,
                mediaType: entry.mime
            )
            pendingName = entry.name
            message = "Download complete. Confirm the file to save."
            hasError = false
            isAwaitingSave = true
        } catch {
            temporaryFiles.remove(entry.file)
            fail("The downloaded file could not be protected or imported.")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            temporaryFiles?.remove(entry.file)
        }
        if downloads.isEmpty { sizeTimer?.invalidate(); sizeTimer = nil }
        fail("Download failed. Nothing was saved.")
    }

    private func startSizeTimer() {
        guard sizeTimer == nil else { return }
        sizeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let oversized = self.downloads.filter { element in
                    let size = (try? element.value.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return Int64(size) > self.sizeLimit
                }
                for (id, entry) in oversized {
                    self.downloads.removeValue(forKey: id)
                    entry.download.cancel(nil)
                    self.temporaryFiles?.remove(entry.file)
                    self.fail("The download exceeded 1 GB and was stopped.")
                }
            }
        }
    }

    private func fail(_ text: String) {
        message = text
        hasError = true
    }
}
