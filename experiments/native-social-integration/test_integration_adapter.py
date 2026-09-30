import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('adapter', ROOT / 'prepare-integration.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class IntegrationAdapterTests(unittest.TestCase):
    def sources(self):
        return {
            adapter.APP: 'Build 20 framework portrait test 1',
            adapter.BOOT: '''// three fixed path guards in the retained invokeAppMain loader:
// native-framework-research native-framework-research native-framework-research
int LiveContainerMain(int argc, char *argv[]) {
    // retained shared initialization and simulator-only prepatch helper
    NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];
    moveSharedAppFolderBack(); dumpPreferenceToPath(); restoreCookies(); loadSelfTweaks();
}
#ifdef DEBUG
int callAppMain(int argc, char *argv[]) { return 0; }
''',
            adapter.PROBE: '''Build marker: build20-framework-portrait1.
// native-framework-research
#if !TARGET_OS_SIMULATOR
    if (![CVLPMigrationFixture[@"ready"] boolValue]) {
        return @"Synthetic migration did not finish; guest launch blocked.";
    }
#endif
// independent synthetic file and Keychain controls remain
''',
            adapter.PROJECT: '\t\t\t\tOTHER_LDFLAGS = "-Wl,-U,_OBJC_CLASS_$_RBSTarget";\n' * 2,
            adapter.SESSION: 'native-framework-research',
            adapter.SCENE: 'native-framework-research native-framework-research',
            adapter.EXTENSION: 'native-framework-research native-framework-research'
        }

    def test_host_cannot_restore_data_or_dispatch_a_selected_guest(self):
        result = adapter.transform(self.sources(), 'integration app root')
        boot = result[adapter.BOOT]
        for removed in ('moveSharedAppFolderBack', 'dumpPreferenceToPath', 'restoreCookies', 'loadSelfTweaks'):
            self.assertNotIn(removed, boot)
        self.assertIn('if (isLiveProcess)', boot)
        self.assertIn('return 96', boot)
        self.assertEqual(boot.count('invokeAppMain('), 1)
        self.assertIn('retained shared initialization', boot)

    def test_does_not_forge_migration_success_or_remove_boundary_controls(self):
        probe = adapter.transform(self.sources(), 'root')[adapter.PROBE]
        self.assertNotIn('setMigrationFixture', probe)
        self.assertIn('migration fixture not repeated', probe)
        self.assertIn('independent synthetic file and Keychain controls remain', probe)
        self.assertIn('errno != ENOENT', probe)
        self.assertIn('ALTCertificate.p12', probe)

    def test_links_only_two_ui_framework_configurations(self):
        project = adapter.transform(self.sources(), 'root')[adapter.PROJECT]
        self.assertEqual(project.count('-framework CalcVaultKit'), 2)
        self.assertEqual(project.count('FRAMEWORK_SEARCH_PATHS'), 2)
        self.assertEqual(project.count('SWIFT_INCLUDE_PATHS'), 2)

    def test_drift_or_repeat_is_rejected_before_writes(self):
        for key in adapter.NAMES:
            source = self.sources()
            source[key] = ''
            with self.assertRaises(ValueError):
                adapter.transform(source, 'root')
        prepared = adapter.transform(self.sources(), 'root')
        with self.assertRaises(ValueError):
            adapter.transform(prepared, 'root')

    def test_device_root_has_no_automatic_authentication_or_guest_launch(self):
        app = (ROOT / 'IntegrationApp.swift').read_text()
        for forbidden in ('authenticate(', 'completeAuthentication(', '.startNativeGuest(', 'CVLP_AUTORUN'):
            self.assertNotIn(forbidden, app)
        self.assertIn('CalcVaultIntegratedRootView(host: host)', app)

    def test_keeps_synthetic_data_separate_from_existing_private_guest(self):
        prepared = adapter.transform(self.sources(), 'root')
        for name in (adapter.BOOT, adapter.PROBE, adapter.SESSION, adapter.SCENE, adapter.EXTENSION):
            self.assertNotIn('native-framework-research', prepared[name])
            self.assertIn('integration-synthetic-22', prepared[name])


if __name__ == '__main__':
    unittest.main()
