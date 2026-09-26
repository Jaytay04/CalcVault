import UIKit

/// Static, non-functional content used while the app is inactive. Keeping the
/// layout data separate makes it harder for the privacy cover to accidentally
/// display live calculator state.
struct PrivacyShieldCalculatorLayout {
    static let displayText = "0"

    static let keyRows = [
        ["AC", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["⌫", "0", ".", "="]
    ]
}

/// Installs an opaque calculator-style cover synchronously from UIKit
/// lifecycle callbacks. This protects app-switcher/background captures; it is
/// not a claim of screenshot prevention or forensic invisibility.
@MainActor
public final class PrivacyShieldController {
    private static let coverIdentifier = "CalcVault.PrivacyShieldController.cover"

    public init() {}

    /// Call from `applicationWillResignActive` before the system can capture a
    /// background representation.
    public func coverImmediately() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where shouldCover(window) {
                if findCover(in: window) == nil {
                    let cover = makeCover(frame: window.bounds)
                    window.addSubview(cover)
                } else if let cover = findCover(in: window) {
                    window.bringSubviewToFront(cover)
                }
            }
        }
    }

    /// Removes only covers created by this controller. The app coordinator
    /// decides whether revealing private UI is currently authorized.
    public func revealImmediately() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                findCover(in: window)?.removeFromSuperview()
            }
        }
    }

    private func findCover(in window: UIWindow) -> UIView? {
        window.subviews.first { $0.accessibilityIdentifier == Self.coverIdentifier }
    }

    private func shouldCover(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0 && window.rootViewController != nil
    }

    private func makeCover(frame: CGRect) -> UIView {
        let cover = UIView(frame: frame)
        cover.backgroundColor = .systemBackground
        cover.isOpaque = true
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.accessibilityIdentifier = Self.coverIdentifier
        cover.isAccessibilityElement = true
        cover.accessibilityLabel = "Calculator"
        cover.accessibilityTraits = [.staticText]

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isAccessibilityElement = false
        cover.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cover.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: cover.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: cover.safeAreaLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: cover.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Calculator"
        title.font = .systemFont(ofSize: 20, weight: .medium)
        title.textColor = .secondaryLabel
        title.textAlignment = .center
        title.isAccessibilityElement = false

        let display = UILabel()
        display.translatesAutoresizingMaskIntoConstraints = false
        display.text = PrivacyShieldCalculatorLayout.displayText
        display.font = .monospacedDigitSystemFont(ofSize: 56, weight: .regular)
        display.textColor = .label
        display.textAlignment = .right
        display.minimumScaleFactor = 0.6
        display.adjustsFontSizeToFitWidth = true
        display.isAccessibilityElement = false

        let keypad = UIStackView()
        keypad.translatesAutoresizingMaskIntoConstraints = false
        keypad.axis = .vertical
        keypad.alignment = .fill
        keypad.distribution = .fillEqually
        keypad.spacing = 6
        keypad.isAccessibilityElement = false

        for row in PrivacyShieldCalculatorLayout.keyRows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.alignment = .fill
            rowStack.distribution = .fillEqually
            rowStack.spacing = 8
            rowStack.isAccessibilityElement = false
            rowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

            for key in row {
                let keyView = UIView()
                keyView.backgroundColor = key == "÷" || key == "×" || key == "−" || key == "+" || key == "="
                    ? .systemOrange
                    : .secondarySystemBackground
                keyView.layer.cornerRadius = 12
                keyView.isAccessibilityElement = false

                let keyLabel = UILabel()
                keyLabel.translatesAutoresizingMaskIntoConstraints = false
                keyLabel.text = key
                keyLabel.font = .systemFont(ofSize: 22, weight: .regular)
                keyLabel.textColor = key == "÷" || key == "×" || key == "−" || key == "+" || key == "="
                    ? .white
                    : .label
                keyLabel.textAlignment = .center
                keyLabel.isAccessibilityElement = false
                keyView.addSubview(keyLabel)
                NSLayoutConstraint.activate([
                    keyLabel.leadingAnchor.constraint(equalTo: keyView.leadingAnchor, constant: 4),
                    keyLabel.trailingAnchor.constraint(equalTo: keyView.trailingAnchor, constant: -4),
                    keyLabel.centerYAnchor.constraint(equalTo: keyView.centerYAnchor)
                ])

                rowStack.addArrangedSubview(keyView)
            }
            keypad.addArrangedSubview(rowStack)
        }

        content.addSubview(title)
        content.addSubview(display)
        content.addSubview(keypad)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            title.heightAnchor.constraint(equalToConstant: 24),

            display.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            display.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            display.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            display.heightAnchor.constraint(equalToConstant: 64),

            keypad.topAnchor.constraint(equalTo: display.bottomAnchor, constant: 12),
            keypad.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            keypad.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            keypad.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            keypad.heightAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
        return cover
    }

    #if DEBUG
    /// Test-only access to the synchronous factory; lifecycle code continues
    /// to use `makeCover(frame:)` directly.
    internal func makeCoverForTesting(frame: CGRect) -> UIView {
        makeCover(frame: frame)
    }
    #endif
}
