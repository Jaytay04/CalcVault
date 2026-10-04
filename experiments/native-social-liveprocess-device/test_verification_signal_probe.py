"""Source-contract checks for the synthetic-only bounded signal probe."""

from pathlib import Path
import unittest


ROOT = Path(__file__).parent
HOST = (ROOT / "CVLPHostView.swift").read_text(encoding="utf-8")
SESSION = (ROOT / "CVLPGuestSession.m").read_text(encoding="utf-8")
SESSION_HEADER = (ROOT / "CVLPGuestSession.h").read_text(encoding="utf-8")
PATCHER = (ROOT / "prepare-lifecycle.py").read_text(encoding="utf-8")


def section(source, start, end):
    first = source.index(start)
    last = source.index(end, first + len(start))
    return source[first:last]


class VerificationSignalProbeTests(unittest.TestCase):
    def test_swift_uses_imported_boolean_getter_name(self):
        self.assertIn("getter=isVerificationSignalProbeAvailable", SESSION_HEADER)
        self.assertEqual(HOST.count("guest.isVerificationSignalProbeAvailable"), 3)
        self.assertNotIn("guest.verificationSignalProbeAvailable", HOST)

    def test_signal_declarations_preserve_framework_geometry_anchors(self):
        self.assertIn("@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;\n"
                      "- (void)cvlpRevoke;\n@end", SESSION)
        self.assertIn("@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;\n"
                      "- (void)cvlpRevoke;\n@property int resizeDebounceToken;", PATCHER)

    def test_signal_target_is_verified_without_blocking_other_framework_launches(self):
        start = section(SESSION, "- (void)startWithCompletion:", "- (void)deliverCompletion:")
        self.assertIn('NSString *bundleIdentifier = @"org.example.syntheticnativeguest.app";', start)
        self.assertIn('NSString *dataUUID = @"synthetic-liveprocess-device";', start)
        self.assertIn("self.syntheticTargetIdentityVerified = [self syntheticTargetIdentityIsVerified]", start)
        self.assertIn("scene.cvlpSyntheticTargetVerified = self.syntheticTargetIdentityVerified", start)
        self.assertNotIn("[self deliverCompletion:NO]", section(start, "self.syntheticTargetIdentityVerified", "AppSceneViewController *scene"))

        identity = section(SESSION, "- (BOOL)syntheticTargetIdentityIsVerified {", "- (BOOL)verificationSignalRequestIsReady {")
        self.assertIn("CVLPFrameworkDescriptorTargetsSyntheticGuest()", identity)
        self.assertIn("CVLPFrameworkGuestURL(NSBundle.mainBundle.bundleURL)", SESSION)
        self.assertIn("CVLPGuestPropertyList(descriptorPath, 64 * 1024)", SESSION)
        self.assertIn("isEqualToString:CVLPSyntheticBundleIdentifier()", SESSION)
        self.assertIn("CVLPFrameworkGuestMode", identity)
        self.assertIn("fileExistsAtPath:frameworkDescriptorURL.path", identity)
        self.assertEqual(SESSION.count('@"org.example.syntheticnativeguest.app"'), 1)
        self.assertEqual(SESSION.count('@"synthetic-liveprocess-device"'), 1)
        self.assertNotIn("com.zhiliaoapp.musically", identity)

    def test_scene_method_allows_only_stop_continue_and_refuses_unready_or_revoked_targets(self):
        self.assertIn("- (BOOL)cvlpRequestVerificationSignal:(int)signal", PATCHER)
        self.assertIn("if (signal != SIGSTOP && signal != SIGCONT) return NO;", PATCHER)
        for guard in (
            "self.cvlpRevoked",
            "!self.cvlpSyntheticTargetVerified",
            "!self.cvlpBeginCompleted",
            "self.cvlpObservedPID <= 0",
            "!self.identifier",
            "!self.presenter",
            "!self.view.window",
            "respondsToSelector:@selector(_kill:)",
        ):
            self.assertIn(guard, PATCHER)
        self.assertEqual(PATCHER.count("[self.extension _kill:signal]"), 1)
        self.assertIn("- (void)_kill:(int)signal;", PATCHER)
        self.assertIn("suspension and media stop unproved", PATCHER)

    def test_probe_is_user_started_and_uses_a_fixed_two_second_foreground_deadline(self):
        self.assertIn("private let verificationSignalProbeDuration: TimeInterval = 2.0", HOST)
        start = section(HOST, "func startVerificationSignalProbe()", "private func finishVerificationSignalProbe(")
        self.assertIn("guard !verificationSignalProbeAttempted else { return }", start)
        self.assertIn("guest.requestVerificationSignal(SIGSTOP)", start)
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + verificationSignalProbeDuration", start)
        self.assertIn("MainActor.assumeIsolated", start)
        self.assertIn("exact synthetic descriptor", start)

        finish = section(HOST, "private func finishVerificationSignalProbe(", "private func cancelVerificationSignalProbe()")
        for foreground_guard in (
            "verificationSignalProbeGeneration == generation",
            "launchedToken == guestToken",
            "gate.accepts(token: guestToken)",
            "!inactiveTransition",
            "UIApplication.shared.applicationState == .active",
            "!locked, showingGuest",
        ):
            self.assertIn(foreground_guard, finish)
        self.assertIn("guest.requestVerificationSignal(SIGCONT)", finish)
        self.assertIn("scheduled 2-second callback", finish)

        appearance = section(HOST, "}.onAppear {", "\n    }\n}")
        self.assertNotIn("startVerificationSignalProbe", appearance)
        self.assertIn('Button(model.verificationSignalProbeAttempted ? "Signal probe used" : "2-second signal probe")', HOST)

    def test_one_shot_and_late_resume_are_closed_by_lock(self):
        request = section(SESSION, "- (BOOL)requestVerificationSignal:", "- (void)deliverCompletion:")
        self.assertIn("self.verificationSignalProbeUsed = YES", request)
        self.assertIn("!self.verificationSignalStopSubmitted", request)
        self.assertIn("self.verificationSignalContinueSubmitted", request)
        self.assertIn("self.verificationSignalContinueAttempted = YES", request)
        self.assertIn("self.verificationSignalContinueSubmitted = submitted", request)
        self.assertLess(request.index("BOOL submitted = [self.sceneController"),
                        request.index("self.verificationSignalContinueSubmitted = submitted"))
        ready = section(SESSION, "- (BOOL)verificationSignalRequestIsReady {", "- (BOOL)isVerificationSignalProbeAvailable")
        self.assertIn("!self.revoked", ready)

        lock = section(HOST, "func lock(reason:", "@objc private func inactive(")
        self.assertLess(lock.index("cancelVerificationSignalProbe()"), lock.index("gate.revoke()"))
        self.assertLess(lock.index("gate.revoke()"), lock.index("guest.revoke()"))
        cancel = section(HOST, "private func cancelVerificationSignalProbe()", "func lock(reason:")
        self.assertIn("verificationSignalProbeGeneration &+= 1", cancel)
        self.assertIn("verificationSignalContinueWorkItem?.cancel()", cancel)
        self.assertIn("no continuation request will be sent", cancel)
        self.assertIn("host is revoking the guest now", HOST)

    def test_status_never_claims_suspension_or_media_stop_as_observed_or_production_enabled(self):
        sources = "\n".join((HOST, SESSION, PATCHER, SESSION_HEADER)).lower()
        self.assertIn("suspension and media stop are unproved", sources)
        self.assertNotIn("suspension confirmed", sources)
        self.assertNotIn("media stop observed", sources)
        self.assertNotIn("production signal enabled", sources)
        self.assertNotIn("corenativeguestverificationruntime", sources)
        self.assertIn("verificationSignalProbeAvailable", SESSION_HEADER)


if __name__ == "__main__":
    unittest.main()
