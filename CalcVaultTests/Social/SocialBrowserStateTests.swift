import WebKit
import XCTest
@testable import CalcVault

@MainActor
final class SocialBrowserStateTests: XCTestCase {
    func testNativeBackAvailabilityFollowsLocalWebViewHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialNavigationTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.html")
        let secondURL = directory.appendingPathComponent("second.html")
        try Data("<html><title>First</title></html>".utf8).write(to: firstURL)
        try Data("<html><title>Second</title></html>".utf8).write(to: secondURL)

        let browser = SocialBrowserState(service: .x)
        let coordinator = SocialWebView.Coordinator(browser: browser)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let delegate = SyntheticNavigationDelegate()
        webView.navigationDelegate = delegate
        coordinator.attach(to: webView)

        let firstLoaded = expectation(description: "first synthetic page loaded")
        delegate.nextFinish = firstLoaded
        webView.loadFileURL(firstURL, allowingReadAccessTo: directory)
        await fulfillment(of: [firstLoaded], timeout: 15)

        let secondLoaded = expectation(description: "second synthetic page loaded")
        delegate.nextFinish = secondLoaded
        webView.loadFileURL(secondURL, allowingReadAccessTo: directory)
        await fulfillment(of: [secondLoaded], timeout: 15)

        for _ in 0..<50 where !browser.canGoBack {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(webView.canGoBack)
        XCTAssertTrue(browser.canGoBack)
        coordinator.detach()
        webView.navigationDelegate = nil
    }

    func testProfilesLoadOnFirstSelectionAndRemainMountedAfterSwitchingAway() {
        var activation = SocialProfileActivation()
        activation.observe(selectedService: .tikTok, isWorkspaceActive: false)
        XCTAssertTrue(activation.mountedServices.isEmpty)
        XCTAssertFalse(activation.shouldMount(.x, selectedService: .tikTok, isWorkspaceActive: false))

        // The selected profile mounts immediately, before the state observer runs.
        XCTAssertTrue(activation.shouldMount(.tikTok, selectedService: .tikTok, isWorkspaceActive: true))
        XCTAssertFalse(activation.shouldMount(.x, selectedService: .tikTok, isWorkspaceActive: true))
        activation.observe(selectedService: .tikTok, isWorkspaceActive: true)
        activation.observe(selectedService: .x, isWorkspaceActive: true)

        XCTAssertTrue(activation.shouldMount(.tikTok, selectedService: .x, isWorkspaceActive: true))
        XCTAssertTrue(activation.shouldMount(.x, selectedService: .x, isWorkspaceActive: true))
        XCTAssertFalse(activation.shouldMount(.instagram, selectedService: .x, isWorkspaceActive: true))
        XCTAssertEqual(activation.mountedServices, [.tikTok, .x])

        activation.observe(selectedService: .x, isWorkspaceActive: false)
        XCTAssertEqual(activation.mountedServices, [.tikTok, .x])
    }

    func testBrowserChoicesAreIndependentByService() {
        let suiteName = "SocialProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(BrowserProfilePreferences.hasChoice(for: .tikTok, defaults: defaults))
        XCTAssertEqual(BrowserProfilePreferences.mode(for: .tikTok, defaults: defaults), .remembered)
        BrowserProfilePreferences.setMode(.ephemeral, for: .tikTok, defaults: defaults)
        XCTAssertTrue(BrowserProfilePreferences.hasChoice(for: .tikTok, defaults: defaults))
        XCTAssertEqual(BrowserProfilePreferences.mode(for: .tikTok, defaults: defaults), .ephemeral)
        XCTAssertEqual(BrowserProfilePreferences.mode(for: .x, defaults: defaults), .remembered)
    }

    func testEmbeddedNavigationRejectsNonHTTPSAndPopupAllowsOnlyBlankBootstrap() {
        XCTAssertTrue(SocialNavigationPolicy.permitsEmbeddedLoad(URL(string: "https://www.tiktok.com/search")!))
        XCTAssertFalse(SocialNavigationPolicy.permitsEmbeddedLoad(URL(string: "http://www.tiktok.com/")!))
        XCTAssertFalse(SocialNavigationPolicy.permitsEmbeddedLoad(URL(string: "file:///private/test")!))
        XCTAssertFalse(SocialNavigationPolicy.permitsEmbeddedLoad(URL(string: "about:blank")!))
        XCTAssertFalse(SocialNavigationPolicy.permitsEmbeddedLoad(URL(string: "x-safari-https://x.com/")!))
        XCTAssertTrue(SocialNavigationPolicy.permitsPopupBootstrap(URL(string: "about:blank")!))
    }

    func testAppStoreDestinationsAreNotEmbeddedOrOpenedAsPopups() {
        for destination in [
            "https://apps.apple.com/us/app/example/id123456789",
            "https://itunes.apple.com/us/app/example/id123456789",
            "itms-apps://itunes.apple.com/us/app/example/id123456789"
        ] {
            let url = URL(string: destination)!
            XCTAssertTrue(SocialNavigationPolicy.isAppStoreDestination(url))
            XCTAssertFalse(SocialNavigationPolicy.permitsEmbeddedLoad(url))
            XCTAssertFalse(SocialNavigationPolicy.permitsPopupBootstrap(url))
        }
        let deceptiveHost = URL(string: "https://apps.apple.com.example.org/")!
        XCTAssertFalse(SocialNavigationPolicy.isAppStoreDestination(deceptiveHost))
        XCTAssertTrue(SocialNavigationPolicy.permitsEmbeddedLoad(deceptiveHost))
    }

    func testPolicyInterruptionDoesNotReplaceExistingNavigationMessage() {
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        XCTAssertFalse(SocialNavigationErrorPolicy.shouldReport(interrupted, hasExistingMessage: true))
        XCTAssertTrue(SocialNavigationErrorPolicy.shouldReport(interrupted, hasExistingMessage: false))

        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(SocialNavigationErrorPolicy.shouldReport(cancelled, hasExistingMessage: false))

        let unrelated = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertTrue(SocialNavigationErrorPolicy.shouldReport(unrelated, hasExistingMessage: true))
    }

    func testOnlyOneWebsitePopupCanBeOpenAndClosingReleasesIt() {
        let browser = SocialBrowserState()
        let first = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let second = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertTrue(browser.openPopup(first))
        XCTAssertTrue(browser.popup?.webView === first)
        XCTAssertFalse(browser.openPopup(second))
        XCTAssertTrue(browser.popup?.webView === first)

        browser.closePopup()

        XCTAssertNil(browser.popup)
        XCTAssertTrue(browser.openPopup(second))
        browser.closePopup()
    }

    func testDesktopRequestChangesOnlyWebpagePreferences() {
        let browser = SocialBrowserState()
        let preferences = WKWebpagePreferences()
        browser.applyContentMode(to: preferences)
        XCTAssertEqual(preferences.preferredContentMode, .recommended)

        browser.toggleDesktopSite(homeURL: SocialService.x.officialURL)
        browser.applyContentMode(to: preferences)
        XCTAssertEqual(preferences.preferredContentMode, .desktop)

        browser.toggleDesktopSite(homeURL: SocialService.x.officialURL)
        browser.applyContentMode(to: preferences)
        XCTAssertEqual(preferences.preferredContentMode, .recommended)
    }

    func testTikTokAndXStartInDesktopModeButCanUseMobileMode() {
        for service in [SocialService.tikTok, .x] {
            let browser = SocialBrowserState(service: service)
            let preferences = WKWebpagePreferences()
            browser.applyContentMode(to: preferences)
            XCTAssertEqual(preferences.preferredContentMode, .desktop)

            browser.toggleDesktopSite(homeURL: service.officialURL)
            browser.applyContentMode(to: preferences)
            XCTAssertEqual(preferences.preferredContentMode, .recommended)
        }

        let instagram = SocialBrowserState(service: .instagram)
        let preferences = WKWebpagePreferences()
        instagram.applyContentMode(to: preferences)
        XCTAssertEqual(preferences.preferredContentMode, .recommended)
    }

    func testInactiveBrowserRemainsSuspendedUntilReactivated() {
        let browser = SocialBrowserState(service: .tikTok)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browser.attach(webView)

        browser.suspendMedia()
        XCTAssertTrue(browser.mediaIsSuspended)
        browser.suspendMedia()
        XCTAssertTrue(browser.mediaIsSuspended)

        browser.resumeMedia()
        XCTAssertFalse(browser.mediaIsSuspended)
        browser.detach(webView)
    }

    func testTikTokInlineVideoStillRequiresUserAction() {
        let configuration = BrowserProfileStore().configuration(for: .tikTok, persistence: .ephemeral)
        XCTAssertTrue(configuration.allowsInlineMediaPlayback)
        XCTAssertTrue(configuration.preferences.isElementFullscreenEnabled)
        XCTAssertTrue(configuration.mediaTypesRequiringUserActionForPlayback.contains(.video))
        XCTAssertTrue(configuration.mediaTypesRequiringUserActionForPlayback.contains(.audio))
        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].isForMainFrameOnly)
        XCTAssertEqual(scripts[0].injectionTime, .atDocumentEnd)
        XCTAssertTrue(scripts[0].source.contains("video.webkitEnterFullscreen()"))
        XCTAssertTrue(scripts[0].source.contains("button.addEventListener('click'"))

        let instagram = BrowserProfileStore().configuration(for: .instagram, persistence: .ephemeral)
        XCTAssertFalse(instagram.preferences.isElementFullscreenEnabled)
        XCTAssertTrue(instagram.userContentController.userScripts.isEmpty)
        let x = BrowserProfileStore().configuration(for: .x, persistence: .ephemeral)
        XCTAssertTrue(x.allowsInlineMediaPlayback)
        XCTAssertFalse(x.mediaTypesRequiringUserActionForPlayback.contains(.video))
        XCTAssertTrue(x.mediaTypesRequiringUserActionForPlayback.contains(.audio))
        XCTAssertTrue(x.userContentController.userScripts.isEmpty)
    }

    func testOnlyTikTokDesktopPageUsesFittedZoom() {
        XCTAssertEqual(SocialPageLayout.zoom(for: .tikTok, prefersDesktopSite: true), 0.85)
        XCTAssertEqual(SocialPageLayout.zoom(for: .tikTok, prefersDesktopSite: true, fitsMore: true), 1.0)
        XCTAssertEqual(SocialPageLayout.zoom(for: .tikTok, prefersDesktopSite: false), 1.0)
        XCTAssertEqual(SocialPageLayout.zoom(for: .tikTok, prefersDesktopSite: false, fitsMore: true), 1.0)
        XCTAssertEqual(SocialPageLayout.zoom(for: .x, prefersDesktopSite: true), 1.0)
        XCTAssertEqual(SocialPageLayout.zoom(for: .instagram, prefersDesktopSite: true), 1.0)
        XCTAssertTrue(SocialPageLayout.usesWideViewport(for: .tikTok, prefersDesktopSite: true, fitsMore: true))
        XCTAssertFalse(SocialPageLayout.usesWideViewport(for: .tikTok, prefersDesktopSite: false, fitsMore: true))
        XCTAssertFalse(SocialPageLayout.usesWideViewport(for: .x, prefersDesktopSite: true, fitsMore: true))
        XCTAssertEqual(SocialPageLayout.viewportScale(for: 393, fitsDesktopPage: true), 393.0 / 980.0)
        XCTAssertEqual(SocialPageLayout.viewportScale(for: 393, fitsDesktopPage: false), 1.0)
        XCTAssertEqual(SocialPageLayout.viewportScale(for: 0, fitsDesktopPage: true), 1.0)

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let viewport = SocialWebViewport(webView: webView)
        viewport.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        viewport.fitsDesktopPage = true
        viewport.layoutIfNeeded()
        XCTAssertTrue(viewport.webView === webView)
        XCTAssertEqual(viewport.webView.bounds.width, 980, accuracy: 0.5)
        XCTAssertEqual(viewport.webView.frame.width, 393, accuracy: 0.5)
        viewport.fitsDesktopPage = false
        viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.webView.bounds.width, 393, accuracy: 0.5)

        let browser = SocialBrowserState(service: .tikTok)
        XCTAssertFalse(browser.fitsMoreOfPage)
        browser.togglePageFit()
        XCTAssertTrue(browser.fitsMoreOfPage)

        let script = TikTokFullscreenControl.source
        XCTAssertTrue(script.contains("videoRect.bottom - controlRect.height"))
        XCTAssertFalse(script.contains("bottom:92px"))
    }

    func testMainFrameLoadStatusIgnoresOtherWebViewsAndResets() {
        let browser = SocialBrowserState()
        let main = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let unrelated = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browser.attach(main)

        browser.navigationStarted(in: unrelated)
        XCTAssertEqual(browser.mainFrameLoadPhase, .notStarted)
        browser.recordAppPolicyRejection(in: unrelated, reason: "unsupported about navigation")
        XCTAssertEqual(browser.appPolicySummary, "App policy: no rejection observed")

        browser.navigationStarted(in: main)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Connecting")
        browser.mainFrameResponse(in: unrelated, statusCode: 403)
        XCTAssertNil(browser.mainFrameHTTPStatus)
        browser.mainFrameResponse(in: main, statusCode: 200)
        browser.navigationCommitted(in: main)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Receiving page · HTTP 200")
        browser.navigationFinished(in: main)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Navigation finished · HTTP 200")

        browser.navigationStarted(in: main)
        XCTAssertNil(browser.mainFrameHTTPStatus)
        browser.navigationFailed(
            in: main,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        XCTAssertEqual(browser.mainFrameLoadPhase, .cancelled)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Navigation cancelled · NSURLErrorDomain -999")

        browser.navigationFailed(in: main, error: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertEqual(browser.mainFrameLoadPhase, .policyInterrupted)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Policy interrupted · WebKitErrorDomain 102")

        browser.navigationFailed(in: main, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertEqual(browser.mainFrameLoadPhase, .failed)
        XCTAssertEqual(browser.mainFrameLoadSummary, "X page: Navigation failed · NSURLErrorDomain -1001")

        browser.recordAppPolicyRejection(in: main, reason: "unsupported about navigation")
        XCTAssertEqual(browser.appPolicySummary, "App policy: unsupported about navigation")
        browser.navigationStarted(in: main)
        XCTAssertEqual(browser.appPolicySummary, "App policy: unsupported about navigation")
        browser.clearAppPolicyRejection()
        XCTAssertEqual(browser.appPolicySummary, "App policy: no rejection observed")

        browser.resetPageState()
        XCTAssertEqual(browser.mainFrameLoadPhase, .notStarted)
        XCTAssertNil(browser.mainFrameHTTPStatus)
        XCTAssertNil(browser.mainFrameErrorCode)
        browser.detach(main)
    }

    func testClearAllRememberedProfilesWithDisposableCookies() async throws {
        let fixtureIdentifiers = Dictionary(
            uniqueKeysWithValues: SocialService.allCases.map { ($0, UUID()) }
        )
        let profiles = BrowserProfileStore(fixtureIdentifiers: fixtureIdentifiers)
        let fixtureName = "clear-all-fixture-\(UUID().uuidString)"
        let unrelatedStore = WKWebsiteDataStore(forIdentifier: UUID())
        let unrelatedCookie = try XCTUnwrap(fixtureCookie(named: fixtureName))

        for service in SocialService.allCases {
            let store = profiles.configuration(for: service, persistence: .remembered).websiteDataStore
            let cookie = try XCTUnwrap(fixtureCookie(named: fixtureName))
            await store.httpCookieStore.setCookie(cookie)
            let storedCookies = await store.httpCookieStore.allCookies()
            XCTAssertTrue(storedCookies.contains { $0.name == fixtureName })
        }
        await unrelatedStore.httpCookieStore.setCookie(unrelatedCookie)

        // The UI's clear-all action invokes this operation once per service.
        for service in SocialService.allCases {
            await profiles.clearRememberedData(for: service)
        }

        for service in SocialService.allCases {
            let store = profiles.configuration(for: service, persistence: .remembered).websiteDataStore
            let storedCookies = await store.httpCookieStore.allCookies()
            XCTAssertFalse(storedCookies.contains { $0.name == fixtureName })
        }
        let unrelatedCookies = await unrelatedStore.httpCookieStore.allCookies()
        XCTAssertTrue(unrelatedCookies.contains { $0.name == fixtureName })
        await unrelatedStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    private func fixtureCookie(named name: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: "fixture.invalid",
            .path: "/",
            .name: name,
            .value: "synthetic",
            .expires: Date().addingTimeInterval(3_600)
        ])
    }

}

@MainActor
private final class SyntheticNavigationDelegate: NSObject, WKNavigationDelegate {
    var nextFinish: XCTestExpectation?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        nextFinish?.fulfill()
        nextFinish = nil
    }
}
