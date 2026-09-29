"""Structural tests for preflight validation and initial guest scene geometry."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "framework_initial_geometry",
    Path(__file__).with_name("framework_initial_geometry.py"),
)
initial_geometry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(initial_geometry)


def sources():
    # Minimal fixture follows AppSceneViewController.m's pinned method order:
    # request completion, revoke, then scene setup and initial parameter capture.
    return {
        initial_geometry.SCENE_PATH: '''#import "AppSceneViewController.h"

@interface AppSceneViewController()
@property(nonatomic) BOOL cvlpRevoked;
@end

@implementation AppSceneViewController
- (instancetype)initWithBundleId:(NSString *)bundleId delegate:(id)delegate {
    dispatch_block_t handleCompletion = ^{
        if (self.cvlpRevoked) return;
                if (identifier) {
                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
                    [delegate appSceneVC:self didInitializeWithError:nil];
                    if (!self.cvlpRevoked) [self setUpAppPresenter];
                }
    };
    return self;
}
- (void)cvlpRevoke {
    self.cvlpRevoked = YES;
    self.view.hidden = YES;
    [self.extension _kill:SIGKILL];
    [self.presenter invalidate];
}
- (void)setUpAppPresenter {
    if (self.cvlpRevoked) return;
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        settings.level = 1;
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
    };
    if (@available(iOS 17.4, *)) {
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        [self addChildViewController:self.hostingController.sceneViewController];
    }
}
@end
''',
        "Unowned/Unchanged.m": "synthetic unrelated source sentinel",
    }


class FrameworkInitialGeometryTests(unittest.TestCase):
    def test_transform_returns_copy_and_preserves_unowned_sources(self):
        before = sources()
        snapshot = dict(before)

        after = initial_geometry.transform(before)

        self.assertEqual(before, snapshot)
        self.assertEqual(set(after), set(before))
        self.assertEqual(after["Unowned/Unchanged.m"], before["Unowned/Unchanged.m"])

    def test_preflight_guards_loaded_view_before_property_access_and_checks_bounds(self):
        scene = initial_geometry.transform(sources())[initial_geometry.SCENE_PATH]
        helper_start = scene.index("- (BOOL)cvlpPrepareInitialGeometry {")
        helper_end = scene.index("\n- (void)setUpAppPresenter", helper_start)
        helper = scene[helper_start:helper_end]

        self.assertLess(helper.index("NSAssert(NSThread.isMainThread"), helper.index("UIView *cvlpHostView = self.viewIfLoaded;"))
        self.assertLess(helper.index("if (!cvlpHostView) return NO;"), helper.index("cvlpHostView.window"))
        self.assertIn("UIWindowScene *cvlpHostScene = cvlpHostWindow.windowScene;", helper)
        for component in ("origin.x", "origin.y", "size.width", "size.height"):
            self.assertIn(f"isfinite(cvlpHostBounds.{component})", helper)
        self.assertIn("!cvlpHostWindow || !cvlpHostScene || !cvlpHostGeometryIsFinite", helper)
        self.assertIn("cvlpHostBounds.size.width <= 0.0", helper)
        self.assertIn("cvlpHostBounds.size.height <= 0.0", helper)
        self.assertIn("self.cvlpInitialGeometryPrepared = YES;", helper)
        self.assertIn("#import <math.h>", scene)

    def test_simulator_rejection_seam_precedes_geometry_and_scene_launch(self):
        scene = initial_geometry.transform(sources())[initial_geometry.SCENE_PATH]
        helper = scene[scene.index("- (BOOL)cvlpPrepareInitialGeometry {"):scene.index("\n- (void)setUpAppPresenter")]
        simulator_check = helper.index('CVLP_TEST_INVALID_INITIAL_GEOMETRY"] isEqualToString:@"1"')
        self.assertLess(helper.index("NSAssert(NSThread.isMainThread"), simulator_check)
        self.assertLess(simulator_check, helper.index("UIView *cvlpHostView = self.viewIfLoaded;"))
        self.assertIn("#if TARGET_OS_SIMULATOR", helper)
        self.assertIn("#endif", helper)

        setup_completion = scene[scene.index("- (instancetype)initWithBundleId:"):scene.index("\n- (void)cvlpRevoke")]
        self.assertLess(setup_completion.index("[self cvlpPrepareInitialGeometry]"), setup_completion.index("CVLP_INITIAL_GEOMETRY_REJECTED"))
        self.assertLess(setup_completion.index("CVLP_INITIAL_GEOMETRY_REJECTED"), setup_completion.index("[self cvlpRevoke];"))
        self.assertLess(setup_completion.index("[self cvlpRevoke];"), setup_completion.index("didInitializeWithError:geometryError"))
        self.assertLess(setup_completion.index("didInitializeWithError:geometryError"), setup_completion.index("registerMultitaskContainer"))
        self.assertLess(setup_completion.index("didInitializeWithError:geometryError"), setup_completion.index("didInitializeWithError:nil"))

    def test_normalizes_landscape_and_seeds_settings_and_hosting_view_early(self):
        scene = initial_geometry.transform(sources())[initial_geometry.SCENE_PATH]
        helper = scene[scene.index("- (BOOL)cvlpPrepareInitialGeometry {"):scene.index("\n- (void)setUpAppPresenter")]
        setup = scene[scene.index("- (void)setUpAppPresenter {"):]

        self.assertIn("CGRectMake(0.0, 0.0,", helper)
        self.assertIn("if (self.cvlpInitialOrientation == UIInterfaceOrientationUnknown)", helper)
        self.assertIn("self.cvlpInitialOrientation = UIInterfaceOrientationPortrait;", helper)
        self.assertIn("if (UIInterfaceOrientationIsLandscape(self.cvlpInitialOrientation))", helper)
        self.assertIn("cvlpInitialSceneFrame.size = CGSizeMake(\n            self.cvlpInitialBounds.size.height, self.cvlpInitialBounds.size.width)", helper)
        self.assertIn("self.cvlpInitialSceneFrame = cvlpInitialSceneFrame;", helper)
        foreground = setup.index("settings.foreground = YES;")
        self.assertLess(setup.index("settings.frame = self.cvlpInitialSceneFrame;"), foreground)
        self.assertLess(setup.index("settings.interfaceOrientation = self.cvlpInitialOrientation;"), foreground)
        self.assertIn("clientSettings.interfaceOrientation = self.cvlpInitialOrientation;", setup)

        assignment = setup.index("self.contentView = self.hostingController.sceneViewController.view;")
        frame = setup.index("self.contentView.frame = self.cvlpInitialBounds;", assignment)
        clips = setup.index("self.contentView.clipsToBounds = NO;", assignment)
        configure = setup.index("[scene configureParameters:", assignment)
        child = setup.index("[self addChildViewController:self.hostingController.sceneViewController];", assignment)
        self.assertEqual(frame, assignment + len("self.contentView = self.hostingController.sceneViewController.view;\n        "))
        self.assertLess(frame, clips)
        self.assertLess(frame, configure)
        self.assertLess(configure, child)

    def test_log_is_once_and_contains_only_numeric_geometry_values(self):
        scene = initial_geometry.transform(sources())[initial_geometry.SCENE_PATH]
        helper = scene[scene.index("- (BOOL)cvlpPrepareInitialGeometry {"):scene.index("\n- (void)setUpAppPresenter")]
        self.assertEqual(scene.count("CVLP_INITIAL_SCENE_GEOMETRY"), 1)
        self.assertIn("@property(nonatomic) BOOL cvlpInitialGeometryLogged;", scene)
        log_start = helper.index('NSLog(@"CVLP_INITIAL_SCENE_GEOMETRY')
        log_end = helper.index("self.cvlpInitialGeometryLogged = YES;", log_start)
        log = helper[log_start:log_end]
        for field in ("host=%.1f", "scene=%.1f", "orientation=%ld", "self.cvlpInitialBounds", "self.cvlpInitialSceneFrame"):
            self.assertIn(field, log)
        for forbidden in ("bundleIdentifier", "URL", "cookie", "password", "keychain", "token"):
            self.assertNotIn(forbidden.lower(), log.lower())

    def test_existing_revoke_body_and_setup_guard_are_preserved(self):
        before = sources()[initial_geometry.SCENE_PATH]
        after = initial_geometry.transform(sources())[initial_geometry.SCENE_PATH]
        revoke_start_before = before.index("- (void)cvlpRevoke {")
        revoke_end_before = before.index("\n- (void)setUpAppPresenter", revoke_start_before)
        revoke_start_after = after.index("- (void)cvlpRevoke {")
        revoke_end_after = after.index("\n- (BOOL)cvlpPrepareInitialGeometry", revoke_start_after)
        self.assertEqual(before[revoke_start_before:revoke_end_before], after[revoke_start_after:revoke_end_after])
        setup = after[after.index("- (void)setUpAppPresenter {"):]
        self.assertLess(setup.index("if (self.cvlpRevoked) return;"), setup.index("self.cvlpInitialGeometryPrepared"))
        self.assertEqual(after.count("- (void)setUpAppPresenter {"), 1)

    def test_missing_anchor_drift_duplicate_and_reapplication_fail_atomically(self):
        with self.assertRaisesRegex(ValueError, "sources_missing"):
            initial_geometry.transform({})

        required = (
            '#import "AppSceneViewController.h"\n',
            "@property(nonatomic) BOOL cvlpRevoked;\n",
            "                if (identifier) {\n                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];",
            "        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;\n        settings.foreground = YES;",
            "        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;",
            "        self.contentView = self.hostingController.sceneViewController.view;",
            "        FBScene *scene = self.presenter.scene;\n        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {",
            "        [self addChildViewController:self.hostingController.sceneViewController];",
        )
        for anchor in required:
            for replacement in ("__drifted_anchor__", anchor + anchor):
                before = sources()
                before[initial_geometry.SCENE_PATH] = before[initial_geometry.SCENE_PATH].replace(anchor, replacement, 1)
                snapshot = dict(before)
                with self.assertRaises(ValueError):
                    initial_geometry.transform(before)
                self.assertEqual(before, snapshot)

        with self.assertRaisesRegex(ValueError, "already_applied"):
            initial_geometry.transform(initial_geometry.transform(sources()))


if __name__ == "__main__":
    unittest.main()
