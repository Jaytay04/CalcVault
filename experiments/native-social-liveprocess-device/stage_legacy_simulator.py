"""Replace the synthetic framework guest in an isolated simulator host clone."""

import argparse
from pathlib import Path
import plistlib
import struct


HOST_ID = 'com.jaylintaylor.calcvault'
GUEST_ID = 'org.example.syntheticnativeguest.app'
FRAMEWORK_EXECUTABLE = 'NativeGuest'
MACHO_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_DYLIB = 6
LC_BUILD_VERSION = 0x32
PLATFORM_IOS_SIMULATOR = 7


def _plain_file(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('expected_regular_file')
    return path


def _plist(path):
    _plain_file(path)
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError('expected_dictionary_plist')
    return value


def _is_simulator_arm64_dylib(path):
    _plain_file(path)
    size = path.stat().st_size
    if size < 32 or size > 256 * 1024 * 1024:
        raise ValueError('unexpected_payload_size')
    data = path.read_bytes()
    header = struct.unpack_from('<8I', data)
    magic, cpu_type, _, file_type, command_count, command_bytes, _, _ = header
    if magic != MACHO_MAGIC_64 or cpu_type != CPU_TYPE_ARM64 or file_type != MH_DYLIB:
        raise ValueError('expected_arm64_dynamic_library')
    command_end = 32 + command_bytes
    if command_count > 10000 or command_end > len(data):
        raise ValueError('invalid_macho_load_commands')
    offset = 32
    platforms = []
    for _ in range(command_count):
        if offset + 8 > command_end:
            raise ValueError('invalid_macho_load_commands')
        command, command_size = struct.unpack_from('<2I', data, offset)
        if command_size < 8 or offset + command_size > command_end:
            raise ValueError('invalid_macho_load_commands')
        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise ValueError('invalid_build_version_command')
            platforms.append(struct.unpack_from('<I', data, offset + 8)[0])
        offset += command_size
    if offset != command_end or platforms != [PLATFORM_IOS_SIMULATOR]:
        raise ValueError('expected_ios_simulator_build')
    return True


def _validated_paths(host_arg, guest_arg, payload_arg):
    if host_arg.is_symlink() or guest_arg.is_symlink() or payload_arg.is_symlink():
        raise ValueError('symlink_input')
    host = host_arg.resolve(strict=True)
    guest = guest_arg.resolve(strict=True)
    payload = payload_arg.resolve(strict=True)
    host_parts = set(host.parts)
    guest_parts = set(guest.parts)
    if (host.name != 'LiveContainer.app' or not host.is_dir() or
            not {'Build', 'Products'} <= host_parts or
            'Debug-iphonesimulator' not in host.parts or
            'cvlp-legacy-host' not in host.parts):
        raise ValueError('expected_isolated_simulator_host_clone')
    if (guest.name != 'CVLPGuest.app' or not guest.is_dir() or
            not {'Build', 'Products'} <= guest_parts or
            'Release-iphonesimulator' not in guest.parts):
        raise ValueError('expected_simulator_guest_product')
    if payload.name != 'cvlp-legacy-payload.dylib':
        raise ValueError('expected_legacy_payload_name')
    _is_simulator_arm64_dylib(payload)
    return host, guest, payload


def stage(host_arg, guest_arg, payload_arg):
    host, guest, payload = _validated_paths(host_arg, guest_arg, payload_arg)
    host_info = _plist(host / 'Info.plist')
    if (host_info.get('CFBundleIdentifier') != HOST_ID or
            host_info.get('CVLPFrameworkGuestMode') != 1):
        raise ValueError('unexpected_host_identity_or_route')

    framework = host / 'Frameworks/NativeGuest.framework'
    if framework.is_symlink() or not framework.is_dir():
        raise ValueError('expected_synthetic_framework')
    current_info = _plist(framework / 'Info.plist')
    descriptor_path = host / 'CVLPFrameworkGuest.plist'
    descriptor = _plist(descriptor_path)
    expected_keys = {'schema', 'bundleIdentifier', 'bundleVersion', 'executable'}
    if set(descriptor) != expected_keys:
        raise ValueError('unexpected_framework_descriptor')
    current_version = current_info.get('CFBundleVersion')
    if (descriptor.get('schema') != 1 or
            descriptor.get('bundleIdentifier') != GUEST_ID or
            descriptor.get('bundleVersion') != current_version or
            descriptor.get('executable') != FRAMEWORK_EXECUTABLE or
            current_info.get('CFBundleIdentifier') != GUEST_ID or
            current_info.get('CFBundleExecutable') != FRAMEWORK_EXECUTABLE or
            current_info.get('CFBundlePackageType') != 'FMWK'):
        raise ValueError('synthetic_framework_only')
    _plain_file(framework / FRAMEWORK_EXECUTABLE)

    guest_info_path = guest / 'Info.plist'
    guest_info = _plist(guest_info_path)
    if (guest_info.get('CFBundleIdentifier') != GUEST_ID or
            guest_info.get('CFBundleVersion') != current_version or
            guest_info.get('CFBundleExecutable') != 'CVLPGuest'):
        raise ValueError('synthetic_guest_only')
    if 'UIApplicationSceneManifest' not in guest_info:
        raise ValueError('legacy_scene_manifest_missing')

    # Prepare all metadata before the first write; these paths are a disposable clone.
    guest_info.pop('UIApplicationSceneManifest')
    guest_info['UIRequiresFullScreen'] = True
    framework_info = dict(guest_info)
    framework_info['CFBundleExecutable'] = FRAMEWORK_EXECUTABLE
    framework_info['CFBundlePackageType'] = 'FMWK'
    framework_info.pop('LCSyntheticGuestExecutable', None)
    new_descriptor = {
        'schema': 1,
        'bundleIdentifier': GUEST_ID,
        'bundleVersion': current_version,
        'executable': FRAMEWORK_EXECUTABLE,
    }
    new_guest_bytes = plistlib.dumps(guest_info)
    new_framework_bytes = plistlib.dumps(framework_info)
    new_descriptor_bytes = plistlib.dumps(new_descriptor)
    new_payload_bytes = payload.read_bytes()

    guest_info_path.write_bytes(new_guest_bytes)
    (framework / 'Info.plist').write_bytes(new_framework_bytes)
    executable_path = framework / FRAMEWORK_EXECUTABLE
    executable_path.write_bytes(new_payload_bytes)
    executable_path.chmod(0o755)
    descriptor_path.write_bytes(new_descriptor_bytes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', type=Path, help='isolated Build/Products host clone')
    parser.add_argument('guest', type=Path, help='legacy simulator CVLPGuest.app product')
    parser.add_argument('payload', type=Path, help='prepatched simulator payload')
    args = parser.parse_args()
    try:
        stage(args.host, args.guest, args.payload)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise SystemExit(str(error)) from error
    print('Legacy synthetic simulator guest staged in isolated host clone; re-sign framework, extension, and host')


if __name__ == '__main__':
    main()
