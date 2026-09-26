import SwiftUI
import WebKit

enum SocialMainFrameLoadPhase: String {
    case notStarted = "Not started"
    case started = "Connecting"
    case committed = "Receiving page"
    case finished = "Navigation finished"
    case failed = "Navigation failed"
    case cancelled = "Navigation cancelled"
    case policyInterrupted = "Policy interrupted"
    case processTerminated = "Web content stopped"
}

/// Native browser state for one social profile. It never reads page content or cookies.
@MainActor
final class SocialBrowserState: ObservableObject {
    @Published private(set) var host: String?
    @Published private(set) var pageURL: URL?
    @Published private(set) var title: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var popupHost: String?
    @Published var popup: SocialBrowserPopup?
    @Published private(set) var mainFrameLoadPhase: SocialMainFrameLoadPhase = .notStarted
    @Published private(set) var mainFrameHTTPStatus: Int?
    @Published private(set) var mainFrameErrorCode: String?
    @Published private(set) var appPolicyRejection: String?
    @Published private(set) var prefersDesktopSite = false
    @Published private(set) var fitsMoreOfPage = false
    private(set) var mediaIsSuspended = false

    private weak var mainWebView: WKWebView?

    init(service: SocialService = .instagram) {
        prefersDesktopSite = service.prefersDesktopSiteByDefault
    }

    func attach(_ webView: WKWebView) {
        mainWebView = webView
        if mediaIsSuspended {
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        refresh(from: webView)
    }

    func detach(_ webView: WKWebView) {
        if mainWebView === webView {
            mainWebView = nil
        }
        closePopup()
    }

    func refresh(from webView: WKWebView) {
        if popup?.webView === webView {
            popupHost = webView.url?.host
            return
        }
        guard mainWebView === webView else { return }
        host = webView.url?.host
        pageURL = webView.url
        title = webView.title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    var mainFrameLoadSummary: String {
        if let mainFrameErrorCode {
            return "X page: \(mainFrameLoadPhase.rawValue) · \(mainFrameErrorCode)"
        }
        if let mainFrameHTTPStatus {
            return "X page: \(mainFrameLoadPhase.rawValue) · HTTP \(mainFrameHTTPStatus)"
        }
        return "X page: \(mainFrameLoadPhase.rawValue)"
    }

    var appPolicySummary: String {
        "App policy: \(appPolicyRejection ?? "no rejection observed")"
    }

    func recordAppPolicyRejection(in webView: WKWebView, reason: String) {
        guard mainWebView === webView else { return }
        appPolicyRejection = reason
    }

    func clearAppPolicyRejection() {
        appPolicyRejection = nil
    }

    func navigationStarted(in webView: WKWebView) {
        guard mainWebView === webView else { return }
        mainFrameHTTPStatus = nil
        mainFrameErrorCode = nil
        mainFrameLoadPhase = .started
    }

    func mainFrameResponse(in webView: WKWebView, statusCode: Int?) {
        guard mainWebView === webView else { return }
        mainFrameHTTPStatus = statusCode
    }

    func navigationCommitted(in webView: WKWebView) {
        guard mainWebView === webView else { return }
        mainFrameLoadPhase = .committed
    }

    func navigationFinished(in webView: WKWebView) {
        guard mainWebView === webView else { return }
        mainFrameLoadPhase = .finished
    }

    func navigationFailed(in webView: WKWebView, error: NSError) {
        guard mainWebView === webView else { return }
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            mainFrameLoadPhase = .cancelled
        } else if error.domain == "WebKitErrorDomain" && error.code == 102 {
            mainFrameLoadPhase = .policyInterrupted
        } else {
            mainFrameLoadPhase = .failed
        }
        // Domain and numeric code identify a WebKit/URL-loading failure without
        // retaining request URLs, response bodies, cookies, or credentials.
        mainFrameErrorCode = "\(error.domain) \(error.code)"
    }

    func webContentStopped(in webView: WKWebView) {
        guard mainWebView === webView else { return }
        mainFrameLoadPhase = .processTerminated
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    func resetPageState() {
        host = nil
        pageURL = nil
        title = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        errorMessage = nil
        mainFrameLoadPhase = .notStarted
        mainFrameHTTPStatus = nil
        mainFrameErrorCode = nil
        appPolicyRejection = nil
    }

    func goBack() {
        if popup != nil {
            closePopup()
        } else if mainWebView?.canGoBack == true {
            mainWebView?.goBack()
        }
    }

    func goForward() {
        mainWebView?.goForward()
    }

    func reload() {
        clearError()
        clearAppPolicyRejection()
        mainWebView?.reload()
    }

    func toggleDesktopSite(homeURL: URL) {
        prefersDesktopSite.toggle()
        goHome(homeURL)
    }

    func togglePageFit() {
        fitsMoreOfPage.toggle()
    }

    func applyContentMode(to preferences: WKWebpagePreferences) {
        preferences.preferredContentMode = prefersDesktopSite ? .desktop : .recommended
    }

    func goHome(_ url: URL) {
        closePopup()
        clearError()
        clearAppPolicyRejection()
        mainWebView?.load(URLRequest(url: url))
    }

    func suspendMedia() {
        guard !mediaIsSuspended else { return }
        mediaIsSuspended = true
        // Suspended pages cannot restart playback while they are inactive.
        // Native media presentations can live outside the web view's hierarchy.
        mainWebView?.pauseAllMediaPlayback(completionHandler: nil)
        mainWebView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        mainWebView?.closeAllMediaPresentations(completionHandler: nil)
        popup?.webView.pauseAllMediaPlayback(completionHandler: nil)
        popup?.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        popup?.webView.closeAllMediaPresentations(completionHandler: nil)
    }

    func resumeMedia() {
        guard mediaIsSuspended else { return }
        mediaIsSuspended = false
        mainWebView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        popup?.webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    func openPopup(_ webView: WKWebView) -> Bool {
        guard popup == nil else {
            showError("Close the open website window before opening another.")
            return false
        }
        popupHost = webView.url?.host
        popup = SocialBrowserPopup(webView: webView)
        if mediaIsSuspended {
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        return true
    }

    func closePopup() {
        guard let popup else { return }
        popup.webView.pauseAllMediaPlayback(completionHandler: nil)
        popup.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        popup.webView.closeAllMediaPresentations(completionHandler: nil)
        popup.webView.stopLoading()
        popup.webView.navigationDelegate = nil
        popup.webView.uiDelegate = nil
        self.popup = nil
        popupHost = nil
    }
}

struct SocialBrowserPopup: Identifiable {
    let id = UUID()
    let webView: WKWebView
}
