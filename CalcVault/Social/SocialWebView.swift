import SwiftUI
import WebKit

/// A WebKit wrapper with native navigation and no JavaScript-to-native bridge.
@available(iOS 17.0, *)
struct SocialWebView: UIViewRepresentable {
    let service: SocialService
    let persistence: BrowserPersistenceMode
    let browser: SocialBrowserState
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeUIView(context: Context) -> SocialWebViewport {
        let configuration = BrowserProfileStore().configuration(for: service, persistence: persistence)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = SocialPageLayout.zoom(
            for: service,
            prefersDesktopSite: browser.prefersDesktopSite,
            fitsMore: browser.fitsMoreOfPage
        )
        let viewport = SocialWebViewport(webView: webView)
        viewport.fitsDesktopPage = SocialPageLayout.usesWideViewport(
            for: service,
            prefersDesktopSite: browser.prefersDesktopSite,
            fitsMore: browser.fitsMoreOfPage
        )
        context.coordinator.attach(to: webView)
        if isActive { browser.resumeMedia() } else { browser.suspendMedia() }
        webView.load(URLRequest(url: service.officialURL))
        return viewport
    }

    func updateUIView(_ viewport: SocialWebViewport, context: Context) {
        let webView = viewport.webView
        if isActive { browser.resumeMedia() } else { browser.suspendMedia() }
        let zoom = SocialPageLayout.zoom(
            for: service,
            prefersDesktopSite: browser.prefersDesktopSite,
            fitsMore: browser.fitsMoreOfPage
        )
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        viewport.fitsDesktopPage = SocialPageLayout.usesWideViewport(
            for: service,
            prefersDesktopSite: browser.prefersDesktopSite,
            fitsMore: browser.fitsMoreOfPage
        )
    }

    static func dismantleUIView(_ viewport: SocialWebViewport, coordinator: Coordinator) {
        let webView = viewport.webView
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        private var mediaLifecycleObserver: SocialMediaLifecycleObserver?
        private var backObservation: NSKeyValueObservation?
        private var forwardObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private let browser: SocialBrowserState

        init(browser: SocialBrowserState) {
            self.browser = browser
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            browser.attach(webView)
            backObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let webView = self.webView else { return }
                    self.browser.refresh(from: webView)
                }
            }
            forwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let webView = self.webView else { return }
                    self.browser.refresh(from: webView)
                }
            }
            urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let webView = self.webView else { return }
                    self.browser.refresh(from: webView)
                }
            }
            let observer = SocialMediaLifecycleObserver { [weak browser] in
                browser?.suspendMedia()
            }
            observer.start()
            mediaLifecycleObserver = observer
        }

        func detach() {
            backObservation?.invalidate()
            backObservation = nil
            forwardObservation?.invalidate()
            forwardObservation = nil
            urlObservation?.invalidate()
            urlObservation = nil
            mediaLifecycleObserver?.stop()
            mediaLifecycleObserver = nil
            if let webView { browser.detach(webView) }
            webView = nil
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            if let url = navigationAction.request.url,
               SocialNavigationPolicy.isAppStoreDestination(url) {
                browser.recordAppPolicyRejection(in: webView, reason: "App Store destination")
                browser.showError("This website action leads to the App Store. The service may not offer it on its mobile website.")
                decisionHandler(.cancel, preferences)
                return
            }
            guard let url = navigationAction.request.url,
                  (SocialNavigationPolicy.permitsEmbeddedLoad(url)
                    || (browser.popup?.webView === webView && url.absoluteString == "about:blank")) else {
                let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "missing URL"
                browser.recordAppPolicyRejection(in: webView, reason: "unsupported \(scheme) navigation")
                browser.showError("This destination cannot open inside the browser.")
                decisionHandler(.cancel, preferences)
                return
            }
            browser.clearError()
            browser.applyContentMode(to: preferences)
            decisionHandler(.allow, preferences)
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            browser.navigationStarted(in: webView)
            report(webView)
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                browser.mainFrameResponse(
                    in: webView,
                    statusCode: (navigationResponse.response as? HTTPURLResponse)?.statusCode
                )
            }
            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            browser.navigationCommitted(in: webView)
            report(webView)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            browser.navigationFinished(in: webView)
            report(webView)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            browser.webContentStopped(in: webView)
            browser.showError("The website stopped responding. Reload to try again.")
            report(webView)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            browser.navigationFailed(in: webView, error: error as NSError)
            reportError(error)
            report(webView)
        }

        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            browser.navigationFailed(in: webView, error: error as NSError)
            reportError(error)
            report(webView)
        }

        /// WebKit loads the original navigation in this bounded child window. Returning
        /// a real view preserves the website's window handle and request semantics.
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               SocialNavigationPolicy.isAppStoreDestination(url) {
                browser.recordAppPolicyRejection(in: webView, reason: "App Store new window")
                browser.showError("This website action leads to the App Store. The service may not offer it on its mobile website.")
                return nil
            }
            guard let url = navigationAction.request.url,
                  SocialNavigationPolicy.permitsPopupBootstrap(url) else {
                let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "missing URL"
                browser.recordAppPolicyRejection(in: webView, reason: "unsupported \(scheme) new window")
                browser.showError("This destination cannot open inside the browser.")
                return nil
            }
            let child = WKWebView(frame: .zero, configuration: configuration)
            child.navigationDelegate = self
            child.uiDelegate = self
            child.allowsBackForwardNavigationGestures = true
            guard browser.openPopup(child) else { return nil }
            return child
        }

        public func webViewDidClose(_ webView: WKWebView) {
            if browser.popup?.webView === webView {
                browser.closePopup()
            }
        }

        public func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        public func webView(
            _ webView: WKWebView,
            requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        private func report(_ webView: WKWebView) {
            browser.refresh(from: webView)
        }

        private func reportError(_ error: Error) {
            let nsError = error as NSError
            guard SocialNavigationErrorPolicy.shouldReport(
                nsError,
                hasExistingMessage: browser.errorMessage != nil
            ) else {
                return
            }
            browser.showError(error.localizedDescription)
        }
    }
}

/// An opt-in wider UIKit viewport fits more of TikTok's desktop page without
/// changing its website mode, session, or DOM. Other profiles are unaffected.
enum SocialPageLayout {
    static let desktopViewportWidth: CGFloat = 980

    static func zoom(for service: SocialService, prefersDesktopSite: Bool, fitsMore: Bool = false) -> CGFloat {
        service == .tikTok && prefersDesktopSite ? (fitsMore ? 1.0 : 0.85) : 1.0
    }

    static func usesWideViewport(for service: SocialService, prefersDesktopSite: Bool, fitsMore: Bool) -> Bool {
        service == .tikTok && prefersDesktopSite && fitsMore
    }

    static func viewportScale(for availableWidth: CGFloat, fitsDesktopPage: Bool) -> CGFloat {
        guard fitsDesktopPage, availableWidth > 0 else { return 1.0 }
        return min(1.0, availableWidth / desktopViewportWidth)
    }
}

/// Enlarges only the WebKit viewport, then scales the entire interactive view
/// back into the phone. Fixed website overlays share that wider viewport.
final class SocialWebViewport: UIView {
    let webView: WKWebView
    var fitsDesktopPage = false {
        didSet { if fitsDesktopPage != oldValue { setNeedsLayout() } }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = SocialPageLayout.viewportScale(for: bounds.width, fitsDesktopPage: fitsDesktopPage)
        let virtualSize = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        webView.transform = .identity
        webView.bounds = CGRect(origin: .zero, size: virtualSize)
        webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// Hosts a WebKit-created window without reconstructing its original request.
struct SocialPopupWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
