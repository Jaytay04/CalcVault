"""Pure source-transform tests; native compilation remains a macOS check."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "framework_geometry",
    Path(__file__).with_name("framework_geometry.py"),
)
geometry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(geometry)


def sources():
    return {
        geometry.SESSION_PATH: '''@interface AppSceneViewController (CVLPLifecycle)
@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;
- (void)cvlpRevoke;
@end

@implementation CVLPGuestSession
- (void)revoke {
    self.sceneController.view.hidden = YES;
    [self.sceneController cvlpRevoke];
}
- (NSString *)summary {
    NSString *diagnostics = [NSString stringWithFormat:
        @"liveness and lifecycle details",
        groupShutdownObserved ? @"observed" : @"unproved"];
    return diagnostics;
}
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    if (self.revoked || self.sceneEnded) return;
    [vc updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        [settings setFrame:vc.view.bounds];
    }];
    vc.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}
@end
''',
        geometry.SCENE_PATH: '''@interface AppSceneViewController()
@property(nonatomic) BOOL cvlpRevoked;
@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;
- (void)cvlpRevoke;
@property int resizeDebounceToken;
@end

@implementation AppSceneViewController
- (void)setUpAppPresenter {
    if (@available(iOS 17.4, *)) {
        [self addChildViewController:self.hostingController.sceneViewController];
    }
    [self.view addSubview:_contentView];
    NSString *selection = @"fixed framework selection remains upstream";
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
}
- (void)viewWillLayoutSubviews {
    if (self.cvlpRevoked) return;
    /// Existing upstream resize behavior.
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if (self.cvlpRevoked) return;
    if(!_hostingController && self.contentView) {
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    updateSettingsBlock(settings);
    CGRect frame = settings.frame;
    if (self.contentView) {
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}
@end
''',
        "LiveContainer/LCBootstrap.m": "fixed framework guest selection sentinel",
    }


class FrameworkGeometryTests(unittest.TestCase):
    def test_transform_preserves_other_sources_and_existing_guards(self):
        before = sources()
        snapshot = dict(before)
        after = geometry.transform(before)
        self.assertEqual(before, snapshot)
        self.assertEqual(set(after), set(before))
        self.assertEqual(after["LiveContainer/LCBootstrap.m"], before["LiveContainer/LCBootstrap.m"])
        self.assertIn("if (self.revoked || self.sceneEnded) return;", after[geometry.SESSION_PATH])
        self.assertIn("[self.sceneController cvlpRevoke];", after[geometry.SESSION_PATH])
        self.assertIn("if (self.cvlpRevoked) return;", after[geometry.SCENE_PATH])
        self.assertIn("fixed framework selection remains upstream", after[geometry.SCENE_PATH])

    def test_layout_order_explicit_mask_and_guarded_initial_sync(self):
        after = geometry.transform(sources())
        session = after[geometry.SESSION_PATH]
        scene = after[geometry.SCENE_PATH]
        self.assertIn("vc.contentView.autoresizingMask = UIViewAutoresizingNone;", session)
        self.assertNotIn("vc.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;", session)
        add_view = scene.index("[self.view addSubview:_contentView];")
        did_move = scene.index("[sceneViewController didMoveToParentViewController:self];")
        skip_debounce = scene.index("self.shouldSkipDebounceOnce = YES;")
        immediate_sync = scene.index("[self updateFrameWithSettingsBlock:nil];", skip_debounce)
        self.assertLess(add_view, did_move)
        self.assertLess(did_move, skip_debounce)
        self.assertLess(skip_debounce, immediate_sync)
        self.assertIn("sceneViewController.parentViewController == self", scene)
        self.assertIn("self.usesHostingControllerAPI", scene)
        self.assertIn("if (!self.cvlpRevoked && self.view.window && !CGRectIsEmpty(self.view.bounds))", scene)

    def test_layout_and_geometry_diagnostics_are_bounded_and_allowlisted(self):
        scene = geometry.transform(sources())[geometry.SCENE_PATH]
        layout = scene[scene.index("- (void)viewWillLayoutSubviews"):
                       scene.index("- (void)updateSettingsWithBlock:")]
        self.assertLess(layout.index("if (self.cvlpRevoked) return;"), layout.index("[super viewWillLayoutSubviews];"))
        self.assertIn("!self.presenter || !self.view.window || CGRectIsEmpty(self.view.bounds)", layout)

        recorder_start = scene.index("- (void)cvlpRecordGeometry:")
        recorder_end = scene.index("- (NSString *)cvlpGeometrySummary", recorder_start)
        recorder = scene[recorder_start:recorder_end]
        for field in ("viewBounds", "contentBounds", "contentFrame", "windowBounds", "safeAreaInsets",
                      "interfaceOrientation", "parentAttached", "windowAttached", "sceneSettingsPresent",
                      "sceneFrame", "presentationPresent", "presentationBounds", "presentationFrame",
                      "contentWindowFrame", "contentClips"):
            self.assertIn(field, recorder)
        for forbidden in ("bundleIdentifier", "URL", "cookie", "password", "keychain", "token"):
            self.assertNotIn(forbidden.lower(), recorder.lower())
        self.assertIn("count >= 12", recorder)
        self.assertIn("removeObjectAtIndex:0", recorder)
        self.assertIn("isEqualToString:geometry", recorder)
        self.assertIn('NSLog(@"CVLP_GEOMETRY %@", sample);', recorder)
        self.assertEqual(scene.count("dispatch_after("), sources()[geometry.SCENE_PATH].count("dispatch_after("))

    def test_settings_geometry_sampling_occurs_after_assignment_and_has_guards(self):
        scene = geometry.transform(sources())[geometry.SCENE_PATH]
        frame_assignment = scene.index("self.contentView.frame = frame;")
        sampled_update = scene.index('[self cvlpRecordGeometry:@"settings-update"];', frame_assignment)
        self.assertLess(frame_assignment, sampled_update)
        legacy_update = scene.index("[self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];")
        legacy_sample = scene.index('[self cvlpRecordGeometry:@"settings-update"];', legacy_update)
        self.assertLess(legacy_update, legacy_sample)

    def test_missing_duplicate_drift_and_reapplication_fail_without_mutation(self):
        with self.assertRaises(ValueError):
            geometry.transform({geometry.SESSION_PATH: "only one owned file"})

        for mutate in (
            lambda value: value.__setitem__(geometry.SCENE_PATH,
                                            value[geometry.SCENE_PATH].replace(
                                                "[self.view addSubview:_contentView];", "drift", 1)),
            lambda value: value.__setitem__(geometry.SCENE_PATH,
                                            value[geometry.SCENE_PATH] + "\n    [self.view addSubview:_contentView];"),
        ):
            before = sources()
            mutate(before)
            snapshot = dict(before)
            with self.assertRaises(ValueError):
                geometry.transform(before)
            self.assertEqual(before, snapshot)

        with self.assertRaises(ValueError):
            geometry.transform(geometry.transform(sources()))


if __name__ == "__main__":
    unittest.main()
