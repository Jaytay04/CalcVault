import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A profile loads only after its first selection, then remains mounted for
/// the rest of the private session so website state and navigation stay intact.
struct SocialProfileActivation {
    private(set) var mountedServices: Set<SocialService> = []

    mutating func observe(selectedService: SocialService, isWorkspaceActive: Bool) {
        guard isWorkspaceActive else { return }
        mountedServices.insert(selectedService)
    }

    func shouldMount(_ service: SocialService, selectedService: SocialService, isWorkspaceActive: Bool) -> Bool {
        mountedServices.contains(service) || (isWorkspaceActive && selectedService == service)
    }
}

/// Three native browser profiles. Website state is separate from vault content.
@available(iOS 17.0, *)
public struct SocialWorkspaceView: View {
    @Binding private var selectedService: SocialService
    let isWorkspaceActive: Bool
    let requestDownload: (SocialService, URL?) -> Void
    @State private var showingClearAllConfirmation = false
    @State private var clearAllGeneration = 0
    @State private var profileActivation = SocialProfileActivation()

    public init(
        selectedService: Binding<SocialService>,
        isWorkspaceActive: Bool,
        requestDownload: @escaping (SocialService, URL?) -> Void
    ) {
        _selectedService = selectedService
        self.isWorkspaceActive = isWorkspaceActive
        self.requestDownload = requestDownload
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(SocialService.allCases) { service in
                    if profileActivation.shouldMount(
                        service,
                        selectedService: selectedService,
                        isWorkspaceActive: isWorkspaceActive
                    ) {
                        SocialProfileView(
                            service: service,
                            isActive: isWorkspaceActive && selectedService == service,
                            clearAllGeneration: clearAllGeneration,
                            requestClearAll: { showingClearAllConfirmation = true },
                            requestDownload: requestDownload
                        )
                        .opacity(selectedService == service ? 1 : 0)
                        .allowsHitTesting(selectedService == service)
                        .accessibilityHidden(selectedService != service)
                    }
                }
            }
        }
        .navigationTitle(selectedService.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: observeSelection)
        .onChange(of: selectedService) { _, _ in observeSelection() }
        .onChange(of: isWorkspaceActive) { _, _ in observeSelection() }
        .confirmationDialog(
            "Clear all local browser data?",
            isPresented: $showingClearAllConfirmation
        ) {
            Button("Clear all local data", role: .destructive) {
                clearAllGeneration += 1
            }
        } message: {
            Text("All three website views will close and their local data will be cleared. This can sign you out but does not delete server-side accounts or history.")
        }
    }

    private func observeSelection() {
        profileActivation.observe(
            selectedService: selectedService,
            isWorkspaceActive: isWorkspaceActive
        )
    }
}

@available(iOS 17.0, *)
private struct SocialProfileView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let service: SocialService
    let isActive: Bool
    let clearAllGeneration: Int
    let requestClearAll: () -> Void
    let requestDownload: (SocialService, URL?) -> Void
    @StateObject private var browser: SocialBrowserState
    @State private var persistence: BrowserPersistenceMode
    @State private var hasSelectedMode: Bool
    @State private var requestedMode: BrowserPersistenceMode?
    @State private var showingModeConfirmation = false
    @State private var showingClearConfirmation = false
    @State private var showingSafariConfirmation = false
    @State private var isResetting = false
    @State private var browserGeneration = 0
    @State private var dataMessage: String?

    init(
        service: SocialService,
        isActive: Bool,
        clearAllGeneration: Int,
        requestClearAll: @escaping () -> Void,
        requestDownload: @escaping (SocialService, URL?) -> Void
    ) {
        self.service = service
        self.isActive = isActive
        self.clearAllGeneration = clearAllGeneration
        self.requestClearAll = requestClearAll
        self.requestDownload = requestDownload
        _browser = StateObject(wrappedValue: SocialBrowserState(service: service))
        _persistence = State(initialValue: BrowserProfilePreferences.mode(for: service))
        _hasSelectedMode = State(initialValue: BrowserProfilePreferences.hasChoice(for: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text(browser.host ?? service.officialHostname)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Menu {
                    Section("Navigation") {
                        Button("Back", systemImage: "chevron.left", action: browser.goBack)
                            .disabled(!hasSelectedMode || (!browser.canGoBack && browser.popup == nil))
                        Button("Forward", systemImage: "chevron.right", action: browser.goForward)
                            .disabled(!hasSelectedMode || !browser.canGoForward)
                        Button("Reload", systemImage: "arrow.clockwise", action: browser.reload)
                            .disabled(!hasSelectedMode)
                        Button("Home", systemImage: "house") { browser.goHome(service.officialURL) }
                            .disabled(!hasSelectedMode)
                        Button("Open in Safari", systemImage: "safari") {
                            showingSafariConfirmation = true
                        }
                    }
                    if service != .instagram {
                        Section("Display") {
                            Button(browser.prefersDesktopSite ? "Use mobile site" : "Try desktop site") {
                                toggleDesktopSite()
                            }
                            .disabled(!hasSelectedMode)
                            if service == .tikTok {
                                Button(browser.fitsMoreOfPage ? "Reset page size" : "Fit desktop page") {
                                    browser.togglePageFit()
                                    dataMessage = browser.fitsMoreOfPage
                                        ? "The desktop page is scaled down to show more of its width. Reset page size to restore the normal view."
                                        : "Normal TikTok page size restored."
                                }
                                .disabled(!hasSelectedMode || !browser.prefersDesktopSite)
                            }
                        }
                    }
                    Section("Media") {
                        Button("Copy current post/story link", systemImage: "link") {
                            copyCurrentContentLink()
                        }
                        .disabled(!hasSelectedMode)
                        Button("Download to Files", systemImage: "arrow.down.circle") {
                            requestDownload(service, browser.pageURL)
                        }
                        .disabled(!hasSelectedMode)
                    }
                    Section("Browser data") {
                        ForEach(BrowserPersistenceMode.allCases) { mode in
                            Button(mode.displayName) { requestMode(mode) }
                                .disabled(!hasSelectedMode)
                        }
                        Button("Clear site data", role: .destructive) {
                            showingClearConfirmation = true
                        }
                        .disabled(!hasSelectedMode)
                        Button("Clear all local browser data", role: .destructive) {
                            requestClearAll()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(minWidth: 44, minHeight: 32)
                        .accessibilityLabel("Browser options")
                }
                .disabled(isResetting)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(.bar)

            Text("\(persistence.displayName): \(persistence.disclosure)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 3)

            if service == .x {
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.mainFrameLoadSummary)
                    Text(browser.appPolicySummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            if let error = browser.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            if isResetting {
                ProgressView("Clearing website data")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasSelectedMode {
                VStack(spacing: 14) {
                    Text("Choose \(service.displayName) browser data mode")
                        .font(.headline)
                    Text("Remembered keeps website-managed sign-in data on this device. Ephemeral asks WebKit not to persist it after the session ends.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Use Remembered") { chooseInitialMode(.remembered) }
                        .buttonStyle(.borderedProminent)
                    Button("Use Ephemeral") { chooseInitialMode(.ephemeral) }
                        .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SocialWebView(service: service, persistence: persistence, browser: browser, isActive: isActive)
                    .id("\(service.id)-\(persistence.id)-\(browserGeneration)")
                    .accessibilityLabel(Text(browser.title ?? service.displayName))
            }

            if let dataMessage {
                Text(dataMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

        }
        .onChange(of: isActive) { _, active in
            if active { browser.resumeMedia() } else { browser.suspendMedia() }
        }
        .onChange(of: clearAllGeneration) { _, _ in
            Task { await resetSiteData() }
        }
        .onDisappear(perform: browser.suspendMedia)
        .sheet(item: $browser.popup, onDismiss: browser.closePopup) { popup in
            NavigationStack {
                SocialPopupWebView(webView: popup.webView)
                    .navigationTitle(browser.popupHost ?? "Website")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done", action: browser.closePopup)
                        }
                    }
            }
        }
        .confirmationDialog(
            "Change \(service.displayName) browser mode?",
            isPresented: $showingModeConfirmation
        ) {
            if requestedMode == .ephemeral {
                Button("Clear remembered data and switch", role: .destructive) {
                    Task { await applyRequestedMode() }
                }
            } else {
                Button("Switch to Remembered") {
                    Task { await applyRequestedMode() }
                }
            }
        } message: {
            Text("Switching ends the current web view session. Choosing Ephemeral also clears this service's remembered local website data. You may need to sign in again.")
        }
        .confirmationDialog(
            "Clear \(service.displayName) local website data?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear local data", role: .destructive) {
                Task { await resetSiteData() }
            }
        } message: {
            Text("This signs out the local browser profile. It does not delete your account or server-side history.")
        }
        .confirmationDialog(
            "Open \(service.displayName) in Safari?",
            isPresented: $showingSafariConfirmation
        ) {
            Button("Lock CalcVault and open Safari") {
                coordinator.lock()
                UIApplication.shared.open(service.officialURL)
            }
        } message: {
            Text("Safari opens outside CalcVault and may use a different website session. Returning to CalcVault requires unlocking again.")
        }
    }

    private func requestMode(_ mode: BrowserPersistenceMode) {
        guard mode != persistence, !isResetting else { return }
        requestedMode = mode
        showingModeConfirmation = true
    }

    private func toggleDesktopSite() {
        browser.toggleDesktopSite(homeURL: service.officialURL)
        dataMessage = browser.prefersDesktopSite
            ? "Desktop rendering requested. The website may still redirect or fail to load."
            : "Mobile rendering restored."
    }

    private func copyCurrentContentLink() {
        guard let url = SocialLinkPolicy.contentURL(browser.pageURL, service: service) else {
            dataMessage = "This page has not exposed a distinct post or Story link. Try the website's Share control; on TikTok, Fit desktop page may reveal it."
            return
        }
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: url.absoluteString]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        dataMessage = "Current post or Story link copied locally for two minutes."
    }

    private func chooseInitialMode(_ mode: BrowserPersistenceMode) {
        if mode == .ephemeral {
            Task {
                isResetting = true
                await BrowserProfileStore().clearRememberedData(for: service)
                finishInitialChoice(mode)
            }
        } else {
            finishInitialChoice(mode)
        }
    }

    private func finishInitialChoice(_ mode: BrowserPersistenceMode) {
        persistence = mode
        BrowserProfilePreferences.setMode(mode, for: service)
        hasSelectedMode = true
        isResetting = false
    }

    private func applyRequestedMode() async {
        guard let mode = requestedMode, mode != persistence, !isResetting else { return }
        let previousMode = persistence
        await tearDownBrowser()
        if previousMode == .remembered && mode == .ephemeral {
            await BrowserProfileStore().clearRememberedData(for: service)
        }
        persistence = mode
        BrowserProfilePreferences.setMode(mode, for: service)
        requestedMode = nil
        finishBrowserReset(message: "Browser mode changed. The website may require sign-in again.")
    }

    private func resetSiteData() async {
        guard !isResetting else { return }
        await tearDownBrowser()
        if persistence == .remembered {
            await BrowserProfileStore().clearRememberedData(for: service)
        }
        finishBrowserReset(message: "Local website data cleared. Server-side account data was not changed.")
    }

    private func tearDownBrowser() async {
        isResetting = true
        browser.closePopup()
        browser.suspendMedia()
        await Task.yield()
    }

    private func finishBrowserReset(message: String) {
        browser.resetPageState()
        browserGeneration += 1
        dataMessage = message
        isResetting = false
    }
}
