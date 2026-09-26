import Foundation
import UIKit

/// Pauses browser media whenever iOS makes the app inactive or backgrounds it.
/// The injected action keeps lifecycle behavior testable without loading a site.
@MainActor
public final class SocialMediaLifecycleObserver: NSObject {
    private let notificationCenter: NotificationCenter
    private let pauseMedia: @MainActor () -> Void
    private var isObserving = false

    public init(
        notificationCenter: NotificationCenter = .default,
        pauseMedia: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.pauseMedia = pauseMedia
        super.init()
    }

    public func start() {
        guard !isObserving else { return }
        isObserving = true
        notificationCenter.addObserver(
            self,
            selector: #selector(pauseForLifecycleChange),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(pauseForLifecycleChange),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    public func stop() {
        guard isObserving else { return }
        notificationCenter.removeObserver(self)
        isObserving = false
    }

    @objc private func pauseForLifecycleChange(_ notification: Notification) {
        pauseMedia()
    }
}
