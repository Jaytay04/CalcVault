"""Source-contract checks for the synthetic Apple dyld early-loader fixture."""

from pathlib import Path
import unittest


HERE = Path(__file__).parent
FIXTURE = HERE / "CVLPEarlyLoaderFixture.m"
FIXTURE_HEADER = HERE / "CVLPEarlyLoaderFixture.h"
SYNTHETIC_IMAGE = HERE / "CVLPEarlyLoaderSyntheticImage.m"
HIGHLIGHTS_FIXTURE = HERE / "HighlightsDiagnosticsFixture.m"


class EarlyLoaderFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = FIXTURE.read_text(encoding="utf-8")
        cls.fixture_header = FIXTURE_HEADER.read_text(encoding="utf-8")
        cls.synthetic_image = SYNTHETIC_IMAGE.read_text(encoding="utf-8")
        cls.highlights_fixture = HIGHLIGHTS_FIXTURE.read_text(encoding="utf-8")

    def test_real_dylib_constructor_calls_mutable_natural_false_slot(self):
        self.assertIn('section("__DATA,__cvlpgate")', self.synthetic_image)
        self.assertIn("CVLPEarlyLoaderOriginalCallCountValue, 1", self.synthetic_image)
        self.assertIn("return NO;", self.synthetic_image)
        self.assertIn("__attribute__((constructor))", self.synthetic_image)
        self.assertIn("CVLPEarlyLoaderGateFunction gate = atomic_load_explicit", self.synthetic_image)
        self.assertIn("int32_t result = gate == NULL ? -1 : (gate() ? 1 : 0);", self.synthetic_image)

    def test_only_real_dyld_delivery_proves_pre_initializer_timing(self):
        normal_path = self.fixture[
            self.fixture.index("static BOOL CVLPEarlyLoaderRunNormalTimingPath"):
            self.fixture.index("static BOOL CVLPEarlyLoaderRunReplayOnlyPath")
        ]
        arm = normal_path.index("[CVLPHighlightsDiagnostics armEarlyViewing]")
        mismatch = normal_path.index('CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderMismatch.dylib"')
        target = normal_path.index('CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderTarget.dylib"')
        self.assertLess(arm, mismatch)
        self.assertLess(mismatch, target)
        self.assertIn("target.constructorResult() == 1", normal_path)
        self.assertIn("target.originalCallCount() == 1", normal_path)
        self.assertIn("CVLPHighlightsEarlyTestCASAttempts() == 1", normal_path)
        self.assertIn("case=callback-before-constructor", normal_path)
        self.assertNotIn("CVLPHighlightsEarlyProcessTestImage(", self.fixture)

    def test_unrelated_registration_replay_does_not_consume_normal_attempt(self):
        normal_path = self.fixture[
            self.fixture.index("static BOOL CVLPEarlyLoaderRunNormalTimingPath"):
            self.fixture.index("static BOOL CVLPEarlyLoaderRunReplayOnlyPath")
        ]
        for token in (
            "unrelatedReplayResolverCalls > 0",
            "afterArm.earlyStatus == CVLPHighlightsEarlyArmed",
            "afterArm.earlyMatches == 0",
            "targetResolverCalls == 0",
            "case=unrelated-registration-replay-does-not-consume-attempt",
        ):
            self.assertIn(token, normal_path)

    def test_exact_target_registration_replay_is_terminal_in_separate_process(self):
        replay_path = self.fixture[
            self.fixture.index("static BOOL CVLPEarlyLoaderRunReplayOnlyPath"):
            self.fixture.index("BOOL CVLPEarlyLoaderRunFixture")
        ]
        target_load = replay_path.index('CVLPEarlyLoaderLoadImage(@"CVLPEarlyLoaderTarget.dylib"')
        arm = replay_path.index("[CVLPHighlightsDiagnostics armEarlyViewing]")
        self.assertLess(target_load, arm)
        for token in (
            "afterArm.earlyStatus == CVLPHighlightsEarlyReplaySkipped",
            "afterArm.earlyMatches == 1",
            "CVLPHighlightsEarlyTestCASAttempts() == 0",
            "CVLPEarlyLoaderContext.targetReplayResolverCalls == 1",
            "case=matching-target-replay-terminal-no-cas",
            "case=replay-terminal-blocks-later-mismatch",
            "case=replay-only-observer-preserved-counters",
            "case=exact-target-replay-terminal",
        ):
            self.assertIn(token, replay_path)
        self.assertIn('getenv("CV_HIGHLIGHTS_EARLY_REPLAY_ONLY")', self.fixture)

    def test_mismatch_duplicate_finish_and_observer_contracts(self):
        for token in (
            "CVLPEarlyLoaderAlreadyLoaded.dylib",
            "CVLPEarlyLoaderMismatch.dylib",
            "CVLPHighlightsEarlyTestReplayDeliveries() > 0",
            "mismatchResolverCalls > 0",
            "duplicate_callback_does_not_compare_exchange_or_reinstall",
            "installed_pointer_retained_on_writable_data_slot",
            "finishEarlyViewingLoad",
            "post_finish_pointer_change_reported_without_reinstall",
            "finished_callback_is_inert_for_duplicate_image",
            "early_observer_start_preserves_counters_and_numeric_schema",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=mismatch-rejected",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=duplicate-no-second-cas",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=early-slot-retained",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=post-finish-pointer-change-reported",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=callback-inert-after-finish",
            "CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=observer-start-preserved-counters",
        ):
            self.assertIn(token, self.fixture)

    def test_mach_o_identity_and_writable_slot_checks_are_bounded(self):
        self.assertIn("header.sizeofcmds > 4 * 1024 * 1024", self.fixture)
        self.assertIn("header.ncmds > 4096", self.fixture)
        self.assertIn("command.cmdsize > remaining", self.fixture)
        self.assertIn('"__cvlpgate"', self.fixture)
        self.assertIn('"__DATA"', self.fixture)
        self.assertIn("CVLPHighlightsDirectRangeContains(segment.vmaddr, segment.vmsize", self.fixture)
        self.assertIn("VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE", self.fixture)
        self.assertIn("CVLPEarlyLoaderUUIDFromFile(targetPath)", self.fixture)
        self.assertIn("CVLPEarlyLoaderUUIDFromFile(unrelatedPath)", self.fixture)
        self.assertIn("CVLPEarlyLoaderUUIDFromFile(mismatchPath)", self.fixture)

    def test_fixture_is_textually_linked_and_reports_numeric_mode_fields(self):
        self.assertIn('#import "CVLPEarlyLoaderFixture.m"', self.highlights_fixture)
        self.assertIn("CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT", self.highlights_fixture)
        self.assertIn(
            'CV_HIGHLIGHTS_FIXTURE_PASS viewing=%d direct=%d early=%d\\n',
            self.highlights_fixture,
        )
        self.assertIn("CVLPHighlightsEarlyViewingExperimentMode", self.highlights_fixture)
        self.assertIn("CVLPEarlyLoaderRunFixture(failure)", self.highlights_fixture)
        self.assertIn("CVLPEarlyLoaderRunFixture(NSString * _Nullable * _Nullable failure)", self.fixture_header)


if __name__ == "__main__":
    unittest.main()
