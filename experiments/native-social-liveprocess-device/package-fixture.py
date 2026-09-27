"""Stage only generated synthetic resources and explicit research entitlements."""

import argparse
from pathlib import Path
import plistlib
import shutil


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("guest", type=Path)
    parser.add_argument("payload", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--simulator", action="store_true")
    args = parser.parse_args()
    host = args.host.resolve(strict=True)
    guest = args.guest.resolve(strict=True)
    output = args.output.resolve()
    if host.name != "LiveContainer.app" or "Build/Products" not in host.as_posix():
        raise SystemExit("Expected a generated LiveContainer build product")
    plugins = host / "PlugIns"
    for extra in ("ShareExtension.appex", "LaunchAppExtension.appex"):
        target = (plugins / extra).resolve()
        if target.parent != plugins.resolve():
            raise SystemExit("Unexpected extension path")
        if target.exists():
            shutil.rmtree(target)
    if sorted(p.name for p in plugins.iterdir()) != ["LiveProcess.appex"]:
        raise SystemExit("Expected only the reviewed LiveProcess extension")
    if list(host.rglob("*.app")):
        raise SystemExit("A guest must not be packaged as another app product")
    if any(p.suffix.lower() in (".p12", ".pfx", ".mobileprovision") for p in host.rglob("*")):
        raise SystemExit("Signing material must not appear in the public CI fixture")
    host_info = plistlib.loads((host / "Info.plist").read_bytes())
    if host_info["CFBundleIdentifier"] != "com.jaylintaylor.calcvault":
        raise SystemExit("Unexpected containing app identity")
    host_info["CFBundleDisplayName"] = "Native Probe"
    host_info["CFBundleVersion"] = "18"
    host_info["NSFaceIDUsageDescription"] = "Authenticate disposable synthetic Keychain migration test items."
    (host / "Info.plist").write_bytes(plistlib.dumps(host_info))
    resources = host / "SyntheticGuestResources.bundle"
    resources.mkdir(exist_ok=True)
    shutil.copy2(guest / "Info.plist", resources / "GuestInfo.plist")
    resource_info = {
        "CFBundleIdentifier": "org.example.cvlp.resources",
        "CFBundleName": "SyntheticGuestResources",
        "CFBundlePackageType": "BNDL",
        "CFBundleVersion": "18",
        "CFBundleShortVersionString": "1.0.0",
    }
    (resources / "Info.plist").write_bytes(plistlib.dumps(resource_info))
    (host / "Frameworks").mkdir(exist_ok=True)
    shutil.copy2(args.payload, host / "Frameworks/SyntheticNativeGuestPayload.dylib")
    output.mkdir(parents=True, exist_ok=True)
    group = "group.com.jaylintaylor.calcvault.nativeprobe"
    prefix = "AAAAA11111." if args.simulator else "FAKETEAMID."
    common = [prefix + "com.jaylintaylor.calcvault", prefix + "com.kdt.livecontainer.shared"]
    base = {"com.apple.security.application-groups": [group], "get-task-allow": True}
    for name, groups in (("host", common + [prefix + "com.jaylintaylor.calcvault.hostonly"]), ("extension", common)):
        entitlements = dict(base, **{"keychain-access-groups": groups})
        if args.simulator:
            # Match the earlier successful simulator loader fixture. Placeholder
            # phone Keychain/debug entitlements are not a simulator signing test.
            entitlements = {"com.apple.security.application-groups": [group]}
        (output / f"{name}.entitlements").write_bytes(plistlib.dumps(entitlements))
    print("One host, one LiveProcess extension, one embedded synthetic dylib; no signing credentials")


if __name__ == "__main__":
    main()
