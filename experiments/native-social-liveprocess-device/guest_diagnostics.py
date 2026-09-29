"""Apply opt-in, bounded UIKit startup diagnostics to a transformed guest map."""

PROBE_HEADER_PATH = "LiveContainer/CVLPProbe.h"
PROBE_IMPLEMENTATION_PATH = "LiveContainer/CVLPProbe.m"
BOOTSTRAP_PATH = "LiveContainer/LCBootstrap.m"
OWNED_PATHS = (PROBE_HEADER_PATH, PROBE_IMPLEMENTATION_PATH, BOOTSTRAP_PATH)


def _require_once(source, anchor):
    if source.count(anchor) != 1:
        raise ValueError(f"guest_diagnostics_anchor_drift:{anchor[:80]!r}")


def _replace_once(source, anchor, replacement):
    _require_once(source, anchor)
    return source.replace(anchor, replacement, 1)


def transform(sources):
    """Return a transformed copy, validating all anchors before making edits."""
    if not all(path in sources for path in OWNED_PATHS):
        raise ValueError("guest_diagnostics_sources_missing")

    header = sources[PROBE_HEADER_PATH]
    probe = sources[PROBE_IMPLEMENTATION_PATH]
    bootstrap = sources[BOOTSTRAP_PATH]
    if (
        "CVLPGuestDiagnostics.h" in probe
        or "startGuestGeometryObservations" in header
        or "CVLP_GUEST_GEOMETRY" in bootstrap
    ):
        raise ValueError("guest_diagnostics_already_applied")

    header_anchor = '+ (NSString *)recordStage:(NSString *)stage;'
    import_anchor = '#import "CVLPKeychainIdentity.h"'
    implementation_anchor = "+ (NSString *)hostSummary {"
    bootstrap_anchor = (
        '    [CVLPProbe recordStage:@"post-loader"];\n'
        "\n"
        "    // Go!\n"
    )
    app_main_anchor = "ret = appMain(argc, argv);"

    # Validate every touched anchor and ordering before editing any copy.
    _require_once(header, header_anchor)
    _require_once(probe, import_anchor)
    _require_once(probe, implementation_anchor)
    _require_once(bootstrap, bootstrap_anchor)
    _require_once(bootstrap, app_main_anchor)
    if bootstrap.index(app_main_anchor) < bootstrap.index(bootstrap_anchor):
        raise ValueError("guest_diagnostics_app_main_order")

    header = _replace_once(
        header,
        header_anchor,
        header_anchor
        + "\n\n"
        + "/// Installs bounded, content-free guest startup observations.\n"
        + "+ (void)startGuestGeometryObservations;\n"
        + "/// Appends one sanitized startup observation to the existing stage report.\n"
        + "+ (void)recordGuestDiagnostic:(NSString *)line;",
    )
    probe = _replace_once(
        probe,
        import_anchor,
        import_anchor + '\n#import "CVLPGuestDiagnostics.h"',
    )
    methods = '''+ (void)startGuestGeometryObservations {
    [CVLPGuestGeometryDiagnostics start];
}

+ (void)recordGuestDiagnostic:(NSString *)line {
    if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }
    NSArray<NSString *> *allStageObservations;
    BOOL bookmarkActivated;
    @synchronized (self) {
        if (CVLPStageObservations == nil) { CVLPStageObservations = [NSMutableArray array]; }
        [CVLPStageObservations addObject:line];
        allStageObservations = [CVLPStageObservations copy];
        bookmarkActivated = CVLPGuestBookmarkActivated;
    }
    NSLog(@"%@", line);
    if (bookmarkActivated) { CVLPWriteGuestReportIfAuthorized(allStageObservations); }
}

'''
    probe = _replace_once(probe, implementation_anchor, methods + implementation_anchor)
    bootstrap = _replace_once(
        bootstrap,
        bootstrap_anchor,
        '    [CVLPProbe recordStage:@"post-loader"];\n'
        '    [CVLPProbe startGuestGeometryObservations];\n'
        "\n"
        "    // Go!\n",
    )

    result = dict(sources)
    result[PROBE_HEADER_PATH] = header
    result[PROBE_IMPLEMENTATION_PATH] = probe
    result[BOOTSTRAP_PATH] = bootstrap
    return result
