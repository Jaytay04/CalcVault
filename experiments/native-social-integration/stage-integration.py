"""Embed only the freshly built CalcVaultKit into a generated synthetic host."""
import argparse
from pathlib import Path
import plistlib
import shutil


def stage(host, kit):
    if Path(host).is_symlink() or Path(kit).is_symlink():
        raise ValueError('symlink_input')
    host, kit = Path(host).resolve(strict=True), Path(kit).resolve(strict=True)
    if host.name != 'LiveContainer.app' or 'Build/Products' not in host.as_posix():
        raise ValueError('expected_generated_host')
    info = plistlib.loads((host / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.jaylintaylor.calcvault':
        raise ValueError('unexpected_host_identity')
    if kit.name != 'CalcVaultKit.framework' or kit.is_symlink():
        raise ValueError('expected_generated_kit')
    kit_info = plistlib.loads((kit / 'Info.plist').read_bytes())
    if kit_info.get('CFBundleIdentifier') != 'com.jaylintaylor.calcvault.kit':
        raise ValueError('unexpected_kit_identity')
    if sorted(p.name for p in (host / 'PlugIns').iterdir()) != ['LiveProcess.appex']:
        raise ValueError('unexpected_extension_inventory')
    contract = plistlib.loads((host / 'CVLPFrameworkGuest.plist').read_bytes())
    if contract.get('bundleIdentifier') != 'org.example.syntheticnativeguest.app':
        raise ValueError('synthetic_guest_required')
    target = host / 'Frameworks/CalcVaultKit.framework'
    if target.exists():
        raise ValueError('kit_already_embedded')
    shutil.copytree(kit, target)
    info['CFBundleVersion'] = '22.2'
    info['CFBundleDisplayName'] = 'Calculator'
    info['CVNativeIntegrationStage'] = 'synthetic-integration-22-authcheck1'
    # The containing app is CalcVault, not the generic upstream file manager.
    # Do not expose its Documents directory or inherit broad network/background
    # exceptions. Guest extension metadata is intentionally untouched here.
    info['UIFileSharingEnabled'] = False
    info['LSSupportsOpeningDocumentsInPlace'] = False
    info.pop('NSAppTransportSecurity', None)
    info.pop('UIBackgroundModes', None)
    info['NSFaceIDUsageDescription'] = 'Face ID verifies access to biometric-protected CalcVault key material.'
    (host / 'Info.plist').write_bytes(plistlib.dumps(info))
    print('Integration 22.2 synthetic host staged; nested code and host require fresh signing')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path)
    parser.add_argument('kit', type=Path)
    args = parser.parse_args()
    stage(args.host, args.kit)
