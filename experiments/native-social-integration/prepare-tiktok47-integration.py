"""Prepare the pinned Build 24 integration host sources without packaging a guest."""
import argparse
import importlib.util
from pathlib import Path
import subprocess

APP = 'LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift'
BOOT = 'LiveContainer/LCBootstrap.m'
PROBE = 'LiveContainer/CVLPProbe.m'
SESSION = 'LiveContainer/CVLPGuestSession.m'
SCENE = 'MultitaskSupport/AppSceneViewController.m'
EXTENSION = 'LiveProcess/main.m'
DATA_PATH_COUNTS = {BOOT: 4, PROBE: 1, SESSION: 1, SCENE: 2, EXTENSION: 2}
MARKER = 'Build marker: integration-23.'
OBSERVATION = 'Integration 23: migration fixture not repeated; guest boundary controls remain synthetic.'


def transform(sources):
    """Return a Build 24 copy, failing closed if the Build 23 base drifted."""
    changed = dict(sources)
    if changed.get(APP, '').count('Build 20 framework portrait test 1') != 0:
        raise ValueError('unexpected_app_source_after_base_transform')
    if changed.get(PROBE, '').count(MARKER) != 1:
        raise ValueError('build_marker_anchor_drift')
    if changed[PROBE].count(OBSERVATION) != 1:
        raise ValueError('host_observation_anchor_drift')
    for path, count in DATA_PATH_COUNTS.items():
        if changed.get(path, '').count('integration-native-23') != count:
            raise ValueError('guest_data_path_anchor_drift')

    changed[PROBE] = changed[PROBE].replace(MARKER, 'Build marker: integration-24.')
    changed[PROBE] = changed[PROBE].replace(
        OBSERVATION,
        'Integration 24: migration fixture not repeated; guest boundary controls remain synthetic.')
    for path in DATA_PATH_COUNTS:
        changed[path] = changed[path].replace('integration-native-23', 'integration-native-24')
    return changed


def load_base_adapter(path):
    spec = importlib.util.spec_from_file_location('prepare_integration_base', path)
    if spec is None or spec.loader is None:
        raise RuntimeError('base_adapter_unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(source, base_path, integration_app):
    base = load_base_adapter(base_path)
    root = Path(source).resolve(strict=True)
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != base.PIN:
        raise SystemExit('upstream_revision_mismatch')
    raw = {name: (root / name).read_text(encoding='utf-8') for name in base.NAMES}
    base_prepared = base.transform(raw, Path(integration_app).read_text(encoding='utf-8'))
    prepared = transform(base_prepared)
    for name, contents in prepared.items():
        (root / name).write_text(contents, encoding='utf-8')
    print('Build 24 integration host sources prepared; package identity remains selected at staging')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    prepare(args.source, here / 'prepare-integration.py', here / 'IntegrationApp.swift')


if __name__ == '__main__':
    main()
