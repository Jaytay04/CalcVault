import XCTest

final class SyntheticNativeGuestUITests: XCTestCase {
    func testGuestControlsAndHostFileBoundary() {
        let host = XCUIApplication(bundleIdentifier: "com.kdt.livecontainer.AAAAA11111")
        host.launchEnvironment["LC_SYNTHETIC_GUEST_TEST"] = "1"
        host.launch()

        let tapButton = host.buttons["syntheticTapButton"]
        guard tapButton.waitForExistence(timeout: 30) else {
            XCTFail("Synthetic guest tap button did not appear")
            return
        }
        tapButton.tap()
        XCTAssertEqual(host.staticTexts["syntheticTapCount"].label, "Taps: 1")

        host.buttons["syntheticCanaryButton"].tap()
        XCTAssertEqual(host.staticTexts["syntheticCanaryStatus"].label, "Canary round trip passed")

        host.buttons["syntheticHostFileButton"].tap()
        XCTAssertEqual(
            host.staticTexts["syntheticHostFileStatus"].label,
            "Host file inaccessible to guest",
            "A readable synthetic host file disproves the proposed file boundary."
        )
    }
}
