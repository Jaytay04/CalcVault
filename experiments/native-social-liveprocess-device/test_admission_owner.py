"""Source-contract checks for the native admission-owner fixture.

The matching Objective-C cases run in the existing Apple native fixture.
These checks protect the fixture's presence and key safety boundaries; they do
not claim to execute the Objective-C runtime on this Python host.
"""

from pathlib import Path
import unittest


HERE = Path(__file__).parent
FIXTURE = HERE / "AdmissionOwnerFixtureCases.h"
HEADER = HERE / "CVLPAdmissionOwnerMetadata.h"
HOST_FIXTURE = HERE / "HighlightsDiagnosticsFixture.m"
DIAGNOSTICS = HERE / "CVLPHighlightsDiagnostics.h"


class AdmissionOwnerFixtureSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = FIXTURE.read_text(encoding="utf-8")
        cls.header = HEADER.read_text(encoding="utf-8")
        cls.host_fixture = HOST_FIXTURE.read_text(encoding="utf-8")
        cls.diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")

    def assert_contains(self, source, marker):
        self.assertIn(marker, source, f"missing source marker: {marker!r}")

    def assert_absent(self, source, marker):
        self.assertNotIn(marker, source, f"unexpected source marker: {marker!r}")

    def test_fixture_covers_imp_ownership_and_failure_boundaries(self):
        for case in (
            "admission_owner_instance_imp_matched_without_invocation",
            "admission_owner_metaclass_imp_matched_without_invocation",
            "admission_owner_inherited_method_not_counted",
            "admission_owner_same_selector_different_imp_not_matched",
            "admission_owner_same_imp_category_ambiguity_has_no_owner_or_abi",
            "admission_owner_unsupported_signature_withdraws_abi",
            "admission_owner_malformed_selector_is_not_emitted",
            "admission_owner_malformed_class_name_is_not_emitted",
            "admission_owner_method_cap_before_later_match_keeps_lower_bound_only",
            "admission_owner_method_cap_after_match_is_lower_bound",
            "admission_owner_class_cap_rejects_without_scanning",
            "admission_owner_image_guard_withdraws_owner_and_abi",
            "admission_owner_image_mismatch_after_skip_preserves_terminal_reason",
            "admission_owner_deadline_after_match_clears_names_and_signature",
            "admission_owner_reference_mapping_failure_after_skip_clears_stale_identifiers",
            "admission_owner_reference_change_clears_names_and_signature",
            "admission_owner_wrong_digest_clears_validated_image_before_scan",
            "admission_owner_objc_enumerate_classes_image_bound_unique_getter_imp_no_call",
            "admission_owner_terminal_formatter_clears_stale_identifiers",
            "admission_owner_schema_rejects_content_path_url_query_control_nul_and_spoofed_fields",
        ):
            self.assert_contains(self.fixture, case)
        self.assert_contains(self.fixture, "CVLPAdmissionOwnerRunFixtureCases(NSString **failure)")
        self.assert_contains(self.fixture, "CVLPAdmissionFixtureCreateMethodCapClass()")
        self.assert_contains(self.fixture, "CVLPAdmissionMaximumMethodsPerList + 1")
        self.assert_contains(self.fixture, "CVLPAdmissionOwnerFixtureMethodCalls == 0")
        self.assert_contains(self.fixture, "CVLPAdmissionOwnerFixtureGetterCalls == 0")
        self.assert_contains(self.fixture, "CVLPAdmissionFixtureMethodCalls == 0")
        self.assert_contains(self.fixture, "CVLPAdmissionFixtureMethodCapCalls == 0")
        self.assert_contains(self.fixture, "fixture.CASCalls == 0")

    def test_fixture_uses_metadata_only_and_never_calls_or_replaces_imps(self):
        self.assert_contains(self.fixture, "method_getImplementation(method)")
        self.assert_contains(self.fixture, "CVLPAdmissionOwnerScanProvidedClasses(")
        self.assert_contains(self.fixture, "CVLPAdmissionOwnerEnumerateClass(")
        self.assert_contains(self.fixture, "objc_enumerateClasses(")
        for marker in (
            "objc_msgSend",
            "method_invoke(",
            "method_setImplementation(",
            "imp_implementationWithBlock",
        ):
            self.assert_absent(self.fixture, marker)

    def test_output_contract_is_exact_and_rejects_unsafe_content(self):
        self.assert_contains(self.fixture, "tokens.count == 15")
        self.assert_contains(self.fixture, "@\"CVLP_ADMISSION_OWNER\"")
        self.assert_contains(self.fixture, "@\"callable=0\"")
        for marker in (
            "badPath",
            "badURL",
            "badQuery",
            "badNUL",
            "badControl",
            "badCallable",
            "badNumber",
            "badExtra",
            "synthetic-secret",
        ):
            self.assert_contains(self.fixture, marker)

    def test_production_scans_actual_imps_with_a_pinned_image_enumerator(self):
        self.assert_contains(self.header, "method_getImplementation(method)")
        self.assert_contains(self.header, "(uintptr_t)implementation != context->targetIMP")
        self.assert_contains(self.header, "class_copyMethodList(owner, &count)")
        self.assert_contains(self.header, "classCount > CVLPAdmissionMaximumClassCount")
        self.assert_contains(self.header, "count > CVLPAdmissionMaximumMethodsPerList")
        self.assert_contains(self.header, "startedAt + CVLPAdmissionScanDeadline")
        self.assert_contains(self.header, ".deadlineAt = deadlineAt")
        self.assert_contains(self.header, "objc_enumerateClasses((const void *)validated.imageBase")
        self.assert_contains(self.header, "class_getImageName(cls)")
        self.assert_contains(self.header, "CVLPAdmissionRecheckReferences(")
        self.assert_contains(self.header, "CVLPAdmissionOwnerClear(result, YES)")
        self.assert_contains(self.header, "CVLPAdmissionMaximumMethodsPerList")
        for marker in (
            "objc_copyClassNamesForImage(",
            "objc_lookUpClass(",
            "objc_getClassList(",
            "NSClassFromString(",
            "class_getInstanceMethod(",
            "class_getClassMethod(",
            "method_invoke(",
            "objc_msgSend",
            "method_setImplementation(",
        ):
            self.assert_absent(self.header, marker)

    def test_testing_imp_injection_does_not_enter_production_path(self):
        testing_declaration = self.header.split(
            "#if defined(CVLP_HIGHLIGHTS_TESTING)", 1
        )[1].split("#endif", 1)[0]
        self.assert_contains(testing_declaration, "CVLPAdmissionOwnerScanProvidedClasses(")
        production = self.header.split(
            "static NSString *CVLPAdmissionOwnerMetadataLineForAnchor(Class anchor, uint32_t sequence) {",
            1,
        )[1]
        self.assert_contains(production, "CVLPAdmissionValidateImage(")
        self.assert_contains(production, "CVLPHighlightsDirectAddress(validated.imageBase, CVLPAdmissionFunctionVM")
        self.assert_contains(production, "objc_enumerateClasses((const void *)validated.imageBase")

    def test_native_owner_cases_run_before_the_persisted_completion_bit(self):
        self.assert_contains(self.host_fixture, '#import "AdmissionOwnerFixtureCases.h"')
        call = "if (!CVLPAdmissionOwnerRunFixtureCases(failure)) { return NO; }"
        completion = "CVLPAdmissionOwnerFixtureCompleted = YES;"
        self.assert_contains(self.host_fixture, call)
        self.assertLess(self.host_fixture.index(call), self.host_fixture.index(completion))
        self.assertEqual(self.host_fixture.count(completion), 1)
        self.assert_contains(self.host_fixture, "owner=%d admissionCases=%d ownerCases=%d")
        self.assert_contains(self.host_fixture, "CVLPAdmissionOwnerFixtureCompleted, replayTerminal]")

        owner_start = self.host_fixture.split(
            "#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA\n    Method untouchedMethods[] = {", 1
        )[1].split("#endif\n#if CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT", 1)[0]
        self.assert_contains(owner_start, "owner_start_never_installs_or_invokes_highlights_methods")
        self.assert_contains(
            owner_start,
            "method_getImplementation(untouchedMethods[index]) == untouchedImplementations[index]",
        )
        self.assert_contains(
            owner_start,
            "ownerStartObserver->_installStatuses[index] == CVLPHighlightsInstallUnknown",
        )
        self.assert_contains(owner_start, "CVLPHighlightsState.counts[index] == 0")

    def test_owner_mode_keeps_startup_inert_and_sampling_bounded(self):
        self.assert_contains(self.diagnostics, "#define CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA 0")
        start = self.diagnostics.split("- (void)startOnMainQueue {", 1)[1].split(
            "- (void)scheduleSample:", 1
        )[0]
        inactive = start.split("#if !CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA", 1)[1]
        production_installs, owner_branch = inactive.split(
            "#else\n    // Owner discovery must see untouched Method metadata.", 1
        )
        owner_branch = owner_branch.split("#endif", 1)[0]
        for marker in (
            "CVLPHighlightsInstallClassBoolean(",
            "CVLPHighlightsDirectInstallForAnchor(",
            "CVLPHighlightsInstallInstance(",
        ):
            self.assert_contains(production_installs, marker)
            self.assert_absent(owner_branch, marker)
        self.assert_contains(owner_branch, "self->_installStatuses[index] = CVLPHighlightsInstallUnknown")

        scheduler = self.diagnostics.split("- (void)takeSample:(NSUInteger)sampleNumber {", 1)[1].split(
            "- (void)stopWithReason:", 1
        )[0]
        attempt_guard = "(sampleNumber == 1 || sampleNumber == 4) && self->_admissionAttempts < 2"
        self.assert_contains(scheduler, attempt_guard)
        self.assertEqual(scheduler.count("self->_admissionAttempts++;"), 1)
        attempt = scheduler.split(attempt_guard, 1)[1]
        owner_branch = attempt.split("#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA", 1)[1].split(
            "#else", 1
        )[0]
        self.assert_contains(owner_branch, "CVLPAdmissionOwnerMetadataLineForAnchor(")
        self.assert_contains(owner_branch, "CVLPAdmissionOwnerLineIsSanitized(admissionLine)")
        self.assert_contains(attempt, "[CVLPProbe recordGuestDiagnostic:admissionLine]")
        self.assert_contains(attempt, "CACurrentMediaTime() - self->_startedAt < CVLPHighlightsDeadline")

        self.assert_contains(self.header, "deadlineAt = startedAt + CVLPAdmissionScanDeadline")
        self.assertGreaterEqual(self.header.count(".deadlineAt = deadlineAt"), 2)


if __name__ == "__main__":
    unittest.main()
