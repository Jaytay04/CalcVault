import Combine
import Foundation

/// Runs a diagnostic scan only while a valid private session is active.
/// The result is an observation; it does not grant or retain session authority.
@MainActor
public final class NativeGuestPreflightModel: ObservableObject {
    public enum State: Equatable {
        case notChecked
        case checking
        case noLegacyCopiesObserved
        case blocked
    }

    @Published public private(set) var state: State = .notChecked

    private struct SessionContext: Equatable {
        let sessionID: UUID
        let generation: UInt64
    }

    private struct CheckRequest: Equatable {
        let session: SessionContext
        let requestID: UUID
    }

    private let lifecycle: SessionLifecycleCoordinator
    private let checkLegacyCredentialAbsence: @Sendable () async throws -> Void
    private var lifecycleObservation: AnyCancellable?
    private var stateSession: SessionContext?
    private var activeRequest: CheckRequest?
    private var activeTask: Task<Void, Never>?

    public init(
        lifecycle: SessionLifecycleCoordinator,
        check: @escaping @Sendable () async throws -> Void
    ) {
        self.lifecycle = lifecycle
        self.checkLegacyCredentialAbsence = check

        lifecycleObservation = lifecycle.$state
            .dropFirst()
            .sink { [weak self] _ in
                // SessionLifecycleCoordinator publishes only from its main-actor API.
                // Published emits during willSet, so invalidate on every transition
                // instead of reading the coordinator's not-yet-updated state here.
                MainActor.assumeIsolated {
                    self?.invalidateAndReset()
                }
            }
    }

    /// Starts a fresh scan. Returns nil when another scan is in flight or the
    /// lifecycle does not currently authorize access to the private session.
    @discardableResult
    public func check() -> Task<Void, Never>? {
        let currentSession = validSessionContext()

        if let activeRequest {
            if currentSession == activeRequest.session {
                return nil
            }

            invalidateAndReset()
            guard let currentSession else {
                state = .blocked
                return nil
            }
            return startCheck(in: currentSession)
        }

        guard let currentSession else {
            stateSession = nil
            state = .blocked
            return nil
        }

        return startCheck(in: currentSession)
    }

    private func startCheck(in session: SessionContext) -> Task<Void, Never> {
        let request = CheckRequest(session: session, requestID: UUID())
        let checker = checkLegacyCredentialAbsence
        stateSession = session
        activeRequest = request
        state = .checking

        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled, self?.canRun(request) == true else {
                self?.finishCancelled(request)
                return
            }

            do {
                try await checker()
                guard !Task.isCancelled else {
                    self?.finishCancelled(request)
                    return
                }
                self?.finish(request, succeeded: true)
            } catch {
                guard !Task.isCancelled else {
                    self?.finishCancelled(request)
                    return
                }
                self?.finish(request, succeeded: false)
            }
        }
        activeTask = task
        return task
    }

    private func finish(_ request: CheckRequest, succeeded: Bool) {
        guard activeRequest == request else { return }

        guard stateSession == request.session,
              isValid(request.session) else {
            invalidateAndReset()
            return
        }

        activeRequest = nil
        activeTask = nil
        state = succeeded ? .noLegacyCopiesObserved : .blocked
    }

    private func finishCancelled(_ request: CheckRequest) {
        guard activeRequest == request else { return }
        invalidateAndReset()
    }

    private func canRun(_ request: CheckRequest) -> Bool {
        activeRequest == request
            && stateSession == request.session
            && isValid(request.session)
    }

    private func validSessionContext() -> SessionContext? {
        guard case .privateUnlocked(let sessionID) = lifecycle.state else {
            return nil
        }

        let session = SessionContext(
            sessionID: sessionID,
            generation: lifecycle.sessionGeneration
        )
        return isValid(session) ? session : nil
    }

    private func isValid(_ session: SessionContext) -> Bool {
        lifecycle.isValidSession(
            sessionID: session.sessionID,
            generation: session.generation
        )
    }

    private func invalidateAndReset() {
        activeTask?.cancel()
        activeTask = nil
        activeRequest = nil
        stateSession = nil
        state = .notChecked
    }
}
