"""Source-contract checks for the synthetic admission-metadata fixture.

These checks do not execute Objective-C or prove the Apple runtime behavior.
The matching native fixture is run by the existing Xcode simulator workflow.
"""

from pathlib import Path
import re
import unittest


HERE = Path(__file__).parent
FIXTURE = HERE / "AdmissionMetadataFixtureCases.h"
HOST_FIXTURE = HERE / "HighlightsDiagnosticsFixture.m"
HEADER = HERE / "CVLPAdmissionMetadata.h"
DIAGNOSTICS = HERE / "CVLPHighlightsDiagnostics.h"


class AdmissionMetadataFixtureSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = FIXTURE.read_text(encoding="utf-8")
        cls.host_fixture = HOST_FIXTURE.read_text(encoding="utf-8")
        cls.header = HEADER.read_text(encoding="utf-8")
        cls.diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")

    def assert_source_contains(self, source, marker):
        self.assertTrue(marker in source, f"missing source marker: {marker!r}")

    def assert_source_absent(self, source, marker):
        self.assertFalse(marker in source, f"unexpected source marker: {marker!r}")

    def test_native_cases_are_in_existing_fail_closed_self_test(self):
        self.assert_source_contains(self.host_fixture, '#import "AdmissionMetadataFixtureCases.h"')
        self.assert_source_contains(self.host_fixture, "CVLPAdmissionRunFixtureCases(failure)")
        self.assert_source_contains(self.host_fixture, "CV_ADMISSION_METADATA_FIXTURE_PASS\\n")
        self.assertLess(
            self.host_fixture.index("CVLPAdmissionRunFixtureCases(failure)"),
            self.host_fixture.index('NSString *result = [NSString stringWithFormat:'),
        )
        self.assert_source_contains(self.host_fixture, "admission=%d\\n")
        self.assert_source_contains(self.host_fixture, "CVLP_HIGHLIGHTS_ADMISSION_METADATA")

    def test_runtime_sampling_is_limited_to_sequences_one_and_four(self):
        scheduler = self.diagnostics.split(
            "- (void)takeSample:(NSUInteger)sampleNumber {", 1
        )[1].split("- (void)stopWithReason:", 1)[0]
        self.assert_source_contains(
            scheduler, "(sampleNumber == 1 || sampleNumber == 4) && self->_admissionAttempts < 2"
        )
        self.assert_source_contains(scheduler, "self->_admissionAttempts++;")
        self.assert_source_contains(scheduler, "(uint32_t)self->_admissionAttempts")
        attempt = scheduler.split("if ((sampleNumber == 1 || sampleNumber == 4)", 1)[1]
        sink = attempt.index("[CVLPProbe recordGuestDiagnostic:admissionLine]")
        self.assertLess(attempt.index("if (!self->_stopped && CACurrentMediaTime()"), sink)
        self.assertLess(attempt.index("admissionLine != nil && CVLPAdmissionLineIsSanitized(admissionLine)"), sink)
        self.assert_source_absent(attempt[:sink], "method_setImplementation(")
        self.assert_source_absent(attempt[:sink], "objc_msgSend")

    def test_fixture_covers_pins_rejections_and_never_mutates_guest_memory(self):
        for case in (
            "admission_pinned_synthetic_image_valid",
            "admission_wrong_uuid_rejected",
            "admission_wrong_architecture_rejected",
            "admission_wrong_header_rejected",
            "admission_wrong_section_rejected",
            "admission_wrong_code_rejected",
            "admission_wrong_class_slot_rejected",
            "admission_wrong_selector_slot_rejected",
            "admission_null_input_rejected",
            "admission_nonreadable_metadata_rejected",
            "admission_executable_metadata_rejected",
            "admission_address_overflow_rejected",
            "admission_read_failure_rejected",
            "admission_selector_second_read_change_clears_result",
        ):
            self.assert_source_contains(self.fixture, case)
        validation = self.fixture.split(
            "static BOOL CVLPAdmissionRunImageValidationCases(", 1
        )[1].split("static BOOL CVLPAdmissionRunDiscoveryCases(", 1)[0]
        self.assert_source_contains(self.fixture, ".compareExchange = CVLPAdmissionFixtureCompareExchange")
        self.assert_source_contains(validation, "CASCalls == 0")
        self.assert_source_contains(validation, "slotsBefore")
        self.assert_source_contains(validation, "slotsAfter")

    def test_discovery_is_declared_method_only_and_never_executes_guest_methods(self):
        for case in (
            "admission_instance_declared_method_matched",
            "admission_same_selector_multiple_slots_counted",
            "admission_metaclass_declared_method_matched",
            "admission_inherited_method_not_counted",
            "admission_duplicate_matches_are_ambiguous_examples_not_callers",
            "admission_image_mismatch_is_incomplete",
            "admission_deadline_stops_scan",
            "admission_class_cap_stops_scan",
            "admission_method_cap_stops_scan",
            "admission_runtime_resolvers_not_called",
            "admission_original_methods_not_invoked",
        ):
            self.assert_source_contains(self.fixture, case)
        self.assert_source_contains(self.fixture, "CVLPAdmissionScanProvidedClasses(")
        self.assert_source_contains(self.fixture, "CVLPFixtureResolverCalls == 0")
        self.assert_source_contains(self.fixture, "CVLPAdmissionFixtureMethodCalls == 0")
        self.assert_source_contains(self.fixture, "result.exampleOwners")
        self.assert_source_absent(self.fixture, "method_invoke(")
        self.assert_source_absent(self.fixture, "objc_msgSend")

    def test_identifiers_and_diagnostic_schema_reject_content_and_spoofed_fields(self):
        for case in (
            "admission_safe_identifier_names_only",
            "admission_nul_return_encoding_is_unknown",
            "admission_line_schema_rejects_content_path_url",
            "admission_line_schema_rejects_unbounded_names_and_line",
            "admission_line_schema_rejects_bad_numeric_fields",
            "admission_line_schema_rejects_spoofed_extra_fields",
        ):
            self.assert_source_contains(self.fixture, case)
        self.assert_source_contains(self.fixture, "CVLPAdmissionSelectorNameIsSafe")
        self.assert_source_contains(self.fixture, "CVLPAdmissionLineIsSanitized")
        self.assert_source_contains(self.fixture, "CVLPAdmissionFormatLine")
        for forbidden in ("/private/", "https://", "text=", "path=", "profile="):
            self.assert_source_contains(self.fixture, forbidden)
        self.assert_source_contains(self.fixture, "hiddenpayload")
        self.assert_source_contains(self.fixture, "(unichar)0x7f")

    def test_production_helper_uses_only_bounded_reads_and_runtime_metadata(self):
        for marker in (
            "CVLPAdmissionValidateImage(",
            "CVLPAdmissionValidateImageWithExpectedDigest(",
            "CVLPAdmissionScanProvidedClasses(",
            "CVLPAdmissionSelectorNameIsSafe(",
            "CVLPAdmissionLineIsSanitized(",
            "CVLPAdmissionFormatLine(",
            "memory->read(",
            "memory->regionAllows(",
            "class_copyMethodList(",
            "method_getName(",
            "sel_getName(",
            "method_getNumberOfArguments(",
            "static const CFTimeInterval CVLPAdmissionScanDeadline = 1.5",
            "startedAt + CVLPAdmissionScanDeadline",
        ):
            self.assert_source_contains(self.header, marker)
        for marker in (
            "memory->compareExchange",
            "method_setImplementation(",
            "objc_msgSend",
            "class_getInstanceMethod(",
            "class_getClassMethod(",
        ):
            self.assert_source_absent(self.header, marker)
        self.assertTrue(re.search(r"CVLPAdmissionMaximumClassCount\s*=\s*100000", self.header),
            "missing bounded class-count constant")
        self.assertTrue(re.search(r"CVLPAdmissionMaximumMethodsPerList\s*=\s*4096", self.header),
            "missing bounded method-list constant")

    def test_build_mode_is_default_off_and_mutually_exclusive(self):
        self.assert_source_contains(self.diagnostics, "#define CVLP_HIGHLIGHTS_ADMISSION_METADATA 0")
        self.assert_source_contains(self.diagnostics, "CVLP_HIGHLIGHTS_ADMISSION_METADATA must be 0 or 1")
        self.assert_source_contains(
            self.diagnostics, "Admission metadata discovery cannot be combined with viewing overrides"
        )
        self.assert_source_contains(self.diagnostics, "CVLP_HIGHLIGHTS_ADMISSION_METADATA")
        self.assert_source_contains(self.host_fixture, "CVLP_HIGHLIGHTS_ADMISSION_METADATA")


if __name__ == "__main__":
    unittest.main()
