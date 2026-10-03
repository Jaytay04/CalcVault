#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$script_dir/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1; then
  echo "Simulator fixture NOT RUN: macOS with Xcode command-line tools is required." >&2
  exit 77
fi

xcode_version="$(xcodebuild -version 2>/dev/null | head -n 1 || true)"
if [[ "$xcode_version" != "Xcode 16.4" ]]; then
  echo "Simulator fixture NOT RUN: expected Xcode 16.4; found '${xcode_version:-unavailable}'." >&2
  exit 77
fi

sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
if [[ -z "$sdk_path" || "$(basename "$sdk_path")" != "iPhoneSimulator18.5.sdk" ]]; then
  echo "Simulator fixture NOT RUN: the iOS 18.5 simulator SDK is required." >&2
  exit 77
fi

case "$(uname -m)" in
  arm64)
    simulator_arch="arm64"
    simulator_target="arm64-apple-ios18.0-simulator"
    ;;
  x86_64)
    simulator_arch="x86_64"
    simulator_target="x86_64-apple-ios18.0-simulator"
    ;;
  *)
    echo "Simulator fixture NOT RUN: unsupported macOS host architecture '$(uname -m)'." >&2
    exit 77
    ;;
esac

runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-18-5"
runtime_json="$(xcrun simctl list runtimes -j)"
if ! python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(r.get("identifier")==sys.argv[1] and r.get("isAvailable") for r in d.get("runtimes",[])) else 1)' \
  "$runtime_id" <<<"$runtime_json"; then
  echo "Simulator fixture NOT RUN: the iOS 18.5 simulator runtime is unavailable." >&2
  exit 77
fi

device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-16"
device_types_json="$(xcrun simctl list devicetypes -j)"
if ! python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(t.get("identifier")==sys.argv[1] for t in d.get("devicetypes",[])) else 1)' \
  "$device_type" <<<"$device_types_json"; then
  echo "Simulator fixture NOT RUN: the iPhone 16 simulator device type is unavailable." >&2
  exit 77
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tkp-profile-settings-ui.XXXXXX")"
app_path="$build_dir/TKPProfileSettingsUIFixture.app"
mkdir -p "$app_path"
echo "Synthetic simulator fixture artifacts: $build_dir"

xcrun --sdk iphonesimulator clang \
  -target "$simulator_target" \
  -isysroot "$sdk_path" \
  -fobjc-arc -fblocks -std=c11 \
  -Wall -Wextra -Werror \
  -DTKP_DEVICE_PANEL_TESTING=1 \
  -I "$experiment_dir/Guest" \
  "$script_dir/TKPProfileSettingsUIFixture.m" \
  "$experiment_dir/Guest/TKPProfileControls.m" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -o "$app_path/TKPProfileSettingsUIFixture"

cp "$script_dir/TKPProfileSettingsUIFixture-Info.plist" "$app_path/Info.plist"
plutil -lint "$app_path/Info.plist"

architectures="$(lipo -archs "$app_path/TKPProfileSettingsUIFixture")"
if [[ "$architectures" != "$simulator_arch" ]]; then
  echo "Simulator fixture build failed: expected $simulator_arch only; found '$architectures'." >&2
  exit 1
fi

build_info="$(xcrun vtool -show-build "$app_path/TKPProfileSettingsUIFixture")"
if ! grep -Fq 'platform IOSSIMULATOR' <<<"$build_info"; then
  echo "Simulator fixture build failed: executable is not marked for the iOS simulator." >&2
  exit 1
fi
if ! grep -Fq 'minos 18.0' <<<"$build_info"; then
  echo "Simulator fixture build failed: minimum deployment target is not iOS 18.0." >&2
  exit 1
fi

codesign --force --sign - --timestamp=none --deep "$app_path"
codesign --verify --deep --strict "$app_path"

device_name="tkp-profile-settings-fixture-${BASHPID:-$$}"
device_uuid="$(xcrun simctl create "$device_name" "$device_type" "$runtime_id")"
cleanup() {
  if [[ -n "${device_uuid:-}" ]]; then
    xcrun simctl shutdown "$device_uuid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun simctl boot "$device_uuid"
xcrun simctl bootstatus "$device_uuid" -b
xcrun simctl install "$device_uuid" "$app_path"

launch_log="$build_dir/simulator-console.log"
set +e
python3 - "$device_uuid" "org.example.tkplus.settingsfixture" <<'PY' 2>&1 | tee "$launch_log"
import subprocess
import sys

command = ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", sys.argv[1], sys.argv[2]]
try:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
except subprocess.TimeoutExpired as error:
    for chunk in (error.stdout, error.stderr):
        if chunk:
            sys.stdout.write(chunk.decode(errors="replace") if isinstance(chunk, bytes) else chunk)
    print("Simulator fixture failed: launch did not exit within 60 seconds.")
    sys.exit(124)

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
PY
launch_status=${PIPESTATUS[0]}
set -e

if [[ "$launch_status" -ne 0 ]]; then
  echo "Simulator fixture failed: simctl launch returned $launch_status. Log: $launch_log" >&2
  exit "$launch_status"
fi
if ! grep -Fqx 'PASS: synthetic profile settings UI fixture' "$launch_log"; then
  echo "Simulator fixture failed: the exact PASS marker is missing. Log: $launch_log" >&2
  exit 1
fi

echo "PASS: simulator profile settings UI fixture (iPhone 16 / iOS 18.5)."
