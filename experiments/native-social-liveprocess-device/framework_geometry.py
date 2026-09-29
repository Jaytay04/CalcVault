"""Apply bounded geometry and hosting-layout diagnostics to the research guest."""

SESSION_PATH = "LiveContainer/CVLPGuestSession.m"
SCENE_PATH = "MultitaskSupport/AppSceneViewController.m"
OWNED_PATHS = (SESSION_PATH, SCENE_PATH)


def _require_once(source, anchor):
    if source.count(anchor) != 1:
        raise ValueError(f"framework_geometry_anchor_drift:{anchor[:80]!r}")


def _replace_once(source, anchor, replacement):
    _require_once(source, anchor)
    return source.replace(anchor, replacement, 1)


def transform(sources):
    """Return a transformed copy, validating every owned anchor before edits."""
    if not all(path in sources for path in OWNED_PATHS):
        raise ValueError("framework_geometry_sources_missing")

    session = sources[SESSION_PATH]
    scene = sources[SCENE_PATH]
    if "cvlpGeometrySummary" in session or "CVLP_GEOMETRY" in session + scene:
        raise ValueError("framework_geometry_already_applied")

    session_anchors = (
        "@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;\n"
        "- (void)cvlpRevoke;\n@end",
        "    vc.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;",
        '        groupShutdownObserved ? @"observed" : @"unproved"];',
        "- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {\n"
        "    if (self.revoked) return;",
    )
    scene_anchors = (
        "@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;\n"
        "- (void)cvlpRevoke;\n@property int resizeDebounceToken;",
        "        [self addChildViewController:self.hostingController.sceneViewController];",
        "    [self.view addSubview:_contentView];",
        "    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];\n}",
        "- (void)viewWillLayoutSubviews {\n    if (self.cvlpRevoked) return;\n",
        "        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];\n        return;",
        "    } else {\n"
        "        // This method can be called while contentView is nil to set up initial frame\n"
        "        self.view.frame = frame;\n"
        "    }\n}",
        "- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {\n"
        "    if (self.cvlpRevoked) return;",
    )
    for anchor in session_anchors:
        _require_once(session, anchor)
    for anchor in scene_anchors:
        _require_once(scene, anchor)

    # Session-side changes stay narrow: explicit frame updates own sizing, and
    # the host report receives only the geometry summary retained by the scene.
    session = _replace_once(
        session,
        "@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;\n- (void)cvlpRevoke;\n@end",
        "@property(nonatomic, readonly) NSUInteger cvlpPreRevokeAttemptCount;\n"
        "- (void)cvlpRevoke;\n"
        "- (NSString *)cvlpGeometrySummary;\n@end",
    )
    session = _replace_once(
        session,
        "    vc.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;",
        "    vc.contentView.autoresizingMask = UIViewAutoresizingNone;",
    )
    session = _replace_once(
        session,
        '        groupShutdownObserved ? @"observed" : @"unproved"];',
        '        groupShutdownObserved ? @"observed" : @"unproved"];\n'
        '    NSString *geometry = self.sceneController.cvlpGeometrySummary ?: @"none";\n'
        '    diagnostics = [diagnostics stringByAppendingFormat:@"; geometry={%@}", geometry];',
    )

    scene = _replace_once(
        scene,
        "@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;\n"
        "- (void)cvlpRevoke;\n@property int resizeDebounceToken;",
        "@property(nonatomic) NSUInteger cvlpPreRevokeAttemptCount;\n"
        "- (void)cvlpRevoke;\n"
        "@property(nonatomic, strong) NSMutableArray<NSString *> *cvlpGeometrySamples;\n"
        "@property(nonatomic, copy) NSString *cvlpLastGeometrySnapshot;\n"
        "@property int resizeDebounceToken;",
    )
    scene = _replace_once(
        scene,
        "    [self.view addSubview:_contentView];",
        "    [self.view addSubview:_contentView];\n"
        "    if (@available(iOS 17.0, *)) {\n"
        "        if (self.usesHostingControllerAPI) {\n"
        "            UIViewController *sceneViewController = self.hostingController.sceneViewController;\n"
        "            if (sceneViewController.parentViewController == self) {\n"
        "                [sceneViewController didMoveToParentViewController:self];\n"
        "            }\n"
        "        }\n"
        "    }",
    )
    scene = _replace_once(
        scene,
        "    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];\n}",
        "    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];\n"
        "    if (!self.cvlpRevoked && self.view.window && !CGRectIsEmpty(self.view.bounds)) {\n"
        "        self.shouldSkipDebounceOnce = YES;\n"
        "        [self updateFrameWithSettingsBlock:nil];\n"
        '        [self cvlpRecordGeometry:@"attached-setup"];\n'
        "    }\n}",
    )

    geometry_methods = '''- (void)cvlpRecordGeometry:(NSString *)phase {
    if (self.cvlpRevoked || !self.view.window || CGRectIsEmpty(self.view.bounds)) return;
    UIWindow *window = self.view.window;
    UIInterfaceOrientation orientation = window.windowScene.interfaceOrientation;
    UIApplicationSceneSettings *sceneSettings = (UIApplicationSceneSettings *)self.presenter.scene.settings;
    UIView *presentationView = self.presenter.presentationView;
    CGRect contentWindowFrame = self.contentView ? [self.contentView convertRect:self.contentView.bounds toView:window] : CGRectZero;
    NSString *geometry = [NSString stringWithFormat:
        @"viewBounds=%@,contentBounds=%@,contentFrame=%@,windowBounds=%@,safeAreaInsets=%@,interfaceOrientation=%ld,parentAttached=%d,windowAttached=%d,contentWindowAttached=%d,sceneSettingsPresent=%d,sceneFrame=%@,presentationPresent=%d,presentationBounds=%@,presentationFrame=%@,contentWindowFrame=%@,contentClips=%d",
        NSStringFromCGRect(self.view.bounds), NSStringFromCGRect(self.contentView.bounds),
        NSStringFromCGRect(self.contentView.frame),
        NSStringFromCGRect(window.bounds), NSStringFromUIEdgeInsets(self.view.safeAreaInsets),
        (long)orientation, self.parentViewController != nil, window != nil,
        self.contentView.window == window, sceneSettings != nil, NSStringFromCGRect(sceneSettings.frame),
        presentationView != nil, NSStringFromCGRect(presentationView.bounds), NSStringFromCGRect(presentationView.frame),
        NSStringFromCGRect(contentWindowFrame), self.contentView.clipsToBounds];
    if ([self.cvlpLastGeometrySnapshot isEqualToString:geometry]) return;
    self.cvlpLastGeometrySnapshot = geometry;
    if (!self.cvlpGeometrySamples) self.cvlpGeometrySamples = [NSMutableArray array];
    NSString *sample = [NSString stringWithFormat:@"phase=%@,%@", phase, geometry];
    if (self.cvlpGeometrySamples.count >= 12) [self.cvlpGeometrySamples removeObjectAtIndex:0];
    [self.cvlpGeometrySamples addObject:sample];
    NSLog(@"CVLP_GEOMETRY %@", sample);
}

- (NSString *)cvlpGeometrySummary {
    return [self.cvlpGeometrySamples componentsJoinedByString:@" | "] ?: @"";
}

'''
    scene = _replace_once(
        scene,
        "- (void)viewWillLayoutSubviews {\n    if (self.cvlpRevoked) return;\n",
        geometry_methods
        + "- (void)viewWillLayoutSubviews {\n"
        "    if (self.cvlpRevoked) return;\n"
        "    [super viewWillLayoutSubviews];\n"
        "    if (!self.presenter || !self.view.window || CGRectIsEmpty(self.view.bounds)) return;\n",
    )
    scene = _replace_once(
        scene,
        "        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];\n        return;",
        "        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];\n"
        "        if (!self.cvlpRevoked && self.view.window && !CGRectIsEmpty(self.view.bounds)) {\n"
        '            [self cvlpRecordGeometry:@"settings-update"];\n'
        "        }\n"
        "        return;",
    )
    scene = _replace_once(
        scene,
        "    } else {\n"
        "        // This method can be called while contentView is nil to set up initial frame\n"
        "        self.view.frame = frame;\n"
        "    }\n}",
        "    } else {\n"
        "        // This method can be called while contentView is nil to set up initial frame\n"
        "        self.view.frame = frame;\n"
        "    }\n"
        "    if (!self.cvlpRevoked && self.view.window && !CGRectIsEmpty(self.view.bounds)) {\n"
        '        [self cvlpRecordGeometry:@"settings-update"];\n'
        "    }\n}",
    )

    result = dict(sources)
    result[SESSION_PATH] = session
    result[SCENE_PATH] = scene
    return result
