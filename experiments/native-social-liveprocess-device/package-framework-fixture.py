"""Stage ONLY the generated synthetic guest for the opt-in framework loader.

This is not the private social-package merger. Run on a disposable host after
package-fixture.py; then sign the new framework before the extension and host.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import struct


def stage(host, guest, payload):
    host, guest, payload = (Path(p).resolve(strict=True) for p in (host, guest, payload))
    if host.name != 'LiveContainer.app' or 'Build/Products' not in host.as_posix():
        raise ValueError('expected_generated_host')
    host_info = plistlib.loads((host / 'Info.plist').read_bytes())
    info = plistlib.loads((guest / 'Info.plist').read_bytes())
    if host_info.get('CFBundleIdentifier') != 'com.jaylintaylor.calcvault':
        raise ValueError('unexpected_host_identity')
    if info.get('CFBundleIdentifier') != 'org.example.syntheticnativeguest.app':
        raise ValueError('synthetic_guest_only')
    with payload.open('rb') as stream:
        header = stream.read(16)
    if len(header) != 16 or struct.unpack('<4I', header)[:2] != (0xfeedfacf, 0x100000c) or struct.unpack('<4I', header)[3] != 6:
        raise ValueError('expected_prepared_arm64_dylib')
    framework = host / 'Frameworks/NativeGuest.framework'
    descriptor = host / 'CVLPFrameworkGuest.plist'
    if framework.exists() or descriptor.exists():
        raise ValueError('framework_fixture_already_exists')
    if not (host / 'Frameworks').is_dir() or (host / 'Frameworks').is_symlink():
        raise ValueError('expected_framework_directory')
    info['CFBundleExecutable'] = 'NativeGuest'
    info['CFBundlePackageType'] = 'FMWK'
    info.pop('LCSyntheticGuestExecutable', None)
    version = info.get('CFBundleVersion')
    if not isinstance(version, str) or not 0 < len(version) <= 64:
        raise ValueError('invalid_fixture_version')
    contract = {'schema': 1, 'bundleIdentifier': info['CFBundleIdentifier'],
                'bundleVersion': version, 'executable': 'NativeGuest'}
    framework.mkdir()
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile(payload, framework / 'NativeGuest')
    (framework / 'NativeGuest').chmod(0o755)
    descriptor.write_bytes(plistlib.dumps(contract))
    host_info['CFBundleVersion'] = '20'
    host_info['CVLPFrameworkGuestMode'] = 1
    (host / 'Info.plist').write_bytes(plistlib.dumps(host_info))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path)
    parser.add_argument('guest', type=Path)
    parser.add_argument('payload', type=Path)
    args = parser.parse_args()
    stage(args.host, args.guest, args.payload)
    print('Synthetic immutable guest framework staged; fresh framework/extension/host signing required')


if __name__ == '__main__':
    main()
