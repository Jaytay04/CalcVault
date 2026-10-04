"""Pure source-transform and privacy-bound tests; native compilation is a macOS check."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "guest_diagnostics",
    Path(__file__).with_name("guest_diagnostics.py"),
)
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


def sources():
    return {
        diagnostics.PROBE_HEADER_PATH: '''@interface CVLPProbe : NSObject
+ (NSString *)recordStage:(NSString *)stage;
+ (NSString *)hostSummary;
@end
''',
        diagnostics.PROBE_IMPLEMENTATION_PATH: '''#import "CVLPKeychainIdentity.h"

@implementation CVLPProbe
+ (NSString *)recordStage:(NSString *)stage { return @"stage"; }
+ (NSString *)hostSummary {
    return @"summary";
}
@end
''',
        diagnostics.BOOTSTRAP_PATH: '''    [CVLPProbe recordStage:@"post-loader"];

    // Go!
    ret = appMain(argc, argv);
''',
        "LiveContainer/CVLPGuestSession.m": "already transformed geometry summary sentinel",
        "MultitaskSupport/AppSceneViewController.m": "CVLP_GEOMETRY transformed sentinel",
        "Unowned/source.m": "must remain byte-for-byte unchanged",
    }


class GuestDiagnosticsTests(unittest.TestCase):
    def test_transform_preserves_inputs_unowned_sources_and_geometry_output(self):
        before = sources()
        snapshot = dict(before)
        after = diagnostics.transform(before)
        self.assertEqual(before, snapshot)
        self.assertEqual(set(after), set(before))
        self.assertEqual(after["Unowned/source.m"], before["Unowned/source.m"])
        self.assertEqual(after["LiveContainer/CVLPGuestSession.m"],
                         before["LiveContainer/CVLPGuestSession.m"])
        self.assertEqual(after["MultitaskSupport/AppSceneViewController.m"],
                         before["MultitaskSupport/AppSceneViewController.m"])

    def test_probe_declaration_import_and_bootstrap_order(self):
        after = diagnostics.transform(sources())
        header = after[diagnostics.PROBE_HEADER_PATH]
        probe = after[diagnostics.PROBE_IMPLEMENTATION_PATH]
        bootstrap = after[diagnostics.BOOTSTRAP_PATH]
        self.assertIn("+ (void)startGuestGeometryObservations;", header)
        self.assertIn("+ (void)recordGuestDiagnostic:(NSString *)line;", header)
        self.assertIn('#import "CVLPGuestDiagnostics.h"', probe)
        self.assertIn("@synchronized (self)", probe)
        record_stage = bootstrap.index('[CVLPProbe recordStage:@"post-loader"];')
        start = bootstrap.index("[CVLPProbe startGuestGeometryObservations];")
        invocation = bootstrap.index("ret = appMain(argc, argv);")
        self.assertIn(
            '[CVLPProbe recordStage:@"post-loader"];\n'
            '    [CVLPProbe startGuestGeometryObservations];',
            bootstrap,
        )
        self.assertLess(record_stage, start)
        self.assertLess(start, invocation)

    def test_missing_duplicate_drift_and_reapplication_fail_without_mutation(self):
        with self.assertRaises(ValueError):
            diagnostics.transform({diagnostics.PROBE_HEADER_PATH: "only one owned source"})

        anchor_cases = (
            (diagnostics.PROBE_HEADER_PATH, '+ (NSString *)recordStage:(NSString *)stage;'),
            (diagnostics.PROBE_IMPLEMENTATION_PATH, '#import "CVLPKeychainIdentity.h"'),
            (diagnostics.BOOTSTRAP_PATH, '[CVLPProbe recordStage:@"post-loader"];'),
        )
        for path, anchor in anchor_cases:
            before = sources()
            before[path] = before[path].replace(anchor, "drift", 1)
            snapshot = dict(before)
            with self.assertRaises(ValueError):
                diagnostics.transform(before)
            self.assertEqual(before, snapshot)

        before = sources()
        before[diagnostics.BOOTSTRAP_PATH] = (
            "ret = appMain(argc, argv);\n" + before[diagnostics.BOOTSTRAP_PATH]
        )
        with self.assertRaises(ValueError):
            diagnostics.transform(before)
        with self.assertRaises(ValueError):
            diagnostics.transform(diagnostics.transform(sources()))

    def test_helper_uses_bounded_allowlisted_public_observations(self):
        helper = Path(__file__).with_name("CVLPGuestDiagnostics.h").read_text(encoding="utf-8")
        self.assertIn('appendPhase:@"armed" fields:@"mainQueuePending=1"', helper)
        self.assertIn("CVLPGuestDiagnosticsMaximumEvents = 16", helper)
        self.assertIn("CVLPGuestDiagnosticsMaximumNotificationSamples = 6", helper)
        self.assertIn("CVLPGuestDiagnosticsDeadline = 30.0", helper)
        self.assertIn("CVLPGuestDiagnosticsFinalSampleGrace = 0.25", helper)
        self.assertIn("@[@1, @3, @10, @30]", helper)
        self.assertIn("@[@2, @8, @30]", helper)
        self.assertIn('runloop-2s\", @"runloop-8s\", @"runloop-30s', helper)
        self.assertIn("addTimer:timer forMode:NSRunLoopCommonModes", helper)
        self.assertIn("repeats:NO", helper)
        self.assertIn("dispatchScheduled=4 runLoopScheduled=3 runLoopTerminalScheduled=1 notificationLimit=%lu", helper)
        self.assertIn('appendPhase:@"installed"', helper)
        self.assertIn("runLoopTerminalTimer = [NSTimer timerWithTimeInterval:runLoopTerminalDelay repeats:NO", helper)
        self.assertIn("addTimer:runLoopTerminalTimer forMode:NSRunLoopCommonModes", helper)
        self.assertIn("sampledScenes.count >= 2", helper)
        self.assertIn("windows.count < 3", helper)
        self.assertIn("line.length > 2048", helper)
        self.assertIn("application:configurationForConnectingSceneSession:options:", helper)
        self.assertIn("UIWindowDidBecomeVisibleNotification", helper)
        self.assertIn("UIWindowDidBecomeKeyNotification", helper)
        self.assertIn("UIApplicationDidFinishLaunchingNotification", helper)
        self.assertIn("UISceneDidActivateNotification", helper)
        self.assertIn("UIApplicationWillResignActiveNotification", helper)
        self.assertIn("UIApplicationDidEnterBackgroundNotification", helper)
        self.assertIn("UISceneWillDeactivateNotification", helper)
        self.assertIn("window.rootViewController.viewIfLoaded", helper)
        self.assertNotIn("rootViewController.view.bounds", helper)
        self.assertIn("notification.object isKindOfClass:UIWindow.class", helper)
        self.assertIn("respondsToSelector:@selector(window)", helper)
        self.assertNotIn("performSelector", helper)
        implementation = helper.index("@implementation CVLPGuestGeometryDiagnostics")
        snapshot = helper.index("- (BOOL)snapshot:", implementation)
        self.assertNotIn("UIApplication.sharedApplication", helper[implementation:snapshot])

    def test_scheduler_terminal_contract_is_bounded_and_fixed(self):
        helper = Path(__file__).with_name("CVLPGuestDiagnostics.h").read_text(encoding="utf-8")
        for reason in (
            'return @"app-inactive";',
            'return @"app-background";',
            'return @"scene-deactivated";',
            'return @"deadline";',
            'return @"event-limit";',
        ):
            self.assertIn(reason, helper)
        self.assertIn("phase=stopped reason=%@ sequence=%lu elapsedMs=%llu dispatchSamples=%lu runLoopSamples=%lu notificationSamples=%lu", helper)
        self.assertIn("phase=%@ sequence=%lu elapsedMs=%llu%@", helper)
        self.assertIn("self.eventCount >= CVLPGuestDiagnosticsMaximumEvents - 1", helper)
        self.assertIn("[timer invalidate]", helper)
        self.assertIn("if (self.stopped) { return; }", helper)
        self.assertIn("elapsed > CVLPGuestDiagnosticsDeadline + CVLPGuestDiagnosticsFinalSampleGrace", helper)

        implementation = helper.index("@implementation CVLPGuestGeometryDiagnostics")
        stop = helper.index("- (void)stopWithReason:", implementation)
        terminal = helper.index("[CVLPProbe recordGuestDiagnostic:line];", stop)
        cleanup = helper.index("[timer invalidate]", stop)
        self.assertLess(terminal, cleanup)
        self.assertIn("__weak typeof(self) weakSelf = self;", helper)
        self.assertIn("source:CVLPGuestDiagnosticsSampleSourceDispatch", helper)
        self.assertIn("source:CVLPGuestDiagnosticsSampleSourceRunLoop", helper)
        self.assertIn("source:CVLPGuestDiagnosticsSampleSourceNotification", helper)

        emitted_fields = helper[helper.index('NSString *line = [NSString stringWithFormat:'):]
        for forbidden in ("url=", "cookie=", "password=", "path=", "text=", "preferences="):
            self.assertNotIn(forbidden, emitted_fields.lower())

    def test_guest_inactive_observation_does_not_remove_host_or_background_stops(self):
        helper = Path(__file__).with_name("CVLPGuestDiagnostics.h").read_text(encoding="utf-8")
        self.assertIn('name:UIApplicationWillResignActiveNotification phase:@"app-inactive" stops:NO', helper)
        self.assertIn('name:UIApplicationDidBecomeActiveNotification phase:@"app-active" stops:NO', helper)
        self.assertIn('name:UIApplicationDidEnterBackgroundNotification phase:nil stops:YES', helper)
        self.assertIn('name:UISceneWillDeactivateNotification phase:nil stops:YES', helper)
        self.assertIn('appState=%ld screen=%@', helper)
        host = Path(__file__).with_name("CVLPHostView.swift").read_text(encoding="utf-8")
        self.assertIn('if gate.phase != .preparing { lock(reason: "inactive") }', host)
        self.assertIn('lock(reason: "background or pending synthetic authentication backgrounded")', host)
        self.assertIn('lock(reason: "protected-data loss")', host)
        self.assertIn('handoffGate.phase == .holding && heldGuestIsLive()', host)
        self.assertIn('gate.revoke()', host)
        self.assertIn('guest.revoke()', host)
        guest = Path(__file__).with_name("Guest.m").read_text(encoding="utf-8")
        start = guest.index('#if TARGET_OS_SIMULATOR')
        end = guest.index('#endif', start)
        self.assertIn('CVLP_SYNTHETIC_INACTIVE_NOTIFICATION', guest[start:end])
        self.assertIn('postNotificationName:UIApplicationWillResignActiveNotification', guest[start:end])


if __name__ == "__main__":
    unittest.main()
