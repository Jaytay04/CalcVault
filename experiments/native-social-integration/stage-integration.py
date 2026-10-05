"""Embed only the freshly built CalcVaultKit into a generated synthetic host."""
import argparse
from pathlib import Path
import plistlib
import shutil


def stage(host, kit, build=23, profile='synthetic', signal_diagnostic=False):
    if type(signal_diagnostic) is not bool or (signal_diagnostic and build != 24):
        raise ValueError('unsupported_signal_diagnostic')
    if type(build) is not int or build not in (23, 24):
        raise ValueError('unsupported_integration_build')
    if profile not in ('synthetic', 'tiktok47') or (build == 23 and profile != 'synthetic'):
        raise ValueError('unsupported_integration_profile')
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
    contract_path = host / 'CVLPFrameworkGuest.plist'
    if contract_path.is_symlink() or not contract_path.is_file():
        raise ValueError('invalid_guest_contract_file')
    contract = plistlib.loads(contract_path.read_bytes())
    expected = {
        (23, 'synthetic'): ('org.example.syntheticnativeguest.app', '1'),
        (24, 'synthetic'): ('org.example.syntheticnativeguest.app', '1'),
        (24, 'tiktok47'): ('com.zhiliaoapp.musically', '470044'),
    }[(build, profile)]
    if (not isinstance(contract, dict) or
            set(contract) != {'schema', 'bundleIdentifier', 'bundleVersion', 'executable'} or
            type(contract.get('schema')) is not int):
        raise ValueError('guest_profile_mismatch')
    if profile == 'synthetic' and contract.get('bundleIdentifier') != expected[0]:
        raise ValueError('synthetic_guest_required')
    if (contract.get('bundleIdentifier'), contract.get('bundleVersion'),
            contract.get('executable'), contract.get('schema')) != (*expected, 'NativeGuest', 1):
        raise ValueError('guest_profile_mismatch')
    target = host / 'Frameworks/CalcVaultKit.framework'
    if target.exists():
        raise ValueError('kit_already_embedded')
    shutil.copytree(kit, target)
    info['CFBundleVersion'] = str(build)
    info['CFBundleDisplayName'] = 'Calculator'
    info['CVNativeIntegrationStage'] = (
        'private-tiktok47-integration-24' if profile == 'tiktok47'
        else f'synthetic-integration-{build}'
    )
    info['CVNativeGuestKind'] = 'tiktok47' if profile == 'tiktok47' else 'synthetic'
    # This flag does not make a synthetic host eligible for native signals.
    # The session additionally checks the privately merged original descriptor.
    if signal_diagnostic:
        info['CVNativeSignalDiagnosticEnabled'] = True
    else:
        info.pop('CVNativeSignalDiagnosticEnabled', None)
    # The containing app is CalcVault, not the generic upstream file manager.
    # Do not expose its Documents directory or inherit broad network/background
    # exceptions. Guest extension metadata is intentionally untouched here.
    info['UIFileSharingEnabled'] = False
    info['LSSupportsOpeningDocumentsInPlace'] = False
    info.pop('NSAppTransportSecurity', None)
    info.pop('UIBackgroundModes', None)
    info['NSFaceIDUsageDescription'] = 'Face ID verifies access to biometric-protected CalcVault key material.'
    (host / 'Info.plist').write_bytes(plistlib.dumps(info))
    print(f'Integration {build} {profile} host staged; nested code and host require fresh signing')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path)
    parser.add_argument('kit', type=Path)
    parser.add_argument('--build', type=int, choices=(23, 24), default=23)
    parser.add_argument('--profile', choices=('synthetic', 'tiktok47'), default='synthetic')
    parser.add_argument('--signal-diagnostic', action='store_true')
    args = parser.parse_args()
    stage(args.host, args.kit, build=args.build, profile=args.profile, signal_diagnostic=args.signal_diagnostic)
