import XCTest
@testable import CalcVault

final class SocialDownloadPolicyTests: XCTestCase {
    func testOnlyKnownPostPagesAreSuggested() {
        XCTAssertEqual(
            SocialDownloadPolicy.postURL(
                URL(string: "https://www.tiktok.com/@creator/video/123?tracking=1"), service: .tikTok
            )?.absoluteString,
            "https://www.tiktok.com/@creator/video/123"
        )
        XCTAssertNotNil(SocialDownloadPolicy.postURL(
            URL(string: "https://x.com/creator/status/123"), service: .x
        ))
        XCTAssertNotNil(SocialDownloadPolicy.postURL(
            URL(string: "https://www.instagram.com/reel/ABC/"), service: .instagram
        ))
        XCTAssertEqual(
            SocialDownloadPolicy.postURL(
                URL(string: "https://www.instagram.com/stories/creator/123456789/?igsh=tracking"),
                service: .instagram
            )?.absoluteString,
            "https://www.instagram.com/stories/creator/123456789/"
        )
        XCTAssertNotNil(SocialDownloadPolicy.postURL(
            URL(string: "https://www.tiktok.com/@creator/story/123456789"), service: .tikTok
        ))
        XCTAssertNil(SocialDownloadPolicy.postURL(URL(string: "https://x.com/home"), service: .x))
        XCTAssertNil(SocialDownloadPolicy.postURL(
            URL(string: "https://www.instagram.com/stories/creator/"), service: .instagram
        ))
        XCTAssertNil(SocialDownloadPolicy.postURL(
            URL(string: "https://x.com.evil.example/creator/status/123"), service: .x
        ))
        XCTAssertNil(SocialDownloadPolicy.postURL(
            URL(string: "http://x.com/creator/status/123"), service: .x
        ))
    }

    func testProviderHostsAreExact() {
        XCTAssertEqual(
            SocialDownloadPolicy.providerURL(for: .instagram).absoluteString,
            "https://fastdl.app/en5IW"
        )
        XCTAssertTrue(SocialDownloadPolicy.isProviderPage(
            URL(string: "https://fastdl.app/en5IW")!, service: .instagram
        ))
        XCTAssertTrue(SocialDownloadPolicy.isProviderPage(
            URL(string: "https://ssstwitter.com/" )!, service: .x
        ))
        XCTAssertFalse(SocialDownloadPolicy.isProviderPage(
            URL(string: "https://ssstwitter.com.evil.example/" )!, service: .x
        ))
    }

    func testOnlyMediaFilesAreAccepted() {
        XCTAssertNotNil(SocialDownloadPolicy.mediaType(suggestedFilename: "sample.mp4", mimeType: "video/mp4"))
        XCTAssertNotNil(SocialDownloadPolicy.mediaType(suggestedFilename: "sample.jpg", mimeType: "image/jpeg"))
        XCTAssertNil(SocialDownloadPolicy.mediaType(suggestedFilename: "index.html", mimeType: "text/html"))
        XCTAssertNil(SocialDownloadPolicy.mediaType(suggestedFilename: "photo.jpg", mimeType: "text/html"))
        XCTAssertNil(SocialDownloadPolicy.mediaType(suggestedFilename: "drawing.svg", mimeType: "image/svg+xml"))
    }
}
