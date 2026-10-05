"""Source contracts for the bounded cooperative media gate.

These checks inspect source only; they do not compile an iOS target or prove
that every media implementation on a device is intercepted.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).parent
HEADER = (ROOT / "CVLPCooperativeMediaGate.h").read_text(encoding="utf-8")
SOURCE = (ROOT / "CVLPCooperativeMediaGate.m").read_text(encoding="utf-8")


def implementation_section(start, end):
    start_at = SOURCE.rindex(start)
    end_at = SOURCE.index(end, start_at + len(start))
    return SOURCE[start_at:end_at]


class CooperativeMediaGateTests(unittest.TestCase):
    def test_public_api_uses_async_completion_and_uuid_tokens(self):
        for api in (
            "+ (BOOL)install;",
            "+ (void)beginHoldWithToken:(NSUUID *)token",
            "maximumDuration:(NSTimeInterval)duration",
            "completion:(void (^)(BOOL applied))completion",
            "expiration:(void (^)(void))expiration;",
            "+ (BOOL)endHoldWithToken:(NSUUID *)token;",
            "+ (void)invalidate;",
        ):
            self.assertIn(api, HEADER)
        begin = implementation_section("- (void)beginHoldWithToken:", "- (BOOL)endHoldWithToken:")
        for check in (
            "NSThread.isMainThread",
            "![token isKindOfClass:NSUUID.class]",
            "!isfinite(duration)",
            "duration <= 0.0",
            "duration > CVLPMediaMaximumHoldDuration",
            "self.held || self.activeToken",
            "self.consumedTokens containsObject:token",
            "self.inFlightEntries != 0",
            "systemUptime + duration",
        ):
            self.assertIn(check, begin)
        self.assertIn("CVLPMediaMaximumHoldDuration = 120.0", SOURCE)
        self.assertIn("CVLPMediaTokenLimit = 128", SOURCE)

    def test_hooks_are_type_checked_owned_and_worker_os_is_supported(self):
        for symbol in ("CVLPMethodHasSignature", "method_getNumberOfArguments",
                       "method_getArgumentType", "CVLPTypeEncodingMatches",
                       "hooksAreOwnedLocked", "method_getImplementation(hook.method)"):
            self.assertIn(symbol, SOURCE)
        install = implementation_section("- (BOOL)installHooks {", "- (BOOL)hooksAreOwnedLocked {")
        self.assertIn("@available(iOS 16.0, *)", install)
        for selector in (
            "@selector(play)", "@selector(setRate:)", "@selector(playImmediatelyAtRate:)",
            'sel_registerName("setRate:time:atHostTime:")', "@selector(playAtTime:)",
            "@selector(startAndReturnError:)", "@selector(setActive:error:)",
            "@selector(setActive:withOptions:error:)",
        ):
            self.assertIn(selector, install)
        self.assertIn("self.hooks.count == 10", install)
        end = implementation_section("- (BOOL)endHoldWithToken:", "- (void)invalidateGate {")
        self.assertIn("![self hooksAreOwnedLocked]", end)

    def test_registries_are_weak_bounded_and_entries_are_admitted_atomically(self):
        for declaration in (
            "NSHashTable<AVPlayer *> *players",
            "NSHashTable<AVAudioPlayer *> *audioPlayers",
            "NSHashTable<AVAudioEngine *> *audioEngines",
        ):
            self.assertIn(declaration, SOURCE)
        for registry in ("players", "audioPlayers", "audioEngines"):
            self.assertIn(f"_{registry} = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory", SOURCE)
        self.assertIn("CVLPMediaRegistryLimit = 128", SOURCE)
        entry = implementation_section("- (BOOL)beginMediaEntryForObject:", "- (BOOL)beginSessionActivation {")
        self.assertIn("registry.count >= CVLPMediaRegistryLimit", entry)
        self.assertIn("self.inFlightEntries += 1", entry)
        begin = implementation_section("- (void)beginHoldWithToken:", "- (BOOL)endHoldWithToken:")
        self.assertIn("self.inFlightEntries != 0", begin)
        self.assertIn("self.inFlightEntries < CVLPMediaRegistryLimit", entry)

    def test_begin_closes_gate_snapshots_and_starts_expiry_before_media_worker(self):
        begin = implementation_section("- (void)beginHoldWithToken:", "- (BOOL)endHoldWithToken:")
        self.assertLess(begin.index("self.held = YES"), begin.index("dispatch_async(self.mediaQueue"))
        self.assertLess(begin.index("self.players.allObjects"), begin.index("dispatch_async(self.mediaQueue"))
        self.assertLess(begin.index("dispatch_resume(timer)"), begin.index("dispatch_async(self.mediaQueue"))
        self.assertIn("dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.controlQueue)", begin)
        self.assertIn("_mediaQueue = dispatch_queue_create", SOURCE)
        self.assertNotIn("dispatch_sync", SOURCE)
        self.assertIn("self.activeDeadlineUptime = NSProcessInfo.processInfo.systemUptime + duration", begin)

    def test_pause_and_deactivation_run_on_media_worker_before_fenced_main_ack(self):
        begin = implementation_section("- (void)beginHoldWithToken:", "- (BOOL)endHoldWithToken:")
        self.assertIn("dispatch_async(self.mediaQueue, ^{", begin)
        for operation in ("[player pause]", "[engine pause]", "deactivateAudioSessionForHold"):
            self.assertIn(operation, begin)
        complete = implementation_section("- (void)completeHoldApplicationForToken:", "- (void)pauseTrackedMedia {")
        self.assertIn("dispatch_async(dispatch_get_main_queue()", complete)
        self.assertIn("self.activeToken isEqual:token", complete)
        self.assertIn("self.holdApplying", complete)
        self.assertIn("now >= self.activeDeadlineUptime", complete)
        self.assertIn("[self hooksAreOwnedLocked]", complete)
        self.assertIn("completion(applied)", complete)
        self.assertNotIn("pauseTrackedMediaSynchronously", SOURCE)

    def test_audio_session_busy_exception_is_exact_and_activation_remains_gated(self):
        deactivate = implementation_section("- (BOOL)deactivateAudioSessionForHold {", "- (void)completeHoldApplicationForToken:")
        self.assertIn("CVLPAVAudioSessionSetActiveOriginal", deactivate)
        self.assertIn("NSOSStatusErrorDomain", deactivate)
        self.assertIn("AVAudioSessionErrorCodeIsBusy", deactivate)
        self.assertIn("if (deactivated) return YES;", deactivate)
        self.assertIn("error.code == AVAudioSessionErrorCodeIsBusy", deactivate)
        for hook in ("CVLPAVAudioSessionSetActive", "CVLPAVAudioSessionSetActiveWithOptions"):
            body = SOURCE.split(f"static BOOL {hook}(", 1)[1].split("\n}\n", 1)[0]
            self.assertIn("if (active && ![gate beginSessionActivation])", body)
            self.assertIn("if (active) [gate endMediaEntry];", body)
            self.assertNotIn("if ([gate isGateClosed])", body)

    def test_expiry_is_independent_terminal_and_one_shot(self):
        for marker in ("systemUptime", "dispatch_time(DISPATCH_TIME_NOW", "DISPATCH_TIME_FOREVER",
                       "finishExpirationLockedForToken", "deliverExpiration:", "expirationHandler = nil",
                       "dispatch_source_cancel(self.expirationTimer)"):
            self.assertIn(marker, SOURCE)
        self.assertIn("dispatch_async(self.controlQueue, ^{ handler(); });", SOURCE)
        self.assertIn("Completion runs on main; expiration runs on the independent control queue.", HEADER)
        finish = implementation_section("- (nullable void (^)(void))finishExpirationLockedForToken:", "- (void)expireHoldForToken:")
        self.assertIn("self.invalidated = YES", finish)
        self.assertIn("self.held = YES", finish)
        self.assertNotIn("self.held = NO", finish)
        invalidate = implementation_section("- (void)invalidateGate {", "- (void)cancelExpirationTimerLocked {")
        self.assertIn("self.invalidated = YES", invalidate)
        self.assertIn("self.held = YES", invalidate)
        self.assertIn("[self cancelExpirationTimerLocked]", invalidate)
        self.assertNotIn("SIGSTOP", SOURCE)
        self.assertNotIn("SIGCONT", SOURCE)

    def test_invalidation_pause_is_worker_only_and_release_never_autoplays(self):
        pause = implementation_section("- (void)pauseTrackedMedia {", "@end")
        self.assertIn("dispatch_async(self.mediaQueue, ^{", pause)
        self.assertIn("[gate hooksAreOwnedLocked]", pause)
        self.assertIn("[player pause]", pause)
        end = implementation_section("- (BOOL)endHoldWithToken:", "- (void)invalidateGate {")
        self.assertIn("[self hooksAreOwnedLocked]", end)
        self.assertIn("self.held = NO", end)
        self.assertNotIn("play]", end)
        self.assertNotIn("startAndReturnError", end)


if __name__ == "__main__":
    unittest.main()
