import UIKit
import XCTest
@testable import CalcVault

@MainActor
final class PrivacyShieldControllerTests: XCTestCase {
    func testLayoutIsAStaticGenericCalculatorFixture() {
        XCTAssertEqual(PrivacyShieldCalculatorLayout.displayText, "0")
        XCTAssertEqual(PrivacyShieldCalculatorLayout.keyRows.count, 5)
        XCTAssertEqual(PrivacyShieldCalculatorLayout.keyRows.map(\.count), [4, 4, 4, 4, 4])
        XCTAssertEqual(PrivacyShieldCalculatorLayout.keyRows.flatMap { $0 }.count, 20)
        XCTAssertFalse(PrivacyShieldCalculatorLayout.keyRows.flatMap { $0 }.contains("Calculator"))
    }

    func testCoverIsOpaqueNonInteractiveAndAccessibleAsCalculator() {
        let controller = PrivacyShieldController()
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let cover = controller.makeCoverForTesting(frame: frame)

        XCTAssertEqual(cover.frame, frame)
        XCTAssertEqual(cover.backgroundColor, .systemBackground)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.autoresizingMask, [.flexibleWidth, .flexibleHeight])
        XCTAssertFalse(cover.isUserInteractionEnabled)
        XCTAssertTrue(cover.isAccessibilityElement)
        XCTAssertEqual(cover.accessibilityLabel, "Calculator")
        XCTAssertEqual(cover.accessibilityTraits, [.staticText])
    }

    func testCoverContainsOnlyStaticFixtureLabels() {
        let controller = PrivacyShieldController()
        let cover = controller.makeCoverForTesting(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let labels = labels(in: cover)

        XCTAssertTrue(labels.contains("Calculator"))
        XCTAssertTrue(labels.contains("0"))
        XCTAssertTrue(PrivacyShieldCalculatorLayout.keyRows.flatMap { $0 }.allSatisfy(labels.contains))
    }

    private func labels(in view: UIView) -> Set<String> {
        var result = Set<String>()
        if let label = view as? UILabel, let text = label.text {
            result.insert(text)
        }
        for subview in view.subviews {
            result.formUnion(labels(in: subview))
        }
        return result
    }
}
