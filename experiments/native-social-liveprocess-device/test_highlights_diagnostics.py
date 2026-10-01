"""Source-contract checks for the bounded native Highlights diagnostic fixture."""

import importlib.util
import re
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
        self.assertNotIn("class_getInstanceMethod(", self.header)
        self.assertNotIn("class_getClassMethod(", self.header)
        self.assertIn("method_getName(methods[index]) == selector", self.header)
        self.assertIn("return *matches == 1 ? selected : NULL;", self.header)
        self.assertIn("depth < 64", self.header)
        self.assertGreaterEqual(self.header.count("if (original == NULL) { return CVLPHighlightsInstallFailed; }"), 2)
        self.assertIn("CVLPHighlightsInstallWrongABI", self.header)
        self.assertIn("CVLPHighlightsInstallInherited", self.header)
        self.assertIn("CVLPHighlightsInstallAmbiguous", self.header)
        self.assertIn("CVLPHighlightsInstallBoundedIncomplete", self.header)

    def test_class_owner_search_is_bounded_and_only_unique_declarations_install(self):
        self.assertIn("CVLPHighlightsMaximumClasses = 100000", self.header)
        self.assertIn("CVLPHighlightsClassScanDeadline = 0.5", self.header)
        self.assertIn("objc_enumerateClasses(imageInfo.dli_fbase, NULL, NULL, Nil", self.header)
        self.assertIn("class_getImageName(anchor)", self.header)
        self.assertIn("dladdr((__bridge const void *)anchor, &imageInfo)", self.header)
        self.assertIn("CVLPHighlightsClassSearchObserve(&search, cls)", self.header)
        self.assertIn("CVLPHighlightsDeclaredMethod(object_getClass(cls), search->selector, &ownMatches)", self.header)
        self.assertIn("beforeMethodList = search->clock(search->context)", self.header)
        self.assertIn("afterMethodList = search->clock(search->context)", self.header)
        self.assertNotIn("objc_getClassList(", self.header)
        self.assertIn("search.matches == 0", self.header)
        self.assertIn("search.reason == CVLPHighlightsLookupReasonAmbiguous", self.header)
        self.assertIn("CVLPHighlightsLookupReasonClassLimit", self.header)
        self.assertIn("CVLPHighlightsLookupReasonDeadline", self.header)
        self.assertIn("CVLPHighlightsLookupReasonClassImageMismatch", self.header)
        self.assertIn("CVLPHighlightsLookupReasonAnchorNotEnumerated", self.header)
        self.assertIn("not preemptive", self.header)

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
        self.assertIn("#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 0", self.header)
        self.assertIn("CVLPHighlightsShouldOverrideConsumption(target, exactSelector)", self.header)
        self.assertIn('selector == sel_registerName("enableStoryHighlightConsumption")', self.header)
        self.assertIn("target == CVLPHighlightsConsumptionTarget", self.header)
        consumption_wrapper = self.header.split("id block = ^BOOL(__unsafe_unretained id receiver) {", 1)[1].split("};", 1)[0]
        self.assertIn("BOOL naturalResult = ((BOOL (*)(id, SEL))invocation)", consumption_wrapper)
        self.assertLess(
            consumption_wrapper.index("CVLPHighlightsRecordInvocation(target, 1, naturalResult ? 1 : 0, 0.0)"),
            consumption_wrapper.index("CVLPHighlightsShouldOverrideConsumption(target, exactSelector)"),
        )
        self.assertIn("deliveredResult = YES", consumption_wrapper)
        self.assertIn("CVLPHighlightsRecordOverrideInvocation", consumption_wrapper)
        self.assertIn("if (CVLPHighlightsRecording)", self.header.split("static void CVLPHighlightsRecordOverrideInvocation", 1)[1].split("static void CVLPHighlightsRecordInvocation", 1)[0])
        self.assertNotIn("imp_removeBlock", self.header)
        self.assertNotIn("method_setImplementation(method, original)", self.header)
        self.assertNotIn("@try", self.header[:self.header.index("static CVLPHighlightsTreeSummary CVLPHighlightsSampleTreeSafely")])

    def test_direct_viewing_mode_is_pinned_default_off_and_single_slot_only(self):
        self.assertIn("#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 0", self.header)
        self.assertIn("#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT 0", self.header)
        self.assertIn("#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT 0", self.header)
        self.assertIn("#error Highlights viewing experiments are mutually exclusive", self.header)
        self.assertIn("static _Atomic(uintptr_t) CVLPHighlightsDirectOriginalAddress = 0", self.header)
        self.assertIn("header.filetype != MH_DYLIB", self.header)
        self.assertIn("#if !defined(__arm64__) || defined(__arm64e__)", self.header)
        self.assertIn("if ((imageBase & (sizeof(uintptr_t) - 1)) != 0)", self.header)
        self.assertIn("(consumptionSlot & (sizeof(uintptr_t) - 1)) != 0", self.header)
        self.assertIn("header.ncmds != CVLPHighlightsDirectExpectedCommandCount", self.header)
        self.assertIn("header.sizeofcmds != CVLPHighlightsDirectExpectedCommandBytes", self.header)
        self.assertIn("CVLPHighlightsDirectExpectedUUID[16]", self.header)
        self.assertIn("CVLPHighlightsDirectExpectedStub[12]", self.header)
        self.assertIn("CVLPHighlightsDirectExpectedGetter[28]", self.header)
        self.assertIn('CVLPHighlightsDirectNameEquals(segment.segname, "__TEXT")', self.header)
        self.assertIn('CVLPHighlightsDirectNameEquals(segment.segname, "__DATA")', self.header)
        self.assertIn('CVLPHighlightsDirectNameEquals(segment.segname, "__BD_TEXT")', self.header)
        self.assertIn('CVLPHighlightsDirectNameEquals(section.sectname, "__objc_clsrefs")', self.header)
        self.assertIn("CVLPHighlightsDirectMachRegionAllows", self.header)
        self.assertIn("VM_PROT_READ | VM_PROT_WRITE", self.header)
        self.assertIn("VM_PROT_READ | VM_PROT_EXECUTE", self.header)
        self.assertIn("memory->compareExchange(consumptionSlot, actualConsumption, replacementAddress", self.header)
        self.assertIn("atomic_store_explicit(&CVLPHighlightsDirectOriginalAddress, actualConsumption, memory_order_release)", self.header)
        self.assertIn("original();", self.header)
        self.assertIn("CVLPHighlightsState.directLast = naturalResult ? 1 : 0", self.header)
        self.assertIn("CVLPHighlightsDirectViewingExperimentMode == 0", self.header)
        self.assertNotIn("mach_vm_protect", self.header)
        self.assertNotIn("mprotect(", self.header)
        self.assertNotIn("ptrauth_strip", self.header)
        direct_install = self.header.split(
            "static CVLPHighlightsDirectInstallStatus CVLPHighlightsDirectValidateAndInstall(", 1
        )[1].split("static BOOL CVLPHighlightsDirectMachRegionAllows", 1)[0]
        self.assertIn("#if !CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT && !CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT", direct_install)
        self.assertIn("return CVLPHighlightsDirectDisabled", direct_install)
        self.assertNotIn("compareExchange(creationSlot", direct_install)
        self.assertNotIn("malloc(", direct_install)

    def test_ios_vm_api_and_preprocessor_balance(self):
        self.assertNotIn("#import <mach/mach_vm.h>", self.header)
        self.assertIn("vm_region_64(mach_task_self()", self.header)
        self.assertIn("vm_read_overwrite(mach_task_self()", self.header)
        self.assertIn("sizeof(vm_address_t) == sizeof(uintptr_t)", self.header)
        self.assertIn("sizeof(vm_size_t) == sizeof(size_t)", self.header)
        depth = 0
        for line in self.header.splitlines():
            if re.match(r"^\s*#\s*(if|ifdef|ifndef)\b", line):
                depth += 1
            elif re.match(r"^\s*#\s*endif\b", line):
                depth -= 1
                self.assertGreaterEqual(depth, 0)
        self.assertEqual(depth, 0)

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
        self.assertIn('parts.count != 48', self.header)
        self.assertIn('"scope", "why0", "why1", "classes0", "classes1", "mode", "overrideCalls"', self.header)
        self.assertIn('scope=1 why0=%d why1=%d classes0=%lu classes1=%lu mode=%d overrideCalls=%u', self.header)
        self.assertIn('"directMode", "directStatus", "directCalls", "directLast", "directOverrideCalls"', self.header)
        self.assertIn('directMode=%d directStatus=%d directCalls=%u directLast=%d directOverrideCalls=%u', self.header)
        self.assertIn('"earlyMode", "earlyStatus", "earlyMatches", "earlyRetained"', self.header)
        self.assertIn('earlyMode=%d earlyStatus=%d earlyMatches=%u earlyRetained=%d', self.header)
        self.assertIn('CVLPHighlightsEarlyViewingExperimentMode', self.header)
        self.assertIn('status > CVLPHighlightsEarlyInstallFailed', self.header)
        self.assertIn('strtoll(value, NULL, 10) != CVLPHighlightsViewingExperimentMode', self.header)
        self.assertIn('(CVLPHighlightsViewingExperimentMode == 0 && overrideCalls != 0)', self.header)
        self.assertIn('overrideCalls > CVLPHighlightsCountMaximum', self.header)
        self.assertIn('strtoll(value, NULL, 10) != CVLPHighlightsDirectViewingExperimentMode', self.header)
        self.assertIn('status > CVLPHighlightsDirectCompareExchangeFailed', self.header)
        self.assertIn('directOverrideCalls', self.header)
        self.assertIn('hasPrefix:@"CVLP_HIGHLIGHTS "', self.header)
        self.assertIn('containsObject:phase', self.header)
        start = self.header.split('- (void)startOnMainQueue {', 1)[1].split('- (void)scheduleSample:', 1)[0]
        self.assertNotIn('CVLPHighlightsSampleTreeSafely()', start)
        self.assertIn('initialTree.truncated = 1;', start)

    def test_early_startup_callback_is_consumption_only_bounded_and_inert_after_finish(self):
        self.assertIn("+ (void)armEarlyViewing;", self.header)
        self.assertIn("+ (void)finishEarlyViewingLoad;", self.header)
        self.assertIn("CVLPHighlightsEarlyArm();", self.header)
        self.assertIn("CVLPHighlightsEarlyFinish();", self.header)
        self.assertIn("_dyld_register_func_for_add_image(CVLPHighlightsEarlyAddImageCallback)", self.header)
        self.assertIn("static _Thread_local BOOL CVLPHighlightsEarlyArmThread", self.header)
        self.assertIn("static _Thread_local BOOL CVLPHighlightsEarlyRegistrationReplay", self.header)
        self.assertIn("CVLPHighlightsEarlyMaximumScannedImages = 4096", self.header)
        self.assertIn("CVLPHighlightsEarlyClaimAttempt()", self.header)
        self.assertIn("CVLPHighlightsDirectValidateAndInstall(imageBase, memory)", self.header)
        self.assertIn("CVLPHighlightsEarlyPinnedCandidateMatches", self.header)
        self.assertIn("CVLPHighlightsDirectExpectedUUID", self.header)
        self.assertIn("CVLPHighlightsEarlyActive, false", self.header)
        self.assertIn("CVLPHighlightsEarlyRetainedValue", self.header)
        self.assertIn("CVLPHighlightsEarlyTestSetInstaller", self.header)
        self.assertIn("CVLPHighlightsEarlyTestDeliverImageCallback", self.header)
        self.assertIn("CVLPHighlightsEarlyTestReadState", self.header)
        callback = self.header.split("static void CVLPHighlightsEarlyAddImageCallback(", 1)[1].split(
            "static void CVLPHighlightsEarlyArm(", 1
        )[0]
        for forbidden in ("CACurrentMediaTime", "malloc(", "free(", "objc_", "class_get", "UIApplication", "NSLog"):
            self.assertNotIn(forbidden, callback)
        arm_reset = self.header.split("- (void)startOnMainQueue {", 1)[1].split("- (void)scheduleSample:", 1)[0]
        for preserved in (
            "previous.directCalls",
            "previous.directOverrideCalls",
            "previous.directLast",
            "CVLPHighlightsEarlyStatusValue",
            "CVLPHighlightsEarlyMatchCount",
            "CVLPHighlightsEarlyRetainedValue",
            "self->_startedAt = CVLPHighlightsStartedAt",
        ):
            self.assertIn(preserved, arm_reset)

    def test_exact_registration_replay_terminally_closes_install_attempt(self):
        callback = self.header.split("static void CVLPHighlightsEarlyAddImageCallback(", 1)[1].split(
            "static void CVLPHighlightsEarlyArm(", 1
        )[0]
        replay = callback.split("if (CVLPHighlightsEarlyRegistrationReplay) {", 1)[1].split(
            "struct mach_header_64 header64;", 1
        )[0]
        attempt_guard = callback.index("if (atomic_load_explicit(&CVLPHighlightsEarlyAttempted, memory_order_acquire))")
        replay_guard = callback.index("if (CVLPHighlightsEarlyRegistrationReplay) {")
        self.assertLess(attempt_guard, replay_guard)
        self.assertIn("CVLPHighlightsEarlyClaimAttempt()", replay)
        self.assertIn("CVLPHighlightsEarlyPinnedCandidateMatches", replay)
        self.assertIn("CVLPHighlightsEarlyTestInstallerFunction(header, slide", replay)
        self.assertIn("CVLPHighlightsEarlyReplaySkipped", replay)
        self.assertIn("CVLPHighlightsEarlyRetainedValue, 0", replay)
        for forbidden in (
            "CVLPHighlightsDirectValidateAndInstall",
            "compareExchange(",
            "CVLPHighlightsDirectOriginalAddress",
            "CVLPHighlightsDirectReplacementAddress",
        ):
            self.assertNotIn(forbidden, replay)

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
        self.assertIn('getenv("CV_HIGHLIGHTS_RESULT_NAME")', self.fixture)
        self.assertIn('resultName.length > 100', self.fixture)
        self.assertIn('nameCharacters.invertedSet', self.fixture)
        self.assertIn('NSTemporaryDirectory()', self.fixture)
        self.assertIn('CV_HIGHLIGHTS_FIXTURE_PASS viewing=%d direct=%d', self.fixture)
        self.assertLess(self.fixture.index('runFixtureSelfTest:&failure'),
                        self.fixture.index('NSString *result = [NSString stringWithFormat:'))
        self.assertIn('result writeToFile:resultPath atomically:YES', self.fixture)
        self.assertIn("feature_owner_unique_hook", self.fixture)
        self.assertIn("boolean_false_natural_observation_distinct_from_delivery", self.fixture)
        self.assertIn("boolean_true_natural_value_and_observation_preserved", self.fixture)
        self.assertIn("creation_false_unchanged_by_experiment", self.fixture)
        self.assertIn("creation_true_unchanged_by_experiment", self.fixture)
        self.assertIn("override_requires_exact_selector_and_target", self.fixture)
        self.assertIn("other_selector_remains_natural", self.fixture)
        self.assertIn("stopped_recording_freezes_count_but_experiment_delivery_continues", self.fixture)
        self.assertIn("original_exception_forwarded", self.fixture)
        self.assertIn("consumption_original_exception_forwarded_without_override", self.fixture)
        self.assertIn("model_presence_without_extra_getter", self.fixture)
        self.assertIn("wrong_abi_not_modified", self.fixture)
        self.assertIn("inherited_method_not_modified", self.fixture)
        self.assertIn("runtime_image_ambiguity_does_not_modify_either_owner", self.fixture)
        self.assertIn("counter_saturates", self.fixture)
        self.assertIn("late_hook_disables_recording", self.fixture)
        self.assertIn("terminal_line_bound_and_no_post_stop_emit", self.fixture)
        self.assertIn("sanitizer_enforces_scope_mode_and_numeric_bounds", self.fixture)
        self.assertIn("discovery_never_invokes_resolvers", self.fixture)
        for case in (
            "image_inventory_unique_owner",
            "missing_anchor_is_incomplete",
            "incomplete_lookup_does_not_modify_implementation",
            "missing_anchor_image_is_incomplete",
            "image_inventory_limit_is_reported_and_clamped",
            "runtime_class_callback_limit_is_clamped",
            "inventory_must_contain_anchor",
            "expired_inventory_stops_before_metadata",
            "metadata_copy_time_is_inside_deadline",
            "invalid_enumerated_class_fails_closed",
            "class_from_other_image_fails_closed",
            "inherited_class_method_is_not_a_declaration",
            "same_image_duplicate_declarations_are_ambiguous",
            "runtime_image_ambiguity_does_not_modify_either_owner",
            "sanitizer_enforces_scope_mode_and_numeric_bounds",
        ):
            self.assertIn(case, self.fixture)
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
