"""Source-contract checks for the bounded native Highlights diagnostic fixture."""

import importlib.util
from pathlib import Path
import unittest


HERE = Path(__file__).parent
HEADER = HERE / "CVLPHighlightsDiagnostics.h"
FIXTURE = HERE / "HighlightsDiagnosticsFixture.m"
TRANSFORM_PATH = HERE / "guest_diagnostics.py"


def load_transform():
    spec = importlib.util.spec_from_file_location("guest_diagnostics_for_highlights", TRANSFORM_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def geometry_transform_sources(module):
    return {
        module.PROBE_HEADER_PATH: '''@interface CVLPProbe : NSObject
+ (NSString *)recordStage:(NSString *)stage;
+ (NSString *)hostSummary;
@end
''',
        module.PROBE_IMPLEMENTATION_PATH: '''#import "CVLPKeychainIdentity.h"

@implementation CVLPProbe
+ (NSString *)recordStage:(NSString *)stage { return @"stage"; }
+ (NSString *)hostSummary {
    return @"summary";
}
@end
''',
        module.BOOTSTRAP_PATH: '''    [CVLPProbe recordStage:@"post-loader"];

    // Go!
    ret = appMain(argc, argv);
''',
        "LiveContainer/CVLPGuestSession.m": "already transformed geometry summary sentinel",
        "MultitaskSupport/AppSceneViewController.m": "CVLP_GEOMETRY transformed sentinel",
        "Unowned/source.m": "must remain byte-for-byte unchanged",
    }


class HighlightsDiagnosticsSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = HEADER.read_text(encoding="utf-8")
        cls.fixture = FIXTURE.read_text(encoding="utf-8")

    def test_public_entrypoint_and_fixed_targets(self):
        self.assertIn("@interface CVLPHighlightsDiagnostics : NSObject", self.header)
        self.assertIn("+ (void)start;", self.header)
        for name in (
            "enableStoryHighlightConsumption",
            "enableStoryHighlightCreation",
            "TTKProfileBizDataStoryHighlightInfoModel",
            "storyHighlightInfo",
            "TTKProfileStoryHighlightComponent",
            "componentMount",
            "TTKProfileStoryHighlightCollectionComponent",
            "updateUI",
            "viewHeight",
        ):
            self.assertIn(name, self.header)

    def test_abi_and_own_method_checks_fail_closed(self):
        self.assertIn('CVLPHighlightsMethodHasExactSignature(search.method, "B")', self.header)
        self.assertIn('CVLPHighlightsMethodHasExactSignature(method, returnEncoding)', self.header)
        self.assertIn('"@", CVLPHighlightsModelTarget', self.header)
        self.assertIn('"v", CVLPHighlightsMountTarget', self.header)
        self.assertIn('"v", CVLPHighlightsUpdateTarget', self.header)
        self.assertIn('"d", CVLPHighlightsHeightTarget', self.header)
        self.assertIn('strcmp(returnType, returnEncoding) == 0', self.header)
        self.assertIn('strcmp(selfType, "@") == 0', self.header)
        self.assertIn('strcmp(selectorType, ":") == 0', self.header)
        self.assertIn("Method resolvedMethod = class_getInstanceMethod(cls, selector);", self.header)
        self.assertIn("methods[index] == resolvedMethod", self.header)
        self.assertIn("return resolvedMethodIsOwn ? resolvedMethod : NULL;", self.header)
        self.assertGreaterEqual(self.header.count("if (original == NULL) { return CVLPHighlightsInstallFailed; }"), 2)
        self.assertIn("CVLPHighlightsInstallWrongABI", self.header)
        self.assertIn("CVLPHighlightsInstallInherited", self.header)
        self.assertIn("CVLPHighlightsInstallAmbiguous", self.header)
        self.assertIn("CVLPHighlightsInstallBoundedIncomplete", self.header)

    def test_class_owner_search_is_bounded_and_only_unique_declarations_install(self):
        self.assertIn("CVLPHighlightsMaximumClasses = 100000", self.header)
        self.assertIn("CVLPHighlightsClassScanDeadline = 0.5", self.header)
        self.assertIn("objc_getClassList(NULL, 0)", self.header)
        self.assertIn("(index & 127U) == 0U", self.header)
        self.assertIn("method != inherited", self.header)
        self.assertIn("search.matches > 1", self.header)
        self.assertIn("search.matches == 0", self.header)
        self.assertIn("objc_getClassList(NULL, 0) != reportedCount", self.header)

    def test_wrappers_forward_once_preserve_values_and_do_not_retain_state(self):
        self.assertIn("((BOOL (*)(id, SEL))invocation)((id)receiver, exactSelector)", self.header)
        self.assertIn("((id (*)(id, SEL))invocation)((id)receiver, exactSelector)", self.header)
        self.assertIn("((void (*)(id, SEL))invocation)((id)receiver, exactSelector)", self.header)
        self.assertIn("((double (*)(id, SEL))invocation)((id)receiver, exactSelector)", self.header)
        self.assertEqual(self.header.count("IMP invocation = CVLPHighlightsReadForwarder(&original);"), 4)
        self.assertIn("IMP displaced = method_setImplementation(method, replacement);", self.header)
        self.assertIn("if (displaced != NULL) { *slot = displaced; }", self.header)
        self.assertIn("return result;", self.header)
        self.assertIn("errno = originalErrno;", self.header)
        self.assertIn("CVLPHighlightsState.counts[target]", self.header)
        self.assertIn("CVLPHighlightsCountMaximum = 65535", self.header)
        self.assertNotIn("imp_removeBlock", self.header)
        self.assertNotIn("method_setImplementation(method, original)", self.header)
        self.assertNotIn("@try", self.header[:self.header.index("static CVLPHighlightsTreeSummary CVLPHighlightsSampleTreeSafely")])

    def test_scheduler_lifecycle_and_line_output_are_bounded(self):
        self.assertIn("CVLPHighlightsMaximumEvents = 26", self.header)
        self.assertIn("CVLPHighlightsMaximumSamples = 24", self.header)
        self.assertIn("CVLPHighlightsDeadline = 120.0", self.header)
        self.assertIn("(5.0 * (CFTimeInterval)sampleNumber)", self.header)
        self.assertIn("dispatch_get_main_queue()", self.header)
        self.assertIn("UIApplicationDidEnterBackgroundNotification", self.header)
        self.assertIn("UISceneWillDeactivateNotification", self.header)
        self.assertNotIn("UIApplicationWillResignActiveNotification", self.header)
        self.assertNotIn("UIApplicationDidBecomeActiveNotification", self.header)
        self.assertIn('CVLPHighlightsRecording = NO;', self.header)
        self.assertIn('[self appendLineForPhase:@"stopped"', self.header)
        self.assertIn('line.length > 2048', self.header)
        self.assertIn('parts.count != 32', self.header)
        self.assertIn('hasPrefix:@"CVLP_HIGHLIGHTS "', self.header)
        self.assertIn('containsObject:phase', self.header)
        start = self.header.split('- (void)startOnMainQueue {', 1)[1].split('- (void)scheduleSample:', 1)[0]
        self.assertNotIn('CVLPHighlightsSampleTreeSafely()', start)
        self.assertIn('initialTree.truncated = 1;', start)

    def test_view_walk_is_read_only_shallow_bounded_and_content_free(self):
        self.assertIn("CVLPHighlightsMaximumTreeNodes = 1499", self.header)
        self.assertIn("CVLPHighlightsMaximumTreeDepth = 23", self.header)
        self.assertIn("CVLPHighlightsMaximumWindows = 3", self.header)
        self.assertIn('rootViewController.viewIfLoaded', self.header)
        self.assertIn("windowLimitReached", self.header)
        self.assertIn("summary.truncated = 1", self.header)
        self.assertIn("class_getName(object_getClass(view))", self.header)
        self.assertIn("view.hidden", self.header)
        self.assertIn("view.alpha", self.header)
        self.assertIn("view.frame.size", self.header)
        for forbidden in ("accessibilityLabel", "accessibilityValue", "valueForKey", "URL", "textContent", "NSFileManager", "NSURLSession", "SecItem"):
            self.assertNotIn(forbidden, self.header)
        self.assertIn("@catch (__unused NSException *exception)", self.header)
        self.assertNotIn("exception.reason", self.header)

    def test_fixture_exercises_pass_through_and_finite_report_contract(self):
        self.assertIn("CV_HIGHLIGHTS_FIXTURE_PASS", self.fixture)
        self.assertIn("feature_owner_unique_hook", self.fixture)
        self.assertIn("boolean_false_distinct_from_unknown", self.fixture)
        self.assertIn("original_exception_forwarded", self.fixture)
        self.assertIn("model_presence_without_extra_getter", self.fixture)
        self.assertIn("wrong_abi_not_modified", self.fixture)
        self.assertIn("inherited_method_not_modified", self.fixture)
        self.assertIn("ambiguous_owner_not_modified", self.fixture)
        self.assertIn("stopped_wrappers_forward_without_recording", self.fixture)
        self.assertIn("counter_saturates", self.fixture)
        self.assertIn("late_hook_disables_recording", self.fixture)
        self.assertIn("terminal_line_bound_and_no_post_stop_emit", self.fixture)
        self.assertIn("sanitizer_rejects_text_extra_and_nonfinite", self.fixture)
        self.assertNotIn("UIApplicationMain", self.fixture)

    def test_existing_geometry_transform_remains_independent(self):
        module = load_transform()
        before = geometry_transform_sources(module)
        snapshot = dict(before)
        transformed = module.transform(before)
        self.assertEqual(before, snapshot)
        self.assertEqual(set(transformed), set(before))
        self.assertEqual(transformed["Unowned/source.m"], before["Unowned/source.m"])
        self.assertEqual(transformed["LiveContainer/CVLPGuestSession.m"], before["LiveContainer/CVLPGuestSession.m"])
        self.assertEqual(transformed["MultitaskSupport/AppSceneViewController.m"],
                         before["MultitaskSupport/AppSceneViewController.m"])


if __name__ == "__main__":
    unittest.main()
