import UIKit
import XCTest
@testable import CalcVault

@MainActor
final class SocialMediaLifecycleObserverTests: XCTestCase {
    func testResigningActivePausesMedia() {
        let notificationCenter = NotificationCenter()
        var pauseCount = 0
        let observer = SocialMediaLifecycleObserver(notificationCenter: notificationCenter) {
            pauseCount += 1
        }
        observer.start()

        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)

        XCTAssertEqual(pauseCount, 1)
        observer.stop()
    }

    func testEnteringBackgroundPausesMedia() {
        let notificationCenter = NotificationCenter()
        var pauseCount = 0
        let observer = SocialMediaLifecycleObserver(notificationCenter: notificationCenter) {
            pauseCount += 1
        }
        observer.start()

        notificationCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(pauseCount, 1)
        observer.stop()
    }

    func testStartIsIdempotentAndStopRemovesObservers() {
        let notificationCenter = NotificationCenter()
        var pauseCount = 0
        let observer = SocialMediaLifecycleObserver(notificationCenter: notificationCenter) {
            pauseCount += 1
        }
        observer.start()
        observer.start()

        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        observer.stop()
        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)

        XCTAssertEqual(pauseCount, 1)
    }
}
