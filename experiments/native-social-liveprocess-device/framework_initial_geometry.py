"""Capture valid host geometry before accepting a synthetic guest launch."""

SCENE_PATH = "MultitaskSupport/AppSceneViewController.m"
OWNED_PATHS = (SCENE_PATH,)


def _require_once(source, anchor):
    if source.count(anchor) != 1:
        raise ValueError(f"framework_initial_geometry_anchor_drift:{anchor[:80]!r}")


def _replace_once(source, anchor, replacement):
    _require_once(source, anchor)
    return source.replace(anchor, replacement, 1)


def transform(sources):
    """Return a transformed source map, validating every anchor before editing."""
    if not all(path in sources for path in OWNED_PATHS):
        raise ValueError("framework_initial_geometry_sources_missing")

    scene = sources[SCENE_PATH]
    if ("CVLP_INITIAL_SCENE_GEOMETRY" in scene
            or "cvlpPrepareInitialGeometry" in scene):
        raise ValueError("framework_initial_geometry_already_applied")

    anchors = (
        '#import "AppSceneViewController.h"\n',
        "@property(nonatomic) BOOL cvlpRevoked;\n",
        "                if (identifier) {\n"
        "                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];",
        "        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;\n"
        "        settings.foreground = YES;",
        "        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;",
        "        self.contentView = self.hostingController.sceneViewController.view;",
        "        FBScene *scene = self.presenter.scene;\n"
        "        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {",
        "        [self addChildViewController:self.hostingController.sceneViewController];",
        "- (void)setUpAppPresenter {\n    if (self.cvlpRevoked || self.cvlpSceneEnded) return;",
    )
    for anchor in anchors:
        _require_once(scene, anchor)

    helper_anchors = anchors[2:3]
    success_branch = scene[scene.index("- (instancetype)initWithBundleId:"):]
    method_end = success_branch.find("\n- (void)", 1)
    if method_end < 0:
        method_end = len(success_branch)
    success_branch = success_branch[:method_end]
    if any(success_branch.count(anchor) != 1 for anchor in helper_anchors):
        raise ValueError("framework_initial_geometry_success_anchor_drift")

    setup_anchors = anchors[3:8]
    setup_start = scene.index("- (void)setUpAppPresenter {")
    setup_end = scene.find("\n- (void)", setup_start + 1)
    if setup_end < 0:
        setup_end = len(scene)
    setup = scene[setup_start:setup_end]
    positions = [setup.find(anchor) for anchor in setup_anchors]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValueError("framework_initial_geometry_setup_order_drift")

    helper = '''- (BOOL)cvlpPrepareInitialGeometry {
    NSAssert(NSThread.isMainThread, @"Initial scene geometry must be captured on main");
    if (self.cvlpRevoked || self.cvlpSceneEnded) return NO;
#if TARGET_OS_SIMULATOR
    if ([NSProcessInfo.processInfo.environment[@"CVLP_TEST_INVALID_INITIAL_GEOMETRY"] isEqualToString:@"1"]) return NO;
#endif
    UIView *cvlpHostView = self.viewIfLoaded;
    if (!cvlpHostView) return NO;
    UIWindow *cvlpHostWindow = cvlpHostView.window;
    UIWindowScene *cvlpHostScene = cvlpHostWindow.windowScene;
    CGRect cvlpHostBounds = cvlpHostView.bounds;
    BOOL cvlpHostGeometryIsFinite =
        isfinite(cvlpHostBounds.origin.x) && isfinite(cvlpHostBounds.origin.y) &&
        isfinite(cvlpHostBounds.size.width) && isfinite(cvlpHostBounds.size.height);
    if (!cvlpHostWindow || !cvlpHostScene || !cvlpHostGeometryIsFinite ||
        cvlpHostBounds.size.width <= 0.0 || cvlpHostBounds.size.height <= 0.0) {
        return NO;
    }
    self.cvlpInitialBounds = CGRectMake(0.0, 0.0,
        cvlpHostBounds.size.width, cvlpHostBounds.size.height);
    self.cvlpInitialOrientation = cvlpHostScene.interfaceOrientation;
    if (self.cvlpInitialOrientation == UIInterfaceOrientationUnknown) {
        self.cvlpInitialOrientation = UIInterfaceOrientationPortrait;
    }
    CGRect cvlpInitialSceneFrame = self.cvlpInitialBounds;
    if (UIInterfaceOrientationIsLandscape(self.cvlpInitialOrientation)) {
        cvlpInitialSceneFrame.size = CGSizeMake(
            self.cvlpInitialBounds.size.height, self.cvlpInitialBounds.size.width);
    }
    self.cvlpInitialSceneFrame = cvlpInitialSceneFrame;
    if (!self.cvlpInitialGeometryLogged) {
        NSLog(@"CVLP_INITIAL_SCENE_GEOMETRY host=%.1fx%.1f scene=%.1fx%.1f orientation=%ld",
            self.cvlpInitialBounds.size.width, self.cvlpInitialBounds.size.height,
            self.cvlpInitialSceneFrame.size.width, self.cvlpInitialSceneFrame.size.height,
            (long)self.cvlpInitialOrientation);
        self.cvlpInitialGeometryLogged = YES;
    }
    self.cvlpInitialGeometryPrepared = YES;
    return YES;
}
'''

    result = dict(sources)
    scene = _replace_once(
        scene,
        '#import "AppSceneViewController.h"\n',
        '#import "AppSceneViewController.h"\n#import <math.h>\n',
    )
    scene = _replace_once(
        scene,
        "@property(nonatomic) BOOL cvlpRevoked;\n",
        "@property(nonatomic) BOOL cvlpRevoked;\n"
        "@property(nonatomic) BOOL cvlpInitialGeometryLogged;\n"
        "@property(nonatomic) BOOL cvlpInitialGeometryPrepared;\n"
        "@property(nonatomic) CGRect cvlpInitialBounds;\n"
        "@property(nonatomic) CGRect cvlpInitialSceneFrame;\n"
        "@property(nonatomic) UIInterfaceOrientation cvlpInitialOrientation;\n"
        "- (BOOL)cvlpPrepareInitialGeometry;\n",
    )
    scene = _replace_once(
        scene,
        "                if (identifier) {\n"
        "                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];",
        "                if (identifier) {\n"
        "                    if (![self cvlpPrepareInitialGeometry]) {\n"
        '                        NSLog(@"CVLP_INITIAL_GEOMETRY_REJECTED");\n'
        "                        [self cvlpRevoke];\n"
        "                        NSError *geometryError = [NSError errorWithDomain:@\"CVLPInitialSceneGeometry\" code:1\n"
        "                            userInfo:@{NSLocalizedDescriptionKey: @\"Host scene geometry is unavailable.\"}];\n"
        "                        [delegate appSceneVC:self didInitializeWithError:geometryError];\n"
        "                        return;\n"
        "                    }\n"
        "                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];",
    )
    scene = _replace_once(
        scene,
        "- (void)setUpAppPresenter {\n    if (self.cvlpRevoked || self.cvlpSceneEnded) return;",
        helper + "- (void)setUpAppPresenter {\n"
        "    if (self.cvlpRevoked || self.cvlpSceneEnded) return;\n"
        "    NSAssert(self.cvlpInitialGeometryPrepared, @\"Initial scene geometry must be prepared before scene setup\");\n"
        "    if (!self.cvlpInitialGeometryPrepared) return;",
    )
    scene = _replace_once(
        scene,
        "        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;\n"
        "        settings.foreground = YES;",
        "        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;\n"
        "        settings.frame = self.cvlpInitialSceneFrame;\n"
        "        settings.interfaceOrientation = self.cvlpInitialOrientation;\n"
        "        settings.foreground = YES;",
    )
    scene = _replace_once(
        scene,
        "        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;",
        "        clientSettings.interfaceOrientation = self.cvlpInitialOrientation;",
    )
    scene = _replace_once(
        scene,
        "        self.contentView = self.hostingController.sceneViewController.view;",
        "        self.contentView = self.hostingController.sceneViewController.view;\n"
        "        self.contentView.frame = self.cvlpInitialBounds;",
    )
    result[SCENE_PATH] = scene
    return result
