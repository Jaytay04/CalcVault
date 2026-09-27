import Foundation

@main
private struct LifecycleGateCommandLineTests {
    static func main() {
        testSuccessfulPathAndDuplicateCompletions()
        testRepeatedLaunchIsRejected()
        testStalePreparationAfterRevoke()
        testStaleAttachmentAfterRevoke()
        testNewGenerationRejectsOldCallbacks()
        testFailedPreparationRevokes()
        testGenerationOverflowCannotReuseToken()
        print("CVLPLifecycleGate: 7 scenarios passed")
    }

    private static func testSuccessfulPathAndDuplicateCompletions() {
        var gate = CVLPLifecycleGate()
        expect(gate.phase == .locked, "initial phase is locked")
        expect(gate.generation == 0, "initial generation is zero")
        expect(!gate.accepts(token: 0), "locked gate rejects its generation")

        let token = unwrap(gate.begin(), "locked gate begins preparation")
        expect(token == 1, "begin issues the next generation")
        expect(gate.phase == .preparing, "begin enters preparing")
        expect(gate.accepts(token: token), "preparing gate accepts current token")
        expect(gate.prepared(token: token, ready: true), "ready preparation permits launch")
        expect(gate.phase == .launching, "prepared gate enters launching")
        expect(!gate.prepared(token: token, ready: true), "duplicate preparation completion is rejected")
        expect(gate.attached(token: token), "current launch attaches")
        expect(gate.phase == .running, "attached gate enters running")
        expect(!gate.attached(token: token), "duplicate attachment is rejected")
        expect(gate.accepts(token: token), "running gate accepts current token")
    }

    private static func testRepeatedLaunchIsRejected() {
        var gate = CVLPLifecycleGate()
        let token = unwrap(gate.begin(), "first launch attempt begins")
        expect(gate.begin() == nil, "a second begin is rejected while preparing")
        expect(gate.prepared(token: token, ready: true), "first preparation completes")
        expect(gate.begin() == nil, "a second begin is rejected while launching")
    }

    private static func testStalePreparationAfterRevoke() {
        var gate = CVLPLifecycleGate()
        let staleToken = unwrap(gate.begin(), "preparation starts before revoke")
        gate.revoke()

        expect(gate.phase == .locked, "revoke locks a preparing gate")
        expect(gate.generation == staleToken + 1, "revoke advances generation")
        expect(!gate.prepared(token: staleToken, ready: true), "stale preparation cannot launch")
        expect(!gate.accepts(token: staleToken), "stale token is rejected after revoke")
    }

    private static func testStaleAttachmentAfterRevoke() {
        var gate = CVLPLifecycleGate()
        let token = unwrap(gate.begin(), "launch preparation begins")
        expect(gate.prepared(token: token, ready: true), "launch becomes permitted")
        gate.revoke()

        expect(!gate.attached(token: token), "stale attachment cannot restart a revoked session")
        expect(gate.phase == .locked, "stale attachment leaves gate locked")
        expect(!gate.accepts(token: token), "revoked running token is rejected")
    }

    private static func testNewGenerationRejectsOldCallbacks() {
        var gate = CVLPLifecycleGate()
        let oldToken = unwrap(gate.begin(), "old generation begins")
        expect(gate.prepared(token: oldToken, ready: true), "old generation reaches launching")
        gate.revoke()
        let newToken = unwrap(gate.begin(), "new generation begins after revoke")

        expect(newToken > oldToken, "new generation is strictly greater")
        expect(!gate.prepared(token: oldToken, ready: true), "old preparation callback cannot affect new generation")
        expect(!gate.attached(token: oldToken), "old attachment callback cannot affect new generation")
        expect(gate.phase == .preparing, "old callbacks leave new preparation intact")
        expect(!gate.accepts(token: oldToken), "new generation rejects old token")
        expect(gate.accepts(token: newToken), "new generation accepts current token")
    }

    private static func testFailedPreparationRevokes() {
        var gate = CVLPLifecycleGate()
        let token = unwrap(gate.begin(), "failed preparation begins")
        expect(!gate.prepared(token: token, ready: false), "failed preparation is not launchable")
        expect(gate.phase == .locked, "failed preparation returns to locked")
        expect(gate.generation == token + 1, "failed preparation revokes its generation")
        expect(!gate.accepts(token: token), "failed preparation token is rejected")
        expect(!gate.attached(token: token), "failed preparation cannot attach")
    }

    private static func testGenerationOverflowCannotReuseToken() {
        var gate = CVLPLifecycleGate(generation: UInt64.max - 1)
        let finalToken = unwrap(gate.begin(), "last representable generation can begin")
        expect(finalToken == UInt64.max, "last generation is UInt64.max")
        expect(gate.prepared(token: finalToken, ready: true), "last generation can prepare")
        expect(gate.attached(token: finalToken), "last generation can attach")
        gate.revoke()

        expect(gate.phase == .locked, "overflow revoke still locks")
        expect(gate.generation == UInt64.max, "overflow does not wrap the counter")
        expect(!gate.accepts(token: finalToken), "locked max generation rejects its old token")
        expect(gate.begin() == nil, "overflow prevents issuing a reused token")
        expect(gate.phase == .locked, "failed begin at max leaves gate locked")
    }

    private static func unwrap(_ value: UInt64?, _ message: String) -> UInt64 {
        guard let value else {
            fail(message)
        }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("FAIL: \(message)")
    }
}
